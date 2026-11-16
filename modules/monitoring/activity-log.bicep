// Forwards one subscription's Activity Log to a Log Analytics workspace.
// The stack calls this module once per subscription with
// scope: subscription(<id>), because a subscription-level diagnostic
// setting must be deployed at that subscription's scope.
targetScope = 'subscription'

param name string
param categories string[]
param workspaceId string

resource activityLog 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: name
  properties: {
    workspaceId: workspaceId
    logs: [
      for category in categories: {
        category: category
        enabled: true
      }
    ]
  }
}
