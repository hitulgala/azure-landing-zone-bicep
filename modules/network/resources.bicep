// Resource-group-scoped part of the network module.
import { networkType } from '../types.bicep'

param location string
param tags object
param logAnalyticsWorkspaceId string
param network networkType

var nsgs = items(network.?networkSecurityGroups ?? {})
var routeTables = items(network.?routeTables ?? {})

// NSG diagnostic categories defined by Azure (NSGs expose no metrics).
var nsgLogCategories = [
  'NetworkSecurityGroupEvent'
  'NetworkSecurityGroupRuleCounter'
]

// A custom DenyAll (4096) would also block Azure Load Balancer health probes,
// because Azure's default AllowAzureLoadBalancerInBound sits at 65001. So the
// probe rule is added first (4000) whenever the deny-all baseline is enabled.
var denyAllBaseline = [
  {
    name: 'Allow-AzureLoadBalancer-Inbound'
    properties: {
      priority: 4000
      direction: 'Inbound'
      access: 'Allow'
      protocol: '*'
      sourcePortRange: '*'
      destinationPortRange: '*'
      sourceAddressPrefix: 'AzureLoadBalancer'
      destinationAddressPrefix: '*'
    }
  }
  {
    name: 'Deny-All-Inbound'
    properties: {
      priority: 4096
      direction: 'Inbound'
      access: 'Deny'
      protocol: '*'
      sourcePortRange: '*'
      destinationPortRange: '*'
      sourceAddressPrefix: '*'
      destinationAddressPrefix: '*'
    }
  }
]

// ---------------------------------------------------------------- NSGs (rules inline)
// Terraform creates rules as separate resources; Bicep declares them inside the
// NSG so the whole rule set is replaced in one PUT (no drift between rules).
resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = [
  for n in nsgs: {
    name: n.key
    location: location
    tags: tags
    properties: {
      securityRules: concat(
        map(items(n.value.?rules ?? {}), r => {
          name: r.key
          properties: {
            description: r.value.?description ?? ''
            priority: r.value.priority
            direction: r.value.direction
            access: r.value.access
            protocol: r.value.protocol
            sourcePortRange: r.value.?sourcePortRange ?? '*'
            destinationPortRanges: r.value.destinationPortRanges
            sourceAddressPrefixes: r.value.sourceAddressPrefixes
            destinationAddressPrefixes: r.value.destinationAddressPrefixes
          }
        }),
        (n.value.?addDenyAllInbound ?? true) ? denyAllBaseline : []
      )
    }
  }
]

// ---------------------------------------------------------------- Route tables
resource routeTable 'Microsoft.Network/routeTables@2024-05-01' = [
  for rt in routeTables: {
    name: rt.key
    location: location
    tags: tags
    properties: {
      disableBgpRoutePropagation: !(rt.value.?bgpRoutePropagationEnabled ?? false)
      routes: map(items(rt.value.routes), r => {
        name: r.key
        properties: {
          addressPrefix: r.value.addressPrefix
          nextHopType: r.value.nextHopType
          nextHopIpAddress: r.value.?nextHopInIpAddress
        }
      })
    }
  }
]

// ---------------------------------------------------------------- VNet + subnets
// Subnets are declared inline: VNet and subnets are created in one PUT, and
// re-deployments don't race each other. This also replaces Terraform's
// separate NSG / route table association resources.
resource vnet 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: network.vnet.name
  location: location
  tags: tags
  dependsOn: [
    nsg
    routeTable
  ]
  properties: {
    addressSpace: {
      addressPrefixes: network.vnet.addressSpace
    }
    dhcpOptions: {
      dnsServers: network.vnet.?dnsServers ?? []
    }
    subnets: map(items(network.subnets), s => {
      name: s.key
      properties: {
        addressPrefixes: s.value.addressPrefixes
        networkSecurityGroup: s.value.?nsg == null
          ? null
          : {
              id: resourceId('Microsoft.Network/networkSecurityGroups', s.value.nsg!)
            }
        routeTable: s.value.?routeTable == null
          ? null
          : {
              id: resourceId('Microsoft.Network/routeTables', s.value.routeTable!)
            }
        delegations: s.value.?delegation == null
          ? []
          : [
              {
                name: s.value.delegation!.name
                properties: {
                  serviceName: s.value.delegation!.serviceName
                }
              }
            ]
        privateEndpointNetworkPolicies: s.value.?privateEndpointNetworkPolicies ?? 'Disabled'
        defaultOutboundAccess: s.value.?defaultOutboundAccessEnabled ?? true
      }
    })
  }
}

// ---------------------------------------------------------------- NSG diagnostics -> Log Analytics
resource nsgDiagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = [
  for (n, i) in nsgs: {
    name: network.diagnosticSettingName
    scope: nsg[i]
    properties: {
      workspaceId: logAnalyticsWorkspaceId
      logs: [
        for category in nsgLogCategories: {
          category: category
          enabled: true
        }
      ]
    }
  }
]

output vnetId string = vnet.id
output vnetName string = vnet.name
@description('Map of subnet name => subnet ID.')
output subnetIds object = toObject(
  items(network.subnets),
  s => s.key,
  s => resourceId('Microsoft.Network/virtualNetworks/subnets', network.vnet.name, s.key)
)
