# Permissions Reference

This document lists the Microsoft Graph application permissions each Logic App's
managed identity receives, why each one is needed, and which Graph calls use it.

## Overview

Both Logic Apps use **System-assigned Managed Identities** to authenticate against
Microsoft Graph. Permissions are granted as **application** app role assignments
(not delegated), so they work without a signed-in user.

The two identities get **different** role sets. Microsoft Graph has exactly one
application permission that allows `DELETE /users/{id}`: `User.ReadWrite.All`.
The Mark identity does not receive it, so "Mark can disable but never delete" is
enforced by the directory, not only by the workflow logic.

| App role | Mark | Delete |
| --- | :---: | :---: |
| `AuditLog.Read.All` | ✅ | |
| `User.Read.All` | ✅ | |
| `GroupMember.Read.All` | ✅ | ✅ |
| `User.ReadUpdate.All` | ✅ | |
| `User.EnableDisableAccount.All` | ✅ | |
| `User.ReadWrite.All` | | ✅ |

`infra/deploy.sh` / `infra/deploy.ps1` assign these by default. Override them with
`--mark-roles` / `--delete-roles` (`-MarkRoles` / `-DeleteRoles`).

---

## Logic App 1 - Mark Guests Eligible for Removal

### Required Permissions

| Permission | Purpose | Graph API Calls |
|------------|---------|-----------------|
| `GroupMember.Read.All` | Enumerate the members of the All Guests group | `GET /groups/{id}/members` |
| `User.Read.All` | Read user profiles, extension attributes and `createdDateTime` | `GET /users/{id}` (via batch) |
| `AuditLog.Read.All` | Return the `signInActivity` property. Without it Graph omits the property, even with `User.Read.All` | `GET /users/{id}?$select=signInActivity` |
| `User.ReadUpdate.All` | Write `extensionAttribute14` / `extensionAttribute15`. Least privileged application permission for `PATCH /users/{id}`; it does **not** allow deleting users | `PATCH /users/{id}` (via batch) |
| `User.EnableDisableAccount.All` | Set `accountEnabled = false`. Least privileged permission for that property, together with `User.Read.All` | `PATCH /users/{id}` (via batch) |

### Graph API Calls Made

| Action | Method | Endpoint |
|--------|--------|----------|
| Get group members (paginated) | `GET` | `/v1.0/groups/{groupId}/members?$select=id&$top=999` |
| Get user details (batch) | `POST` | `$batch` containing `GET /users/{id}?$select=id,displayName,userPrincipalName,mail,externalUserState,createdDateTime,signInActivity,accountEnabled,onPremisesExtensionAttributes` |
| Disable + mark user (batch) | `POST` | `$batch` containing `PATCH /users/{id}` with body `{accountEnabled: false, onPremisesExtensionAttributes: {extensionAttribute14: "MarkedEligibleforRemoval", extensionAttribute15: "<timestamp>"}}` |

---

## Logic App 2 - Delete Guests After Grace Period

### Required Permissions

| Permission | Purpose | Graph API Calls |
|------------|---------|-----------------|
| `GroupMember.Read.All` | Enumerate the members of the Eligible For Removal group | `GET /groups/{id}/members` |
| `User.ReadWrite.All` | Read `onPremisesExtensionAttributes` and `accountEnabled`, and delete the user. The only application permission for `DELETE /users/{id}` | `GET /users/{id}`, `DELETE /users/{id}` (via batch) |

The Delete workflow never reads `signInActivity`, so it does not need
`AuditLog.Read.All`. `User.DeleteRestore.All` is **not** sufficient for
`DELETE /users/{id}`; the API documents `User.ReadWrite.All` as the only
application permission.

### Graph API Calls Made

| Action | Method | Endpoint |
|--------|--------|----------|
| Get group members (paginated) | `GET` | `/v1.0/groups/{groupId}/members?$select=id&$top=999` |
| Get user details (batch) | `POST` | `$batch` containing `GET /users/{id}?$select=id,displayName,userPrincipalName,mail,accountEnabled,onPremisesExtensionAttributes` |
| Delete user (batch) | `POST` | `$batch` containing `DELETE /users/{id}` |

Neither application permission is enough to disable or delete a user who holds a
privileged administrator role; such users would show up in `errors[]` with `403`.
Guests normally hold no admin roles.

Sources:
[Update user - permissions](https://learn.microsoft.com/graph/api/user-update?view=graph-rest-1.0#permissions) ·
[Delete user - permissions](https://learn.microsoft.com/graph/api/user-delete?view=graph-rest-1.0#permissions) ·
[List users - signInActivity](https://learn.microsoft.com/graph/api/user-list?view=graph-rest-1.0#examples)

---

## Permission Assignment

The deploy scripts:

1. Resolve the Microsoft Graph service principal (`appId: 00000003-0000-0000-c000-000000000000`) and its application app roles.
2. Wait until both managed identities are visible in the directory.
3. Assign each identity its own role list, skipping roles already present.
4. Warn about roles an identity holds beyond its list, or remove them with `--prune-roles` / `-PruneRoles`.
5. On a fresh install, enable the workflows only after the roles are assigned (see below).

### Role timing and token caching

Managed identity tokens are cached by Azure for up to ~24 hours and cannot be
refreshed on demand. A token obtained **before** a role was assigned keeps failing
with `403`; a role **removed** with `--prune-roles` may keep working until the
cached token expires. Because a Recurrence trigger fires once when a workflow is
created or enabled, the scripts deploy a fresh install Disabled and enable it
only after the role assignment. See
[Limitation of using managed identities for authorization](https://learn.microsoft.com/entra/identity/managed-identities-azure-resources/managed-identity-best-practice-recommendations#limitation-of-using-managed-identities-for-authorization).

### Upgrading from earlier role sets

| Installed with | Mark held | Delete held | Run once |
| --- | --- | --- | --- |
| v1 permission scripts | `GroupMember.Read.All`, `User.ReadWrite.All`, `AuditLog.Read.All`, `User.EnableDisableAccount.All` | `GroupMember.Read.All`, `User.ReadWrite.All`, `User.DeleteRestore.All` | `./infra/deploy.sh --resource-group RG --skip-infra --prune-roles` |
| v2.0 deploy scripts before the split | `AuditLog.Read.All`, `User.ReadWrite.All`, `GroupMember.Read.All` | the same | the same |

The v1 per-workflow permission scripts
(`Logic-EntraIDGuestLCM-*_Permissions.sh`) have been removed.

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

## Common Permission Errors

| Error | Cause | Resolution |
|-------|-------|------------|
| HTTP 403 on `GET /groups/{id}/members` | Missing `GroupMember.Read.All`, or a token cached from before the assignment | `./infra/deploy.sh --resource-group RG --skip-infra`; if the role is present, see [Role timing](#role-timing-and-token-caching) |
| HTTP 403 on `PATCH /users/{id}` (Mark) | Missing `User.ReadUpdate.All` or `User.EnableDisableAccount.All` | Re-run with `--skip-infra` |
| HTTP 403 on `DELETE /users/{id}` (Delete) | Missing `User.ReadWrite.All` | Re-run with `--skip-infra` |
| `signInActivity` missing for all users | Missing `AuditLog.Read.All` on the Mark identity, or no Entra ID P1/P2 license | Grant the role; check licensing |
| `Failed to assign <role>` during deployment | The account running the script lacks Privileged Role Administrator / Global Administrator | Have an eligible admin re-run with `--skip-infra` |
