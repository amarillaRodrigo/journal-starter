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

# El deploy NO toca material sensible.
#
# Las credenciales viven en AWS Secrets Manager y las baja el init container de
# cada pod, con el rol de servicio de la app (journal-api-runtime-role), a un
# emptyDir en memoria. Este script solo publica la configuracion NO sensible
# (que va en un ConfigMap) y el pull secret de ECR.
#
# Consecuencia: ni el Secret de Kubernetes ni el spec del pod contienen una
# credencial, y el rol de la instancia no tiene permiso de lectura sobre los
# secretos: no puede leerlos ni siquiera por error.

echo "==> Liberando disco (imagenes sin uso en containerd)"
# containerd guarda una imagen por commit (el tag es el SHA). Sin esta poda el
# nodo acumula capas y termina en DiskPressure: el kubelet evicta pods en masa
# y el rollout nunca converge.
sudo k3s crictl rmi --prune >/dev/null 2>&1 || true
df -h / | tail -1

echo "==> Namespace"
kubectl apply -f k8s/namespace.yaml

echo "==> Observabilidad (ADOT Collector + Fluent Bit)"
kubectl apply -f k8s/adot-collector.yaml -f k8s/fluent-bit.yaml
kubectl -n "${NAMESPACE}" rollout status deployment/adot-collector --timeout=180s
kubectl -n "${NAMESPACE}" rollout status daemonset/fluent-bit --timeout=180s

echo "==> Configuracion no sensible desde SSM Parameter Store"
OPENAI_URL="$(param /journal-api/OPENAI_BASE_URL)"
OPENAI_MODEL="$(param /journal-api/OPENAI_MODEL)"

# ConfigMap, no Secret: estos valores son publicos (URL del proveedor y nombre
# del modelo) y no tienen por que ir cifrados ni en etcd.
kubectl -n "${NAMESPACE}" create configmap journal-config \
  --from-literal=OPENAI_BASE_URL="${OPENAI_URL}" \
  --from-literal=OPENAI_MODEL="${OPENAI_MODEL}" \
  --dry-run=client -o yaml | kubectl apply -f -

# Limpieza de los Secrets con credenciales que usaba el esquema anterior: si
# quedan, el material sigue en etcd aunque nadie los use.
kubectl -n "${NAMESPACE}" delete secret journal-secrets journal-db --ignore-not-found

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
# El init container de Postgres usa la imagen de la app, asi que tambien hay
# que sustituirle el tag del commit.
sed "s|journal-api:placeholder|journal-api:${TAG}|g" k8s/postgresql.yaml | kubectl apply -f -
kubectl apply -f k8s/service.yaml

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
