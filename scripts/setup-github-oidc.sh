#!/usr/bin/env bash
# Liga o GitHub Actions ao Azure sem nenhuma senha guardada (login por OIDC) e preenche os
# Secrets/Variables dos 4 repositórios do FCG. Rode depois de scripts/provision-azure.sh.
#
# O que ele faz:
#   1. cria (ou reaproveita) o App Registration "fcg-github-actions" e o Service Principal dele;
#   2. em cada repositório, cria a "credencial federada": o Azure passa a aceitar o token que o
#      GitHub emite para jobs com "environment: production" daquele repositório — e só esses;
#   3. dá ao Service Principal só o necessário: AcrPush no ACR (enviar imagens) e
#      "Azure Kubernetes Service Cluster User Role" no AKS (baixar o kubeconfig);
#   4. com o gh, cria o environment "production" (só aceita deploy das branches main e
#      tech_fase_4) e grava Secrets e Variables em cada repositório.
#
# Pode rodar de novo: o que já existe é reaproveitado e os Secrets/Variables são sobrescritos.
#
# Uso:
#   az login && gh auth login
#   ./scripts/setup-github-oidc.sh

set -euo pipefail

cd "$(dirname "$0")/.."

envFile="infra/.env"
[[ -f "$envFile" ]] || { echo "Arquivo $envFile não encontrado. Copie infra/.env.example para $envFile e preencha." >&2; exit 1; }
set -a
# shellcheck source=/dev/null
source "$envFile"
set +a

appDisplayName="fcg-github-actions"
repos=(
  techchallenge_fase2_user
  techchallenge_fase2_catalog_service
  techchallenge_fase2_payments_service
  techchallenge_fase2_orchestration
)

# Secrets de aplicação que cada repositório usa no próprio workflow.
appSecretNamesForRepo() {
  local repo="$1"
  local rabbitmq="RABBITMQ_HOST RABBITMQ_VHOST RABBITMQ_PORT RABBITMQ_USE_SSL RABBITMQ_USER RABBITMQ_PASSWORD"
  case "$repo" in
    techchallenge_fase2_user)             echo "JWT_SECRET_KEY $rabbitmq USERS_SQL_PASSWORD" ;;
    techchallenge_fase2_catalog_service)  echo "JWT_SECRET_KEY $rabbitmq CATALOG_SQL_PASSWORD ELASTICSEARCH_URL ELASTICSEARCH_API_KEY" ;;
    techchallenge_fase2_payments_service) echo "$rabbitmq" ;;
    techchallenge_fase2_orchestration)    echo "JWT_SECRET_KEY" ;;
  esac
}

# Falha antes de mexer em qualquer coisa se faltar alguma entrada no infra/.env.
requireInputs() {
  local missing=()
  local name repo
  for name in AZ_RESOURCE_GROUP ACR_NAME AKS_NAME GITHUB_OWNER; do
    [[ -n "${!name:-}" ]] || missing+=("$name")
  done
  for repo in "${repos[@]}"; do
    for name in $(appSecretNamesForRepo "$repo"); do
      [[ -n "${!name:-}" ]] || missing+=("$name")
    done
  done
  if (( ${#missing[@]} > 0 )); then
    local uniqueMissing
    uniqueMissing="$(printf '%s\n' "${missing[@]}" | sort -u | tr '\n' ' ')"
    echo "Preencha em $envFile: $uniqueMissing" >&2
    exit 1
  fi
}

# Imprime o appId do App Registration, criando-o (e o Service Principal) se ainda não existir.
ensureAppRegistration() {
  local appId
  # --display-name filtra por prefixo; a query garante o nome exato.
  appId="$(az ad app list --display-name "$appDisplayName" --query "[?displayName=='$appDisplayName'].appId | [0]" -o tsv)"
  if [[ -z "$appId" ]]; then
    appId="$(az ad app create --display-name "$appDisplayName" --query appId -o tsv)"
    echo "App Registration $appDisplayName criado." >&2
  fi
  if ! az ad sp show --id "$appId" -o none 2>/dev/null; then
    az ad sp create --id "$appId" -o none
    echo "Service Principal criado." >&2
  fi
  echo "$appId"
}

ensureFederatedCredential() {
  local appId="$1" repo="$2"
  local credentialName="${repo}-production"
  local existingCount
  existingCount="$(az ad app federated-credential list --id "$appId" --query "length([?name=='$credentialName'])" -o tsv)"
  if [[ "$existingCount" != "0" ]]; then
    echo "Credencial federada $credentialName já existe."
    return
  fi
  az ad app federated-credential create --id "$appId" -o none --parameters "$(cat <<EOF
{
  "name": "$credentialName",
  "issuer": "https://token.actions.githubusercontent.com",
  "subject": "repo:$GITHUB_OWNER/$repo:environment:production",
  "audiences": ["api://AzureADTokenExchange"]
}
EOF
)"
  echo "Credencial federada $credentialName criada."
}

assignRole() {
  local spObjectId="$1" role="$2" scope="$3"
  az role assignment create \
    --assignee-object-id "$spObjectId" \
    --assignee-principal-type ServicePrincipal \
    --role "$role" \
    --scope "$scope" -o none
  echo "Papel \"$role\" garantido."
}

# Valor pelo stdin: nunca aparece em argumento de linha de comando (ps, histórico do shell).
setGithubSecret() {
  local repo="$1" name="$2" value="$3"
  printf '%s' "$value" | gh secret set "$name" --repo "$GITHUB_OWNER/$repo"
}

# O environment "production" só aceita jobs vindos destas branches. Sem isso, qualquer branch
# com o workflow poderia pegar o token OIDC e fazer deploy.
deployBranches=(main tech_fase_4)

ensureProductionEnvironment() {
  local repo="$1"
  local environmentPath="repos/$GITHUB_OWNER/$repo/environments/production"
  local existingBranches branch
  gh api -X PUT "$environmentPath" --silent --input - <<'EOF'
{"deployment_branch_policy": {"protected_branches": false, "custom_branch_policies": true}}
EOF
  # Lista antes de criar: o POST de uma branch que já está na política devolve erro.
  existingBranches="$(gh api "$environmentPath/deployment-branch-policies" --jq '.branch_policies[].name')"
  for branch in "${deployBranches[@]}"; do
    if grep -qxF "$branch" <<<"$existingBranches"; then
      continue
    fi
    gh api -X POST "$environmentPath/deployment-branch-policies" -f name="$branch" --silent
    echo "Branch $branch liberada no environment production."
  done
}

configureGithubRepo() {
  local repo="$1" appId="$2" tenantId="$3" subscriptionId="$4"
  local name
  echo "--- $GITHUB_OWNER/$repo"
  ensureProductionEnvironment "$repo"

  setGithubSecret "$repo" AZURE_CLIENT_ID "$appId"
  setGithubSecret "$repo" AZURE_TENANT_ID "$tenantId"
  setGithubSecret "$repo" AZURE_SUBSCRIPTION_ID "$subscriptionId"
  for name in $(appSecretNamesForRepo "$repo"); do
    setGithubSecret "$repo" "$name" "${!name}"
  done

  gh variable set ACR_NAME --repo "$GITHUB_OWNER/$repo" --body "$ACR_NAME"
  gh variable set AKS_RESOURCE_GROUP --repo "$GITHUB_OWNER/$repo" --body "$AZ_RESOURCE_GROUP"
  gh variable set AKS_CLUSTER_NAME --repo "$GITHUB_OWNER/$repo" --body "$AKS_NAME"
}

requireInputs

tenantId="$(az account show --query tenantId -o tsv)"
subscriptionId="$(az account show --query id -o tsv)"
acrId="$(az acr show -n "$ACR_NAME" -g "$AZ_RESOURCE_GROUP" --query id -o tsv)"
aksId="$(az aks show -n "$AKS_NAME" -g "$AZ_RESOURCE_GROUP" --query id -o tsv)"

appId="$(ensureAppRegistration)"
spObjectId="$(az ad sp show --id "$appId" --query id -o tsv)"

for repo in "${repos[@]}"; do
  ensureFederatedCredential "$appId" "$repo"
done

assignRole "$spObjectId" AcrPush "$acrId"
assignRole "$spObjectId" "Azure Kubernetes Service Cluster User Role" "$aksId"

for repo in "${repos[@]}"; do
  configureGithubRepo "$repo" "$appId" "$tenantId" "$subscriptionId"
done

echo
echo "GitHub ligado ao Azure. Próximo passo: rodar o workflow \"Deploy da plataforma\" deste repositório (aba Actions)."
