# Delivery setup: de la imagen al endpoint

Revisión del **paso 7 (Review Your Delivery Setup)**: demostrar que la imagen
Docker, la infraestructura de Terraform, los manifiestos de Kubernetes y el
pipeline de GitHub Actions funcionan **juntos**, y que el commit desplegado se
puede verificar de punta a punta.

Este documento responde cuatro preguntas:

1. ¿Qué hace el pipeline desde un push a `main` hasta que la API responde?
2. ¿Qué archivo del repo produce cada artefacto y qué recurso de AWS queda?
3. ¿Cómo se comprueba, con comandos, que lo desplegado es el commit actual?
4. ¿Cómo llega una credencial desde el dashboard del proveedor hasta el proceso
   que la usa, sin que pase por un archivo ni por el estado de Terraform?

La operación diaria y los fallos típicos están en [runbook.md](runbook.md); la
arquitectura y los secretos en [deployment-ec2.md](deployment-ec2.md); la
telemetría en [observability.md](observability.md).

## 1. Cadena de entrega

```text
  git push origin main
          │
          ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ GitHub Actions · .github/workflows/ci.yml                     │
  │                                                              │
  │  job test     ruff check + pytest (Postgres 16 de servicio)  │
  │       │        OTEL_SDK_DISABLED=true                        │
  │       ▼ needs: test                                          │
  │  job build    docker build --build-arg GIT_SHA=<sha>         │
  │       │       docker push ECR :<sha> y :latest               │
  │       ▼ needs: build                                         │
  │  job deploy   resolve URL pública desde la instancia         │
  │       │       aws ssm send-command (AWS-RunShellScript)      │
  │       │         cd /opt/journal-api                          │
  │       │         git fetch --depth 1 origin main              │
  │       │         git reset --hard FETCH_HEAD                  │
  │       │         bash scripts/deploy-k8s.sh <sha>             │
  │       │       wait rollout + curl /version == <sha>          │
  └───────┼──────────────────────────────────────────────────────┘
          │ SSM (sin puerto 22, sin llaves SSH)
          ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ EC2 t3.small · k3s · namespace journal-api                    │
  │  namespace → ADOT + Fluent Bit → Secrets Manager → Secret k8s│
  │  Postgres/Service/Caddy → schema → journal-api:<sha>         │
  │  rollout status deployment/journal-api                        │
  └───────┬──────────────────────────────────────────────────────┘
          │ HTTPS 443
          ▼
  https://3.215.52.10.sslip.io/version → {"commit":"<sha>"}
```

### Detalle por etapa

| # | Etapa | Disparador | Comando / archivo | Resultado verificable |
|---|---|---|---|---|
| 1 | `test` | push o PR a `main` | `uv run ruff check .` + `uv run pytest -m "not exercise"` con Postgres 16 como service container | el job falla antes de construir si el código o los tests están rotos |
| 2 | `build` | push a `main` (o `workflow_dispatch`), `needs: test` | `docker/build-push-action` con `build-args: GIT_SHA=${{ github.sha }}` | imagen en ECR con tag `<sha>` y `latest` |
| 3 | `deploy` | `needs: build`, `environment: production` | `aws ec2 describe-instances` (URL pública) + `aws ssm send-command` → `git fetch --depth 1 origin main` → `git reset --hard FETCH_HEAD` → `bash scripts/deploy-k8s.sh <sha>` | SSM `Success` + rollout completo |
| 4 | verificación | último paso de `deploy` | `curl -fsS $PUBLIC_URL/version` en un loop de 20 intentos | `commit` == `github.sha`; si no, el job falla |

> **Nota sobre `origin/main`:** el workflow usa `git reset --hard FETCH_HEAD`
> porque el clon de la instancia es *shallow* (`--depth 1`) y no tiene la ref
> `origin/main` completa. Es el mismo commit que `origin/main` en el momento del
> deploy; el cambio se hizo en `6c9001b` justamente para evitar el fallo
> `unknown revision origin/main` en el job `deploy`.

> **Nota sobre la URL pública:** la Elastic IP la asigna Terraform (`aws_eip`)
> y **cambia en cada `destroy`/`apply`**. Por eso el job `deploy` la resuelve
> desde la instancia (`ec2:DescribeInstances`, permiso que el rol de OIDC ya
> tenía) en vez de hardcodearla. La variable de repo `PUBLIC_URL` solo se usa
> para el link cosmético del deployment en GitHub.

### Autenticación sin secretos estáticos

`build` y `deploy` piden `id-token: write` y asumen el rol de GitHub Actions por
**OIDC** (`aws-actions/configure-aws-credentials`). Los permisos del rol son
mínimos:

| Acción | Recurso | Para qué |
|---|---|---|
| `ecr:GetAuthorizationToken` + push de capas/imagen | repositorio `journal-api` | publicar la imagen del commit |
| `ec2:DescribeInstances` | instancias | resolver la instancia por tag `Name=journal-api-instance` y su IP (sin hardcodear ninguno de los dos) |
| `ssm:SendCommand` | instancia + documento `AWS-RunShellScript` | ejecutar el deploy |
| `ssm:GetCommandInvocation` / `List*` | — | leer estado y salida del comando |

No hay `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` en el repo ni en GitHub
Secrets. La única condición de confianza es el repositorio, la rama `main` y el
environment `production`.

## 2. Mapa artefacto → archivo → recurso en AWS

| Artefacto | Archivo(s) en el repo | Recurso / efecto en AWS |
|---|---|---|
| Imagen de la API | `Dockerfile`, `.dockerignore` | repositorio ECR `journal-api`; tag = commit SHA (y `latest`); lifecycle: conserva 15 imágenes |
| Infraestructura base | `terraform/main.tf` | VPC `10.0.0.0/16`, subnet pública, IGW, route table, Security Group 80/443 (sin 22), IAM de instancia (`journal-ssm-role` + `journal-ssm-profile`), OIDC provider de GitHub + rol `journal-github-actions`, repositorio ECR, instancia `t3.small` con `user_data` (swap + k3s + primer deploy), Elastic IP, **volumen raíz 20 GB gp3 cifrado** |
| Observabilidad como código | `terraform/monitoring.tf` | topic SNS `journal-api-alarms`, suscripción email (valor en `terraform.tfvars`, gitignored), log groups `/aws/journal-api/application` y `/aws/journal-api/metrics`, política IAM de X-Ray/CloudWatch Logs/PutMetricData, dashboard `journal-api`, alarmas `journal-api-http-5xx` y `journal-api-latency-p95`, 2 query definitions |
| Secretos (cascarón) | `terraform/secrets.tf` | secretos `journal-api/credentials/database` y `journal-api/credentials/llm` + sus resource policies; IAM con `GetSecretValue` acotado a esos dos ARN |
| Configuración no sensible | `terraform/main.tf` | parámetros SSM `/journal-api/OPENAI_BASE_URL`, `/journal-api/OPENAI_MODEL`, `/journal-api/ACME_EMAIL` (tipo `String`) |
| Namespace | `k8s/namespace.yaml` | namespace `journal-api` |
| Telemetría | `k8s/adot-collector.yaml` | ConfigMap `adot-collector-config`, Deployment `adot-collector`, Service ClusterIP `adot-collector:4318` |
| Logs | `k8s/fluent-bit.yaml` | ServiceAccount + ClusterRole/Binding, ConfigMap `fluent-bit-config`, DaemonSet `fluent-bit` |
| Base de datos | `k8s/postgresql.yaml` | PVC `postgres-data` (1Gi), Service `postgres:5432`, Deployment `postgres` |
| Entrada HTTP | `k8s/caddy.yaml` | ConfigMap `caddy-config` (hostname y email ACME resueltos en deploy time), PVC `caddy-data` (TLS), Deployment `caddy` con hostPort 80/443 |
| Servicio interno de la API | `k8s/service.yaml` | Service ClusterIP `journal-api-service:8000` (consumido por Caddy) |
| Aplicación | `k8s/deployment.yaml` | Deployment `journal-api` (1 réplica, `strategy: Recreate`), probes en `/version`, límites 320Mi/700m |
| Secretos (siembra) | `scripts/migrate-secrets.sh` | mueve el valor de SSM Parameter Store a Secrets Manager **fuera de banda**; también rota (`--set-llm-key`) y limpia los parámetros viejos (`--cleanup-ssm`) |
| Secretos (consumo) | `scripts/deploy-k8s.sh` | Secrets de Kubernetes (`journal-secrets`, `journal-db`) y pull secret de ECR (`ecr-credential`) creados en el deploy desde Secrets Manager; el `secret.yaml` real está gitignored y no se aplica |
| Pipeline | `.github/workflows/ci.yml` | jobs `test` → `build` → `deploy`, OIDC, push a ECR y SSM Run Command |

> `k8s/deployment-eks.yaml`, `k8s/aspire-dashboard.yaml` y `eks-cluster.yaml` no
> forman parte del delivery de producción: el primero es una variante EKS, el
> segundo se usó solo para verificar la instrumentación localmente y
> `deploy-k8s.sh` no los aplica.

### Orden exacto de `scripts/deploy-k8s.sh <sha>`

El script es la única fuente de verdad del orden de aplicación. Con
`set -euo pipefail`, cualquier paso falla el job `deploy` completo.

| Paso | Acción | Recurso |
|---|---|---|
| 0 | `sudo k3s crictl rmi --prune` + `df -h /` | poda de imágenes sin uso: containerd guarda una imagen por commit (el tag es el SHA) y sin esto el nodo llega a `DiskPressure` |
| 1 | `kubectl apply -f k8s/namespace.yaml` | namespace `journal-api` |
| 2 | `kubectl apply -f k8s/adot-collector.yaml -f k8s/fluent-bit.yaml` + `rollout status` de ambos | ADOT Collector y Fluent Bit listos **antes** de la app (para no perder la primera telemetría) |
| 3 | lee `journal-api/credentials/database` y `journal-api/credentials/llm` de Secrets Manager, y `/journal-api/{OPENAI_BASE_URL,OPENAI_MODEL,ACME_EMAIL}` de SSM | credenciales con `GetSecretValue`; config con `GetParameter` |
| 4 | crea/actualiza `journal-db`, `journal-secrets` y `ecr-credential` con `--dry-run=client -o yaml \| kubectl apply -f -` | Secrets idempotentes |
| 5 | `sed` de `__PUBLIC_IP__` y `__ACME_EMAIL__` en `k8s/caddy.yaml` + `kubectl apply` de `postgresql.yaml`, `service.yaml` y `caddy.yaml` + espera Postgres | la IP la resuelve el nodo por IMDSv2 y el email viene de SSM: ninguno de los dos está hardcodeado |
| 6 | `kubectl exec -i deploy/postgres -- psql ... < database_setup.sql` | esquema idempotente en cada deploy |
| 7 | `sed s|journal-api:placeholder|journal-api:<sha>|` + `kubectl apply` + `rollout status deployment/journal-api` | imagen exacta del commit, con timeout de 240 s |

El `user_data` de Terraform ejecuta este mismo script en el primer arranque,
usando `git rev-parse HEAD` como tag y cayendo a `latest` si ese tag todavía no
existe en ECR.

## 3. Ciclo de vida de los secretos

Esta es la parte del delivery que **no** es obvia: una credencial del proveedor
tiene que llegar al proceso que la usa sin pasar por un archivo del repo, por
el estado de Terraform ni por un log.

### Dónde vive cada cosa

| Dato | Dónde | Por qué |
|---|---|---|
| `POSTGRES_PASSWORD`, `DATABASE_URL`, `OPENAI_API_KEY` | **Secrets Manager** | son credenciales: cifradas, versionadas, auditadas |
| `OPENAI_BASE_URL`, `OPENAI_MODEL`, `ACME_EMAIL` | **SSM Parameter Store** (`String`) | no son secretos: son configuración pública y no tienen por qué pagar el coste de un secreto |

### Por qué el valor no pasa por Terraform

`terraform/secrets.tf` crea **solo el "cascarón"** del secreto: nombre, ARN,
tags, resource policy y cifrado. **Nunca** el valor.

Si el valor estuviera en una `aws_secretsmanager_secret_version` o en
`terraform.tfvars`, quedaría en **texto plano dentro de `terraform.tfstate`** y
de `terraform.tfstate.backup`, que son archivos en disco. Mover un secreto de
"archivo" a Secrets Manager mientras se lo deja en el estado no cambia nada.

Por eso la siembra es **fuera de banda**, con un script que corre una sola vez:

```bash
./scripts/migrate-secrets.sh            # SSM Parameter Store → Secrets Manager
./scripts/migrate-secrets.sh --dry-run  # muestra el plan sin escribir
```

### Quién puede leerlos (IAM mínimo + negaciones explícitas)

El rol `journal-ssm-role` (instance profile de la EC2) tiene:

| Statement | Efecto |
|---|---|
| **Allow** `secretsmanager:GetSecretValue` y `DescribeSecret` | solo sobre los **dos ARN exactos** de los secretos del proyecto |
| **Deny** `GetSecretValue`, `DescribeSecret`, `PutSecretValue`, `UpdateSecret`, `DeleteSecret`, `ListSecrets` sobre cualquier otro secreto | un Deny explícito gana sobre cualquier Allow: aunque mañana se adjuntara una política amplia al rol, el acceso sigue acotado |
| **Deny** `ssm:GetParameter*` sobre cualquier parámetro fuera de los tres de configuración | `AmazonSSMManagedInstanceCore` concede `ssm:GetParameters` sobre `*`; el Deny lo recorta |

Además cada secreto tiene una **resource policy** que nombra al rol. **Las dos
políticas deben permitir la acción**: AWS evalúa la intersección de la identity
policy y la resource policy.

### Rotación

Mover un secreto a Secrets Manager **no revoca** el valor anterior: hay que
rotarlo en su origen. El procedimiento está en
[runbook.md](runbook.md#12-rotar-un-secreto). En resumen:

```bash
# la key nueva entra por stdin: no pasa por un archivo ni por el historial
printf '%s' "$NUEVA_KEY" | ./scripts/migrate-secrets.sh --set-llm-key
gh workflow run ci.yml --ref main
# y recién después se revoca la vieja en el dashboard del proveedor
```

## 4. Verificación end-to-end

Los comandos de instancia van **siempre por SSM**: el puerto 22 está cerrado y
no hay llaves SSH en el flujo.

```bash
# Helper: resolver la instancia por tag (no hardcodear el ID)
IID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=journal-api-instance" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)

# Helper: ejecutar un comando de solo lectura en la instancia y ver la salida
run_on_instance() {
  CID=$(aws ssm send-command --instance-ids "$IID" \
    --document-name AWS-RunShellScript \
    --parameters commands="$1" \
    --query 'Command.CommandId' --output text)
  aws ssm wait command-executed --command-id "$CID" --instance-id "$IID"
  aws ssm get-command-invocation --command-id "$CID" --instance-id "$IID" \
    --query StandardOutputContent --output text
}
```

| # | Qué se verifica | Comando exacto | Resultado esperado | Observado (2026-10-23) |
|---|---|---|---|---|
| 1 | Terraform aplicado y sin drift | `cd terraform && terraform output` | `api_url`, `public_ip`, `ecr_image`, ARNs de alarmas y topic | `api_url = https://3.215.52.10.sslip.io` |
| 2 | Imagen del commit en ECR | `aws ecr describe-images --repository-name journal-api --query 'sort_by(imageDetails,&imagePushedAt)[-1].[imageTags,imagePushedAt]' --output json` | el tag contiene el SHA de `HEAD` | `["57f60ee...","latest"]`, push 12:15 UTC |
| 3 | Cluster sano | `run_on_instance 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n journal-api get pods -o wide'` | 5 pods `Running` (`journal-api`, `postgres`, `caddy`, `adot-collector`, `fluent-bit`) | 5/5 `Running`, 0 reinicios |
| 4 | La API corre ese SHA | `curl -fsS https://3.215.52.10.sslip.io/version` | `{"commit":"<sha de HEAD>"}` | `{"commit":"57f60eed0cc650b7ab41d98f99f3f04748bbfc78"}` |
| 5 | La imagen desplegada es la del tag | `run_on_instance '... kubectl -n journal-api get deploy/journal-api -o jsonpath="{.spec.template.spec.containers[0].image}"'` | `.../journal-api:<sha de HEAD>` | `...journal-api:57f60ee...` |
| 6 | Alarmas activas | `aws cloudwatch describe-alarms --alarm-name-prefix journal-api --query 'MetricAlarms[].[AlarmName,StateValue]' --output table` | 2 alarmas en `OK` (o `ALARM` si hay incidente real) | `journal-api-http-5xx OK`, `journal-api-latency-p95 OK` |
| 7 | Notificación SNS operativa | `aws sns list-subscriptions-by-topic --topic-arn "$(terraform -chdir=terraform output -raw sns_alarms_topic_arn)" --query 'Subscriptions[].[Protocol,SubscriptionArn]' --output table` | `email` con ARN real, no `PendingConfirmation` | 1 suscripción confirmada |
| 8 | HTTPS válido | `curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' https://3.215.52.10.sslip.io/version` | `200 0` | `200 0` (cert de Let's Encrypt para `3.215.52.10.sslip.io`) |
| 9 | Los secretos están en Secrets Manager | `aws secretsmanager list-secrets --region us-east-1 --query 'SecretList[].[Name,RotationEnabled]' --output table` | los 2 secretos del proyecto | `journal-api/credentials/database`, `journal-api/credentials/llm` |
| 10 | El valor del secreto llega **idéntico** al pod | comparar el `sha256` del Secret de k8s con el del secreto (comandos en la sección 5) | mismo hash | `bb09fe69365cfb8d…` en ambos |
| 11 | El IAM no deja leer de más | `run_on_instance 'aws secretsmanager list-secrets --region us-east-1'` | `AccessDenied` | `AccessDeniedException ... with an explicit deny` (igual para un secreto fuera de scope y para el parámetro SSM viejo) |
| 12 | El valor **nunca** estuvo en el estado | buscar el valor en `terraform.tfstate` y `.backup` | ausente | ausente en ambos, y en todo archivo versionado del repo |
| 13 | El análisis con el proveedor real | `curl -sS -X POST "https://3.215.52.10.sslip.io/entries/<id>/analyze"` | `200` con `sentiment`, `summary` y `topics` | `200` en 2,48 s, con la salida de `gpt-4o-mini` |
| 14 | La telemetría del análisis se registra | `aws cloudwatch get-metric-statistics --namespace JournalAPI --metric-name journal.analysis.duration --dimensions Name=llm_model,Value=gpt-4o-mini Name=OTelLib,Value=journal-api ...` | datapoints en los últimos minutos | 10 muestras en el bucket de 15:16 UTC, max 1922 ms |
| 15 | Disco con margen | `run_on_instance 'df -h /'` | por debajo del 85 % | 20 GB, 6,8 GB usados (34 %) |

### Hash: el valor llega intacto al pod

```bash
# En la instancia: hash de lo que el Secret de k8s le entrega al pod
K=$(kubectl -n journal-api get secret journal-secrets \
      -o jsonpath='{.data.OPENAI_API_KEY}' | base64 -d | sha256sum | cut -d' ' -f1)

# Hash del valor guardado en Secrets Manager
S=$(aws secretsmanager get-secret-value \
      --secret-id journal-api/credentials/llm --region us-east-1 --output json \
    | python3 -c "import json,sys; print(json.loads(json.load(sys.stdin)['SecretString'])['OPENAI_API_KEY'])" \
    | sha256sum | cut -d' ' -f1)

[ "$K" = "$S" ] && echo "MATCH: el pod consume exactamente el valor de Secrets Manager" \
                || echo "DIVERGENCIA: k8s=$K secrets=$S"
```

Comparar **hashes** y no valores es lo que permite verificar la cadena completa
sin exponer la credencial ni una sola vez en un log.

## 5. ¿Lo desplegado es el commit actual?

La trazabilidad se apoya en cuatro valores que deben coincidir **exactamente**:

| Fuente | Comando | Verificado el 2026-10-23 (commit `57f60ee`) |
|---|---|---|
| Commit local | `git rev-parse HEAD` | `57f60eed0cc650b7ab41d98f99f3f04748bbfc78` |
| Tag de la imagen en ECR | `aws ecr describe-images --repository-name journal-api --image-ids imageTag=$(git rev-parse HEAD) --query 'imageDetails[0].imageTags' --output json` | `["57f60ee...","latest"]` |
| Tag que corre Kubernetes | `run_on_instance '... kubectl -n journal-api get deploy/journal-api -o jsonpath="{.spec.template.spec.containers[0].image}"'` | `.../journal-api:57f60ee...` |
| SHA que responde la app | `curl -fsS https://3.215.52.10.sslip.io/version` | `{"commit":"57f60ee..."}` |

Comparación en un solo paso:

```bash
HEAD=$(git rev-parse HEAD)
LIVE=$(curl -fsS https://3.215.52.10.sslip.io/version | python -c "import json,sys; print(json.load(sys.stdin)['commit'])")
[ "$HEAD" = "$LIVE" ] && echo "OK: producción corre $HEAD" || echo "DRIFT: HEAD=$HEAD live=$LIVE"
```

Por qué funciona:

- El job `build` hornea el SHA en la imagen con `--build-arg GIT_SHA=<sha>`; el
  `Dockerfile` lo guarda en `ENV GIT_SHA` y `GET /version` lo devuelve
  (`api/main.py`). No se lee de git en runtime: el contenedor no tiene `.git`.
- El job `deploy` reemplaza `journal-api:placeholder` por
  `journal-api:<sha>` y espera `rollout status`, así que el pod nuevo solo queda
  `Ready` si `/version` responde.
- `imagePullPolicy: IfNotPresent` es seguro porque cada commit tiene un tag
  propio e inmutable en la práctica; `latest` solo se usa para el primer
  arranque o para un rollback manual.

Si los cuatro valores no coinciden, el diagnóstico está en
[runbook.md](runbook.md#4-deploy-verde-pero-version-devuelve-otro-sha).

## 6. Runs de CI verificados

| Fecha (UTC) | Commit | Run ID | `test` | `build` | `deploy` | Nota |
|---|---|---|---|---|---|---|
| 2026-10-23 15:13 | `57f60ee` | [39976466154](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39976466154) | ✅ | ✅ | ✅ | docs del runbook |
| 2026-10-23 15:06 | `0334382` | [39975355584](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39975355584) | ✅ | ✅ | ✅ | redeploy tras rotar la credencial |
| 2026-10-23 14:47 | `0334382` | [39972651199](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39972651199) | ✅ | ✅ | ✅ | docs |
| 2026-10-23 14:45 | `25a33e3` | [39972396525](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39972396525) | ✅ | ✅ | ✅ | primer deploy con el disco de 20 GB y la poda de imágenes |
| 2026-10-23 14:25 | `bbb690a` | [39969565199](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39969565199) | ✅ | ✅ | ❌ | `DiskPressure`: 28 pods evictados (ver más abajo) |
| 2026-10-23 14:24 | `4462ede` | [39969414170](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39969414170) | ✅ | ✅ | ✅ | primer deploy **después** de borrar los parámetros SSM viejos |
| 2026-10-23 14:20 | `ddf79dc` | [39968798184](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39968798184) | ✅ | ✅ | ✅ | hostname y email ACME resueltos en deploy time |
| 2026-10-23 14:12 | `34572aa` | [39967596214](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39967596214) | ✅ | ✅ | ❌ | `tlsv1 alert internal error`: Caddy pedía el certificado de la IP vieja |
| 2026-10-22 17:38 | `2cfbc50` | [39824519576](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39824519576) | ✅ | ✅ | ✅ | delivery original |
| 2026-10-22 17:24 | `e88dd8f` | [39822443046](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39822443046) | ✅ | ✅ | ✅ | |
| 2026-10-22 16:56 | `11e519e` | [39818333716](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39818333716) | ✅ | ✅ | ✅ | |
| 2026-10-22 15:47 | `6c9001b` | [39808118539](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39808118539) | ✅ | ✅ | ✅ | |
| 2026-10-22 15:43 | `f37087b` | [39807526706](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39807526706) | ✅ | ✅ | ❌ | clon shallow sin `origin/main` |

Los tres runs en rojo se conservan porque **documentan los fallos reales del
pipeline y su corrección**, que es la parte que un reviewer de un capstone
quiere ver:

| Run | Síntoma | Causa | Corrección |
|---|---|---|---|
| `39807526706` | `unknown revision origin/main` | clon *shallow* sin la ref completa | `git reset --hard FETCH_HEAD` (`6c9001b`) |
| `39967596214` | `tlsv1 alert internal error` | Caddy tenía la IP vieja hardcodeada en `k8s/caddy.yaml` y pedía el certificado de una IP que ya no era suya; además `admin@example.com` es rechazado por Let's Encrypt | placeholders `__PUBLIC_IP__` / `__ACME_EMAIL__` resueltos en deploy time (`ddf79dc`) |
| `39969565199` | `error: timed out waiting for the condition` y endpoint en `502` | `DiskPressure`: el kubelet evictó 28 pods porque el volumen raíz de 8 GB se llenó con una imagen por commit | volumen raíz de 20 GB + poda de imágenes en cada deploy (`25a33e3`) |

> El síntoma del último es el más engañoso de los tres: el deploy "aplicaba
> bien", el pod nuevo no quedaba `Ready` y el endpoint daba `502`, lo que
> parece un problema de imagen o de aplicación. La causa estaba tres capas más
> abajo, en el estado del nodo. Ver
> [runbook.md](runbook.md#11-disco-lleno).

> **Contrato del pipeline:** los jobs se llaman exactamente `test`, `build` y
> `deploy`. Esos nombres son parte del contrato (badges, branch protection,
> `environment: production` y la lectura del run); no se renombran aunque cambie
> la implementación interna.

## 7. Reproducir el delivery sin esperar un push

```bash
# 1. Re-ejecutar el pipeline completo sobre main (mismos jobs y mismas reglas)
gh workflow run ci.yml --ref main
gh run list --workflow ci.yml --limit 1

# 2. Reconstruir la imagen localmente con el SHA actual y comprobar /version
docker build --build-arg GIT_SHA=$(git rev-parse HEAD) -t journal-api:local .
docker run --rm -p 8000:8000 --env-file .env journal-api:local
curl -fsS http://localhost:8000/version

# 3. Reintentar el deploy del mismo commit (idempotente)
IID=$(aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=journal-api-instance" \
            "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
aws ssm start-session --target "$IID"   # luego: sudo bash /opt/journal-api/scripts/deploy-k8s.sh <sha>
```

El deploy es idempotente: los Secrets se recrean con `apply`, `database_setup.sql`
usa `CREATE TABLE IF NOT EXISTS` y los manifiestos se aplican por nombre.

> ⚠️ **En Windows**, el AWS CLI y `curl.exe` pierden las comillas dobles de un
> JSON pasado como argumento. Para bodies o `--secret-string`, usá un archivo:
> `aws ... --secret-string file://C:/ruta/archivo.json` y
> `curl.exe --data-binary "@archivo.json"`. Es la causa de varios "parece que
> funciona pero no" durante la puesta en marcha.

## 8. Criterios de aceptación del paso 7

| Requisito | Evidencia en este repo |
|---|---|
| Imagen, Terraform, manifiestos y pipeline integrados | secciones 1 y 2; `deploy-k8s.sh` es el punto de unión |
| Deploy reproducible y verificable | jobs `build`/`deploy` + `/version` == SHA (sección 5) |
| Secretos fuera del repo y fuera del estado | sección 3 + verificaciones 9 a 12 de la sección 4 |
| Permisos mínimos y denegaciones comprobadas | sección 3 + verificación 11 |
| Rotación documentada y ejecutable | [runbook.md](runbook.md#12-rotar-un-secreto) |
| Observación documentada | [observability.md](observability.md) y [deployment-ec2.md](deployment-ec2.md) |
| Troubleshooting de producción | [runbook.md](runbook.md) |
| Fallos reales del pipeline documentados | sección 6, tabla de runs en rojo |
| Documentación ordenada | índice en el [README](../README.md#documentación) |
