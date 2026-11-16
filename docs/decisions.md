# Design decisions

## Infrastructure
| # | Decision |
|---|----------|
| 1 | Two stacks, one per region, each with its own `main.bicep`. Each stack is **one subscription-scope deployment** at the governance subscription that reaches all four subscriptions through module scopes (`subscription(<id>)`, `resourceGroup(<id>, <name>)`). |
| 2 | **All deployment values live in `main.bicepparam`.** Code contains only Azure-mandated constants (documented inline). Subscription IDs and the DC password are the exceptions (decisions 9 and 18). |
| 3 | Parameters are typed with user-defined types (`modules/types.bicep`). Cross-field rules that types cannot express are checked by the deploy script before every deployment (pre-flight checks). |
| 4 | No management group code. Azure Policy is assigned at **subscription scope**, per subscription, from the primary stack only (policy is not regional). Built-in definitions are referenced by GUID through `builtInPolicyDefinitions`, which also lists the roles a Modify policy's identity needs. |
| 4a | Mandatory tags: `mandatoryTagNames` + `tags` in `main.bicepparam`; checked before deployment, required by every module, enforced by policy (require on resource groups, inherit from resource group). Other policies are rolled out in audit mode before enforcement. |
| 5 | Hub-and-spoke (not Virtual WAN). Azure Firewall **Standard**, one policy per region. Identity and workload VNets are spokes. |
| 6 | Private DNS zones exist once, in the primary hub network resource group. The secondary only links its hub VNet to them (`createZones: false`). |
| 7 | DNS path: spoke VMs -> firewall DNS proxy -> DNS Private Resolver inbound -> AD domain forwarded to the domain controllers. |
| 8 | Identity: domain controllers with private IPs only; count, size, image and placement (availability set or zones) are set in `main.bicepparam`. Default: two DCs per region in an availability set. AD DS promotion is manual. |
| 9 | DC admin password: Bicep cannot generate secrets, so the deploy script generates it on the first run, the deployment stores it in Key Vault (RBAC, purge protection, private endpoint) as a secure parameter, and later runs read it back. A new password is never generated while the vault exists, because it would not match the existing DCs. |
| 10 | Workload subscription: resource group, VNet, NSGs, route table, Recovery Services Vault. No VMs, SQL or storage. |
| 11 | DCs are not backed up. DR = native AD replication to the other region. Enable AD Recycle Bin after promotion. |
| 12 | Log Analytics workspace per region in the governance subscription; retention is set in `main.bicepparam`. |
| 13 | Spoke route tables and DNS servers reference the firewall IP (first free address of AzureFirewallSubnet) from `main.bicepparam`; the deployment outputs `firewallIpMatchesExpected` and the deploy script warns if Azure assigned a different address. |
| 14 | An activity log alert rule may watch only one subscription, so the Service Health alert is created **once per distinct subscription**, in a resource group of that subscription, all routed to one action group. |
| 15 | Subnets, NSG rules and route associations are declared inline (inside the VNet and NSG), so each is written in a single request and removed rules disappear from Azure. |
| 16 | No state file: Azure Resource Manager is the source of truth and every deployment is idempotent. Resources removed from the code are **not** deleted automatically; Deployment Stacks are on the roadmap for that. |

## Delivery (CI/CD)
| # | Decision |
|---|----------|
| 17 | GitHub Actions with two workflows: **Bicep What-If** (pull requests, `main`, manual) and **Bicep Deploy** (started by `workflow_run` when a What-If on a push to `main` succeeds, or manually). Previewing and deploying are separate concerns. |
| 18 | Subscription IDs are kept out of Git: `scripts/ids.local.ps1` (git-ignored) locally, repository variables in CI. Both reach the deployment as environment variables read by `readEnvironmentVariable()`. |
| 19 | A what-if is a prediction, not an artifact: Bicep Deploy deploys the **same commit** that was previewed and ARM re-evaluates it. Approvers review the linked what-if before approving. |
| 20 | Production deployments require approval on the `prod` environment, which only `main` may deploy to. Automatic deployments cover the primary stack; the secondary is a deliberate manual run. |
| 21 | The pipeline authenticates with **OIDC** (workload identity federation): a dedicated app registration with three federated credentials (`main` branch, pull requests, `prod` environment). No client secret exists. |
| 22 | The pipeline identity has Contributor, User Access Administrator and Resource Policy Contributor on each subscription, plus **Key Vault Secrets User** on vaults it did not create, so it can read the existing DC password. |
| 23 | Key Vault allows public network access, protected by RBAC, because GitHub-hosted runners have no fixed IP. Network restrictions are configured in `main.bicepparam` once deployments run inside the VNet. |
| 24 | The Bicep CLI version is pinned (`BICEP_VERSION` variable) so that format checks and compilation behave the same in CI as on the laptop. |

## Open items
* The secondary stack is not yet published or deployed by the pipeline.
* Removed resources are not deleted automatically (decision 16).
* Policy: only built-in definitions are used. Tag *values* are not validated (only presence).
* Verify VM size availability and Windows Server image compatibility in both regions before changing them.
* Firewall rules cover Active Directory and internal ICMP only. Internet egress (for example Windows Update) needs application rules.
* Log Analytics long-term archive, VM guest monitoring (Azure Monitor Agent), Defender for Cloud and RBAC design are not covered.
