# Modules

Nine single-purpose modules, called by both regional stacks. Rules for every module:
* **No subscription logic inside.** The stack decides where a module runs with `scope: subscription(<id>)` or `scope: resourceGroup(<id>, <name>)`.
* **No hard-coded deployment values.** Everything arrives through typed parameters defined in [`types.bicep`](types.bicep). The only literals are Azure-mandated constants, commented inline.
* **`tags` is a required input** and is applied to every taggable resource.

| Module | Scope | What it builds |
|--------|-------|----------------|
| `monitoring` | Subscription (governance) | Resource group, Log Analytics workspace, action group. `activity-log.bicep` forwards one subscription's Activity Log; `service-health-alert.bicep` creates one subscription's Service Health alert |
| `network` | Subscription (hub / identity / workload) | Resource group, VNet with inline subnets, NSGs with inline rules (+ optional load-balancer-probe / deny-all baseline), route tables, NSG diagnostics |
| `firewall` | Hub network RG | Public IP, firewall policy (DNS proxy), network rule collection group, Azure Firewall, diagnostics, health alert |
| `dns` | Hub network RG | DNS Private Resolver, inbound (static IP) and outbound endpoints, forwarding ruleset, rules and VNet link. `private-dns.bicep` creates the Private DNS zones (primary) or links to them (secondary) |
| `peering` | Subscription (any) | Both halves of a VNet peering, each a nested deployment in its own subscription (`half.bicep`) |
| `key-vault` | Identity network RG | Key Vault (RBAC, purge protection, network ACLs), private endpoint and DNS zone group, Secrets Officer role for the deploying identity, DC password secret, diagnostics |
| `domain-controllers` | Identity network RG | Optional availability set, NICs with static IPs, NTDS managed disks (host caching None), Windows Server VMs |
| `recovery-vault` | Workload network RG | Recovery Services Vault (redundancy, cross-region restore, immutability), optional daily VM backup policy, diagnostics |
| `policy` | Subscription (one call per subscription) | Mandatory-tag policies (require on RG, inherit from RG, optionally require on resources) and free-form built-in assignments, with role assignments for Modify identities |

Modules with subscription scope (`monitoring`, `network`) create their own resource group and deploy their resources through a nested `resources.bicep`.

## Typed parameters
`types.bicep` exports one type per stack parameter (`networkType`, `firewallType`, `identityType`, ...). Maps such as subnets, NSGs, routes and servers are objects with any keys (`{ *: subnetType }`), so names are written once, as keys. A wrong key or a wrong value type fails at build time (`bicep build-params`), before anything reaches Azure. Cross-field rules that types cannot express (for example *a subnet's NSG must exist in the same network*) are checked by `scripts/Deploy-LandingZone.ps1` before every deployment.
