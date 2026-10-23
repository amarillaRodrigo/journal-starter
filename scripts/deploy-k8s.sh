#!/usr/bin/env bash
# Deploy de la imagen de Journal API al cluster k3s del nodo EC2.
#
# Uso: ./scripts/deploy-k8s.sh <image-tag>
#
# - Lee los secretos desde AWS Secrets Manager (nunca desde el repo).
# - Lee la configuracion no sensible desde SSM Parameter Store.
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

# IP pública de la instancia (IMDSv2). El hostname que sirve Caddy y el
# certificado TLS dependen de ella, y Terraform la reasigna en cada
# destroy/apply: por eso se resuelve en runtime en vez de estar hardcodeada.
public_ip() {
  local token
  token="$(curl -s -X PUT "http://169.254.169.254/latest/api/token" \
             -H "X-aws-ec2-metadata-token-ttl-seconds: 60")"
  curl -s -H "X-aws-ec2-metadata-token: ${token}" \
    "http://169.254.169.254/latest/meta-data/public-ipv4"
}

# Credenciales: viven en AWS Secrets Manager, cifradas con aws/secretsmanager.
# Solo el rol de la instancia puede leerlas, y solo GetSecretValue sobre dos
# ARN exactos (ver terraform/secrets.tf).
#
# Reintenta porque la siembra es out-of-band (scripts/migrate-secrets.sh): en el
# primer arranque el secreto puede todavia no estar listo.
secret_field() {
  local secret_id="$1" key="$2"
  local attempts="${SECRET_READ_ATTEMPTS:-12}"
  local value=""
  for _ in $(seq 1 "${attempts}"); do
    value="$(aws secretsmanager get-secret-value \
                --secret-id "${secret_id}" --region "${REGION}" --output json 2>/dev/null \
              | python3 -c 'import json, sys
raw = json.load(sys.stdin).get("SecretString", "")
try:
    data = json.loads(raw)
except ValueError:
    data = {"VALUE": raw}
sys.stdout.write(str(data.get(sys.argv[1], data.get("VALUE", ""))))' "${key}" 2>/dev/null || true)"
    if [ -n "${value}" ]; then
      printf '%s' "${value}"
      return 0
    fi
    sleep 5
  done
  echo "ERROR: no se pudo leer '${key}' del secreto '${secret_id}'" >&2
  return 1
}

echo "==> Namespace"
kubectl apply -f k8s/namespace.yaml

echo "==> Observabilidad (ADOT Collector + Fluent Bit)"
kubectl apply -f k8s/adot-collector.yaml -f k8s/fluent-bit.yaml
kubectl -n "${NAMESPACE}" rollout status deployment/adot-collector --timeout=180s
kubectl -n "${NAMESPACE}" rollout status daemonset/fluent-bit --timeout=180s

echo "==> Secretos desde AWS Secrets Manager"
PGPASS="$(secret_field journal-api/credentials/database POSTGRES_PASSWORD)"
DB_URL="$(secret_field journal-api/credentials/database DATABASE_URL)"
OPENAI_KEY="$(secret_field journal-api/credentials/llm OPENAI_API_KEY)"

echo "==> Configuracion no sensible desde SSM Parameter Store"
OPENAI_URL="$(param /journal-api/OPENAI_BASE_URL)"
OPENAI_MODEL="$(param /journal-api/OPENAI_MODEL)"

kubectl -n "${NAMESPACE}" create secret generic journal-db \
  --from-literal=POSTGRES_PASSWORD="${PGPASS}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl -n "${NAMESPACE}" create secret generic journal-secrets \
  --from-literal=DATABASE_URL="${DB_URL}" \
  --from-literal=OPENAI_API_KEY="${OPENAI_KEY}" \
  --from-literal=OPENAI_BASE_URL="${OPENAI_URL}" \
  --from-literal=OPENAI_MODEL="${OPENAI_MODEL}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Pull secret de ECR"
ECR_TOKEN="$(aws ecr get-login-password --region "${REGION}")"
ECR_AUTH="$(printf 'AWS:%s' "${ECR_TOKEN}" | base64 -w0)"
kubectl -n "${NAMESPACE}" create secret generic ecr-credential \
  --type=kubernetes.io/dockerconfigjson \
  --from-literal=.dockerconfigjson="{\"auths\":{\"${REGISTRY}\":{\"username\":\"AWS\",\"password\":\"${ECR_TOKEN}\",\"auth\":\"${ECR_AUTH}\"}}}" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Postgres, Service y Caddy"
PUBLIC_IP="$(public_ip)"
ACME_EMAIL="$(param /journal-api/ACME_EMAIL)"
echo "  IP publica: ${PUBLIC_IP}"
sed -e "s|__PUBLIC_IP__|${PUBLIC_IP}|g" -e "s|__ACME_EMAIL__|${ACME_EMAIL}|g" \
  k8s/caddy.yaml | kubectl apply -f -
kubectl apply -f k8s/postgresql.yaml -f k8s/service.yaml

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
