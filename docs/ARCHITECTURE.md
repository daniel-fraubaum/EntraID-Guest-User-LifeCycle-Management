# Architecture

This document provides a detailed overview of how the Entra ID Guest User Lifecycle Management solution works, including data flow, component interaction, and design decisions.

## Solution Overview

The solution automates guest user lifecycle management in Microsoft Entra ID using two independent Azure Logic Apps that communicate indirectly through **Entra ID extension attributes** and **dynamic security groups**.

No premium Entra ID licenses (e.g., Identity Governance, PIM, or Access Reviews) are required.

```
  ┌─────────────────────────────────────────────────────────────────────┐
  │                     Microsoft Entra ID Tenant                      │
  │                                                                    │
  │  ┌──────────────────────┐         ┌───────────────────────────┐   │
  │  │  Dynamic Group:      │         │  Dynamic Group:            │   │
  │  │  AllGuests            │         │  EligibleForRemoval        │   │
  │  │  (active + enabled)  │────────▶│  (disabled + marked)       │   │
  │  └──────────┬───────────┘         └──────────┬────────────────┘   │
  │             │                                 │                    │
  │             ▼                                 ▼                    │
  │  ┌──────────────────────┐         ┌───────────────────────────┐   │
  │  │  Logic App 1:        │         │  Logic App 2:              │   │
  │  │  Mark Guests         │         │  Delete Guests             │   │
  │  │  (Weekly, Sun 01:00) │         │  (Weekly, Sun 03:00)       │   │
  │  └──────────────────────┘         └───────────────────────────┘   │
  │             │                                 │                    │
  │             ▼                                 ▼                    │
  │        Microsoft Graph API            Microsoft Graph API          │
  │        (Batch Operations)             (Batch Operations)           │
  └─────────────────────────────────────────────────────────────────────┘
```

## Component Details

### Dynamic Security Groups

Two Entra ID dynamic security groups serve as input scopes for the Logic Apps:

| Group | Membership Rule | Purpose |
|-------|----------------|---------|
| `GRP_SEC_GuestUserLCM_AllGuests` | `(user.userType -eq "Guest") and (user.extensionAttribute15 -ne "ExcludeFromLCM") and (user.accountEnabled -eq true)` | Contains all active guest users eligible for evaluation. |
| `GRP_SEC_GuestUserLCM_EligibleForRemoval` | `(user.extensionAttribute14 -eq "MarkedEligibleforRemoval") and (user.accountEnabled -eq false)` | Contains guests already marked and disabled — awaiting deletion. |

The groups update automatically as user attributes change, creating a seamless handoff between the two Logic Apps.

### Extension Attributes

Two on-premises extension attributes drive the lifecycle state machine:

| Attribute | Values | Purpose |
|-----------|--------|---------|
| `extensionAttribute14` | `"MarkedEligibleforRemoval"` | Lifecycle flag indicating the user has been identified as inactive. |
| `extensionAttribute15` | UTC timestamp (e.g., `2025-06-15T01:00:00Z`) or `"ExcludeFromLCM"` | Dual-purpose: stores the marking timestamp for grace period calculation, or permanently excludes a user from lifecycle processing. |

### Logic App 1 — Mark Guests Eligible for Removal

**Trigger:** Weekly recurrence (default: Sunday, 01:00 UTC)

**Data Flow:**

```
Recurrence Trigger
       │
       ▼
Initialize Variables
(Threshold, ReportArray, NextLink, AllMembers, counters, error flags)
       │
       ▼
┌──────────────────────────────┐
│  Paginate Group Members      │◀─── GET /groups/{id}/members
│  (Do Until NextLink is empty)│     ($select=id, $top=999)
└──────────────┬───────────────┘
               │
               ▼
       API Error? ──Yes──▶ Terminate (Failed)
               │
              No
               │
               ▼
┌──────────────────────────────────────┐
│  Process Batches                     │
│  (Do Until AllMembers is empty)      │
│                                      │
│  1. Select batch of N user IDs       │
│  2. POST /beta/$batch                │
│     (GET user details per ID)        │
│  3. For each response:               │
│     ├─ Account already disabled?     │
│     │  └─ Skip                       │
│     ├─ Has sign-in activity?         │
│     │  └─ Last sign-in < Threshold?  │
│     │     └─ Yes: Add to report +    │
│     │        disable requests        │
│     └─ No sign-in activity at all?   │
│        └─ Created before Threshold?  │
│           └─ Yes: Add to report +    │
│              disable requests        │
│                                      │
│  4. If ReportOnly = false:           │
│     POST /beta/$batch                │
│     (PATCH each user:                │
│      accountEnabled=false,           │
│      extensionAttribute14=marked,    │
│      extensionAttribute15=timestamp) │
│                                      │
│  5. Remove processed batch from      │
│     AllMembers, loop                 │
└──────────────┬───────────────────────┘
               │
               ▼
       Rate Limit / Error? ──Yes──▶ Terminate (Failed)
               │
              No
               │
               ▼
       Generate JSON Report (Compose)
```

**Key design decisions:**

- Uses Microsoft Graph **batch API** (`/beta/$batch`) to minimize API calls and stay within rate limits.
- Evaluates both `lastSuccessfulSignInDateTime` and `lastSignInDateTime` (with fallback via `coalesce`) to determine the most recent sign-in.
- Users who have **never signed in** are evaluated by comparing `createdDateTime` against the threshold — if they were created before the threshold date, they are considered inactive.
- Already-disabled accounts (`accountEnabled = false`) are skipped to avoid re-processing.

### Logic App 2 — Delete Guests After Grace Period

**Trigger:** Weekly recurrence (default: Sunday, 03:00 UTC)

**Data Flow:**

```
Recurrence Trigger
       │
       ▼
Initialize Variables
(DeletionThreshold, DeletedUsersReport, NextLink, AllMembers,
 counters, error flags, FailedDeletes)
       │
       ▼
┌──────────────────────────────┐
│  Paginate Group Members      │◀─── GET /groups/{id}/members
│  (Do Until NextLink is empty)│     ($select=id, $top=999)
└──────────────┬───────────────┘
               │
               ▼
       API Error? ──Yes──▶ Terminate (Failed)
               │
              No
               │
               ▼
┌──────────────────────────────────────┐
│  Process Batches                     │
│  (Do Until AllMembers is empty)      │
│                                      │
│  1. Select batch of N user IDs       │
│  2. POST /beta/$batch                │
│     (GET user details incl.          │
│      onPremisesExtensionAttributes)  │
│  3. For each response:               │
│     ├─ extensionAttribute14          │
│     │  = "MarkedEligibleforRemoval"? │
│     ├─ extensionAttribute15          │
│     │  timestamp < DeletionThreshold?│
│     ├─ accountEnabled = false?       │
│     └─ All true:                     │
│        Add to report + delete batch  │
│                                      │
│  4. If ReportOnly = false:           │
│     POST /beta/$batch                │
│     (DELETE /users/{id})             │
│                                      │
│  5. Count successes (204) and        │
│     failures per response            │
│                                      │
│  6. Remove processed batch,          │
│     loop                             │
└──────────────┬───────────────────────┘
               │
               ▼
       Rate Limit? ──Yes──▶ Terminate (Failed)
               │
              No
               │
               ▼
       Failed Deletes? ──Yes──▶ Terminate (Failed)
               │
              No
               │
               ▼
       Generate JSON Report (Compose)
```

**Key design decisions:**

- Triple condition check before deletion: correct `extensionAttribute14` value **AND** `extensionAttribute15` timestamp older than threshold **AND** `accountEnabled = false`.
- Failed deletes are individually tracked and reported.
- Deleted users go to the Entra ID "Deleted Users" recycle bin and can be restored within 30 days.

## User Lifecycle State Machine

```
                    ┌───────────────┐
                    │  Guest User   │
                    │  (Active)     │
                    └───────┬───────┘
                            │
                   Group: AllGuests
                            │
                  Logic App 1 evaluates
                            │
             ┌──────────────┴──────────────┐
             │                             │
        Still Active               Inactive / Never
        (no action)                  signed in
             │                             │
             │                    Set extensionAttribute14
             │                    Set extensionAttribute15
             │                    Disable account
             │                             │
             │                    ┌────────┴────────┐
             │                    │  Guest User     │
             │                    │  (Disabled,     │
             │                    │   Marked)       │
             │                    └────────┬────────┘
             │                             │
             │                   Group: EligibleForRemoval
             │                             │
             │                  Logic App 2 evaluates
             │                             │
             │              ┌──────────────┴──────────────┐
             │              │                             │
             │       Grace period                  Grace period
             │       NOT exceeded                    exceeded
             │       (no action)                         │
             │              │                     DELETE user
             │              │                             │
             │              │                    ┌────────┴────────┐
             │              │                    │  Deleted Users  │
             │              │                    │  (Recycle Bin)  │
             │              │                    │  30-day retain  │
             │              │                    └─────────────────┘
             │              │
             └──────────────┘
```

## Error Handling Strategy

Both Logic Apps implement a layered error handling approach:

| Layer | Mechanism | Behavior |
|-------|-----------|----------|
| HTTP transport | `retryPolicy: exponential` (3 retries, 20s base interval) | Automatic retry for transient network/Graph errors. |
| API error detection | Status code checks after every HTTP action | Catches 400, 401, 403, 404, 409, 429, 500, 503. |
| Rate limiting | Dedicated `HasRateLimit` flag + HTTP 429 detection | Stops processing gracefully, reports progress so far. |
| Batch-level errors | Individual response status check per batch item | Tracks successes and failures per user within a batch. |
| Terminal errors | `Terminate` action with `runStatus: Failed` | Ensures the Logic App run is marked as failed for monitoring. |

## Batch Processing

Both Logic Apps use the Microsoft Graph **JSON batching** endpoint (`/beta/$batch`) to group multiple API calls into a single HTTP request:

1. **Member retrieval** — Paginated with `$top=999` and `@odata.nextLink` handling.
2. **User detail queries** — Batched in groups of `BatchSize` (default: 20, max: 100).
3. **Write/delete operations** — Batched PATCH (disable) or DELETE requests in the same batch size.

This approach significantly reduces the number of HTTP round-trips and helps stay within Microsoft Graph API rate limits.

## Deployment Model

Both Logic Apps are deployed as **ARM templates** (`deploymentTemplate.json`):

- Parameters are injected at deployment time and mapped to Logic App workflow parameters.
- System-assigned Managed Identity is enabled by default in the template.
- Microsoft Graph app role assignments must be granted separately using the provided Azure CLI scripts.
- The default Azure region is `westeurope` (configurable in the template).
