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
3. **Expected behavior** — What did you expect to happen?
4. **Actual behavior** — What actually happened?
5. **Run output** — Include the JSON report from the Logic App run history (redact any sensitive user data such as UPNs or object IDs).
6. **Error messages** — Copy the full error from the Logic App run details if applicable.

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
2. **Make your changes** — keep them focused and minimal. One PR per feature or fix.
3. **Test thoroughly** — deploy and test in a non-production tenant before submitting.
4. **Update documentation** — if your change affects behavior, parameters, or deployment steps, update the relevant documentation.
5. **Submit the PR** with a clear description:
   - What changed and why.
   - How it was tested.
   - Any breaking changes or migration steps.
6. **Respond to feedback** — maintainers may request changes before merging.

---

## Development Guidelines

### Logic App Templates (ARM JSON)

- Use descriptive action names (e.g., `Check_If_Inactive`, `Execute_DisableBatch`).
- Include `metadata.description` for all template parameters.
- Set sensible `defaultValue` entries for all parameters.
- Use `retryPolicy` with exponential backoff on all HTTP actions.
- Handle all HTTP error status codes explicitly (400, 401, 403, 404, 429, 500, 503).
- Use `ManagedServiceIdentity` authentication — never embed secrets or tokens.

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

1. **Deploy both Logic Apps** to a test Azure subscription.
2. **Run in `ReportOnly = true` mode** first and verify the JSON output.
3. **Run in `ReportOnly = false` mode** in a non-production tenant with test guest users.
4. **Verify Graph API permissions** by running the corresponding shell script.
5. **Check edge cases:**
   - Empty group (no members)
   - Group with a single member
   - Users with no sign-in activity data
   - Users already marked/disabled
   - Rate limiting behavior (large batch sizes)

---

## Questions?

If you have questions that aren't covered here, feel free to open a GitHub issue with the label `question`.
