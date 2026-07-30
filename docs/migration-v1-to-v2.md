# Migrating from v1 to v2.0.0

For anyone already running the two Logic Apps from v1. Read the defect notice
first: it changes how you should interpret your existing v1 run history.

---

## ⚠️ Fixed defect in v1: successful disables were classified as errors

**v1 misclassified every successful disable, and the run then failed.** If you ever
ran the Mark Logic App with `ReportOnly = false`, your run history is misleading.

**Accounts were disabled correctly.** The Microsoft Graph `PATCH /users/{id}` call
succeeded and the guests really were disabled and tagged. Only the classification
of that success was wrong. **No guest was left enabled because of this defect, and
no guest was disabled that should not have been.**

### What went wrong

Graph returns **`204 No Content`** for a successful `PATCH /users/{id}`. The v1
per-item success check inside the disable batch tested for status **`200`**:

```json
"Check_If_Disable_Success": {
  "expression": { "equals": ["@item()?['status']", 200] },
  "else": { "actions": { "Set_variable": {
      "inputs": { "name": "HasDisableBatchError", "value": true } } } }
}
```

Every real success took the `else` branch. The consequences cascaded:

| Effect | Detail |
| --- | --- |
| `SuccessfulDisables` never incremented | `summary.accountsDisabled` reported `0` even though accounts were disabled |
| `HasDisableBatchError` set to `true` | This is also a batch loop exit condition, so the run stopped after the **first** batch of `BatchSize` guests |
| Run terminated as **Failed** | With `runError.message` taken from `TerminateErrorMessage`, which was only ever set by the transport level check, so the message was **empty** |
| Final report never produced | `Generate_JSON_Report` runs after the terminate check, so it never executed |

If you saw v1 Mark runs failing with an empty error message while guests were
visibly being disabled and tagged in Entra ID, this was the cause. The practical
effect was that each run only ever processed one batch, so the backlog cleared
about `BatchSize` guests per week instead of all of them.

The Delete Logic App was **not** affected: its check tested for `204`, which is
correct for `DELETE /users/{id}`.

### What v2 does

The per-item success test now accepts any `2xx`, so `204` is a success. Per-item
`4xx` and `5xx` no longer set a run-failing flag at all: they are routed into the
new `errors[]` and `throttledUnprocessed[]` report sections
(see [#2](https://github.com/daniel-fraubaum/EntraID-Guest-User-LifeCycle-Management/issues/2)).

### What to do about your v1 history

- Treat v1 `accountsDisabled: 0` figures as unreliable. Entra ID is the source of truth: query for `extensionAttribute14 eq 'MarkedEligibleforRemoval'` to see what was actually marked.
- Treat v1 Mark run failures with an empty error message as almost certainly this defect, not a permissions or throttling problem.
- Expect the first v2 run with `ReportOnly = false` to process a **larger** number of guests than a v1 run did, because the run no longer stops after one batch. Validate in report-only mode first and check the count before going live.

---

## What else changed

### Deployment moved from portal templates to Bicep plus scripts

| v1 | v2 |
| --- | --- |
| Two ARM templates at the repository root, pasted into the portal | `workflows/*.json` definitions embedded by `infra/main.bicep` |
| Two per-workflow `*_Permissions.sh` scripts, each edited by hand to insert a principal ID | `infra/deploy.sh` and `infra/deploy.ps1` resolve both managed identity IDs automatically |
| Managed identity enabled by hand in the portal after deployment | Declared in Bicep, enabled on deployment |
| Graph app roles assigned once, no retry | Assigned idempotently to both identities, retried 5 times with 15 second waits for directory propagation |

Removed files, all superseded:

```
Logic-EntraIDGuestLCM-MarkGuestsEligibleforRemoval.json
Logic-EntraIDGuestLCM-DeleteGuestUsersAfterGracePeriod.json
Logic-EntraIDGuestLCM-MarkGuestsEligibleforRemoval_Azure_CLI_Permissions.sh
Logic-EntraIDGuestLCM-DeleteGuestUsersAfterGracePeriod_AzureCLIPermissions.sh
```

### Parameters replace hardcoded values

Everything you previously edited inside the workflow JSON is now a deployment
parameter. Nothing is baked into the definition any more.

| Was | Now |
| --- | --- |
| `Threshold` workflow parameter | `InactivityThresholdDays`, set via `inactivityThresholdDays` |
| Never-signed-in guests compared against `Threshold` only | Additionally compared against the new `NewAccountGraceDays` |
| `ReportOnly` defaulted to `false` in the Mark definition | Defaults to `true` in both definitions |
| Hardcoded `westeurope` in the template | `location` parameter, defaults to the resource group location |
| Group object IDs typed into the portal at deploy time | `allGuestsGroupId` and `eligibleForRemovalGroupId` parameters |

The only rename is `Threshold` to `InactivityThresholdDays`. If you scripted
against the workflow parameter names, update that reference.

### Redeploying updates in place

**You do not need to delete anything.** Deploying v2 over an existing v1
installation is an in-place update:

```bash
git pull
./infra/deploy.sh \
  --resource-group <your existing resource group> \
  --all-guests-group-id "<objectId>" \
  --eligible-group-id  "<objectId>"
```

What is preserved and what changes:

| Aspect | Outcome |
| --- | --- |
| Logic App resource | Updated in place, provided you keep the same names. The defaults match the v1 names, so this is automatic unless you renamed them |
| Managed identity object ID | **Preserved.** The identity is not recreated, so the Graph app roles you already granted stay valid |
| Existing Graph app role assignments | Detected and skipped. The script only adds what is missing |
| Run history | Preserved |
| Workflow definition | Replaced wholesale by the version in `workflows/` |
| `ReportOnly` | **Reset to `true`** unless you pass `--report-only false`. This is deliberate: validate the new marking conditions before letting them act |
| Guest state in Entra ID | Untouched. Existing `extensionAttribute14` and `extensionAttribute15` values keep their meaning, so guests already marked continue through the grace period normally |

If you renamed the Logic Apps in v1, pass `markWorkflowName` and
`deleteWorkflowName` so the deployment targets your existing resources instead of
creating new ones alongside them:

```bash
./infra/deploy.sh --resource-group <rg> \
  --all-guests-group-id "<objectId>" --eligible-group-id "<objectId>" \
  --parameters-file my-names.json
```

### New behaviour to be aware of

- **Expiry based marking.** If `extensionAttribute13` already holds dates in your tenant, guests with past dates will be marked on the first v2 run. Check the `expiry` count in a report-only run before going live.
- **Exclusion guard.** Guests with `extensionAttribute15 = "ExcludeFromLCM"` are now skipped by the workflow itself, not only by the group rule. In v1 a guest caught in dynamic membership re-evaluation lag had its exclusion flag permanently overwritten by the mark timestamp; that can no longer happen.
- **Throttling.** Per-item `429` and `5xx` responses inside Graph batches are retried honouring `Retry-After`. Runs may take longer under throttling, and anything still failing after 5 attempts appears in `throttledUnprocessed[]` instead of vanishing.
- **Report schema.** New `reasonCode` on every entry, plus `throttledUnprocessed[]`, `errors[]` and `excluded[]` sections. If you parse the reports, see the schema in the [README](../README.md#-reports).

---

## Suggested migration sequence

1. `git pull` on your existing clone, or clone fresh.
2. Deploy v2 over the existing resource group. `ReportOnly` returns to `true`.
3. Trigger both Logic Apps by hand and read both reports.
4. Compare the marked population against what v1 was producing. Investigate any large `expiry` or `never-signed-in` count before proceeding.
5. Set `--report-only false` for the Mark app, leave Delete in report-only for one cycle.
6. Set `--report-only false` for the Delete app.

Full deployment reference: [deployment.md](deployment.md).
