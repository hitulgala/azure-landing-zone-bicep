// =============================================================================
// Module  : policy   (ONE call per subscription; subscription-scope assignments)
// Purpose : Azure Policy for a single subscription, driven entirely by params:
//             * MANDATORY TAGS - for every tag in mandatoryTagNames:
//                 - require the tag on resource groups   (Deny)
//                 - inherit the tag from the resource group when missing (Modify)
//                 - optionally require the tag on every resource (Deny)
//             * ANY other built-in policy: allowed VM SKUs, allowed locations,
//               no public IPs on NICs, ... defined in 'assignments'.
//
// enforce = false -> "DoNotEnforce": evaluated and reported, nothing blocked (audit).
// enforce = true  -> Deny / Modify effects are active.
//
// Built-in definitions are referenced by their fixed GUIDs (identical in every
// tenant): builtInPolicyDefinitions maps each display name used in the
// parameters to its GUID and to the roles its managed identity needs.
// Scope   : subscription.
// =============================================================================
targetScope = 'subscription'

import {
  policyDefinitionNamesType
  builtInPolicyDefinitionsType
  subscriptionPoliciesType
} from '../types.bicep'

@description('Region for the managed identities of Modify policies (metadata only).')
param location string
param mandatoryTagNames string[]
param policyDefinitionNames policyDefinitionNamesType
param builtInPolicyDefinitions builtInPolicyDefinitionsType
param policies subscriptionPoliciesType

var tags = policies.mandatoryTags

// ---- Mandatory-tag assignments, expanded from the tag list --------------------------
var tagOnRgAssignments = tags.requireOnResourceGroups
  ? map(mandatoryTagNames, t => {
      name: 'tag-rg-${t}'
      displayName: 'Require tag \'${t}\' on resource groups'
      definitionDisplayName: policyDefinitionNames.requireTagOnResourceGroups
      enforce: tags.enforce
      parameters: { tagName: t }
      identity: false
    })
  : []

var tagInheritAssignments = tags.inheritFromResourceGroup
  ? map(mandatoryTagNames, t => {
      name: 'tag-inherit-${t}'
      displayName: 'Inherit tag \'${t}\' from the resource group'
      definitionDisplayName: policyDefinitionNames.inheritTagFromResourceGroup
      enforce: tags.enforce
      parameters: { tagName: t }
      identity: true // Modify effect needs a managed identity
    })
  : []

var tagOnResourceAssignments = tags.requireOnResources
  ? map(mandatoryTagNames, t => {
      name: 'tag-res-${t}'
      displayName: 'Require tag \'${t}\' on resources'
      definitionDisplayName: policyDefinitionNames.requireTagOnResources
      enforce: tags.enforce
      parameters: { tagName: t }
      identity: false
    })
  : []

// ---- Free-form assignments --------------------------------------------------------
var customAssignments = map(items(policies.assignments), a => {
  name: a.key
  displayName: a.value.displayName
  definitionDisplayName: a.value.definitionDisplayName
  enforce: a.value.?enforce ?? false
  parameters: a.value.?parameters ?? {}
  identity: a.value.?identity ?? false
})

var allAssignments = concat(tagOnRgAssignments, tagInheritAssignments, tagOnResourceAssignments, customAssignments)

// ---- Roles for the managed identities (from builtInPolicyDefinitions) ------------------
var identityRoles = flatten(map(
  range(0, length(allAssignments)),
  i =>
    allAssignments[i].identity
      ? map(builtInPolicyDefinitions[allAssignments[i].definitionDisplayName].?roleDefinitionIds ?? [], r => {
          index: i
          roleGuid: r
        })
      : []
))

resource assignment 'Microsoft.Authorization/policyAssignments@2024-04-01' = [
  for a in allAssignments: {
    name: a.name // max 64 characters at subscription scope
    // A location is only needed (and allowed) when the assignment has an identity.
    location: a.identity ? location : null
    identity: a.identity ? { type: 'SystemAssigned' } : null
    properties: {
      displayName: a.displayName
      policyDefinitionId: tenantResourceId(
        'Microsoft.Authorization/policyDefinitions',
        builtInPolicyDefinitions[a.definitionDisplayName].id
      )
      enforcementMode: a.enforce ? 'Default' : 'DoNotEnforce'
      // Parameter values are wrapped as { name: { value: ... } } as Azure expects.
      parameters: toObject(items(a.parameters), p => p.key, p => { value: p.value })
    }
  }
]

resource identityRole 'Microsoft.Authorization/roleAssignments@2022-04-01' = [
  for r in identityRoles: {
    name: guid(subscription().id, allAssignments[r.index].name, r.roleGuid)
    properties: {
      principalId: assignment[r.index].identity.principalId
      principalType: 'ServicePrincipal' // the new identity may not be visible in Entra ID yet
      roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', r.roleGuid)
    }
  }
]

output assignmentNames string[] = map(allAssignments, a => a.name)
