# Modules

Nine single-purpose modules, called by both stacks, mirroring the Terraform modules one-to-one. Rules for every module:
* No subscription logic inside: the stack decides the scope (`subscription()` or `resourceGroup()`).
* No hard-coded deployment values: everything arrives through typed parameters from `types.bicep`. The only literals are Azure-mandated constants, commented inline.
* `tags` is a required input and is applied to every taggable resource.

| Module | Scope | What it builds |
|--------|-------|----------------|
| `monitoring` | Subscription (Governance) | Resource group, Log Analytics workspace, action group, Service Health alert; `activity-log.bicep` forwards one subscription's Activity Log |
| `network` | Subscription (Hub / Identity / Workload) | Resource group, VNet with inline subnets, NSGs with inline rules (+ optional LB-probe/deny-all baseline), route tables, NSG diagnostics |
| `firewall` | Hub network RG | Public IP, firewall policy (DNS proxy), rule collection group, Azure Firewall, diagnostics, health alert |
| `dns` | Hub network RG | DNS Private Resolver, inbound/outbound endpoints, forwarding ruleset, rules and VNet link; `private-dns.bicep` creates (primary) or links to (secondary) the Private DNS zones |
| `peering` | Subscription (any) | Both halves of a VNet peering, each a nested deployment in its own subscription (`half.bicep`) |
| `key-vault` | Identity network RG | Key Vault (RBAC, purge protection, network ACLs), private endpoint, deployer Secrets Officer role, DC password secret, diagnostics |
| `domain-controllers` | Identity network RG | Optional availability set, NICs with static IPs, NTDS managed disks, VMs |
| `recovery-vault` | Workload network RG | Recovery Services Vault, optional daily VM backup policy, diagnostics |
| `policy` | Subscription (one call per subscription) | Mandatory-tag policies (require on RG, inherit, require on resources) + free-form built-in assignments, with roles for Modify identities |

Modules with subscription scope (`monitoring`, `network`) create their own resource group and deploy their resources through a nested `resources.bicep`.
