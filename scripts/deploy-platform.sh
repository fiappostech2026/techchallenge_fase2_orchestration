#!/usr/bin/env bash
# Sobe a "plataforma" compartilhada no cluster do kubectl atual:
# API Gateway (Kong) + monitoramento (Prometheus/Grafana).
#
# Uso:  JWT_SECRET_KEY='<chave>' ./scripts/deploy-platform.sh
#
# A pipeline (azure-pipelines.yml) roda este mesmo script no AKS, com a chave
# vinda do Variable Group do Azure DevOps — a chave nunca é gravada no Git.
set -euo pipefail

: "${JWT_SECRET_KEY:?Defina a variável JWT_SECRET_KEY (mesma chave do UsersAPI/CatalogAPI)}"

cd "$(dirname "$0")/.."

# Gera o kong.yml final trocando o marcador pela chave real (awk + ENVIRON em vez
# de sed para não quebrar se a chave tiver caracteres como / & |).
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
awk '{ while ((i = index($0, "${JWT_SECRET_KEY}")) > 0) $0 = substr($0, 1, i - 1) ENVIRON["JWT_SECRET_KEY"] substr($0, i + 17); print }' \
  k8s/kong/kong.yml.tpl > "$rendered"

# "create --dry-run | apply" cria o Secret na primeira vez e atualiza nas seguintes.
kubectl create secret generic kong-config --from-file=kong.yml="$rendered" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl apply -f k8s/kong/
# O Kong só lê o kong.yml na inicialização: reinicia para pegar rotas/chave novas.
kubectl rollout restart deployment/kong
kubectl rollout status deployment/kong --timeout=180s

kubectl apply -f k8s/monitoring/

echo
echo "Plataforma aplicada. IP público do gateway (pode levar ~1 min para aparecer no AKS):"
kubectl get service kong-proxy
