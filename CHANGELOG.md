# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Added
- Hub-and-spoke landing zone for Central India (primary) across four subscriptions (governance, hub, identity, workload), as one subscription-scope Bicep deployment per region with module scopes per subscription.
- Nine modules: monitoring, network, firewall, dns, peering, key-vault, domain-controllers, recovery-vault, policy; shared parameter schemas in `modules/types.bicep`.
- Mandatory tags checked before deployment, applied to every taggable resource and enforced by subscription-scope Azure Policy; other policies start in audit mode.
- Built-in policy definitions referenced by GUID (`builtInPolicyDefinitions`), including the roles needed by Modify policies.
- Service Health alert per distinct subscription, routed to the governance action group.
- `scripts/Deploy-LandingZone.ps1`: pre-flight checks, DC password generated once and read back from Key Vault, what-if, confirm-before-deploy, firewall IP check, job summaries in CI.
- GitHub Actions pipeline: **Bicep What-If** (lint, format check, build, pre-flight checks, what-if) on pull requests and `main`; **Bicep Deploy** started by `workflow_run`, gated by the `prod` environment, deploying the previewed commit. Authentication with OIDC federated credentials; no client secret.
- Subscription IDs kept out of Git (`scripts/ids.local.ps1` locally, repository variables in CI).
- Documentation: local deployment guide, CI/CD pipeline, deployment and DR, design decisions, architecture diagrams, contributing guide, security policy, pull request template.

[Unreleased]: https://github.com/hitulgala/azure-landing-zone-bicep/commits/main
