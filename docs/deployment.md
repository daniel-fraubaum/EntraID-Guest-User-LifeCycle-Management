# Deployment Guide

Reproducible deployment of the two Consumption Logic Apps that make up the Entra
ID guest lifecycle: **Mark** (find inactive guests, tag + disable them) and
**Delete** (remove tagged guests after a grace period).

```
workflows/                                  Workflow definitions — source of truth for behaviour
  mark-guests-eligible-for-removal.json
  delete-guests-after-grace-period.json
infra/
  main.bicep                                Both Logic Apps, definitions embedded from workflows/
  modules/logic-app-workflow.bicep          One workflow + system-assigned managed identity
  main.parameters.json                      Sample parameter file
  deploy.sh                                 Linux / macOS / Azure Cloud Shell
  deploy.ps1                                Windows PowerShell / pwsh
```

The Bicep template creates the workflows and their managed identities. It cannot
grant Microsoft Graph app roles — those are directory objects, not ARM
resources — so the deploy scripts do that as a second step.

---

## Prerequisites

### Licensing — required, not optional

> **Reading `signInActivity` requires a Microsoft Entra ID P1 or P2 license in
> the tenant.** The Mark workflow decides who is inactive from
> `signInActivity.lastSuccessfulSignInDateTime` / `lastSignInDateTime`. Without
> a premium license, Microsoft Graph does not return the property and the
> workflow cannot identify inactive guests.
>
> Source: [How to detect and investigate inactive user accounts](https://learn.microsoft.com/entra/identity/monitoring-health/howto-manage-inactive-user-accounts)

### Microsoft Graph application permissions

Both managed identities need these **application** permissions (app roles) on
Microsoft Graph. `deploy.sh` / `deploy.ps1` assign all three to both identities.

| App role | Why it is needed | Required |
| --- | --- | --- |
| `AuditLog.Read.All` | Gates the `signInActivity` property. Without it, Graph omits it. | Yes — the solution cannot work without it |
| `User.ReadWrite.All` | Patch `accountEnabled` + extension attributes (Mark), `DELETE /users/{id}` (Delete) | Yes |
| `GroupMember.Read.All` | Enumerate `/groups/{id}/members` to get the users to evaluate | Yes for group-scoped operation, which is how both workflows are written |

Override the set with `--roles` / `-Roles` if your tenant grants equivalents a
different way.

### Tooling and rights

- **Azure CLI**, logged in (`az login`) against the target subscription.
- **jq** — used by `deploy.sh` (preinstalled in Azure Cloud Shell). Not needed by `deploy.ps1`.
- **Bicep** — bundled with recent Azure CLI; `az bicep install` if missing.
- Azure RBAC: **Contributor** on the target subscription or resource group.
- Entra ID: **Privileged Role Administrator** or **Global Administrator** — granting
  Graph app roles to a managed identity requires it. A Contributor alone will get
  through the Bicep deployment and then fail on role assignment.

### Directory objects

Two dynamic security groups (see the README for the membership rules) and their
object IDs:

| Group | Feeds | Membership rule summary |
| --- | --- | --- |
| `GRP_SEC_GuestUserLCM_AllGuests` | Mark workflow | Guests, enabled, not excluded via `extensionAttribute15` |
| `GRP_SEC_GuestUserLCM_EligibleForRemoval` | Delete workflow | `extensionAttribute14 = MarkedEligibleforRemoval` and disabled |

`extensionAttribute14` and `extensionAttribute15` must be free for this
solution's use in your tenant.

---

## Quickstart

Both scripts are idempotent — re-run them freely. Both default to
`ReportOnly = true`, so a first deployment cannot disable or delete anything.

### Linux, macOS, Azure Cloud Shell

```bash
git clone https://github.com/daniel-fraubaum/EntraID-Guest-User-LifeCycle-Management.git
cd EntraID-Guest-User-LifeCycle-Management

az login
az account set --subscription "<subscription-id>"

./infra/deploy.sh \
  --resource-group rg-entraid-guest-lcm \
  --location westeurope \
  --all-guests-group-id "<objectId of GRP_SEC_GuestUserLCM_AllGuests>" \
  --eligible-group-id  "<objectId of GRP_SEC_GuestUserLCM_EligibleForRemoval>"
```

### Windows PowerShell / pwsh

```powershell
git clone https://github.com/daniel-fraubaum/EntraID-Guest-User-LifeCycle-Management.git
cd EntraID-Guest-User-LifeCycle-Management

az login
az account set --subscription "<subscription-id>"

./infra/deploy.ps1 `
  -ResourceGroup rg-entraid-guest-lcm `
  -Location westeurope `
  -AllGuestsGroupId "<objectId of GRP_SEC_GuestUserLCM_AllGuests>" `
  -EligibleGroupId  "<objectId of GRP_SEC_GuestUserLCM_EligibleForRemoval>"
```

Either script prints both workflow names and both managed identity object IDs
when it finishes.

### What the scripts do

1. Create the resource group if it does not exist.
2. Deploy `infra/main.bicep` — both workflows, each with a system-assigned managed identity.
3. Read both managed identity object IDs from the deployment outputs.
4. Wait for those identities to appear in the directory, then assign the Graph app roles to **both**, skipping any already present.

Directory writes replicate asynchronously, so every lookup and the role
assignment itself retries **up to 5 times with 15 seconds between attempts**. No
call is ever made with an empty id: if a lookup returns nothing, it is retried
and then aborts with an explicit error rather than sending a malformed request.

### Partial runs

| Goal | Command |
| --- | --- |
| Everything (default) | `./infra/deploy.sh --resource-group RG --all-guests-group-id … --eligible-group-id …` |
| Infrastructure only, grant roles later | `./infra/deploy.sh --resource-group RG … --skip-permissions` |
| Re-assign Graph roles only | `./infra/deploy.sh --resource-group RG --skip-infra` |
| Flip the dry-run switch only | `./infra/deploy.sh --resource-group RG --skip-infra --report-only false` |

With `--skip-infra`, the scripts discover the existing workflows in the resource
group instead of reading deployment outputs, so no group IDs are needed.

`--report-only` combined with `--skip-infra` updates **only** the `ReportOnly`
parameter on both workflows: the script reads each workflow, replaces that one
parameter value, and writes it back with the definition round-tripped unchanged
and the managed identity preserved. Without `--skip-infra`, `--report-only` is
passed to the Bicep deployment instead.

---

## First run: keep ReportOnly = true

**Do not skip this.** Deleting a guest is irreversible once the Entra ID deleted-users
retention window passes. Both workflows ship with `ReportOnly = true`, which
makes them evaluate every guest and report what they *would* do without touching
a single account.

Run each workflow at least once in report-only mode, read the report, confirm the
population and the thresholds look right, and only then go live.

### 1. Trigger a run manually

Both workflows have a single trigger named `Recurrence` and would otherwise only
fire on their weekly schedule. Trigger one now:

```bash
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
RESOURCE_GROUP=rg-entraid-guest-lcm
WORKFLOW=Logic-EntraIDGuestLCM-MarkGuestsEligibleforRemoval

az rest --method POST --url \
  "https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Logic/workflows/${WORKFLOW}/triggers/Recurrence/run?api-version=2016-06-01"
```

> The `logic` Azure CLI extension covers workflow CRUD (`az logic workflow
> create|show|list|update|delete`) but exposes no verb for firing a trigger, so
> the `az rest` call above is the Azure CLI path. In PowerShell you can instead
> use `Start-AzLogicApp -ResourceGroupName <rg> -Name <workflow> -TriggerName Recurrence`
> from the `Az.LogicApp` module, or the Portal's **Run trigger** button.

### 2. Read the report

Each run ends with a Compose action holding the full JSON report:

| Workflow | Report action |
| --- | --- |
| Mark | `Generate_JSON_Report` |
| Delete | `Generate_Final_Report` |

**Portal:** Logic App → **Run history** → newest run → the report action → **Outputs**.

**CLI** — newest run's status, then that action's output:

```bash
BASE="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Logic/workflows/${WORKFLOW}"

RUN=$(az rest --method GET --url "${BASE}/runs?api-version=2016-06-01&\$top=1" \
        --query 'value[0].name' -o tsv)

az rest --method GET \
  --url "${BASE}/runs/${RUN}/actions/Generate_JSON_Report?api-version=2016-06-01" \
  --query 'properties.outputsLink.uri' -o tsv | xargs curl -s | jq .
```

What to check in the report before going live:

- `reportMetadata.mode` is `Report Only` — proof nothing was changed.
- `reportMetadata.totalMembersFound` is non-zero. Zero means the dynamic group is empty or unreadable, not that every guest is active.
- `summary.totalAffectedUsers` is plausible for your tenant. A surprisingly high number usually means the threshold is too aggressive or `signInActivity` is missing (see troubleshooting).
- `affectedUsers[]` — spot-check a few UPNs by hand against the Entra ID sign-in logs.

### 3. Go live

Once the report looks right:

```bash
./infra/deploy.sh --resource-group rg-entraid-guest-lcm --skip-infra --report-only false
```

Stagger the two workflows: Mark runs Sunday 01:00, Delete Sunday 03:00. The gap
lets the disable + tag propagate into the `EligibleForRemoval` dynamic group
before the Delete workflow enumerates it. Going live on Mark first and leaving
Delete in report-only for a full cycle is the cautious path.

---

## Parameter reference

Set on `infra/main.bicep`; each is passed through to the corresponding workflow parameter.

| Bicep parameter | Workflow parameter | Default | Applies to | Meaning |
| --- | --- | --- | --- | --- |
| `allGuestsGroupId` | `guestSourceGroupId` | — | Mark | Object ID of the All Guests group |
| `eligibleForRemovalGroupId` | `guestSourceGroupId` | — | Delete | Object ID of the Eligible For Removal group |
| `inactivityThresholdDays` | `InactivityThresholdDays` | `180` | Mark | Days since last sign-in before a guest is marked |
| `deletionThresholdDays` | `DeletionThresholdDays` | `30` | Delete | Days after marking before deletion |
| `newAccountGraceDays` | `NewAccountGraceDays` | `30` | Mark | Grace period for never-signed-in new accounts. **Declared and deployed but not yet consumed** — see note below |
| `reportOnly` | `ReportOnly` | `true` | Both | Dry run. Nothing is disabled or deleted while true |
| `excludeFlagValue` | `ExcludeFlagValue` | `ExcludeFromLCM` | Both | Value of `extensionAttribute15` that permanently excludes a guest |
| `batchSize` | `BatchSize` | `20` | Both | Users per Graph `$batch` request (1–100) |
| `workflowState` | — | `Enabled` | Both | `Disabled` deploys the workflows without arming the schedule |

Two parameters are deployed but not yet read by any workflow expression, because
wiring them requires a workflow logic change that is deliberately out of scope
for this restructure:

- **`NewAccountGraceDays`** — the never-signed-in branch currently compares
  `createdDateTime` against `InactivityThresholdDays`. A guest created 200 days
  ago that never signed in is marked at the 180-day threshold; there is no
  separate new-account grace period yet.
- **`ExcludeFlagValue`** — exclusion is enforced by the `All Guests` **dynamic
  group membership rule**, not by the workflow. Changing this value means editing
  that rule too. It is surfaced on the workflow so the deployed value is
  discoverable and auditable alongside everything else.

---

## Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Run fails `403 Forbidden` on the first Graph call | App roles not assigned, or assigned after the run started | `./infra/deploy.sh --resource-group RG --skip-infra`, then re-trigger |
| `Failed to assign <role>` at the end of deployment | Your account lacks Privileged Role Administrator / Global Administrator | Have an eligible admin re-run with `--skip-infra` |
| `Managed identity … is not visible in the directory yet` | Identity has not replicated within 5 × 15 s | Wait a few minutes, re-run with `--skip-infra` |
| Report shows every guest as never-signed-in | `signInActivity` is absent — missing P1/P2 license or `AuditLog.Read.All` | Verify tenant licensing, then confirm the role assignment on **both** identities |
| `totalMembersFound: 0` | Group ID wrong, group empty, or `GroupMember.Read.All` missing | Check the object ID; confirm membership in the Portal; re-run role assignment |
| Users marked but never deleted | Delete workflow still in report-only, grace period not elapsed, or the user is not in the Eligible group | Check `ReportOnly`, `extensionAttribute15` age vs `deletionThresholdDays`, and that `accountEnabled = false` |
| Run fails with a rate-limit message | Graph throttling on `$batch` | Lower `batchSize` and redeploy |
| Deployment fails: `expected value of type … 36` | A group ID is empty or not a GUID | Pass real object IDs — `main.bicep` rejects malformed ones rather than deploying a broken workflow |
| `deploy.sh: jq not found` | jq missing | Install jq, or use `deploy.ps1`, or run in Azure Cloud Shell |
| Delete run reports failures with status 404 | User already deleted, e.g. by a concurrent run | Harmless; the report lists them under `failedDeletes` |

---

## Sources

- [List users — sign-in activity example, permissions and paging limits](https://learn.microsoft.com/graph/api/user-list?view=graph-rest-1.0#examples)
- [How to detect and investigate inactive user accounts — P1/P2 requirement](https://learn.microsoft.com/entra/identity/monitoring-health/howto-manage-inactive-user-accounts)
- [Access Microsoft Graph from a secured app as the app — granting app roles to a managed identity](https://learn.microsoft.com/entra/identity-platform/multi-service-web-app-access-microsoft-graph-as-app#grant-access-to-microsoft-graph)
- [Microsoft.Logic/workflows/triggers](https://learn.microsoft.com/azure/templates/microsoft.logic/workflows/triggers)
