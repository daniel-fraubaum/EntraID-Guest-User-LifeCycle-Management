<#
.SYNOPSIS
    Deploy the Entra ID guest lifecycle solution: resource group, both Consumption
    Logic Apps (via main.bicep), and the Microsoft Graph app roles their managed
    identities need.

.DESCRIPTION
    PowerShell counterpart of deploy.sh with identical behaviour and switches.
    Everything is idempotent — re-running converges rather than duplicating.
    Directory writes (managed identity service principals, app role assignments)
    replicate asynchronously, so every directory lookup and the role assignment
    itself is retried $RetryAttempts times with $RetryWaitSeconds between tries.

    Uses the az CLI (not the Az PowerShell modules) so both scripts behave the
    same. Requires an authenticated az session.

.EXAMPLE
    # First deployment, safe by default (ReportOnly = true)
    ./deploy.ps1 -ResourceGroup rg-guest-lcm `
                 -AllGuestsGroupId <guid> -EligibleGroupId <guid>

.EXAMPLE
    # Re-assign Graph roles only (e.g. after a role was revoked)
    ./deploy.ps1 -ResourceGroup rg-guest-lcm -SkipInfra

.EXAMPLE
    # Go live: flip ReportOnly off without redeploying the workflows
    ./deploy.ps1 -ResourceGroup rg-guest-lcm -SkipInfra -ReportOnly false
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $ResourceGroup,

    [string] $Location = 'westeurope',

    [string] $Subscription,

    [string] $AllGuestsGroupId,

    [string] $EligibleGroupId,

    [string] $ParametersFile,

    # Dry-run switch. With -SkipInfra this updates ONLY the ReportOnly parameter
    # on both existing workflows and leaves the definitions untouched.
    [ValidateSet('true', 'false')]
    [string] $ReportOnly,

    # AuditLog.Read.All + User.ReadWrite.All are the two roles the workflows
    # cannot function without: signInActivity is gated behind AuditLog.Read.All,
    # and disabling/deleting a guest needs User.ReadWrite.All.
    # GroupMember.Read.All is included because both definitions enumerate
    # /groups/{id}/members to find the users to evaluate.
    [string[]] $Roles = @('AuditLog.Read.All', 'User.ReadWrite.All', 'GroupMember.Read.All'),

    [switch] $SkipInfra,

    [switch] $SkipPermissions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$GraphAppId = '00000003-0000-0000-c000-000000000000'
$WorkflowApiVersion = '2019-05-01'
$RetryAttempts = 5
$RetryWaitSeconds = 15
$DeploymentName = "entraid-guest-lcm-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"

function Write-Section { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Info    { param([string] $Message) Write-Host "    $Message" }
function Write-Warn    { param([string] $Message) Write-Warning $Message }
function Stop-WithError { param([string] $Message) throw $Message }

# Runs an az command, returning trimmed stdout. Retries on failure.
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [string[]] $AzArgs,
        # When set, an empty result also counts as failure. This is what makes
        # directory propagation tolerable: a lookup that succeeds with an empty
        # body is retried instead of being passed on as an empty id.
        [switch] $RequireOutput
    )
    for ($attempt = 1; $attempt -le $RetryAttempts; $attempt++) {
        $output = & az @AzArgs 2>$null
        $joined = ($output | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and (-not $RequireOutput -or ($joined -and $joined -ne 'null'))) {
            return $joined
        }
        if ($RequireOutput -and $LASTEXITCODE -eq 0) {
            Write-Warn "$Description returned nothing yet (attempt $attempt/$RetryAttempts)."
        }
        else {
            Write-Warn "$Description failed (attempt $attempt/$RetryAttempts)."
        }
        if ($attempt -eq $RetryAttempts) { return $null }
        Start-Sleep -Seconds $RetryWaitSeconds
    }
    return $null
}

function Assert-Id {
    param([string] $Label, [string] $Value)
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value -eq 'null') {
        Stop-WithError "$Label is empty - refusing to call the API with an empty id."
    }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) {
    Stop-WithError 'az CLI not found. See https://learn.microsoft.com/cli/azure/install-azure-cli'
}

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path

# --- subscription ------------------------------------------------------------

if ($Subscription) {
    Write-Section "Selecting subscription $Subscription"
    az account set --subscription $Subscription | Out-Null
}
$AccountName = Invoke-WithRetry -Description 'Reading the current subscription' -RequireOutput `
    -AzArgs @('account', 'show', '--query', 'name', '-o', 'tsv')
if (-not $AccountName) { Stop-WithError 'Not logged in. Run: az login' }
Write-Info "Subscription: $AccountName"

# --- infrastructure ----------------------------------------------------------

if ($SkipInfra) {
    Write-Section 'Skipping infrastructure (-SkipInfra)'
}
else {
    if (-not $AllGuestsGroupId -and -not $ParametersFile) {
        Stop-WithError '-AllGuestsGroupId (or -ParametersFile) is required unless -SkipInfra is set.'
    }
    if (-not $EligibleGroupId -and -not $ParametersFile) {
        Stop-WithError '-EligibleGroupId (or -ParametersFile) is required unless -SkipInfra is set.'
    }

    Write-Section "Ensuring resource group $ResourceGroup in $Location"
    az group create --name $ResourceGroup --location $Location --output none
    if ($LASTEXITCODE -ne 0) { Stop-WithError "Could not create resource group $ResourceGroup." }
    Write-Info 'Resource group ready.'

    $deployArgs = @(
        'deployment', 'group', 'create',
        '--resource-group', $ResourceGroup,
        '--name', $DeploymentName,
        '--template-file', (Join-Path $ScriptDir 'main.bicep')
    )
    if ($ParametersFile)   { $deployArgs += @('--parameters', "@$ParametersFile") }
    # Explicit switches win over the parameters file, so they come last.
    if ($AllGuestsGroupId) { $deployArgs += @('--parameters', "allGuestsGroupId=$AllGuestsGroupId") }
    if ($EligibleGroupId)  { $deployArgs += @('--parameters', "eligibleForRemovalGroupId=$EligibleGroupId") }
    if ($ReportOnly)       { $deployArgs += @('--parameters', "reportOnly=$ReportOnly") }

    Write-Section 'Deploying main.bicep'
    az @deployArgs --output none
    if ($LASTEXITCODE -ne 0) { Stop-WithError 'Bicep deployment failed.' }
    Write-Info "Deployment $DeploymentName complete."
}

# --- resolve workflow names + managed identity principal ids -----------------

Write-Section 'Resolving workflow managed identities'

$MarkName = $null
$DeleteName = $null

if (-not $SkipInfra) {
    $outputsJson = Invoke-WithRetry -Description 'Reading deployment outputs' -RequireOutput `
        -AzArgs @('deployment', 'group', 'show', '--resource-group', $ResourceGroup,
                  '--name', $DeploymentName, '--query', 'properties.outputs', '-o', 'json')
    if (-not $outputsJson) { Stop-WithError 'Could not read deployment outputs.' }
    $outputs = $outputsJson | ConvertFrom-Json
    $MarkName = $outputs.markWorkflowName.value
    $DeleteName = $outputs.deleteWorkflowName.value
}

# On -SkipInfra there is no deployment to read, so discover the workflows in the
# resource group by the naming convention.
if (-not $MarkName -or -not $DeleteName) {
    $listJson = Invoke-WithRetry -Description 'Listing Logic Apps in the resource group' -RequireOutput `
        -AzArgs @('resource', 'list', '--resource-group', $ResourceGroup,
                  '--resource-type', 'Microsoft.Logic/workflows', '--query', '[].name', '-o', 'json')
    if (-not $listJson) { Stop-WithError "No Logic Apps found in $ResourceGroup." }
    $names = @($listJson | ConvertFrom-Json)
    if (-not $MarkName)   { $MarkName   = $names | Where-Object { $_ -match 'Mark' }   | Select-Object -First 1 }
    if (-not $DeleteName) { $DeleteName = $names | Where-Object { $_ -match 'Delete' } | Select-Object -First 1 }
}

Assert-Id 'Mark workflow name' $MarkName
Assert-Id 'Delete workflow name' $DeleteName
Write-Info "Mark workflow:   $MarkName"
Write-Info "Delete workflow: $DeleteName"

function Get-WorkflowPrincipalId {
    param([Parameter(Mandatory)] [string] $WorkflowName)
    return Invoke-WithRetry -Description "Reading managed identity of $WorkflowName" -RequireOutput `
        -AzArgs @('resource', 'show', '--resource-group', $ResourceGroup, '--name', $WorkflowName,
                  '--resource-type', 'Microsoft.Logic/workflows',
                  '--query', 'identity.principalId', '-o', 'tsv')
}

$MarkPrincipalId = Get-WorkflowPrincipalId -WorkflowName $MarkName
if (-not $MarkPrincipalId) {
    Stop-WithError "$MarkName has no managed identity principalId. Is the system-assigned identity enabled?"
}
$DeletePrincipalId = Get-WorkflowPrincipalId -WorkflowName $DeleteName
if (-not $DeletePrincipalId) {
    Stop-WithError "$DeleteName has no managed identity principalId. Is the system-assigned identity enabled?"
}

Assert-Id 'Mark managed identity principalId' $MarkPrincipalId
Assert-Id 'Delete managed identity principalId' $DeletePrincipalId
Write-Info "Mark identity:   $MarkPrincipalId"
Write-Info "Delete identity: $DeletePrincipalId"

# --- Microsoft Graph app roles ----------------------------------------------

function Get-ExistingAssignmentId {
    param(
        [Parameter(Mandatory)] [string] $PrincipalId,
        [Parameter(Mandatory)] [string] $AppRoleId,
        [Parameter(Mandatory)] [string] $GraphSpId
    )
    Assert-Id 'Managed identity principalId' $PrincipalId
    return Invoke-WithRetry -Description "Checking existing assignments on $PrincipalId" `
        -AzArgs @('rest', '--method', 'GET',
                  '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments",
                  '--query', "value[?appRoleId=='$AppRoleId' && resourceId=='$GraphSpId'] | [0].id",
                  '-o', 'tsv')
}

function Set-GraphAppRoles {
    $graphSpId = Invoke-WithRetry -Description 'Looking up the Microsoft Graph service principal' -RequireOutput `
        -AzArgs @('ad', 'sp', 'show', '--id', $GraphAppId, '--query', 'id', '-o', 'tsv')
    if (-not $graphSpId) { Stop-WithError 'Microsoft Graph service principal not found in this tenant.' }
    Assert-Id 'Microsoft Graph service principal objectId' $graphSpId
    Write-Info "Microsoft Graph SP: $graphSpId"

    # A brand-new workflow's identity may not be queryable as a service
    # principal for a few seconds after ARM returns. Wait for both.
    foreach ($principal in @($MarkPrincipalId, $DeletePrincipalId)) {
        Assert-Id 'Managed identity principalId' $principal
        $visible = Invoke-WithRetry -Description "Waiting for service principal $principal to replicate" -RequireOutput `
            -AzArgs @('ad', 'sp', 'show', '--id', $principal, '--query', 'id', '-o', 'tsv')
        if (-not $visible) {
            Stop-WithError "Managed identity $principal is not visible in the directory yet. Re-run with -SkipInfra in a few minutes."
        }
    }

    foreach ($role in $Roles) {
        Write-Section "Graph app role: $role"

        $appRoleId = Invoke-WithRetry -Description "Resolving app role id for $role" -RequireOutput `
            -AzArgs @('ad', 'sp', 'show', '--id', $GraphAppId,
                      '--query', "appRoles[?value=='$role' && contains(allowedMemberTypes,'Application')].id | [0]",
                      '-o', 'tsv')
        if (-not $appRoleId) { Stop-WithError "Could not resolve the app role id for $role. Check the spelling." }
        Assert-Id "App role id for $role" $appRoleId
        Write-Info "Role id: $appRoleId"

        foreach ($principal in @($MarkPrincipalId, $DeletePrincipalId)) {
            Assert-Id 'Managed identity principalId' $principal

            $existing = Get-ExistingAssignmentId -PrincipalId $principal -AppRoleId $appRoleId -GraphSpId $graphSpId
            if ($existing -and $existing -ne 'null') {
                Write-Info "$principal already has $role - skipping."
                continue
            }

            $body = @{
                principalId = $principal
                resourceId  = $graphSpId
                appRoleId   = $appRoleId
            } | ConvertTo-Json -Compress

            $assigned = Invoke-WithRetry -Description "Assigning $role to $principal" `
                -AzArgs @('rest', '--method', 'POST',
                          '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$principal/appRoleAssignments",
                          '--headers', 'Content-Type=application/json',
                          '--body', $body)
            if ($null -ne $assigned) {
                Write-Info "Assigned $role to $principal."
                continue
            }

            # A concurrent run may have created it between our check and our POST.
            $existing = Get-ExistingAssignmentId -PrincipalId $principal -AppRoleId $appRoleId -GraphSpId $graphSpId
            if ($existing -and $existing -ne 'null') {
                Write-Info "$role already present on $principal (created concurrently)."
            }
            else {
                Stop-WithError "Failed to assign $role to $principal. You need Privileged Role Administrator or Global Administrator to grant Graph app roles."
            }
        }
    }
}

if ($SkipPermissions) {
    Write-Section 'Skipping Graph app roles (-SkipPermissions)'
}
else {
    Set-GraphAppRoles
}

# --- ReportOnly-only update --------------------------------------------------

# Flipping the dry-run switch without redeploying: read the workflow, replace
# exactly one parameter value, PUT it back. The definition is round-tripped
# unchanged, and identity.type is resent so the managed identity is preserved.
function Set-ReportOnlyParameter {
    param(
        [Parameter(Mandatory)] [string] $WorkflowName,
        [Parameter(Mandatory)] [ValidateSet('true', 'false')] [string] $Value
    )

    $workflowId = Invoke-WithRetry -Description "Resolving resource id of $WorkflowName" -RequireOutput `
        -AzArgs @('resource', 'show', '--resource-group', $ResourceGroup, '--name', $WorkflowName,
                  '--resource-type', 'Microsoft.Logic/workflows', '--query', 'id', '-o', 'tsv')
    if (-not $workflowId) { Stop-WithError "Could not resolve $WorkflowName." }
    Assert-Id "Resource id of $WorkflowName" $workflowId

    $url = "https://management.azure.com$workflowId`?api-version=$WorkflowApiVersion"
    $currentJson = Invoke-WithRetry -Description "Reading $WorkflowName" -RequireOutput `
        -AzArgs @('rest', '--method', 'GET', '--url', $url)
    if (-not $currentJson) { Stop-WithError "Could not read $WorkflowName." }
    $current = $currentJson | ConvertFrom-Json

    if (-not $current.properties.definition.actions -or
        $current.properties.definition.actions.PSObject.Properties.Count -eq 0) {
        Stop-WithError "Refusing to update ${WorkflowName}: its definition read back empty."
    }

    # Preserve every other parameter; set exactly one.
    $parameters = @{}
    if ($current.properties.PSObject.Properties.Name -contains 'parameters' -and $current.properties.parameters) {
        foreach ($property in $current.properties.parameters.PSObject.Properties) {
            $parameters[$property.Name] = $property.Value
        }
    }
    $parameters['ReportOnly'] = @{ value = [System.Convert]::ToBoolean($Value) }

    $tags = @{}
    if ($current.PSObject.Properties.Name -contains 'tags' -and $current.tags) {
        $tags = $current.tags
    }

    $payload = @{
        location   = $current.location
        tags       = $tags
        identity   = @{ type = $current.identity.type }
        properties = @{
            state      = $current.properties.state
            definition = $current.properties.definition
            parameters = $parameters
        }
    } | ConvertTo-Json -Depth 100 -Compress

    $temporaryFile = [System.IO.Path]::GetTempFileName()
    try {
        # The definition is far too large for a command-line argument on Windows.
        # Written without a BOM: az rest rejects a BOM-prefixed JSON body, and
        # Set-Content -Encoding utf8 adds one on Windows PowerShell 5.1.
        [System.IO.File]::WriteAllText($temporaryFile, $payload, (New-Object System.Text.UTF8Encoding($false)))
        $updated = Invoke-WithRetry -Description "Updating ReportOnly on $WorkflowName" `
            -AzArgs @('rest', '--method', 'PUT', '--url', $url,
                      '--headers', 'Content-Type=application/json',
                      '--body', "@$temporaryFile")
        if ($null -eq $updated) { Stop-WithError "Could not update ReportOnly on $WorkflowName." }
    }
    finally {
        Remove-Item $temporaryFile -ErrorAction SilentlyContinue
    }
    Write-Info "${WorkflowName}: ReportOnly = $Value"
}

if ($ReportOnly -and $SkipInfra) {
    Write-Section "Updating ReportOnly to $ReportOnly (parameter only)"
    Set-ReportOnlyParameter -WorkflowName $MarkName -Value $ReportOnly
    Set-ReportOnlyParameter -WorkflowName $DeleteName -Value $ReportOnly
}

Write-Section 'Done'
Write-Host @"
    Mark workflow:   $MarkName   (identity $MarkPrincipalId)
    Delete workflow: $DeleteName (identity $DeletePrincipalId)

    Next: keep ReportOnly = true, trigger one run of each workflow manually and
    read the report before going live. See docs/deployment.md.
"@
