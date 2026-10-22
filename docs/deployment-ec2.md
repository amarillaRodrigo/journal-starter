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
   └── deploy  (aws ssm send-command → rollout status)
                        │
                        ▼
        EC2 t3.small (Amazon Linux 2023) — Elastic IP 3.216.116.179
          └── k3s (namespace journal-api)
                ├── caddy            hostPort 80/443, TLS automático (Let's Encrypt)
                ├── journal-api      Deployment (1 réplica), :8000
                ├── postgres         Deployment + PVC, :5432 (ClusterIP)
                ├── adot-collector   OTLP :4318 → X-Ray + CloudWatch (EMF)
                └── fluent-bit       DaemonSet → CloudWatch Logs
```

**URL pública:** https://3.216.116.179.sslip.io

**Puertos abiertos:** 80 y 443. El 22 está **cerrado**; la administración es por
**SSM Run Command / Session Manager**.

## Pipeline (`.github/workflows/ci.yml`)

| Job | `name` / id | Qué hace |
|---|---|---|
| 1 | `test` | `ruff check`, inicializa las DBs y corre `pytest` contra un Postgres de servicio |
| 2 | `build` | `needs: test` — build con `--build-arg GIT_SHA=${{ github.sha }}` y push a ECR con tags `<sha>` y `latest` |
| 3 | `deploy` | `needs: build` — `environment: production` (url HTTPS), SSM Run Command: `git reset --hard origin/main` + `scripts/deploy-k8s.sh <sha>` y espera `rollout status` |

**Autenticación cloud:** GitHub OIDC (`aws-actions/configure-aws-credentials`) asume
`arn:aws:iam::607856468834:role/journal-github-actions`. No hay
`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` en el repo ni en Secrets.

El rol solo confía en:

- `repo:amarillaRodrigo/journal-starter:ref:refs/heads/main` (job `build`)
- `repo:amarillaRodrigo/journal-starter:environment:production` (job `deploy`)

y solo permite: push a ECR, `ec2:DescribeInstances` y `ssm:SendCommand` /
`GetCommandInvocation`.

El último paso de `deploy` consulta `https://3.216.116.179.sslip.io/version` y
falla si el `commit` devuelto no es el SHA del push.

## Secretos

Nada sensible vive en el repo ni en la imagen (`.env`, `k8s/secret.yaml` y
`terraform/` están en `.gitignore` y `.dockerignore`).

Los valores reales están en **SSM Parameter Store**:

| Parámetro | Tipo |
|---|---|
| `/journal-api/OPENAI_API_KEY` | SecureString |
| `/journal-api/POSTGRES_PASSWORD` | SecureString |
| `/journal-api/OPENAI_BASE_URL` | String |
| `/journal-api/OPENAI_MODEL` | String |

`scripts/deploy-k8s.sh` los lee con `--with-decryption` y crea los Secrets de
Kubernetes (`journal-secrets`, `journal-db`) y el pull secret de ECR
(`ecr-credential`) en cada deploy.

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
(SSM + ECR read + X-Ray/CloudWatch), OIDC provider de GitHub + rol
`journal-github-actions`, repositorio ECR + lifecycle policy, EC2 con
`user_data` que instala k3s y despliega, y Elastic IP.

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
Invoke-RestMethod https://3.216.116.179.sslip.io/version   # {"commit":"<sha>"}
Invoke-RestMethod https://3.216.116.179.sslip.io/entries
Invoke-RestMethod https://3.216.116.179.sslip.io/openapi.json
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
