// ==============================================================================
// primary-centralindia  |  ALL deployment values live in this file (= terraform.tfvars).
// IP plan:  Central India 10.10.0.0/16   South India 10.20.0.0/16
// Search for "<--" to find the values you must change.
//
// NOT in this file (read from environment variables set by
// scripts/Deploy-LandingZone.ps1, never committed):
//   * subscription IDs  -> scripts/ids.local.ps1 locally, GitHub variables in CI
//   * DC admin password -> generated once, then read back from Key Vault
// ==============================================================================
using 'main.bicep'

param subscriptionIds = {
  governance: readEnvironmentVariable('ALZ_SUB_GOVERNANCE', '')
  hub: readEnvironmentVariable('ALZ_SUB_HUB', '')
  identity: readEnvironmentVariable('ALZ_SUB_IDENTITY', '')
  workload: readEnvironmentVariable('ALZ_SUB_WORKLOAD', '')
}

param dcAdminPassword = readEnvironmentVariable('ALZ_DC_ADMIN_PASSWORD', '')

// ------------------------------------------------------------------ Placement and tags
param location = 'centralindia'

// MANDATORY tags. Every name in mandatoryTagNames must have a value in 'tags'
// (Deploy-LandingZone.ps1 stops before deploying otherwise). 'tags' is applied to
// EVERY taggable resource, and the policies enforce the same tags in Azure.
// Use the SAME values in both regions.
param mandatoryTagNames = ['environment', 'workload', 'owner', 'cost_center', 'managed_by']

param tags = {
  environment: 'production'
  workload: 'platform-landing-zone'
  owner: 'platform-team@example.com' // <-- change
  cost_center: 'CC-0000' // <-- change
  managed_by: 'bicep'
}

// First free address of AzureFirewallSubnet. Must equal the next-hop IP used in the
// spoke route tables and the DNS servers below. The deploy script warns if Azure
// assigns another (output firewallIpMatchesExpected).
param expectedFirewallPrivateIp = '10.10.0.4'

// ------------------------------------------------------------------ GOVERNANCE subscription
// Activity Logs are subscription-wide: forwarded here (primary), disabled in the secondary.
param governance = {
  resourceGroupName: 'rg-gov-prd-cin-001'
  logAnalytics: {
    name: 'log-platform-prd-cin-001'
    retentionInDays: 60
    dailyQuotaGb: -1
  }
  actionGroup: {
    name: 'ag-platform-prd-cin-001'
    shortName: 'platform-ag' // max 12 characters
    emailReceivers: {
      'platform-team': 'platform-team@example.com'
    }
  }
  serviceHealthAlert: {
    name: 'alert-svchealth-prd-cin-001'
    events: ['Incident', 'Maintenance', 'ActionRequired', 'Security']
    locations: ['centralindia', 'southindia']
  }
  activityLogDiagnostics: {
    enabled: true
    name: 'diag-activitylog-to-law'
    categories: [
      'Administrative'
      'Security'
      'ServiceHealth'
      'Alert'
      'Recommendation'
      'Policy'
      'Autoscale'
      'ResourceHealth'
    ]
  }
}

// ------------------------------------------------------------------ HUB subscription
// network: RG, VNet, subnets, NSGs, route tables. AzureFirewallSubnet, GatewaySubnet
// and AzureBastionSubnet names are mandated by Azure (Gateway/Bastion are reserved).
// The firewall route table sends the OTHER region's range to the OTHER firewall.
// firewall: Azure Firewall denies everything not allowed. Internet egress (e.g.
// Windows Update) needs application rules and is NOT included.
// privateDns: zones are CREATED by the primary and only LINKED from the secondary.
param hub = {
  network: {
    resourceGroupName: 'rg-net-prd-cin-001'
    diagnosticSettingName: 'diag-nsg-to-law'
    vnet: {
      name: 'vnet-hub-prd-cin-001'
      addressSpace: ['10.10.0.0/22']
      dnsServers: [] // hub uses Azure-provided DNS so the resolver works
    }
    subnets: {
      AzureFirewallSubnet: {
        addressPrefixes: ['10.10.0.0/26']
        routeTable: 'rt-afw-prd-cin-001' // cross-region route (below)
      }
      GatewaySubnet: {
        addressPrefixes: ['10.10.0.128/27']
      }
      AzureBastionSubnet: {
        addressPrefixes: ['10.10.0.192/26']
      }
      'snet-dns-inbound': {
        addressPrefixes: ['10.10.1.0/28']
        delegation: {
          name: 'dnsresolver'
          serviceName: 'Microsoft.Network/dnsResolvers'
        }
      }
      'snet-dns-outbound': {
        addressPrefixes: ['10.10.1.16/28']
        delegation: {
          name: 'dnsresolver'
          serviceName: 'Microsoft.Network/dnsResolvers'
        }
      }
      'snet-shared': {
        addressPrefixes: ['10.10.1.64/26']
        nsg: 'nsg-shared-prd-cin-001'
        privateEndpointNetworkPolicies: 'Enabled'
      }
    }
    networkSecurityGroups: {
      'nsg-shared-prd-cin-001': {
        addDenyAllInbound: true
        rules: {
          'Allow-Internal-PrivateEndpoints': {
            description: 'HTTPS and SQL to private endpoints from internal networks'
            priority: 100
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            destinationPortRanges: ['443', '1433']
            sourceAddressPrefixes: ['10.10.0.0/16', '10.20.0.0/16']
            destinationAddressPrefixes: ['10.10.1.64/26']
          }
        }
      }
    }
    routeTables: {
      'rt-afw-prd-cin-001': {
        bgpRoutePropagationEnabled: true
        routes: {
          'default-to-internet': {
            addressPrefix: '0.0.0.0/0'
            nextHopType: 'Internet'
          }
          'to-south-india': {
            addressPrefix: '10.20.0.0/16'
            nextHopType: 'VirtualAppliance'
            nextHopInIpAddress: '10.20.0.4'
          }
        }
      }
    }
  }
  firewall: {
    subnetName: 'AzureFirewallSubnet'
    name: 'afw-prd-cin-001'
    publicIpName: 'pip-afw-prd-cin-001'
    policyName: 'afwp-prd-cin-001'
    skuTier: 'Standard'
    zones: ['1', '2', '3']
    threatIntelligenceMode: 'Alert'
    dnsProxyEnabled: true
    dnsServers: ['10.10.1.4'] // = dnsResolver.inboundStaticIp below
    diagnosticSettingName: 'diag-afw-to-law'
    ruleCollectionGroup: {
      name: 'rcg-net-prd-cin-001'
      priority: 200
    }
    networkRuleCollections: [
      {
        name: 'allow-active-directory'
        priority: 100
        action: 'Allow'
        rules: [
          {
            name: 'ad-tcp'
            protocols: ['TCP']
            sourceAddresses: ['10.10.0.0/16', '10.20.0.0/16']
            destinationAddresses: ['10.10.4.0/27', '10.20.4.0/27']
            destinationPorts: ['53', '88', '135', '389', '445', '464', '636', '3268', '3269', '9389', '49152-65535']
          }
          {
            name: 'ad-udp'
            protocols: ['UDP']
            sourceAddresses: ['10.10.0.0/16', '10.20.0.0/16']
            destinationAddresses: ['10.10.4.0/27', '10.20.4.0/27']
            destinationPorts: ['53', '88', '123', '389', '464']
          }
          {
            name: 'dc-to-dc-replication'
            protocols: ['Any']
            sourceAddresses: ['10.10.4.0/27', '10.20.4.0/27']
            destinationAddresses: ['10.10.4.0/27', '10.20.4.0/27']
            destinationPorts: ['*']
          }
        ]
      }
      {
        name: 'allow-internal-icmp'
        priority: 110
        action: 'Allow'
        rules: [
          {
            name: 'icmp-internal'
            protocols: ['ICMP']
            sourceAddresses: ['10.10.0.0/16', '10.20.0.0/16']
            destinationAddresses: ['10.10.0.0/16', '10.20.0.0/16']
            destinationPorts: ['*']
          }
        ]
      }
    ]
    healthAlert: {
      name: 'alert-afw-health-prd-cin'
      severity: 1
      threshold: 90
    }
  }
  dnsResolver: {
    inboundSubnetName: 'snet-dns-inbound'
    outboundSubnetName: 'snet-dns-outbound'
    name: 'dnspr-prd-cin'
    inboundEndpointName: 'dnspr-prd-cin-inbound'
    inboundStaticIp: '10.10.1.4' // first usable address of snet-dns-inbound
    outboundEndpointName: 'dnspr-prd-cin-outbound'
    rulesetName: 'dnspr-prd-cin-ruleset'
    rulesetVnetLinkName: 'link-ruleset-hub-prd-cin'
    forwardingRules: {
      'ad-domain': {
        domainName: 'corp.example.com.' // <-- your AD domain, trailing dot required
        targetDnsServers: ['10.10.4.4', '10.10.4.5', '10.10.4.6', '10.20.4.4', '10.20.4.5']
      }
    }
  }
  privateDns: {
    createZones: true // PRIMARY creates the zones
    resourceGroupName: 'rg-net-prd-cin-001'
    vnetLinkName: 'link-hub-prd-cin'
    zoneNames: [
      'privatelink.vaultcore.azure.net'
      'privatelink.blob.core.windows.net'
      'privatelink.file.core.windows.net'
      'privatelink.database.windows.net'
    ]
  }
}

// ------------------------------------------------------------------ IDENTITY subscription
// domainControllers.servers: key = Windows computer name (max 15 chars); first
// usable IP is .4. Region WITHOUT zones: keep availabilitySet and omit every zone.
// Region WITH zones: remove availabilitySet and give each DC zone: '1' / '2' / '3'.
param identity = {
  network: {
    resourceGroupName: 'rg-adds-prd-cin-001'
    diagnosticSettingName: 'diag-nsg-to-law'
    vnet: {
      name: 'vnet-adds-prd-cin-001'
      addressSpace: ['10.10.4.0/24']
      dnsServers: ['10.10.0.4'] // hub firewall (DNS proxy) = expectedFirewallPrivateIp
    }
    subnets: {
      'snet-dc-001': {
        addressPrefixes: ['10.10.4.0/27']
        nsg: 'nsg-dc-prd-cin-001'
        routeTable: 'rt-adds-prd-cin-001'
        defaultOutboundAccessEnabled: false
      }
      'snet-mgmt-001': {
        addressPrefixes: ['10.10.4.32/27']
        nsg: 'nsg-mgmt-prd-cin-001'
        routeTable: 'rt-adds-prd-cin-001'
        defaultOutboundAccessEnabled: false
      }
      'snet-pe-001': {
        addressPrefixes: ['10.10.4.64/27']
        nsg: 'nsg-pe-prd-cin-001'
        privateEndpointNetworkPolicies: 'Enabled'
      }
    }
    networkSecurityGroups: {
      'nsg-dc-prd-cin-001': {
        addDenyAllInbound: true
        rules: {
          'Allow-AD-TCP-Inbound': {
            description: 'Active Directory TCP from internal networks'
            priority: 100
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            destinationPortRanges: [
              '53'
              '88'
              '135'
              '389'
              '445'
              '464'
              '636'
              '3268'
              '3269'
              '9389'
              '49152-65535'
            ]
            sourceAddressPrefixes: ['10.10.0.0/16', '10.20.0.0/16']
            destinationAddressPrefixes: ['10.10.4.0/27']
          }
          'Allow-AD-UDP-Inbound': {
            description: 'Active Directory UDP (DNS, Kerberos, NTP, LDAP)'
            priority: 110
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Udp'
            destinationPortRanges: ['53', '88', '123', '389', '464']
            sourceAddressPrefixes: ['10.10.0.0/16', '10.20.0.0/16']
            destinationAddressPrefixes: ['10.10.4.0/27']
          }
          'Allow-RDP-From-Bastion': {
            description: 'RDP from the reserved hub Bastion subnet (remove if you will not use Bastion)'
            priority: 200
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            destinationPortRanges: ['3389']
            sourceAddressPrefixes: ['10.10.0.192/26']
            destinationAddressPrefixes: ['10.10.4.0/27']
          }
        }
      }
      'nsg-mgmt-prd-cin-001': {
        addDenyAllInbound: true
        rules: {
          'Allow-RDP-From-Bastion': {
            priority: 100
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            destinationPortRanges: ['3389']
            sourceAddressPrefixes: ['10.10.0.192/26']
            destinationAddressPrefixes: ['10.10.4.32/27']
          }
        }
      }
      'nsg-pe-prd-cin-001': {
        addDenyAllInbound: true
        rules: {
          'Allow-Internal-HTTPS': {
            description: 'HTTPS to the Key Vault private endpoint'
            priority: 100
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            destinationPortRanges: ['443']
            sourceAddressPrefixes: ['10.10.0.0/16', '10.20.0.0/16']
            destinationAddressPrefixes: ['10.10.4.64/27']
          }
        }
      }
    }
    routeTables: {
      'rt-adds-prd-cin-001': {
        bgpRoutePropagationEnabled: false
        routes: {
          'default-to-firewall': {
            addressPrefix: '0.0.0.0/0'
            nextHopType: 'VirtualAppliance'
            nextHopInIpAddress: '10.10.0.4'
          }
        }
      }
    }
  }
  keyVault: {
    name: 'kv-adds-bcp-cin-002' // <-- globally unique, 3-24 chars
    skuName: 'standard'
    purgeProtectionEnabled: true
    softDeleteRetentionDays: 90
    publicNetworkAccessEnabled: true // keep true only while deploying from OUTSIDE the VNet
    networkDefaultAction: 'Allow'
    secretName: 'dc-local-admin-password'
    diagnosticSettingName: 'diag-kv-to-law'
    privateEndpoint: {
      name: 'pe-kv-adds-prd-cin'
      connectionName: 'psc-kv-adds-prd-cin'
      subnetName: 'snet-pe-001' // subnet of identity.network that hosts the endpoint
    }
    privateDnsZoneName: 'privatelink.vaultcore.azure.net' // must be in hub.privateDns.zoneNames
  }
  domainControllers: {
    subnetName: 'snet-dc-001'
    settings: {
      adminUsername: 'dcadmin' // <-- change (not Administrator / admin)
      vmSize: 'Standard_B2ats_v2' // VERIFY availability: Get-AzComputeResourceSku | Where-Object Locations -contains <region>
      osDiskType: 'StandardSSD_LRS'
      dataDiskType: 'StandardSSD_LRS'
      ntdsDiskSizeGb: 32
      timezone: 'India Standard Time'
      acceleratedNetworkingEnabled: true
      image: {
        publisher: 'MicrosoftWindowsServer'
        offer: 'WindowsServer'
        sku: '2019-datacenter-gensecond'
        version: 'latest'
      }
    }
    availabilitySet: {
      name: 'avset-adds-prd-cin-001'
      platformFaultDomainCount: 2
      platformUpdateDomainCount: 5
    }
    servers: {
      CINDC01: {
        vmName: 'vm-cin-dc01'
        nicName: 'nic-cindc01'
        osDiskName: 'osdisk-cindc01'
        ntdsDiskName: 'datadisk-cindc01'
        privateIp: '10.10.4.4'
      }
      CINDC02: {
        vmName: 'vm-cin-dc02'
        nicName: 'nic-cindc02'
        osDiskName: 'osdisk-cindc02'
        ntdsDiskName: 'datadisk-cindc02'
        privateIp: '10.10.4.5'
      }
    }
  }
}

// ------------------------------------------------------------------ WORKLOAD subscription
param workload = {
  network: {
    resourceGroupName: 'rg-wld-prd-cin-001'
    diagnosticSettingName: 'diag-nsg-to-law'
    vnet: {
      name: 'vnet-wld-prd-cin-001'
      addressSpace: ['10.10.8.0/22']
      dnsServers: ['10.10.0.4'] // hub firewall (DNS proxy) = expectedFirewallPrivateIp
    }
    subnets: {
      'snet-app-001': {
        addressPrefixes: ['10.10.8.0/25']
        nsg: 'nsg-app-prd-cin-001'
        routeTable: 'rt-wld-prd-cin-001'
        defaultOutboundAccessEnabled: false
      }
      'snet-data-001': {
        addressPrefixes: ['10.10.8.128/26']
        nsg: 'nsg-data-prd-cin-001'
        routeTable: 'rt-wld-prd-cin-001'
        defaultOutboundAccessEnabled: false
      }
      'snet-pe-001': {
        addressPrefixes: ['10.10.8.192/26']
        nsg: 'nsg-pe-wld-prd-cin-001'
        privateEndpointNetworkPolicies: 'Enabled'
      }
    }
    networkSecurityGroups: {
      'nsg-app-prd-cin-001': {
        addDenyAllInbound: true
        rules: {
          'Allow-App-Inbound': {
            description: 'Application ports from internal networks'
            priority: 100
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            destinationPortRanges: ['443']
            sourceAddressPrefixes: ['10.10.0.0/16', '10.20.0.0/16']
            destinationAddressPrefixes: ['10.10.8.0/25']
          }
          'Allow-Admin-From-Bastion': {
            description: 'RDP/SSH from the reserved hub Bastion subnet (remove if unused)'
            priority: 200
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            destinationPortRanges: ['3389', '22']
            sourceAddressPrefixes: ['10.10.0.192/26']
            destinationAddressPrefixes: ['10.10.8.0/25']
          }
        }
      }
      'nsg-data-prd-cin-001': {
        addDenyAllInbound: true
        rules: {
          'Allow-SQL-From-App': {
            description: 'SQL from the app subnet only'
            priority: 100
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            destinationPortRanges: ['1433']
            sourceAddressPrefixes: ['10.10.8.0/25']
            destinationAddressPrefixes: ['10.10.8.128/26']
          }
        }
      }
      'nsg-pe-wld-prd-cin-001': {
        addDenyAllInbound: true
        rules: {
          'Allow-Internal-PrivateEndpoints': {
            description: 'HTTPS and SQL to private endpoints'
            priority: 100
            direction: 'Inbound'
            access: 'Allow'
            protocol: 'Tcp'
            destinationPortRanges: ['443', '1433']
            sourceAddressPrefixes: ['10.10.0.0/16', '10.20.0.0/16']
            destinationAddressPrefixes: ['10.10.8.192/26']
          }
        }
      }
    }
    routeTables: {
      'rt-wld-prd-cin-001': {
        bgpRoutePropagationEnabled: false
        routes: {
          'default-to-firewall': {
            addressPrefix: '0.0.0.0/0'
            nextHopType: 'VirtualAppliance'
            nextHopInIpAddress: '10.10.0.4'
          }
        }
      }
    }
  }
  recoveryVault: {
    vault: {
      name: 'rsv-wld-prd-cin-001'
      storageModeType: 'GeoRedundant'
      crossRegionRestoreEnabled: true
      immutability: 'Disabled'
      diagnosticSettingName: 'diag-rsv-to-law'
    }
    vmBackupPolicy: {
      name: 'bkppolicy-vm-daily'
      timezone: 'India Standard Time'
      time: '23:00'
      dailyRetentionDays: 30
      instantRestoreRetentionDays: 2
    }
  }
}

// ------------------------------------------------------------------ Peering names
param peerings = {
  hubIdentity: {
    hubToSpoke: 'peer-hub-to-adds-prd-cin-001'
    spokeToHub: 'peer-adds-to-hub-prd-cin-001'
  }
  hubWorkload: {
    hubToSpoke: 'peer-hub-to-wld-prd-cin-001'
    spokeToHub: 'peer-wld-to-hub-prd-cin-001'
  }
}

// ------------------------------------------------------------------ AZURE POLICY (per subscription, subscription scope)
// Each subscription has its OWN block, so rules can differ per subscription.
//   mandatoryTags.enforce = true : resource groups without the tags are denied and
//                                  resources inherit missing tags from their RG.
//   assignments.*.enforce = false: audit only (compliance report, nothing blocked).
//                                  Set true once the compliance report is clean.
// Assignments take up to ~30 min to become effective.
param policyDefinitionNames = {
  requireTagOnResourceGroups: 'Require a tag on resource groups'
  inheritTagFromResourceGroup: 'Inherit a tag from the resource group if missing'
  requireTagOnResources: 'Require a tag on resources'
}

// Built-in policy definitions, keyed by the display names used above and in
// 'policies'. Terraform resolves display names with a data source at plan time;
// Bicep has no data sources, so the fixed GUIDs (identical in every tenant) are
// listed here. roleDefinitionIds = roles the policy's managed identity needs
// (taken from the definition; Contributor for the inherit-tag Modify policy).
// Add an entry here before using a new definitionDisplayName in 'policies'.
param builtInPolicyDefinitions = {
  'Require a tag on resource groups': {
    id: '96670d01-0a4d-4649-9c89-2d3abc0a5025'
  }
  'Inherit a tag from the resource group if missing': {
    id: 'ea3f2387-9b95-492a-a190-fcdc54f7b070'
    roleDefinitionIds: ['b24988ac-6180-42a0-ab88-20f7382dd24c'] // Contributor
  }
  'Require a tag on resources': {
    id: '871b6d14-10aa-478d-b590-94f262ecfa99'
  }
  'Allowed locations': {
    id: 'e56962a6-4747-49cd-b67b-bf8b01975c4c'
  }
  'Allowed locations for resource groups': {
    id: 'e765b5de-1225-4ba3-bd56-1ac6695af988'
  }
  'Allowed virtual machine size SKUs': {
    id: 'cccc23c7-8427-4f53-ad12-b6a63eb452b3'
  }
  'Network interfaces should not have public IPs': {
    id: '83a86a26-fd1f-447c-b59d-e51f44264114'
  }
}

param policies = {
  governance: {
    mandatoryTags: {
      requireOnResourceGroups: true
      inheritFromResourceGroup: true
      requireOnResources: false
      enforce: true
    }
    assignments: {
      'allowed-locations': {
        displayName: 'Allowed locations'
        definitionDisplayName: 'Allowed locations'
        enforce: false
        parameters: {
          listOfAllowedLocations: ['centralindia', 'southindia', 'global']
        }
      }
      'allowed-locations-rg': {
        displayName: 'Allowed locations for resource groups'
        definitionDisplayName: 'Allowed locations for resource groups'
        enforce: false
        parameters: {
          listOfAllowedLocations: ['centralindia', 'southindia']
        }
      }
    }
  }
  hub: {
    mandatoryTags: {
      requireOnResourceGroups: true
      inheritFromResourceGroup: true
      requireOnResources: false
      enforce: true
    }
    assignments: {
      'allowed-locations': {
        displayName: 'Allowed locations'
        definitionDisplayName: 'Allowed locations'
        enforce: false
        parameters: {
          listOfAllowedLocations: ['centralindia', 'southindia', 'global']
        }
      }
      'allowed-locations-rg': {
        displayName: 'Allowed locations for resource groups'
        definitionDisplayName: 'Allowed locations for resource groups'
        enforce: false
        parameters: {
          listOfAllowedLocations: ['centralindia', 'southindia']
        }
      }
    }
  }
  identity: {
    mandatoryTags: {
      requireOnResourceGroups: true
      inheritFromResourceGroup: true
      requireOnResources: false
      enforce: true
    }
    assignments: {
      'allowed-locations': {
        displayName: 'Allowed locations'
        definitionDisplayName: 'Allowed locations'
        enforce: false
        parameters: {
          listOfAllowedLocations: ['centralindia', 'southindia', 'global']
        }
      }
      'allowed-locations-rg': {
        displayName: 'Allowed locations for resource groups'
        definitionDisplayName: 'Allowed locations for resource groups'
        enforce: false
        parameters: {
          listOfAllowedLocations: ['centralindia', 'southindia']
        }
      }
      'allowed-vm-skus': {
        displayName: 'Allowed VM SKUs (domain controllers)'
        definitionDisplayName: 'Allowed virtual machine size SKUs'
        enforce: false
        parameters: {
          listOfAllowedSKUs: ['Standard_D2as_v6', 'Standard_D4as_v6'] // <-- must include the VM sizes you deploy
        }
      }
      'nic-no-public-ip': {
        displayName: 'Network interfaces should not have public IPs'
        definitionDisplayName: 'Network interfaces should not have public IPs'
        enforce: false
      }
    }
  }
  workload: {
    mandatoryTags: {
      requireOnResourceGroups: true
      inheritFromResourceGroup: true
      requireOnResources: false
      enforce: true
    }
    assignments: {
      'allowed-locations': {
        displayName: 'Allowed locations'
        definitionDisplayName: 'Allowed locations'
        enforce: false
        parameters: {
          listOfAllowedLocations: ['centralindia', 'southindia', 'global']
        }
      }
      'allowed-locations-rg': {
        displayName: 'Allowed locations for resource groups'
        definitionDisplayName: 'Allowed locations for resource groups'
        enforce: false
        parameters: {
          listOfAllowedLocations: ['centralindia', 'southindia']
        }
      }
      'allowed-vm-skus': {
        displayName: 'Allowed VM SKUs (application servers)'
        definitionDisplayName: 'Allowed virtual machine size SKUs'
        enforce: false
        parameters: {
          listOfAllowedSKUs: ['Standard_D2as_v6', 'Standard_D4as_v6', 'Standard_D8as_v6'] // <-- must include the VM sizes you deploy
        }
      }
      'nic-no-public-ip': {
        displayName: 'Network interfaces should not have public IPs'
        definitionDisplayName: 'Network interfaces should not have public IPs'
        enforce: false
      }
    }
  }
}
