# Contributing

## Ground rules
* Deployment values go in `main.bicepparam`; subscription IDs go in `scripts/ids.local.ps1` (never committed).
* Modules never decide their own subscription and always accept `tags`.
* New parameters get a type in `modules/types.bicep`; cross-field rules go into the pre-flight checks of `scripts/Deploy-LandingZone.ps1`.
* No commented-out code: make optional behaviour a parameter instead.
* Never commit IDs, passwords or compiled ARM JSON (`main.json`). Run `git status` before every commit.

## Workflow
`main` only receives changes through pull requests with a passing **Bicep What-If**.

```powershell
git switch main ; git pull origin main          # always start from the latest main
git switch -c feat/<topic>                      # feat/, fix/, chore/, docs/, ci/
# make the change
Get-ChildItem -Recurse -Include *.bicep, *.bicepparam | ForEach-Object { bicep format $_.FullName }
bicep build-params primary-centralindia/main.bicepparam --stdout | Out-Null
./scripts/Deploy-LandingZone.ps1 -Stack primary-centralindia        # pre-flight checks + what-if
git add <files>
git commit -m "feat(scope): short summary"
git push -u origin feat/<topic>
gh pr create --fill
```
Read the what-if in the pull request's run **Summary** before merging. Keep one logical change per pull request.

## Commit messages
[Conventional Commits](https://www.conventionalcommits.org/): `type(scope): summary`.

| Type | Use for |
|------|---------|
| `feat` | New capability or resource |
| `fix` | Bug fix |
| `chore` | Maintenance with no behaviour change |
| `docs` | Documentation only |
| `ci` | Workflow changes |
| `style` | Formatting only |

## Diagrams
Diagrams are Mermaid sources in `docs/diagrams/` with PNG exports in `docs/images/`. When you change a source, re-export it (command in [docs/architecture-diagrams.md](docs/architecture-diagrams.md)) and commit both files.

## Keeping your local copy current
```powershell
git switch main ; git pull origin main ; git fetch --prune
git branch -D <merged-branch>        # -D because squash merges create a new commit
```
If your pull request falls behind `main`, click **Update branch** or run `git fetch origin`, `git rebase origin/main` and `git push --force-with-lease`.
