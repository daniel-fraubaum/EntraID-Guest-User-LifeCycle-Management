#!/bin/bash

# === Input Variables ===
miPrincipalId="xxxxxxxxxxxxxxxxxxx"
graphPermissions=("GroupMember.Read.All" "User.ReadWrite.All" "User.DeleteRestore.All")  # List desired app permissions here

# === Constants ===
graphAppId="00000003-0000-0000-c000-000000000000"  # Microsoft Graph API AppId (built-in)

# === Check 1: Microsoft Graph SP existence ===
graphSpExists=$(az ad sp show --id "$graphAppId" --only-show-errors 2>/dev/null)
if [[ -z $graphSpExists ]]; then
    echo "❌  Microsoft Graph service principal not found. Deployment cannot proceed."
    exit 1
fi

# === Check 2: Managed Identity existence ===
miSpExists=$(az ad sp show --id "$miPrincipalId" --only-show-errors 2>/dev/null)
if [[ -z $miSpExists ]]; then
    echo "❌  Managed Identity with objectId $miPrincipalId does not exist. Check the input value!"
    exit 1
fi

# === Get Graph SP objectId ===
graphSpId=$(az ad sp show --id "$graphAppId" --query id -o tsv)

# === Loop through permissions and assign them ===
for permission in "${graphPermissions[@]}"; do
    echo "🔄  Assigning permission: $permission"

    appRoleId=$(az ad sp show \
        --id "$graphAppId" \
        --query "appRoles[?value=='$permission' && contains(allowedMemberTypes,'Application')].id | [0]" \
        -o tsv)

    if [[ -z $appRoleId ]]; then
        echo "❌  Could not resolve appRoleId for $permission!"
        continue
    fi

    # Prepare the JSON body for the assignment
    body=$(jq -nc \
        --arg principalId "$miPrincipalId" \
        --arg resourceId "$graphSpId" \
        --arg appRoleId "$appRoleId" \
        '{principalId: $principalId, resourceId: $resourceId, appRoleId: $appRoleId}'
    )

    az rest --method POST \
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$miPrincipalId/appRoleAssignments" \
        --headers "Content-Type=application/json" \
        --body "$body" >/dev/null
done

# === Output current Graph permissions for verification ===
echo "✅  Current Graph permissions assigned to the managed identity:"
az rest --method GET --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$miPrincipalId/appRoleAssignments"
