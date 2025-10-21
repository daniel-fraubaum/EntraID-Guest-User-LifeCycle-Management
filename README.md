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

- ☁️ Azure subscription with permissions to deploy Logic Apps
- 🧭 Entra ID tenant with guest users
- 🧱 Two free extension attributes (e.g., `extensionAttribute14`, `extensionAttribute15`)
- 🔐 Microsoft Graph API app roles granted to each Logic App’s System-assigned Managed Identity
  - Read sign-in logs (e.g., `AuditLog.Read.All`)
  - Read/Write users (e.g., `User.ReadWrite.All`)
  - Read groups if you scope by group (e.g., `Group.Read.All`)
- 🆔 Ability to enable System-assigned Managed Identity

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
- `Threshold`: Days since last sign-in (default: `180`)
- `ReportOnly`: `true` (only report) or `false` (disable + mark)
- `BatchSize`: Users per run (default: `20`)

Deployment Steps
1) 🧱 Import template:
   - Azure Portal → Deploy a custom template → Build your own template in the editor
   - Paste/upload `Logic-EntraIDGuestLCM-MarkGuestsEligibleforRemoval.json`
2) 🧾 Fill parameters and deploy.
3) 🆔 Enable System-assigned Managed Identity:
   - Logic App → Identity → System-assigned → Status: On → Save
   - Copy the Object (principal) ID
4) 🔐 Grant Microsoft Graph permissions:
   - Use `Logic-EntraIDGuestLCM-MarkGuestsEligibleforRemoval_Azure_CLI_Permissions.sh`
   - Set `miPrincipalId` to the Managed Identity’s Object (principal) ID
   - Run in Azure Cloud Shell (Bash) or local `az` CLI

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

Deployment Steps
1) 🧱 Import template:
   - Azure Portal → Deploy a custom template → Build your own template in the editor
   - Paste/upload `Logic-EntraIDGuestLCM-DeleteGuestUsersAfterGracePeriod.json`
2) 🧾 Fill parameters and deploy.
3) 🆔 Enable System-assigned Managed Identity:
   - Logic App → Identity → System-assigned → Status: On → Save
   - Copy the Object (principal) ID
4) 🔐 Grant Microsoft Graph permissions:
   - Use `Logic-EntraIDGuestLCM-DeleteGuestUsersAfterGracePeriod_AzureCLIPermissions.sh`
   - Set `miPrincipalId` to the Managed Identity’s Object (principal) ID
   - Run in Azure Cloud Shell (Bash) or local `az` CLI

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
  - Re-run the Azure CLI permission scripts with the correct `miPrincipalId`
  - Verify Graph App Role assignments are “Granted”

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
