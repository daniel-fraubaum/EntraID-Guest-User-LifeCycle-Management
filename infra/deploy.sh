#!/usr/bin/env bash
#
# Deploy the Entra ID guest lifecycle solution: resource group, both Consumption
# Logic Apps (via main.bicep), and the Microsoft Graph app roles their managed
# identities need.
#
# Everything here is idempotent - re-running converges rather than duplicating.
# Directory writes (managed identity service principals, app role assignments)
# replicate asynchronously, so every directory lookup and the role assignment
# itself are retried RETRY_ATTEMPTS times with RETRY_WAIT_SECONDS between tries.
#
# First installation order matters. A Recurrence trigger fires once as soon as
# a workflow is created or enabled. If that first run happens before the Graph
# app roles exist, the managed identity token it obtains carries no roles, and
# managed identity tokens are cached for up to ~24 hours - the workflows then
# fail with 403 long after the roles were granted. So on a fresh install the
# workflows are deployed Disabled, the roles are assigned, and only then are the
# workflows enabled.
#
# Requires: az CLI (logged in, correct subscription), jq.
#
set -euo pipefail

readonly GRAPH_APP_ID='00000003-0000-0000-c000-000000000000'
readonly WORKFLOW_API_VERSION='2019-05-01'
readonly RETRY_ATTEMPTS=5
readonly RETRY_WAIT_SECONDS=15
# Wait between granting app roles and enabling a workflow, so the first token
# the workflow requests already carries the roles.
readonly ENABLE_DELAY_SECONDS=120

# Graph app roles, per managed identity.
#
# Mark reads signInActivity (AuditLog.Read.All), enumerates the source group
# (GroupMember.Read.All), and writes extensionAttribute14/15 plus
# accountEnabled (User.ReadWrite.All). Writing onPremisesExtensionAttributes is
# rejected with 403 under User.ReadUpdate.All (verified live), and the only
# other option, Directory.ReadWrite.All, is broader. User.ReadWrite.All also
# allows DELETE /users, so "Mark never deletes" rests on the workflow
# definition: restrict who can edit the Logic App.
#
# Delete enumerates the source group (GroupMember.Read.All) and deletes users,
# for which User.ReadWrite.All is the only application permission. It never
# reads signInActivity, so it does not get AuditLog.Read.All.
DEFAULT_MARK_ROLES='AuditLog.Read.All GroupMember.Read.All User.ReadWrite.All'
DEFAULT_DELETE_ROLES='GroupMember.Read.All User.ReadWrite.All'

resource_group=''
location='westeurope'
subscription=''
all_guests_group_id=''
eligible_group_id=''
parameters_file=''
report_only=''
report_only_target='both'
mark_roles="${DEFAULT_MARK_ROLES}"
delete_roles="${DEFAULT_DELETE_ROLES}"
skip_infra=false
skip_permissions=false
prune_roles=false
enable_after=false
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
                               the ReportOnly parameter on the existing workflows
                               and leaves the definitions untouched.
  --workflow mark|delete|both  Which workflow --skip-infra --report-only updates
                               (default: both). Use it to go live one app at a time.
  --mark-roles "A B C"         Graph app roles for the Mark identity (default:
                               AuditLog.Read.All GroupMember.Read.All User.ReadWrite.All).
  --delete-roles "A B"         Graph app roles for the Delete identity (default:
                               GroupMember.Read.All User.ReadWrite.All).
  --roles "A B C"              Same role list for both identities (overrides the two above).
  --prune-roles                Remove Graph app roles an identity holds beyond its
                               list (e.g. AuditLog.Read.All on Delete after a v2.0 install).
  --enable                     Enable both workflows after the role assignment.
                               Done automatically on a fresh install.
  --skip-infra                 Do not create the RG or deploy Bicep.
  --skip-permissions           Deploy infrastructure only; assign no Graph roles.
  -h, --help                   Show this help.

Examples:
  # First deployment, safe by default (ReportOnly=true)
  ./deploy.sh --resource-group rg-guest-lcm \
              --all-guests-group-id <guid> --eligible-group-id <guid>

  # Re-assign Graph roles only (e.g. after a role was revoked)
  ./deploy.sh --resource-group rg-guest-lcm --skip-infra

  # Go live with the Mark app only, Delete stays in report-only mode
  ./deploy.sh --resource-group rg-guest-lcm --skip-infra --report-only false --workflow mark
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
    --workflow)            report_only_target="${2:-}"; shift 2 ;;
    --mark-roles)          mark_roles="${2:-}"; shift 2 ;;
    --delete-roles)        delete_roles="${2:-}"; shift 2 ;;
    --roles)               mark_roles="${2:-}"; delete_roles="${2:-}"; shift 2 ;;
    --prune-roles)         prune_roles=true; shift ;;
    --enable)              enable_after=true; shift ;;
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
case "$report_only_target" in
  mark|delete|both) ;;
  *) die "--workflow must be mark, delete or both (got: '${report_only_target}')." ;;
esac
if [[ $report_only_target != 'both' && ( $skip_infra != true || -z $report_only ) ]]; then
  die '--workflow mark|delete only applies together with --skip-infra --report-only. A full deployment always sets ReportOnly on both workflows.'
fi
command -v az >/dev/null || die 'az CLI not found. See https://learn.microsoft.com/cli/azure/install-azure-cli'
command -v jq >/dev/null || die 'jq not found. Install jq (it is preinstalled in Azure Cloud Shell).'

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
stderr_file="$(mktemp)"
trap 'rm -f "$stderr_file"' EXIT

# --- retry helpers -----------------------------------------------------------

# Last non-empty stderr line of the previous attempt, for the warning.
last_error() {
  local line
  line="$(grep -v '^[[:space:]]*$' "$stderr_file" 2>/dev/null | tail -n 1 || true)"
  [[ -n $line ]] && printf ': %s' "${line:0:300}"
}

# retry <description> <command...> - echoes stdout of the first successful run.
retry() {
  local description="$1"; shift
  local attempt=1 output=''
  while (( attempt <= RETRY_ATTEMPTS )); do
    if output="$("$@" 2>"$stderr_file")"; then
      printf '%s' "${output//$'\r'/}"
      return 0
    fi
    warn "${description} failed (attempt ${attempt}/${RETRY_ATTEMPTS})$(last_error)."
    (( attempt == RETRY_ATTEMPTS )) && break
    sleep "$RETRY_WAIT_SECONDS"
    (( attempt++ ))
  done
  return 1
}

# retry_nonempty <description> <command...> - as retry, but an empty result also
# counts as failure. This is what makes directory propagation tolerable: a
# lookup that succeeds with an empty body is retried instead of being passed on
# as an empty id.
retry_nonempty() {
  local description="$1"; shift
  local attempt=1 output=''
  while (( attempt <= RETRY_ATTEMPTS )); do
    output="$("$@" 2>"$stderr_file" || true)"
    output="${output//$'\r'/}"
    if [[ -n ${output// /} && $output != 'null' ]]; then
      printf '%s' "$output"
      return 0
    fi
    warn "${description} returned nothing yet (attempt ${attempt}/${RETRY_ATTEMPTS})$(last_error)."
    (( attempt == RETRY_ATTEMPTS )) && break
    sleep "$RETRY_WAIT_SECONDS"
    (( attempt++ ))
  done
  return 1
}

require_id() {
  local label="$1" value="$2"
  [[ -n ${value// /} && $value != 'null' ]] || die "${label} is empty - refusing to call the API with an empty id."
}

# --- subscription ------------------------------------------------------------

if [[ -n $subscription ]]; then
  log "Selecting subscription ${subscription}"
  az account set --subscription "$subscription"
fi
account_name="$(az account show --query name -o tsv)" \
  || die 'Not logged in. Run: az login'
info "Subscription: ${account_name//$'\r'/}"

# --- infrastructure ----------------------------------------------------------

fresh_install=false
desired_state='Enabled'

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

  # No workflow in the resource group yet means a fresh install: deploy the
  # workflows Disabled so their first run cannot happen before the roles exist.
  existing_count="$(az resource list --resource-group "$resource_group" \
    --resource-type 'Microsoft.Logic/workflows' --query 'length(@)' -o tsv 2>/dev/null || echo 0)"
  existing_count="${existing_count//$'\r'/}"
  if [[ ${existing_count:-0} == 0 ]]; then
    fresh_install=true
    if [[ -n $parameters_file ]]; then
      file_state="$(jq -r '.parameters.workflowState.value // empty' "$parameters_file")"
      [[ -n $file_state ]] && desired_state="$file_state"
    fi
    info "Fresh install: deploying the workflows Disabled; they are enabled after the Graph app roles are assigned."
  fi

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
  [[ $fresh_install == true ]]  && deploy_args+=(--parameters "workflowState=Disabled")

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
# the resource group by the naming convention: name contains Mark / Delete.
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

roles_changed=false
graph_sp_id=''
graph_app_roles=''

# assign_roles_to <label> <principalId> "<role> <role> ..."
assign_roles_to() {
  local label="$1" principal="$2" roles="$3"
  local role app_role_id existing body wanted_ids='' assignment_id assigned_role_id assigned_name

  require_id "${label} managed identity principalId" "$principal"
  log "Graph app roles: ${label} (${principal})"

  existing="$(retry "Reading existing app role assignments of ${principal}" \
    az rest --method GET \
      --url "https://graph.microsoft.com/v1.0/servicePrincipals/${principal}/appRoleAssignments" \
      --query "value[?resourceId=='${graph_sp_id}'].{id:id,appRoleId:appRoleId}" -o json)" \
    || die "Could not read existing app role assignments for ${principal}."

  for role in $roles; do
    app_role_id="$(jq -r --arg v "$role" '[.[] | select(.value == $v) | .id] | first // empty' <<<"$graph_app_roles")"
    [[ -n $app_role_id ]] || die "Could not resolve the app role id for ${role}. Check the spelling."
    require_id "App role id for ${role}" "$app_role_id"
    wanted_ids="${wanted_ids} ${app_role_id}"

    if jq -e --arg r "$app_role_id" 'any(.[]; .appRoleId == $r)' <<<"$existing" >/dev/null; then
      info "${role}: already assigned - skipping."
      continue
    fi

    body="$(jq -nc --arg principalId "$principal" \
                   --arg resourceId "$graph_sp_id" \
                   --arg appRoleId "$app_role_id" \
                   '{principalId: $principalId, resourceId: $resourceId, appRoleId: $appRoleId}')"

    if retry "Assigning ${role} to ${principal}" \
      az rest --method POST \
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/${principal}/appRoleAssignments" \
        --headers 'Content-Type=application/json' \
        --body "$body" >/dev/null; then
      info "${role}: assigned."
      roles_changed=true
    else
      # A concurrent run may have created it between our check and our POST.
      existing="$(az rest --method GET \
        --url "https://graph.microsoft.com/v1.0/servicePrincipals/${principal}/appRoleAssignments" \
        --query "value[?resourceId=='${graph_sp_id}'].{id:id,appRoleId:appRoleId}" -o json 2>/dev/null || echo '[]')"
      jq -e --arg r "$app_role_id" 'any(.[]; .appRoleId == $r)' <<<"$existing" >/dev/null \
        || die "Failed to assign ${role} to ${principal}. See the error above; a 403 means you need Privileged Role Administrator or Global Administrator."
      info "${role}: already present (created concurrently)."
    fi
  done

  # Roles held beyond the list, e.g. AuditLog.Read.All on Delete from v2.0.
  while IFS=$'\t' read -r assignment_id assigned_role_id; do
    [[ -n $assignment_id ]] || continue
    [[ " ${wanted_ids} " == *" ${assigned_role_id} "* ]] && continue
    assigned_name="$(jq -r --arg i "$assigned_role_id" '[.[] | select(.id == $i) | .value] | first // $i' <<<"$graph_app_roles")"
    if [[ $prune_roles == true ]]; then
      retry "Removing ${assigned_name} from ${principal}" \
        az rest --method DELETE \
          --url "https://graph.microsoft.com/v1.0/servicePrincipals/${principal}/appRoleAssignments/${assignment_id}" \
          </dev/null >/dev/null \
        || die "Failed to remove ${assigned_name} from ${principal}."
      info "${assigned_name}: removed (--prune-roles). Cached tokens can keep it usable for up to ~24 hours."
    else
      warn "${label} identity also holds ${assigned_name}, which is not in its role list. Re-run with --prune-roles to remove it."
    fi
  # tr: jq on Windows ends lines with CRLF, and read would keep the \r.
  done < <(jq -r '.[] | [.id, .appRoleId] | @tsv' <<<"$existing" | tr -d '\r')
}

assign_graph_roles() {
  local principal

  graph_sp_id="$(retry_nonempty 'Looking up the Microsoft Graph service principal' \
    az ad sp show --id "$GRAPH_APP_ID" --query id -o tsv)" \
    || die 'Microsoft Graph service principal not found in this tenant.'
  require_id 'Microsoft Graph service principal objectId' "$graph_sp_id"
  info "Microsoft Graph SP: ${graph_sp_id}"

  graph_app_roles="$(retry_nonempty 'Reading the Microsoft Graph app roles' \
    az ad sp show --id "$GRAPH_APP_ID" \
      --query "appRoles[?contains(allowedMemberTypes,'Application')].{id:id,value:value}" -o json)" \
    || die 'Could not read the Microsoft Graph app roles.'

  # A brand-new workflow's identity may not be queryable as a service principal
  # for a few seconds after ARM returns. Wait for both before assigning.
  for principal in "$mark_principal_id" "$delete_principal_id"; do
    require_id 'Managed identity principalId' "$principal"
    retry_nonempty "Waiting for service principal ${principal} to replicate" \
      az ad sp show --id "$principal" --query id -o tsv >/dev/null \
      || die "Managed identity ${principal} is not visible in the directory yet. Re-run with --skip-infra in a few minutes."
  done

  assign_roles_to 'Mark' "$mark_principal_id" "$mark_roles"
  assign_roles_to 'Delete' "$delete_principal_id" "$delete_roles"
}

if [[ $skip_permissions == true ]]; then
  log 'Skipping Graph app roles (--skip-permissions)'
else
  assign_graph_roles
fi

# --- enable after a fresh install --------------------------------------------

workflow_resource_id() {
  local workflow_name="$1"
  retry_nonempty "Resolving resource id of ${workflow_name}" \
    az resource show --resource-group "$resource_group" --name "$workflow_name" \
      --resource-type 'Microsoft.Logic/workflows' --query id -o tsv
}

enable_workflows() {
  local workflow_name workflow_id state
  if [[ $roles_changed == true ]]; then
    info "Waiting ${ENABLE_DELAY_SECONDS}s so the first token already carries the new app roles."
    sleep "$ENABLE_DELAY_SECONDS"
  fi
  for workflow_name in "$mark_name" "$delete_name"; do
    workflow_id="$(workflow_resource_id "$workflow_name")" || die "Could not resolve ${workflow_name}."
    # -g/-n rather than --ids: Git Bash would rewrite a leading /subscriptions/... as a path.
    state="$(az resource show --resource-group "$resource_group" --name "$workflow_name" \
      --resource-type 'Microsoft.Logic/workflows' --query properties.state -o tsv 2>/dev/null || true)"
    if [[ ${state//$'\r'/} == 'Enabled' ]]; then
      info "${workflow_name}: already enabled."
      continue
    fi
    retry "Enabling ${workflow_name}" \
      az rest --method POST --url "https://management.azure.com${workflow_id}/enable?api-version=${WORKFLOW_API_VERSION}" >/dev/null \
      || die "Could not enable ${workflow_name}."
    # Enabling fires the Recurrence trigger once, right away.
    info "${workflow_name}: enabled (its Recurrence trigger runs once now)."
  done
}

want_enable=false
[[ $enable_after == true ]] && want_enable=true
[[ $fresh_install == true && $desired_state == 'Enabled' ]] && want_enable=true

if [[ $want_enable == true ]]; then
  if [[ $skip_permissions == true ]]; then
    warn 'Leaving the workflows Disabled: no Graph app roles were assigned in this run. Assign them, then run: ./deploy.sh --resource-group RG --skip-infra --enable'
  else
    log 'Enabling workflows'
    [[ $report_only == 'false' ]] \
      && warn 'ReportOnly is false: the run fired by enabling the workflows acts for real.'
    enable_workflows
  fi
fi

# --- ReportOnly-only update --------------------------------------------------

# Flipping the dry-run switch without redeploying: read the workflow, replace
# exactly one parameter value, PUT it back. The definition is round-tripped
# unchanged, and identity.type is resent so the managed identity is preserved.
# A PUT does not fire the Recurrence trigger.
set_report_only() {
  local workflow_name="$1" value="$2" workflow_id current updated

  workflow_id="$(workflow_resource_id "$workflow_name")" || die "Could not resolve ${workflow_name}."
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
  log "Updating ReportOnly to ${report_only} (parameter only, workflow: ${report_only_target})"
  [[ $report_only_target == 'mark' || $report_only_target == 'both' ]] && set_report_only "$mark_name" "$report_only"
  [[ $report_only_target == 'delete' || $report_only_target == 'both' ]] && set_report_only "$delete_name" "$report_only"
fi

log 'Done'
cat <<EOF
    Mark workflow:   ${mark_name}   (identity ${mark_principal_id})
    Delete workflow: ${delete_name} (identity ${delete_principal_id})

    Next: keep ReportOnly = true, trigger one run of each workflow manually and
    read the report before going live. See docs/deployment.md.
EOF
