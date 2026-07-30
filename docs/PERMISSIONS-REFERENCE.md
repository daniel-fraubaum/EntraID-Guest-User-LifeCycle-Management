# Permissions Reference

This document provides a complete reference of all Microsoft Graph API permissions required by each Logic App, including their purpose and how they are used.

## Overview

Both Logic Apps use **System-assigned Managed Identities** to authenticate against the Microsoft Graph API. Permissions are granted as **application-level** app role assignments (not delegated), meaning they operate without user context.

---

## Logic App 1 - Mark Guests Eligible for Removal

### Required Permissions

| Permission | Type | Purpose | Graph API Calls |
|------------|------|---------|-----------------|
| `GroupMember.Read.All` | Application | Read group membership to enumerate guest users | `GET /groups/{id}/members` |
| `User.ReadWrite.All` | Application | Read user profiles (sign-in activity, extension attributes) and write extension attributes (`extensionAttribute14`, `extensionAttribute15`) | `GET /users/{id}` (via batch), `PATCH /users/{id}` (via batch) |
| `AuditLog.Read.All` | Application | Access `signInActivity` property on user objects (requires this permission even when reading via `/users` endpoint) | Included in `GET /users/{id}?$select=signInActivity` |
| `User.EnableDisableAccount.All` | Application | Set `accountEnabled = false` to disable inactive guest accounts | Included in `PATCH /users/{id}` body |

### Graph API Calls Made

| Action | Method | Endpoint | Authentication |
|--------|--------|----------|----------------|
| Get group members (paginated) | `GET` | `/v1.0/groups/{groupId}/members?$select=id&$top=999` | Managed Identity |
| Get user details (batch) | `POST` | `/beta/$batch` containing `GET /users/{id}?$select=id,displayName,userPrincipalName,mail,externalUserState,createdDateTime,signInActivity,accountEnabled` | Managed Identity |
| Disable + mark user (batch) | `POST` | `/beta/$batch` containing `PATCH /users/{id}` with body `{accountEnabled: false, onPremisesExtensionAttributes: {extensionAttribute14: "MarkedEligibleforRemoval", extensionAttribute15: "<timestamp>"}}` | Managed Identity |

---

## Logic App 2 - Delete Guests After Grace Period

### Required Permissions

| Permission | Type | Purpose | Graph API Calls |
|------------|------|---------|-----------------|
| `GroupMember.Read.All` | Application | Read group membership to enumerate marked guest users | `GET /groups/{id}/members` |
| `User.ReadWrite.All` | Application | Read user profiles including `onPremisesExtensionAttributes` and `accountEnabled` | `GET /users/{id}` (via batch) |
| `User.DeleteRestore.All` | Application | Permanently delete (soft-delete) user objects from Entra ID | `DELETE /users/{id}` (via batch) |

### Graph API Calls Made

| Action | Method | Endpoint | Authentication |
|--------|--------|----------|----------------|
| Get group members (paginated) | `GET` | `/v1.0/groups/{groupId}/members?$select=id&$top=999` | Managed Identity |
| Get user details (batch) | `POST` | `/beta/$batch` containing `GET /users/{id}?$select=id,displayName,userPrincipalName,mail,accountEnabled,onPremisesExtensionAttributes` | Managed Identity |
| Delete user (batch) | `POST` | `/beta/$batch` containing `DELETE /users/{id}` | Managed Identity |

---

## Permission Assignment

Permissions are assigned using the Azure CLI scripts provided in the repository. The scripts:

1. Resolve the Microsoft Graph service principal (`appId: 00000003-0000-0000-c000-000000000000`).
2. Validate that the Managed Identity exists.
3. Look up the `appRoleId` for each permission string.
4. Create `appRoleAssignment` entries via the Graph API.

> **⚠️ The two per-workflow permission scripts below have been removed.**
> `infra/deploy.sh` / `infra/deploy.ps1` now assign the app roles to **both**
> managed identities in one idempotent, retrying run. The role lists below are
> retained as a record of what the original scripts granted; the deploy scripts
> grant `AuditLog.Read.All`, `User.ReadWrite.All` and `GroupMember.Read.All` by
> default, overridable with `--roles` / `-Roles`. See
> [deployment.md](deployment.md#microsoft-graph-application-permissions).

### Script: Mark Logic App Permissions

**File:** `Logic-EntraIDGuestLCM-MarkGuestsEligibleforRemoval_Azure_CLI_Permissions.sh` *(removed)*

```bash
graphPermissions=(
  "GroupMember.Read.All"
  "User.ReadWrite.All"
  "AuditLog.Read.All"
  "User.EnableDisableAccount.All"
)
```

### Script: Delete Logic App Permissions

**File:** `Logic-EntraIDGuestLCM-DeleteGuestUsersAfterGracePeriod_AzureCLIPermissions.sh` *(removed)*

```bash
graphPermissions=(
  "GroupMember.Read.All"
  "User.ReadWrite.All"
  "User.DeleteRestore.All"
)
```

---

## Verifying Permissions

### Via Azure CLI

```bash
# Replace with the Managed Identity's Object (principal) ID
miPrincipalId="<your-managed-identity-object-id>"

az rest --method GET \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$miPrincipalId/appRoleAssignments"
```

### Via Entra Admin Center

1. Navigate to **Enterprise applications**.
2. Change the **Application type** filter to **Managed Identities**.
3. Search for your Logic App name.
4. Go to **Permissions** to view the granted API permissions.

---

## Least Privilege Considerations

- Both Logic Apps follow the principle of least privilege - only requesting the minimum set of permissions required for their specific function.
- The two Logic Apps have **separate Managed Identities** with **independent permission sets**, ensuring that the Mark Logic App cannot delete users and the Delete Logic App cannot disable accounts.
- `AuditLog.Read.All` is only granted to Logic App 1 because only it needs to read `signInActivity`.
- `User.EnableDisableAccount.All` is only granted to Logic App 1.
- `User.DeleteRestore.All` is only granted to Logic App 2.

---

## Common Permission Errors

| Error | Cause | Resolution |
|-------|-------|------------|
| HTTP 403 on `GET /groups/{id}/members` | Missing `GroupMember.Read.All` | Re-run the permission script and verify admin consent. |
| HTTP 403 on `PATCH /users/{id}` | Missing `User.ReadWrite.All` or `User.EnableDisableAccount.All` | Re-run the permission script for Logic App 1. |
| HTTP 403 on `DELETE /users/{id}` | Missing `User.DeleteRestore.All` | Re-run the permission script for Logic App 2. |
| `signInActivity` returns `null` for all users | Missing `AuditLog.Read.All` | Grant `AuditLog.Read.All` to Logic App 1's Managed Identity. |
| `"Insufficient privileges to complete the operation"` | Permissions not admin-consented | A Global Admin must grant admin consent in the Entra admin center. |
