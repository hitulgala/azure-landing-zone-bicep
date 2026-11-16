## What changes
<!-- One logical change. What and why. -->

## Stack(s) affected
- [ ] primary-centralindia
- [ ] secondary-southindia
- [ ] modules (both stacks)
- [ ] pipeline / scripts / docs only

## Checklist
- [ ] Values changed in `main.bicepparam`, not hard-coded in `.bicep` files
- [ ] `bicep format` run on changed files
- [ ] Pre-flight checks and what-if pass locally (`./scripts/Deploy-LandingZone.ps1 -Stack <stack>`)
- [ ] What-if in this pull request's run Summary reviewed: no unexpected `Create`, `Delete` or `Modify`
- [ ] No IDs, passwords or other secrets committed
- [ ] Docs and diagrams updated if behaviour or the address plan changed
