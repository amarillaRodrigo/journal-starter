#!/usr/bin/env bash
# Deploy de la imagen de Journal API al cluster k3s del nodo EC2.
#
# Uso: ./scripts/deploy-k8s.sh <image-tag>
#
# - Lee los secretos desde SSM Parameter Store (nunca desde el repo).
# - Crea/actualiza los Secrets de Kubernetes y el pull secret de ECR.
# - Aplica los manifiestos de k8s/ y espera el rollout de la API.
set -euo pipefail

TAG="${1:?uso: deploy-k8s.sh <image-tag>}"
REGION="us-east-1"
REGISTRY="607856468834.dkr.ecr.us-east-1.amazonaws.com"
REPO="journal-api"
NAMESPACE="journal-api"
IMAGE="${REGISTRY}/${REPO}:${TAG}"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

param() {
  local name="$1"
  shift
  aws ssm get-parameter --name "${name}" --region "${REGION}" "$@" \
    --query 'Parameter.Value' --output text
}

echo "==> Namespace"
kubectl apply -f k8s/namespace.yaml

echo "==> Secretos desde SSM Parameter Store"
PGPASS="$(param /journal-api/POSTGRES_PASSWORD --with-decryption)"
OPENAI_KEY="$(param /journal-api/OPENAI_API_KEY --with-decryption)"
OPENAI_URL="$(param /journal-api/OPENAI_BASE_URL)"
OPENAI_MODEL="$(param /journal-api/OPENAI_MODEL)"

kubectl -n "${NAMESPACE}" create secret generic journal-db \
  --from-literal=POSTGRES_PASSWORD="${PGPASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${NAMESPACE}" create secret generic journal-secrets \
  --from-literal=DATABASE_URL="postgresql://postgres:${PGPASS}@postgres:5432/career_journal" \
  --from-literal=OPENAI_API_KEY="${OPENAI_KEY}" \
  --from-literal=OPENAI_BASE_URL="${OPENAI_URL}" \
  --from-literal=OPENAI_MODEL="${OPENAI_MODEL}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Pull secret de ECR"
aws ecr get-login-password --region "${REGION}" \
  | kubectl -n "${NAMESPACE}" create secret docker-registry ecr-credential \
      --docker-server="${REGISTRY}" \
      --docker-username=AWS \
      --docker-password-stdin \
      --dry-run=client -o yaml | kubectl apply -f -

echo "==> Postgres, Service y Caddy"
kubectl apply -f k8s/postgresql.yaml -f k8s/service.yaml -f k8s/caddy.yaml

echo "==> Esperando Postgres"
kubectl -n "${NAMESPACE}" rollout status deployment/postgres --timeout=180s

echo "==> Esquema de la base (idempotente)"
kubectl -n "${NAMESPACE}" exec -i deploy/postgres -- \
  psql -U postgres -d career_journal -v ON_ERROR_STOP=1 < database_setup.sql

echo "==> Journal API ${IMAGE}"
sed "s|journal-api:placeholder|journal-api:${TAG}|" k8s/deployment.yaml \
  | kubectl -n "${NAMESPACE}" apply -f -

echo "==> Esperando rollout"
kubectl -n "${NAMESPACE}" rollout status deployment/journal-api --timeout=240s

kubectl -n "${NAMESPACE}" get pods -o wide

echo "==> Deploy OK: ${IMAGE}"
