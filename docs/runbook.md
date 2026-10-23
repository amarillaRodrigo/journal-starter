# Runbook de producción: Journal API en EC2 + k3s

Guía de diagnóstico para el entorno **desplegado** (EC2 + k3s + ECR + GitHub
Actions). Complementa —no reemplaza— el
[troubleshooting de desarrollo local](reference/troubleshooting.md), que cubre
devcontainer, `.env` y tests.

Cada entrada sigue el mismo formato: **síntoma → diagnóstico → causa probable →
fix → confirmación**.

## Antes de empezar

### El puerto 22 está cerrado

La instancia **no acepta SSH**. Todo acceso es por **AWS Systems Manager**:

| Necesidad | Herramienta |
|---|---|
| Shell interactiva | `aws ssm start-session --target "$IID"` |
| Comando puntual / script | `aws ssm send-command --document-name AWS-RunShellScript` |
| Ver el resultado | `aws ssm get-command-invocation` |

No abras el 22 "para probar": el Security Group solo publica 80/443 y así queda.

### Helpers

```bash
# Resolver la instancia por tag (sin hardcodear el ID)
IID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=journal-api-instance" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# Ejecutar un comando en la instancia y traer stdout/stderr
run_on_instance() {
  CID=$(aws ssm send-command --instance-ids "$IID" \
    --document-name AWS-RunShellScript \
    --parameters commands="$1" \
    --query 'Command.CommandId' --output text)
  aws ssm wait command-executed --command-id "$CID" --instance-id "$IID"
  aws ssm get-command-invocation --command-id "$CID" --instance-id "$IID" \
    --query '{out:StandardOutputContent,err:StandardErrorContent}' --output json
}

# Prefijo de todo comando de Kubernetes en la instancia
K="export KUBECONFIG=/etc/rancher/k3s/k3s.yaml;"

run_on_instance "$K kubectl -n journal-api get pods -o wide"
```

`terraform output` da la URL, la IP y los ARNs sin exponer valores sensibles:

```bash
terraform -chdir=terraform output
```

> **No imprimas secretos.** Para verificar un Secret, listá las **claves**, no
> los valores: `kubectl -n journal-api get secret journal-secrets -o jsonpath='{.data}'`
> y decodificá solo si es imprescindible; nunca pegues el valor en un issue o log.

---

## 1. Pipeline rojo en `test`

**Síntoma:** el run falla antes de construir; `build` y `deploy` quedan
`skipped`.

**Diagnóstico:**

```bash
gh run view <run-id> --log-failed
gh run view <run-id> --json jobs --jq '.jobs[] | {name, conclusion}'
```

Buscá en el log el paso exacto: `Lint`, `Initialize application and test
databases`, `Install dependencies` o `Run tests`.

Reproducción local (mismo comando que CI):

```bash
uv sync --locked
uv run ruff check .
uv run pytest -m "not exercise" -v
```

**Causa probable:**

- `ruff` por imports/orden/formato (`style`).
- Dependencia usada en runtime pero no declarada en `pyproject.toml`/`uv.lock`
  (`ModuleNotFoundError` solo en CI).
- Tests que asumen una DB local o estado compartido; CI usa bases
  `career_journal` y `career_journal_test` y `OTEL_SDK_DISABLED=true`.
- `uv sync --locked` falla porque el lock no se actualizó en el commit.

**Fix:** corregí el código o el lock (`uv lock`, `uv sync`), commit y push. No
cambies los nombres de los jobs ni agregues `continue-on-error` para "destrabar".

**Confirmación:** el job `test` en verde y, como consecuencia, `build` ejecutado.

---

## 2. Pipeline rojo en `build`

**Síntoma:** `test` verde y `build` falla en *Configure AWS credentials*,
*Login to Amazon ECR* o *Build and push*.

**Diagnóstico:**

```bash
gh run view <run-id> --log-failed

# ¿El rol existe y confía en este repo/rama?
aws iam get-role --role-name journal-github-actions \
  --query 'Role.AssumeRolePolicyDocument' --output json

# ¿La imagen del commit llegó a ECR?
aws ecr describe-images --repository-name journal-api \
  --image-ids imageTag=$(git rev-parse HEAD) 2>&1
```

**Causa probable:**

- **OIDC:** `Not authorized to perform sts:AssumeRoleWithWebIdentity`. El claim
  `sub` de GitHub incluye IDs inmutables (`repo:owner@id/repo@id:ref:...`); el
  rol debe usar `StringLike` con comodines para `ref:refs/heads/main` y
  `environment:production`. También falla si el job perdió
  `permissions: id-token: write`.
- **ECR:** `denied` al hacer push → falta alguna acción `ecr:*` en la política o
  el repositorio no es `journal-api`.
- **Docker:** el build falla por dependencias (p. ej. `--only-binary=:all:` sin
  wheel para la plataforma), `.dockerignore` que excluye algo necesario o disco
  del runner.
- **Tag:** se intentó construir con un SHA vacío (`GIT_SHA=unknown`) por un
  checkout incompleto.

**Fix:** corregí el workflow/política o el `Dockerfile`; para OIDC verificá el
`sub` real en los logs del paso de credenciales y ajustá el `StringLike` en
`terraform/main.tf` (requiere `terraform apply`, fuera del alcance de un deploy
normal). No agregues llaves estáticas como atajo.

**Confirmación:** `aws ecr describe-images --repository-name journal-api` muestra
el tag `<sha>` con `imagePushedAt` reciente.

---

## 3. Pipeline rojo en `deploy`

**Síntoma:** `build` verde y `deploy` falla. Distinguí **tres** puntos: el
`send-command`, el script dentro de la instancia, o la verificación de
`/version`.

**Diagnóstico:**

```bash
gh run view <run-id> --log-failed

# Últimos comandos SSM y su estado
aws ssm list-commands --max-results 10 \
  --query 'Commands[].[CommandId,Status,Comment,RequestedDateTime]' --output table

# Detalle del comando que falló (reemplazar <cmd-id> e <iid>)
aws ssm get-command-invocation --command-id <cmd-id> --instance-id "$IID" \
  --query '{status:Status,out:StandardOutputContent,err:StandardErrorContent}'
```

Dentro de la instancia, reproducir el tramo final:

```bash
run_on_instance "$K cd /opt/journal-api && git fetch --depth 1 origin main && git reset --hard FETCH_HEAD && sudo bash scripts/deploy-k8s.sh <sha>"
```

**Causa probable:**

| Señal | Causa |
|---|---|
| `InvalidInstanceId` / `InvocationDoesNotExist` | instancia apagada, SSM Agent caído o tag `Name` distinto |
| `AccessDenied` en `ssm:SendCommand` | política del rol OIDC o recurso de instancia incorrecto |
| `AccessDenied` en `secretsmanager:GetSecretValue` | el rol de la instancia no tiene el permiso, o la resource policy del secreto no lo nombra (hacen falta **las dos**) |
| `unknown revision origin/main` | clon shallow sin esa ref; debe usarse `FETCH_HEAD` |
| timeout de 400 s en el job | 40 reintentos × 10 s; el deploy superó ~6,5 min |
| `rollout status` timeout | imagen inexistente, pull de ECR fallido, crash de la app o falta de memoria |
| `/version` no coincide | el pod no se actualizó (mirar siguiente entrada) |

**Fix:** corregí la causa puntual. Si el script falló por un manifiesto o por
SSM, el deploy es idempotente: se puede re-ejecutar el mismo SHA. Si el rollout
quedó a medias, seguí con la entrada 4/5 antes de relanzar.

**Confirmación:** `deploy` verde, SSM `Success` y el paso *Verify the public
endpoint runs the new commit* imprime `OK: Kubernetes está corriendo la imagen
del commit <sha>`.

---

## 4. Deploy verde pero `/version` devuelve otro SHA

**Síntoma:** el run terminó bien, pero
`curl https://3.215.52.10.sslip.io/version` devuelve un commit anterior o
`unknown`.

**Diagnóstico:**

```bash
HEAD=$(git rev-parse HEAD)
curl -fsS https://3.215.52.10.sslip.io/version

run_on_instance "$K kubectl -n journal-api get deploy/journal-api -o jsonpath='{.spec.template.spec.containers[0].image}'"
run_on_instance "$K kubectl -n journal-api get pods -o wide"
run_on_instance "$K kubectl -n journal-api rollout status deployment/journal-api"
run_on_instance "$K kubectl -n journal-api describe pod -l app=journal-api | tail -40"
```

**Causa probable:**

- **Rollout incompleto:** el pod viejo sigue `Running` porque el nuevo no pasa
  readiness (`/version`) o está en `ImagePullBackOff`.
- **Imagen vieja:** el Deployment conserva `:latest` o un tag anterior; el
  `sed` de `deploy-k8s.sh` no sustituyó el placeholder.
- **Caché/proxy:** respuesta cacheada por Caddy o por el cliente; Caddy no cachea
  por defecto, pero un `curl` con caché intermedia puede confundir.
- **Dos fuentes:** se comparó contra un commit local no pusheado (HEAD ≠ el SHA
  que disparó el run).

**Fix:**

```bash
# Forzar el rollout del tag correcto (idempotente)
run_on_instance "$K kubectl -n journal-api set image deploy/journal-api journal-api=<ecr-registry>/journal-api:<sha>"
run_on_instance "$K kubectl -n journal-api rollout status deployment/journal-api --timeout=240s"

# Si el pull falla, renovar el pull secret (lo hace el script en cada deploy)
run_on_instance "$K sudo bash /opt/journal-api/scripts/deploy-k8s.sh <sha>"
```

**Confirmación:** los cuatro valores de la tabla de
[delivery.md §4](delivery.md#4-lo-desplegado-es-el-commit-actual) coinciden:
`git rev-parse HEAD`, el tag en ECR, la imagen del Deployment y `/version`.

---

## 5. Pod en `CrashLoopBackOff` u `OOMKilled`

**Síntoma:** `kubectl get pods` muestra `CrashLoopBackOff`, `Error`,
`OOMKilled` o reinicios crecientes. La instancia es `t3.small` (2 GB, ~1,9 GB
visibles) y `metrics-server` está deshabilitado, así que `kubectl top` **no
existe** en este cluster.

**Diagnóstico:**

```bash
run_on_instance "$K kubectl -n journal-api get pods"
run_on_instance "$K kubectl -n journal-api describe pod <pod> | tail -60"
run_on_instance "$K kubectl -n journal-api logs <pod> --previous --tail=100"
run_on_instance "$K kubectl -n journal-api get events --sort-by=.lastTimestamp | tail -20"

# Presión real del nodo
run_on_instance "free -m; df -h /; dmesg -T | grep -i -E 'oom|killed process' | tail -10"
```

**Causa probable:**

- Límite de memoria del contenedor demasiado bajo (app 320Mi, Postgres 192Mi,
  ADOT 192Mi, Caddy 128Mi) o pico del LLM/librerías.
- Nodo sin memoria: k3s + 5 pods compiten por ~1,9 GB; el kernel mata procesos.
- Imagen nueva que no arranca por configuración (variables faltantes) y el
  contenedor reinicia antes de escuchar en 8000.
- PVC de Postgres sin espacio o corrupción tras un corte.

**Fix:**

- Si es OOM del **pod**: subir el límite (requiere cambio de manifiesto + commit
  + deploy) o reducir carga; si es OOM del **nodo**, liberar memoria
  (ver entrada 11) antes de subir límites.
- Si es un crash de arranque: corregir la variable/secret y relanzar el rollout.
- Si Postgres no arranca por datos: revisar el PVC antes de borrar nada
  (`kubectl -n journal-api describe pvc postgres-data`). **No** borres el PVC
  para "reiniciar": perdés las entradas del journal.

**Confirmación:** el pod queda `1/1 Running` con 0 reinicios durante 10 minutos,
`kubectl -n journal-api rollout status deployment/<nombre>` completa y
`/version` responde 200.

---

## 6. La app devuelve 500 o 503

**Síntoma:** `/version` responde 200 pero `/entries` devuelve 500, o
`POST /entries/{id}/analyze` devuelve 503.

**Diagnóstico:**

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://3.215.52.10.sslip.io/entries
curl -sS -o /dev/null -w '%{http_code}\n' -X POST https://3.215.52.10.sslip.io/entries \
  -H 'Content-Type: application/json' -d '{"title":"t","content":"c"}'

run_on_instance "$K kubectl -n journal-api get pods"
run_on_instance "$K kubectl -n journal-api logs deploy/journal-api --tail=100"
run_on_instance "$K kubectl -n journal-api exec deploy/postgres -- pg_isready -U postgres"
run_on_instance "$K kubectl -n journal-api get secret journal-secrets -o jsonpath='{.data}' | tr ',' '\n' | cut -d: -f1"
run_on_instance "$K kubectl -n journal-api describe pod -l app=postgres | tail -30"
```

En CloudWatch Logs, la query guardada `journal-api/errores-5xx` muestra el
`ERROR: Exception in ASGI application` con el traceback.

**Causa probable:**

- **Postgres caído o sin readiness:** `DATABASE_URL` apunta a `postgres:5432`;
  si el Deployment no está listo, la app devuelve 500 en cada request.
- **Credenciales desincronizadas:** `journal-secrets`/`journal-db` no coinciden
  con `/journal-api/POSTGRES_PASSWORD` (p. ej. alguien rotó SSM sin redeploy).
- **Esquema ausente:** la tabla `entries` no existe porque el paso
  `database_setup.sql` falló y `set -e` cortó el deploy (en ese caso el deploy
  no debería estar verde).
- **Proveedor LLM sin crédito:** `429 insufficient_quota` → la API responde
  **503** solo en `/analyze`; es el comportamiento esperado y está documentado
  en [observability.md](observability.md#limitaciones-conocidas). El resto de la
  API sigue funcionando.

**Fix:**

- Postgres: `kubectl -n journal-api rollout restart deploy/postgres`, esperar
  readiness y reintentar.
- Credenciales: re-ejecutar `sudo bash /opt/journal-api/scripts/deploy-k8s.sh <sha>`
  para recrear ambos Secrets desde SSM.
- Esquema: aplicar `database_setup.sql` con el comando del paso 6 del
  [deploy](delivery.md#orden-exacto-de-scriptsdeploy-k8ssh-sha); es idempotente.
- LLM: cargar crédito o cambiar el proveedor; no es un fallo de la plataforma.
  Mientras tanto, el span `llm.analyze_entry` queda con `fault` y la métrica
  `journal.analysis.duration` se registra igual.

**Confirmación:** `POST /entries` devuelve 201, `GET /entries` devuelve 200 y la
alarma `journal-api-http-5xx` permanece en `OK`.

---

## 7. Caddy sin certificado TLS

**Síntoma:** el navegador/curl falla con error de certificado, `NET::ERR_CERT_*`,
o `curl` devuelve `SSL certificate problem`.

**Diagnóstico:**

```bash
# DNS: sslip.io debe resolver a la Elastic IP
nslookup 3.215.52.10.sslip.io

# Puertos públicos (22 debe estar cerrado; 80/443 abiertos)
curl -sS -o /dev/null -w 'http=%{http_code}\n' http://3.215.52.10.sslip.io/version
curl -sSv https://3.215.52.10.sslip.io/version 2>&1 | tail -25

run_on_instance "$K kubectl -n journal-api get pods -l app=caddy -o wide"
run_on_instance "$K kubectl -n journal-api logs deploy/caddy --tail=120"
run_on_instance "$K kubectl -n journal-api describe pvc caddy-data"
run_on_instance "sudo ss -lntp | grep -E ':80|:443'"
```

**Causa probable:**

- **DNS:** el nombre de `k8s/caddy.yaml` no coincide con la IP (se recreó la
  Elastic IP o se cambió de IP) → sslip.io resuelve a otro host.
- **Puertos:** Security Group sin 80/443, o Caddy no bindea `hostPort` porque
  otro proceso ocupa el puerto.
- **ACME:** Let's Encrypt no puede validar HTTP-01 (puerto 80 cerrado, DNS
  incorrecto) o se agotó el rate limit de certificados.
- **Estado TLS perdido:** el PVC `caddy-data` se borró; Caddy debe emitir de
  nuevo (puede tardar y fallar por rate limit).
- **Caddy reiniciado:** el pod muestra reinicios; revisar memoria.

**Fix:**

- Corregir DNS (si cambió la IP, actualizar el Caddyfile y el `PUBLIC_URL` del
  workflow, y redeploy).
- Abrir 80/443 en el Security Group (Terraform), nunca 22.
- Si el rate limit está agotado, esperar o usar el entorno de *staging* de
  Let's Encrypt en el Caddyfile solo para diagnóstico.
- Recrear `caddy-data` solo si es aceptable reemitir el certificado.

**Confirmación:**

```bash
curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' https://3.215.52.10.sslip.io/version
# 200 0
```

y `kubectl -n journal-api logs deploy/caddy` sin errores de ACME.

---

## 8. Las métricas no aparecen en CloudWatch

**Síntoma:** el namespace `JournalAPI` está vacío o deja de recibir datos; el
dashboard queda en blanco.

**Diagnóstico:**

```bash
aws cloudwatch list-metrics --namespace JournalAPI --region us-east-1

run_on_instance "$K kubectl -n journal-api get pods -l app=adot-collector"
run_on_instance "$K kubectl -n journal-api logs deploy/adot-collector --tail=120"
run_on_instance "$K kubectl -n journal-api exec deploy/adot-collector -- wget -qO- http://localhost:13133/"

# ¿La app apunta al collector?
run_on_instance "$K kubectl -n journal-api get deploy/journal-api -o jsonpath='{.spec.template.spec.containers[0].env}'"

# ¿EMF llegó al log group de métricas? (los documentos EMF son logs)
aws logs tail /aws/journal-api/metrics --since 15m --region us-east-1
```

**Causa probable:**

- **Collector caído:** pod no `Running`, OOM o readiness fallando.
- **Endpoint equivocado:** falta `OTEL_EXPORTER_OTLP_ENDPOINT=http://adot-collector:4318`
  o el Service no resuelve.
- **Permisos IAM:** el instance role no puede `xray:Put*` o
  `cloudwatch:PutMetricData`; la condición exige el namespace `JournalAPI`.
  IMDS hop limit debe ser 2 para que el pod lea el instance profile.
- **Dimensión `OTelLib`:** el exporter la agrega siempre. Si una consulta,
  widget o alarma omite `OTelLib=journal-api`, no matchea ninguna serie.
- **Latencia EMF:** CloudWatch tarda ~1–2 minutos en extraer las métricas; un
  `list-metrics` inmediato después del deploy puede verse vacío.
- **Filtro de métricas:** `http.server.*` se descarta a propósito; solo existen
  las `journal.*`.

**Fix:** reiniciar el collector (`rollout restart deploy/adot-collector`),
corregir el endpoint/IAM, y esperar 2–3 minutos. Si el problema es de consulta,
agregar la dimensión `OTelLib` exacta.

**Confirmación:**

```bash
aws cloudwatch get-metric-statistics --namespace JournalAPI \
  --metric-name journal.http.requests.total \
  --dimensions Name=OTelLib,Value=journal-api Name=status_class,Value=2xx \
  --start-time "$(date -u -d '-15 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 60 --statistics Sum --region us-east-1
```

devuelve datapoints con `Timestamp` de los últimos minutos y `list-metrics`
cuenta 15 series.

---

## 9. Logs ausentes en CloudWatch

**Síntoma:** `/aws/journal-api/application` no recibe streams nuevos, o faltan
los logs de un pod.

**Diagnóstico:**

```bash
aws logs describe-log-streams --log-group-name /aws/journal-api/application \
  --order-by LastEventTime --descending --max-items 5 --region us-east-1

run_on_instance "$K kubectl -n journal-api get pods -l app=fluent-bit -o wide"
run_on_instance "$K kubectl -n journal-api logs ds/fluent-bit --tail=120"
run_on_instance "sudo ls -l /var/log/containers/ | grep journal-api | tail -5"
```

**Causa probable:**

- **Fluent Bit caído** o el DaemonSet no corre en el nodo (tolerations/hostPath).
- **`rewrite_tag`:** solo pasa `kubernetes.namespace_name == journal-api`; un
  pod en otro namespace no se envía (por diseño, para no pagar kube-system).
- **Permisos IAM:** faltan `logs:CreateLogStream` / `logs:PutLogEvents` sobre
  `/aws/journal-api/*`, o `auto_create_group` está en `false` y el grupo no
  existe (lo crea Terraform).
- **Rotación/CRI:** el parser `cri` no matchea el formato del runtime.
- **Retención:** 7 días; eventos más viejos se borran.

**Fix:** reiniciar `ds/fluent-bit`, corregir namespace o IAM, y verificar que el
log group exista (`terraform apply` si se borró).

**Confirmación:**

```bash
aws logs filter-log-events --log-group-name /aws/journal-api/application \
  --start-time $(( $(date +%s) * 1000 - 600000 )) --region us-east-1 \
  --query 'events[-5:].[timestamp,message]' --output text
```

muestra eventos recientes con `kubernetes.pod_name` del namespace `journal-api`.

---

## 10. Una alarma no dispara

**Síntoma:** hay errores o latencia alta, pero `journal-api-http-5xx` /
`journal-api-latency-p95` siguen en `OK` y no llega email.

**Diagnóstico:**

```bash
aws cloudwatch describe-alarms --alarm-name-prefix journal-api --region us-east-1 \
  --query 'MetricAlarms[].[AlarmName,StateValue,StateReason,Threshold,EvaluationPeriods]' --output table

aws cloudwatch describe-alarm-history --alarm-name journal-api-http-5xx \
  --history-item-type StateUpdate --max-items 10 --region us-east-1

# ¿La métrica existe con EXACTAMENTE las dimensiones de la alarma?
aws cloudwatch get-metric-statistics --namespace JournalAPI \
  --metric-name journal.http.requests.total \
  --dimensions Name=OTelLib,Value=journal-api Name=status_class,Value=5xx \
  --start-time "$(date -u -d '-30 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 60 --statistics Sum --region us-east-1

# Suscripción SNS
aws sns list-subscriptions-by-topic \
  --topic-arn "$(terraform -chdir=terraform output -raw sns_alarms_topic_arn)" \
  --region us-east-1
```

**Causa probable:**

- **Dimensiones incompletas:** la alarma declara `{OTelLib, status_class}`; si
  falta `OTelLib=journal-api`, no hay serie que evaluar.
- **`treat_missing_data = notBreaching`:** sin datos la alarma queda `OK`, no
  `INSUFFICIENT_DATA`; un collector caído se ve como "todo bien".
- **Umbral/evaluación:** 5xx exige >5 en 1 minuto; p95 exige 3 periodos
  consecutivos >2000 ms.
- **SNS:** suscripción en `PendingConfirmation` (hoy está confirmada) o email en
  spam; `alarm_actions`/`ok_actions` vacíos.

**Fix:** corregir dimensiones en `terraform/monitoring.tf` (requiere apply),
bajar el umbral si el tráfico es bajo, o hacer una prueba controlada: escalar
Postgres a 0 y generar tráfico, como en
[observability.md §5.11](observability.md#511-prueba-end-to-end-de-la-alarma).
Recordá restaurar `--replicas=1`.

**Confirmación:** `describe-alarm-history` muestra la secuencia
`OK → ALARM → OK`, la métrica `5xx` tiene datapoints por encima del umbral y el
email llega a la casilla suscripta (1 confirmed / 0 pending).

---

## 11. Disco lleno

**Síntoma:** pods en `Evicted`, `ImagePullBackOff`, Postgres no puede escribir,
`no space left on device`, o el disco raíz supera ~85 %.

**Diagnóstico:**

```bash
run_on_instance "df -h /; sudo du -xh --max-depth=1 /var/lib/rancher /var/log /opt 2>/dev/null | sort -h | tail -15"
run_on_instance "$K kubectl -n journal-api get pods"
run_on_instance "$K kubectl -n journal-api get events --sort-by=.lastTimestamp | tail -20"
run_on_instance "sudo k3s crictl images | head -20"
run_on_instance "sudo k3s crictl info | head -40"
```

**Causa probable:**

- Imágenes viejas en containerd: cada deploy baja una imagen nueva y el nodo de
  8 GB acumula capas.
- Logs del sistema/`journald` sin rotación.
- PVCs (`postgres-data` 1Gi, `caddy-data` 256Mi) y snapshots locales de k3s.
- Restos de la verificación con Aspire Dashboard (Deployment eliminado, imagen
  todavía en containerd).

**Fix (en este orden, sin borrar datos):**

```bash
# 1. Podar imágenes no usadas por ningún contenedor
run_on_instance "sudo k3s crictl rmi --prune"

# 2. Liberar logs del sistema y del journal
run_on_instance "sudo journalctl --vacuum-size=100M; sudo find /var/log -type f -name '*.gz' -delete"

# 3. Revisar el lifecycle de ECR (conserva 15 imágenes)
aws ecr describe-lifecycle-policy --repository-name journal-api --region us-east-1

# 4. Si el PVC de Postgres es el que llenó el disco, ampliar el volumen/EBS
#    (requiere cambio de infraestructura, no se hace en caliente desde el runbook)
```

**Confirmación:** `df -h /` por debajo de ~70 %, los pods vuelven a `Running`,
no hay nuevos `Evicted` y `kubectl -n journal-api exec deploy/postgres --
pg_isready -U postgres` responde `accepting connections`.

> El lifecycle de ECR limita el registry, **no** el disco de la instancia. La
> poda de containerd es la que libera espacio local.

---

## 12. Rotar un secreto

**Síntoma:** hay que cambiar la API key de OpenAI o la password de Postgres.

**Diagnóstico:** las credenciales viven en AWS Secrets Manager. Las versiones
están en el secreto, no en el repo:

```bash
aws secretsmanager describe-secret --secret-id journal-api/credentials/llm \
  --region us-east-1 --query '{versions:VersionIdsToStages,deleted:DeletedDate}'

# Y qué versión está sirviendo el Secret de Kubernetes (sin imprimir valores)
aws ssm send-command --instance-ids "$IID" --document-name AWS-RunShellScript \
  --parameters 'commands=["kubectl -n journal-api get secret journal-secrets -o jsonpath=\"{.metadata.annotations}\""]'
```

**Causa habitual:** no es un fallo técnico, es de **orden**. Mover un secreto a
Secrets Manager **no revoca el valor anterior**: la key vieja sigue siendo
válida hasta que se revoque en su origen.

**Fix (rotación de la API key de OpenAI):**

```bash
# 1. Generar una key nueva en el dashboard de OpenAI.

# 2. Escribirla en Secrets Manager SIN que pase por el repo, por un archivo
#    ni por un canal de chat. El script la lee de stdin.
printf '%s' "$NUEVA_KEY" | ./scripts/migrate-secrets.sh --set-llm-key

# 3. Redeploy para que el pod tome el valor nuevo.
gh workflow run ci.yml --ref main

# 4. Verificar que la API responde con la key nueva.

# 5. REVOCAR la key vieja en el dashboard de OpenAI.
#    Recién ahí la rotación está completa.
```

**Fix (rotación de la password de Postgres):**

```bash
# 1. Generar una password nueva.

# 2. Cambiarla en la base de datos. Va PRIMERO, antes de tocar el Secret.
#    La password no debe llevar comillas simples (rompe el quoting del comando).
read -rsp "Nueva password: " NEWPW; echo
run_on_instance "$K kubectl -n journal-api exec deploy/postgres -- psql -U postgres -d career_journal -c \"ALTER USER postgres WITH PASSWORD '$NEWPW'\""

# 3. Actualizar el secreto. POSTGRES_PASSWORD y DATABASE_URL van juntos:
#    el script vuelve a armar la URL a partir de la password.
./scripts/migrate-secrets.sh

# 4. Redeploy y verificar.
gh workflow run ci.yml --ref main
```

> ⚠️ Si se cambia la password **solo** en el Secret y no en Postgres, la app
> deja de poder conectarse al arrancar. Y al revés: si se cambia **solo** en
> Postgres, el Secret queda desincronizado. El orden correcto es a → b → c.

**Caveat sobre borrar los parámetros viejos de SSM:**

```bash
./scripts/migrate-secrets.sh --cleanup-ssm
```

Borra `/journal-api/OPENAI_API_KEY` y `/journal-api/POSTGRES_PASSWORD`, pero el
valor **queda en el historial de versiones de SSM** y se puede recuperar durante
~30 días. Borrar el parámetro no es revocar: para revocar hay que rotar en el
origen.

**Confirmación:** el secreto tiene una versión nueva, el pod corre con ella
(comparando el hash del Secret de k8s con el del secreto) y la credencial
anterior ya no funciona.

---

## Referencias

- [delivery.md](delivery.md): cadena de entrega y verificación commit ↔ imagen ↔ `/version`.
- [deployment-ec2.md](deployment-ec2.md): arquitectura, secretos, deploy manual y Terraform.
- [observability.md](observability.md): pipeline de telemetría, alarmas y prueba end-to-end.
- [Troubleshooting de desarrollo local](reference/troubleshooting.md): devcontainer, `.env` y tests.
