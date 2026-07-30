#!/usr/bin/env bash
#
# Deploy the Entra ID guest lifecycle solution: resource group, both Consumption
# Logic Apps (via main.bicep), and the Microsoft Graph app roles their managed
# identities need.
#
# Everything here is idempotent — re-running converges rather than duplicating.
# Directory writes (managed identity service principals, app role assignments)
# replicate asynchronously, so every directory lookup and the role assignment
# itself are retried RETRY_ATTEMPTS times with RETRY_WAIT_SECONDS between tries.
#
# Requires: az CLI (logged in, correct subscription), jq.
#
set -euo pipefail

readonly GRAPH_APP_ID='00000003-0000-0000-c000-000000000000'
readonly WORKFLOW_API_VERSION='2019-05-01'
readonly RETRY_ATTEMPTS=5
readonly RETRY_WAIT_SECONDS=15

# AuditLog.Read.All + User.ReadWrite.All are the two roles the workflows cannot
# function without: signInActivity is gated behind AuditLog.Read.All, and
# disabling/deleting a guest needs User.ReadWrite.All. GroupMember.Read.All is
# included because both definitions enumerate /groups/{id}/members to find the
# users to evaluate. Override with --roles if your tenant grants differently.
DEFAULT_GRAPH_ROLES='AuditLog.Read.All User.ReadWrite.All GroupMember.Read.All'

resource_group=''
location='westeurope'
subscription=''
all_guests_group_id=''
eligible_group_id=''
parameters_file=''
report_only=''
graph_roles="${DEFAULT_GRAPH_ROLES}"
skip_infra=false
skip_permissions=false
deployment_name="entraid-guest-lcm-$(date -u +%Y%m%d%H%M%S)"

log()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    \033[33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\n\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: deploy.sh --resource-group NAME [options]

Required for a full deployment:
  --resource-group NAME        Target resource group (created if absent).
  --all-guests-group-id GUID   Object ID of the "All Guests" dynamic group.
  --eligible-group-id GUID     Object ID of the "Eligible For Removal" group.

Options:
  --location REGION            Region for the resource group (default: westeurope).
  --subscription ID            Subscription to deploy into (default: current).
  --parameters-file PATH       Bicep parameters file; supplies/overrides group IDs.
  --report-only true|false     Dry-run switch. With --skip-infra this updates ONLY
                               the ReportOnly parameter on both existing workflows
                               and leaves the definitions untouched.
  --roles "A B C"              Graph app roles to assign (default:
                               AuditLog.Read.All User.ReadWrite.All GroupMember.Read.All).
  --skip-infra                 Do not create the RG or deploy Bicep.
  --skip-permissions           Deploy infrastructure only; assign no Graph roles.
  -h, --help                   Show this help.

Examples:
  # First deployment, safe by default (ReportOnly=true)
  ./deploy.sh --resource-group rg-guest-lcm \
              --all-guests-group-id <guid> --eligible-group-id <guid>

  # Re-assign Graph roles only (e.g. after a role was revoked)
  ./deploy.sh --resource-group rg-guest-lcm --skip-infra

  # Go live: flip ReportOnly off without redeploying the workflows
  ./deploy.sh --resource-group rg-guest-lcm --skip-infra --report-only false
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --resource-group)      resource_group="${2:-}"; shift 2 ;;
    --location)            location="${2:-}"; shift 2 ;;
    --subscription)        subscription="${2:-}"; shift 2 ;;
    --all-guests-group-id) all_guests_group_id="${2:-}"; shift 2 ;;
    --eligible-group-id)   eligible_group_id="${2:-}"; shift 2 ;;
    --parameters-file)     parameters_file="${2:-}"; shift 2 ;;
    --report-only)         report_only="${2:-}"; shift 2 ;;
    --roles)               graph_roles="${2:-}"; shift 2 ;;
    --skip-infra)          skip_infra=true; shift ;;
    --skip-permissions)    skip_permissions=true; shift ;;
    -h|--help)             usage; exit 0 ;;
    *)                     usage >&2; die "Unknown argument: $1" ;;
  esac
done

[[ -n $resource_group ]] || { usage >&2; die '--resource-group is required.'; }
if [[ -n $report_only && $report_only != 'true' && $report_only != 'false' ]]; then
  die "--report-only must be exactly 'true' or 'false' (got: '${report_only}')."
fi
command -v az >/dev/null || die 'az CLI not found. See https://learn.microsoft.com/cli/azure/install-azure-cli'
command -v jq >/dev/null || die 'jq not found. Install jq (it is preinstalled in Azure Cloud Shell).'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# --- retry helpers -----------------------------------------------------------

# retry <description> <command...> — echoes stdout of the first successful run.
retry() {
  local description="$1"; shift
  local attempt=1 output=''
  while (( attempt <= RETRY_ATTEMPTS )); do
    if output="$("$@" 2>/dev/null)"; then
      printf '%s' "$output"
      return 0
    fi
    warn "${description} failed (attempt ${attempt}/${RETRY_ATTEMPTS})."
    (( attempt == RETRY_ATTEMPTS )) && break
    sleep "$RETRY_WAIT_SECONDS"
    (( attempt++ ))
  done
  return 1
}

# retry_nonempty <description> <command...> — as retry, but an empty result also
# counts as failure. This is what makes directory propagation tolerable: a
# lookup that succeeds with an empty body is retried instead of being passed on
# as an empty id.
retry_nonempty() {
  local description="$1"; shift
  local attempt=1 output=''
  while (( attempt <= RETRY_ATTEMPTS )); do
    output="$("$@" 2>/dev/null || true)"
    output="${output//$'\r'/}"
    if [[ -n ${output// /} && $output != 'null' ]]; then
      printf '%s' "$output"
      return 0
    fi
    warn "${description} returned nothing yet (attempt ${attempt}/${RETRY_ATTEMPTS})."
    (( attempt == RETRY_ATTEMPTS )) && break
    sleep "$RETRY_WAIT_SECONDS"
    (( attempt++ ))
  done
  return 1
}

require_id() {
  local label="$1" value="$2"
  [[ -n ${value// /} && $value != 'null' ]] || die "${label} is empty — refusing to call the API with an empty id."
}

# --- subscription ------------------------------------------------------------

if [[ -n $subscription ]]; then
  log "Selecting subscription ${subscription}"
  az account set --subscription "$subscription"
fi
account_name="$(az account show --query name -o tsv)" \
  || die 'Not logged in. Run: az login'
info "Subscription: ${account_name}"

# --- infrastructure ----------------------------------------------------------

if [[ $skip_infra == true ]]; then
  log 'Skipping infrastructure (--skip-infra)'
else
  [[ -n $all_guests_group_id || -n $parameters_file ]] \
    || die '--all-guests-group-id (or --parameters-file) is required unless --skip-infra is set.'
  [[ -n $eligible_group_id || -n $parameters_file ]] \
    || die '--eligible-group-id (or --parameters-file) is required unless --skip-infra is set.'

  log "Ensuring resource group ${resource_group} in ${location}"
  az group create --name "$resource_group" --location "$location" --output none
  info 'Resource group ready.'

  deploy_args=(
    --resource-group "$resource_group"
    --name "$deployment_name"
    --template-file "${script_dir}/main.bicep"
  )
  [[ -n $parameters_file ]] && deploy_args+=(--parameters "@${parameters_file}")
  # Explicit flags win over the parameters file, so they come last.
  [[ -n $all_guests_group_id ]] && deploy_args+=(--parameters "allGuestsGroupId=${all_guests_group_id}")
  [[ -n $eligible_group_id ]]   && deploy_args+=(--parameters "eligibleForRemovalGroupId=${eligible_group_id}")
  [[ -n $report_only ]]         && deploy_args+=(--parameters "reportOnly=${report_only}")

  log 'Deploying main.bicep'
  az deployment group create "${deploy_args[@]}" --output none
  info "Deployment ${deployment_name} complete."
fi

# --- resolve workflow names + managed identity principal ids -----------------

log 'Resolving workflow managed identities'

mark_name=''
delete_name=''
if [[ $skip_infra == false ]]; then
  outputs="$(retry_nonempty 'Reading deployment outputs' \
    az deployment group show --resource-group "$resource_group" --name "$deployment_name" \
      --query properties.outputs -o json)" || die 'Could not read deployment outputs.'
  mark_name="$(jq -r '.markWorkflowName.value // empty' <<<"$outputs")"
  delete_name="$(jq -r '.deleteWorkflowName.value // empty' <<<"$outputs")"
fi

# On --skip-infra there is no deployment to read, so discover the workflows in
# the resource group by the tag-free convention: name contains EntraIDGuestLCM.
if [[ -z $mark_name || -z $delete_name ]]; then
  workflows="$(retry_nonempty 'Listing Logic Apps in the resource group' \
    az resource list --resource-group "$resource_group" \
      --resource-type 'Microsoft.Logic/workflows' --query '[].name' -o json)" \
    || die "No Logic Apps found in ${resource_group}."
  mark_name="${mark_name:-$(jq -r '[.[] | select(test("Mark"; "i"))] | first // empty' <<<"$workflows")}"
  delete_name="${delete_name:-$(jq -r '[.[] | select(test("Delete"; "i"))] | first // empty' <<<"$workflows")}"
fi

require_id 'Mark workflow name' "$mark_name"
require_id 'Delete workflow name' "$delete_name"
info "Mark workflow:   ${mark_name}"
info "Delete workflow: ${delete_name}"

workflow_principal_id() {
  local workflow_name="$1"
  retry_nonempty "Reading managed identity of ${workflow_name}" \
    az resource show --resource-group "$resource_group" --name "$workflow_name" \
      --resource-type 'Microsoft.Logic/workflows' \
      --query 'identity.principalId' -o tsv
}

mark_principal_id="$(workflow_principal_id "$mark_name")" \
  || die "${mark_name} has no managed identity principalId. Is the system-assigned identity enabled?"
delete_principal_id="$(workflow_principal_id "$delete_name")" \
  || die "${delete_name} has no managed identity principalId. Is the system-assigned identity enabled?"

require_id 'Mark managed identity principalId' "$mark_principal_id"
require_id 'Delete managed identity principalId' "$delete_principal_id"
info "Mark identity:   ${mark_principal_id}"
info "Delete identity: ${delete_principal_id}"

# --- Microsoft Graph app roles ----------------------------------------------

assign_graph_roles() {
  local graph_sp_id app_role_id principal existing

  graph_sp_id="$(retry_nonempty 'Looking up the Microsoft Graph service principal' \
    az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv)" \
    || die 'Microsoft Graph service principal not found in this tenant.'
  require_id 'Microsoft Graph service principal objectId' "$graph_sp_id"
  info "Microsoft Graph SP: ${graph_sp_id}"

  # A brand-new workflow's identity may not be queryable as a service principal
  # for a few seconds after ARM returns. Wait for both before assigning.
  for principal in "$mark_principal_id" "$delete_principal_id"; do
    require_id 'Managed identity principalId' "$principal"
    retry_nonempty "Waiting for service principal ${principal} to replicate" \
      az ad sp show --id "$principal" --query id -o tsv >/dev/null \
      || die "Managed identity ${principal} is not visible in the directory yet. Re-run with --skip-infra in a few minutes."
  done

  local role
  for role in $graph_roles; do
    log "Graph app role: ${role}"

    app_role_id="$(retry_nonempty "Resolving app role id for ${role}" \
      az ad sp show --id "$GRAPH_APP_ID" \
        --query "appRoles[?value=='${role}' && contains(allowedMemberTypes,'Application')].id | [0]" -o tsv)" \
      || die "Could not resolve the app role id for ${role}. Check the spelling."
    require_id "App role id for ${role}" "$app_role_id"
    info "Role id: ${app_role_id}"

    for principal in "$mark_principal_id" "$delete_principal_id"; do
      require_id 'Managed identity principalId' "$principal"

      existing="$(retry "Checking existing assignments on ${principal}" \
        az rest --method GET \
          --url "https://graph.microsoft.com/v1.0/servicePrincipals/${principal}/appRoleAssignments" \
          --query "value[?appRoleId=='${app_role_id}' && resourceId=='${graph_sp_id}'] | [0].id" -o tsv)" \
        || die "Could not read existing app role assignments for ${principal}."

      if [[ -n ${existing// /} && $existing != 'null' ]]; then
        info "${principal} already has ${role} — skipping."
        continue
      fi

      local body
      body="$(jq -nc --arg principalId "$principal" \
                     --arg resourceId "$graph_sp_id" \
                     --arg appRoleId "$app_role_id" \
                     '{principalId: $principalId, resourceId: $resourceId, appRoleId: $appRoleId}')"

      if retry "Assigning ${role} to ${principal}" \
        az rest --method POST \
          --url "https://graph.microsoft.com/v1.0/servicePrincipals/${principal}/appRoleAssignments" \
          --headers 'Content-Type=application/json' \
          --body "$body" >/dev/null; then
        info "Assigned ${role} to ${principal}."
      else
        # A concurrent run may have created it between our check and our POST.
        existing="$(az rest --method GET \
          --url "https://graph.microsoft.com/v1.0/servicePrincipals/${principal}/appRoleAssignments" \
          --query "value[?appRoleId=='${app_role_id}' && resourceId=='${graph_sp_id}'] | [0].id" \
          -o tsv 2>/dev/null || true)"
        [[ -n ${existing// /} && $existing != 'null' ]] \
          || die "Failed to assign ${role} to ${principal}. You need Privileged Role Administrator or Global Administrator to grant Graph app roles."
        info "${role} already present on ${principal} (created concurrently)."
      fi
    done
  done
}

if [[ $skip_permissions == true ]]; then
  log 'Skipping Graph app roles (--skip-permissions)'
else
  assign_graph_roles
fi

# --- ReportOnly-only update --------------------------------------------------

# Flipping the dry-run switch without redeploying: read the workflow, replace
# exactly one parameter value, PUT it back. The definition is round-tripped
# unchanged, and identity.type is resent so the managed identity is preserved.
set_report_only() {
  local workflow_name="$1" value="$2" workflow_id current updated

  workflow_id="$(retry_nonempty "Resolving resource id of ${workflow_name}" \
    az resource show --resource-group "$resource_group" --name "$workflow_name" \
      --resource-type 'Microsoft.Logic/workflows' --query id -o tsv)" \
    || die "Could not resolve ${workflow_name}."
  require_id "Resource id of ${workflow_name}" "$workflow_id"

  current="$(retry_nonempty "Reading ${workflow_name}" \
    az rest --method GET --url "https://management.azure.com${workflow_id}?api-version=${WORKFLOW_API_VERSION}")" \
    || die "Could not read ${workflow_name}."

  updated="$(jq --argjson reportOnly "$value" '{
      location: .location,
      tags: (.tags // {}),
      identity: { type: .identity.type },
      properties: {
        state: .properties.state,
        definition: .properties.definition,
        parameters: ((.properties.parameters // {}) | .ReportOnly = { value: $reportOnly })
      }
    }' <<<"$current")"

  # Guard against writing back a workflow whose definition we failed to read.
  [[ "$(jq -r '.properties.definition.actions | length' <<<"$updated")" -gt 0 ]] \
    || die "Refusing to update ${workflow_name}: its definition read back empty."

  # The embedded definition is tens of kilobytes; pass it as a file rather than
  # an argv entry.
  local body_file
  body_file="$(mktemp)"
  printf '%s' "$updated" >"$body_file"
  if ! retry "Updating ReportOnly on ${workflow_name}" \
    az rest --method PUT \
      --url "https://management.azure.com${workflow_id}?api-version=${WORKFLOW_API_VERSION}" \
      --headers 'Content-Type=application/json' \
      --body "@${body_file}" >/dev/null; then
    rm -f "$body_file"
    die "Could not update ReportOnly on ${workflow_name}."
  fi
  rm -f "$body_file"
  info "${workflow_name}: ReportOnly = ${value}"
}

if [[ -n $report_only && $skip_infra == true ]]; then
  log "Updating ReportOnly to ${report_only} (parameter only)"
  set_report_only "$mark_name" "$report_only"
  set_report_only "$delete_name" "$report_only"
fi

log 'Done'
cat <<EOF
    Mark workflow:   ${mark_name}   (identity ${mark_principal_id})
    Delete workflow: ${delete_name} (identity ${delete_principal_id})

    Next: keep ReportOnly = true, trigger one run of each workflow manually and
    read the report before going live. See docs/deployment.md.
EOF
