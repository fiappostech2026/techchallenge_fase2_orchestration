// Infraestrutura como código da Fase 4: o registro privado de imagens (ACR) e o cluster
// Kubernetes gerenciado (AKS) onde rodam Kong, as APIs, os bancos e o monitoramento.
// O resource group é criado antes, fora deste template (`az group create`), e este arquivo é
// implantado com `az deployment group create` — os dois passos estão em
// scripts/provision-azure.sh. Rodar de novo não duplica nada: o Azure só ajusta o que mudou.

@description('Região dos recursos.')
param location string = resourceGroup().location

@description('Nome do Azure Container Registry. Precisa ser único no Azure inteiro (só letras minúsculas e números, 5 a 50 caracteres).')
@minLength(5)
@maxLength(50)
param acrName string

@description('Nome do cluster AKS.')
param aksName string = 'aks-fcg'

@description('Quantidade de máquinas (nós) do cluster.')
@minValue(1)
param nodeCount int = 2

@description('Tamanho das máquinas do cluster. Standard_D2s_v4 = 2 vCPUs e 8 GB de RAM. A série B (B2ms) não é liberada para AKS em todas as assinaturas/regiões.')
param nodeVmSize string = 'Standard_D2s_v4'

@description('Versão do Kubernetes. Vazio = a versão padrão que o Azure oferece no momento.')
param kubernetesVersion string = ''

// Papel "AcrPull" (id fixo, igual em todo o Azure): permite só BAIXAR imagens do registro.
var acrPullRoleId = '7f951dda-4ed3-4680-a7ca-43fe172d538d'

resource acr 'Microsoft.ContainerRegistry/registries@2023-07-01' = {
  name: acrName
  location: location
  sku: {
    name: 'Basic'
  }
  properties: {
    // Sem usuário/senha de administrador: quem envia imagens (GitHub Actions) e quem baixa
    // (o AKS) entram com identidade do Azure, então nenhuma senha do registro existe.
    adminUserEnabled: false
  }
}

resource aks 'Microsoft.ContainerService/managedClusters@2024-02-01' = {
  name: aksName
  location: location
  // Identidade gerenciada pelo Azure: o cluster recebe uma "conta" própria, sem senha para guardar.
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    kubernetesVersion: empty(kubernetesVersion) ? null : kubernetesVersion
    dnsPrefix: aksName
    agentPoolProfiles: [
      {
        name: 'system'
        mode: 'System'
        osType: 'Linux'
        count: nodeCount
        vmSize: nodeVmSize
      }
    ]
    // Azure CNI em modo "overlay": é o padrão atual do `az aks create` e não exige criar rede
    // virtual nem planejar faixas de IP. O kubenet seria a outra opção simples, mas está sendo
    // aposentado pela Microsoft.
    networkProfile: {
      networkPlugin: 'azure'
      networkPluginMode: 'overlay'
    }
  }
}

// Equivalente ao `az aks create --attach-acr`: dá à identidade das máquinas do cluster
// (kubelet) o papel AcrPull no registro, para o AKS conseguir baixar as imagens das APIs.
// O nome é um guid() calculado dos mesmos dados, então rodar de novo não cria uma cópia.
resource aksAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(acr.id, aks.id, acrPullRoleId)
  scope: acr
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', acrPullRoleId)
    principalId: aks.properties.identityProfile.kubeletidentity.objectId
    principalType: 'ServicePrincipal'
  }
}

output acrName string = acr.name
output acrLoginServer string = acr.properties.loginServer
output aksName string = aks.name
