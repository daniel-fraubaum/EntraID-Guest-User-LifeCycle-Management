# Frequently Asked Questions (FAQ)

## General

### What is this solution?

This solution automates the lifecycle management of guest (B2B) users in Microsoft Entra ID. It identifies inactive guest users, disables and marks them for removal, and - after a configurable grace period - deletes them. It uses two Azure Logic Apps and requires no premium Entra ID licenses.

### Why not use Entra ID Access Reviews or Identity Governance?

Entra ID Access Reviews and Identity Governance are excellent tools but require **Entra ID Premium P2** or **Entra ID Governance** licenses, which come at additional cost. This solution provides similar functionality for guest user cleanup without any premium license requirement.

### Does this work with Entra ID Free / P1?

Yes. The solution relies only on Azure Logic Apps (Consumption tier), Microsoft Graph API, System-assigned Managed Identities, and dynamic security groups. No Entra ID Premium P2 or Governance license is required.

### Can I use this for member (non-guest) users?

The solution is designed specifically for guest users (`userType = "Guest"`). It could be adapted for member users, but this is not recommended without careful consideration of the impact and additional safeguards. The dynamic group rules explicitly filter for `user.userType -eq "Guest"`.

---

## Deployment

### Which Azure region should I deploy to?

The ARM templates default to `westeurope`. You can change this to any region that supports Azure Logic Apps (Consumption). The region does not affect which Entra ID tenant is managed - that is determined by the Managed Identity.

### Can I deploy both Logic Apps to the same Resource Group?

Yes. Both Logic Apps can coexist in the same Resource Group. They are independent resources with separate Managed Identities.

### Do I need to create the dynamic groups before deploying the Logic Apps?

Yes. You must create the dynamic groups first and have their Object IDs ready before deploying the Logic Apps, because the group Object ID is a required parameter.

### Can I rename the Logic Apps?

Yes. The `LogicApp-Name` parameter in each template can be customized to any valid Azure resource name. The internal logic does not depend on the resource name.

---

## Configuration

### What is a good value for `Threshold`?

The default is `180` days (6 months). This means guest users who have not signed in for 180 days will be flagged. Adjust based on your organization's guest user policies:
- **90 days** - aggressive, suitable for short-lived collaboration.
- **180 days** - balanced default for most organizations.
- **365 days** - conservative, allows for seasonal or annual collaborators.

### What is a good value for `DeletionThresholdDays`?

The default is `30` days. This is the grace period between marking a user and deleting them. During this time, the user is disabled but not yet deleted, giving administrators time to review and exclude any false positives. Adjust based on your review cadence:
- **14 days** - fast cleanup, requires frequent review.
- **30 days** - balanced default.
- **60-90 days** - conservative, allows extended review time.

### What does `ReportOnly` do?

When set to `true` (the default), the Logic Apps evaluate users and generate a JSON report but do **not** modify any user accounts. No accounts are disabled, no attributes are changed, and no users are deleted. This is equivalent to a "dry run" or "what-if" mode.

### What `BatchSize` should I use?

The default is `20`, which is a safe starting point. The maximum is `100` (limited by the Microsoft Graph batch API). Considerations:
- **Smaller batches (5-10):** Safer for initial testing; lower risk of rate limiting.
- **Default (20):** Good balance between throughput and safety.
- **Larger batches (50-100):** Higher throughput but increased risk of hitting Graph API rate limits (HTTP 429).

---

## Extension Attributes

### Why `extensionAttribute14` and `extensionAttribute15`?

These are two of the 15 on-premises extension attributes available on Entra ID user objects. They were chosen because they are commonly unused, but you can modify the Logic App templates to use different attributes if needed.

### Can I use different extension attributes?

Yes, but you would need to modify both Logic App templates (JSON) and the dynamic group membership rules accordingly. Search for `extensionAttribute14` and `extensionAttribute15` in the templates and replace them consistently.

### What happens if `extensionAttribute15` is already in use?

If `extensionAttribute15` is used by another application (e.g., for Exchange Online custom attributes or HR sync), this solution will overwrite those values when marking users. **Always verify** that the chosen extension attributes are available before deployment. See also the note in the main README about the dual-purpose nature of `extensionAttribute15`.

### How do I exclude a user from lifecycle management?

Set `extensionAttribute15 = "ExcludeFromLCM"` on the user object. This removes the user from the `AllGuests` dynamic group, so they will never be evaluated by Logic App 1.

You can set this via the Microsoft Graph API, PowerShell, or the Entra admin center:

```powershell
# PowerShell (Microsoft.Graph module)
Update-MgUser -UserId "<user-object-id>" -OnPremisesExtensionAttributes @{
    extensionAttribute15 = "ExcludeFromLCM"
}
```

---

## Operations

### How do I monitor the Logic Apps?

- **Azure Portal:** Navigate to each Logic App → **Run history** to see past executions and their status (Succeeded / Failed).
- **Alerts:** Configure Azure Monitor alerts on Logic App failures to receive email or Teams notifications.
- **Log Analytics:** Optionally enable diagnostic settings to forward Logic App logs to a Log Analytics workspace.

### What happens if a Logic App run fails?

The run is marked as "Failed" in the run history with a detailed error message. Common failure causes:
- Graph API rate limiting (HTTP 429)
- Permission errors (HTTP 403)
- Invalid group ID (HTTP 404)

Failed runs do not leave the system in an inconsistent state - partial progress is captured in the report, and the next scheduled run will re-evaluate all users.

### Can I run the Logic Apps manually?

Yes. Navigate to the Logic App in the Azure Portal and click **Run Trigger** → **Run**. This is recommended for initial testing.

### What happens if both Logic Apps run at the same time?

They should not overlap because they are scheduled 2 hours apart by default (01:00 and 03:00). If they do overlap, there is no data corruption risk because they target different groups and different user states. However, dynamic group membership may not have fully updated, so users recently marked by Logic App 1 might not yet appear in the `EligibleForRemoval` group for Logic App 2.

### Can I restore a deleted user?

Yes. Deleted users go to the Entra ID **Deleted Users** recycle bin and can be restored within **30 days**. After 30 days, the deletion is permanent.

To restore via the Entra admin center:
1. Navigate to **Users** → **Deleted users**.
2. Select the user and click **Restore user**.

To restore via PowerShell:
```powershell
Restore-MgDirectoryDeletedItem -DirectoryObjectId "<user-object-id>"
```

---

## Troubleshooting

### No users are being marked - the report shows 0 affected users

1. **Check group membership:** Verify that `GRP_SEC_GuestUserLCM_AllGuests` contains members. Wait for dynamic group evaluation to complete.
2. **Verify permissions:** Ensure `AuditLog.Read.All` is granted - without it, `signInActivity` will be `null` and users won't be detected as inactive.
3. **Check threshold:** If `Threshold` is set to 365 days, only users inactive for over a year will be flagged. Try a shorter threshold for testing.
4. **Verify user state:** The Logic App skips users where `accountEnabled = false`. If users are already disabled, they won't be processed.

### Users are marked but not deleted

1. **Verify group membership:** Check that marked users appear in `GRP_SEC_GuestUserLCM_EligibleForRemoval`. The dynamic rule requires both `extensionAttribute14 = "MarkedEligibleforRemoval"` **and** `accountEnabled = false`.
2. **Check grace period:** The `DeletionThresholdDays` must have elapsed since the `extensionAttribute15` timestamp. For the default of 30 days, users must have been marked at least 30 days ago.
3. **Verify permissions:** Ensure `User.ReadWrite.All` is granted to Logic App 2's Managed Identity. `User.DeleteRestore.All` is not sufficient for `DELETE /users/{id}`.

### Graph API returns HTTP 429 (rate limiting)

1. Reduce `BatchSize` (e.g., from 20 to 10).
2. Ensure the schedule does not coincide with other automated Graph API workloads.
3. The Logic Apps have built-in exponential retry (3 retries, 20s base interval), but persistent 429 errors will cause the run to fail gracefully.

### The permission script fails

1. Ensure you are logged in to the correct Azure tenant: `az account show`.
2. Verify you have sufficient permissions (Global Admin or Privileged Role Admin).
3. Ensure `jq` is installed: `jq --version`.
4. Verify the `miPrincipalId` is the **Object (principal) ID** of the Managed Identity (not the application/client ID).

### Extension attributes are not being written

1. Verify `User.ReadUpdate.All` and `User.EnableDisableAccount.All` are granted to Logic App 1's Managed Identity.
2. Check that `ReportOnly` is set to `false` - in report-only mode, no attributes are written.
3. Inspect the Logic App run details for the `Execute_DisableBatch` action to see if it succeeded.
