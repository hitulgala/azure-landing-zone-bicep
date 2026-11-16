# CI/CD pipeline

The landing zone is deployed by two GitHub Actions workflows. Nothing reaches Azure without a reviewed what-if and an explicit approval.

```
feature branch -> pull request -> Bicep What-If (pull_request)
                                  lint + what-if shown in the run Summary; nothing is deployed

merge to main  -> Bicep What-If (push)
                  lint: format check, lint, build -> what-if: pre-flight checks, what-if
               -> Bicep Deploy (workflow_run)
                  run only if: What-If succeeded, on main, triggered by a push
                  deploy: wait for 'prod' approval -> deploy the previewed commit -> outputs in Summary
```

## Workflows
| File | Trigger | What it does |
|------|---------|--------------|
| `bicep-whatif.yml` | Pull request into `main`, push to `main`, manual (choose the stack) | **lint** job (no Azure access): `bicep format` check, `bicep lint` on every file, build of each stack present. **what-if** job: OIDC login, `Deploy-LandingZone.ps1 -Mode WhatIf` (pre-flight checks, DC password lookup, what-if); change counts and the full what-if go to the run Summary |
| `bicep-deploy.yml` | Completion of **Bicep What-If**, or manual (choose the stack, `main` only) | Pauses on the `prod` environment, checks out the previewed commit, OIDC login, `Deploy-LandingZone.ps1 -Mode Deploy -Force`; outputs (or the failed operations) go to the run Summary |

Key behaviours:
* **The previewed commit is the deployed commit.** A what-if is a prediction, not a saved plan; ARM evaluates the template again at deployment time. Every deployment is idempotent.
* **Deployments are never cancelled.** Bicep Deploy uses `cancel-in-progress: false`. What-if runs for the same branch or pull request cancel older ones.
* **Only the primary deploys automatically.** A push to `main` previews and deploys `primary-centralindia`. The secondary is deployed with a manual run of both workflows.
* **Stacks that are not in the repository are skipped** by the lint job, so the secondary can be added later.

## Setup

### 1. Deployment identity (OIDC)
The pipeline signs in with **workload identity federation**: GitHub issues a short-lived token per job, and Entra ID trusts it for one app registration. There is no client secret to store or rotate.

GitHub's token subject contains the **immutable IDs** of the owner and the repository (for example `repo:<owner>@<owner-id>/<repo>@<repo-id>:ref:refs/heads/main`). Read them from GitHub instead of typing them:

```powershell
$repo    = '<owner>/<repo>'
$ownerId = gh api "repos/$repo" --jq .owner.id
$repoId  = gh api "repos/$repo" --jq .id
$owner, $name = $repo -split '/'
$prefix  = "repo:$owner@$ownerId/$name@$repoId"

Connect-AzAccount -Tenant '<tenant-id>'
$app = New-AzADApplication -DisplayName 'sp-alz-bicep-github'
$sp  = New-AzADServicePrincipal -ApplicationId $app.AppId

$subjects = @{
    'main-branch'  = "${prefix}:ref:refs/heads/main"   # what-if on push to main and manual runs
    'pull-request' = "${prefix}:pull_request"          # what-if on pull requests
    'env-prod'     = "${prefix}:environment:prod"      # deploy job (uses environment: prod)
}
foreach ($s in $subjects.GetEnumerator()) {
    New-AzADAppFederatedCredential -ApplicationObjectId $app.Id -Name $s.Key `
        -Issuer 'https://token.actions.githubusercontent.com' -Subject $s.Value `
        -Audience 'api://AzureADTokenExchange' | Out-Null
}
"AZURE_CLIENT_ID = $($app.AppId)"
```

A job that uses `environment: prod` presents the **environment** subject, not the branch subject, which is why the deploy job needs its own credential. If a login fails, the error message shows the exact subject GitHub presented: that string is what must be registered.

Grant the roles on **every** subscription:
```powershell
$roles = 'Contributor', 'User Access Administrator', 'Resource Policy Contributor'
foreach ($sub in '<governance-id>', '<hub-id>', '<identity-id>', '<workload-id>' | Select-Object -Unique) {
    foreach ($r in $roles) { New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName $r -Scope "/subscriptions/$sub" | Out-Null }
}
```

| Role | Needed for |
|------|-----------|
| Contributor | All resources |
| User Access Administrator | Role assignments: Key Vault Secrets Officer for the deploying identity, policy managed identities |
| Resource Policy Contributor | Azure Policy assignments |

User Access Administrator can grant any role, so treat this identity as Owner-equivalent.

**If a stack was first deployed from a laptop**, its Key Vault grants the DC password to your account only. Give the pipeline read access before its first run:
```powershell
$kv = Get-AzKeyVault -VaultName '<key-vault-name>'      # in the identity subscription
New-AzRoleAssignment -ObjectId $sp.Id -RoleDefinitionName 'Key Vault Secrets User' -Scope $kv.ResourceId
```
Use **Secrets User**, not Secrets Officer: the deployment itself grants Secrets Officer to the deploying identity under a deterministic name, and a manually created duplicate would make the deployment fail with `RoleAssignmentExists`.

### 2. GitHub variables
**Settings → Secrets and variables → Actions → Variables**, at **repository** level (the what-if job has no environment, so it cannot read environment-level values). With OIDC, none of these are secrets.

| Name | Value |
|------|-------|
| `AZURE_CLIENT_ID` | Application (client) ID from step 1 |
| `AZURE_TENANT_ID` | Entra tenant ID |
| `ALZ_SUB_GOVERNANCE` | Governance subscription ID (the deployment scope) |
| `ALZ_SUB_HUB` | Hub subscription ID |
| `ALZ_SUB_IDENTITY` | Identity subscription ID |
| `ALZ_SUB_WORKLOAD` | Workload subscription ID |
| `BICEP_VERSION` | Bicep CLI release tag, e.g. `v0.38.33`. Use the version you run locally: format output can differ between versions |

With the GitHub CLI:
```powershell
$r = '<owner>/<repo>'
gh variable set AZURE_CLIENT_ID -R $r --body '<client-id>'
gh variable set BICEP_VERSION   -R $r --body ('v' + ((bicep --version) -replace '.*version ([\d.]+).*', '$1'))
# ... and the others
```

### 3. The `prod` environment
**Settings → Environments → New environment → `prod`**
* **Required reviewers:** at least one person. Leave *Prevent self-review* unchecked if you work alone.
* **Deployment branches and tags:** selected branches, `main` only.

### 4. Protect `main`
**Settings → Rules → Rulesets → New branch ruleset**, targeting the default branch:
* Restrict deletions, block force pushes
* Require a pull request before merging (allowed merge method: squash)
* Require status checks `lint` and `what-if`, with branches up to date before merging

Status checks can only be selected after they have run once. Do not add a `paths:` filter to the pull request trigger: a required check that never runs blocks every merge.

## Day-to-day flow
```powershell
git switch main ; git pull origin main
git switch -c feat/<topic>
# edit, then:
Get-ChildItem -Recurse -Include *.bicep, *.bicepparam | ForEach-Object { bicep format $_.FullName }
git commit -am "feat(scope): summary"
git push -u origin feat/<topic>
gh pr create --fill
gh pr checks --watch            # read the what-if in the run Summary
gh pr merge --squash --delete-branch
```
After the merge, read the what-if of the new **Bicep What-If** run on `main` and approve **Bicep Deploy**: in the browser (**Review deployments → prod → Approve and deploy**) or with the GitHub CLI:
```powershell
$repo  = '<owner>/<repo>'
$runId = gh run list --workflow 'Bicep Deploy' --limit 1 --json databaseId --jq '.[0].databaseId'
$envId = gh api "repos/$repo/environments/prod" --jq '.id'
gh api "repos/$repo/actions/runs/$runId/pending_deployments" -X POST `
  -F "environment_ids[]=$envId" -f state=approved -f comment='What-if reviewed'
```

### Secondary region
**Actions → Bicep What-If → Run workflow** with `secondary-southindia`, review the result, then **Actions → Bicep Deploy → Run workflow** with the same stack.

## Reading a what-if
| Change type | Meaning |
|-------------|---------|
| `Create` | Resource does not exist yet |
| `Modify` | Properties will change; the detail lists each one |
| `NoChange` | Deployed as-is |
| `Ignore` | Exists in a targeted scope but is not in the template; left untouched |
| `Unsupported` / not evaluated | The value depends on another module's output, known only at deployment time |

A what-if can show changes that will not happen (*noise*): properties Azure normalises, or secret values it cannot compare (the Key Vault secret always appears as a change). Treat it as a prediction and focus on `Create`, `Delete` and unexpected `Modify` entries.

## Recovery
| Situation | What to do |
|-----------|-----------|
| Deployment failed halfway | Read the failed operations in the run Summary, fix the cause in a pull request, merge, approve the new deployment. Re-running is safe because deployments are idempotent |
| Transient Azure error (`InternalServerError`, `Conflict`) | **Re-run failed jobs** on the Bicep Deploy run |
| Two merges close together | Approve the newest deployment, reject older ones |
| What-if approved long ago | Re-run Bicep What-If on `main` before approving: Azure may have changed since |
| Change made in the portal (drift) | The next deployment puts the configured values back. Add intentional changes to `main.bicepparam` first |

## Security notes
* **No secrets in GitHub.** OIDC tokens are short-lived and issued per job; only `main`, pull requests and the `prod` environment of this repository can obtain one.
* The DC password is passed as a secure parameter: it does not appear in logs, run summaries or the deployment history.
* In a public repository, workflow logs and run summaries are visible to everyone. The what-if shows names, addresses and IPs.
* Workflows triggered from forks get no OIDC token, so they cannot reach Azure.
* Key Vault accepts public network traffic because GitHub-hosted runners have no fixed IP; access is still restricted by Entra ID RBAC. See [deployment-and-dr.md](deployment-and-dr.md#key-vault-network-access).

## Troubleshooting
| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `AADSTS700213: No matching federated identity record` | The subject in the error is not registered | Register exactly that subject (step 1). The deploy job needs `environment:prod` |
| `AuthorizationFailed` | Missing role on a subscription | Step 1 roles; assignments take a few minutes to apply |
| `Key Vault ... secret could not be read` | The pipeline identity cannot read an existing password | Grant **Key Vault Secrets User** on the vault (step 1) |
| `RoleAssignmentExists` on the Key Vault | Secrets Officer was granted manually | Remove the manual assignment; use Secrets User |
| `curl: (22) ... 404` installing Bicep | Wrong `BICEP_VERSION` | Use a release tag with `v`, e.g. `v0.38.33` |
| `Not formatted` in the lint job | Files differ from `bicep format` output | Format all files (day-to-day flow), commit, push |
| Pre-flight check failed | Cross-field error in `main.bicepparam` | The log lists each problem; fix and push |
| Bicep Deploy never starts | Workflow not on `main`, What-If run was a pull request, or the What-If workflow was renamed | Keep both files on `main`; the preview workflow must be named `Bicep What-If` |
| Deploy runs without asking for approval | No required reviewer on `prod` (private repo on GitHub Free) | Make the repository public or use a paid plan |
| Required check stays *Expected* | The What-If workflow did not run for that pull request | Do not filter the pull request trigger by path |
