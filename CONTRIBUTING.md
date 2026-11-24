# Contributing to Entra ID Guest User Lifecycle Management

Thank you for your interest in contributing to this project! Whether you're reporting a bug, suggesting a feature, or submitting a pull request, your help is appreciated.

## Table of Contents

- [Code of Conduct](#code-of-conduct)
- [How to Report Issues](#how-to-report-issues)
- [How to Suggest Features](#how-to-suggest-features)
- [Pull Request Process](#pull-request-process)
- [Development Guidelines](#development-guidelines)
- [Testing](#testing)

---

## Code of Conduct

This project follows standard open-source community guidelines. Be respectful, constructive, and collaborative. Harassment, discrimination, or abusive behavior will not be tolerated.

---

## How to Report Issues

When filing an issue, please include:

1. **Environment details**
   - Azure region
   - Entra ID tenant type (e.g., production, dev/test)
   - Logic App runtime version (if known)
2. **Steps to reproduce**
   - Which Logic App was affected (Mark or Delete)?
   - What parameters were used (`ReportOnly`, `Threshold`, `BatchSize`, etc.)?
   - Was it a scheduled or manual run?
3. **Expected behavior** - What did you expect to happen?
4. **Actual behavior** - What actually happened?
5. **Run output** - Include the JSON report from the Logic App run history (redact any sensitive user data such as UPNs or object IDs).
6. **Error messages** - Copy the full error from the Logic App run details if applicable.

> **Important:** Never share tenant IDs, real user principal names, or Managed Identity credentials in public issues. Redact or anonymize all sensitive information.

---

## How to Suggest Features

Open a GitHub issue with the label `enhancement` and include:

- A clear description of the feature or improvement.
- The problem it solves or the use case it addresses.
- Any implementation ideas or references (optional).

---

## Pull Request Process

1. **Fork** the repository and create a feature branch from `main`.
2. **Make your changes** - keep them focused and minimal. One PR per feature or fix.
3. **Test thoroughly** - deploy and test in a non-production tenant before submitting.
4. **Update documentation** - if your change affects behavior, parameters, or deployment steps, update the relevant documentation.
5. **Submit the PR** with a clear description:
   - What changed and why.
   - How it was tested.
   - Any breaking changes or migration steps.
6. **Respond to feedback** - maintainers may request changes before merging.

---

## Development Guidelines

### ⚠️ Both workflows sit at the nesting depth limit

**Read this before adding any condition to a workflow definition.**

Azure Logic Apps caps
[**actions nesting depth at 8**](https://learn.microsoft.com/azure/logic-apps/logic-apps-limits-and-config#workflow-limits).
Both workflows in `workflows/` are already at **exactly 8**:

```
Mark:   Check_If_Members_Exist / Do_Until_Process_All_Batches / For_each_BatchResponse /
        Check_Response_Success / Process_User_If_Enabled / Check_If_Inactive /
        Add_Inactive_To_Disable / Append_Disable_Inactive           <- depth 8

Delete: Check_If_Members_Exist / Do_Until_Process_All_Batches / For_each_BatchResponse /
        Check_Response_Success / Check_If_Marked_For_Deletion / Check_If_Past_Threshold /
        Add_To_Delete_Batch / Append_Delete_Request                  <- depth 8
```

There is **no headroom left on those paths.** Wrapping the per-user logic in one
more `If` produces depth 9, which Azure rejects at deployment time.

So when you add a condition to the per-user evaluation path:

- ❌ **Do not** add a nested `If` around existing actions.
- ✅ **Do** merge the new test into an existing condition's `expression`, as an
  extra clause in its `and` / `or` array.
- ✅ **Do** add a **sibling** action at the same level when you need separate
  actions, for example a counter or a report append, rather than nesting.

The exclusion guard is the worked example. It needed to skip a guest and count it,
and both parts had to fit without adding a level:

```jsonc
// The skip: an extra clause on the condition that already existed.
"Process_User_If_Enabled": {
  "expression": { "and": [
    { "not": { "equals": ["@item()?['body']?['accountEnabled']", false] } },
    { "not": { "equals": ["@toLower(trim(...extensionAttribute15...))", "excludefromlcm"] } }
  ] }
}

// The count: a sibling of Process_User_If_Enabled, not a wrapper around it.
"Check_Is_Excluded": { "runAfter": { "Increment_TotalProcessed": ["Succeeded"] }, ... }
```

Other limits worth knowing, both with plenty of headroom today: **500 actions per
workflow** (currently 147 and 120) and an **8,192 character limit per expression**.

**The validator enforces all of this.** Run it after any change to a workflow
definition; it exits non-zero on a violation:

```bash
python3 scripts/validate-workflows.py
```

It fails on nesting depth over 8, action count over 500, a `runAfter` pointing at a
non-sibling, a `runAfter` cycle, an invalid `runAfter` status, a parameter that is
referenced but not declared **or** declared but never used, a variable read before
the action that initializes it, unbalanced expression parentheses or quotes, an
expression over 8,192 characters, a `SetVariable` whose value reads the same
variable, a `Select` / `Query` `from` or a `Foreach` input that lacks the leading
`@`, `createArray()` without arguments, and any `outputs()` / `body()` / `actions()`
reference that reaches across a scope boundary.

The scope rule matters more than it sounds: referencing an action inside an
`Until` loop from outside it is accepted by Azure but silently reads only the
final iteration.

The `SetVariable`, missing `@` and `createArray()` rules are not style rules
either: Azure rejects the first two when the workflow is saved, and
`createArray()` passes the save but fails the action at runtime. Use these forms
instead:

```jsonc
// Instead of SetVariable X = @union(variables('X'), body('Y')):
"Compose_Aggregate": { "type": "Compose", "inputs": "@union(variables('X'), body('Y'))" },
"Aggregate":         { "type": "SetVariable", "inputs": { "name": "X", "value": "@outputs('Compose_Aggregate')" },
                       "runAfter": { "Compose_Aggregate": ["Succeeded"] } }

// An empty array:
"@coalesce(body('Y')?['value'], json('[]'))"
```

It also prints notes for scopes with parallel entry points. Those are legal, but
parallel branches writing the same variable race, so check any you add.

### Logic App Templates (ARM JSON)

- Use descriptive action names (e.g., `Check_If_Inactive`, `Execute_DisableBatch`).
- Include `metadata.description` for all template parameters.
- Set sensible `defaultValue` entries for all parameters.
- Use `retryPolicy` with exponential backoff on all HTTP actions.
- Handle all HTTP error status codes explicitly (400, 401, 403, 404, 429, 500, 503).
- Use `ManagedServiceIdentity` authentication - never embed secrets or tokens.

### Shell Scripts

- Include input validation (check for empty variables, verify service principal existence).
- Use `az` CLI commands with `--only-show-errors` where appropriate.
- Provide clear console output (success/failure indicators).

### General

- Keep the solution license-free (no Entra ID Premium dependencies).
- Maintain backward compatibility whenever possible.
- Follow the existing naming conventions for files and resources.

---

## Testing

Before submitting a PR, verify your changes:

1. **Validate the workflow definitions**: `python3 scripts/validate-workflows.py`.
   This is fast, needs no Azure access, and catches the limits and scope mistakes
   described above.
2. **Compile the infrastructure**: `az bicep build --file infra/main.bicep`.
3. **Deploy both Logic Apps** to a test Azure subscription: `./infra/deploy.sh --resource-group <test-rg> ...`.
4. **Run in `ReportOnly = true` mode** first and verify the JSON output, including that `throttledUnprocessed[]`, `errors[]` and `excluded[]` are as expected.
5. **Run in `ReportOnly = false` mode** in a non-production tenant with test guest users.
6. **Verify Graph API permissions** are present on both managed identities: `./infra/deploy.sh --resource-group <test-rg> --skip-infra` reports what is already assigned.
7. **Check edge cases:**
   - Empty group (no members)
   - Group with a single member
   - Users with no sign-in activity data
   - Users already marked/disabled
   - Users with `extensionAttribute15 = "ExcludeFromLCM"` (must never be marked)
   - Users with an unparseable `extensionAttribute13` (must never be marked)
   - Rate limiting behavior (large batch sizes), including per-item `429` inside a batch

---

## Questions?

If you have questions that aren't covered here, feel free to open a GitHub issue with the label `question`.
