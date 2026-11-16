// =============================================================================
// Module  : key-vault   (IDENTITY subscription)
// Purpose : The vault that holds the domain-controller local admin password:
//             - Key Vault (RBAC mode, purge protection, configurable network access)
//             - Private endpoint (+ DNS zone group in the hub's Private DNS zone)
//             - Key Vault Secrets Officer for the deploying identity
//             - The password stored as a secret
//             - Diagnostics to Log Analytics
//
// Differences from Terraform:
//   * No random_password: the deploy script generates the password once (or
//     reads it back from this vault) and passes it in as a secure parameter.
//   * No time_sleep for RBAC propagation: ARM writes the secret through the
//     control plane, which doesn't need the data-plane role. The role exists
//     so the deploy script can read the password back on the next run.
// Scope   : identity network resource group.
// =============================================================================
import { keyVaultType } from '../types.bicep'

param location string
param tags object
param logAnalyticsWorkspaceId string
param keyVault keyVaultType
param privateEndpointSubnetId string
@description('ID of privatelink.vaultcore.azure.net (lives in the primary hub network RG).')
param privateDnsZoneId string
@secure()
param adminPassword string

// Azure built-in role "Key Vault Secrets Officer" (constant GUID).
var secretsOfficerRoleId = 'b86a8fe4-44ce-4948-aee5-eccb2c155cd7'

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVault.name
  location: location
  tags: tags
  properties: {
    tenantId: subscription().tenantId
    sku: {
      family: 'A'
      name: keyVault.skuName
    }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: keyVault.softDeleteRetentionDays
    // ARM rejects an explicit false here: purge protection is either on or omitted.
    enablePurgeProtection: keyVault.purgeProtectionEnabled ? true : null
    publicNetworkAccess: keyVault.publicNetworkAccessEnabled ? 'Enabled' : 'Disabled'
    networkAcls: {
      defaultAction: keyVault.?networkDefaultAction ?? 'Allow'
      bypass: 'AzureServices'
      ipRules: map(keyVault.?allowedIpRanges ?? [], ip => { value: ip })
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: keyVault.privateEndpoint.name
  location: location
  tags: tags
  properties: {
    subnet: {
      id: privateEndpointSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: keyVault.privateEndpoint.connectionName
        properties: {
          privateLinkServiceId: vault.id
          groupIds: [
            'vault' // Azure-mandated sub-resource name
          ]
        }
      }
    ]
  }
}

// The Private DNS zone lives in the HUB subscription. The deploying identity
// needs rights there too (Contributor on the hub subscription covers it).
resource dnsZoneGroup 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [
      {
        name: 'vaultcore'
        properties: {
          privateDnsZoneId: privateDnsZoneId
        }
      }
    ]
  }
}

resource deployerSecretsOfficer 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(vault.id, deployer().objectId, secretsOfficerRoleId)
  scope: vault
  properties: {
    principalId: deployer().objectId
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', secretsOfficerRoleId)
  }
}

resource adminSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: keyVault.secretName
  tags: tags
  properties: {
    value: adminPassword
    contentType: 'Domain controller local administrator password'
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: keyVault.diagnosticSettingName
  scope: vault
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      {
        categoryGroup: 'allLogs' // includes AuditEvent
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
output secretName string = adminSecret.name
