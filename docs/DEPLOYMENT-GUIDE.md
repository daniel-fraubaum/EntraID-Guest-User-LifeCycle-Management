# Deployment Guide

This guide walks through the complete deployment of both Logic Apps, from prerequisites to verification. Follow the steps in order.

## Table of Contents

- [Prerequisites Checklist](#prerequisites-checklist)
- [Step 1 — Create Dynamic Security Groups](#step-1--create-dynamic-security-groups)
- [Step 2 — Deploy Logic App 1 (Mark Guests)](#step-2--deploy-logic-app-1-mark-guests)
- [Step 3 — Deploy Logic App 2 (Delete Guests)](#step-3--deploy-logic-app-2-delete-guests)
- [Step 4 — Grant Microsoft Graph Permissions](#step-4--grant-microsoft-graph-permissions)
- [Step 5 — Validate with Report-Only Mode](#step-5--validate-with-report-only-mode)
- [Step 6 — Enable Production Mode](#step-6--enable-production-mode)
- [Post-Deployment Checklist](#post-deployment-checklist)

---

## Prerequisites Checklist

Before starting, verify the following:

- [ ] Azure subscription with permissions to create Logic Apps and Managed Identities
- [ ] Entra ID tenant with guest users to manage
- [ ] Global Administrator or Privileged Role Administrator role (required to grant Graph API app roles)
- [ ] Azure CLI (`az`) installed locally or access to Azure Cloud Shell
- [ ] `jq` installed (used by the permission scripts) — pre-installed in Azure Cloud Shell
- [ ] Two free extension attributes available in your tenant (`extensionAttribute14` and `extensionAttribute15`)

> **Warning:** Verify that `extensionAttribute14` and `extensionAttribute15` are not already in use by other applications (e.g., Exchange, HR sync, or other automation). Overwriting existing values can cause unintended side effects.

---

## Step 1 — Create Dynamic Security Groups

Create two dynamic security groups in the [Microsoft Entra admin center](https://entra.microsoft.com):

### Group 1: All Guests

| Setting | Value |
|---------|-------|
| Group type | Security |
| Group name | `GRP_SEC_GuestUserLCM_AllGuests` |
| Membership type | Dynamic User |
| Dynamic membership rule | See below |

**Dynamic rule:**
```
(user.userType -eq "Guest") and (user.extensionAttribute15 -ne "ExcludeFromLCM") and (user.accountEnabled -eq true)
```

### Group 2: Eligible For Removal

| Setting | Value |
|---------|-------|
| Group type | Security |
| Group name | `GRP_SEC_GuestUserLCM_EligibleForRemoval` |
| Membership type | Dynamic User |
| Dynamic membership rule | See below |

**Dynamic rule:**
```
(user.extensionAttribute14 -eq "MarkedEligibleforRemoval") and (user.accountEnabled -eq false)
```

After creating both groups:

1. Wait for the initial membership evaluation to complete (can take up to several minutes).
2. Note the **Object ID** of each group — you will need these during Logic App deployment.

> **Tip:** To permanently exclude a guest user from lifecycle management (e.g., VIPs, service accounts), set `extensionAttribute15 = "ExcludeFromLCM"` on that user. They will be automatically excluded from the `AllGuests` group.

---

## Step 2 — Deploy Logic App 1 (Mark Guests)

1. Open the [Azure Portal](https://portal.azure.com).
2. Navigate to **Deploy a custom template** (search for "Deploy a custom template" in the portal search bar).
3. Click **Build your own template in the editor**.
4. Paste or upload the contents of `Logic-EntraIDGuestLCM-MarkGuestsEligibleforRemoval.json`.
5. Click **Save**.
6. Fill in the deployment parameters:

| Parameter | Description | Recommended Value |
|-----------|-------------|-------------------|
| `LogicApp-Name` | Name of the Logic App resource | `Logic-EntraIDGuestLCM-MarkGuestsEligibleforRemoval` |
| `guestSourceGroupId` | Object ID of `GRP_SEC_GuestUserLCM_AllGuests` | *(your group's Object ID)* |
| `Threshold` | Days of inactivity before marking | `180` |
| `ReportOnly` | Dry-run mode (no changes) | `true` *(start with this!)* |
| `BatchSize` | Users per API batch | `20` |

7. Select the target **Subscription**, **Resource Group**, and **Region**.
8. Click **Review + create**, then **Create**.
9. After deployment succeeds, navigate to the Logic App resource.
10. Go to **Identity** → **System assigned** → set **Status** to **On** → **Save**.
11. Copy the **Object (principal) ID** of the Managed Identity — you will need this for the permission script.

---

## Step 3 — Deploy Logic App 2 (Delete Guests)

Repeat the same deployment process using the second template:

1. Navigate to **Deploy a custom template** again.
2. Paste or upload `Logic-EntraIDGuestLCM-DeleteGuestUsersAfterGracePeriod.json`.
3. Fill in the deployment parameters:

| Parameter | Description | Recommended Value |
|-----------|-------------|-------------------|
| `LogicApp-Name` | Name of the Logic App resource | `Logic-EntraIDGuestLCM-DeleteGuestUsersAfterGracePeriod` |
| `guestSourceGroupId` | Object ID of `GRP_SEC_GuestUserLCM_EligibleForRemoval` | *(your group's Object ID)* |
| `DeletionThresholdDays` | Grace period in days after marking | `30` |
| `ReportOnly` | Dry-run mode (no changes) | `true` *(start with this!)* |
| `BatchSize` | Users per API batch | `20` |

4. Deploy and enable the System-assigned Managed Identity as before.
5. Copy the **Object (principal) ID** for the permission script.

---

## Step 4 — Grant Microsoft Graph Permissions

Each Logic App needs specific Microsoft Graph API application permissions. These are granted via the provided shell scripts.

### For Logic App 1 (Mark Guests)

1. Open **Azure Cloud Shell** (Bash) or a local terminal with `az` CLI.
2. Open the script `Logic-EntraIDGuestLCM-MarkGuestsEligibleforRemoval_Azure_CLI_Permissions.sh`.
3. Replace the placeholder in `miPrincipalId` with the **Object (principal) ID** from Step 2.
4. Run the script.

**Permissions granted:**

| Permission | Purpose |
|------------|---------|
| `GroupMember.Read.All` | Read members of the source dynamic group |
| `User.ReadWrite.All` | Read user details, write extension attributes |
| `AuditLog.Read.All` | Access sign-in activity logs |
| `User.EnableDisableAccount.All` | Disable user accounts |

### For Logic App 2 (Delete Guests)

1. Open the script `Logic-EntraIDGuestLCM-DeleteGuestUsersAfterGracePeriod_AzureCLIPermissions.sh`.
2. Replace the placeholder in `miPrincipalId` with the **Object (principal) ID** from Step 3.
3. Run the script.

**Permissions granted:**

| Permission | Purpose |
|------------|---------|
| `GroupMember.Read.All` | Read members of the source dynamic group |
| `User.ReadWrite.All` | Read user details and extension attributes |
| `User.DeleteRestore.All` | Delete user accounts |

### Verify Permissions

After running each script, verify in the Entra admin center:

1. Go to **Enterprise applications** → filter by **Application type: Managed Identities**.
2. Select the Managed Identity for each Logic App.
3. Go to **Permissions** and verify the listed API permissions match the table above.

> **Important:** If the permissions show as "Not granted for [tenant]", an admin consent may be required. A Global Administrator or Privileged Role Administrator must approve them.

---

## Step 5 — Validate with Report-Only Mode

Before enabling production mode, validate both Logic Apps in dry-run mode:

### Validate Logic App 1

1. Navigate to the Logic App in the Azure Portal.
2. Click **Run Trigger** → **Run** to manually trigger the workflow.
3. Open the run from **Run history**.
4. Inspect the final action (`Generate_JSON_Report`) output:
   - Verify `summary.reportOnlyMode` is `true`.
   - Check `summary.totalAffectedUsers` — are the numbers plausible?
   - Review the `affectedUsers` array — do the listed users match your expectations?
5. Verify the `AllGuests` group contains the users you expect.

### Validate Logic App 2

1. Manually trigger the Delete Logic App.
2. Inspect the `Generate_Final_Report` output:
   - Verify `summary.reportOnlyMode` is `true`.
   - Check `summary.totalMarkedUsersFound` — should be `0` if no users have been marked yet.
3. This is expected to show no users for deletion until Logic App 1 has actually marked users (in production mode).

---

## Step 6 — Enable Production Mode

Once you are satisfied with the report-only results:

1. Navigate to each Logic App.
2. Go to **Logic App Designer** or **Parameters**.
3. Set `ReportOnly` to `false`.
4. Save the Logic App.

> **Recommendation:** Enable production mode for Logic App 1 first. Wait at least one full run cycle (1 week) and verify that users are correctly marked and disabled before enabling Logic App 2.

---

## Post-Deployment Checklist

- [ ] Both Logic Apps deployed and enabled
- [ ] System-assigned Managed Identity enabled on both Logic Apps
- [ ] Graph permissions granted and admin-consented for both Managed Identities
- [ ] Both dynamic security groups created and evaluating correctly
- [ ] Report-only validation completed for both Logic Apps
- [ ] VIP/service accounts excluded via `extensionAttribute15 = "ExcludeFromLCM"`
- [ ] Production mode enabled (Logic App 1 first, then Logic App 2 after validation)
- [ ] Monitoring/alerting configured for Logic App failures (optional but recommended)
- [ ] Run output archival set up (e.g., Log Analytics, Storage Account) (optional)
