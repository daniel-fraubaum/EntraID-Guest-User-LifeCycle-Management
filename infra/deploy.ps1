<#
.SYNOPSIS
    Deploy the Entra ID guest lifecycle solution: resource group, both Consumption
    Logic Apps (via main.bicep), and the Microsoft Graph app roles their managed
    identities need.

.DESCRIPTION
    PowerShell counterpart of deploy.sh with identical behaviour and switches.
    Everything is idempotent - re-running converges rather than duplicating.
    Directory writes (managed identity service principals, app role assignments)
    replicate asynchronously, so every directory lookup and the role assignment
    itself is retried $RetryAttempts times with $RetryWaitSeconds between tries.

    First installation order matters. A Recurrence trigger fires once as soon as
    a workflow is created or enabled. If that first run happens before the Graph
    app roles exist, the managed identity token it obtains carries no roles, and
    managed identity tokens are cached for up to ~24 hours - the workflows then
    fail with 403 long after the roles were granted. So on a fresh install the
    workflows are deployed Disabled, the roles are assigned, and only then are
    the workflows enabled.

    Uses the az CLI (not the Az PowerShell modules) so both scripts behave the
    same. Requires an authenticated az session. On Windows az is a .cmd file,
    which cmd.exe re-parses: JSON bodies are therefore always passed as files,
    and JMESPath queries are kept free of parentheses and quotes.

.EXAMPLE
    # First deployment, safe by default (ReportOnly = true)
    ./deploy.ps1 -ResourceGroup rg-guest-lcm `
                 -AllGuestsGroupId <guid> -EligibleGroupId <guid>

.EXAMPLE
    # Re-assign Graph roles only (e.g. after a role was revoked)
    ./deploy.ps1 -ResourceGroup rg-guest-lcm -SkipInfra

.EXAMPLE
    # Go live with the Mark app only, Delete stays in report-only mode
    ./deploy.ps1 -ResourceGroup rg-guest-lcm -SkipInfra -ReportOnly false -Workflow mark
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
    # on the existing workflows and leaves the definitions untouched.
    [ValidateSet('true', 'false')]
    [string] $ReportOnly,

    # Which workflow -SkipInfra -ReportOnly updates. Use it to go live one app
    # at a time.
    [ValidateSet('mark', 'delete', 'both')]
    [string] $Workflow = 'both',

    # Graph app roles, per managed identity.
    # Mark reads signInActivity (AuditLog.Read.All), enumerates the source group
    # (GroupMember.Read.All), and writes extensionAttribute14/15 plus
    # accountEnabled (User.ReadWrite.All). Writing onPremisesExtensionAttributes
    # is rejected with 403 under User.ReadUpdate.All (verified live), and the
    # only other option, Directory.ReadWrite.All, is broader. User.ReadWrite.All
    # also allows DELETE /users, so "Mark never deletes" rests on the workflow
    # definition: restrict who can edit the Logic App.
    [string[]] $MarkRoles = @('AuditLog.Read.All', 'GroupMember.Read.All', 'User.ReadWrite.All'),

    # Delete enumerates the source group and deletes users, for which
    # User.ReadWrite.All is the only application permission. It never reads
    # signInActivity, so it does not get AuditLog.Read.All.
    [string[]] $DeleteRoles = @('GroupMember.Read.All', 'User.ReadWrite.All'),

    # Same role list for both identities (overrides -MarkRoles / -DeleteRoles).
    [string[]] $Roles,

    # Remove Graph app roles an identity holds beyond its list, e.g.
    # AuditLog.Read.All on Delete after a v2.0 install.
    [switch] $PruneRoles,

    # Enable both workflows after the role assignment. Done automatically on a
    # fresh install.
    [switch] $Enable,

    [switch] $SkipInfra,

    [switch] $SkipPermissions
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$GraphAppId = '00000003-0000-0000-c000-000000000000'
$WorkflowApiVersion = '2019-05-01'
$RetryAttempts = 5
$RetryWaitSeconds = 15
# Wait between granting app roles and enabling a workflow, so the first token
# the workflow requests already carries the roles.
$EnableDelaySeconds = 120
$DeploymentName = "entraid-guest-lcm-$([DateTime]::UtcNow.ToString('yyyyMMddHHmmss'))"

if ($Roles) {
    $MarkRoles = $Roles
    $DeleteRoles = $Roles
}
if ($Workflow -ne 'both' -and (-not $SkipInfra -or -not $ReportOnly)) {
    throw '-Workflow mark|delete only applies together with -SkipInfra -ReportOnly. A full deployment always sets ReportOnly on both workflows.'
}

function Write-Section { param([string] $Message) Write-Host "`n==> $Message" -ForegroundColor Cyan }
function Write-Info    { param([string] $Message) Write-Host "    $Message" }
function Write-Warn    { param([string] $Message) Write-Warning $Message }
function Stop-WithError { param([string] $Message) throw $Message }

# Runs an az command, returning trimmed stdout. Retries on failure, and puts the
# last stderr line of a failed attempt into the warning.
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory)] [string] $Description,
        [Parameter(Mandatory)] [string[]] $AzArgs,
        # When set, an empty result also counts as failure. This is what makes
        # directory propagation tolerable: a lookup that succeeds with an empty
        # body is retried instead of being passed on as an empty id.
        [switch] $RequireOutput
    )
    # Native stderr must not become a terminating error (Windows PowerShell 5.1
    # does that under 'Stop' when stderr is redirected); the exit code decides.
    $ErrorActionPreference = 'Continue'
    for ($attempt = 1; $attempt -le $RetryAttempts; $attempt++) {
        $combined = & az @AzArgs 2>&1
        $exitCode = $LASTEXITCODE
        $stdout = @($combined | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] })
        $stderr = @($combined | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] } |
                    ForEach-Object { "$_".Trim() } | Where-Object { $_ })
        $joined = ($stdout | Out-String).Trim()
        if ($exitCode -eq 0 -and (-not $RequireOutput -or ($joined -and $joined -ne 'null'))) {
            return $joined
        }
        $detail = if ($stderr.Count -gt 0) {
            $last = $stderr[-1]
            ': ' + $last.Substring(0, [Math]::Min(300, $last.Length))
        } else { '' }
        if ($RequireOutput -and $exitCode -eq 0) {
            Write-Warn "$Description returned nothing yet (attempt $attempt/$RetryAttempts)$detail."
        }
        else {
            Write-Warn "$Description failed (attempt $attempt/$RetryAttempts)$detail."
        }
        if ($attempt -eq $RetryAttempts) { return $null }
        Start-Sleep -Seconds $RetryWaitSeconds
    }
    return $null
}

# Writes a JSON body to a BOM-less temp file and returns its path. az.cmd strips
# the quotes out of JSON passed as an argument, so bodies always go via a file.
function New-JsonBodyFile {
    param([Parameter(Mandatory)] [string] $Json)
    $path = [System.IO.Path]::GetTempFileName()
    [System.IO.File]::WriteAllText($path, $Json, (New-Object System.Text.UTF8Encoding($false)))
    return $path
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

$FreshInstall = $false
$DesiredState = 'Enabled'

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

    # No workflow in the resource group yet means a fresh install: deploy the
    # workflows Disabled so their first run cannot happen before the roles exist.
    $existingJson = Invoke-WithRetry -Description 'Listing existing Logic Apps' `
        -AzArgs @('resource', 'list', '--resource-group', $ResourceGroup,
                  '--resource-type', 'Microsoft.Logic/workflows', '--query', '[].name', '-o', 'json')
    if ($null -eq $existingJson) { Stop-WithError "Could not list the Logic Apps in $ResourceGroup." }
    $existingCount = if ($existingJson) { @($existingJson | ConvertFrom-Json).Count } else { 0 }
    if ($existingCount -eq 0) {
        $FreshInstall = $true
        if ($ParametersFile) {
            $file = Get-Content $ParametersFile -Raw | ConvertFrom-Json
            $fileParameters = if ($file.PSObject.Properties.Name -contains 'parameters') { $file.parameters } else { $null }
            if ($fileParameters -and $fileParameters.PSObject.Properties.Name -contains 'workflowState') {
                $DesiredState = [string] $fileParameters.workflowState.value
            }
        }
        Write-Info 'Fresh install: deploying the workflows Disabled; they are enabled after the Graph app roles are assigned.'
    }

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
    if ($FreshInstall)     { $deployArgs += @('--parameters', 'workflowState=Disabled') }

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

$script:RolesChanged = $false

function Get-GraphAssignments {
    param([Parameter(Mandatory)] [string] $PrincipalId, [Parameter(Mandatory)] [string] $GraphSpId)
    Assert-Id 'Managed identity principalId' $PrincipalId
    $json = Invoke-WithRetry -Description "Reading existing app role assignments of $PrincipalId" `
        -AzArgs @('rest', '--method', 'GET',
                  '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments",
                  '--query', 'value', '-o', 'json')
    if ($null -eq $json) { Stop-WithError "Could not read existing app role assignments for $PrincipalId." }
    return @(($json | ConvertFrom-Json) | Where-Object { $_.resourceId -eq $GraphSpId })
}

function Set-RolesForIdentity {
    param(
        [Parameter(Mandatory)] [string] $Label,
        [Parameter(Mandatory)] [string] $PrincipalId,
        [Parameter(Mandatory)] [string[]] $RoleNames,
        [Parameter(Mandatory)] [string] $GraphSpId,
        [Parameter(Mandatory)] [hashtable] $RoleIdByName,
        [Parameter(Mandatory)] [hashtable] $RoleNameById
    )
    Write-Section "Graph app roles: $Label ($PrincipalId)"
    $existing = Get-GraphAssignments -PrincipalId $PrincipalId -GraphSpId $GraphSpId
    $wantedIds = @()

    foreach ($role in $RoleNames) {
        if (-not $RoleIdByName.ContainsKey($role)) {
            Stop-WithError "Could not resolve the app role id for $role. Check the spelling."
        }
        $appRoleId = $RoleIdByName[$role]
        Assert-Id "App role id for $role" $appRoleId
        $wantedIds += $appRoleId

        if (@($existing | Where-Object { $_.appRoleId -eq $appRoleId }).Count -gt 0) {
            Write-Info "${role}: already assigned - skipping."
            continue
        }

        $bodyFile = New-JsonBodyFile -Json (@{
            principalId = $PrincipalId
            resourceId  = $GraphSpId
            appRoleId   = $appRoleId
        } | ConvertTo-Json -Compress)
        try {
            $assigned = Invoke-WithRetry -Description "Assigning $role to $PrincipalId" `
                -AzArgs @('rest', '--method', 'POST',
                          '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments",
                          '--headers', 'Content-Type=application/json',
                          '--body', "@$bodyFile")
        }
        finally {
            Remove-Item $bodyFile -ErrorAction SilentlyContinue
        }
        if ($null -ne $assigned) {
            Write-Info "${role}: assigned."
            $script:RolesChanged = $true
            continue
        }

        # A concurrent run may have created it between our check and our POST.
        $existing = Get-GraphAssignments -PrincipalId $PrincipalId -GraphSpId $GraphSpId
        if (@($existing | Where-Object { $_.appRoleId -eq $appRoleId }).Count -gt 0) {
            Write-Info "${role}: already present (created concurrently)."
        }
        else {
            Stop-WithError "Failed to assign $role to $PrincipalId. See the warning above; a 403 means you need Privileged Role Administrator or Global Administrator."
        }
    }

    # Roles held beyond the list, e.g. AuditLog.Read.All on Delete from v2.0.
    foreach ($assignment in $existing) {
        if ($wantedIds -contains $assignment.appRoleId) { continue }
        $assignedName = if ($RoleNameById.ContainsKey($assignment.appRoleId)) { $RoleNameById[$assignment.appRoleId] } else { $assignment.appRoleId }
        if ($PruneRoles) {
            $removed = Invoke-WithRetry -Description "Removing $assignedName from $PrincipalId" `
                -AzArgs @('rest', '--method', 'DELETE',
                          '--url', "https://graph.microsoft.com/v1.0/servicePrincipals/$PrincipalId/appRoleAssignments/$($assignment.id)")
            if ($null -eq $removed) { Stop-WithError "Failed to remove $assignedName from $PrincipalId." }
            Write-Info "${assignedName}: removed (-PruneRoles). Cached tokens can keep it usable for up to ~24 hours."
        }
        else {
            Write-Warn "$Label identity also holds $assignedName, which is not in its role list. Re-run with -PruneRoles to remove it."
        }
    }
}

function Set-GraphAppRoles {
    $graphSpId = Invoke-WithRetry -Description 'Looking up the Microsoft Graph service principal' -RequireOutput `
        -AzArgs @('ad', 'sp', 'show', '--id', $GraphAppId, '--query', 'id', '-o', 'tsv')
    if (-not $graphSpId) { Stop-WithError 'Microsoft Graph service principal not found in this tenant.' }
    Assert-Id 'Microsoft Graph service principal objectId' $graphSpId
    Write-Info "Microsoft Graph SP: $graphSpId"

    $appRolesJson = Invoke-WithRetry -Description 'Reading the Microsoft Graph app roles' -RequireOutput `
        -AzArgs @('ad', 'sp', 'show', '--id', $GraphAppId, '--query', 'appRoles', '-o', 'json')
    if (-not $appRolesJson) { Stop-WithError 'Could not read the Microsoft Graph app roles.' }
    $roleIdByName = @{}
    $roleNameById = @{}
    foreach ($appRole in ($appRolesJson | ConvertFrom-Json)) {
        if (@($appRole.allowedMemberTypes) -contains 'Application') {
            $roleIdByName[[string] $appRole.value] = [string] $appRole.id
            $roleNameById[[string] $appRole.id] = [string] $appRole.value
        }
    }

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

    Set-RolesForIdentity -Label 'Mark' -PrincipalId $MarkPrincipalId -RoleNames $MarkRoles `
        -GraphSpId $graphSpId -RoleIdByName $roleIdByName -RoleNameById $roleNameById
    Set-RolesForIdentity -Label 'Delete' -PrincipalId $DeletePrincipalId -RoleNames $DeleteRoles `
        -GraphSpId $graphSpId -RoleIdByName $roleIdByName -RoleNameById $roleNameById
}

if ($SkipPermissions) {
    Write-Section 'Skipping Graph app roles (-SkipPermissions)'
}
else {
    Set-GraphAppRoles
}

# --- enable after a fresh install --------------------------------------------

function Get-WorkflowResourceId {
    param([Parameter(Mandatory)] [string] $WorkflowName)
    $id = Invoke-WithRetry -Description "Resolving resource id of $WorkflowName" -RequireOutput `
        -AzArgs @('resource', 'show', '--resource-group', $ResourceGroup, '--name', $WorkflowName,
                  '--resource-type', 'Microsoft.Logic/workflows', '--query', 'id', '-o', 'tsv')
    if (-not $id) { Stop-WithError "Could not resolve $WorkflowName." }
    Assert-Id "Resource id of $WorkflowName" $id
    return $id
}

function Enable-Workflows {
    if ($script:RolesChanged) {
        Write-Info "Waiting ${EnableDelaySeconds}s so the first token already carries the new app roles."
        Start-Sleep -Seconds $EnableDelaySeconds
    }
    foreach ($name in @($MarkName, $DeleteName)) {
        $workflowId = Get-WorkflowResourceId -WorkflowName $name
        $state = Invoke-WithRetry -Description "Reading state of $name" -RequireOutput `
            -AzArgs @('resource', 'show', '--resource-group', $ResourceGroup, '--name', $name,
                      '--resource-type', 'Microsoft.Logic/workflows', '--query', 'properties.state', '-o', 'tsv')
        if ($state -eq 'Enabled') {
            Write-Info "${name}: already enabled."
            continue
        }
        $enabled = Invoke-WithRetry -Description "Enabling $name" `
            -AzArgs @('rest', '--method', 'POST',
                      '--url', "https://management.azure.com$workflowId/enable?api-version=$WorkflowApiVersion")
        if ($null -eq $enabled) { Stop-WithError "Could not enable $name." }
        # Enabling fires the Recurrence trigger once, right away.
        Write-Info "${name}: enabled (its Recurrence trigger runs once now)."
    }
}

$wantEnable = $Enable -or ($FreshInstall -and $DesiredState -eq 'Enabled')
if ($wantEnable) {
    if ($SkipPermissions) {
        Write-Warn 'Leaving the workflows Disabled: no Graph app roles were assigned in this run. Assign them, then run: ./deploy.ps1 -ResourceGroup RG -SkipInfra -Enable'
    }
    else {
        Write-Section 'Enabling workflows'
        if ($ReportOnly -eq 'false') {
            Write-Warn 'ReportOnly is false: the run fired by enabling the workflows acts for real.'
        }
        Enable-Workflows
    }
}

# --- ReportOnly-only update --------------------------------------------------

# Flipping the dry-run switch without redeploying: read the workflow, replace
# exactly one parameter value, PUT it back. The definition is round-tripped
# unchanged, and identity.type is resent so the managed identity is preserved.
# A PUT does not fire the Recurrence trigger.
function Set-ReportOnlyParameter {
    param(
        [Parameter(Mandatory)] [string] $WorkflowName,
        [Parameter(Mandatory)] [ValidateSet('true', 'false')] [string] $Value
    )

    $workflowId = Get-WorkflowResourceId -WorkflowName $WorkflowName

    $url = "https://management.azure.com$workflowId`?api-version=$WorkflowApiVersion"
    $currentJson = Invoke-WithRetry -Description "Reading $WorkflowName" -RequireOutput `
        -AzArgs @('rest', '--method', 'GET', '--url', $url)
    if (-not $currentJson) { Stop-WithError "Could not read $WorkflowName." }
    # -DateKind String (pwsh 7.5+) keeps ISO date strings in the definition as
    # strings instead of round-tripping them through DateTime.
    $fromJsonArgs = @{}
    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey('DateKind')) { $fromJsonArgs['DateKind'] = 'String' }
    $current = $currentJson | ConvertFrom-Json @fromJsonArgs

    if (-not $current.properties.definition.actions -or
        @($current.properties.definition.actions.PSObject.Properties).Count -eq 0) {
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

    # The definition is far too large for a command-line argument on Windows.
    $temporaryFile = New-JsonBodyFile -Json $payload
    try {
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
    Write-Section "Updating ReportOnly to $ReportOnly (parameter only, workflow: $Workflow)"
    if ($Workflow -in 'mark', 'both')   { Set-ReportOnlyParameter -WorkflowName $MarkName -Value $ReportOnly }
    if ($Workflow -in 'delete', 'both') { Set-ReportOnlyParameter -WorkflowName $DeleteName -Value $ReportOnly }
}

Write-Section 'Done'
Write-Host @"
    Mark workflow:   $MarkName   (identity $MarkPrincipalId)
    Delete workflow: $DeleteName (identity $DeletePrincipalId)

    Next: keep ReportOnly = true, trigger one run of each workflow manually and
    read the report before going live. See docs/deployment.md.
"@
