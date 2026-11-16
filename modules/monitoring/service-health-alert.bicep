// =============================================================================
// Service Health alert for ONE subscription.
//
// Azure allows exactly one scope per activity log alert rule ("The rule scope
// must contain only one item"), and the rule must live in the subscription it
// watches. The stack therefore calls this module once per DISTINCT
// subscription, in a resource group of that subscription. All rules notify the
// same action group in the governance subscription.
// Scope: a resource group in the monitored subscription.
// =============================================================================
import { governanceType } from '../types.bicep'

param name string
param tags object
param actionGroupId string
param config governanceType['serviceHealthAlert']

var locations = config.?locations ?? []

resource serviceHealthAlert 'Microsoft.Insights/activityLogAlerts@2020-10-01' = {
  name: name
  location: 'global' // Azure-mandated
  tags: tags
  properties: {
    description: 'Azure Service Health events'
    enabled: true
    scopes: [
      subscription().id
    ]
    condition: {
      allOf: concat(
        [
          {
            field: 'category'
            equals: 'ServiceHealth'
          }
          {
            anyOf: map(config.events, e => {
              field: 'properties.incidentType'
              equals: e
            })
          }
        ],
        empty(locations)
          ? []
          : [
              {
                field: 'properties.impactedServices[*].ImpactedRegions[*].RegionName'
                containsAny: locations
              }
            ]
      )
    }
    actions: {
      actionGroups: [
        {
          actionGroupId: actionGroupId
        }
      ]
    }
  }
}
