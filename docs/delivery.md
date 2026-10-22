# Delivery setup: de la imagen al endpoint

Revisión del **paso 7 (Review Your Delivery Setup)**: demostrar que la imagen
Docker, la infraestructura de Terraform, los manifiestos de Kubernetes y el
pipeline de GitHub Actions funcionan **juntos**, y que el commit desplegado se
puede verificar de punta a punta.

Este documento responde tres preguntas:

1. ¿Qué hace el pipeline desde un push a `main` hasta que la API responde?
2. ¿Qué archivo del repo produce cada artefacto y qué recurso de AWS queda?
3. ¿Cómo se comprueba, con comandos, que lo desplegado es el commit actual?

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
  │                                                               │
  │  job test     ruff check + pytest (Postgres 16 de servicio)   │
  │       │        OTEL_SDK_DISABLED=true                         │
  │       ▼ needs: test                                           │
  │  job build    docker build --build-arg GIT_SHA=<sha>          │
  │       │       docker push ECR :<sha> y :latest                │
  │       ▼ needs: build                                          │
  │  job deploy   aws ssm send-command (AWS-RunShellScript)       │
  │       │         cd /opt/journal-api                           │
  │       │         git fetch --depth 1 origin main               │
  │       │         git reset --hard FETCH_HEAD                   │
  │       │         bash scripts/deploy-k8s.sh <sha>              │
  │       │       wait rollout + curl /version == <sha>           │
  └───────┼───────────────────────────────────────────────────────┘
          │ SSM (sin puerto 22, sin llaves SSH)
          ▼
  ┌──────────────────────────────────────────────────────────────┐
  │ EC2 t3.small · k3s · namespace journal-api                     │
  │  namespace → ADOT + Fluent Bit → secrets desde SSM →           │
  │  Postgres/Service/Caddy → schema → journal-api:<sha>           │
  │  rollout status deployment/journal-api                         │
  └───────┬───────────────────────────────────────────────────────┘
          │ HTTPS 443
          ▼
  https://3.216.116.179.sslip.io/version → {"commit":"<sha>"}
```

### Detalle por etapa

| # | Etapa | Disparador | Comando / archivo | Resultado verificable |
|---|---|---|---|---|
| 1 | `test` | push o PR a `main` | `uv run ruff check .` + `uv run pytest -m "not exercise"` con Postgres 16 como service container | el job falla antes de construir si el código o los tests están rotos |
| 2 | `build` | push a `main` (o `workflow_dispatch`), `needs: test` | `docker/build-push-action` con `build-args: GIT_SHA=${{ github.sha }}` | imagen en ECR con tag `<sha>` y `latest` |
| 3 | `deploy` | `needs: build`, `environment: production` | `aws ssm send-command` → `git fetch --depth 1 origin main` → `git reset --hard FETCH_HEAD` → `bash scripts/deploy-k8s.sh <sha>` | SSM `Success` + rollout completo |
| 4 | verificación | último paso de `deploy` | `curl -fsS $PUBLIC_URL/version` en un loop de 20 intentos | `commit` == `github.sha`; si no, el job falla |

> **Nota sobre `origin/main`:** el workflow usa `git reset --hard FETCH_HEAD`
> porque el clon de la instancia es *shallow* (`--depth 1`) y no tiene la ref
> `origin/main` completa. Es el mismo commit que `origin/main` en el momento del
> deploy; el cambio se hizo en `6c9001b` justamente para evitar el fallo
> `unknown revision origin/main` en el job `deploy`.

### Autenticación sin secretos estáticos

`build` y `deploy` piden `id-token: write` y asumen el rol de GitHub Actions por
**OIDC** (`aws-actions/configure-aws-credentials`). Los permisos del rol son
mínimos:

| Acción | Recurso | Para qué |
|---|---|---|
| `ecr:GetAuthorizationToken` + push de capas/imagen | repositorio `journal-api` | publicar la imagen del commit |
| `ec2:DescribeInstances` | instancias | resolver la instancia por tag `Name=journal-api-instance` (sin hardcodear el ID) |
| `ssm:SendCommand` | instancia + documento `AWS-RunShellScript` | ejecutar el deploy |
| `ssm:GetCommandInvocation` / `List*` | — | leer estado y salida del comando |

No hay `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` en el repo ni en GitHub
Secrets. La única condición de confianza es el repositorio, la rama `main` y el
environment `production`.

## 2. Mapa artefacto → archivo → recurso en AWS

| Artefacto | Archivo(s) en el repo | Recurso / efecto en AWS |
|---|---|---|
| Imagen de la API | `Dockerfile`, `.dockerignore` | repositorio ECR `journal-api`; tag = commit SHA (y `latest`); lifecycle: conserva 15 imágenes |
| Infraestructura base | `terraform/main.tf` | VPC `10.0.0.0/16`, subnet pública, IGW, route table, Security Group 80/443 (sin 22), IAM de instancia (`journal-ssm-role` + `journal-ssm-profile`), OIDC provider de GitHub + rol `journal-github-actions`, repositorio ECR, instancia `t3.small` con `user_data` (swap + k3s + primer deploy), Elastic IP |
| Observabilidad como código | `terraform/monitoring.tf` | topic SNS `journal-api-alarms`, suscripción email (valor en `terraform.tfvars`, gitignored), log groups `/aws/journal-api/application` y `/aws/journal-api/metrics`, política IAM de X-Ray/CloudWatch Logs/PutMetricData, dashboard `journal-api`, alarmas `journal-api-http-5xx` y `journal-api-latency-p95`, 2 query definitions |
| Namespace | `k8s/namespace.yaml` | namespace `journal-api` |
| Telemetría | `k8s/adot-collector.yaml` | ConfigMap `adot-collector-config`, Deployment `adot-collector`, Service ClusterIP `adot-collector:4318` |
| Logs | `k8s/fluent-bit.yaml` | ServiceAccount + ClusterRole/Binding, ConfigMap `fluent-bit-config`, DaemonSet `fluent-bit` |
| Base de datos | `k8s/postgresql.yaml` | PVC `postgres-data` (1Gi), Service `postgres:5432`, Deployment `postgres` |
| Entrada HTTP | `k8s/caddy.yaml` | ConfigMap `caddy-config`, PVC `caddy-data` (TLS), Deployment `caddy` con hostPort 80/443 |
| Servicio interno de la API | `k8s/service.yaml` | Service ClusterIP `journal-api-service:8000` (consumido por Caddy) |
| Aplicación | `k8s/deployment.yaml` | Deployment `journal-api` (1 réplica, `strategy: Recreate`), probes en `/version`, límites 320Mi/700m |
| Secretos | `k8s/secret.example.yaml` (plantilla), `scripts/deploy-k8s.sh` | Secrets `journal-secrets`, `journal-db` y `ecr-credential` creados en el deploy desde SSM Parameter Store; el `secret.yaml` real está gitignored y no se aplica |
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
| 1 | `kubectl apply -f k8s/namespace.yaml` | namespace `journal-api` |
| 2 | `kubectl apply -f k8s/adot-collector.yaml -f k8s/fluent-bit.yaml` + `rollout status` de ambos | ADOT Collector y Fluent Bit listos **antes** de la app (para no perder la primera telemetría) |
| 3 | lee `/journal-api/{POSTGRES_PASSWORD,OPENAI_API_KEY,OPENAI_BASE_URL,OPENAI_MODEL}` de SSM | valores con `--with-decryption` |
| 4 | crea/actualiza `journal-db`, `journal-secrets` y `ecr-credential` con `--dry-run=client -o yaml \| kubectl apply -f -` | Secrets idempotentes |
| 5 | `kubectl apply -f k8s/postgresql.yaml -f k8s/service.yaml -f k8s/caddy.yaml` + espera Postgres | PVC, Services y Caddy |
| 6 | `kubectl exec -i deploy/postgres -- psql ... < database_setup.sql` | esquema idempotente en cada deploy |
| 7 | `sed s|journal-api:placeholder|journal-api:<sha>|` + `kubectl apply` + `rollout status deployment/journal-api` | imagen exacta del commit, con timeout de 240 s |

El `user_data` de Terraform ejecuta este mismo script en el primer arranque,
usando `git rev-parse HEAD` como tag y cayendo a `latest` si ese tag todavía no
existe en ECR.

## 3. Verificación end-to-end

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

| # | Qué se verifica | Comando exacto | Resultado esperado | Observado (2026-10-22) |
|---|---|---|---|---|
| 1 | Terraform aplicado y sin drift | `cd terraform && terraform output` | `api_url`, `public_ip`, `ecr_image`, ARNs de alarmas y topic | `api_url = https://3.216.116.179.sslip.io` |
| 2 | Imagen del commit en ECR | `aws ecr describe-images --repository-name journal-api --query 'sort_by(imageDetails,&imagePushedAt)[-1].[imageTags,imagePushedAt]' --output json` | el tag contiene el SHA de `HEAD` | `["2cfbc50...","latest"]`, push 17:40 UTC |
| 3 | Cluster sano | `run_on_instance 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n journal-api get pods -o wide'` | 5 pods `Running` (`journal-api`, `postgres`, `caddy`, `adot-collector`, `fluent-bit`) | 5/5 `Running`, 0 reinicios salvo Caddy (1) |
| 4 | La API corre ese SHA | `curl -fsS https://3.216.116.179.sslip.io/version` | `{"commit":"<sha de HEAD>"}` | `{"commit":"2cfbc50e7fb2f0f24837ff67b82f9bc2cdc09a97"}` |
| 5 | La imagen desplegada es la del tag | `run_on_instance 'export KUBECONFIG=/etc/rancher/k3s/k3s.yaml; kubectl -n journal-api get deploy/journal-api -o jsonpath="{.spec.template.spec.containers[0].image}"'` | `.../journal-api:<sha de HEAD>` | `...journal-api:2cfbc50e...` |
| 6 | Alarmas activas | `aws cloudwatch describe-alarms --alarm-name-prefix journal-api --query 'MetricAlarms[].[AlarmName,StateValue]' --output table` | 2 alarmas en `OK` (o `ALARM` si hay incidente real) | `journal-api-http-5xx OK`, `journal-api-latency-p95 OK` |
| 7 | Notificación SNS operativa | `aws sns list-subscriptions-by-topic --topic-arn "$(terraform -chdir=terraform output -raw sns_alarms_topic_arn)" --query 'Subscriptions[].[Protocol,SubscriptionArn]' --output table` | `email` con ARN real, no `PendingConfirmation` | 1 suscripción confirmada |
| 8 | HTTPS válido | `curl -sS -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' https://3.216.116.179.sslip.io/version` | `200 0` | `200 0` |

## 4. ¿Lo desplegado es el commit actual?

La trazabilidad se apoya en tres valores que deben coincidir **exactamente**:

| Fuente | Comando | Valor actual |
|---|---|---|
| Commit local | `git rev-parse HEAD` | `2cfbc50e7fb2f0f24837ff67b82f9bc2cdc09a97` |
| Tag de la imagen en ECR | `aws ecr describe-images --repository-name journal-api --image-ids imageTag=$(git rev-parse HEAD) --query 'imageDetails[0].imageTags' --output json` | `["2cfbc50e...","latest"]` |
| Tag que corre Kubernetes | `run_on_instance '... kubectl -n journal-api get deploy/journal-api -o jsonpath="{.spec.template.spec.containers[0].image}"'` | `.../journal-api:2cfbc50e...` |
| SHA que responde la app | `curl -fsS https://3.216.116.179.sslip.io/version` | `{"commit":"2cfbc50e..."}` |

Comparación en un solo paso:

```bash
HEAD=$(git rev-parse HEAD)
LIVE=$(curl -fsS https://3.216.116.179.sslip.io/version | python -c "import json,sys; print(json.load(sys.stdin)['commit'])")
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

Si los tres valores no coinciden, el diagnóstico está en
[runbook.md](runbook.md#4-deploy-verde-pero-version-devuelve-otro-sha).

## 5. Runs de CI verificados

| Fecha (UTC) | Commit | Run ID | `test` | `build` | `deploy` |
|---|---|---|---|---|---|
| 2026-10-22 17:38 | `2cfbc50` | [39824519576](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39824519576) | ✅ | ✅ | ✅ |
| 2026-10-22 17:24 | `e88dd8f` | [39822443046](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39822443046) | ✅ | ✅ | ✅ |
| 2026-10-22 16:56 | `11e519e` | [39818333716](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39818333716) | ✅ | ✅ | ✅ |
| 2026-10-22 15:47 | `6c9001b` | [39808118539](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39808118539) | ✅ | ✅ | ✅ |
| 2026-10-22 15:43 | `f37087b` | [39807526706](https://github.com/amarillaRodrigo/journal-starter/actions/runs/39807526706) | ✅ | ✅ | ❌ |

El run `39807526706` falló en `deploy` porque el clon shallow no podía resolver
`origin/main`; `6c9001b` cambió el reset a `FETCH_HEAD` y el run siguiente quedó
verde. Se conserva en la tabla porque documenta el único fallo real del pipeline
y su corrección.

> **Contrato del pipeline:** los jobs se llaman exactamente `test`, `build` y
> `deploy`. Esos nombres son parte del contrato (badges, branch protection,
> `environment: production` y la lectura del run); no se renombran aunque cambie
> la implementación interna.

## 6. Reproducir el delivery sin esperar un push

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

## 7. Criterios de aceptación del paso 7

| Requisito | Evidencia en este repo |
|---|---|
| Imagen, Terraform, manifiestos y pipeline integrados | secciones 1 y 2; `deploy-k8s.sh` es el punto de unión |
| Deploy reproducible y verificable | jobs `build`/`deploy` + `/version` == SHA (sección 4) |
| Observación documentada | [observability.md](observability.md) y [deployment-ec2.md](deployment-ec2.md) |
| Troubleshooting de producción | [runbook.md](runbook.md) |
| Documentación ordenada | índice en el [README](../README.md#documentación) |
