# 🚀 Entra ID Guest User Lifecycle Management (Azure Logic Apps)

Automate the lifecycle of Entra ID guest users — without expensive licenses. This solution uses two Azure Logic Apps to:
- 💤 Detect and disable inactive guest users, tagging them as eligible for removal
- 🧹 Delete tagged guest users after a configurable grace period

Includes report-only mode, dynamic group examples, and template-driven deployment for fast, consistent rollout.

---

## ✨ Highlights

- 💸 No premium identity governance license required
- 🧪 Report-only (dry-run) support
- 👥 Works with dynamic security groups
- 🆔 Uses Managed Identity + Microsoft Graph API
- 📊 Clear, auditable JSON reports per run
- ⚙️ Tunable thresholds and batch size

---

## 📁 Repository Layout

```
workflows/                                 Workflow definitions — source of truth for behaviour
  mark-guests-eligible-for-removal.json
  delete-guests-after-grace-period.json
infra/
  main.bicep                               Both Logic Apps, definitions embedded from workflows/
  modules/logic-app-workflow.bicep         One workflow + system-assigned managed identity
  main.parameters.json                     Sample parameter file
  deploy.sh / deploy.ps1                   Deploy + grant Graph app roles, idempotent
docs/deployment.md                         Deployment guide, first-run guidance, troubleshooting
scripts/learn-search.py                    Query official Microsoft Learn docs from the CLI
```

---

## 🧩 Architecture

This solution consists of two independent Logic Apps:

1) Logic-EntraIDGuestLCM-MarkGuestsEligibleforRemoval
- ⏱️ Schedule: Weekly (e.g., Sunday, 01:00)
- 🔎 Evaluates guests’ sign-in activity via Microsoft Graph
- ✅ Marks user if:
  - Never signed in, or
  - Last sign-in older than Threshold (days)
- 🏷️ Actions:
  - Set `extensionAttribute14 = "MarkedEligibleforRemoval"`
  - Set `extensionAttribute15 = <UTC timestamp>`
  - Disable account (`accountEnabled = false`) when `ReportOnly = false`
- 📤 Output: JSON report (evaluated, marked, disabled, details)

2) Logic-EntraIDGuestLCM-DeleteGuestUsersAfterGracePeriod
- ⏱️ Schedule: Weekly (e.g., Sunday, 03:00)
- 🧮 Evaluates previously marked users
- ✅ Deletes user when:
  - `extensionAttribute14 = "MarkedEligibleforRemoval"`
  - `extensionAttribute15` older than `DeletionThresholdDays`
  - `accountEnabled = false`
- 🗑️ Action: Delete user when `ReportOnly = false`
- 📤 Output: JSON report (evaluated, deleted, failed, details)

---

## ✅ Prerequisites

> ### ⚠️ Reading `signInActivity` has two hard requirements
>
> The Mark Logic App decides who is inactive from the `signInActivity` property on
> the user object. Reading it requires **both** of the following — miss either one
> and Microsoft Graph simply omits the property, so no guest is ever identified as
> inactive:
>
> 1. The **`AuditLog.Read.All` application permission**, granted to each Logic App’s
>    managed identity.
> 2. A **Microsoft Entra ID P1 or P2 license** in the tenant.
>
> Sources: [List users — sign-in activity example](https://learn.microsoft.com/graph/api/user-list?view=graph-rest-1.0#examples) ·
> [How to detect and investigate inactive user accounts](https://learn.microsoft.com/entra/identity/monitoring-health/howto-manage-inactive-user-accounts)

- ☁️ Azure subscription with permissions to deploy Logic Apps (Contributor)
- 🧭 Entra ID tenant with guest users, licensed **Microsoft Entra ID P1 or P2**
- 🧱 Two free extension attributes (e.g., `extensionAttribute14`, `extensionAttribute15`)
- 🔐 Microsoft Graph API app roles granted to **each** Logic App’s System-assigned Managed Identity
  - `AuditLog.Read.All` — **required**, gates `signInActivity`
  - `User.ReadWrite.All` — **required**, to disable and delete guests
  - `GroupMember.Read.All` — required to enumerate the source groups
- 🛡️ **Privileged Role Administrator** or **Global Administrator** to grant those app roles
- 🆔 Ability to enable System-assigned Managed Identity
- 🧰 Azure CLI, plus `jq` if you use the Bash deploy script

📘 Full walkthrough, including the mandatory first run in report-only mode:
**[docs/deployment.md](docs/deployment.md)**

Note on extension attributes:
- `extensionAttribute14` → lifecycle flag (“MarkedEligibleforRemoval”)
- `extensionAttribute15` → dual purpose:
  - Exclusion flag for “All Guests” group when set to `"ExcludeFromLCM"`
  - Timestamp when a user is marked for removal
- ℹ️ This is by design: newly marked users are disabled and thus fall out of the “All Guests” dynamic group (which requires `accountEnabled = true`). Ensure `extensionAttribute15` isn’t used for other purposes in your tenant.

---

## 👥 Dynamic Group Setup

Create two dynamic security groups in Entra ID to scope and monitor the lifecycle:

1) All Guests
- 🏷️ Name: `GRP_SEC_GuestUserLCM_AllGuests`
- 🧠 Rule (dynamic membership):
```kusto
(user.userType -eq "Guest") and (user.extensionAttribute15 -ne "ExcludeFromLCM") and (user.accountEnabled -eq true)
```

2) Eligible For Removal
- 🏷️ Name: `GRP_SEC_GuestUserLCM_EligibleForRemoval`
- 🧠 Rule (dynamic membership):
```kusto
(user.extensionAttribute14 -eq "MarkedEligibleforRemoval") and (user.accountEnabled -eq false)
```

💡 Tip: Permanently exclude VIPs or critical guests by setting `extensionAttribute15 = "ExcludeFromLCM"`.

---

## ⚙️ Logic App 1 — Mark Guests Eligible for Removal

Find inactive guest users and mark them for removal.

- ⏱️ Suggested schedule: Weekly, Sunday 01:00
- 🔎 Evaluation:
  - Check all members of `GRP_SEC_GuestUserLCM_AllGuests`
  - Fetch sign-in activity via Microsoft Graph
  - Mark user if:
    - Never signed in, or
    - Last sign-in older than `Threshold` (days)
- 🏷️ Actions:
  - `extensionAttribute14 = "MarkedEligibleforRemoval"`
  - `extensionAttribute15 = <current UTC datetime>`
  - Disable account when `ReportOnly = false`
- 📤 Output:
  - JSON report with:
    - `totalEvaluated`
    - `totalMarked`
    - `totalDisabled`
    - `details[]` (UPN, objectId, reason)

Parameters
- `guestSourceGroupId`: Object ID of `GRP_SEC_GuestUserLCM_AllGuests`
- `InactivityThresholdDays`: Days since last sign-in (default: `180`)
- `ReportOnly`: `true` (only report) or `false` (disable + mark)
- `BatchSize`: Users per run (default: `20`)

Deployment — both Logic Apps are deployed together from `infra/`:
```bash
./infra/deploy.sh --resource-group rg-entraid-guest-lcm \
  --all-guests-group-id <guid> --eligible-group-id <guid>
```
This creates the resource group, deploys `infra/main.bicep` (both workflows with
system-assigned managed identities), and grants the Graph app roles to both.
`ReportOnly` defaults to `true`. See **[docs/deployment.md](docs/deployment.md)**
for the PowerShell equivalent, partial runs, and how to go live.

🧪 Test & Verify
- ▶️ Manually run the Logic App once
- 👀 Check:
  - `GRP_SEC_GuestUserLCM_AllGuests` contains active guests to evaluate
  - `GRP_SEC_GuestUserLCM_EligibleForRemoval` starts filling with disabled, marked users
  - Run output includes the report array (e.g., `ReportArray`)

---

## 🧹 Logic App 2 — Delete Guests After Grace Period

Delete previously marked guest users after a grace period.

- ⏱️ Suggested schedule: Weekly, Sunday 03:00
- 🔎 Evaluation:
  - Check all members of `GRP_SEC_GuestUserLCM_EligibleForRemoval`
  - Read user attributes via Microsoft Graph
  - Delete user if:
    - `extensionAttribute14 = "MarkedEligibleforRemoval"`
    - `extensionAttribute15` older than `DeletionThresholdDays`
    - `accountEnabled = false`
- 🗑️ Action:
  - Delete user when `ReportOnly = false`
- 📤 Output:
  - JSON report with:
    - `totalEvaluated`
    - `totalDeleted`
    - `totalFailed`
    - `details[]` (UPN, objectId, reason)

Parameters
- `guestSourceGroupId`: Object ID of `GRP_SEC_GuestUserLCM_EligibleForRemoval`
- `DeletionThresholdDays`: Days since marking before deletion (default: `30`)
- `ReportOnly`: `true` (only report) or `false` (delete users)
- `BatchSize`: Users per run (default: `20`)

Deployment — deployed by the same `infra/deploy.sh` run as Logic App 1; no
separate steps. See **[docs/deployment.md](docs/deployment.md)**.

🧪 Test & Verify
- ▶️ Manually run the Logic App once
- 👀 Check:
  - `GRP_SEC_GuestUserLCM_EligibleForRemoval` shrinks as users are deleted
  - Entra ID → Users → Deleted users shows newly deleted accounts
  - Run output includes `DeletedUsersReport`

---

## 📊 Reports

Each Logic App emits a JSON array in its run output for easy auditing.

Example (Mark app):
```json
{
  "totalEvaluated": 120,
  "totalMarked": 18,
  "totalDisabled": 18,
  "details": [
    {
      "userPrincipalName": "guest1@contoso.com",
      "objectId": "11111111-1111-1111-1111-111111111111",
      "reason": "No sign-in activity in the last 180 days",
      "action": "MarkedEligibleforRemoval + Disabled"
    }
  ]
}
```

Example (Delete app):
```json
{
  "totalEvaluated": 42,
  "totalDeleted": 12,
  "totalFailed": 0,
  "details": [
    {
      "userPrincipalName": "guest1@contoso.com",
      "objectId": "11111111-1111-1111-1111-111111111111",
      "markedOn": "2025-01-01T00:00:00Z",
      "action": "Deleted"
    }
  ]
}
```

---

## ⏱️ Scheduling Guidance

- ⛓️ Stagger runs to allow propagation:
  - Mark app: Sunday 01:00
  - Delete app: Sunday 03:00
- 🕒 Adjust to your maintenance windows and dynamic group evaluation delays.

---

## 🛡️ Safety Tips

- 🧪 Start with `ReportOnly = true` for both Logic Apps to validate logic and outputs.
- 🙅 Exclude VIP/service-linked guests by setting `extensionAttribute15 = "ExcludeFromLCM"`.
- 📉 Watch for Graph API throttling; tune `BatchSize` as needed.
- 📝 Consider exporting reports to Storage/Log Analytics for auditing.

---

## 🧰 Troubleshooting

- ❓ No users are marked:
  - Verify dynamic group membership and `accountEnabled = true`
  - Ensure Graph permissions are granted and admin-consented for the Managed Identity
  - Confirm sign-in activity data exists and `Threshold` is reasonable
- 🗂️ Users not deleted:
  - Check `extensionAttribute14/15` values on the user
  - Validate `DeletionThresholdDays` logic (compare with `extensionAttribute15` timestamp)
  - Ensure `accountEnabled = false`
- 🔑 Permission errors:
  - Re-assign the Graph app roles: `./infra/deploy.sh --resource-group <rg> --skip-infra`
  - Verify Graph App Role assignments are “Granted” on **both** managed identities
  - Confirm the tenant has a Microsoft Entra ID P1/P2 license — without it `signInActivity` is never returned

📘 Full troubleshooting table: **[docs/deployment.md](docs/deployment.md#troubleshooting)**

---

## 🔒 Security & Compliance

- 🗑️ Deleting users is irreversible after the Deleted Users retention period — validate with `ReportOnly` first.
- 📜 Review your organization’s data retention and guest user policies before enabling deletion.
- 🔏 Restrict who can modify the Logic Apps and their Managed Identities.

---

## 🤝 Contributing

Issues and PRs are welcome. Please describe your environment, steps to reproduce, and include relevant run outputs when filing an issue.

---

## ⚠️ Disclaimer

Use at your own risk. Test thoroughly in a non-production tenant before rolling out to production.
