# Deployment notes and DR outline

## Permissions
Roles are assigned outside this repository. The identity that runs the deployment (you when deploying from a laptop, the pipeline's app registration in GitHub Actions) needs on **every subscription** in `subscriptionIds`:

| Role | Why |
|------|-----|
| Contributor | Creates and manages all resources |
| User Access Administrator | Creates role assignments: Key Vault Secrets Officer for the deploying identity and roles for the policy managed identities |
| Resource Policy Contributor | Creates the Azure Policy assignments |

**Owner** covers all three. The resource providers used (`Microsoft.Network`, `Microsoft.Compute`, `Microsoft.KeyVault`, `Microsoft.OperationalInsights`, `Microsoft.Insights`, `Microsoft.RecoveryServices`, `Microsoft.PolicyInsights`) must be registered on each subscription; see [local-deployment.md](local-deployment.md#2-sign-in-and-check-access).

## Deployment order
1. **Primary** (`primary-centralindia`): from a laptop ([local-deployment.md](local-deployment.md)) or through the pipeline ([cicd-pipeline.md](cicd-pipeline.md)).
2. **Secondary** (`secondary-southindia`): only after the primary succeeded. Copy `hubNetworkResourceGroupName` and `hubVnetName` from the primary outputs into its `primaryHub` parameter (they match the defaults if you kept the naming). The secondary links to the primary's Private DNS zones and creates both halves of the hub-to-hub peering.
3. **Verify the firewall IPs.** Each region's firewall IP is written into `main.bicepparam` (spoke routes, DNS servers and the other region's hub route). The deployment output `firewallIpMatchesExpected` is `false` if Azure assigned a different address than `expectedFirewallPrivateIp`, and the deploy script prints a warning. If that happens, correct the IP everywhere in the affected `main.bicepparam` files and redeploy both stacks.

Every deployment is idempotent: re-running the same stack only changes what differs, so a failed deployment is fixed by correcting the cause and running it again.

## The DC admin password
* **First run:** no Key Vault exists, so `Deploy-LandingZone.ps1` generates a 24-character password and passes it to the deployment as a secure parameter (through a process-local environment variable that is removed afterwards). The deployment stores it as the secret named in `identity.keyVault.secretName` and uses it for the DC VMs.
* **Later runs:** the script reads the secret back from Key Vault, so the VMs and the vault never disagree.
* **Safety rule:** if the vault exists but the secret cannot be read, the script stops instead of generating a new password.
* **Soft-deleted vault:** purge protection keeps a deleted vault's name reserved for the retention period. Recover it with `Undo-AzKeyVaultRemoval` rather than choosing a new name.

## Key Vault network access
Laptops and GitHub-hosted runners reach Key Vault over the internet, so the vault accepts public network traffic and relies on Entra ID RBAC (`enableRbacAuthorization: true`), in addition to its private endpoint.

When deployments run from inside the network (a self-hosted runner in the hub or identity VNet):
* restrict network access with `identity.keyVault.networkDefaultAction: 'Deny'` and `allowedIpRanges` (plain IPs without `/32`), or
* set `identity.keyVault.publicNetworkAccessEnabled: false` to allow the private endpoint only.

## Azure Policy
* Assigned by the **primary** stack only. Policy is subscription-wide, so resources of the secondary region are covered too.
* Mandatory-tag policies are enforced from the start (every resource group the stacks create carries the tags). Other assignments start with `enforce: false` (audit): review **Portal → Policy → Compliance**, then set `enforce: true` in a separate pull request.
* Assignments take up to about 30 minutes to become effective.
* Resource groups created outside this repository without the mandatory tags are denied.
* Tag inheritance (Modify) only affects resources created or updated after assignment. For existing resources, run a remediation task (**Portal → Policy → Remediation**).
* The domain controller VM size must be in the identity `allowed-vm-skus` list before that assignment is enforced.

## After the first deployment
1. Read the DC password from Key Vault (outputs `keyVaultName` and `keyVaultSecretName`). Rotate it after promotion.
2. Connect to the DCs: deploy Azure Bastion into the reserved `AzureBastionSubnet` (the DC and management NSGs already allow RDP from it), or use **Run Command** for scripted steps.
3. Promote the DCs manually and put NTDS, logs and SYSVOL on the data disk. Central India: create the forest on the first DC, then add the others. South India: add its DCs as additional domain controllers.
4. AD Sites and Services: one site per region with its subnets, an inter-site link, and **change notification enabled on the link** (default replication interval is 180 minutes) so cross-region RPO is minutes.
5. Make all DCs global catalog servers, keep the FSMO roles on a Central India DC, and enable **AD Recycle Bin**.
6. Optionally set the identity VNet `dnsServers` to the DC IPs once AD DNS is healthy.

## DR outline (active-passive)
| Failure | Domain controllers | Workload VMs (created outside this repo) |
|---------|--------------------|-------------------------------------------|
| Host or rack (Central India) | Automatic: the other DC in the availability set keeps serving | Per application design |
| Availability zone (Central India) | The availability set is not zonal, so both DCs may be affected: clients use the South India DCs. Give each DC a `zone` (and remove `availabilitySet`) for zone resilience | Per application design |
| Region | Automatic: clients use the other region's DCs; seize FSMO roles only if needed | Azure Site Recovery to South India with the secondary-region vault, recovery plan, then repoint DNS |
| Deletion or corruption | No backup by design; use AD Recycle Bin | Azure Backup with the VM backup policy defined in `main.bicepparam` |

Never restore a DC from a snapshot or an ASR replica (USN rollback).

Bicep keeps no state, so a regional outage does not block deployments to the surviving region: deployment history lives in each subscription. The pipeline depends on GitHub and the app registration; if either is unavailable during an incident, deploy from a laptop with `Deploy-LandingZone.ps1` and record the change in a pull request afterwards.
