// =============================================================================
// Stack: primary-centralindia  |  PARENT ORCHESTRATION
//
// This file only WIRES modules together. It contains no environment values:
// every name, address, port and setting comes from main.bicepparam.
//
// One deployment runs at the GOVERNANCE subscription scope; every module is
// pointed at its subscription with subscription(<id>) or
// resourceGroup(<id>, <name>), so a single deployment spans all four.
// =============================================================================
targetScope = 'subscription'

import {
  subscriptionIdsType
  governanceType
  hubType
  identityType
  workloadType
  primaryPeeringsType
  policyDefinitionNamesType
  builtInPolicyDefinitionsType
  policiesType
} from '../modules/types.bicep'

// ---------------------------------------------------------------- Inputs (= variables.tf)
@description('The four platform subscription IDs (from environment variables, never committed).')
param subscriptionIds subscriptionIdsType
@description('Azure region of this stack.')
param location string
@description('Tags every resource must carry. Deploy-LandingZone.ps1 fails if tags lacks one; Azure Policy enforces them.')
param mandatoryTagNames string[]
@description('Tags applied to every taggable resource created by this stack.')
param tags object
@description('IP the firewall is expected to receive (first free address of AzureFirewallSubnet).')
param expectedFirewallPrivateIp string
param governance governanceType
param hub hubType
param identity identityType
param workload workloadType
param peerings primaryPeeringsType
param policyDefinitionNames policyDefinitionNamesType
param builtInPolicyDefinitions builtInPolicyDefinitionsType
param policies policiesType
@secure()
@description('DC local admin password. Generated or read back by Deploy-LandingZone.ps1; never stored in Git.')
param dcAdminPassword string

var subs = subscriptionIds

// ---------------------------------------------------------------- Governance subscription
module governanceMonitoring '../modules/monitoring/main.bicep' = {
  name: 'alz-cin-governance'
  scope: subscription(subs.governance)
  params: {
    location: location
    tags: tags
    config: governance
  }
}

// Activity Logs are subscription-wide: one diagnostic setting per subscription.
module activityLogs '../modules/monitoring/activity-log.bicep' = [
  for sub in (governance.activityLogDiagnostics.enabled ? items(subs) : []): {
    name: 'alz-cin-activity-log-${sub.key}'
    scope: subscription(sub.value)
    params: {
      name: governance.activityLogDiagnostics.name
      categories: governance.activityLogDiagnostics.categories
      workspaceId: governanceMonitoring.outputs.logAnalyticsWorkspaceId
    }
  }
]

// ---------------------------------------------------------------- Service Health alerts
// One rule per DISTINCT subscription (Azure allows one scope per rule), placed
// in a resource group of that subscription. With the same ID used for several
// subscriptions (single-subscription lab), only one rule is created.
var serviceHealthTargets = [
  {
    key: 'governance'
    subscriptionId: subs.governance
    resourceGroupName: governance.resourceGroupName
  }
  {
    key: 'hub'
    subscriptionId: subs.hub
    resourceGroupName: hub.network.resourceGroupName
  }
  {
    key: 'identity'
    subscriptionId: subs.identity
    resourceGroupName: identity.network.resourceGroupName
  }
  {
    key: 'workload'
    subscriptionId: subs.workload
    resourceGroupName: workload.network.resourceGroupName
  }
]
var serviceHealthSubIds = map(serviceHealthTargets, t => t.subscriptionId)
var distinctServiceHealthTargets = filter(
  serviceHealthTargets,
  t => indexOf(serviceHealthSubIds, t.subscriptionId) == indexOf(map(serviceHealthTargets, x => x.key), t.key)
)

module serviceHealthAlerts '../modules/monitoring/service-health-alert.bicep' = [
  for t in distinctServiceHealthTargets: {
    name: 'alz-cin-service-health-${t.key}'
    scope: resourceGroup(t.subscriptionId, t.resourceGroupName)
    dependsOn: [
      hubNetwork // the network modules create the hub / identity / workload RGs
      identityNetwork
      workloadNetwork
    ]
    params: {
      // governance keeps the configured name; others get a -<subscription> suffix
      name: t.key == 'governance'
        ? governance.serviceHealthAlert.name
        : '${governance.serviceHealthAlert.name}-${t.key}'
      tags: tags
      actionGroupId: governanceMonitoring.outputs.actionGroupId
      config: governance.serviceHealthAlert
    }
  }
]

// ---------------------------------------------------------------- Hub subscription
module hubNetwork '../modules/network/main.bicep' = {
  name: 'alz-cin-hub-network'
  scope: subscription(subs.hub)
  params: {
    location: location
    tags: tags
    network: hub.network
    logAnalyticsWorkspaceId: governanceMonitoring.outputs.logAnalyticsWorkspaceId
  }
}

module hubFirewall '../modules/firewall/main.bicep' = {
  name: 'alz-cin-hub-firewall'
  scope: resourceGroup(subs.hub, hub.network.resourceGroupName)
  params: {
    location: location
    tags: tags
    subnetId: hubNetwork.outputs.subnetIds[hub.firewall.subnetName]
    firewall: hub.firewall
    logAnalyticsWorkspaceId: governanceMonitoring.outputs.logAnalyticsWorkspaceId
    actionGroupId: governanceMonitoring.outputs.actionGroupId
  }
}

module hubDns '../modules/dns/main.bicep' = {
  name: 'alz-cin-hub-dns'
  scope: resourceGroup(subs.hub, hub.network.resourceGroupName)
  params: {
    location: location
    tags: tags
    vnetId: hubNetwork.outputs.vnetId
    inboundSubnetId: hubNetwork.outputs.subnetIds[hub.dnsResolver.inboundSubnetName]
    outboundSubnetId: hubNetwork.outputs.subnetIds[hub.dnsResolver.outboundSubnetName]
    resolver: hub.dnsResolver
  }
}

// The Private DNS zones are created in privateDns.resourceGroupName (the hub
// network RG), so the hub network module must have created it first.
module hubPrivateDns '../modules/dns/private-dns.bicep' = {
  name: 'alz-cin-hub-private-dns'
  scope: resourceGroup(subs.hub, hub.privateDns.resourceGroupName)
  params: {
    tags: tags
    vnetId: hubNetwork.outputs.vnetId
    privateDns: hub.privateDns
  }
}

// ---------------------------------------------------------------- Identity subscription
module identityNetwork '../modules/network/main.bicep' = {
  name: 'alz-cin-identity-network'
  scope: subscription(subs.identity)
  params: {
    location: location
    tags: tags
    network: identity.network
    logAnalyticsWorkspaceId: governanceMonitoring.outputs.logAnalyticsWorkspaceId
  }
}

module keyVault '../modules/key-vault/main.bicep' = {
  name: 'alz-cin-key-vault'
  scope: resourceGroup(subs.identity, identity.network.resourceGroupName)
  params: {
    location: location
    tags: tags
    logAnalyticsWorkspaceId: governanceMonitoring.outputs.logAnalyticsWorkspaceId
    keyVault: identity.keyVault
    privateEndpointSubnetId: identityNetwork.outputs.subnetIds[identity.keyVault.privateEndpoint.subnetName]
    privateDnsZoneId: hubPrivateDns.outputs.zoneIds[identity.keyVault.privateDnsZoneName]
    adminPassword: dcAdminPassword
  }
}

module domainControllers '../modules/domain-controllers/main.bicep' = {
  name: 'alz-cin-domain-controllers'
  scope: resourceGroup(subs.identity, identity.network.resourceGroupName)
  dependsOn: [
    keyVault // the password is stored in the vault before any VM uses it
  ]
  params: {
    location: location
    tags: tags
    subnetId: identityNetwork.outputs.subnetIds[identity.domainControllers.subnetName]
    adminPassword: dcAdminPassword
    domainControllers: identity.domainControllers
  }
}

// ---------------------------------------------------------------- Workload subscription
module workloadNetwork '../modules/network/main.bicep' = {
  name: 'alz-cin-workload-network'
  scope: subscription(subs.workload)
  params: {
    location: location
    tags: tags
    network: workload.network
    logAnalyticsWorkspaceId: governanceMonitoring.outputs.logAnalyticsWorkspaceId
  }
}

module recoveryVault '../modules/recovery-vault/main.bicep' = {
  name: 'alz-cin-recovery-vault'
  scope: resourceGroup(subs.workload, workload.network.resourceGroupName)
  dependsOn: [
    workloadNetwork // creates the resource group
  ]
  params: {
    location: location
    tags: tags
    logAnalyticsWorkspaceId: governanceMonitoring.outputs.logAnalyticsWorkspaceId
    recoveryVault: workload.recoveryVault
  }
}

// ---------------------------------------------------------------- Hub <-> spoke peerings
module peeringHubIdentity '../modules/peering/main.bicep' = {
  name: 'alz-cin-peering-hub-identity'
  scope: subscription(subs.hub)
  dependsOn: [
    hubNetwork
    identityNetwork
  ]
  params: {
    nameAToB: peerings.hubIdentity.hubToSpoke
    nameBToA: peerings.hubIdentity.spokeToHub
    sideA: {
      subscriptionId: subs.hub
      resourceGroupName: hub.network.resourceGroupName
      vnetName: hub.network.vnet.name
    }
    sideB: {
      subscriptionId: subs.identity
      resourceGroupName: identity.network.resourceGroupName
      vnetName: identity.network.vnet.name
    }
  }
}

module peeringHubWorkload '../modules/peering/main.bicep' = {
  name: 'alz-cin-peering-hub-workload'
  scope: subscription(subs.hub)
  dependsOn: [
    hubNetwork
    workloadNetwork
  ]
  params: {
    nameAToB: peerings.hubWorkload.hubToSpoke
    nameBToA: peerings.hubWorkload.spokeToHub
    sideA: {
      subscriptionId: subs.hub
      resourceGroupName: hub.network.resourceGroupName
      vnetName: hub.network.vnet.name
    }
    sideB: {
      subscriptionId: subs.workload
      resourceGroupName: workload.network.resourceGroupName
      vnetName: workload.network.vnet.name
    }
  }
}

// ---------------------------------------------------------------- Azure Policy (subscription scope)
// Policy is subscription-wide, not regional, so ONLY the primary stack assigns it.
// One call per subscription; each subscription has its own rules (policies.<name>).
module policy '../modules/policy/main.bicep' = [
  for sub in items(subs): {
    name: 'alz-policy-${sub.key}'
    scope: subscription(sub.value)
    params: {
      location: location
      mandatoryTagNames: mandatoryTagNames
      policyDefinitionNames: policyDefinitionNames
      builtInPolicyDefinitions: builtInPolicyDefinitions
      policies: policies[sub.key]
    }
  }
]

// ---------------------------------------------------------------- Outputs (= outputs.tf)
@description('Hub network RG (holds the Private DNS zones). Copy into the secondary primaryHub.')
output hubNetworkResourceGroupName string = hubNetwork.outputs.resourceGroupName
@description('Hub VNet name. Copy into the secondary primaryHub.')
output hubVnetName string = hubNetwork.outputs.vnetName
@description('Verify it equals the primary firewall IP referenced in the SECONDARY params.')
output firewallPrivateIp string = hubFirewall.outputs.privateIpAddress
@description('False when Azure assigned another IP; Deploy-LandingZone.ps1 warns.')
output firewallIpMatchesExpected bool = hubFirewall.outputs.privateIpAddress == expectedFirewallPrivateIp
output domainControllerIps object = domainControllers.outputs.privateIps
output keyVaultName string = keyVault.outputs.name
output keyVaultSecretName string = keyVault.outputs.secretName
output logAnalyticsWorkspaceName string = governanceMonitoring.outputs.logAnalyticsWorkspaceName
