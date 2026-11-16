#Requires -Version 7.2
#Requires -Modules Az.Accounts, Az.Resources, Az.KeyVault
<#
.SYNOPSIS
    Previews (what-if) or deploys one landing zone stack with the Az PowerShell module.

.DESCRIPTION
    1. Checks the tooling and loads tenant/subscription IDs from scripts/ids.local.ps1.
    2. Compiles main.bicepparam and runs the checks the Terraform version ran
       at plan time as variable validations (mandatory tags, NSG / route table
       references, DC placement, forwarding-rule dots, policy definitions...).
    3. Resolves the DC admin password: reads it back from Key Vault if the vault
       already exists, otherwise generates a strong one. Bicep cannot generate
       passwords, and a new password on every run would not match existing DCs.
    4. Runs New-AzSubscriptionDeployment with -WhatIf (preview) or -Confirm
       (shows the what-if, then asks before deploying, like terraform apply).
    5. Warns if Azure assigned the firewall a different IP than expected
       (replaces the Terraform check block).

.EXAMPLE
    ./scripts/Deploy-LandingZone.ps1 -Stack primary-centralindia                 # preview only
    ./scripts/Deploy-LandingZone.ps1 -Stack primary-centralindia -Mode Deploy    # preview, confirm, deploy
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('primary-centralindia', 'secondary-southindia')]
    [string] $Stack,

    [ValidateSet('WhatIf', 'Deploy')]
    [string] $Mode = 'WhatIf',

    # Deploy without the confirmation prompt. Required in CI (the prod environment
    # approval is the gate); avoid locally.
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot     = Split-Path -Parent $PSScriptRoot
$stackDir     = Join-Path $repoRoot $Stack
$templateFile = Join-Path $stackDir 'main.bicep'
$paramFile    = Join-Path $stackDir 'main.bicepparam'

function Write-Step([string] $Message) { Write-Host "`n==> $Message" -ForegroundColor Cyan }

function Get-RandomChar([string] $Set) {
    $Set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($Set.Length)]
}

function New-StrongPassword([int] $Length = 24) {
    # Look-alike characters (0/O, 1/l/I) are left out so the password can be read aloud.
    $upper   = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower   = 'abcdefghijkmnopqrstuvwxyz'
    $digits  = '23456789'
    $special = '!@#%^*-_=+'
    $all     = $upper + $lower + $digits + $special

    $chars = @(
        (Get-RandomChar $upper), (Get-RandomChar $lower),
        (Get-RandomChar $digits), (Get-RandomChar $special)
    ) + (1..($Length - 4) | ForEach-Object { Get-RandomChar $all })

    -join ($chars | Sort-Object { [System.Security.Cryptography.RandomNumberGenerator]::GetInt32([int]::MaxValue) })
}

function Get-StackParameters {
    # bicep build-params compiles the .bicepparam file, so we read exactly the
    # values the deployment will use (including readEnvironmentVariable results).
    $raw = bicep build-params $paramFile --stdout 2>$null
    if ($LASTEXITCODE -ne 0) { throw "bicep build-params failed. Run: bicep build-params $paramFile" }
    ((($raw | Out-String) | ConvertFrom-Json).parametersJson | ConvertFrom-Json -AsHashtable).parameters
}

# ---- 1. Tooling -----------------------------------------------------------------
Write-Step 'Checking tooling'
if (-not (Get-Command bicep -ErrorAction SilentlyContinue)) {
    throw 'The Bicep CLI is not on PATH (Az PowerShell needs it). Install it with: winget install -e --id Microsoft.Bicep'
}
Write-Host "Bicep: $(bicep --version)"
Write-Host "Az.Resources: $((Get-Module Az.Resources -ListAvailable | Sort-Object Version -Descending | Select-Object -First 1).Version)"

# ---- 2. Tenant and subscription IDs ------------------------------------------------
Write-Step 'Loading tenant and subscription IDs'
$idsFile = Join-Path $PSScriptRoot 'ids.local.ps1'
if (-not $env:ALZ_SUB_GOVERNANCE) {
    if (-not (Test-Path $idsFile)) {
        throw "Neither ALZ_* environment variables nor $idsFile found. Copy scripts/ids.local.ps1.example to scripts/ids.local.ps1 and fill in your IDs."
    }
    . $idsFile
}
$guidPattern = '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$'
foreach ($name in 'ALZ_TENANT_ID', 'ALZ_SUB_GOVERNANCE', 'ALZ_SUB_HUB', 'ALZ_SUB_IDENTITY', 'ALZ_SUB_WORKLOAD') {
    $value = [Environment]::GetEnvironmentVariable($name)
    if ($value -notmatch $guidPattern) { throw "$name is missing or not a GUID." }
}

# ---- 3. Parameters and pre-flight checks -----------------------------------------------
# Terraform ran these as variable validations at plan time. Bicep types catch
# wrong keys and types; the cross-field rules below need a script.
Write-Step "Compiling $Stack/main.bicepparam and running pre-flight checks"
$params   = Get-StackParameters
$location = $params.location.value
$problems = [System.Collections.Generic.List[string]]::new()

# Mandatory tags
$tags = $params.tags.value
foreach ($t in $params.mandatoryTagNames.value) {
    if (-not $tags.ContainsKey($t) -or [string]::IsNullOrWhiteSpace($tags[$t])) { $problems.Add("tags: mandatory tag '$t' is missing or empty") }
}

# Every subnet must point at an NSG / route table defined in the same network
$networks = @{ hub = $params.hub.value.network; identity = $params.identity.value.network; workload = $params.workload.value.network }
foreach ($n in $networks.GetEnumerator()) {
    $nsgs   = if ($n.Value.ContainsKey('networkSecurityGroups')) { $n.Value.networkSecurityGroups.Keys } else { @() }
    $tables = if ($n.Value.ContainsKey('routeTables')) { $n.Value.routeTables.Keys } else { @() }
    foreach ($s in $n.Value.subnets.GetEnumerator()) {
        if ($s.Value.ContainsKey('nsg') -and $s.Value.nsg -notin $nsgs) { $problems.Add("$($n.Key).network: subnet '$($s.Key)' references undefined NSG '$($s.Value.nsg)'") }
        if ($s.Value.ContainsKey('routeTable') -and $s.Value.routeTable -notin $tables) { $problems.Add("$($n.Key).network: subnet '$($s.Key)' references undefined route table '$($s.Value.routeTable)'") }
    }
}

# DNS forwarding rules need a trailing dot
foreach ($r in $params.hub.value.dnsResolver.forwardingRules.GetEnumerator()) {
    if (-not $r.Value.domainName.EndsWith('.')) { $problems.Add("hub.dnsResolver.forwardingRules.$($r.Key): domainName must end with a dot") }
}

# Domain controllers: computer names <= 15 chars; availability set XOR zones; unique names and IPs
$dcs = $params.identity.value.domainControllers
$hasAvSet = $dcs.ContainsKey('availabilitySet')
foreach ($dc in $dcs.servers.GetEnumerator()) {
    if ($dc.Key.Length -gt 15) { $problems.Add("identity.domainControllers.servers: computer name '$($dc.Key)' is longer than 15 characters") }
    $hasZone = $dc.Value.ContainsKey('zone')
    if ($hasAvSet -and $hasZone)          { $problems.Add("identity.domainControllers: '$($dc.Key)' has a zone, but an availability set is configured (omit every zone)") }
    if (-not $hasAvSet -and -not $hasZone) { $problems.Add("identity.domainControllers: '$($dc.Key)' needs a zone when availabilitySet is omitted") }
}
foreach ($field in 'vmName', 'nicName', 'osDiskName', 'ntdsDiskName', 'privateIp') {
    $dupes = $dcs.servers.Values | Group-Object { $_[$field] } | Where-Object Count -gt 1
    foreach ($d in $dupes) { $problems.Add("identity.domainControllers.servers: $field '$($d.Name)' is used by more than one DC") }
}

# Recovery vault: cross-region restore requires GRS
$rsv = $params.workload.value.recoveryVault.vault
if ($rsv.crossRegionRestoreEnabled -and $rsv.storageModeType -ne 'GeoRedundant') { $problems.Add('workload.recoveryVault.vault: crossRegionRestoreEnabled requires storageModeType = GeoRedundant') }

# Policy (primary only): every definition display name must be in builtInPolicyDefinitions
if ($params.ContainsKey('policies')) {
    $known = $params.builtInPolicyDefinitions.value.Keys
    $names = @($params.policyDefinitionNames.value.Values)
    foreach ($sub in $params.policies.value.GetEnumerator()) {
        foreach ($a in $sub.Value.assignments.GetEnumerator()) {
            $names += $a.Value.definitionDisplayName
            if ($a.Key.Length -gt 64) { $problems.Add("policies.$($sub.Key): assignment name '$($a.Key)' is longer than 64 characters") }
        }
    }
    foreach ($n in ($names | Sort-Object -Unique)) {
        if ($n -notin $known) { $problems.Add("policy definition '$n' is not listed in builtInPolicyDefinitions (add its GUID)") }
    }
}

if ($problems.Count -gt 0) {
    $problems | ForEach-Object { Write-Host "  x $_" -ForegroundColor Red }
    throw "$($problems.Count) pre-flight check(s) failed. Fix main.bicepparam and run again."
}
Write-Host "Location: $location | all pre-flight checks passed"

# ---- 4. Sign in ------------------------------------------------------------------
Write-Step 'Signing in to Azure'
$context = Get-AzContext
if (-not $context -or $context.Tenant.Id -ne $env:ALZ_TENANT_ID) {
    Connect-AzAccount -Tenant $env:ALZ_TENANT_ID | Out-Null
}
Set-AzContext -Tenant $env:ALZ_TENANT_ID -Subscription $env:ALZ_SUB_GOVERNANCE | Out-Null
Write-Host "Signed in as $((Get-AzContext).Account.Id); deployment scope: governance subscription"

# ---- 5. DC admin password --------------------------------------------------------
Write-Step 'Resolving the DC admin password'
$kvName      = $params.identity.value.keyVault.name
$secretName  = $params.identity.value.keyVault.secretName
$identityRg  = $params.identity.value.network.resourceGroupName

Set-AzContext -Subscription $env:ALZ_SUB_IDENTITY | Out-Null
$vault = Get-AzKeyVault -VaultName $kvName -ErrorAction SilentlyContinue
$password = $null

if ($vault) {
    try {
        $password = Get-AzKeyVaultSecret -VaultName $kvName -Name $secretName -AsPlainText -ErrorAction Stop
    }
    catch {
        throw "Key Vault '$kvName' exists but secret '$secretName' could not be read ($($_.Exception.Message)). " +
              'Grant yourself Key Vault Secrets Officer on the vault. A new password is NOT generated, because it would not match the existing domain controllers.'
    }
    if ($password) { Write-Host "Using the existing password from Key Vault '$kvName'." }
}
elseif (Get-AzKeyVault -VaultName $kvName -Location $location -InRemovedState -ErrorAction SilentlyContinue) {
    throw "Key Vault '$kvName' is soft-deleted (purge protection keeps the name reserved). " +
          "Recover it: Undo-AzKeyVaultRemoval -VaultName $kvName -ResourceGroupName $identityRg -Location $location"
}

if (-not $password) {
    $password = New-StrongPassword
    Write-Host 'Generated a new password; the deployment stores it in Key Vault.'
}
Set-AzContext -Subscription $env:ALZ_SUB_GOVERNANCE | Out-Null

# ---- 6. What-if / deploy -----------------------------------------------------------
$inCi = [bool]$env:GITHUB_ACTIONS
if ($inCi -and $Mode -eq 'Deploy' -and -not $Force) {
    throw 'Running in GitHub Actions: use -Force (the approval gate is the prod environment, not a prompt).'
}

function Write-Summary([string] $Markdown) {
    # Job summary in GitHub Actions; no-op locally.
    if ($env:GITHUB_STEP_SUMMARY) { Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value $Markdown }
}

$deployment = @{
    Name                  = "alz-$Stack-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Location              = $location
    TemplateFile          = $templateFile
    TemplateParameterFile = $paramFile
}

# main.bicepparam reads the password with readEnvironmentVariable(). The variable
# lives only in this PowerShell process and is removed in the finally block.
$env:ALZ_DC_ADMIN_PASSWORD = $password
try {
    if ($Mode -eq 'WhatIf') {
        Write-Step 'What-if (no changes are made)'
        $whatIf = Get-AzDeploymentWhatIfResult @deployment
        $whatIf | Out-Host

        # Job summary: change counts + the full what-if text (ANSI colours removed)
        $counts = $whatIf.Changes | Group-Object ChangeType | Sort-Object Name |
                  ForEach-Object { "| $($_.Name) | $($_.Count) |" }
        $text = (($whatIf | Out-String) -replace "`e\[[0-9;]*m", '')
        if ($text.Length -gt 60000) { $text = $text.Substring(0, 60000) + "`n... (truncated, see the job log)" }
        Write-Summary ("## What-if: ``$Stack```n`nCommit: ``$env:GITHUB_SHA```n`n| Change | Resources |`n|---|---|`n" +
                       ($counts -join "`n") + "`n`n<details><summary>Full what-if</summary>`n`n``````text`n$text`n```````n</details>`n")
        return
    }

    Write-Step "Deploying $Stack"
    try {
        $result = if ($Force) {
            New-AzSubscriptionDeployment @deployment
        } else {
            New-AzSubscriptionDeployment @deployment -Confirm   # shows the what-if, then asks
        }
    }
    catch {
        # Show which module/resource failed, not only ARM's generic message.
        Write-Host 'Failed operations at the deployment scope:' -ForegroundColor Red
        Get-AzDeploymentOperation -DeploymentName $deployment.Name -ErrorAction SilentlyContinue |
            Where-Object ProvisioningState -eq 'Failed' |
            ForEach-Object { Write-Host "  x $($_.TargetResource): $($_.StatusMessage)" -ForegroundColor Red }
        Write-Summary "## Deployment ``$Stack``: **Failed**`n`n``````text`n$($_.Exception.Message)`n``````"
        throw
    }
}
finally {
    Remove-Item Env:ALZ_DC_ADMIN_PASSWORD -ErrorAction SilentlyContinue
    $password = $null
}

if (-not $result) { Write-Host 'Deployment cancelled.' -ForegroundColor Yellow; return }

# ---- 7. Results -------------------------------------------------------------------
Write-Step "Result: $($result.ProvisioningState)"
if ($result.ProvisioningState -ne 'Succeeded') { throw "Deployment $($deployment.Name) did not succeed." }

$outputs = $result.Outputs.GetEnumerator() |
    ForEach-Object { [pscustomobject]@{ Output = $_.Key; Value = (($_.Value.Value | Out-String).Trim() -replace '\s+', ' ') } }
$outputs | Format-Table -AutoSize | Out-Host
Write-Summary ("## Deployment ``$Stack``: **$($result.ProvisioningState)**`n`nDeployment: ``$($deployment.Name)```n`n| Output | Value |`n|---|---|`n" +
               (($outputs | ForEach-Object { "| $($_.Output) | ``$($_.Value)`` |" }) -join "`n"))

# Output values arrive as JSON tokens, so compare their text form.
if ("$($result.Outputs['firewallIpMatchesExpected'].Value)" -ne 'True') {
    $msg = "Azure assigned the firewall $($result.Outputs['firewallPrivateIp'].Value), which differs from expectedFirewallPrivateIp. " +
           'Update the IP in the route tables / dnsServers of both main.bicepparam files and redeploy both stacks.'
    Write-Warning $msg
    if ($inCi) { Write-Host "::warning title=Firewall IP mismatch::$msg" }
}
