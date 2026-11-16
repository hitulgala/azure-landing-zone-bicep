// =============================================================================
// Module  : domain-controllers   (IDENTITY subscription)
// Purpose : Domain-controller-ready Windows Server VMs (NO AD DS promotion):
//           optional availability set + per DC: NIC (static private IP, no
//           public IP), OS disk, dedicated NTDS data disk, VM.
//
//   Region WITH Availability Zones   : omit availabilitySet, each DC has a zone
//   Region WITHOUT Availability Zones: availabilitySet = {...}, omit every zone
//   (Deploy-LandingZone.ps1 checks this rule before deploying.)
//
// NTDS disk: AD database/logs go on a separate disk with host caching = None.
// Scope   : identity network resource group.
// =============================================================================
import { domainControllersType } from '../types.bicep'

param location string
param tags object
param subnetId string
@secure()
param adminPassword string
param domainControllers domainControllersType

var settings = domainControllers.settings
var servers = items(domainControllers.servers)
var useAvailabilitySet = domainControllers.?availabilitySet != null

resource availabilitySet 'Microsoft.Compute/availabilitySets@2024-07-01' = if (useAvailabilitySet) {
  name: domainControllers.?availabilitySet.?name ?? 'unused'
  location: location
  tags: tags
  sku: {
    name: 'Aligned' // Azure-mandated for managed disks
  }
  properties: {
    platformFaultDomainCount: domainControllers.?availabilitySet.?platformFaultDomainCount ?? 2
    platformUpdateDomainCount: domainControllers.?availabilitySet.?platformUpdateDomainCount ?? 5
  }
}

resource nic 'Microsoft.Network/networkInterfaces@2024-05-01' = [
  for dc in servers: {
    name: dc.value.nicName
    location: location
    tags: tags
    properties: {
      enableAcceleratedNetworking: settings.acceleratedNetworkingEnabled
      ipConfigurations: [
        {
          name: 'ipconfig1'
          properties: {
            privateIPAllocationMethod: 'Static' // DCs need fixed IPs
            privateIPAddress: dc.value.privateIp
            subnet: {
              id: subnetId
            }
          }
        }
      ]
    }
  }
]

resource ntdsDisk 'Microsoft.Compute/disks@2024-03-02' = [
  for dc in servers: {
    name: dc.value.ntdsDiskName
    location: location
    tags: tags
    zones: dc.value.?zone == null ? null : [dc.value.zone!] // must match the VM zone
    sku: {
      name: settings.dataDiskType
    }
    properties: {
      creationData: {
        createOption: 'Empty'
      }
      diskSizeGB: settings.ntdsDiskSizeGb
    }
  }
]

resource vm 'Microsoft.Compute/virtualMachines@2024-07-01' = [
  for (dc, i) in servers: {
    name: dc.value.vmName
    location: location
    tags: tags
    zones: dc.value.?zone == null ? null : [dc.value.zone!]
    properties: {
      availabilitySet: useAvailabilitySet ? { id: availabilitySet.id } : null
      licenseType: settings.?licenseType // "Windows_Server" = Azure Hybrid Benefit
      hardwareProfile: {
        vmSize: settings.vmSize
      }
      osProfile: {
        computerName: dc.key // NetBIOS name, max 15 chars
        adminUsername: settings.adminUsername
        adminPassword: adminPassword
        windowsConfiguration: {
          provisionVMAgent: true
          enableAutomaticUpdates: true
          timeZone: settings.timezone
        }
      }
      storageProfile: {
        imageReference: settings.image
        osDisk: {
          name: dc.value.osDiskName
          createOption: 'FromImage'
          caching: 'ReadWrite'
          managedDisk: {
            storageAccountType: settings.osDiskType
          }
        }
        dataDisks: [
          {
            lun: 0
            createOption: 'Attach'
            caching: 'None'
            managedDisk: {
              id: ntdsDisk[i].id
            }
          }
        ]
      }
      networkProfile: {
        networkInterfaces: [
          {
            id: nic[i].id
          }
        ]
      }
      diagnosticsProfile: {
        bootDiagnostics: {
          enabled: true // managed boot diagnostics, no storage account needed
        }
      }
    }
  }
]

output privateIps object = toObject(servers, dc => dc.key, dc => dc.value.privateIp)
