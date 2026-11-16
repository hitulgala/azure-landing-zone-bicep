// =============================================================================
// Private DNS zones (global resources) and the link from this region's hub
// VNet to each of them.
//   PRIMARY   (createZones = true) : creates the zones and links its hub VNet
//   SECONDARY (createZones = false): links its hub VNet to the existing zones
// Scope: resourceGroup(<hub subscription>, privateDns.resourceGroupName),
//        i.e. the PRIMARY hub network RG in both stacks.
//
// Note: in the Terraform repo the secondary creates NO links (the link
// resource iterates over created zones only). This module implements the
// documented design (decision 5) for both regions.
// =============================================================================
import { privateDnsType } from '../types.bicep'

param tags object
param vnetId string
param privateDns privateDnsType

resource newZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [
  for z in privateDns.zoneNames: if (privateDns.createZones) {
    name: z
    location: 'global' // Azure-mandated
    tags: tags
  }
]

resource existingZones 'Microsoft.Network/privateDnsZones@2024-06-01' existing = [
  for z in privateDns.zoneNames: if (!privateDns.createZones) {
    name: z
  }
]

resource newZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (z, i) in privateDns.zoneNames: if (privateDns.createZones) {
    parent: newZones[i]
    name: '${privateDns.vnetLinkName}-${replace(z, '.', '-')}'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnetId
      }
    }
  }
]

resource existingZoneLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [
  for (z, i) in privateDns.zoneNames: if (!privateDns.createZones) {
    parent: existingZones[i]
    name: '${privateDns.vnetLinkName}-${replace(z, '.', '-')}'
    location: 'global'
    tags: tags
    properties: {
      registrationEnabled: false
      virtualNetwork: {
        id: vnetId
      }
    }
  }
]

@description('Map of zone name => zone resource ID.')
output zoneIds object = toObject(privateDns.zoneNames, z => z, z => resourceId('Microsoft.Network/privateDnsZones', z))
