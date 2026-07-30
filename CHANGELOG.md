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
- Workflow parameters `NewAccountGraceDays` and `ExcludeFlagValue`, declared and deployed but not yet consumed by any workflow expression.

### Changed

- Mark workflow parameter `Threshold` renamed to `InactivityThresholdDays`.
- `ReportOnly` now defaults to `true` in both workflow definitions.
- README and `docs/PERMISSIONS-REFERENCE.md` state that reading `signInActivity` requires both the `AuditLog.Read.All` application permission and a Microsoft Entra ID P1/P2 license.
- `docs/DEPLOYMENT-GUIDE.md` marked as superseded by `docs/deployment.md`.

### Removed

- The two root-level ARM templates, replaced by `workflows/` + `infra/`.
- The two per-workflow `*_Permissions.sh` scripts, replaced by the role assignment in `infra/deploy.sh` / `infra/deploy.ps1`.

No workflow logic changed: every action, condition, expression and `runAfter` edge
is carried over unchanged apart from the parameter rename above.

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
