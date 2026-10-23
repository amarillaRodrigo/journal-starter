#!/usr/bin/env bash
# Verificación de seguridad post-deploy.
#
# Corre DENTRO de la instancia (por SSM Run Command), con las credenciales del
# instance role. Comprueba que las propiedades de seguridad del deploy siguen
# en pie, no solo que la app responde.
#
# Por qué existe: un deploy verde solo dice que el rollout convergió. No dice
# que el IAM siga acotado, que el secreto que consume el pod siga siendo el
# de Secrets Manager, ni que las denegaciones esperadas sigan ocurriendo.
# Estas comprobaciones son la red de seguridad que hace que la migración a
# Secrets Manager sea una propiedad continua y no un hecho de un día.
#
# Uso: bash scripts/verify-security.sh
# Salida: 0 si todas las comprobaciones pasan, 1 si alguna falla.

set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
NAMESPACE="journal-api"

export KUBECONFIG="${KUBECONFIG:-/etc/rancher/k3s/k3s.yaml}"

FAILURES=0
PASSES=0

pass() { printf '  [PASS] %s\n' "$1"; PASSES=$((PASSES + 1)); }
fail() { printf '  [FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# --- helpers -----------------------------------------------------------------

# sha256 del valor que un Secret de k8s entrega al pod. Vacío si no se puede leer.
hash_of_k8s_secret() {
  local raw
  raw="$(kubectl -n "${NAMESPACE}" get secret "$1" -o jsonpath="{.data.$2}" 2>/dev/null)" || return 1
  [ -n "${raw}" ] || return 1
  printf '%s' "${raw}" | base64 -d 2>/dev/null | sha256sum | cut -d' ' -f1
}

# sha256 de un valor guardado en Secrets Manager. Vacío si no se puede leer.
hash_of_sm_secret() {
  local raw value
  raw="$(aws secretsmanager get-secret-value --secret-id "$1" --region "${REGION}" --output json 2>/dev/null)" || return 1
  [ -n "${raw}" ] || return 1
  value="$(printf '%s' "${raw}" \
    | python3 -c "import json,sys; print(json.loads(json.load(sys.stdin)['SecretString'])['$2'])" 2>/dev/null)" || return 1
  [ -n "${value}" ] || return 1
  printf '%s' "${value}" | sha256sum | cut -d' ' -f1
}

# ¿La llamada fue denegada explícitamente por IAM?
is_denied() {
  printf '%s' "$1" | grep -q "AccessDenied"
}

# --- 1. el pod consume exactamente el valor de Secrets Manager ---------------

echo "==> 1. El pod consume exactamente el valor de Secrets Manager"
check_hash() {
  local k8s_secret="$1" key="$2" sm_secret="$3" label="$4"
  local k8s_hash sm_hash
  k8s_hash="$(hash_of_k8s_secret "${k8s_secret}" "${key}")"
  sm_hash="$(hash_of_sm_secret "${sm_secret}" "${key}")"
  if [ -z "${k8s_hash}" ] || [ -z "${sm_hash}" ]; then
    fail "${label}: no se pudo leer (k8s=${k8s_hash:-vacio} secrets=${sm_hash:-vacio})"
  elif [ "${k8s_hash}" = "${sm_hash}" ]; then
    pass "${label}: sha256 ${k8s_hash:0:12} idéntico en k8s y en Secrets Manager"
  else
    fail "${label}: DIVERGENCIA k8s=${k8s_hash:0:12} secrets=${sm_hash:0:12}"
  fi
}
check_hash journal-secrets OPENAI_API_KEY journal-api/credentials/llm "OPENAI_API_KEY"
check_hash journal-db POSTGRES_PASSWORD journal-api/credentials/database "POSTGRES_PASSWORD"

# --- 2. el IAM no deja listar secretos ---------------------------------------

echo ""
echo "==> 2. El IAM no deja listar secretos"
out="$(aws secretsmanager list-secrets --region "${REGION}" 2>&1 || true)"
if is_denied "${out}"; then
  pass "list-secrets -> AccessDenied"
else
  fail "list-secrets NO fue denegado: ${out}"
fi

# --- 3. el IAM no deja leer un secreto fuera de scope ------------------------

echo ""
echo "==> 3. El IAM no deja leer un secreto fuera de scope"
out="$(aws secretsmanager get-secret-value \
        --secret-id journal-api/credentials/fuera-de-scope \
        --region "${REGION}" 2>&1 || true)"
if is_denied "${out}"; then
  pass "get-secret-value (fuera de scope) -> AccessDenied"
else
  fail "get-secret-value (fuera de scope) NO fue denegado: ${out}"
fi

# --- 4. el IAM no deja leer los parámetros SSM de credenciales ----------------

echo ""
echo "==> 4. El IAM no deja leer los parametros SSM de credenciales"
# Esos parametros ya no existen (se limpiaron con --cleanup-ssm), pero el Deny
# explicito se evalua antes que la existencia: por eso esto tiene que dar
# AccessDenied y no ParameterNotFound.
out="$(aws ssm get-parameter --name /journal-api/POSTGRES_PASSWORD \
        --region "${REGION}" 2>&1 || true)"
if is_denied "${out}"; then
  pass "ssm:GetParameter (credenciales) -> AccessDenied"
else
  fail "ssm:GetParameter (credenciales) respondio: ${out}"
fi

# --- 5. la configuración no sensible sigue siendo legible --------------------

echo ""
echo "==> 5. La configuracion no sensible sigue siendo de lectura publica"
out="$(aws ssm get-parameter --name /journal-api/OPENAI_MODEL \
        --region "${REGION}" --query 'Parameter.Value' --output text 2>&1 || true)"
if is_denied "${out}"; then
  fail "El parametro de configuracion deberia ser legible: ${out}"
else
  pass "OPENAI_MODEL es legible (config, no secreto)"
fi

# --- 6. ningún pod expone la credencial en texto plano en su spec ------------

echo ""
echo "==> 6. Ningun pod expone la credencial en texto plano en su spec"
leaked="$(kubectl -n "${NAMESPACE}" get pods -o json 2>/dev/null \
  | python3 -c "
import json, sys
try:
    pods = json.load(sys.stdin)
except Exception:
    sys.exit(0)
hits = []
for p in pods.get('items', []):
    for c in p['spec']['containers']:
        for e in (c.get('env') or []):
            if e.get('value') and e.get('name') in ('OPENAI_API_KEY', 'DATABASE_URL', 'POSTGRES_PASSWORD'):
                hits.append(p['metadata']['name'] + ':' + e['name'])
print(' '.join(hits))
" 2>/dev/null || true)"
if [ -z "${leaked}" ]; then
  pass "ningun pod lleva la credencial en el spec (solo referencias secretKeyRef)"
else
  fail "credencial en texto plano en el spec del pod: ${leaked}"
fi

# --- 7. los pods siguen sanos -------------------------------------------------

echo ""
echo "==> 7. Los pods siguen sanos"
total="$(kubectl -n "${NAMESPACE}" get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')"
notready="$(kubectl -n "${NAMESPACE}" get pods --no-headers 2>/dev/null | grep -vc ' Running' || true)"
if [ "${notready}" = "0" ] && [ "${total}" -ge 5 ]; then
  pass "${total} pods Running"
else
  fail "${total} pods, ${notready} no Running"
fi

# --- resumen ------------------------------------------------------------------

echo ""
echo "======================================================"
printf 'Verificacion de seguridad: %s PASS, %s FAIL\n' "${PASSES}" "${FAILURES}"
# Sentinel unico: el job de CI lo busca para decidir si el deploy es seguro.
# "NO cumple..." contendria el texto del caso Bueno, asi que el marcador
# tiene que ser inequivoco.
if [ "${FAILURES}" -ne 0 ]; then
  echo "RESULTADO_SEGURIDAD: FALLO"
  exit 1
fi
echo "RESULTADO_SEGURIDAD: OK"
exit 0
