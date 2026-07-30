metadata description = 'Deploys one Consumption Logic App workflow with a system-assigned managed identity.'

@description('Name of the Consumption Logic App workflow.')
@minLength(1)
@maxLength(80)
param name string

@description('Azure region for the workflow.')
param location string

@description('Workflow definition object, embedded from workflows/*.json at build time.')
param definition object

@description('Values for the parameters declared by the workflow definition, in { name: { value: ... } } form.')
param workflowParameters object

@description('Whether the recurrence trigger is live after deployment.')
@allowed([
  'Enabled'
  'Disabled'
])
param state string = 'Enabled'

@description('Tags applied to the workflow.')
param tags object = {}

resource workflow 'Microsoft.Logic/workflows@2019-05-01' = {
  name: name
  location: location
  tags: tags
  // System-assigned identity is what the definition's HTTP actions
  // authenticate with (authentication.type = ManagedServiceIdentity).
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: state
    definition: definition
    parameters: workflowParameters
  }
}

@description('Workflow name.')
output name string = workflow.name

@description('Workflow resource ID.')
output resourceId string = workflow.id

@description('Object (principal) ID of the system-assigned managed identity, for Graph app role assignment.')
output principalId string = workflow.identity.principalId
