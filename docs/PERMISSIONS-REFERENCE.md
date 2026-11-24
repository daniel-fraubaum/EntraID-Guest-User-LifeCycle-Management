# Permissions Reference

This document lists the Microsoft Graph application permissions each Logic App's
managed identity receives, why each one is needed, and which Graph calls use it.

## Overview

Both Logic Apps use **System-assigned Managed Identities** to authenticate against
Microsoft Graph. Permissions are granted as **application** app role assignments
(not delegated), so they work without a signed-in user.

| App role | Mark | Delete |
| --- | :---: | :---: |
| `AuditLog.Read.All` | ✅ | |
| `GroupMember.Read.All` | ✅ | ✅ |
| `User.ReadWrite.All` | ✅ | ✅ |

### Why Mark holds `User.ReadWrite.All`

Mark writes `onPremisesExtensionAttributes` (`extensionAttribute14` / `15`). A
narrower set was tested against a live tenant with the Mark identity:

| Call | `User.ReadUpdate.All` + `User.EnableDisableAccount.All` + `User.Read.All` |
| --- | --- |
| `PATCH` `accountEnabled` | `204` |
| `PATCH` an ordinary property (`jobTitle`) | `204` |
| `PATCH` `onPremisesExtensionAttributes` | **`403`** |
| `DELETE /users/{id}` | `403` |

The only other application permission that can write the extension attributes
is `Directory.ReadWrite.All`. It cannot delete users or groups, but it can write
almost everything else in the directory, and Microsoft recommends resource
specific permissions over directory permissions. `User.ReadWrite.All` is the
narrower choice overall.

The consequence: `User.ReadWrite.All` also allows `DELETE /users/{id}`, the
single application permission for that call. "Mark can disable but never
delete" is therefore a property of the Mark workflow definition, not of its
permissions. Anyone who can edit the Mark Logic App (Logic App Contributor,
Contributor or Owner on its resource group) can make it delete guests.

`infra/deploy.sh` / `infra/deploy.ps1` assign these by default. Override them with
`--mark-roles` / `--delete-roles` (`-MarkRoles` / `-DeleteRoles`).

---

## Logic App 1 - Mark Guests Eligible for Removal

### Required Permissions

| Permission | Purpose | Graph API Calls |
|------------|---------|-----------------|
| `GroupMember.Read.All` | Enumerate the members of the All Guests group | `GET /groups/{id}/members` |
| `AuditLog.Read.All` | Return the `signInActivity` property. Without it Graph omits the property | `GET /users/{id}?$select=signInActivity` |
| `User.ReadWrite.All` | Read user profiles; write `accountEnabled = false` and `extensionAttribute14` / `extensionAttribute15` (see above for why nothing narrower works) | `GET /users/{id}`, `PATCH /users/{id}` (via batch) |

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
| v1 permission scripts | `GroupMember.Read.All`, `User.ReadWrite.All`, `AuditLog.Read.All`, `User.EnableDisableAccount.All` (extra) | `GroupMember.Read.All`, `User.ReadWrite.All`, `User.DeleteRestore.All` (extra) | `./infra/deploy.sh --resource-group RG --skip-infra --prune-roles` |
| v2.0 deploy scripts before the per-identity lists | `AuditLog.Read.All`, `User.ReadWrite.All`, `GroupMember.Read.All` (matches) | the same, `AuditLog.Read.All` extra | the same |

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
| HTTP 403 on `PATCH /users/{id}` (Mark) | Missing `User.ReadWrite.All` on the Mark identity. `User.ReadUpdate.All` is not enough for `onPremisesExtensionAttributes` | Re-run with `--skip-infra` |
| HTTP 403 on `DELETE /users/{id}` (Delete) | Missing `User.ReadWrite.All` | Re-run with `--skip-infra` |
| `signInActivity` missing for all users | Missing `AuditLog.Read.All` on the Mark identity, or no Entra ID P1/P2 license | Grant the role; check licensing |
| `Failed to assign <role>` during deployment | The account running the script lacks Privileged Role Administrator / Global Administrator | Have an eligible admin re-run with `--skip-infra` |
