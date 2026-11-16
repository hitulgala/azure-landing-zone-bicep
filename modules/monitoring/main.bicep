// =============================================================================
// Module  : monitoring   (GOVERNANCE subscription)
// Purpose : Central monitoring for one region:
//             - resource group
//             - Log Analytics workspace
//             - Action group (alert routing: e-mail / webhook)
// Subscription-scoped pieces are separate files the stack calls once per
// subscription:
//   activity-log.bicep         - Activity Log -> workspace (ONE region only)
//   service-health-alert.bicep - Service Health alert (an activity log alert
//                                rule may watch only ONE subscription)
// Scope: subscription (the module creates its own resource group).
// =============================================================================
targetScope = 'subscription'

import { governanceType } from '../types.bicep'

param location string
param tags object
param config governanceType

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: config.resourceGroupName
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'monitoring-resources'
  scope: rg
  params: {
    location: location
    tags: tags
    config: config
  }
}

output resourceGroupName string = rg.name
output logAnalyticsWorkspaceId string = resources.outputs.logAnalyticsWorkspaceId
output logAnalyticsWorkspaceName string = resources.outputs.logAnalyticsWorkspaceName
output actionGroupId string = resources.outputs.actionGroupId
