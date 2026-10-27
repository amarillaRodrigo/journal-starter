# ==========================================
# Variables
# ==========================================

variable "aws_region" {
  description = "Región de AWS donde se despliega la API"
  type        = string
  default     = "us-east-1"
}

variable "image_tag" {
  description = "Tag de la imagen en ECR. Usar el commit SHA completo para pinear una versión exacta, o 'latest'."
  type        = string
  default     = "latest"
}

variable "project" {
  description = "Prefijo de nombres de recursos"
  type        = string
  default     = "journal-api"
}

variable "instance_type" {
  description = "Tipo de instancia EC2. t3.small (2 GB) deja lugar para k3s + app + ADOT + Fluent Bit."
  type        = string
  default     = "t3.small"
}

variable "github_repository" {
  description = "Repositorio de GitHub autorizado a asumir el rol vía OIDC (owner/repo)"
  type        = string
  default     = "amarillaRodrigo/journal-starter"
}

variable "github_pipeline_repository" {
  description = <<-EOT
    Repo espejo (owner/repo) donde corre el pipeline de GitHub Actions.
    GitHub deshabilito Actions en el fork "journal-starter" del lado de su
    plataforma: la API responde enabled=true y un PUT devuelve 204, pero todo
    trigger falla con HTTP 422 y solo soporte de GitHub puede limpiarlo.
    El CI/CD corre aqui, con el mismo codigo y los mismos workflows.
  EOT
  type        = string
  default     = "amarillaRodrigo/journal-starter-pipeline"
}

variable "acme_email" {
  description = "Email de contacto para el registro ACME (Caddy / Let's Encrypt). Si se deja vacío se usa alarm_email."
  type        = string
  default     = ""
}

locals {
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  image        = "${local.ecr_registry}/${var.project}:${var.image_tag}"
  repo_url     = "https://github.com/${var.github_repository}.git"
  gh_owner     = split("/", var.github_repository)[0]
  gh_repo      = split("/", var.github_repository)[1]

  gh_pipeline_owner = split("/", var.github_pipeline_repository)[0]
  gh_pipeline_repo  = split("/", var.github_pipeline_repository)[1]

  # Email de contacto para el registro ACME de Caddy. Reutiliza el de las
  # alarmas si no se define uno propio, para no duplicar el dato en
  # terraform.tfvars (que está gitignored).
  acme_email = var.acme_email != "" ? var.acme_email : var.alarm_email
}

# ==========================================
# VPC & Networking
# ==========================================

resource "aws_vpc" "journal_vpc" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags = {
    Name = "${var.project}-vpc"
  }
}

resource "aws_subnet" "journal_subnet" {
  vpc_id                  = aws_vpc.journal_vpc.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "${var.aws_region}a"
  map_public_ip_on_launch = true
  tags = {
    Name = "${var.project}-subnet"
  }
}

resource "aws_internet_gateway" "journal_igw" {
  vpc_id = aws_vpc.journal_vpc.id
  tags = {
    Name = "${var.project}-igw"
  }
}

resource "aws_route_table" "journal_rt" {
  vpc_id = aws_vpc.journal_vpc.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.journal_igw.id
  }
  tags = {
    Name = "${var.project}-rt"
  }
}

resource "aws_route_table_association" "journal_rta" {
  subnet_id      = aws_subnet.journal_subnet.id
  route_table_id = aws_route_table.journal_rt.id
}

# ==========================================
# Security Group
# ==========================================

resource "aws_security_group" "journal_sg" {
  name        = "journal-sg"
  description = "Security group for Journal API EC2 instance"
  vpc_id      = aws_vpc.journal_vpc.id

  # Sin puerto 22: la administración es vía AWS Systems Manager (SSM).
  ingress {
    description = "HTTP (ACME + redirect a HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS (API publica)"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Salida (ECR, SSM, ACME, dependencias)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project}-sg"
  }
}

# ==========================================
# IAM: perfil de instancia para SSM + lectura de ECR
# ==========================================

data "aws_caller_identity" "current" {}

resource "aws_iam_role" "journal_ssm_role" {
  name = "journal-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = {
    Name = "${var.project}-ssm-role"
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.journal_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "ecr_read" {
  role       = aws_iam_role.journal_ssm_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_iam_instance_profile" "journal_ssm_profile" {
  name = "journal-ssm-profile"
  role = aws_iam_role.journal_ssm_role.name
}

# ==========================================
# IAM: GitHub Actions vía OIDC (sin credenciales estáticas)
# ==========================================

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]

  tags = {
    Name = "${var.project}-github-oidc"
  }
}

resource "aws_iam_role" "github_actions" {
  name        = "journal-github-actions"
  description = "Rol asumido por GitHub Actions (OIDC) para build y deploy de Journal API"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        StringLike = {
          # GitHub agrega IDs inmutables al claim sub (owner@id/repo@id), por eso
          # los comodines. build corre en main; deploy en el environment production.
          # El repo espejo tambien esta autorizado: es donde GitHub permite
          # ejecutar Actions, porque en el fork los deshabilito la plataforma.
          "token.actions.githubusercontent.com:sub" = [
            "repo:${local.gh_owner}@*/${local.gh_repo}@*:ref:refs/heads/main",
            "repo:${local.gh_owner}@*/${local.gh_repo}@*:environment:production",
            "repo:${local.gh_pipeline_owner}@*/${local.gh_pipeline_repo}@*:ref:refs/heads/main",
            "repo:${local.gh_pipeline_owner}@*/${local.gh_pipeline_repo}@*:environment:production",
          ]
        }
      }
    }]
  })

  tags = {
    Name = "${var.project}-github-actions"
  }
}

resource "aws_iam_role_policy" "github_actions" {
  name = "${var.project}-github-actions-policy"
  role = aws_iam_role.github_actions.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "EcrLogin"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "EcrPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
          "ecr:BatchGetImage",
          "ecr:GetDownloadUrlForLayer",
        ]
        Resource = aws_ecr_repository.journal_api.arn
      },
      {
        Sid      = "ResolveInstance"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      },
      {
        Sid    = "DeployViaSsm"
        Effect = "Allow"
        Action = ["ssm:SendCommand"]
        Resource = [
          "arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/*",
          "arn:aws:ssm:${var.aws_region}::document/AWS-RunShellScript",
        ]
      },
      {
        Sid    = "ReadCommandResult"
        Effect = "Allow"
        Action = [
          "ssm:GetCommandInvocation",
          "ssm:ListCommandInvocations",
          "ssm:ListCommands",
        ]
        Resource = "*"
      },
    ]
  })
}

# ==========================================
# ECR (registro de la imagen)
# ==========================================

resource "aws_ecr_repository" "journal_api" {
  name                 = var.project
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = {
    Name = var.project
  }
}

resource "aws_ecr_lifecycle_policy" "journal_api" {
  repository = aws_ecr_repository.journal_api.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Mantener solo las últimas 15 imágenes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 15
      }
      action = { type = "expire" }
    }]
  })
}

# ==========================================
# EC2 Instance (k3s + API + Postgres + Caddy)
# ==========================================

resource "aws_instance" "journal_api" {
  ami                    = "ami-0856027a77429315a" # Amazon Linux 2023
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.journal_subnet.id
  vpc_security_group_ids = [aws_security_group.journal_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.journal_ssm_profile.name

  # El volumen raíz por defecto del t3.small son 8 GB, y no alcanzan para k3s +
  # containerd: containerd conserva una imagen por commit (el tag es el SHA) y
  # el overlayfs llega a 1.5 GB con una sola versión. Al 85 % el kubelet entra
  # en DiskPressure y evicta pods en masa, el rollout nunca converge y el
  # endpoint queda en 502. 20 GB en gp3 da margen de sobra para las dos
  # cosas: las imagenes y los logs de los pods.
  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
  }

  # IMDSv2 obligatorio y hop limit 2 para que los pods (ADOT/Fluent Bit)
  # obtengan las credenciales del instance role sin secretos estaticos.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  # Bootstrap completo: swap, k3s, clonado del repo y primer deploy.
  # Los secretos se leen de AWS Secrets Manager en el deploy, nunca se hornean.
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail

    # --- Swap: t3.micro tiene 1 GB de RAM y acá corre k3s + 3 pods ---
    if [ ! -f /swapfile ]; then
      dd if=/dev/zero of=/swapfile bs=1M count=2048
      chmod 600 /swapfile
      mkswap /swapfile
      swapon /swapfile
      echo '/swapfile none swap sw 0 0' >> /etc/fstab
    fi

    # --- k3s (Kubernetes ligero, sin Traefik/servicelb/metrics-server) ---
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="server --disable traefik --disable servicelb --disable metrics-server --write-kubeconfig-mode 644" sh -

    export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
    for i in $(seq 1 60); do
      kubectl get nodes 2>/dev/null | grep -q " Ready" && break
      sleep 5
    done
    kubectl get nodes

    # --- Código (repo público) y primer deploy ---
    dnf install -y git
    # deploy-k8s.sh parsea el SecretString con python3 (solo stdlib).
    command -v python3 >/dev/null 2>&1 || dnf install -y python3
    if [ ! -d /opt/journal-api/.git ]; then
      git clone --depth 1 --branch main ${local.repo_url} /opt/journal-api
    fi
    chmod +x /opt/journal-api/scripts/deploy-k8s.sh

    SHA=$(git -C /opt/journal-api rev-parse HEAD)
    /opt/journal-api/scripts/deploy-k8s.sh "$SHA" || /opt/journal-api/scripts/deploy-k8s.sh latest
  EOF

  depends_on = [
    aws_iam_role_policy_attachment.ssm_core,
    aws_iam_role_policy_attachment.ecr_read,
    aws_iam_role_policy.observability,
    aws_ecr_repository.journal_api,
    # El user_data corre deploy-k8s.sh en el primer arranque: el secreto y el
    # permiso GetSecretValue tienen que existir ANTES de que la instancia
    # arranque, o el bootstrap falla.
    aws_secretsmanager_secret.database,
    aws_secretsmanager_secret.llm,
    aws_iam_role_policy.instance_delegate,
    aws_iam_role.journal_api_runtime_role,
  ]

  tags = {
    Name = "${var.project}-instance"
  }
}

# ==========================================
# Elastic IP (IP pública estable)
# ==========================================

resource "aws_eip" "journal_eip" {
  domain   = "vpc"
  instance = aws_instance.journal_api.id

  tags = {
    Name = "${var.project}-eip"
  }
}

# ==========================================
# Configuración no sensible en SSM Parameter Store
# ==========================================
#
# Valores que el deploy necesita y que NO son credenciales: son públicos, así
# que van como String plano y no tienen por qué pagar el coste de un secreto
# en Secrets Manager. El rol de la instancia solo puede leer estos (ver
# terraform/secrets.tf).

resource "aws_ssm_parameter" "acme_email" {
  name        = "/journal-api/ACME_EMAIL"
  type        = "String"
  value       = local.acme_email
  description = "Email de contacto para el registro ACME (Let's Encrypt / ZeroSSL) de Caddy."
}

# ==========================================
# Outputs
# ==========================================

output "vpc_id" {
  value = aws_vpc.journal_vpc.id
}

output "public_ip" {
  value = aws_eip.journal_eip.public_ip
}

output "api_url" {
  value = "https://${aws_eip.journal_eip.public_ip}.sslip.io"
}

output "ecr_image" {
  value = local.image
}

output "github_actions_role_arn" {
  value = aws_iam_role.github_actions.arn
}
