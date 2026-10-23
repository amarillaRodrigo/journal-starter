# ==========================================
# Secretos: AWS Secrets Manager
# ==========================================
#
# El Terraform crea el "cascarón" del secreto (nombre, ARN, tags, resource
# policy y cifrado) pero NUNCA el valor.
#
# Por qué: si el valor estuviera en una `aws_secretsmanager_secret_version` o en
# una variable de `terraform.tfvars`, quedaría en TEXTO PLANO dentro de
# terraform.tfstate y terraform.tfstate.backup, que son archivos en disco.
# Mover un secreto de "archivo" a Secrets Manager mientras se lo deja en el
# estado no cambia nada.
#
# El valor real se siembra UNA SOLA VEZ, fuera de banda:
#
#     python scripts/migrate_secrets.py
#
# Ese script lee los parámetros de SSM (con --with-decryption) y los escribe
# en Secrets Manager. Terraform nunca lo ve.

locals {
  secret_names = {
    database = "journal-api/credentials/database"
    llm      = "journal-api/credentials/llm"
  }

  # Secrets Manager agrega un sufijo aleatorio de 6 caracteres al nombre
  # (journal-api/credentials/llm-AbCdEf). En los NotResource se usa el patrón
  # con comodín para que la política sobreviva a un recreate del secreto; en
  # los Allow se usa el ARN exacto que devuelve Terraform.
  secret_arn_pattern = {
    database = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${local.secret_names.database}-*"
    llm      = "arn:aws:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current.account_id}:secret:${local.secret_names.llm}-*"
  }

  # Parámetros de SSM que NO son secretos (String plano) y siguen siendo la
  # fuente de la configuración del proveedor LLM y del contacto ACME.
  ssm_config_params = [
    "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/journal-api/OPENAI_BASE_URL",
    "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/journal-api/OPENAI_MODEL",
    "arn:aws:ssm:${var.aws_region}:${data.aws_caller_identity.current.account_id}:parameter/journal-api/ACME_EMAIL",
  ]

  # 'sub' del token de ServiceAccount del pod de la app. Se usa como
  # ExternalId del AssumeRole: un pod de otro namespace, o con otra
  # ServiceAccount, produce otro 'sub' y por lo tanto no puede asumir el rol.
  service_account_subject = "system:serviceaccount:${var.project}:journal-api"
}

resource "aws_secretsmanager_secret" "database" {
  name        = local.secret_names.database
  description = "Credenciales de PostgreSQL de Journal API (POSTGRES_PASSWORD, DATABASE_URL)."

  # 7 días de ventana de recuperación: un borrado accidental no es definitivo.
  recovery_window_in_days = 7

  tags = {
    Name = "${var.project}-secret-database"
  }
}

resource "aws_secretsmanager_secret" "llm" {
  name        = local.secret_names.llm
  description = "Credenciales del proveedor LLM de Journal API (OPENAI_API_KEY)."

  recovery_window_in_days = 7

  tags = {
    Name = "${var.project}-secret-llm"
  }
}

# ==========================================
# Identidad de servicio de la aplicación
# ==========================================
#
# La app NO usa las credenciales de la instancia: asume su propio rol, acotado
# a leer los dos secretos del proyecto y nada más.
#
# El rol de la instancia (journal-ssm-role) pierde el acceso directo a los
# secretos y solo puede DELEGAR en este rol. Asi, si un pod o un proceso del
# nodo obtains las credenciales del instance profile, no puede leer los
# secretos: tiene que pasar por el AssumeRole con el ExternalId correcto.

resource "aws_iam_role" "journal_api_runtime_role" {
  name        = "journal-api-runtime-role"
  description = "Identidad de servicio de la app: lee los dos secretos del proyecto y nada mas"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.journal_ssm_role.arn }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "sts:ExternalId" = local.service_account_subject
        }
      }
    }]
  })

  tags = {
    Name = "${var.project}-runtime-role"
  }
}

resource "aws_iam_role_policy" "runtime_secrets" {
  name = "${var.project}-runtime-secrets-policy"
  role = aws_iam_role.journal_api_runtime_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadOnlyScopedSecrets"
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = [
        aws_secretsmanager_secret.database.arn,
        aws_secretsmanager_secret.llm.arn,
      ]
    }]
  })
}

# ==========================================
# IAM del instance profile: delegar, no leer
# ==========================================

resource "aws_iam_role_policy" "instance_delegate" {
  name = "${var.project}-instance-delegate-policy"
  role = aws_iam_role.journal_ssm_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DelegateToRuntimeRole"
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = aws_iam_role.journal_api_runtime_role.arn
        Condition = {
          StringEquals = {
            "sts:ExternalId" = local.service_account_subject
          }
        }
      },
      {
        # El rol de la instancia NO puede leer secretos: solo delegar en el rol
        # de la app. Esto no afecta a la sesion asumida (que se evalua contra
        # las politicas del rol de destino, no contra las de este).
        Sid      = "DenyDirectSecretAccess"
        Effect   = "Deny"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = "*"
      },
      {
        # AmazonSSMManagedInstanceCore concede ssm:GetParameters sobre "*".
        # OPENAI_BASE_URL y OPENAI_MODEL no son secretos (siguen en SSM como
        # String porque son configuracion publica), pero no hay motivo para que
        # la instancia pueda leer cualquier parametro de la cuenta.
        #
        # Caveat: el SSM Agent no usa GetParameter para sus propias
        # operaciones (usa UpdateInstanceInformation, ListAssociations, etc.),
        # asi que este Deny no afecta la administeracion por SSM.
        Sid    = "DenySsmParametersOutsideScope"
        Effect = "Deny"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParameterHistory",
        ]
        NotResource = local.ssm_config_params
      },
    ]
  })
}

# ==========================================
# Resource policy del secreto: "quién puede leer ESTE secreto"
# ==========================================
#
# Junto con la identity policy del rol, las DOS deben permitir la acción: AWS
# evalúa la intersección de ambas. Si falta una de las dos, el acceso se
# deniega. Es el patrón del tutorial de Secrets Manager: la resource policy
# dice "este rol puede leer este secreto", la identity policy dice "este rol
# puede leer secretos, y solo estos dos".

resource "aws_secretsmanager_secret_policy" "database" {
  secret_arn = aws_secretsmanager_secret.database.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowRuntimeRoleRead"
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.journal_api_runtime_role.arn }
      Action    = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource  = aws_secretsmanager_secret.database.arn
    }]
  })
}

resource "aws_secretsmanager_secret_policy" "llm" {
  secret_arn = aws_secretsmanager_secret.llm.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowRuntimeRoleRead"
      Effect    = "Allow"
      Principal = { AWS = aws_iam_role.journal_api_runtime_role.arn }
      Action    = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
      Resource  = aws_secretsmanager_secret.llm.arn
    }]
  })
}
