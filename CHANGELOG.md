# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `workflows/` — both workflow definitions, extracted from the ARM wrappers and parameterized.
- `infra/main.bicep` + `infra/modules/logic-app-workflow.bicep` — deploy both Consumption Logic Apps with system-assigned managed identities, definitions embedded from `workflows/` at build time.
- `infra/deploy.sh` and `infra/deploy.ps1` — create the resource group, deploy the Bicep, and assign the Microsoft Graph app roles to both managed identities. Idempotent, with 5 × 15 s retries around every directory lookup and role assignment, and no API call made with an empty id. Support `--skip-infra`, `--skip-permissions` and a `--report-only true|false` switch that updates only that parameter.
- `infra/main.parameters.json` — sample parameter file.
- `docs/deployment.md` — prerequisites, quickstart for both operating systems, mandatory first-run-in-report-only guidance, parameter reference and troubleshooting table.
- **Expiry-based marking (VouchGate handoff)** — the Mark workflow additionally marks a guest whose `onPremisesExtensionAttributes.extensionAttribute13` holds a date in the past, with reason `Approved access period expired` / `reasonCode: expiry`. Empty, null, whitespace and unparseable values are treated as "no expiry set" and never mark: the value must have a well-formed `yyyy-MM-dd` prefix with an in-range month and day before it is compared against today.
- **New-account grace period** — a never-signed-in guest is only marked once `createdDateTime` is older than `NewAccountGraceDays`, applied in addition to `InactivityThresholdDays`.
- `reasonCode` on every report entry (`inactivity` | `never-signed-in` | `expiry`), so a report-only run distinguishes why each guest was selected. The three conditions are mutually exclusive, so a guest appears at most once per run and produces at most one disable request.
- `newAccountGraceDays` / `newAccountGraceDate` in the Mark report metadata.
- `onPremisesExtensionAttributes` added to the `$select` of the guest evaluation call.
- README: real report schemas for both workflows, replacing example JSON that did not match what the workflows emit; per-reason field tables; an explicit section on how exclusion works and how the two uses of `extensionAttribute15` can collide.

### Changed

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

- **Logic App 1 — Mark Guests Eligible for Removal**
  - Weekly scheduled evaluation of guest user sign-in activity via Microsoft Graph API.
  - Detection of inactive users (last sign-in exceeds configurable threshold).
  - Detection of users who have never signed in (created before threshold date).
  - Marking via `extensionAttribute14` ("MarkedEligibleforRemoval") and `extensionAttribute15` (UTC timestamp).
  - Account disabling (`accountEnabled = false`) when not in report-only mode.
  - Report-only (dry-run) mode enabled by default.
  - Configurable batch size (1–100) for Graph API batch operations.
  - Comprehensive error handling: rate limiting (HTTP 429), permission errors, API failures.
  - JSON report output with run metadata, summary, and per-user details.

- **Logic App 2 — Delete Guests After Grace Period**
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
