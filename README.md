# Learn to Cloud Phase 3 Capstone: Journal API

[![CI](https://github.com/amarillaRodrigo/journal-starter/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/amarillaRodrigo/journal-starter/actions/workflows/ci.yml)

Welcome to [Learn to Cloud's](https://learntocloud.com) Phase 3 capstone. You will be guided to building a journal API with **FastAPI**, **PostgreSQL**, structured logging, input validation, and AI-powered entry analysis.

## Capstone

These chapters will guide you and are meant to be completed in order. Each chapter builds on the previous one, so do not skip ahead. 

1. [Check the prerequisites](docs/01-prerequisites.md)
2. [Set up the project](docs/02-project-setup.md)
3. [Run the API](docs/03-run-the-api.md)
4. [Build GET for one entry](docs/04-get-entry.md)
5. [Build DELETE for one entry](docs/05-delete-entry.md)
6. [Add input validation and debug a partial update](docs/06-input-validation.md)
7. [Use logs to understand the API](docs/07-logging.md)
8. [Set up an AI provider](docs/08-ai-setup.md)
9. [Build AI-powered analysis](docs/09-ai-analysis.md)
10. [Finish the capstone](docs/10-finish.md)

**[Start the capstone →](docs/01-prerequisites.md)**

## Reference

This is additional reference material for the capstone in case you want to explore further or need help:

- [Testing and CI](docs/reference/testing-and-ci.md)
- [Troubleshooting](docs/reference/troubleshooting.md)
- [Sync your fork with upstream](docs/reference/upstream-sync.md)
- [Explore your database](docs/reference/explore-database.md)

> **Learning environment only:** This application has no authentication or
> per-user data isolation. Do not expose it publicly or store personal or
> sensitive journal content in it.

## Cloud Deployment (EC2 + k3s + ECR + GitHub Actions)

### 1. Architecture Diagram & Traffic Paths

```text
                        +------------------------------------------------------+
                        |                     AWS VPC (10.0.0.0/16)            |
                        |                                                      |
 [ Public Client ] ---> | Internet Gateway                                     |
   (HTTPS / 443)        |        |                                             |
                        |        v  Public Subnet 10.0.1.0/24                  |
                        | +--------------------------------------------------+ |
                        | | EC2 t3.small (Amazon Linux 2023)                 | |
                        | | Elastic IP 3.216.116.179                         | |
                        | |   k3s (namespace journal-api)                    | |
                        | |     ├── caddy      hostPort 80/443, TLS (sslip)  | |
                        | |     ├── journal-api Deployment :8000             | |
                        | |     ├── postgres   Deployment + PVC :5432        | |
                        | |     ├── adot-collector  OTLP :4318               | |
                        | |     └── fluent-bit      DaemonSet                | |
                        | |   IAM instance role: SSM + ECR read + X-Ray/CW   | |
                        | +--------------------------------------------------+ |
                        +------------------------------------------------------+
                                  ▲                          │
                                  │ SSM Run Command          │ OTLP / logs
                                  │ (no inbound 22)          ▼
                        GitHub Actions                X-Ray + CloudWatch + SNS
```

**Traffic paths**

1. **Public inbound:** HTTPS (443) → Internet Gateway → Caddy on the instance →
   `journal-api` Service on port 8000.
2. **Internal data:** `journal-api` → `postgres` ClusterIP on 5432 (in-cluster,
   not exposed).
3. **Administration:** GitHub Actions and operators use **AWS SSM Run Command /
   Session Manager**; port 22 is closed.
4. **Telemetry:** app → ADOT Collector (OTLP) → X-Ray + CloudWatch; pod stdout →
   Fluent Bit → CloudWatch Logs.

**Selected cloud services**

- **Compute:** EC2 `t3.small` running k3s (single node).
- **Registry:** Amazon ECR, image tag = commit SHA.
- **Database:** PostgreSQL 16 in-cluster (Deployment + PVC).
- **Ingress/TLS:** Caddy with automatic Let's Encrypt certificates for
  `sslip.io`.
- **Observability:** ADOT Collector, X-Ray, CloudWatch (metrics, logs,
  dashboard, alarms) and SNS. See [docs/observability.md](docs/observability.md).
- **Secrets:** SSM Parameter Store (`/journal-api/*`), read at deploy time.

### 2. CI/CD Pipeline

`.github/workflows/ci.yml` — jobs are named exactly `test`, `build`, `deploy`:

| Job | What it does |
|---|---|
| `test` | `ruff check` + `pytest` against a Postgres service container (`OTEL_SDK_DISABLED=true`) |
| `build` | `docker build --build-arg GIT_SHA=${{ github.sha }}` and push to ECR with tags `<sha>` and `latest` |
| `deploy` | SSM Run Command → `git reset --hard origin/main` + `scripts/deploy-k8s.sh <sha>`, waits for rollouts and verifies `/version` returns the pushed SHA |

Authentication is **GitHub OIDC** (`arn:aws:iam::607856468834:role/journal-github-actions`);
there are no long-lived AWS keys in the repository or in GitHub Secrets.

### 3. Observability

| Signal | Backend | Where |
|---|---|---|
| Traces | AWS X-Ray | `journal-api` segment, custom `db.entries.*` and `llm.analyze_entry` subsegments |
| Metrics | CloudWatch namespace `JournalAPI` | 15 series (requests by status, latency p50/p95, DB, LLM) |
| Logs | CloudWatch Logs `/aws/journal-api/application` | Fluent Bit, only the `journal-api` namespace |
| Dashboard | `journal-api` | <https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=journal-api> |
| Alarms | `journal-api-http-5xx`, `journal-api-latency-p95` | SNS `journal-api-alarms` |

Implementation details, saved queries, the end-to-end alarm test and the cost
breakdown are documented in **[docs/observability.md](docs/observability.md)**.

### 4. Cost Controls

- AWS Budget with a $10.00 USD monthly threshold and email alerting.
- Approximate operating cost: **~$25/month** on-demand (`t3.small` + EBS +
  public IPv4 + ECR + CloudWatch/X-Ray/SNS), of which **~$4.90/month** is
  observability and **~$7.59/month** is the resize from `t3.micro` to
  `t3.small` needed to run k3s + app + database + agents.

### 5. Production Limitations

- **Single node:** k3s + app + database + agents run on one EC2 instance and one
  AZ. A production design would use an ALB across AZs with an ASG or ECS/EKS,
  and RDS for the database.
- **No authentication or per-user isolation:** learning environment only.
- **LLM dependency:** `POST /entries/{id}/analyze` returns `503` when the
  provider has no quota or is unavailable; the failure is visible in traces,
  metrics and logs.

## Documentación

Deployment, operación y diagnóstico del entorno desplegado:

- [Delivery setup](docs/delivery.md): cadena push → test → build → deploy y cómo
  verificar que `/version` corresponde al commit actual.
- [Deployment en EC2](docs/deployment-ec2.md): arquitectura, secretos en SSM,
  deploy manual y Terraform.
- [Observabilidad](docs/observability.md): pipeline ADOT/Fluent Bit, métricas,
  logs, dashboard, alarmas y costos.
- [Runbook de producción](docs/runbook.md): troubleshooting de pipeline, pods,
  TLS, métricas, logs, alarmas y disco (todo por SSM; el puerto 22 está cerrado).

## License

MIT License - see [LICENSE](LICENSE).

