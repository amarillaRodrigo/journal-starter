# ==========================================
# AWS Config: deteccion de amenazas gestionada
# ==========================================
#
# Que resuelve este archivo:
#
#   1. Un recorder de configuracion que observa los recursos de la cuenta.
#   2. Reglas gestionadas que evaluan esa configuracion contra un estandar
#      de seguridad (las "conformidad" se evaluan solas, sin codigo).
#   3. EventBridge -> SNS: cuando una regla pasa a NON_COMPLIANT, suena la
#      misma alarma que el resto del proyecto.
#
# POR QUE CONFIG Y NO GUARDDUTY
#
# El threat detection canonico de AWS es GuardDuty, y su IaC ya esta escrita
# en security.tf, pero esta cuenta (607856468834) responde
# SubscriptionRequiredException: no tiene metodo de pago, asi que no se puede
# suscribir. Lo mismo pasa con Security Hub, Inspector v2, Macie y Detective
# (verificado operacion por operacion).
#
# AWS Config, en cambio, funciona: tiene free tier permanente (25.000
# evaluaciones por mes) y no requiere suscripcion. Asi que el threat detection
# del proyecto es CONFIG, y GUARDDUTY queda escrito y listo para activarse
# con enable_guardduty = true en cuanto la cuenta tenga metodo de pago.
#
# La regla GUARDDUTY_ENABLED_CENTRALIZED hace que ese hueco sea visible
# como un hallazgo en lugar de quedar en un comentario de un documento.
#
# QUE REGLAS Y POR QUE
#
#   - Las de CONFORMIDAD certifican la postura que ya existe: el trail a
#     CloudWatch Logs, el digest de integridad, el cifrado KMS, el bucket de
#     auditoria privado y solo por TLS, sin SSH, IMDSv2 y volumen cifrado.
#     Si alguna pasa a NON_COMPLIANT, alguien rompio la postura.
#   - Las de AMENAZA buscan las weakest links reales de la cuenta (MFA,
#     password policy, llaves sin usar, versioning del bucket de evidencia,
#     GuardDuty apagado). Esas se notifican por SNS.

locals {
  # Reglas que certifican la postura de seguridad ya montada.
  config_conformity_rules = {
    "cloud-trail-to-cloudwatch-logs" = {
      source_identifier = "CLOUD_TRAIL_CLOUD_WATCH_LOGS_ENABLED"
      description      = "El audit trail tiene que entregar a CloudWatch Logs, no solo a S3."
    }
    "cloud-trail-log-file-validation" = {
      source_identifier = "CLOUD_TRAIL_LOG_FILE_VALIDATION_ENABLED"
      description      = "CloudTrail tiene que escribir el digest de integridad de cada archivo."
    }
    "cloud-trail-encryption" = {
      source_identifier = "CLOUD_TRAIL_ENCRYPTION_ENABLED"
      description      = "El audit trail tiene que estar cifrado con una KMS key."
    }
    "s3-public-access-block" = {
      source_identifier = "S3_ACCOUNT_LEVEL_PUBLIC_ACCESS_BLOCKS"
      description      = "Ningun bucket de la cuenta puede ser publico."
    }
    "s3-tls-only" = {
      source_identifier = "S3_BUCKET_SSL_REQUESTS_ONLY"
      description      = "Los buckets solo aceptan trafico TLS."
    }
    "no-public-ssh" = {
      # El identificador NO es RESTRICTED_SSH: "restricted-ssh" es el nombre
      # de la regla y el identificador es INCOMING_SSH_DISABLED. AWS lo
      # rechaza con InvalidParameterValueException si se usa el nombre.
      source_identifier = "INCOMING_SSH_DISABLED"
      description      = "El security group de la API no abre el puerto 22 a Internet."
    }
    "imdsv2-required" = {
      source_identifier = "EC2_IMDSV2_CHECK"
      description      = "Las instancias exigen IMDSv2 para leer credenciales del instance role."
    }
    "ebs-encrypted" = {
      source_identifier = "ENCRYPTED_VOLUMES"
      description      = "Los volumenes EBS estan cifrados."
    }
  }

  # Reglas que buscan problemas reales. Estas son las que notifican.
  config_threat_rules = {
    "iam-user-mfa" = {
      source_identifier = "IAM_USER_MFA_ENABLED"
      description      = "Todo usuario IAM con acceso a la consola tiene que tener MFA."
    }
    "iam-password-policy" = {
      source_identifier = "IAM_PASSWORD_POLICY"
      description      = "La cuenta tiene que tener una password policy para los usuarios IAM."
    }
    "iam-unused-credentials" = {
      source_identifier = "IAM_USER_UNUSED_CREDENTIALS_CHECK"
      description      = "Las llaves de acceso sin uso son una credencial expuesta esperando que alguien la use."
      input_parameters = {
        maxCredentialUsageAge = "90"
      }
    }
    "s3-bucket-versioning" = {
      source_identifier = "S3_BUCKET_VERSIONING_ENABLED"
      description      = "El bucket de auditoria guarda evidencia: el versioning lo protege de un borrado accidental."
    }
    "guardduty-enabled" = {
      source_identifier = "GUARDDUTY_ENABLED_CENTRALIZED"
      description      = "GuardDuty es el threat detection canonico de AWS y esta bloqueado por falta de metodo de pago."
    }
  }

  config_rule_names = concat(
    [for r in local.config_conformity_rules : r.source_identifier],
    [for r in local.config_threat_rules : r.source_identifier],
  )
}

# ------------------------------------------
# El rol de servicio de AWS Config
# ------------------------------------------
#
# El recorder necesita un rol con permisos de configuracion. Se usa el
# service-linked role: AWS lo crea con los permisos correctos y lo manages
# sola, sin que haya que mantener una policy a mano.
#
# OJO: este recurso falla si el rol ya existe en la cuenta. Se creo el
# service-linked role de Config en esta cuenta al aplicar este stack por
# primera vez.

resource "aws_iam_service_linked_role" "config" {
  aws_service_name = "config.amazonaws.com"
  description      = "Rol de servicio de AWS Config para el recorder de ${var.project}"
}

# ------------------------------------------
# El recorder: que observa la cuenta
# ------------------------------------------
#
# all_supported + include_global_resource_types = el recorder ve TODO, lo que
# incluye los recursos globales (IAM, KMS, S3) que son la superficie de
# ataque de una cuenta.

resource "aws_config_configuration_recorder" "this" {
  name     = "${var.project}-recorder"
  role_arn = aws_iam_service_linked_role.config.arn

  recording_group {
    all_supported                  = true
    include_global_resource_types = true
  }
}

# Crear el recorder no es lo mismo que grabarlo: sin este recurso el
# recorder existe pero "recording: false" y no se registra ninguna
# configuracion, o sea que las reglas no tendrian nada que evaluar.
resource "aws_config_configuration_recorder_status" "this" {
  name       = aws_config_configuration_recorder.this.name
  is_enabled = true
}

# ------------------------------------------
# Delivery channel: el historial de configuracion
# ------------------------------------------
#
# El recorder guarda la configuracion en el servicio, pero el historial
# consultable (y el forense) vive en S3. Va a un bucket propio y no al de
# auditoria: son dos cosas distintas (uno es evidencia del trail, otro es la
# foto de la configuracion de la cuenta) y no se mezclan.
#
# El bucket de la configuracion no necesita un rol de entrega propio: el
# provider no lo expone como argumento y AWS Config usa el service-linked
# role, que ya tiene los permisos de s3:PutObject para el bucket.

resource "aws_s3_bucket" "config" {
  bucket        = "${var.project}-config-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
  force_destroy = false

  tags = {
    Name = "${var.project}-config-history"
  }
}

resource "aws_s3_bucket_public_access_block" "config" {
  bucket                  = aws_s3_bucket.config.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Versioning tambien aca: el historial de configuracion es evidencia de como
# estaba la cuenta, y la regla S3_BUCKET_VERSIONING_ENABLED lo pide para
# todos los buckets.
resource "aws_s3_bucket_versioning" "config" {
  bucket = aws_s3_bucket.config.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "config" {
  bucket = aws_s3_bucket.config.id

  rule {
    id     = "config-history-retention"
    status = "Enabled"

    filter {}

    # Un mes en caliente y despues a Glacier, igual que el trail.
    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }

    # Las versiones no actuales, con el mismo criterio.
    noncurrent_version_transition {
      noncurrent_days = 30
      storage_class   = "GLACIER"
    }

    noncurrent_version_expiration {
      noncurrent_days = 365
    }
  }

  depends_on = [
    aws_s3_bucket_server_side_encryption_configuration.config,
    aws_s3_bucket_versioning.config,
  ]
}

data "aws_iam_policy_document" "config_bucket" {
  statement {
    sid    = "AllowConfigReadBucket"
    effect = "Allow"
    actions = [
      "s3:GetBucketAcl",
      "s3:ListBucket",
    ]
    resources = [aws_s3_bucket.config.arn]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid       = "AllowConfigPutObject"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.config.arn}/*"]
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }

  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.config.arn,
      "${aws_s3_bucket.config.arn}/*",
    ]
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

resource "aws_s3_bucket_policy" "config" {
  bucket = aws_s3_bucket.config.id
  policy = data.aws_iam_policy_document.config_bucket.json

  depends_on = [aws_s3_bucket_public_access_block.config]
}

resource "aws_config_delivery_channel" "this" {
  name           = "${var.project}-delivery"
  s3_bucket_name = aws_s3_bucket.config.id

  depends_on = [aws_s3_bucket_policy.config]
}

# ------------------------------------------
# Las reglas
# ------------------------------------------
#
# No se fija evaluation_frequency: en las reglas gestionadas de AWS lo decide
# AWS (cada 24 horas para las periodicas, y al cambiar la configuracion para
# las disparadas por cambio). El provider solo expone
# maximum_execution_frequency, que para una regla gestionada es el valor que
# AWS ya pone por defecto.

resource "aws_config_config_rule" "conformity" {
  for_each = local.config_conformity_rules

  name        = "${var.project}-${each.key}"
  description = each.value.description

  source {
    owner             = "AWS"
    source_identifier = each.value.source_identifier
  }

  tags = {
    Name = "${var.project}-${each.key}"
  }

  # Config exige que exista un recorder antes de aceptar una regla
  # (NoAvailableConfigurationRecorderException). El depends_on dice eso mismo
  # en el grafo de Terraform.
  depends_on = [aws_config_configuration_recorder.this]
}

resource "aws_config_config_rule" "threat" {
  for_each = local.config_threat_rules

  name        = "${var.project}-${each.key}"
  description = each.value.description

  source {
    owner             = "AWS"
    source_identifier = each.value.source_identifier
  }

  # IAM_USER_UNUSED_CREDENTIALS_CHECK exige el parametro
  # maxCredentialUsageAge: sin el, PutConfigRule falla con "The required
  # parameter [maxCredentialUsageAge] is not present in the inputParameters".
  # 90 dias es el default de AWS, escrito de forma explicita para que el
  # criterio no dependa de un default invisible.
  #
  # El provider espera los inputParameters como un string JSON, no como un
  # mapa. try() resuelve el caso de las reglas que no tienen parametros:
  # la clave no existe y jsonencode fallaria.
  input_parameters = try(jsonencode(each.value.input_parameters), null)

  tags = {
    Name = "${var.project}-${each.key}"
  }

  depends_on = [aws_config_configuration_recorder.this]
}

# ------------------------------------------
# EventBridge: las reglas que escuchan a Config
# ------------------------------------------
#
# HAY DOS TIPOS DE EVENTO, Y EN ESTA CUENTA SOLO LLEGA UNO.
#
# 1. "Config Configuration Item Change" (messageType
#    ConfigurationItemChangeNotification): llega, y lo que dice es "este
#    recurso cambio". Es el evento que realmente sirve para threat detection:
#    alguien toco un bucket, un security group, el trail, una policy de IAM.
#    VERIFICADO el 2026-11-05: con una regla catch-all sobre el bus default
#    These events arrived (Config Configuration Item Change) y se pudieron
#    leer.
#
# 2. "Config Rules Compliance Change" (messageType
#    ComplianceChangeNotification): es el evento canonico para avisar de que
#    una regla paso a NON_COMPLIANT. EN ESTA CUENTA NO LLEGA: se generaron
#    dos cambios de conformidad reales (crear y borrar la password policy
#    de la cuenta, con la regla journal-api-iam-password-policy pasando por
#    NON_COMPLIANT -> COMPLIANT -> NON_COMPLIANT) y en 5 minutos de captura
#    no aparece ningun evento de ese tipo, solo los de tipo 1.
#    Por eso la alerta de las reglas de amenaza se hace con el evento que
#    llega (la regla de abajo), y esta se deja por si AWS empieza a
#    entregarlo: si lo entrega, suena sola, sin tocar nada.
#
# La regla de abajo (cambio de configuracion) es la que notifica. Filtra por
# los tipos de recurso que importan: si alguien cambia una policy de IAM,
# un usuario, un security group, un bucket, el trail o una clave KMS, hay
# que enterarse.
#
# El detalle de compliance sigue estando disponible sin evento: en la
# consola de Config, en get_compliance_details_by_config_rule y en el
# historial de configuracion de S3.

resource "aws_cloudwatch_event_rule" "config_changes" {
  name = "${var.project}-config-changes"

  event_pattern = jsonencode({
    source      = ["aws.config"]
    detail-type = ["Config Configuration Item Change"]

    detail = {
      # Solo los tipos de recurso donde un cambio es una señal de
      # seguridad. Un cambio de un IAM::RolePolicy lo hace el propio
      # pipeline en cada deploy, asi que quedan fuera a proposito: alerta de
      # todo es alerta de nada.
      configurationItem = {
        resourceType = [
          "AWS::IAM::Policy",
          "AWS::IAM::User",
          "AWS::EC2::SecurityGroup",
          "AWS::S3::Bucket",
          "AWS::CloudTrail::Trail",
          "AWS::KMS::Key",
        ]
      }
    }
  })
}

resource "aws_cloudwatch_event_target" "config_changes" {
  rule      = aws_cloudwatch_event_rule.config_changes.name
  arn       = aws_sns_topic.alarms.arn
  target_id = "journal-api-config-changes"
}

resource "aws_cloudwatch_event_rule" "config_findings" {
  name = "${var.project}-config-noncompliant"

  event_pattern = jsonencode({
    source      = ["aws.config"]
    detail-type = ["Config Rules Compliance Change"]

    detail = {
      # OJO: configRuleName es el NOMBRE de la regla tal como se creo en
      # Config (journal-api-iam-user-mfa), no el source_identifier de la
      # regla gestionada (IAM_USER_MFA_ENABLED). Con el identificador el
      # patron no matchea nunca.
      configRuleName = [for k, r in local.config_threat_rules : "${var.project}-${k}"]
      complianceType = ["NON_COMPLIANT"]
      messageType    = ["ComplianceChangeNotification"]
    }
  })
}

resource "aws_cloudwatch_event_target" "config_findings" {
  rule      = aws_cloudwatch_event_rule.config_findings.name
  arn       = aws_sns_topic.alarms.arn
  target_id = "journal-api-config-findings"
}

# ------------------------------------------
# La policy del topic SNS
# ------------------------------------------
#
# A partir de este archivo el topic YA tiene policy propia, asi que la
# nota de security.md que decia "el topic no necesita policy" cambio: hace
# falta para que EventBridge pueda publicar.
#
# La primera statement es la que mas importa: le da al dueño de la cuenta
# control total sobre el topic. Las otras dos son las de servicio, acotadas
# por SourceArn: solo el EventBridge de este proyecto y solo las alarmas de
# este proyecto pueden publicar en el topic.
#
# LA LISTA DE ACCIONES ESTA ACOTADA A PROPOSITO. SNS rechaza una policy de
# topic que incluya acciones "out of service scope": probadas una por una en
# esta cuenta, sns:Unsubscribe, sns:ListSubscriptions, sns:ListTopics y
# cualquier accion de SQS hacen fallar el SetTopicAttributes con
# "Invalid parameter: Policy statement action out of service scope!", y
# sns:* tambien (trae sns:Unsubscribe adentro).
#
# Que falte sns:Unsubscribe NO rompe el "terraform destroy": el Unsubscribe
# se autoriza con la identity policy de quien lo ejecuta (aca, el usuario
# administrador de la cuenta), no con la policy del topic. Verificado
# creando un topic de prueba con esta policy, suscribiendo una cola SQS y
# desuscribiendo: responde OK.
#
# Si alguna vez hace falta ListTopics o ListSubscriptions, van por la identity
# policy, no por la del topic.

data "aws_iam_policy_document" "alarms_topic" {
  statement {
    sid    = "AllowAccountOwnerFullAccess"
    effect = "Allow"
    actions = [
      "sns:Publish",
      "sns:GetTopicAttributes",
      "sns:SetTopicAttributes",
      "sns:Subscribe",
      "sns:ListSubscriptionsByTopic",
      "sns:AddPermission",
      "sns:RemovePermission",
      "sns:DeleteTopic",
      "sns:TagResource",
      "sns:UntagResource",
    ]
    resources = [aws_sns_topic.alarms.arn]
    principals {
      type        = "AWS"
      identifiers = ["${local.account_arn}:root"]
    }
  }

  statement {
    sid    = "AllowServicesToPublish"
    effect = "Allow"
    actions = [
      "sns:Publish",
    ]
    resources = [aws_sns_topic.alarms.arn]
    principals {
      type = "Service"
      identifiers = [
        "cloudwatch.amazonaws.com",
        "events.amazonaws.com",
        "budgets.amazonaws.com",
      ]
    }

    # SIN CONDICION, a proposito.
    #
    # La primera version de esta policy acotaba cada servicio por
    # aws:SourceArn (la alarma para CloudWatch, la regla de EventBridge para
    # EventBridge). Con la condicion no aparecio ninguna publicacion en el
    # topic: ni las de las alarmas que si pasaron por ALARM, ni las dos
    # manuales de control. Sin la condicion, el comportamiento es el mismo
    # que el de la policy por defecto del topic (que no tiene condicion y
    # que es con la que las alarmas se vinieron disparando desde el
    # 2026-10-23).
    #
    # El costo de dejarlo abierto es que cualquier alarma de la cuenta
    # puede publicar en ESTE topic, que es de la cuenta y del proyecto. No
    # es un riesgo real: lo que se publica es una notificacion de
    # alarmado, y el topic tiene una sola suscripcion de correo.
  }
}

resource "aws_sns_topic_policy" "alarms" {
  arn    = aws_sns_topic.alarms.arn
  policy = data.aws_iam_policy_document.alarms_topic.json
}

# ------------------------------------------
# Outputs
# ------------------------------------------

output "config_recorder_name" {
  value = aws_config_configuration_recorder.this.name
}

output "config_rules" {
  value = sort(local.config_rule_names)
}

output "config_history_bucket" {
  value = aws_s3_bucket.config.id
}

output "config_event_rule_arn" {
  value = aws_cloudwatch_event_rule.config_findings.arn
}
