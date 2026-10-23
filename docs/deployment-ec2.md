# Despliegue en AWS: k3s + ECR + GitHub Actions

Arquitectura del capstone: la API corre en **Kubernetes (k3s)** sobre una instancia
EC2, la imagen se construye y publica en **ECR** desde **GitHub Actions**, y el
deploy se ejecuta sin abrir puertos de administración, vía **AWS SSM**.

## Arquitectura

```text
 push a main
     │
     ▼
 GitHub Actions
   ├── test    (ruff + pytest + Postgres service)
   ├── build   (docker build → ECR, tag = commit SHA)   ← OIDC, sin secretos
   └── deploy  (resolve URL pública + aws ssm send-command → rollout status)
                        │
                        ▼
        EC2 t3.small (Amazon Linux 2023) — Elastic IP 3.215.52.10
          └── k3s (namespace journal-api)
                ├── caddy            hostPort 80/443, TLS automático (Let's Encrypt)
                ├── journal-api      Deployment (1 réplica), :8000
                ├── postgres         Deployment + PVC, :5432 (ClusterIP)
                ├── adot-collector   OTLP :4318 → X-Ray + CloudWatch (EMF)
                └── fluent-bit       DaemonSet → CloudWatch Logs

  En cada deploy el nodo arma los secretos del pod:

     Secrets Manager ──GetSecretValue (2 ARN exactos)──┐
     SSM Parameter Store ──GetParameter (solo config)───┴──► Secret de k8s ──► env vars
```

> El **volumen raíz es de 20 GB gp3 cifrado**: el default de 8 GB del `t3.small`
> no alcanza porque containerd conserva una imagen por commit (el tag es el
> SHA) y al 15 % de espacio libre el kubelet entra en `DiskPressure`.

**URL pública:** https://3.215.52.10.sslip.io

**Puertos abiertos:** 80 y 443. El 22 está **cerrado**; la administración es por
**SSM Run Command / Session Manager**.

## Pipeline (`.github/workflows/ci.yml`)

| Job | `name` / id | Qué hace |
|---|---|---|
| 1 | `test` | `ruff check`, inicializa las DBs y corre `pytest` contra un Postgres de servicio |
| 2 | `build` | `needs: test` — build con `--build-arg GIT_SHA=${{ github.sha }}` y push a ECR con tags `<sha>` y `latest` |
| 3 | `deploy` | `needs: build` - `environment: production` (url HTTPS), resolución de la IP pública desde la instancia y SSM Run Command: `git reset --hard FETCH_HEAD` + `scripts/deploy-k8s.sh <sha>` y espera `rollout status` |

**Autenticación cloud:** GitHub OIDC (`aws-actions/configure-aws-credentials`) asume
`arn:aws:iam::607856468834:role/journal-github-actions`. No hay
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` en el repo ni en Secrets.

El rol solo confía en:

- `repo:amarillaRodrigo/journal-starter:ref:refs/heads/main` (job `build`)
- `repo:amarillaRodrigo/journal-starter:environment:production` (job `deploy`)

y solo permite: push a ECR, `ec2:DescribeInstances` y `ssm:SendCommand` /
`GetCommandInvocation`.

El último paso de `deploy` consulta `https://3.215.52.10.sslip.io/version` y
falla si el `commit` devuelto no es el SHA del push.

## Secretos

Nada sensible vive en el repo ni en la imagen: `.env` y `k8s/secret.yaml` están
en `.gitignore` y `.dockerignore`, y `terraform.tfstate` / `terraform.tfvars`
también están fuera de git.

Las **credenciales** viven en **AWS Secrets Manager**:

| Secreto | Claves |
|---|---|
| `journal-api/credentials/database` | `POSTGRES_PASSWORD`, `DATABASE_URL` |
| `journal-api/credentials/llm` | `OPENAI_API_KEY` |

La **configuración no sensible** sigue en **SSM Parameter Store** como `String`
plano: son valores públicos (la URL del proveedor y el nombre del modelo), no
credenciales, y no tienen por qué pagar el coste de un secreto:

| Parámetro | Tipo | ¿Secreto? |
|---|---|---|
| `/journal-api/OPENAI_BASE_URL` | String | no |
| `/journal-api/OPENAI_MODEL` | String | no |

### El valor del secreto no pasa por Terraform

`terraform/secrets.tf` crea **solo el "cascarón"** del secreto (nombre, ARN,
tags, resource policy, cifrado). El **valor** se siembra una sola vez, fuera de
banda:

```bash
./scripts/migrate-secrets.sh            # SSM Parameter Store -> Secrets Manager
./scripts/migrate-secrets.sh --dry-run  # muestra el plan sin escribir
```

Si el valor estuviera en una `aws_secretsmanager_secret_version` o en
`terraform.tfvars`, quedaría en **texto plano dentro de `terraform.tfstate`**,
que es un archivo en disco. Mover un secreto de "archivo" a Secrets Manager
mientras se lo deja en el estado no cambia nada.

### Dos identidades de servicio

| Identidad | Qué puede hacer |
|---|---|
| `journal-api-runtime-role` (la app) | **solo** `GetSecretValue` y `DescribeSecret` sobre los dos ARN exactos de los secretos del proyecto |
| `journal-ssm-role` (instance profile de la EC2) | **no puede leer secretos**: tiene un Deny explícito. Solo puede **delegar** en el rol de la app, y solo con el `ExternalId` correcto |

El `ExternalId` del `AssumeRole` es el `sub` del token de ServiceAccount del
pod (`system:serviceaccount:journal-api:journal-api`), que se lee de
`/var/run/secrets/kubernetes.io/serviceaccount/token`. Además, cada secreto
tiene una **resource policy** que nombra al **rol de la app**. **Las dos
políticas deben permitir la acción**: AWS evalúa la intersección de la identity
policy y la resource policy.

### Cómo llega el secreto al proceso

```text
Secrets Manager
   │  GetSecretValue con el rol de la app (credenciales temporales de STS)
   ▼
init container del pod ──► emptyDir (medium: Memory → tmpfs)
   │                           /secrets/DATABASE_URL
   │                           /secrets/OPENAI_API_KEY
   ▼
app: pydantic-settings los lee del directorio (secrets_dir)
```

El material sensible **no entra** al Secret de Kubernetes (etcd, base64) ni al
spec del pod (legible por cualquiera con `get pods`). Postgres toma la
password de un archivo (`POSTGRES_PASSWORD_FILE`). El deploy solo publica la
configuración no sensible, en un **ConfigMap** (`journal-config`).

> **Limitación conocida:** en k3s cualquier pod alcanza IMDS (hop limit 2) y
> puede obtener las credenciales del instance profile, así que el `ExternalId`
> protege del uso accidental, no de un atacante. El aislamiento real por pod
> exige IRSA o EKS Pod Identity, que necesitan un issuer OIDC público.

### Rotación

Mover un secreto a Secrets Manager **no revoca** el valor anterior: hay que
rotarlo en su origen. Ver [runbook.md](runbook.md#12-rotar-un-secreto) para el
procedimiento completo.

## Deploy manual / troubleshooting

```bash
# en la instancia (vía SSM Session Manager)
cd /opt/journal-api
git fetch --depth 1 origin main && git reset --hard FETCH_HEAD
sudo bash scripts/deploy-k8s.sh <commit-sha>
```

Estado del cluster:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n journal-api get pods,svc,pvc
kubectl -n journal-api rollout status deployment/journal-api
kubectl -n journal-api logs deploy/journal-api --tail=50
```

## Infraestructura (Terraform)

```powershell
cd terraform
terraform init
terraform plan
terraform apply
```

Crea: VPC/subnet/IGW/route table, Security Group (80/443), IAM de instancia
(SSM + ECR read + X-Ray/CloudWatch + Secrets Manager acotado), OIDC provider de
GitHub + rol `journal-github-actions`, repositorio ECR + lifecycle policy, EC2
con `user_data` que instala k3s y despliega, Elastic IP, y los secretos en
Secrets Manager (`terraform/secrets.tf`).

La instancia usa un **volumen raíz de 20 GB en gp3** (`root_block_device`). El
default del `t3.small` son 8 GB y no alcanzan: containerd conserva una imagen
por commit (el tag es el SHA) y al 15 % de espacio libre el kubelet entra en
`DiskPressure` y evicta pods en masa. Ver
[runbook.md](runbook.md#11-disco-lleno).

`terraform output` devuelve `api_url`, `public_ip`, `ecr_image`,
`github_actions_role_arn`, `cloudwatch_dashboard_url`, los ARNs de las alarmas
y el ARN del topic SNS.

> `user_data` solo corre en el primer arranque. Para re-bootstrap completo:
> `terraform apply -replace=aws_instance.journal_api`.

## Observabilidad

El detalle completo (pipeline, métricas, consultas y prueba de alarmas) está en
[`docs/observability.md`](observability.md). Resumen operativo:

```text
journal-api ──OTLP :4318──► adot-collector ──► X-Ray
                                          └──► CloudWatch (namespace JournalAPI)
pods stdout ──────────────► fluent-bit   ──► CloudWatch Logs /aws/journal-api/application
```

| Recurso | Nombre |
|---|---|
| Dashboard | `journal-api` |
| Alarmas | `journal-api-http-5xx`, `journal-api-latency-p95` |
| Topic SNS | `journal-api-alarms` |
| Log groups | `/aws/journal-api/application`, `/aws/journal-api/metrics` |

Los manifiestos viven en `k8s/adot-collector.yaml` y `k8s/fluent-bit.yaml`, y
`scripts/deploy-k8s.sh` los aplica (y espera los rollouts) en cada deploy.

Comandos útiles:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
kubectl -n journal-api logs deploy/adot-collector --tail=50
kubectl -n journal-api logs ds/fluent-bit --tail=50

aws cloudwatch list-metrics --namespace JournalAPI --region us-east-1
aws cloudwatch describe-alarms --alarm-name-prefix journal-api --region us-east-1
aws logs tail /aws/journal-api/application --follow --region us-east-1
```

> El exporter `awsemf` agrega la dimensión `OTelLib=<scope>`. El dashboard y las
> alarmas la declaran explícitamente; si se omite, no matchean ninguna serie.

> La suscripción email del topic SNS está **confirmada (1 confirmed / 0 pending)**;
> las alarmas entregan los avisos sin pasos manuales pendientes.

## Verificación

```powershell
Invoke-RestMethod https://3.215.52.10.sslip.io/version   # {"commit":"<sha>"}
Invoke-RestMethod https://3.215.52.10.sslip.io/entries
Invoke-RestMethod https://3.215.52.10.sslip.io/openapi.json
```

Comprobar que la imagen no lleva secretos:

```powershell
docker run --rm journal-api:latest sh -c "ls -a /app; ls /app/k8s"
```

## Costos y limpieza

EC2 `t3.small` + EBS + IPv4 público + observabilidad (CloudWatch, X-Ray,
alarmas, SNS) ≈ **$25/mes** on-demand, de los cuales ~$4.90 corresponden a
observabilidad. Para destruir todo:

```powershell
cd terraform
terraform destroy
```
