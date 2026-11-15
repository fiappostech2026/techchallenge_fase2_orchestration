#!/usr/bin/env bash
# Cria (ou atualiza) a infraestrutura da Fase 4 no Azure: resource group, ACR e AKS,
# descritos em infra/main.bicep. Pode rodar de novo quantas vezes quiser: o Azure só
# ajusta o que estiver diferente do arquivo, nada é duplicado.
#
# Uso:
#   cp infra/.env.example infra/.env   # e preencha
#   az login
#   ./scripts/provision-azure.sh
#
# Para apagar tudo depois (o AKS cobra por hora enquanto existir):
#   az group delete -n rg-fcg

set -euo pipefail

cd "$(dirname "$0")/.."

envFile="infra/.env"
[[ -f "$envFile" ]] || { echo "Arquivo $envFile não encontrado. Copie infra/.env.example para $envFile e preencha." >&2; exit 1; }
set -a
# shellcheck source=/dev/null
source "$envFile"
set +a

: "${AZ_LOCATION:?defina AZ_LOCATION em $envFile, ex: eastus}"
: "${AZ_RESOURCE_GROUP:?defina AZ_RESOURCE_GROUP em $envFile, ex: rg-fcg}"
: "${ACR_NAME:?defina ACR_NAME em $envFile (nome único no Azure, só letras minúsculas e números)}"
: "${AKS_NAME:?defina AKS_NAME em $envFile, ex: aks-fcg}"

echo "Criando o resource group $AZ_RESOURCE_GROUP em $AZ_LOCATION..."
az group create -n "$AZ_RESOURCE_GROUP" -l "$AZ_LOCATION" -o none

echo "Implantando infra/main.bicep (ACR + AKS). A primeira vez leva de 5 a 10 minutos..."
az deployment group create \
  -g "$AZ_RESOURCE_GROUP" \
  -n fcg-infra \
  -f infra/main.bicep \
  -p acrName="$ACR_NAME" aksName="$AKS_NAME" \
  --query properties.outputs -o json

echo
echo "Infraestrutura pronta. Próximo passo: ./scripts/setup-github-oidc.sh"
