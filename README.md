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
- ✅ Marks user if any one of three conditions holds:
  - **Inactivity** — last sign-in older than `InactivityThresholdDays`
  - **Never signed in** — no sign-in activity *and* created longer ago than **both** `InactivityThresholdDays` and `NewAccountGraceDays`
  - **Expiry** — `extensionAttribute13` holds a date in the past (approved access period elapsed; written by VouchGate)
- 🏷️ Each condition is mutually exclusive, so a guest is marked at most once per run and carries a single `reasonCode`
- 🚫 Skips any guest whose `extensionAttribute15` is `ExcludeFromLCM`, regardless of group membership
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
- `extensionAttribute13` → **read-only input**, the approved access end date (written by VouchGate). A date in the past marks the guest with reason `expiry`. Empty, null or unparseable values mean “no expiry set” and never mark.
- `extensionAttribute14` → lifecycle flag (`"MarkedEligibleforRemoval"`). The same literal is written for **all three** mark reasons, because the Delete Logic App gates on exact equality with it — a reason-specific value would break the Mark → Delete handoff. The reason lives in the report, not in the attribute.
- `extensionAttribute15` → dual purpose:
  - Exclusion flag for the “All Guests” group when set to `"ExcludeFromLCM"`
  - Timestamp when a user is marked for removal
- ℹ️ Newly marked users are disabled and thus fall out of the “All Guests” dynamic group (which requires `accountEnabled = true`). Ensure `extensionAttribute15` isn’t used for other purposes in your tenant.

### 🚫 How exclusion actually works

There is **no exclusion parameter on the Logic Apps.** Exclusion is enforced entirely
by the *dynamic membership rule* of the guest source group:

```kusto
(user.userType -eq "Guest") and (user.extensionAttribute15 -ne "ExcludeFromLCM") and (user.accountEnabled -eq true)
```

A guest with `extensionAttribute15 = "ExcludeFromLCM"` is never a member of
`GRP_SEC_GuestUserLCM_AllGuests`, so the Mark workflow normally never enumerates
it. Changing the sentinel value means editing that membership rule; nothing in
`infra/` or `workflows/` reads it as a parameter.

**Second line of defence, in the workflow itself.** Because dynamic membership
re-evaluation is not instantaneous, the Mark workflow *also* checks
`extensionAttribute15` on every guest it evaluates and skips any whose value is
`ExcludeFromLCM` (compared case-insensitively) — never marking, never disabling,
regardless of how it ended up in the group. Skipped guests are listed in the
report's `excluded[]` section.

**The two uses of `extensionAttribute15` share one field. How each case resolves:**

| Situation | Outcome |
| --- | --- |
| Guest excluded *before* ever being marked | Safe. Not in the group → never evaluated → the flag survives. |
| Guest excluded *after* it was already marked | The mark timestamp is replaced by `"ExcludeFromLCM"`. The Delete workflow compares that value against a threshold date, and `"ExcludeFromLCM"` sorts after any ISO date, so the guest is **not** deleted. Exclusion wins — the safe direction. |
| Guest is excluded but still in the group (rule not yet re-evaluated, or membership cached) | **Safe since v2.0.0.** The in-workflow guard skips it and records it under `excluded[]`, so the exclusion flag is no longer overwritten by the mark timestamp. Before v2.0.0 this destroyed the exclusion permanently. |

⚠️ The guard protects the flag, not the field: if you use `extensionAttribute15`
for anything *other* than the exclusion sentinel, the Mark workflow will still
overwrite that value with a timestamp when it marks a guest. Keep the field
dedicated to this solution.

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
  - Fetch sign-in activity and extension attributes via Microsoft Graph
  - Mark user on the first matching condition:

| `reasonCode` | `reason` | Condition |
| --- | --- | --- |
| `inactivity` | Inactive - Last sign-in before threshold | Has sign-in activity, and last sign-in older than `InactivityThresholdDays` |
| `never-signed-in` | Never logged in | No sign-in activity, `createdDateTime` present, and older than **both** `InactivityThresholdDays` **and** `NewAccountGraceDays` |
| `expiry` | Approved access period expired | `extensionAttribute13` parses as `yyyy-MM-dd` and is before today |

- 🏷️ Actions (identical for all three reasons):
  - `extensionAttribute14 = "MarkedEligibleforRemoval"`
  - `extensionAttribute15 = <current UTC datetime>`
  - Disable account when `ReportOnly = false`
- 📤 Output: JSON report — see [Reports](#-reports)

Parameters
- `guestSourceGroupId`: Object ID of `GRP_SEC_GuestUserLCM_AllGuests`
- `InactivityThresholdDays`: Days since last sign-in (default: `180`)
- `NewAccountGraceDays`: Minimum account age before a never-signed-in guest may be marked (default: `30`)
- `ReportOnly`: `true` (only report) or `false` (disable + mark)
- `BatchSize`: Users per run (default: `20`)

ℹ️ **`NewAccountGraceDays` is an additional guard, not a replacement.** A
never-signed-in guest must be older than both thresholds, so with the defaults
(`180` / `30`) the 180-day threshold is the binding one and behaviour is unchanged.
The grace period only starts to matter when you lower `InactivityThresholdDays`
below it — which is exactly the case it exists to protect, since guests invited by
email may legitimately have no sign-in for weeks before first redemption.

ℹ️ **Expiry marking treats anything unparseable as “no expiry set.”** Null, empty,
whitespace, `01/02/2026`, `2026-13-01`, `not-a-date` and truncated values are all
ignored rather than marked. Only a well-formed `yyyy-MM-dd` prefix with an
in-range month and day is compared against today, so a malformed value can never
cause a guest to be disabled.

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

Each Logic App emits a JSON object in its run output for easy auditing. Read it in
the Portal under **Run history → the run → `Generate_JSON_Report`** (Mark) or
**`Generate_Final_Report`** (Delete). See
[docs/deployment.md](docs/deployment.md#2-read-the-report) for the CLI route.

### Mark app — `Generate_JSON_Report`

Every entry in `affectedUsers[]` carries a machine-readable `reasonCode`
(`inactivity` | `never-signed-in` | `expiry`) alongside the human-readable
`reason`, so a `ReportOnly` run distinguishes *why* each guest was selected.
The remaining fields vary by reason — each carries the dates relevant to its own
condition.

```json
{
  "reportMetadata": {
    "runId": "08585xxxxxxxxxxxxxxx",
    "runDate": "2026-07-30 01:00:04",
    "runDateISO": "2026-07-30T01:00:04.7654321Z",
    "mode": "Report Only",
    "thresholdDays": 180,
    "thresholdDate": "2026-01-31T01:00:04Z",
    "newAccountGraceDays": 30,
    "newAccountGraceDate": "2026-06-30T01:00:04Z",
    "batchSize": 20,
    "totalMembersFound": 120,
    "usersAffected": 18,
    "successfulDisables": 0,
    "throttledUnprocessedCount": 2,
    "itemErrorCount": 1,
    "excludedCount": 3,
    "guestSourceGroupId": "11111111-1111-1111-1111-111111111111",
    "finalStatus": "Success"
  },
  "summary": {
    "totalAffectedUsers": 18,
    "accountsDisabled": 0,
    "reportOnlyMode": true,
    "throttledUnprocessedCount": 2,
    "errorCount": 1,
    "excludedCount": 3,
    "warnings": [
      "2 request(s) were still throttled after 5 attempts and were NOT processed this run. See throttledUnprocessed.",
      "1 request(s) failed with a non-retryable error. See errors."
    ],
    "message": "18 users marked for removal"
  },
  "affectedUsers": [
    {
      "userId": "22222222-2222-2222-2222-222222222222",
      "displayName": "Guest One",
      "userPrincipalName": "guest1_contoso.com#EXT#@tenant.onmicrosoft.com",
      "mail": "guest1@contoso.com",
      "lastSignIn": "2025-06-01T09:12:33Z",
      "daysSinceLastSignIn": 424,
      "reason": "Inactive - Last sign-in before threshold",
      "reasonCode": "inactivity",
      "actionTaken": "REPORT ONLY",
      "timestamp": "2026-07-30T01:00:11Z"
    },
    {
      "userId": "33333333-3333-3333-3333-333333333333",
      "displayName": "Guest Two",
      "userPrincipalName": "guest2_contoso.com#EXT#@tenant.onmicrosoft.com",
      "mail": "guest2@contoso.com",
      "createdDateTime": "2025-02-10T08:00:00Z",
      "daysSinceCreation": 535,
      "reason": "Never logged in",
      "reasonCode": "never-signed-in",
      "actionTaken": "REPORT ONLY",
      "timestamp": "2026-07-30T01:00:11Z"
    },
    {
      "userId": "44444444-4444-4444-4444-444444444444",
      "displayName": "Guest Three",
      "userPrincipalName": "guest3_contoso.com#EXT#@tenant.onmicrosoft.com",
      "mail": "guest3@contoso.com",
      "accessExpiredOn": "2026-05-31",
      "daysSinceExpiry": 60,
      "reason": "Approved access period expired",
      "reasonCode": "expiry",
      "actionTaken": "REPORT ONLY",
      "timestamp": "2026-07-30T01:00:11Z"
    }
  ],
  "throttledUnprocessed": [
    {
      "requestId": "66666666-6666-6666-6666-666666666666",
      "phase": "read-guest-attributes",
      "attempts": 5,
      "reason": "Still throttled or unavailable after the final retry attempt"
    },
    {
      "requestId": "disable-77777777-7777-7777-7777-777777777777",
      "phase": "disable-guest",
      "attempts": 5,
      "reason": "Still throttled or unavailable after the final retry attempt"
    }
  ],
  "errors": [
    {
      "requestId": "88888888-8888-8888-8888-888888888888",
      "status": 404,
      "errorCode": "Request_ResourceNotFound",
      "errorMessage": "Resource '8888...' does not exist or one of its queried reference-property objects are not present.",
      "phase": "read-guest-attributes",
      "attempt": 1
    }
  ],
  "excluded": [
    {
      "userId": "99999999-9999-9999-9999-999999999999",
      "displayName": "VIP Guest",
      "userPrincipalName": "vip_partner.com#EXT#@tenant.onmicrosoft.com",
      "reason": "extensionAttribute15 is set to ExcludeFromLCM",
      "timestamp": "2026-07-30T01:00:08Z"
    }
  ],
  "configuration": {
    "audience": "https://graph.microsoft.com",
    "reportOnly": true,
    "threshold": 180,
    "newAccountGraceDays": 30,
    "batchSize": 20
  }
}
```

The three new sections are always present, empty when nothing applies:

| Section | Meaning | Action needed |
| --- | --- | --- |
| `throttledUnprocessed[]` | Requests that were still `429`/`5xx` after the final retry attempt. **These guests were not evaluated or not disabled this run.** | Usually none — the next scheduled run picks them up. A persistently large count means `BatchSize` is too high for your tenant's throttling limits. |
| `errors[]` | Per-item `4xx` other than `429`: permanent failures, not retried. `403` means a missing Graph app role; `404` usually means the guest was deleted between enumeration and evaluation. | Investigate `403`s. `404`s are typically benign. |
| `excluded[]` | Guests skipped because `extensionAttribute15` is `ExcludeFromLCM`. Never marked, never disabled. | None — this is the guard working. |

`requestId` is the batch request id: the bare user object id for the read phase,
and `disable-<userId>` for the disable phase. `phase` disambiguates
(`read-guest-attributes` or `disable-guest`).

Per-reason fields in `affectedUsers[]`:

| `reasonCode` | Extra fields |
| --- | --- |
| `inactivity` | `lastSignIn`, `daysSinceLastSignIn` |
| `never-signed-in` | `createdDateTime`, `daysSinceCreation` |
| `expiry` | `accessExpiredOn` (the raw `extensionAttribute13` value), `daysSinceExpiry` |

Common to all: `userId`, `displayName`, `userPrincipalName`, `mail`, `reason`,
`reasonCode`, `actionTaken` (`REPORT ONLY` or `DISABLED`), `timestamp`.

### Delete app — `Generate_Final_Report`

The Delete app reports on the guests it evaluated for deletion. It does not
distinguish mark reasons — by the time a guest reaches it, all three reasons look
identical (`extensionAttribute14 = "MarkedEligibleforRemoval"`).

```json
{
  "reportMetadata": {
    "runId": "08585xxxxxxxxxxxxxxx",
    "runDate": "2026-07-30 03:00:02",
    "runDateISO": "2026-07-30T03:00:02.1234567Z",
    "mode": "Report Only",
    "deletionThresholdDays": 30,
    "deletionThresholdDate": "2026-06-30T03:00:02Z",
    "batchSize": 20,
    "totalProcessedUsers": 42,
    "usersDeleted": 12,
    "successfulDeletes": 0,
    "throttledUnprocessedCount": 0,
    "itemErrorCount": 0,
    "guestSourceGroupId": "55555555-5555-5555-5555-555555555555",
    "failedDeletes": []
  },
  "summary": {
    "totalMarkedUsersFound": 12,
    "accountsDeleted": 0,
    "reportOnlyMode": true,
    "failedDeletesCount": 0,
    "throttledUnprocessedCount": 0,
    "errorCount": 0,
    "warnings": [],
    "message": "12 users processed for deletion"
  },
  "deletedUsers": [
    {
      "userId": "22222222-2222-2222-2222-222222222222",
      "displayName": "Guest One",
      "userPrincipalName": "guest1_contoso.com#EXT#@tenant.onmicrosoft.com",
      "mail": "guest1@contoso.com",
      "markedDate": "2026-05-15T01:00:11Z",
      "daysSinceMarked": 76,
      "actionTaken": "REPORT ONLY",
      "timestamp": "2026-07-30T03:00:09Z"
    }
  ],
  "failedDeletes": [],
  "throttledUnprocessed": [],
  "errors": [],
  "configuration": {
    "audience": "https://graph.microsoft.com",
    "reportOnly": true,
    "deletionThresholdDays": 30,
    "batchSize": 20,
    "guestSourceGroupId": "55555555-5555-5555-5555-555555555555"
  }
}
```

`throttledUnprocessed[]` and `errors[]` carry the same shape as in the Mark
report, with `phase` values `read-guest-attributes` and `delete-guest`. Note that
`failedDeletes[]` predates the throttling fix and is now effectively unreachable:
per-item `4xx`/`5xx` are routed to `errors[]` and `throttledUnprocessed[]` before
the delete counter sees them.

---

## 🚦 Throttling and Retries

Microsoft Graph JSON batching returns **`200` for the batch as a whole** while
each response *inside* it carries its own status code. A `429` on an individual
item therefore does not surface as a failed HTTP call — which is how throttled
guests used to be dropped without a trace
([#2](https://github.com/daniel-fraubaum/EntraID-Guest-User-LifeCycle-Management/issues/2)).

Every `$batch` call is now wrapped in a retry loop:

| Per-item status | Treatment |
| --- | --- |
| `2xx` / `3xx` | Success — processed as normal |
| `429` | Retried, honouring `Retry-After` |
| `5xx` | Retried on the same path as `429` |
| `4xx` except `429` | **Not** retried — recorded in `errors[]` |

- Only the affected items are resent; successful items are never re-sent.
- The wait is the **highest** `Retry-After` among the throttled items, falling back to **30 s** when the header is absent and capped at **300 s** so one pathological value cannot exhaust the loop timeout.
- Up to **5 attempts**. Whatever is still failing afterwards lands in `throttledUnprocessed[]` with a warning in `summary.warnings` — **the run does not fail**, so the remaining work is visible and the next scheduled run retries it.

💡 A consistently non-empty `throttledUnprocessed[]` means `BatchSize` is too
aggressive for your tenant. Lower it and redeploy.

---

## ⏱️ Scheduling Guidance

- ⛓️ Stagger runs to allow propagation:
  - Mark app: Sunday 01:00
  - Delete app: Sunday 03:00
- 🕒 Adjust to your maintenance windows and dynamic group evaluation delays.

---

## 🛡️ Safety Tips

- 🧪 Start with `ReportOnly = true` for both Logic Apps to validate logic and outputs.
- 🙅 Exclude VIP/service-linked guests by setting `extensionAttribute15 = "ExcludeFromLCM"`, then **confirm they have left the “All Guests” group** before the next Mark run — see [How exclusion actually works](#-how-exclusion-actually-works).
- 📅 Check `affectedUsers[].reasonCode` in the first report: a spike in `expiry` usually means `extensionAttribute13` was backfilled with old dates.
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
