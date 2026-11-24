# Security Policy

## Supported Versions

| Version | Supported |
| ------- | --------- |
| latest  | Yes       |

## Reporting a Vulnerability

If you discover a security vulnerability in this project, **please do not open a public issue**. Instead, report it responsibly:

1. **Email the maintainer** with a detailed description of the vulnerability.
2. Include:
   - The affected component (Logic App template, shell script, documentation).
   - Steps to reproduce the issue.
   - The potential impact.
   - Any suggested remediation (optional).
3. Allow reasonable time for a fix before public disclosure.

## Security Considerations

This solution manages Entra ID guest user accounts with elevated privileges. The following security practices are built in and should be maintained:

### Authentication & Authorization

- **Managed Identity only** - Both Logic Apps authenticate to Microsoft Graph using System-assigned Managed Identities. No client secrets, certificates, or tokens are stored.
- **Least-privilege Graph permissions** - Each Logic App requests only the minimum Microsoft Graph app roles required:
  - Mark Logic App: `AuditLog.Read.All`, `GroupMember.Read.All`, `User.ReadWrite.All` - needed to write the extension attributes; it also allows deleting users, so protect write access to the Logic App
  - Delete Logic App: `GroupMember.Read.All`, `User.ReadWrite.All` (the only application permission for `DELETE /users/{id}`)
  - See [docs/PERMISSIONS-REFERENCE.md](docs/PERMISSIONS-REFERENCE.md)
- **No shared credentials** - Each Logic App has its own Managed Identity with independently scoped permissions.

### Data Protection

- **No secrets in templates** - ARM templates contain no passwords, keys, or tokens.
- **No PII in source code** - All user data is processed at runtime and emitted only in Logic App run outputs, which are stored in the Azure platform (subject to your Azure retention and compliance settings).
- **Report-only mode** - `ReportOnly = true` (the default) prevents any write or delete operations during dry runs.

### Operational Safety

- **Grace period before deletion** - Users are first disabled and tagged, then deleted only after the configurable `DeletionThresholdDays` waiting period.
- **Exclusion mechanism** - Critical accounts can be permanently excluded by setting `extensionAttribute15 = "ExcludeFromLCM"`.
- **Batch size limits** - The `BatchSize` parameter (1-100) controls throughput and reduces the blast radius of any misconfiguration.
- **Automatic retry with backoff** - All HTTP calls to Microsoft Graph use exponential retry policies to handle transient errors gracefully.
- **Explicit error handling** - Rate limiting (HTTP 429), permission errors (HTTP 403), and other failures are caught, logged, and cause the Logic App to terminate with a clear error message.

### Recommendations

- **Restrict Logic App access** - Use Azure RBAC to limit who can view, edit, or trigger the Logic Apps.
- **Audit run history** - Regularly review Logic App run outputs for unexpected behavior.
- **Export reports** - Consider forwarding run outputs to Azure Log Analytics or a Storage Account for long-term audit trails.
- **Test before production** - Always deploy and validate in a non-production tenant first using `ReportOnly = true`.
- **Monitor Managed Identity permissions** - Periodically review the Graph API app role assignments on each Managed Identity to ensure no permission drift.
- **Do not extend permissions** - Avoid granting additional Graph permissions beyond what is documented; this increases the attack surface if the Managed Identity is compromised.
