// =============================================================================
// Module  : peering
// Purpose : Creates BOTH halves of a VNet peering (A->B and B->A).
//
// Each half is a nested deployment scoped to its own subscription and
// resource group, so one module call owns both halves even when the two
// VNets live in different subscriptions. For hub-to-hub peering (same
// subscription) pass the same subscription ID on both sides.
// Scope   : subscription (any; the halves set their own scope).
// =============================================================================
targetScope = 'subscription'

type sideType = {
  subscriptionId: string
  resourceGroupName: string
  vnetName: string
  @description('Default true.')
  allowForwardedTraffic: bool?
  @description('Default false.')
  allowGatewayTransit: bool?
  @description('Default false.')
  useRemoteGateways: bool?
}

param nameAToB string
param nameBToA string
param sideA sideType
param sideB sideType

var vnetIdA = resourceId(
  sideA.subscriptionId,
  sideA.resourceGroupName,
  'Microsoft.Network/virtualNetworks',
  sideA.vnetName
)
var vnetIdB = resourceId(
  sideB.subscriptionId,
  sideB.resourceGroupName,
  'Microsoft.Network/virtualNetworks',
  sideB.vnetName
)

module aToB 'half.bicep' = {
  name: nameAToB
  scope: resourceGroup(sideA.subscriptionId, sideA.resourceGroupName)
  params: {
    name: nameAToB
    localVnetName: sideA.vnetName
    remoteVnetId: vnetIdB
    allowForwardedTraffic: sideA.?allowForwardedTraffic ?? true
    allowGatewayTransit: sideA.?allowGatewayTransit ?? false
    useRemoteGateways: sideA.?useRemoteGateways ?? false
  }
}

module bToA 'half.bicep' = {
  name: nameBToA
  scope: resourceGroup(sideB.subscriptionId, sideB.resourceGroupName)
  params: {
    name: nameBToA
    localVnetName: sideB.vnetName
    remoteVnetId: vnetIdA
    allowForwardedTraffic: sideB.?allowForwardedTraffic ?? true
    allowGatewayTransit: sideB.?allowGatewayTransit ?? false
    useRemoteGateways: sideB.?useRemoteGateways ?? false
  }
}
