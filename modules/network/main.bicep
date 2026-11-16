// =============================================================================
// Module  : network
// Purpose : One resource group + VNet with its subnets, NSGs (and rules) and
//           route tables. Used for the hub VNet and for every spoke VNet.
//           Everything (names, prefixes, rules, routes) comes from the caller.
// Scope   : subscription (the module creates its own resource group).
// =============================================================================
targetScope = 'subscription'

import { networkType } from '../types.bicep'

param location string
param tags object
param logAnalyticsWorkspaceId string
param network networkType

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: network.resourceGroupName
  location: location
  tags: tags
}

module resources 'resources.bicep' = {
  name: 'network-${network.vnet.name}'
  scope: rg
  params: {
    location: location
    tags: tags
    logAnalyticsWorkspaceId: logAnalyticsWorkspaceId
    network: network
  }
}

output resourceGroupName string = rg.name
output vnetId string = resources.outputs.vnetId
output vnetName string = resources.outputs.vnetName
output subnetIds object = resources.outputs.subnetIds
