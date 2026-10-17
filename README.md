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

## Phase 4 Capstone: Cloud Deployment Evidence

### 1. Architecture Diagram & Traffic Paths

```text
                      +-------------------------------------------------------+
                      |                      AWS VPC                          |
                      |                 (10.0.0.0/16)                         |
                      |                                                       |
 [ Public Client ] ---> [ Internet Gateway ]                                  |
   (HTTPS / 443)      |        |                                              |
                      |        v (Public Subnet: 10.0.1.0/24)                 |
 [ Administrator ] ---> +---------------------------------------------------+ |
   (SSH / 22)         | EC2 Instance (t3.micro - Ubuntu 24.04)              | |
                      |   - Caddy Reverse Proxy (Auto-TLS for sslip.io)     | |
                      |   - FastAPI / Uvicorn (Systemd daemonized)          | |
                      |   - IAM Role: JournalApiEC2Role (Bedrock)           | |
                      |   - SG: app-career-journal-sg                       | |
                      +---------------------------------------------------+ |
                               |                                              |
                               | (Internal VPC Traffic: TCP 5432)             |
                               v (Private Subnets: 10.0.10.0/24, 10.0.11.0/24)|
                      +---------------------------------------------------+ |
                      | RDS PostgreSQL 16 (db.t4g.micro)                  | |
                      |   - Database: career_journal                        | |
                      |   - Public Access: NO                               | |
                      |   - Least-Privilege Role: api_user                  | |
                      |   - SG: rds-career-journal-sg                       | |
                      +---------------------------------------------------+ |
                      +-------------------------------------------------------+
```

**Traffic Paths:**
1. Public Inbound Path: Public HTTPS traffic (port 443) enters through the Internet Gateway to Caddy on the EC2 instance, which proxies requests locally to FastAPI on port 8000.
2. Private Application Path: Internal database queries flow from the EC2 instance in the public subnet to the private RDS tier over TCP port 5432.
3. Administrative Path: Scoped SSH ingress (port 22) allowed strictly from the administrator's public IP address.

### 2. Deployment Specification & Evidence

**Selected Cloud Services:**
- **Compute & Ingress:** AWS EC2 (t3.micro) hosting Caddy reverse proxy and FastAPI application.
- **Database:** AWS RDS PostgreSQL 16 (db.t4g.micro, 20 GB gp3).
- **Networking:** Custom Amazon VPC (10.0.0.0/16) with 1 public subnet and 2 private subnets across multiple AZs (us-east-1a, us-east-1b).
- **AI Service & Safety:** Amazon Bedrock (Anthropic Claude Haiku & Amazon Nova Lite) integrated with Amazon Bedrock Guardrails (journal-api-guardrail).

**Cost Controls & Budget:**
- AWS Budget created with a $10.00 USD monthly threshold and email alerting. Expected baseline operating cost is ~$0.00 inside AWS Free Tier (or <$15.00/mo without Free Tier).

**Access Controls & Least-Privilege:**
- `rds-career-journal-sg` accepts TCP 5432 strictly from `app-career-journal-sg`.
- Database initialized with dedicated application role `api_user` restricted to DML (SELECT, INSERT, UPDATE, DELETE) on schema public.
- Management ports: Database is completely non-routable from the public internet (`PubliclyAccessible: No`).

**Verification Evidence:**
- **Public HTTPS:** Validated via automated certificate issuance on https://98.81.98.31.sslip.io (HTTP/2 200).
- **Private Tier Isolation:** Public attempt via `nc -zv -w 5 <RDS_ENDPOINT> 5432` confirmed connection timed out.
- **Automated Contract Tests:**
  - `POST /entries`: Passed with HTTP 201 returning generated UUID.
  - `POST /entries/{id}/analyze`: Passed with HTTP 200 returning valid sentiment, summary, and topic list under 30 seconds.

### 3. Production Limitation & Mitigation

- **Single Instance Single Point of Failure (SPOF):** The compute tier runs on a standalone EC2 instance within a single Availability Zone. For production readiness, this architecture should be migrated to an Application Load Balancer (ALB) across multiple AZs backing an Auto Scaling Group (ASG) or AWS ECS Fargate cluster to achieve automatic failover and zero-downtime scaling.

## License

MIT License - see [LICENSE](LICENSE).

