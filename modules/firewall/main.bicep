// =============================================================================
// Module  : firewall   (HUB subscription)
// Purpose : Azure Firewall with ONE firewall policy per region:
//             public IP, policy (DNS proxy), network rule collection group,
//             firewall, diagnostics and a health alert.
//
// The firewall's private IP is the first free address of AzureFirewallSubnet.
// Spoke route tables and DNS settings in main.bicepparam reference that IP;
// the stack outputs firewallIpMatchesExpected and the deploy script warns.
// Scope   : hub network resource group.
// =============================================================================
import { firewallType } from '../types.bicep'

param location string
param tags object
@description('ID of AzureFirewallSubnet.')
param subnetId string
param logAnalyticsWorkspaceId string
param actionGroupId string
param firewall firewallType

var zones = empty(firewall.zones) ? null : firewall.zones

resource publicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: firewall.publicIpName
  location: location
  tags: tags
  zones: zones
  sku: {
    name: 'Standard' // Azure-mandated for Azure Firewall
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

// DNS proxy: spokes use the firewall as DNS; it forwards to dnsServers
// (the DNS Private Resolver inbound endpoint).
resource policy 'Microsoft.Network/firewallPolicies@2024-05-01' = {
  name: firewall.policyName
  location: location
  tags: tags
  properties: {
    sku: {
      tier: firewall.skuTier
    }
    threatIntelMode: firewall.threatIntelligenceMode
    dnsSettings: {
      enableProxy: firewall.dnsProxyEnabled
      servers: firewall.dnsServers
    }
  }
}

resource ruleCollectionGroup 'Microsoft.Network/firewallPolicies/ruleCollectionGroups@2024-05-01' = if (!empty(firewall.networkRuleCollections)) {
  parent: policy
  name: firewall.ruleCollectionGroup.name
  properties: {
    priority: firewall.ruleCollectionGroup.priority
    ruleCollections: [
      for c in firewall.networkRuleCollections: {
        ruleCollectionType: 'FirewallPolicyFilterRuleCollection'
        name: c.name
        priority: c.priority
        action: {
          type: c.action
        }
        rules: map(c.rules, r => {
          ruleType: 'NetworkRule'
          name: r.name
          ipProtocols: r.protocols
          sourceAddresses: r.sourceAddresses
          destinationAddresses: r.destinationAddresses
          destinationPorts: r.destinationPorts
        })
      }
    ]
  }
}

resource azureFirewall 'Microsoft.Network/azureFirewalls@2024-05-01' = {
  name: firewall.name
  location: location
  tags: tags
  zones: zones
  // Rules must exist before the firewall starts enforcing the policy.
  dependsOn: [
    ruleCollectionGroup
  ]
  properties: {
    sku: {
      name: 'AZFW_VNet'
      tier: firewall.skuTier
    }
    firewallPolicy: {
      id: policy.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig-fw'
        properties: {
          subnet: {
            id: subnetId // must be AzureFirewallSubnet
          }
          publicIPAddress: {
            id: publicIp.id
          }
        }
      }
    ]
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: firewall.diagnosticSettingName
  scope: azureFirewall
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logAnalyticsDestinationType: 'Dedicated' // resource-specific tables
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

resource healthAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: firewall.healthAlert.name
  location: 'global' // Azure-mandated for single-resource metric alerts
  tags: tags
  properties: {
    description: 'Azure Firewall health below threshold'
    severity: firewall.healthAlert.severity
    enabled: true
    scopes: [
      azureFirewall.id
    ]
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          criterionType: 'StaticThresholdCriterion'
          name: 'FirewallHealth'
          metricNamespace: 'Microsoft.Network/azureFirewalls'
          metricName: 'FirewallHealth'
          operator: 'LessThan'
          threshold: firewall.healthAlert.threshold
          timeAggregation: 'Average'
        }
      ]
    }
    actions: [
      {
        actionGroupId: actionGroupId
      }
    ]
  }
}

output id string = azureFirewall.id
output privateIpAddress string = azureFirewall.properties.ipConfigurations[0].properties.privateIPAddress
output publicIpAddress string = publicIp.properties.ipAddress
