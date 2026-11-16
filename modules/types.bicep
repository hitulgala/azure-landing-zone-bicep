// =============================================================================
// Shared user-defined types. They mirror the variable schemas of the
// Terraform repo one-to-one (snake_case keys become camelCase), so a value in
// terraform.tfvars has an obvious home in main.bicepparam.
//
// Terraform map(object(...))  ->  Bicep { *: someType }  (object with any keys)
// Terraform optional(x, d)    ->  Bicep `x?` with the default applied in code
// =============================================================================

// ---- Common ---------------------------------------------------------------------

@export()
type subscriptionIdsType = {
  governance: string
  hub: string
  identity: string
  workload: string
}

// ---- monitoring (governance) ------------------------------------------------------

@export()
type governanceType = {
  resourceGroupName: string
  logAnalytics: {
    name: string
    @minValue(30)
    @maxValue(730)
    retentionInDays: int
    @description('-1 = unlimited.')
    dailyQuotaGb: int
  }
  actionGroup: {
    name: string
    @maxLength(12)
    shortName: string
    @description('Receiver name => e-mail address.')
    emailReceivers: { *: string }
    @description('Receiver name => webhook URI.')
    webhookReceivers: { *: string }?
  }
  serviceHealthAlert: {
    name: string
    events: ('Incident' | 'Maintenance' | 'Informational' | 'ActionRequired' | 'Security')[]
    @description('[] or omitted = all regions.')
    locations: string[]?
  }
  @description('Forward subscription Activity Logs to the workspace. enabled = true in ONE region only.')
  activityLogDiagnostics: {
    enabled: bool
    name: string
    categories: string[]
  }
}

// ---- network ---------------------------------------------------------------------

@export()
type nsgRuleType = {
  description: string?
  @minValue(100)
  @maxValue(4095)
  priority: int
  direction: 'Inbound' | 'Outbound'
  access: 'Allow' | 'Deny'
  protocol: 'Tcp' | 'Udp' | 'Icmp' | '*'
  @description('Default "*".')
  sourcePortRange: string?
  destinationPortRanges: string[]
  sourceAddressPrefixes: string[]
  destinationAddressPrefixes: string[]
}

@export()
type subnetType = {
  addressPrefixes: string[]
  @description('Key of networkSecurityGroups in the same network.')
  nsg: string?
  @description('Key of routeTables in the same network.')
  routeTable: string?
  delegation: {
    name: string
    serviceName: string
  }?
  @description('Default "Disabled".')
  privateEndpointNetworkPolicies: ('Disabled' | 'Enabled' | 'NetworkSecurityGroupEnabled' | 'RouteTableEnabled')?
  @description('Default true.')
  defaultOutboundAccessEnabled: bool?
}

@export()
type nsgType = {
  @description('Default true. Adds Allow-AzureLoadBalancer-Inbound (4000) and Deny-All-Inbound (4096).')
  addDenyAllInbound: bool?
  rules: { *: nsgRuleType }?
}

@export()
type routeTableType = {
  @description('Default false.')
  bgpRoutePropagationEnabled: bool?
  routes: {
    *: {
      addressPrefix: string
      nextHopType: 'VirtualAppliance' | 'Internet' | 'VirtualNetworkGateway' | 'VnetLocal' | 'None'
      nextHopInIpAddress: string?
    }
  }
}

@export()
type networkType = {
  resourceGroupName: string
  diagnosticSettingName: string
  vnet: {
    name: string
    addressSpace: string[]
    dnsServers: string[]?
  }
  subnets: { *: subnetType }
  networkSecurityGroups: { *: nsgType }?
  routeTables: { *: routeTableType }?
}

// ---- hub: firewall, DNS resolver, Private DNS ------------------------------------------

@export()
type firewallType = {
  subnetName: string
  name: string
  publicIpName: string
  policyName: string
  skuTier: 'Standard' | 'Premium'
  @description('["1","2","3"] or [] in a region without zones.')
  zones: string[]
  threatIntelligenceMode: 'Off' | 'Alert' | 'Deny'
  dnsProxyEnabled: bool
  @description('Resolver inbound IP.')
  dnsServers: string[]
  diagnosticSettingName: string
  ruleCollectionGroup: {
    name: string
    priority: int
  }
  networkRuleCollections: {
    name: string
    priority: int
    action: 'Allow' | 'Deny'
    rules: {
      name: string
      protocols: ('TCP' | 'UDP' | 'ICMP' | 'Any')[]
      sourceAddresses: string[]
      destinationAddresses: string[]
      destinationPorts: string[]
    }[]
  }[]
  healthAlert: {
    name: string
    severity: int
    threshold: int
  }
}

@export()
type dnsResolverType = {
  inboundSubnetName: string
  outboundSubnetName: string
  name: string
  inboundEndpointName: string
  @description('First usable address of the inbound subnet (.4).')
  inboundStaticIp: string
  outboundEndpointName: string
  rulesetName: string
  rulesetVnetLinkName: string
  @description('Rule name => { domainName (trailing dot), targetDnsServers }.')
  forwardingRules: {
    *: {
      domainName: string
      targetDnsServers: string[]
    }
  }
}

@export()
type privateDnsType = {
  @description('true in the PRIMARY region, false in the SECONDARY (link only).')
  createZones: bool
  @description('RG that holds the zones: the PRIMARY hub network RG.')
  resourceGroupName: string
  vnetLinkName: string
  zoneNames: string[]
}

@export()
type hubType = {
  network: networkType
  firewall: firewallType
  dnsResolver: dnsResolverType
  privateDns: privateDnsType
}

// ---- identity: Key Vault, domain controllers ----------------------------------------------

@export()
type keyVaultType = {
  @minLength(3)
  @maxLength(24)
  name: string
  skuName: 'standard' | 'premium'
  purgeProtectionEnabled: bool
  @minValue(7)
  @maxValue(90)
  softDeleteRetentionDays: int
  publicNetworkAccessEnabled: bool
  @description('Plain IPs, not /32.')
  allowedIpRanges: string[]?
  @description('Default "Allow".')
  networkDefaultAction: ('Allow' | 'Deny')?
  secretName: string
  diagnosticSettingName: string
  privateEndpoint: {
    name: string
    connectionName: string
    subnetName: string
  }
  privateDnsZoneName: string
}

@export()
type domainControllersType = {
  subnetName: string
  settings: {
    adminUsername: string
    vmSize: string
    osDiskType: 'Premium_LRS' | 'StandardSSD_LRS' | 'Standard_LRS' | 'PremiumV2_LRS' | 'Premium_ZRS' | 'StandardSSD_ZRS'
    dataDiskType:
      | 'Premium_LRS'
      | 'StandardSSD_LRS'
      | 'Standard_LRS'
      | 'PremiumV2_LRS'
      | 'Premium_ZRS'
      | 'StandardSSD_ZRS'
    ntdsDiskSizeGb: int
    @description('"Windows_Server" for Azure Hybrid Benefit, or omit.')
    licenseType: string?
    timezone: string
    acceleratedNetworkingEnabled: bool
    image: {
      publisher: string
      offer: string
      sku: string
      version: string
    }
  }
  @description('For regions WITHOUT zones. Omit when DCs use zones.')
  availabilitySet: {
    name: string
    platformFaultDomainCount: int
    platformUpdateDomainCount: int
  }?
  @description('Computer name (max 15 chars) => DC definition.')
  servers: {
    *: {
      vmName: string
      nicName: string
      osDiskName: string
      ntdsDiskName: string
      privateIp: string
      @description('"1"/"2"/"3", or omit with an availability set.')
      zone: string?
    }
  }
}

@export()
type identityType = {
  network: networkType
  keyVault: keyVaultType
  domainControllers: domainControllersType
}

// ---- workload: Recovery Services Vault ----------------------------------------------------

@export()
type workloadType = {
  network: networkType
  recoveryVault: {
    vault: {
      name: string
      storageModeType: 'GeoRedundant' | 'LocallyRedundant' | 'ZoneRedundant'
      crossRegionRestoreEnabled: bool
      immutability: 'Disabled' | 'Unlocked' | 'Locked'
      diagnosticSettingName: string
    }
    @description('Omit = no VM backup policy.')
    vmBackupPolicy: {
      name: string
      @description('Windows time zone name.')
      timezone: string
      @description('HH:MM, 24h, on the quarter hour.')
      time: string
      dailyRetentionDays: int
      @minValue(1)
      @maxValue(5)
      instantRestoreRetentionDays: int
    }?
  }
}

// ---- peerings ----------------------------------------------------------------------

@export()
type peeringNamesType = {
  hubToSpoke: string
  spokeToHub: string
}

@export()
type primaryPeeringsType = {
  hubIdentity: peeringNamesType
  hubWorkload: peeringNamesType
}

@export()
type secondaryPeeringsType = {
  hubIdentity: peeringNamesType
  hubWorkload: peeringNamesType
  hubPrimaryHub: {
    thisHubToPrimaryHub: string
    primaryHubToThisHub: string
  }
}

@export()
@description('Where the PRIMARY hub lives (primary stack outputs). Replaces the Terraform data sources.')
type primaryHubType = {
  resourceGroupName: string
  vnetName: string
}

// ---- policy ------------------------------------------------------------------------

@export()
type policyDefinitionNamesType = {
  requireTagOnResourceGroups: string
  inheritTagFromResourceGroup: string
  requireTagOnResources: string
}

@export()
@description('Built-in definition display name => { id (GUID), roleDefinitionIds needed by Modify/DINE policies }.')
type builtInPolicyDefinitionsType = {
  *: {
    id: string
    roleDefinitionIds: string[]?
  }
}

@export()
type subscriptionPoliciesType = {
  mandatoryTags: {
    requireOnResourceGroups: bool
    inheritFromResourceGroup: bool
    requireOnResources: bool
    enforce: bool
  }
  @description('Assignment name (max 64 chars) => assignment.')
  assignments: {
    *: {
      displayName: string
      definitionDisplayName: string
      enforce: bool?
      parameters: object?
      identity: bool?
    }
  }
}

@export()
type policiesType = {
  governance: subscriptionPoliciesType
  hub: subscriptionPoliciesType
  identity: subscriptionPoliciesType
  workload: subscriptionPoliciesType
}
