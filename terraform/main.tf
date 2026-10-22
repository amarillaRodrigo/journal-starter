# ==========================================
# Variables
# ==========================================

variable "aws_region" {
  description = "Región de AWS donde se despliega la API"
  type        = string
  default     = "us-east-1"
}

variable "image_tag" {
  description = "Tag de la imagen en ECR. Usar el commit SHA corto para pinear una versión exacta (ej: -var=\"image_tag=3dc9a69\"), o 'latest' para el último build."
  type        = string
  default     = "latest"
}

variable "project" {
  description = "Prefijo de nombres de recursos"
  type        = string
  default     = "journal-api"
}

locals {
  ecr_registry = "${data.aws_caller_identity.current.account_id}.dkr.ecr.${var.aws_region}.amazonaws.com"
  image        = "${local.ecr_registry}/${var.project}:${var.image_tag}"
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

  # Sin puerto 22: el acceso es vía AWS Systems Manager (SSM Session Manager).
  ingress {
    description = "API HTTP"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "Salida (ECR, SSM, dependencias)"
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

# ==========================================
# EC2 Instance
# ==========================================

resource "aws_instance" "journal_api" {
  ami                    = "ami-0856027a77429315a" # Amazon Linux 2023
  instance_type          = "t3.micro"
  subnet_id              = aws_subnet.journal_subnet.id
  vpc_security_group_ids = [aws_security_group.journal_sg.id]
  iam_instance_profile   = aws_iam_instance_profile.journal_ssm_profile.name

  # Bootstrap: Docker + Postgres + API. Los secretos se leen de SSM Parameter
  # Store en tiempo de arranque, nunca se hornean en la imagen.
  user_data = <<-EOF
    #!/bin/bash
    set -euxo pipefail
    REGION="${var.aws_region}"
    IMG="${local.image}"

    # --- Docker ---
    dnf install -y docker
    systemctl enable --now docker

    # --- ECR login (permisos vía instance profile) ---
    aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin "${local.ecr_registry}"
    docker pull $IMG

    # --- Secretos desde SSM Parameter Store (SecureString) ---
    PGPASS=$(aws ssm get-parameter --name /journal-api/POSTGRES_PASSWORD --with-decryption --query Parameter.Value --output text --region $REGION)
    KAI=$(aws ssm get-parameter --name /journal-api/OPENAI_API_KEY --with-decryption --query Parameter.Value --output text --region $REGION)
    KBU=$(aws ssm get-parameter --name /journal-api/OPENAI_BASE_URL --query Parameter.Value --output text --region $REGION)
    KMO=$(aws ssm get-parameter --name /journal-api/OPENAI_MODEL --query Parameter.Value --output text --region $REGION)

    # --- Red interna entre contenedores ---
    docker network create journal-net || true

    # --- Postgres ---
    docker run -d --name journal-db --network journal-net --restart unless-stopped \
      -e POSTGRES_USER=postgres \
      -e POSTGRES_PASSWORD="$PGPASS" \
      -e POSTGRES_DB=career_journal \
      postgres:16-alpine

    for i in $(seq 1 30); do
      docker exec journal-db pg_isready -U postgres >/dev/null 2>&1 && break
      sleep 2
    done

    # --- Esquema ---
    cat > /tmp/schema.sql <<'SQL'
    CREATE TABLE IF NOT EXISTS entries (
        id VARCHAR PRIMARY KEY,
        data JSONB NOT NULL,
        created_at TIMESTAMP WITH TIME ZONE NOT NULL,
        updated_at TIMESTAMP WITH TIME ZONE NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_entries_created_at ON entries(created_at);
    CREATE INDEX IF NOT EXISTS idx_entries_data_gin ON entries USING GIN (data);
    SQL
    docker exec -i journal-db psql -U postgres -d career_journal < /tmp/schema.sql

    # --- API ---
    docker run -d --name journal-api --network journal-net --restart unless-stopped \
      -p 8000:8000 \
      -e DATABASE_URL="postgresql://postgres:$PGPASS@journal-db:5432/career_journal" \
      -e OPENAI_API_KEY="$KAI" \
      -e OPENAI_BASE_URL="$KBU" \
      -e OPENAI_MODEL="$KMO" \
      $IMG
  EOF

  depends_on = [
    aws_iam_role_policy_attachment.ssm_core,
    aws_iam_role_policy_attachment.ecr_read,
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
# Outputs
# ==========================================

output "vpc_id" {
  value = aws_vpc.journal_vpc.id
}

output "public_ip" {
  value = aws_eip.journal_eip.public_ip
}

output "api_url" {
  value = "http://${aws_eip.journal_eip.public_ip}:8000"
}

output "ecr_image" {
  value = local.image
}
