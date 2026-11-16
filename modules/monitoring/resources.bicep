// Resource-group-scoped part of the monitoring module.
import { governanceType } from '../types.bicep'

param location string
param tags object
param config governanceType

resource workspace 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: config.logAnalytics.name
  location: location
  tags: tags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: config.logAnalytics.retentionInDays
    workspaceCapping: {
      dailyQuotaGb: config.logAnalytics.dailyQuotaGb
    }
  }
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: config.actionGroup.name
  location: 'global' // Azure-mandated: action groups are global resources
  tags: tags
  properties: {
    groupShortName: config.actionGroup.shortName
    enabled: true
    emailReceivers: map(items(config.actionGroup.emailReceivers), r => {
      name: r.key
      emailAddress: r.value
      useCommonAlertSchema: true
    })
    webhookReceivers: map(items(config.actionGroup.?webhookReceivers ?? {}), r => {
      name: r.key
      serviceUri: r.value
      useCommonAlertSchema: true
    })
  }
}

output logAnalyticsWorkspaceId string = workspace.id
output logAnalyticsWorkspaceName string = workspace.name
output actionGroupId string = actionGroup.id
