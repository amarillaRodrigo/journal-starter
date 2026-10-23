#!/usr/bin/env bash
# Verificación de seguridad post-deploy.
#
# Corre DENTRO de la instancia (por SSM Run Command), con las credenciales del
# instance role. Comprueba que las propiedades de seguridad del deploy siguen
# en pie, no solo que la app responde.
#
# Por qué existe: un deploy verde solo dice que el rollout convergió. No dice
# que el IAM siga acotado, que el secreto siga fuera de etcd ni que las
# denegaciones esperadas sigan ocurriendo. Estas comprobaciones son la red de
# seguridad que hace que la migración a Secrets Manager sea una propiedad
# continua y no un hecho de un día.
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

is_denied() { printf '%s' "$1" | grep -q "AccessDenied"; }

# --- 1. el rol de la instancia ya NO puede leer los secretos ------------------

echo "==> 1. El rol de la instancia no puede leer los secretos directamente"
# Los secretos los lee el init container de cada pod, con el rol de servicio
# de la app. El instance profile solo puede DELEGAR en ese rol.
out="$(aws secretsmanager get-secret-value \
        --secret-id journal-api/credentials/llm \
        --region "${REGION}" 2>&1 || true)"
if is_denied "${out}"; then
  pass "get-secret-value con el instance profile -> AccessDenied"
else
  fail "El instance profile puede leer los secretos: ${out}"
fi

# --- 2. no hay material sensible en etcd --------------------------------------

echo ""
echo "==> 2. No queda material sensible en los Secrets de Kubernetes"
# Los pods bajan los secretos a un emptyDir en memoria: en etcd solo queda el
# pull secret de ECR, que es un token efimero.
left=""
for s in journal-secrets journal-db; do
  if kubectl -n "${NAMESPACE}" get secret "${s}" >/dev/null 2>&1; then
    left="${left} ${s}"
  fi
done
if [ -z "${left}" ]; then
  pass "no existen los Secrets ${NAMESPACE}/journal-secrets ni journal-db"
else
  fail "todavia existen Secrets con credenciales en etcd:${left}"
fi

# --- 3. el pod recibio los secretos en su volumen ----------------------------

echo ""
echo "==> 3. El init container bajo los secretos al volumen del pod"
listing="$(kubectl -n "${NAMESPACE}" exec deploy/journal-api -- ls -l /secrets 2>&1 || true)"
if printf '%s' "${listing}" | grep -q "OPENAI_API_KEY" \
   && printf '%s' "${listing}" | grep -q "DATABASE_URL"; then
  perms="$(printf '%s' "${listing}" | grep -c '^-rw-------' || true)"
  if [ "${perms}" -ge 2 ]; then
    pass "OPENAI_API_KEY y DATABASE_URL presentes en /secrets con permisos 0600"
  else
    fail "los archivos de /secrets no tienen permisos 0600: ${listing}"
  fi
else
  fail "el pod no tiene los secretos en /secrets: ${listing}"
fi

# --- 4. ningun pod expone la credencial en el spec ---------------------------

echo ""
echo "==> 4. Ningun pod expone la credencial en el spec"
leaked="$(kubectl -n "${NAMESPACE}" get pods -o json 2>/dev/null \
  | python3 -c "
import json, sys
try:
    pods = json.load(sys.stdin)
except Exception:
    sys.exit(0)
hits = []
for p in pods.get('items', []):
    spec = p['spec']
    for c in spec['containers']:
        for e in (c.get('env') or []):
            if e.get('name') in ('OPENAI_API_KEY', 'DATABASE_URL', 'POSTGRES_PASSWORD'):
                hits.append(p['metadata']['name'] + ':' + e['name'] + ' (env)')
            ref = e.get('valueFrom') or {}
            key = ((ref.get('secretKeyRef') or {}).get('name')) or ''
            if key in ('journal-secrets', 'journal-db'):
                hits.append(p['metadata']['name'] + ':' + e['name'] + ' (secretKeyRef ' + key + ')')
print(' '.join(hits))
" 2>/dev/null || true)"
if [ -z "${leaked}" ]; then
  pass "ningun pod referencia ni contiene la credencial"
else
  fail "credencial referenciada en el spec del pod: ${leaked}"
fi

# --- 5. el IAM no deja listar secretos ----------------------------------------

echo ""
echo "==> 5. El IAM no deja listar secretos"
out="$(aws secretsmanager list-secrets --region "${REGION}" 2>&1 || true)"
if is_denied "${out}"; then
  pass "list-secrets -> AccessDenied"
else
  fail "list-secrets NO fue denegado: ${out}"
fi

# --- 6. el IAM no deja leer un secreto fuera de scope -------------------------

echo ""
echo "==> 6. El IAM no deja leer un secreto fuera de scope"
out="$(aws secretsmanager get-secret-value \
        --secret-id journal-api/credentials/fuera-de-scope \
        --region "${REGION}" 2>&1 || true)"
if is_denied "${out}"; then
  pass "get-secret-value (fuera de scope) -> AccessDenied"
else
  fail "get-secret-value (fuera de scope) NO fue denegado: ${out}"
fi

# --- 7. el IAM no deja leer los parametros SSM de credenciales ---------------

echo ""
echo "==> 7. El IAM no deja leer los parametros SSM de credenciales"
out="$(aws ssm get-parameter --name /journal-api/POSTGRES_PASSWORD \
        --region "${REGION}" 2>&1 || true)"
if is_denied "${out}"; then
  pass "ssm:GetParameter (credenciales) -> AccessDenied"
else
  fail "ssm:GetParameter (credenciales) respondio: ${out}"
fi

# --- 8. la configuracion no sensible sigue siendo legible --------------------

echo ""
echo "==> 8. La configuracion no sensible sigue siendo de lectura publica"
out="$(aws ssm get-parameter --name /journal-api/OPENAI_MODEL \
        --region "${REGION}" --query 'Parameter.Value' --output text 2>&1 || true)"
if is_denied "${out}"; then
  fail "El parametro de configuracion deberia ser legible: ${out}"
else
  pass "OPENAI_MODEL es legible (config, no secreto)"
fi

# --- 9. la app usa su ServiceAccount -----------------------------------------

echo ""
echo "==> 9. Los pods usan la ServiceAccount de la app"
sa="$(kubectl -n "${NAMESPACE}" get pod -l app=journal-api \
      -o jsonpath='{.items[0].spec.serviceAccountName}' 2>/dev/null || true)"
if [ "${sa}" = "journal-api" ]; then
  pass "serviceAccountName=journal-api (su 'sub' es el ExternalId del AssumeRole)"
else
  fail "serviceAccountName='${sa}' (se esperaba 'journal-api')"
fi

# --- 10. la app responde ------------------------------------------------------

echo ""
echo "==> 10. La app responde con la configuracion inyectada"
code="$(curl -sS -o /dev/null -w '%{http_code}' \
        "http://journal-api-service.${NAMESPACE}.svc.cluster.local:8000/version" 2>/dev/null || echo 000)"
if [ "${code}" = "200" ]; then
  pass "GET /version dentro del cluster -> 200"
else
  fail "GET /version dentro del cluster -> ${code}"
fi

# --- 11. los pods siguen sanos ------------------------------------------------

echo ""
echo "==> 11. Los pods siguen sanos"
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
