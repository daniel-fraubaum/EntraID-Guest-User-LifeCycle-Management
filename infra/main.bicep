metadata description = 'Entra ID guest user lifecycle management: two Consumption Logic Apps (Mark + Delete) with system-assigned managed identities.'

// Graph app roles are NOT granted here - role assignment on the Microsoft
// Graph service principal is a directory operation, not an ARM one. Run
// deploy.sh / deploy.ps1, which deploy this template and then assign the
// roles to both managed identities.

@description('Azure region for both workflows.')
param location string = resourceGroup().location

@description('Name of the Logic App that marks inactive guests as eligible for removal.')
param markWorkflowName string = 'Logic-EntraIDGuestLCM-MarkGuestsEligibleforRemoval'

@description('Name of the Logic App that deletes marked guests after the grace period.')
param deleteWorkflowName string = 'Logic-EntraIDGuestLCM-DeleteGuestUsersAfterGracePeriod'

@description('Object ID of the "All Guests" dynamic group - the member source for the Mark workflow.')
@minLength(36)
@maxLength(36)
param allGuestsGroupId string

@description('Object ID of the "Eligible For Removal" dynamic group - the member source for the Delete workflow.')
@minLength(36)
@maxLength(36)
param eligibleForRemovalGroupId string

@description('Days since last sign-in after which an active guest is considered inactive.')
@minValue(1)
@maxValue(3650)
param inactivityThresholdDays int = 180

@description('Days after a guest was marked (extensionAttribute15) before it is deleted.')
@minValue(1)
@maxValue(3650)
param deletionThresholdDays int = 30

@description('Grace period for guests that have never signed in: one is only marked once createdDateTime is older than this. Applied in addition to inactivityThresholdDays, so it is the binding constraint only when it is the larger of the two - which is what protects freshly invited guests if inactivityThresholdDays is lowered.')
@minValue(0)
@maxValue(3650)
param newAccountGraceDays int = 30

@description('Dry-run switch. true = report only, nothing is disabled or deleted. Keep true for the first run.')
param reportOnly bool = true

// Exclusion from the lifecycle is NOT a workflow parameter: it is enforced by
// the "All Guests" dynamic group membership rule, which filters out users whose
// extensionAttribute15 equals 'ExcludeFromLCM'. An excluded guest is never a
// member, so it is never evaluated. See docs/deployment.md.

@description('Number of users per Microsoft Graph $batch request.')
@minValue(1)
@maxValue(100)
param batchSize int = 20

@description('Whether the weekly recurrence triggers are live after deployment.')
@allowed([
  'Enabled'
  'Disabled'
])
param workflowState string = 'Enabled'

@description('Tags applied to both workflows.')
param tags object = {}

// The workflow definitions in workflows/ are the source of truth for
// behaviour; they are embedded verbatim at build time.
var markDefinition = loadJsonContent('../workflows/mark-guests-eligible-for-removal.json')
var deleteDefinition = loadJsonContent('../workflows/delete-guests-after-grace-period.json')

module markWorkflow 'modules/logic-app-workflow.bicep' = {
  name: 'mark-guests-eligible-for-removal'
  params: {
    name: markWorkflowName
    location: location
    state: workflowState
    tags: tags
    definition: markDefinition
    workflowParameters: {
      guestSourceGroupId: {
        value: allGuestsGroupId
      }
      InactivityThresholdDays: {
        value: inactivityThresholdDays
      }
      NewAccountGraceDays: {
        value: newAccountGraceDays
      }
      ReportOnly: {
        value: reportOnly
      }
      BatchSize: {
        value: batchSize
      }
    }
  }
}

module deleteWorkflow 'modules/logic-app-workflow.bicep' = {
  name: 'delete-guests-after-grace-period'
  params: {
    name: deleteWorkflowName
    location: location
    state: workflowState
    tags: tags
    definition: deleteDefinition
    workflowParameters: {
      guestSourceGroupId: {
        value: eligibleForRemovalGroupId
      }
      DeletionThresholdDays: {
        value: deletionThresholdDays
      }
      ReportOnly: {
        value: reportOnly
      }
      BatchSize: {
        value: batchSize
      }
    }
  }
}

@description('Name of the Mark workflow.')
output markWorkflowName string = markWorkflow.outputs.name

@description('Name of the Delete workflow.')
output deleteWorkflowName string = deleteWorkflow.outputs.name

@description('Resource ID of the Mark workflow.')
output markWorkflowId string = markWorkflow.outputs.resourceId

@description('Resource ID of the Delete workflow.')
output deleteWorkflowId string = deleteWorkflow.outputs.resourceId

@description('Managed identity object ID of the Mark workflow - needs the Graph app roles.')
output markPrincipalId string = markWorkflow.outputs.principalId

@description('Managed identity object ID of the Delete workflow - needs the Graph app roles.')
output deletePrincipalId string = deleteWorkflow.outputs.principalId

@description('Effective dry-run state of both workflows.')
output reportOnly bool = reportOnly
