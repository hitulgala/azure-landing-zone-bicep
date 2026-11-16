// =============================================================================
// Module  : recovery-vault   (WORKLOAD subscription)
// Purpose : Recovery Services Vault for Azure Backup AND Azure Site Recovery,
//           with an optional daily VM backup policy and diagnostics.
// Scope   : workload network resource group.
// =============================================================================
import { workloadType } from '../types.bicep'

param location string
param tags object
param logAnalyticsWorkspaceId string
param recoveryVault workloadType['recoveryVault']

var vaultConfig = recoveryVault.vault
var policy = recoveryVault.?vmBackupPolicy
// Only the time part is used; the date is an Azure-required placeholder.
var scheduleTime = '2026-01-01T${policy.?time ?? '23:00'}:00Z'

resource vault 'Microsoft.RecoveryServices/vaults@2024-04-01' = {
  name: vaultConfig.name
  location: location
  tags: tags
  sku: {
    name: 'RS0'
    tier: 'Standard'
  }
  properties: {
    publicNetworkAccess: 'Enabled'
    redundancySettings: {
      standardTierStorageRedundancy: vaultConfig.storageModeType
      crossRegionRestore: vaultConfig.crossRegionRestoreEnabled ? 'Enabled' : 'Disabled'
    }
    securitySettings: {
      immutabilitySettings: {
        state: vaultConfig.immutability
      }
    }
  }
}

resource dailyPolicy 'Microsoft.RecoveryServices/vaults/backupPolicies@2024-04-01' = if (policy != null) {
  parent: vault
  name: policy.?name ?? 'unused'
  properties: {
    backupManagementType: 'AzureIaasVM'
    timeZone: policy.?timezone ?? 'UTC'
    instantRpRetentionRangeInDays: policy.?instantRestoreRetentionDays ?? 2
    schedulePolicy: {
      schedulePolicyType: 'SimpleSchedulePolicy'
      scheduleRunFrequency: 'Daily'
      scheduleRunTimes: [
        scheduleTime
      ]
    }
    retentionPolicy: {
      retentionPolicyType: 'LongTermRetentionPolicy'
      dailySchedule: {
        retentionTimes: [
          scheduleTime
        ]
        retentionDuration: {
          count: policy.?dailyRetentionDays ?? 30
          durationType: 'Days'
        }
      }
    }
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: vaultConfig.diagnosticSettingName
  scope: vault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated'
    logs: [
      {
        categoryGroup: 'allLogs'
        enabled: true
      }
    ]
    metrics: [
      {
        category: 'AllMetrics'
        enabled: true
      }
    ]
  }
}

output id string = vault.id
output name string = vault.name
