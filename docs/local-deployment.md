# Local deployment guide

This guide deploys the landing zone **from your own laptop**, step by step. It is the best way to learn how the code works before you automate it with GitHub Actions ([cicd-pipeline.md](cicd-pipeline.md)).

You will: install the tools, prepare your subscriptions, check names and quotas, preview the deployment with **what-if**, deploy, verify that traffic and DNS work, pause the costs between sessions, and finally remove everything.

> **Cost warning.** From the moment a deployment finishes, Azure Firewall Standard, the DNS resolver endpoints, the domain controller VMs and their disks are billed by the hour. The firewall is by far the largest item. Use [step 7](#7-pause-costs-between-sessions) between sessions and [step 8](#8-remove-everything) when you are done.

Plan for about **1 hour** the first time: 15 minutes of preparation and 30-45 minutes of deployment.

---

## How the deployment works
* **One command per region.** `scripts/Deploy-LandingZone.ps1` runs one *subscription deployment* at the **governance** subscription. Inside it, every module is scoped to its own subscription, so one deployment builds all four subscriptions of a region.
* **No state file.** Azure Resource Manager is the source of truth. Running the same deployment twice changes nothing the second time (it is *idempotent*), so after a failure you fix the cause and simply run it again.
* **What-if before deploy.** A what-if compares the template with what exists in Azure and lists what would be created, modified or left alone. It never changes anything.
* **The script adds what Bicep cannot do on its own:** cross-field pre-flight checks, the domain controller password (generated once, then read back from Key Vault), and a check of the firewall IP after deployment.

---

## 1. Prepare your laptop

**Tools** (Windows, macOS or Linux):

| Tool | Install | Check |
|------|---------|-------|
| PowerShell 7.2+ | <https://aka.ms/powershell> | `$PSVersionTable.PSVersion` |
| Az PowerShell | `Install-Module Az -Scope CurrentUser` | `Get-Module Az.Resources -ListAvailable` |
| Bicep CLI (on `PATH`) | Windows: `winget install -e --id Microsoft.Bicep` · others: <https://aka.ms/bicep-install> | `bicep --version` |
| Git, VS Code + Bicep extension | <https://git-scm.com>, <https://code.visualstudio.com> | |

Az PowerShell calls the standalone `bicep` binary, so `bicep --version` must work in a **new** terminal. The copy installed by `az bicep install` is not on `PATH` and does not count.

**Get the code:**
```powershell
git clone https://github.com/<owner>/<repo>.git
cd <repo>
```
On Windows, if you downloaded a zip instead, unblock the files and allow local scripts once:
```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
Get-ChildItem -Recurse | Unblock-File
```
Keep the folder **outside** OneDrive or other sync tools: they can lock or corrupt Git's internal files.

**Add your IDs** (the file is git-ignored and never committed):
```powershell
Copy-Item scripts/ids.local.ps1.example scripts/ids.local.ps1
notepad scripts/ids.local.ps1            # tenant ID + four subscription IDs
git check-ignore scripts/ids.local.ps1   # must print the path
```
Only one subscription? Use the same ID for all four.

**Edit the values.** Open `primary-centralindia/main.bicepparam` and search for `<--`. At minimum change:
* `identity.keyVault.name`: **globally unique**, 3-24 characters
* the action group e-mail receiver
* the `owner` and `cost_center` tags
* `hub.dnsResolver.forwardingRules` domain name (your future AD domain, with a trailing dot)
* `identity.domainControllers.settings.adminUsername`

Check that the file still compiles:
```powershell
bicep build-params primary-centralindia/main.bicepparam --stdout | Out-Null   # no output = OK
```

---

## 2. Sign in and check access

```powershell
. ./scripts/ids.local.ps1
Connect-AzAccount -Tenant $env:ALZ_TENANT_ID
Get-AzContext | Select-Object Account, Tenant     # must be YOUR account
```
Az PowerShell reuses saved sign-ins. If an old service principal context appears, run `Disconnect-AzAccount` and sign in again; `Disable-AzContextAutosave -Scope CurrentUser` stops contexts being saved between sessions.

**Roles.** On each of the four subscriptions you need **Owner**, or **Contributor + User Access Administrator + Resource Policy Contributor**:
```powershell
$subs = @{ governance = $env:ALZ_SUB_GOVERNANCE; hub = $env:ALZ_SUB_HUB; identity = $env:ALZ_SUB_IDENTITY; workload = $env:ALZ_SUB_WORKLOAD }
$me = (Get-AzADUser -SignedIn).Id
foreach ($s in $subs.GetEnumerator()) {
    $roles = Get-AzRoleAssignment -ObjectId $me -Scope "/subscriptions/$($s.Value)" -ExpandPrincipalGroups |
             Select-Object -ExpandProperty RoleDefinitionName -Unique
    "{0,-11} {1}" -f $s.Key, ($roles -join ', ')
}
```

**Resource providers** (one-time per subscription; prevents `MissingSubscriptionRegistration` halfway through):
```powershell
$providers = 'Microsoft.Network', 'Microsoft.Compute', 'Microsoft.KeyVault', 'Microsoft.OperationalInsights',
             'Microsoft.Insights', 'Microsoft.RecoveryServices', 'Microsoft.PolicyInsights'
foreach ($id in $subs.Values | Select-Object -Unique) {
    Set-AzContext -Subscription $id | Out-Null
    $providers | ForEach-Object { Register-AzResourceProvider -ProviderNamespace $_ | Out-Null }
}
```
Registration takes a minute or two; `Get-AzResourceProvider -ProviderNamespace Microsoft.Network | Select-Object -First 1 RegistrationState` shows the progress.

---

## 3. Check names and capacity

These checks catch the most common first-deployment failures before you wait 20 minutes for them.

**VM size and quota** (identity subscription; use the `vmSize` from `main.bicepparam`):
```powershell
Set-AzContext -Subscription $env:ALZ_SUB_IDENTITY | Out-Null
$size = 'Standard_B2ats_v2'
Get-AzComputeResourceSku -Location centralindia | Where-Object Name -eq $size |
    Select-Object Name, @{n='Restrictions';e={$_.Restrictions.ReasonCode}}       # empty = available
Get-AzVMUsage -Location centralindia |
    Where-Object { $_.Name.LocalizedValue -match 'Total Regional vCPUs' } |
    Select-Object @{n='Quota';e={$_.Name.LocalizedValue}}, CurrentValue, Limit  # 2 DCs x 2 vCPUs = 4 needed
```
If the size is restricted, choose another one and add it to the identity `allowed-vm-skus` policy list too.

**Key Vault name:**
```powershell
$kvName = '<your key vault name>'
$body = @{ name = $kvName; type = 'Microsoft.KeyVault/vaults' } | ConvertTo-Json
(Invoke-AzRestMethod -Method POST -Payload $body `
  -Path "/subscriptions/$env:ALZ_SUB_IDENTITY/providers/Microsoft.KeyVault/checkNameAvailability?api-version=2023-07-01").Content
```
You want `"nameAvailable":true`.

---

## 4. Preview with what-if

```powershell
Set-AzContext -Subscription $env:ALZ_SUB_GOVERNANCE | Out-Null
./scripts/Deploy-LandingZone.ps1 -Stack primary-centralindia
```
The script prints each stage:
1. **Tooling and IDs** are checked.
2. **Pre-flight checks** run against the compiled parameters: mandatory tags present, every subnet's NSG and route table defined, DC placement consistent (availability set *or* zones), names unique, forwarding domains ending with a dot, every policy display name known. Each problem is listed; fix them all and run again.
3. **Password:** on a first run no vault exists, so it prints *Generated a new password* (on a what-if run it is discarded).
4. **What-if** is printed.

On a first run almost everything is `+ Create`: 4 resource groups, 3 VNets, the NSGs and route tables, the firewall with its policy and public IP, the resolver with its endpoints and ruleset, the Private DNS zones and links, Key Vault and its private endpoint, the availability set, NICs, disks and VMs, the Recovery Services Vault, the Service Health alerts and the policy assignments in each subscription. Check the names for typos. Some nested items may be shown as not evaluated: their values depend on another module's output, which is only known during the deployment.

---

## 5. Deploy

```powershell
./scripts/Deploy-LandingZone.ps1 -Stack primary-centralindia -Mode Deploy
```
The what-if is shown again, followed by a confirmation prompt: answer **`Y`**. Expect **30-45 minutes** (firewall 10-15, DNS resolver 5-10, VMs 5-10). Keep the terminal open.

**Watch progress** in the portal: **governance subscription → Settings → Deployments → `alz-primary-centralindia-<timestamp>`**. Each module is a nested deployment you can open. Modules that run in another subscription also appear under that subscription's (or resource group's) **Deployments** blade.

At the end the script prints `Result: Succeeded` and the outputs. Check:
* `firewallIpMatchesExpected` is `True` (if not, read the warning: the firewall IP used in routes and DNS settings must be corrected and both stacks redeployed)
* `firewallPrivateIp` is `10.10.0.4`
* `domainControllerIps` lists the DC addresses

**If it fails,** the script lists the failed operations. For a module that ran in another subscription, open it there:
```powershell
Set-AzContext -Subscription $env:ALZ_SUB_HUB | Out-Null
Get-AzResourceGroupDeploymentOperation -ResourceGroupName rg-net-prd-cin-001 -DeploymentName alz-cin-hub-firewall |
    Where-Object ProvisioningState -eq 'Failed' | Select-Object TargetResource, StatusMessage
```
Fix the cause and run the same command again.

| Error | Cause | Fix |
|-------|-------|-----|
| `VaultAlreadyExists` / name not available | Key Vault name taken or soft-deleted | Change it, or recover with `Undo-AzKeyVaultRemoval` |
| `SkuNotAvailable` / `QuotaExceeded` | VM size or vCPU quota | Step 3, or request quota in the portal |
| `AuthorizationFailed ... roleAssignments/write` | Missing User Access Administrator | Get the role, run again |
| `PrincipalNotFound` on a policy role assignment | New policy identity not replicated yet | Run again |
| `RequestDisallowedByPolicy` | An existing policy in your tenant | The error names the policy; adjust it or your values |
| `MissingSubscriptionRegistration` | Provider not registered | Step 2 |
| `InternalServerError` / `Conflict` | Transient Azure error | Run again |

---

## 6. Verify

**Peerings are connected:**
```powershell
Set-AzContext -Subscription $env:ALZ_SUB_HUB | Out-Null
Get-AzVirtualNetworkPeering -VirtualNetworkName vnet-hub-prd-cin-001 -ResourceGroupName rg-net-prd-cin-001 |
    Select-Object Name, PeeringState, AllowForwardedTraffic
```

**Spoke traffic goes through the firewall** (effective routes of a DC NIC; the VM must be running):
```powershell
Set-AzContext -Subscription $env:ALZ_SUB_IDENTITY | Out-Null
Get-AzEffectiveRouteTable -NetworkInterfaceName nic-cindc01 -ResourceGroupName rg-adds-prd-cin-001 |
    Where-Object { $_.AddressPrefix -contains '0.0.0.0/0' } | Select-Object Source, NextHopType, NextHopIpAddress
```
Expected: `User`, `VirtualAppliance`, `10.10.0.4`.

**The DNS chain works** (DC → firewall DNS proxy → resolver → Private DNS zone), run inside a DC without any public IP:
```powershell
$kvName = '<your key vault name>'
Invoke-AzVMRunCommand -ResourceGroupName rg-adds-prd-cin-001 -VMName vm-cin-dc01 -CommandId RunPowerShellScript `
  -ScriptString "Resolve-DnsName $kvName.vault.azure.net | Select-Object Name, IPAddress" |
  Select-Object -ExpandProperty Value | Select-Object -ExpandProperty Message
```
The answer must be a **private** address from the identity private-endpoint subnet (`10.10.4.64/27`). A public IP means a zone link or the DNS proxy is not working.

**The password is in Key Vault** (without printing it):
```powershell
Get-AzKeyVaultSecret -VaultName $kvName -Name dc-local-admin-password | Select-Object Name, Enabled, Created
```

**Policies are assigned** (repeat per subscription; compliance results appear after up to 30 minutes in **Policy → Compliance**):
```powershell
Get-AzPolicyAssignment | Select-Object Name, @{n='Mode';e={$_.EnforcementMode}}
```

**Idempotency:** run the what-if again.
```powershell
./scripts/Deploy-LandingZone.ps1 -Stack primary-centralindia
```
It now prints *Using the existing password from Key Vault*, and nearly everything is `NoChange` or `Ignore`. The Key Vault secret is always shown as a change because what-if cannot compare secret values.

---

## 7. Pause costs between sessions

Stop the firewall (it keeps its configuration) and the domain controllers:
```powershell
Set-AzContext -Subscription $env:ALZ_SUB_HUB | Out-Null
$fw = Get-AzFirewall -Name afw-prd-cin-001 -ResourceGroupName rg-net-prd-cin-001
$fw.Deallocate(); $fw | Set-AzFirewall

Set-AzContext -Subscription $env:ALZ_SUB_IDENTITY | Out-Null
'vm-cin-dc01', 'vm-cin-dc02' | ForEach-Object { Stop-AzVM -ResourceGroupName rg-adds-prd-cin-001 -Name $_ -Force -NoWait }
```
Start them again:
```powershell
Set-AzContext -Subscription $env:ALZ_SUB_HUB | Out-Null
$fw   = Get-AzFirewall -Name afw-prd-cin-001 -ResourceGroupName rg-net-prd-cin-001
$vnet = Get-AzVirtualNetwork -Name vnet-hub-prd-cin-001 -ResourceGroupName rg-net-prd-cin-001
$pip  = Get-AzPublicIpAddress -Name pip-afw-prd-cin-001 -ResourceGroupName rg-net-prd-cin-001
$fw.Allocate($vnet, $pip); $fw | Set-AzFirewall

Set-AzContext -Subscription $env:ALZ_SUB_IDENTITY | Out-Null
'vm-cin-dc01', 'vm-cin-dc02' | ForEach-Object { Start-AzVM -ResourceGroupName rg-adds-prd-cin-001 -Name $_ -NoWait }
```
Do not deploy while the firewall is deallocated: the deployment would allocate it again. The DNS resolver endpoints, Key Vault, Log Analytics and disks still cost a little while paused.

---

## 8. Remove everything

Without a state file there is no single *destroy* command: you delete what the deployment created. Remove the **secondary** first if you deployed it.

```powershell
. ./scripts/ids.local.ps1

# 1. Resource groups (almost everything lives in them)
$rgs = @(
  @{ sub = $env:ALZ_SUB_WORKLOAD;   rg = 'rg-wld-prd-cin-001'  }
  @{ sub = $env:ALZ_SUB_IDENTITY;   rg = 'rg-adds-prd-cin-001' }
  @{ sub = $env:ALZ_SUB_HUB;        rg = 'rg-net-prd-cin-001'  }
  @{ sub = $env:ALZ_SUB_GOVERNANCE; rg = 'rg-gov-prd-cin-001'  }
)
foreach ($r in $rgs) {
    Set-AzContext -Subscription $r.sub | Out-Null
    Remove-AzResourceGroup -Name $r.rg -Force
}

# 2. Subscription-level items (they live in no resource group), per subscription
foreach ($id in $env:ALZ_SUB_GOVERNANCE, $env:ALZ_SUB_HUB, $env:ALZ_SUB_IDENTITY, $env:ALZ_SUB_WORKLOAD | Select-Object -Unique) {
    Set-AzContext -Subscription $id | Out-Null
    Get-AzPolicyAssignment |
        Where-Object { $_.Name -like 'tag-*' -or $_.Name -like 'allowed-*' -or $_.Name -eq 'nic-no-public-ip' } |
        ForEach-Object { Remove-AzPolicyAssignment -Id $_.Id }
    Remove-AzDiagnosticSetting -ResourceId "/subscriptions/$id" -Name diag-activitylog-to-law -ErrorAction SilentlyContinue
}
```
Afterwards:
* The role assignments of the deleted policy identities remain as **Identity not found** under **Access control (IAM)** on each subscription; delete them there.
* The Key Vault stays **soft-deleted** and, with purge protection, keeps its name reserved for the retention period (90 days by default). Reuse the name later by recovering the vault (`Undo-AzKeyVaultRemoval`) before deploying.
* Remove the governance resource group **last**: other resources send their diagnostics to its workspace until they are gone.

---

## Next steps
* Deploy the **secondary** region the same way with `-Stack secondary-southindia` once the primary is verified (see [deployment-and-dr.md](deployment-and-dr.md#deployment-order)).
* Promote the domain controllers ([deployment-and-dr.md](deployment-and-dr.md#after-the-first-deployment)).
* Automate the whole flow with GitHub Actions ([cicd-pipeline.md](cicd-pipeline.md)).
