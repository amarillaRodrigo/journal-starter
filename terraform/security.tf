# ==========================================
# Seguridad del plano de control: auditoria,
# deteccion de amenazas y alertas de seguridad
# ==========================================
#
# Que resuelve este archivo:
#
#   1. CloudTrail: el registro de todo lo que pasa en la cuenta (quien
#      abrio un puerto, quien leyo un secreto, quien entro a la consola).
#      Sin esto no se puede responder "hubo acceso no autorizado?" después
#      de una fuga de credenciales.
#   2. Una copia del trail en CloudWatch Logs, para consultarla con Logs
#      Insights sin bajar el bucket.
#   3. Metric filters + alarmas sobre ese trail: los eventos de seguridad
#      que de verdad importan en este proyecto.
#   4. GuardDuty: la deteccion de amenazas administrada de AWS.
#
# Decisiones (y el porque):
#
#   - Trail regional en us-east-1, no multi-region: el proyecto es
#     single-region. Pero include_global_service_events = true, porque los
#     eventos de IAM y STS son GLOBALES y solo se registran en us-east-1:
#     sin esto, la mitad del audit trail no existiria.
#   - SSE-KMS (no SSE-S3) con rotacion de clave: el trail es evidencia de
#     auditoria. Si alguien puede leerlo sin dejar rastro, no vale como
#     evidencia.
#   - Doble copia: S3 (duradero, lifecycle a Glacier) + CloudWatch Logs
#     (consultable). La de S3 es la que sobrevive; la de Logs es la que se
#     consulta en 10 segundos.
#   - enable_log_file_validation: CloudTrail escribe un digest de cada
#     archivo. Si alguien modifica el trail en S3, el digest no cuadra y
#     se nota.

locals {
  trail_name         = "${var.project}-audit"
  security_namespace = "JournalSecurity"
  audit_bucket_name  = "${var.project}-audit-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  audit_log_group    = "aws-cloudtrail-logs-${var.project}"
  trail_arn          = "arn:aws:cloudtrail:${var.aws_region}:${data.aws_caller_identity.current.account_id}:trail/${local.trail_name}"
  account_arn        = "arn:aws:iam::${data.aws_caller_identity.current.account_id}"

  # Eventos que significan que alguien toco el security group de la API.
  sg_security_events = [
    "AuthorizeSecurityGroupIngress",
    "RevokeSecurityGroupIngress",
    "ModifySecurityGroup",
    "ModifySecurityGroupRules",
    "DeleteSecurityGroup",
  ]

  # Eventos de escalamiento de privilegios o creacion de credenciales.
  iam_credential_events = [
    "CreateAccessKey",
    "CreateUser",
    "CreateLoginProfile",
    "AttachUserPolicy",
    "PutUserPolicy",
    "UpdateAssumeRolePolicy",
  ]
}

# ==========================================
# KMS: clave de cifrado del bucket de auditoria
# ==========================================
#
# La clave se rota sola (enable_key_rotation) y la policy restringe quien
# puede usarla: CloudTrail, y solo para cifrar los objetos de ESTE trail
# (aws:SourceArn). Sin esa condicion, cualquiera con permisos de
# GenerateDataKey podria usar la clave.

data "aws_iam_policy_document" "audit_kms" {
  statement {
    sid    = "AllowAccountAdministration"
    effect = "Allow"
    actions = [
      "kms:*",
    ]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["${local.account_arn}:root"]
    }
  }

  statement {
    sid    = "AllowCloudTrailEncryption"
    effect = "Allow"
    actions = [
      "kms:GenerateDataKey*",
      "kms:DescribeKey",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
  }
}

resource "aws_kms_key" "audit" {
  description             = "Cifrado del bucket de auditoria (CloudTrail) de Journal API"
  enable_key_rotation     = true
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.audit_kms.json

  tags = {
    Name = "${var.project}-audit-kms"
  }
}

resource "aws_kms_alias" "audit" {
  name          = "alias/${var.project}-audit"
  target_key_id = aws_kms_key.audit.key_id
}

# ==========================================
# S3: archivo durable del trail
# ==========================================

resource "aws_s3_bucket" "audit" {
  # Nombre globalmente unico: el prefijo del proyecto no alcanza, dos
  # cuentas con el mismo nombre de proyecto colisionarian.
  bucket = local.audit_bucket_name

  # force_destroy = false a proposito: el trail es evidencia y no debería
  # borrarse con un `terraform destroy`. Para destruir el stack hay que
  # vaciar el bucket primero (o poner force_destroy = true a mano).
  force_destroy = false

  tags = {
    Name = "${var.project}-audit"
  }
}

resource "aws_s3_bucket_public_access_block" "audit" {
  bucket                  = aws_s3_bucket.audit.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# CloudTrail escribe cada archivo con el header "x-amz-acl:
# bucket-owner-full-control". Con ObjectOwnership = BucketOwnerEnforced (el
# default de S3 desde abril de 2023, ACLs deshabilitadas) ese header hace
# fallar el PUT con AccessControlListNotSupported, y el trail se queda sin
# archivo en S3 sin dar ningun error visible.
#
# Por eso el bucket va en BucketOwnerPreferred: acepta el ACL que escribe
# CloudTrail. La postura sigue siendo privada: Block Public Access, sin
# acceso público, cifrado con KMS y denegacion de trafico sin TLS.
resource "aws_s3_bucket_ownership_controls" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    object_ownership = "BucketOwnerPreferred"
  }
}

# Versioning en el bucket de evidencia.
#
# El trail es evidencia de auditoria: si alguien borra un archivo por error
# (o a proposito), con versioning queda la version anterior. La regla de
# Config S3_BUCKET_VERSIONING_ENABLED lo exigia y estaba en NON_COMPLIANT.
#
# No es Object Lock (que exigiria crear el bucket con esa opcion y no se
# puede agregar despues): el versioning protege del borrado accidental, que
# es el riesgo real aca. El trail ya tiene enable_log_file_validation, asi
# que ademas se puede verificar la integridad de cada version.
resource "aws_s3_bucket_versioning" "audit" {
  bucket = aws_s3_bucket.audit.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.audit.arn
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "audit" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "audit-retention"
    status = "Enabled"

    # Sin filtro: la regla aplica a todos los objetos del bucket.
    filter {}

    # Un mes en caliente (para|Download rapido), despues a Glacier.
    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    # Un año de evidencia y despues se va. Es un capstone, no un banco.
    expiration {
      days = 365
    }

    # Con versioning hay que limpiar las versiones no actuales: si no,
    # cada version anterior del trail se queda para siempre. Mismo criterio
    # que las actuales.
    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }

  depends_on = [
    aws_s3_bucket_server_side_encryption_configuration.audit,
    aws_s3_bucket_versioning.audit,
  ]
}

data "aws_iam_policy_document" "audit_bucket" {
  # CloudTrail valida la policy del bucket ANTES de crear el trail y
  # rechaza la trail si no encuentra exactamente estos permisos. Por eso
  # esta statement es obligatoria: no es "una buena practica", es un
  # requisito de la API (InsufficientS3BucketPolicyException).
  statement {
    sid       = "AllowCloudTrailGetBucketAcl"
    effect    = "Allow"
    actions   = ["s3:GetBucketAcl"]
    resources = [aws_s3_bucket.audit.arn]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "AllowCloudTrailWrite"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.audit.arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["cloudtrail.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceArn"
      values   = [local.trail_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    # CloudTrail escribe cada objeto con el ACL bucket-owner-full-control.
    # Si esta condicion no esta, CloudTrail considera la policy incorrecta.
    condition {
      test     = "StringEquals"
      variable = "s3:x-amz-acl"
      values   = ["bucket-owner-full-control"]
    }
  }

  statement {
    sid       = "DenyInsecureTransport"
    effect    = "Deny"
    actions   = ["s3:*"]
    resources = [aws_s3_bucket.audit.arn, "${aws_s3_bucket.audit.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "audit" {
  bucket = aws_s3_bucket.audit.id
  policy = data.aws_iam_policy_document.audit_bucket.json

  depends_on = [
    aws_s3_bucket_public_access_block.audit,
    aws_s3_bucket_ownership_controls.audit,
  ]
}

# ==========================================
# CloudWatch Logs: la copia consultable del trail
# ==========================================
#
# El trail va a S3 Y a CloudWatch Logs. S3 es el archivo (barato, durable);
# CloudWatch Logs es lo que permite responder "quien leyo el secreto?"
# con una query en vez de con un `aws s3 sync` de 40 MB.
#
# El nombre del log group tiene que empezar por "aws-cloudtrail-logs-":
# es un requisito de CloudTrail, no una convencion.

variable "audit_log_retention_days" {
  description = "Retencion de la copia consultable del trail en CloudWatch Logs. El archivo durable vive en S3."
  type        = number
  default     = 30
}

resource "aws_cloudwatch_log_group" "audit" {
  name              = local.audit_log_group
  retention_in_days = var.audit_log_retention_days

  tags = {
    Name = "${var.project}-audit-logs"
  }
}

resource "aws_iam_role" "cloudtrail_to_cwl" {
  name = "${var.project}-cloudtrail-to-cwl"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudtrail.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = {
          "aws:SourceArn" = local.trail_arn
        }
      }
    }]
  })

  tags = {
    Name = "${var.project}-cloudtrail-to-cwl"
  }
}

resource "aws_iam_role_policy" "cloudtrail_to_cwl" {
  name = "${var.project}-cloudtrail-to-cwl-policy"
  role = aws_iam_role.cloudtrail_to_cwl.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
      ]
      Resource = "${aws_cloudwatch_log_group.audit.arn}:*"
    }]
  })
}

# ==========================================
# CloudTrail: el audit trail
# ==========================================

resource "aws_cloudtrail" "audit" {
  name                          = local.trail_name
  s3_bucket_name                = aws_s3_bucket.audit.id
  include_global_service_events = true
  is_multi_region_trail         = false
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.audit.arn

  # El ARN necesita el sufijo ":*": CloudTrail valida que el log group
  # exista y que el rol pueda escribir en sus streams. Sin el sufijo la
  # API responde InvalidCloudWatchLogsLogGroupArnException.
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.audit.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_to_cwl.arn

  tags = {
    Name = local.trail_name
  }

  # El trail empieza a loguear en cuanto se crea. Si el bucket todavia no
  # tiene la policy (o el rol de CloudWatch Logs no tiene permisos), los
  # primeros eventos se pierden: por eso se espera a que las dos cosas
  # esten listas.
  depends_on = [
    aws_s3_bucket_policy.audit,
    aws_iam_role_policy.cloudtrail_to_cwl,
  ]
}

# ==========================================
# Alertas de seguridad sobre el trail
# ==========================================
#
# Cada metric filter convierte un evento del trail en una metrica de
# CloudWatch, y cada alarma vigila esa metrica. Se eligieron cuatro
# eventos, que son los que un capstone tiene que poder demostrar:
#
#   1. Cambio en el security group: alguien abre o cierra un puerto de la
#      API. Es el ataque clasico sobre un SG con 0.0.0.0/0.
#   2. Login fallido en la consola: la API no tiene autenticacion y el
#      puerto 22 esta cerrado, asi que el unico "login" de esta cuenta es
#      el login de la consola de AWS.
#   3. Lectura de un secreto por alguien que no es el rol asumido: la app
#      lee los secretos con su propio rol (assumed-role), asi que cualquier
#      lectura hecha por una persona o por una access key es sospechosa.
#      Este es el patron de una credencial filtrada en uso.
#   4. Creacion o escalamiento de credenciales de IAM: alguien se crea un
#      usuario, una access key o se adjunta una policy.
#
# Lo que NO se vigila: cada Describe* y cada List* que hace cualquier
# servicio. Alerta de todo = alerta de nada.
#
# POR QUE METRIC FILTERS Y NO EVENTBRIDGE
#
# Lo canonico en AWS seria EventBridge: una regla con patron JSON sobre
# detail.eventName y un target SNS. Los patrones JSON SI se aceptan en
# EventBridge (verificado con TestEventPattern), pero en ESTA CUENTA
# CloudTrail no le entrega sus eventos a EventBridge: se creo la regla, se
# dispararon eventos reales de cambio de security group y las metricas de
# EventBridge (TriggeredRules, Invocations) nunca aparecieron. Sin
# eventos, la regla no matchea. Se probo tambien crear el
# service-linked role que usa CloudTrail para esto: tampoco cambio nada.
#
# Asi que la alerta se hace con metric filters sobre el log group del
# trail, que es lo que si funciona (verificado end-to-end: el evento
# AuthorizeSecurityGroupIngress llego al trail, la metrica subio y la
# alarma disparo).
#
# Y aqui esta el detalle que hace que funcione sin falsos positivos: un
# metric filter con patron JSON ({"$.eventName": [...]}) NO lo acepta la
# API de CloudWatch Logs en esta cuenta (InvalidParameterException:
# "Invalid character(s) in term ':'"), asi que hay que buscar TEXTO.
#
# Buscar texto tiene una trampa: el patron viaja dentro del request del
# API, asi que el evento PutMetricFilter que crea el filtro CONTIENE el
# patron y el filtro se cuenta a si mismo. Con el OR ("?A ?B") era peor:
# las propias queries de investigacion (StartQuery) contienen el nombre
# del evento buscado y tambien se contaban. Una alarma que se dispara
# porque la estas investigando no es una alarma.
#
# La solucion es anclar el patron con el eventSource: cada servicio tiene
# el suyo, y las queries de investigacion no lo mencionan.
#
#   "AuthorizeSecurityGroupIngress" "ec2.amazonaws.com"
#
# Con AND, el patron solo matchea el evento de CloudTrail de ese tipo: un
# StartQuery o un PutMetricFilter son de logs.amazonaws.com y quedan
# afuera.
#
# Y como el AND no se puede combinar con el OR de "?", hay un metric
# filter por evento: cada evento lo cuenta su filtro y solo el suyo, asi
# que la metrica no se infla.
#
# Ruido conocido: cada vez que se crea o modifica uno de estos filtros, el
# evento PutMetricFilter se cuenta a si mismo y la alarma dispara una vez.
# Es ruido de setup, no un incidente.

resource "aws_cloudwatch_log_metric_filter" "security_group_changes" {
  for_each = toset(local.sg_security_events)

  name           = "${var.project}/sg-changes-${each.key}"
  log_group_name = aws_cloudwatch_log_group.audit.name

  pattern = "\"${each.key}\" \"ec2.amazonaws.com\""

  metric_transformation {
    name          = "SecurityGroupChanges"
    namespace     = local.security_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "console_login_failures" {
  name           = "${var.project}/console-login-failures"
  log_group_name = aws_cloudwatch_log_group.audit.name

  # "Failed authentication" es el errorMessage de un login de consola
  # fallido: es lo unico que separa un login bueno de uno malo.
  pattern = "\"ConsoleLogin\" \"signin.amazonaws.com\" \"Failed authentication\""

  metric_transformation {
    name          = "ConsoleLoginFailures"
    namespace     = local.security_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "secret_reads" {
  name           = "${var.project}/secret-reads"
  log_group_name = aws_cloudwatch_log_group.audit.name

  # GetSecretValue AND IAMUser:
  #   - las lecturas legitimas son del rol de la app y del rol de la
  #     instancia, y los dos son "AssumedRole";
  #   - una access key filtrada o un humano en la consola son "IAMUser".
  # Limitacion documentada: un atacante que reuse un session token de un
  # rol asumido no dispara esta alarma (para eso esta GuardDuty).
  #
  # El termino "secretId" esta a proposito y es lo que hace que el filtro
  # NO se auto-alimente. Sin el, la alarma se dispara sola cuando alguien
  # INVESTIGA:
  #
  #   - el evento de la llamada "aws logs filter-log-events --filter-pattern
  #     '\"GetSecretValue\" \"secretsmanager.amazonaws.com\"'" lleva esos dos
  #     terminos en sus requestParameters, y el principal es un IAMUser
  #     (el que investiga), asi que matchea el patron y la alarma suena.
  #   - o sea: la consulta que manda el runbook para verificar accesos no
  #     autorizados dispara la alarma de accesos no autorizados. Verificado
  #     el 2026-11-05: la alarma "journal-api-security-secret-read" entro en
  #     ALARM a las 09:05 por la propia query de investigacion.
  #
  # El evento real de GetSecretValue siempre trae el requestParameter
  # "secretId", y una llamada a Logs API no lo trae (trae logGroupName,
  # filterPattern, limit). Con "secretId" en el patron, el evento real
  # matchea y la query de investigacion no.
  pattern = "\"GetSecretValue\" \"secretsmanager.amazonaws.com\" \"secretId\" IAMUser"

  metric_transformation {
    name          = "SecretReads"
    namespace     = local.security_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "iam_credential_changes" {
  for_each = toset(local.iam_credential_events)

  name           = "${var.project}/iam-credential-changes-${each.key}"
  log_group_name = aws_cloudwatch_log_group.audit.name

  pattern = "\"${each.key}\" \"iam.amazonaws.com\""

  metric_transformation {
    name          = "IAMCredentialChanges"
    namespace     = local.security_namespace
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

# ------------------------------------------
# Alarmas
# ------------------------------------------
#
# Periodo de 60 segundos: los eventos del trail llegan con un par de
# minutos de delay, asi que un periodo largo solo agrega latencia sin
# agregar informacion. treat_missing_data = notBreaching para que la
# alarma no se quede pegada en ALARM cuando no hay eventos nuevos.
#
# evaluation_periods = 3 (no 1) por la latencia de entrega. El trail
# entrega en lotes (hasta ~15 minutos) y el metric filter publica la
# metrica ~2 minutos despues. Con evaluation_periods = 1 la alarma evalua
# el minuto anterior en el momento en que todavia no hay dato, y se
# pierde el evento: la metrica "SecurityGroupChanges" llego a 2 y la alarma
# nunca salio de OK (verificado el 2026-11-05).
#
# Con 3 periodos evaluados y datapoints_to_alarm = 1, la alarma dispara en
# el primer datapoint que breacha dentro de la ventana de 3 minutos: la
# latencia de entrega deja de ser una ventana por la que se escapa un
# evento.

resource "aws_cloudwatch_metric_alarm" "security_group_changed" {
  alarm_name          = "${var.project}-security-sg-changed"
  alarm_description   = "Cambio en el security group de la API: alguien abrio o cerro un puerto"
  namespace           = local.security_namespace
  metric_name         = "SecurityGroupChanges"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "console_login_failure" {
  alarm_name          = "${var.project}-security-console-login-failed"
  alarm_description   = "Login fallido en la consola de AWS: intento de acceso no autorizado"
  namespace           = local.security_namespace
  metric_name         = "ConsoleLoginFailures"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 1
  threshold           = 3
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "secret_read" {
  alarm_name          = "${var.project}-security-secret-read"
  alarm_description   = "Un secreto del proyecto fue leido por un principal que no es el rol de la app"
  namespace           = local.security_namespace
  metric_name         = "SecretReads"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "iam_credential_change" {
  alarm_name          = "${var.project}-security-iam-credential-change"
  alarm_description   = "Se creo o escalo una credencial de IAM en la cuenta"
  namespace           = local.security_namespace
  metric_name         = "IAMCredentialChanges"
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 3
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ==========================================
# GuardDuty: deteccion de amenazas administrada
# ==========================================
#
# GuardDuty no es un reemplazo de CloudTrail: CloudTrail dice "quien hizo
# que", GuardDuty dice "esto se parece a un ataque". Por ejemplo,
# GuardDuty detecta el uso de credenciales desde una IP que no es la de
# siempre; CloudTrail te dice quien las uso.
#
# Lo que se deja apagado a proposito:
#   - EKS runtime monitoring: el proyecto corre k3s, no EKS.
#   - S3 protection: los buckets no guardan datos de clientes.
#   - Malware protection: no hay archivos de usuario que escanear.

variable "enable_guardduty" {
  description = <<-EOT
    Crea el detector de GuardDuty. Esta cuenta (607856468834) responde
    SubscriptionRequiredException cuando se pide el detector: la cuenta no
    puede suscribirse todavia. La IaC queda lista y se activa poniendo
    true en terraform.tfvars (ver docs/security.md).
  EOT
  type        = bool
  default     = false
}

resource "aws_guardduty_detector" "this" {
  count = var.enable_guardduty ? 1 : 0

  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"

  tags = {
    Name = "${var.project}-guardduty"
  }
}

# ==========================================
# Password policy de la cuenta
# ==========================================
#
# La regla de Config IAM_PASSWORD_POLICY la exige. Antes de esto la cuenta
# no tenia ninguna, y el hallazgo era real: sin policy, un usuario IAM con
# acceso a consola puede tener una password de 6 caracteres que nunca caduca
# y se puede volver a usar.
#
# Los valores son los que la regla espera por default, con dos upgrades:
# 14 caracteres en vez de 12, y 24 passwords de historia en vez de 0.
#
# El MFA del usuario NO se puede manejar aca: el seed TOTP es una credencial
# y no puede vivir en un repositorio. El procedimiento esta en
# docs/security.md.

resource "aws_iam_account_password_policy" "this" {
  minimum_password_length        = 14
  require_numbers                = true
  require_symbols                = true
  require_uppercase_characters   = true
  require_lowercase_characters   = true
  allow_users_to_change_password = true
  # expire_passwords no se configura: el provider lo deriva de
  # max_password_age (con 90 dias, expira).
  max_password_age               = 90
  password_reuse_prevention      = 24
  hard_expiry                    = false
}

# GuardDuty publica la metrica GuardDutyFindings en el namespace
# AWS/GuardDuty cada vez que hay un hallazgo: la alarma es un termometro,
# el detalle se mira en la consola de GuardDuty.
resource "aws_cloudwatch_metric_alarm" "guardduty_findings" {
  alarm_name          = "${var.project}-security-guardduty-findings"
  alarm_description   = "GuardDuty detecto un hallazgo de seguridad"
  namespace           = "AWS/GuardDuty"
  metric_name         = "GuardDutyFindings"
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  datapoints_to_alarm = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alarms.arn]
  ok_actions    = [aws_sns_topic.alarms.arn]
}

# ==========================================
# Queries de investigacion (Logs Insights)
# ==========================================
#
# Son las preguntas que hay que poder responder con una query cuando algo
# anda raro. Es tambien lo que el runbook de fuga de credenciales cita
# como paso "verificar si hubo acceso no autorizado".

resource "aws_cloudwatch_query_definition" "audit_secret_reads" {
  name = "${var.project}/audit-lectura-de-secretos"

  log_group_names = [aws_cloudwatch_log_group.audit.name]

  query_string = <<-QUERY
    fields @timestamp, eventName, userIdentity.arn as principal, userIdentity.type as principal_type, requestParameters.secretId as secret, sourceIPAddress
    | filter eventName = "GetSecretValue"
    | sort @timestamp desc
    | limit 50
  QUERY
}

resource "aws_cloudwatch_query_definition" "audit_security_group" {
  name = "${var.project}/audit-cambios-de-sg"

  log_group_names = [aws_cloudwatch_log_group.audit.name]

  query_string = <<-QUERY
    fields @timestamp, eventName, userIdentity.arn as principal, sourceIPAddress, requestParameters
    | filter eventName in ["AuthorizeSecurityGroupIngress", "RevokeSecurityGroupIngress", "ModifySecurityGroup", "DeleteSecurityGroup"]
    | sort @timestamp desc
    | limit 50
  QUERY
}

resource "aws_cloudwatch_query_definition" "audit_console_login" {
  name = "${var.project}/audit-console-login"

  log_group_names = [aws_cloudwatch_log_group.audit.name]

  query_string = <<-QUERY
    fields @timestamp, eventName, userIdentity.arn as principal, sourceIPAddress, errorMessage, responseElements
    | filter eventName = "ConsoleLogin"
    | sort @timestamp desc
    | limit 50
  QUERY
}

# ==========================================
# Outputs
# ==========================================

output "cloudtrail_name" {
  value = aws_cloudtrail.audit.name
}

output "cloudtrail_bucket" {
  value = aws_s3_bucket.audit.id
}

output "audit_log_group" {
  value = aws_cloudwatch_log_group.audit.name
}

output "guardduty_detector_id" {
  # empty si el detector no esta habilitado (ver var.enable_guardduty).
  value = one(aws_guardduty_detector.this[*].id)
}
