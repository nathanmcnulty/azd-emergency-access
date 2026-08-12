@description('Location for the user-assigned managed identity.')
param location string

@description('Tags applied to the managed identity.')
param tags object

@description('Name of the user-assigned managed identity.')
param identityName string

resource identity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: identityName
  location: location
  tags: tags
}

output id string = identity.id
output name string = identity.name
output clientId string = identity.properties.clientId
output principalId string = identity.properties.principalId
