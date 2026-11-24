# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [2.0.0] - 2026-11-24

Validated end to end against a test tenant on 2026-11-23/24: fresh install with
both deploy scripts, idempotent redeploys, role pruning, per-workflow
`ReportOnly` switching, report-only and live runs of both Logic Apps. See
[docs/migration-v1-to-v2.md](docs/migration-v1-to-v2.md) if you are upgrading
from v1.

### Fixed

- **Found in the end-to-end test against a test tenant (2026-11-23).** The v2
  definitions as first written could not be deployed, and once deployable their
  reports failed. None of this was caught by the static validator, which now
  checks for all three patterns:
  - **12 `SetVariable` actions read their own variable** (`AggregatedResponses`, `ItemErrors`, `ThrottledUnprocessed` in the read, disable and delete retry loops). Azure rejects the whole workflow at save time with "Self reference is not supported". Each value is now computed in a sibling `Compose_*` action and the variable is set from its `outputs()`; nesting depth is unchanged.
  - **12 `Select` actions had `"from": "body('…')"` without the leading `@`**, so the input was a plain string. Rejected at save time.
  - **`createArray()` without arguments** in 17 places, including both report actions. Accepted at save time but fails at runtime, so `Generate_JSON_Report` and `Generate_Final_Report` never produced a report. Replaced with `json('[]')`.
  - The Mark workflow's member enumeration now guards its `foreach` with `coalesce(…, json('[]'))`, as the Delete workflow already did, so a failed page read terminates with the API error instead of an expression error.
- **A failed disable or delete was reported as a success.** `affectedUsers[].actionTaken` (Mark) and `deletedUsers[].actionTaken` (Delete) were set to `DISABLED` / `DELETED` when the request was queued, so a guest whose `PATCH` or `DELETE` returned `403` still appeared as done; only `errors[]` told the truth. Three root-level `Select` actions now reconcile each entry with `errors[]` and `throttledUnprocessed[]` before the report is written, giving `DISABLE FAILED` / `DISABLE THROTTLED` and `DELETE FAILED` / `DELETE THROTTLED`. Nesting depth is unchanged.
- **A first deployment could leave both workflows failing with `403` for up to a day.** A Recurrence trigger fires once when a workflow is created Enabled or enabled for the first time. The scripts deployed the workflows Enabled and assigned the Graph app roles afterwards, so that first run obtained a managed identity token without roles, which Azure caches for up to ~24 hours. A fresh install is now deployed Disabled, the roles are assigned, and the workflows are enabled 120 s later.
- **`deploy.ps1` could not assign Graph app roles** under PowerShell 7.3+ on Windows: the JSON body passed as an argument to `az.cmd` lost its quotes and Graph answered `400`, reported as a missing admin role. Bodies are now always passed as files, and the last `az` error line is shown in every retry warning (both scripts).
- **`deploy.ps1 -SkipInfra -ReportOnly` failed** under `Set-StrictMode` on `.PSObject.Properties.Count`.
- **v1 classified every successful disable as an error, and the run then failed.**
  Microsoft Graph answers `204 No Content` for a successful `PATCH /users/{id}`,
  but the per-item success check inside the disable batch tested for status `200`.
  Every real success therefore took the failure branch.

  **Accounts were disabled correctly.** The `PATCH` succeeded and the guests really
  were disabled and tagged; only the classification of that success was wrong. No
  guest was left enabled because of this defect, and no guest was disabled that
  should not have been.

  The knock-on effects made v1 run history misleading:

  - `SuccessfulDisables` never incremented, so `summary.accountsDisabled` reported `0` while accounts were in fact disabled.
  - `HasDisableBatchError` is also a batch loop exit condition, so the run stopped at the **first batch that produced any disable**. Each weekly run therefore cleared at most one batch's worth of eligible guests, up to `BatchSize` and usually fewer, and every guest after that point in the enumeration was never evaluated.
  - The run terminated as **Failed** with an **empty** error message, because `TerminateErrorMessage` was only ever set by the separate transport level check.
  - `Generate_JSON_Report` runs after the terminate check, so no report was produced at all.

  Because the error flag also exits the batch loop, v1 never worked through the
  full population, so existing installations have most likely **accumulated a
  backlog** of eligible guests. The first v2 run processes that entire backlog in
  one execution and its totals will look far larger than the familiar weekly
  figures. That is this defect being corrected, not a v2 error. Run with
  `ReportOnly = true`, review the totals, and only then enable enforcement;
  adjusting `DeletionThresholdDays` is not the lever. See
  [docs/migration-v1-to-v2.md](docs/migration-v1-to-v2.md).

  The Delete Logic App was not affected: its check tested for `204`, which is
  correct for `DELETE /users/{id}`. The per-item success test now accepts any `2xx`
  in both workflows, and per-item `4xx`/`5xx` no longer set a run-failing flag at
  all. If you saw v1 Mark runs failing with an empty error message while guests
  were visibly being disabled, this was the cause.

- **Throttled items inside Graph `$batch` calls are no longer silently dropped** ([#2](https://github.com/daniel-fraubaum/EntraID-Guest-User-LifeCycle-Management/issues/2), reported by [@jaw2floor](https://github.com/jaw2floor)). Microsoft Graph JSON batching answers `200` for the batch as a whole while each response inside it carries its own status, and the workflows only ever inspected the transport status. Any guest whose individual response was `429` was skipped without a trace.

  Every `$batch` call is now wrapped in an `Until` loop that inspects per-item status codes and retries only the affected items:

  - responses with `2xx`/`3xx` proceed exactly as before;
  - `429` **and** `5xx` responses are collected into a retry list, and the loop waits for the highest `Retry-After` value found among them (fallback 30 s if the header is absent, capped at 300 s so a pathological value cannot exhaust the loop timeout) before resending a batch rebuilt from that list alone;
  - up to 5 attempts, after which anything still failing is written to a `throttledUnprocessed` report section with its request id and attempt count, and a warning is emitted in `summary.warnings` - **the run does not fail**, so nothing disappears silently;
  - `4xx` other than `429` are permanent, so they are recorded in a new `errors` report section with status, error code and message, and are not retried.

  Applied to `GetUserInfosBatch` and `Execute_DisableBatch` in the Mark workflow and to `Execute_DeleteBatch` in the Delete workflow - the three actions named in the issue - and additionally to `GetUserInfosBatch` in the Delete workflow, which carried the identical defect.

### Added

- **Deploy to Azure / Portal deployment**, the v1 "Deploy a custom template" path: `infra/main.json` is `main.bicep` compiled to ARM and tracked in the repo, with a Deploy to Azure button in the README. It deploys both workflows Disabled; `deploy.sh --skip-infra --enable` then grants the Graph roles and enables them. `scripts/validate-workflows.py` fails when `infra/main.json` no longer embeds the current workflow definitions.
- **Exclusion guard in the Mark workflow.** A guest whose `extensionAttribute15` equals `ExcludeFromLCM` (compared case-insensitively) is never marked and never disabled, regardless of group membership, and is counted in a new `excluded` report section. This closes the documented hazard where a guest still present in the source group during dynamic-membership re-evaluation lag had its exclusion flag permanently overwritten by the mark timestamp.
- `docs/migration-v1-to-v2.md` - upgrade notes for existing v1 installations, including the defect above and what redeploying preserves.
- `docs/deployment.md` and README: full extension attribute contract, consolidated parameter table with defaults, deploy quickstart, ReportOnly-first walkthrough, and a "Works together with VouchGate" section.
- `throttledUnprocessed`, `errors` and (Mark only) `excluded` sections in both run reports, with matching counts in `reportMetadata` and `summary`, plus `summary.warnings`.
- `workflows/` - both workflow definitions, extracted from the ARM wrappers and parameterized.
- `infra/main.bicep` + `infra/modules/logic-app-workflow.bicep` - deploy both Consumption Logic Apps with system-assigned managed identities, definitions embedded from `workflows/` at build time.
- `infra/deploy.sh` and `infra/deploy.ps1` - create the resource group, deploy the Bicep, and assign the Microsoft Graph app roles to both managed identities. Idempotent, with 5 × 15 s retries around every directory lookup and role assignment, and no API call made with an empty id. Support `--skip-infra`, `--skip-permissions` and a `--report-only true|false` switch that updates only that parameter.
- `infra/main.parameters.json` - sample parameter file.
- `docs/deployment.md` - prerequisites, quickstart for both operating systems, mandatory first-run-in-report-only guidance, parameter reference and troubleshooting table.
- **Expiry-based marking (VouchGate handoff)** - the Mark workflow additionally marks a guest whose `onPremisesExtensionAttributes.extensionAttribute13` holds a date in the past, with reason `Approved access period expired` / `reasonCode: expiry`. Empty, null, whitespace and unparseable values are treated as "no expiry set" and never mark: the value must have a well-formed `yyyy-MM-dd` prefix with an in-range month and day before it is compared against today.
- **New-account grace period** - a never-signed-in guest is only marked once `createdDateTime` is older than `NewAccountGraceDays`, applied in addition to `InactivityThresholdDays`.
- `reasonCode` on every report entry (`inactivity` | `never-signed-in` | `expiry`), so a report-only run distinguishes why each guest was selected. The three conditions are mutually exclusive, so a guest appears at most once per run and produces at most one disable request.
- `newAccountGraceDays` / `newAccountGraceDate` in the Mark report metadata.
- `onPremisesExtensionAttributes` added to the `$select` of the guest evaluation call.
- README: real report schemas for both workflows, replacing example JSON that did not match what the workflows emit; per-reason field tables; an explicit section on how exclusion works and how the two uses of `extensionAttribute15` can collide.

### Changed

- **`workflowState` defaults to `Disabled`** in `main.bicep`, so a template deployment without the role assignment cannot fire a role-less first run. The deploy scripts pass the state explicitly: `Disabled` on a fresh install followed by an enable once the roles exist, and on a redeploy the state the workflows already have. A `workflowState` in `--parameters-file` still wins.
- **Graph app roles are listed per managed identity.** Mark: `AuditLog.Read.All`, `GroupMember.Read.All`, `User.ReadWrite.All`. Delete: `GroupMember.Read.All`, `User.ReadWrite.All` (no longer `AuditLog.Read.All`). New options `--mark-roles` / `--delete-roles` and `--prune-roles` (PowerShell: `-MarkRoles`, `-DeleteRoles`, `-PruneRoles`); `--roles` still sets one list for both.
- **Documentation no longer claims the Mark identity cannot delete.** A narrower Mark set (`User.ReadUpdate.All` + `User.EnableDisableAccount.All`) was tested live: `accountEnabled` works, but `PATCH` of `onPremisesExtensionAttributes` returns `403`. The only alternative, `Directory.ReadWrite.All`, is broader. Mark therefore needs `User.ReadWrite.All`, which also allows `DELETE /users`; the separation is a property of the workflow definition, and write access to the Logic Apps must be restricted accordingly.
- `--report-only` with `--skip-infra` can target one workflow with `--workflow mark|delete|both` (`-Workflow`), so the apps can go live one at a time as the docs recommend.
- New `--enable` / `-Enable` to enable both workflows after a `--skip-permissions` install.
- Documentation: schedules are UTC; inactivity uses the last **successful** sign-in, interactive or non-interactive; `docs/PERMISSIONS-REFERENCE.md` rewritten (it listed `User.DeleteRestore.All` for `DELETE /users`, which is not sufficient).
- Mark workflow parameter `Threshold` renamed to `InactivityThresholdDays`.
- `NewAccountGraceDays` is now wired into the never-signed-in condition (it was previously declared and deployed but unused).
- `ReportOnly` now defaults to `true` in both workflow definitions.
- README and `docs/PERMISSIONS-REFERENCE.md` state that reading `signInActivity` requires both the `AuditLog.Read.All` application permission and a Microsoft Entra ID P1/P2 license.
- `docs/DEPLOYMENT-GUIDE.md` marked as superseded by `docs/deployment.md`.

### Removed

- The two root-level ARM templates, replaced by `workflows/` + `infra/`.
- The two per-workflow `*_Permissions.sh` scripts, replaced by the role assignment in `infra/deploy.sh` / `infra/deploy.ps1`.
- The `ExcludeFlagValue` parameter, from both workflows and from `infra/`. Nothing read it: exclusion is enforced by the dynamic membership rule of the guest source group (`extensionAttribute15 -ne "ExcludeFromLCM"`). The mechanism, and the collision between the sentinel and the mark timestamp, are now documented in the README and `docs/deployment.md` instead.

Existing marking behaviour is preserved: the inactivity and never-signed-in
conditions keep their original predicates, with the grace period added as an
additional necessary condition rather than a replacement.

## [1.0.0] - 2025

### Added

- **Logic App 1 - Mark Guests Eligible for Removal**
  - Weekly scheduled evaluation of guest user sign-in activity via Microsoft Graph API.
  - Detection of inactive users (last sign-in exceeds configurable threshold).
  - Detection of users who have never signed in (created before threshold date).
  - Marking via `extensionAttribute14` ("MarkedEligibleforRemoval") and `extensionAttribute15` (UTC timestamp).
  - Account disabling (`accountEnabled = false`) when not in report-only mode.
  - Report-only (dry-run) mode enabled by default.
  - Configurable batch size (1-100) for Graph API batch operations.
  - Comprehensive error handling: rate limiting (HTTP 429), permission errors, API failures.
  - JSON report output with run metadata, summary, and per-user details.

- **Logic App 2 - Delete Guests After Grace Period**
  - Weekly scheduled evaluation of previously marked guest users.
  - Triple-condition validation before deletion: correct `extensionAttribute14`, expired grace period (`extensionAttribute15`), and `accountEnabled = false`.
  - Configurable grace period (`DeletionThresholdDays`, default: 30 days).
  - Report-only (dry-run) mode enabled by default.
  - Per-user success/failure tracking for delete operations.
  - JSON report output with run metadata, summary, deleted users, and failed deletes.

- **Azure CLI Permission Scripts**
  - `Logic-EntraIDGuestLCM-MarkGuestsEligibleforRemoval_Azure_CLI_Permissions.sh` for granting Graph API permissions to Logic App 1.
  - `Logic-EntraIDGuestLCM-DeleteGuestUsersAfterGracePeriod_AzureCLIPermissions.sh` for granting Graph API permissions to Logic App 2.
  - Input validation (Managed Identity existence, Graph SP existence).
  - Automatic app role ID resolution and assignment.

- **Documentation**
  - README with architecture overview, prerequisites, deployment steps, and troubleshooting.
  - Architecture documentation with data flow diagrams and design decisions.
  - Step-by-step deployment guide.
  - Permissions reference with Graph API call details.
  - FAQ covering common questions and troubleshooting.
  - Security policy and contributing guidelines.

- **Infrastructure**
  - ARM deployment templates for both Logic Apps.
  - System-assigned Managed Identity enabled by default.
  - Dynamic security group membership rules for automated scoping.
  - MIT License.
