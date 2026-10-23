#!/usr/bin/env bash
# Siembra de los secretos de Journal API en AWS Secrets Manager.
#
# POR QUE ESTE SCRIPT EXISTE
# El valor de un secreto no puede pasar por Terraform: si estuviera en una
# `aws_secretsmanager_secret_version` o en `terraform.tfvars`, quedaria en TEXTO
# PLANO dentro de terraform.tfstate y terraform.tfstate.backup, que son
# archivos en disco. Mover un secreto de "archivo" a "Secrets Manager" mientras
# se lo deja en el estado no cambia nada.
#
# Asi que el Terraform crea solo el "cascarón" del secreto (nombre, ARN, tags,
# resource policy, cifrado) y el VALOR se siembra una sola vez, aqui, fuera de
# banda. Terraform nunca lo ve.
#
# USO
#   ./scripts/migrate-secrets.sh --dry-run      # muestra el plan, no escribe
#   ./scripts/migrate-secrets.sh                 # siembra ambos secretos
#   ./scripts/migrate-secrets.sh --set-llm-key  # rota solo la API key (Step 3)
#   ./scripts/migrate-secrets.sh --cleanup-ssm   # borra los parametros viejos
#
# CREDENCIALES
# Hace falta un rol ADMIN (crear y rotar secretos). El rol de la instancia NO
# sirve: ese solo puede leer los dos secretos, no crearlos.
#
# CAVEAT SOBRE --cleanup-ssm
# Borrar un parametro de SSM NO borra el valor: queda en el historial de
# versiones y se puede recuperar durante ~30 dias. Para revocar de verdad hay
# que rotar el secreto en su origen (OpenAI / Postgres). Ver docs/runbook.md.
#
# EN WINDOWS (Git Bash)
# MSYS2 convierte los argumentos que empiezan con "/" a rutas de Windows, asi
# que /journal-api/OPENAI_API_KEY llegaria a la CLI como una ruta local y
# SSM responderia ParameterNotFound. Exporta esto antes de correr:
#     export MSYS_NO_PATHCONV=1
# En Linux (el nodo EC2) no hace falta.

set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
SSM_PREFIX="${SSM_PREFIX:-/journal-api}"

SECRET_DATABASE="journal-api/credentials/database"
SECRET_LLM="journal-api/credentials/llm"

DB_USER="${DB_USER:-postgres}"
DB_HOST="${DB_HOST:-postgres}"
DB_PORT="${DB_PORT:-5432}"
DB_NAME="${DB_NAME:-career_journal}"

# Se busca un Python que realmente funcione: en Windows, `python3` puede ser el
# alias de la Microsoft Store, que no existe de verdad.
PY=""
for candidate in python3 python; do
  if command -v "${candidate}" >/dev/null 2>&1 \
     && "${candidate}" -c 'import json' >/dev/null 2>&1; then
    PY="${candidate}"
    break
  fi
done
if [ -z "${PY}" ]; then
  echo "ERROR: se necesita python3 (solo stdlib) para codificar el JSON." >&2
  exit 1
fi

DRY_RUN=0
SET_LLM_KEY=0
CLEANUP_SSM=0

usage() {
  sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --set-llm-key) SET_LLM_KEY=1 ;;
    --cleanup-ssm) CLEANUP_SSM=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "ERROR: opcion desconocida: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

# Reporta solo metadatos. El valor del secreto nunca se imprime.
say() { printf '%s\n' "$*"; }
say_secret() {
  say "  $1"
  say "    claves: $2"
  say "    longitudes: $3"
}

json_str() {
  # Devuelve el valor como string JSON (con comillas y escapes).
  printf '%s' "$1" | "$PY" -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))'
}

url_encode() {
  printf '%s' "$1" | "$PY" -c 'import sys, urllib.parse; sys.stdout.write(urllib.parse.quote(sys.stdin.read(), safe=""))'
}

ssm_get() {
  aws ssm get-parameter --name "$1" --region "${REGION}" --with-decryption \
    --query 'Parameter.Value' --output text
}

# Lee una credencial y devuelve su valor.
#
# Primero intenta el parametro de SSM (la fuente original). Si ya se limpio
# con --cleanup-ssm, cae al secreto en Secrets Manager, para que el script
# siga siendo re-ejecutable sin volver a sembrar nada.
cred_value() {
  local ssm_name="$1" secret_id="$2" key="$3"
  local value=""
  value="$(aws ssm get-parameter --name "${ssm_name}" --region "${REGION}" \
             --with-decryption --query 'Parameter.Value' --output text 2>/dev/null || true)"
  if [ -n "${value}" ] && [ "${value}" != "None" ]; then
    printf '%s' "${value}"
    return 0
  fi
  aws secretsmanager get-secret-value --secret-id "${secret_id}" --region "${REGION}" \
    --output json 2>/dev/null \
  | "${PY}" -c 'import json, sys
raw = json.load(sys.stdin).get("SecretString", "")
try:
    data = json.loads(raw)
except ValueError:
    data = {"VALUE": raw}
sys.stdout.write(str(data.get(sys.argv[1], data.get("VALUE", ""))))' "${key}"
}

put_secret() {
  local secret_id="$1" payload="$2"
  if [ "${DRY_RUN}" -eq 1 ]; then
    say "  [dry-run] put-secret-value ${secret_id}"
    return 0
  fi
  if ! aws secretsmanager put-secret-value \
        --secret-id "${secret_id}" --region "${REGION}" \
        --secret-string "${payload}" >/dev/null 2>&1; then
    echo "ERROR: no se pudo escribir el secreto '${secret_id}'." >&2
    echo "       Si el secreto no existe todavia, crealo primero con:" >&2
    echo "         terraform apply -target=aws_secretsmanager_secret.database -target=aws_secretsmanager_secret.llm" >&2
    exit 1
  fi
  say "  [ok] ${secret_id} actualizado"
}

# ---------------------------------------------------------------
# --set-llm-key: rotacion del Step 3. La key nueva entra por stdin
# para que nunca pase por un archivo ni por el historial del shell.
# ---------------------------------------------------------------
if [ "${SET_LLM_KEY}" -eq 1 ]; then
  say "==> Rotacion de OPENAI_API_KEY (valor desde stdin)"

  NEW_KEY="$(cat)"
  if [ -z "${NEW_KEY}" ]; then
    echo "ERROR: la key llego vacia por stdin." >&2
    exit 1
  fi

  LLM_PAYLOAD="{\"OPENAI_API_KEY\":$(json_str "${NEW_KEY}")}"
  say_secret "${SECRET_LLM}" "OPENAI_API_KEY" "OPENAI_API_KEY=${#NEW_KEY} chars"
  put_secret "${SECRET_LLM}" "${LLM_PAYLOAD}"

  say ""
  say "  Ahora redeploy (el pod toma el valor nuevo) y REVOCA la key vieja en el"
  say "  dashboard del proveedor. Recien ahi la rotacion esta completa."
  exit 0
fi

# ---------------------------------------------------------------
# Siembra: SSM Parameter Store -> Secrets Manager
# ---------------------------------------------------------------
say "==> Leyendo credenciales desde SSM Parameter Store (${SSM_PREFIX})"

PGPASS="$(cred_value "${SSM_PREFIX}/POSTGRES_PASSWORD" "${SECRET_DATABASE}" POSTGRES_PASSWORD)"
OPENAI_KEY="$(cred_value "${SSM_PREFIX}/OPENAI_API_KEY" "${SECRET_LLM}" OPENAI_API_KEY)"

# La password cruda se usa para POSTGRES_PASSWORD (el contenedor de Postgres la
# toma literal). Dentro de la URL va URL-encoded: si la password tuviera @ o /,
# la URL quedaria rota. Hoy la password es alfanumerica, asi que el encode es
# un no-op y la URL queda identica a la que hardcodeaba deploy-k8s.sh.
DB_URL="postgresql://${DB_USER}:$(url_encode "${PGPASS}")@${DB_HOST}:${DB_PORT}/${DB_NAME}"

DB_PAYLOAD="{\"POSTGRES_PASSWORD\":$(json_str "${PGPASS}"),\"DATABASE_URL\":$(json_str "${DB_URL}")}"
LLM_PAYLOAD="{\"OPENAI_API_KEY\":$(json_str "${OPENAI_KEY}")}"

say ""
say "==> Destino en Secrets Manager"
say_secret "${SECRET_DATABASE}" "POSTGRES_PASSWORD, DATABASE_URL" \
  "POSTGRES_PASSWORD=${#PGPASS} chars, DATABASE_URL=${#DB_URL} chars"
say_secret "${SECRET_LLM}" "OPENAI_API_KEY" "OPENAI_API_KEY=${#OPENAI_KEY} chars"

say ""
say "==> Escribiendo"
put_secret "${SECRET_DATABASE}" "${DB_PAYLOAD}"
put_secret "${SECRET_LLM}" "${LLM_PAYLOAD}"

# ---------------------------------------------------------------
# --cleanup-ssm: el paso "revocar el secreto viejo"
# ---------------------------------------------------------------
if [ "${CLEANUP_SSM}" -eq 1 ]; then
  say ""
  say "==> Borrando los parametros de SSM viejos"
  if [ "${DRY_RUN}" -eq 1 ]; then
    say "  [dry-run] delete-parameter ${SSM_PREFIX}/POSTGRES_PASSWORD"
    say "  [dry-run] delete-parameter ${SSM_PREFIX}/OPENAI_API_KEY"
  else
    for name in "${SSM_PREFIX}/POSTGRES_PASSWORD" "${SSM_PREFIX}/OPENAI_API_KEY"; do
      aws ssm delete-parameter --name "${name}" --region "${REGION}" >/dev/null 2>&1 \
        && say "  [ok] borrado ${name}" \
        || say "  [warn] no se pudo borrar ${name} (puede que ya no exista)"
    done
    say ""
    say "  OJO: el valor sigue en el historial de versiones de SSM (~30 dias)."
    say "  Para revocar de verdad, rota el secreto en su origen."
  fi
fi

say ""
say "Listo. Verifica con:"
say "  aws secretsmanager describe-secret --secret-id ${SECRET_LLM} --region ${REGION}"
