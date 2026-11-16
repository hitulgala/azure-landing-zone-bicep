// =============================================================================
// Module  : dns   (HUB subscription)
// Purpose : Name resolution for the region:
//             - DNS Private Resolver: inbound endpoint (STATIC IP), outbound
//               endpoint, forwarding ruleset + rules (e.g. AD domain -> DCs)
//             - Private DNS zones + VNet links: private-dns.bicep, called by
//               the stack with the zones' own resource group as scope.
// Scope   : hub network resource group.
// =============================================================================
import { dnsResolverType } from '../types.bicep'

param location string
param tags object
param vnetId string
param inboundSubnetId string
param outboundSubnetId string
param resolver dnsResolverType

resource dnsResolver 'Microsoft.Network/dnsResolvers@2022-07-01' = {
  name: resolver.name
  location: location
  tags: tags
  properties: {
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource inbound 'Microsoft.Network/dnsResolvers/inboundEndpoints@2022-07-01' = {
  parent: dnsResolver
  name: resolver.inboundEndpointName
  location: location
  tags: tags
  properties: {
    ipConfigurations: [
      {
        privateIpAllocationMethod: 'Static'
        privateIpAddress: resolver.inboundStaticIp
        subnet: {
          id: inboundSubnetId
        }
      }
    ]
  }
}

resource outbound 'Microsoft.Network/dnsResolvers/outboundEndpoints@2022-07-01' = {
  parent: dnsResolver
  name: resolver.outboundEndpointName
  location: location
  tags: tags
  properties: {
    subnet: {
      id: outboundSubnetId
    }
  }
}

resource ruleset 'Microsoft.Network/dnsForwardingRulesets@2022-07-01' = {
  name: resolver.rulesetName
  location: location
  tags: tags
  properties: {
    dnsResolverOutboundEndpoints: [
      {
        id: outbound.id
      }
    ]
  }
}

resource rules 'Microsoft.Network/dnsForwardingRulesets/forwardingRules@2022-07-01' = [
  for r in items(resolver.forwardingRules): {
    parent: ruleset
    name: r.key
    properties: {
      domainName: r.value.domainName // must end with a dot
      forwardingRuleState: 'Enabled'
      targetDnsServers: map(r.value.targetDnsServers, ip => {
        ipAddress: ip
        port: 53
      })
    }
  }
]

resource rulesetLink 'Microsoft.Network/dnsForwardingRulesets/virtualNetworkLinks@2022-07-01' = {
  parent: ruleset
  name: resolver.rulesetVnetLinkName
  properties: {
    virtualNetwork: {
      id: vnetId
    }
  }
}

output resolverId string = dnsResolver.id
output inboundIpAddress string = inbound.properties.ipConfigurations[0].privateIpAddress
