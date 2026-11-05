# Seguridad del plano de control: auditoría, detección y alertas

Documento de referencia del bloque *Monitoring & Incident Response* del
currículum. Cubre lo que está desplegado en la cuenta `607856468834`
(us-east-1), cómo se verifica y qué se decidió **no** construir.

Complementa —no reemplaza— [incident-response.md](incident-response.md) (el
procedimiento paso a paso ante una fuga de credenciales),
[runbook.md](runbook.md) (el troubleshooting operativo) y
[observability.md](observability.md) (las métricas de la aplicación).

---

## 1. Qué hay desplegado

| Control | Recurso | Qué resuelve |
|---|---|---|
| Audit trail | `aws_cloudtrail.audit` | Quién hizo qué en la cuenta |
| Archivo durable | `aws_s3_bucket.audit` + KMS | Evidencia que sobrevive, con digest de integridad |
| Copia consultable | `aws_cloudwatch_log_group.audit` | Logs Insights sin bajar el bucket |
| Alertas de seguridad | 13 metric filters + 4 alarmas sobre el trail | Reacción ante eventos sospechosos |
| Detección de amenazas | `aws_config_config_rule` (13 reglas) | Evalúa la postura de la cuenta contra un estándar (§4) |
| Alerta de cambios de configuración | `aws_cloudwatch_event_rule.config_changes` | Alguien tocó un bucket, un SG, el trail o una policy de IAM (§4) |
| Detección de amenazas canónica | `aws_guardduty_detector.this` | Patrones de ataque: **bloqueada por la cuenta** (§7) |
| Análisis estático | `.github/workflows/codeql.yml` | Flujos de datos inseguros en Python (§5) |
| Actualizaciones de dependencias | `.github/dependabot.yml` | Actions y dependencias de Python al día |

La IaC vive en `terraform/security.tf` (audit trail y alarmas) y
`terraform/config.tf` (detección de amenazas). CodeQL y Dependabot son
workflows de GitHub.

---

## 2. El audit trail

```
CloudTrail ──┬──▶ S3 (journal-api-audit-607856468834-us-east-1)  [KMS + Glacier + 365 días]
             │         └── digest de integridad (enable_log_file_validation)
             └──▶ CloudWatch Logs (aws-cloudtrail-logs-journal-api)  [30 días]
```

Decisiones y su porqué:

- **Regional en us-east-1, no multi-región.** El proyecto es single-región.
- **`include_global_service_events = true`.** Los eventos de IAM y STS son
  *globales* y **solo** se registran en us-east-1. Sin esto, la mitad del
  audit trail no existiría: ni los cambios de permisos ni los AssumeRole.
- **SSE-KMS con rotación de clave**, no SSE-S3. El trail es evidencia de
  auditoría: si alguien puede leerlo sin dejar rastro, no sirve como
  evidencia. La key policy permite `GenerateDataKey*` solo a
  `cloudtrail.amazonaws.com` y solo para este trail (`aws:SourceArn`).
- **`enable_log_file_validation = true`.** CloudTrail escribe un digest de
  cada archivo. Si alguien edita el trail en S3, el digest no cuadra.
- **Doble copia a propósito.** S3 es el archivo (barato, durable, 30 días en
  caliente y después Glacier). CloudWatch Logs es lo que se consulta en 10
  segundos cuando hay que responder una pregunta.

### Tres requisitos de la API que no son opcionales

Todos fallan **sin error visible** (el trail queda logging y no graba nada):

1. **El ARN del log group necesita el sufijo `:*`**
   (`arn:aws:logs:...:log-group:NAME:*`). Sin él:
   `InvalidCloudWatchLogsLogGroupArnException`.
2. **La bucket policy necesita la condición
   `s3:x-amz-acl = bucket-owner-full-control`** y el permiso
   `s3:GetBucketAcl`. Sin ellos: `InsufficientS3BucketPolicyException`.
3. **El bucket no puede tener ACLs deshabilitadas.** CloudTrail escribe
   cada archivo con el header `x-amz-acl: bucket-owner-full-control`, y con
   `ObjectOwnership = BucketOwnerEnforced` (el default de S3 desde abril de
   2023) ese header hace fallar el PUT. El trail queda logging, sin
   errores, y **sin un solo archivo en S3**. Por eso el bucket va en
   `BucketOwnerPreferred`.

   El resto de la postura no cambia: Block Public Access, sin acceso
   público, cifrado con KMS y denegación de tráfico sin TLS.

### El formato de los patrones de los metric filters

Un metric filter normalmente se escribe en JSON para preguntar por un campo
(`{"$.eventName": [...]}`). **Ese formato no lo acepta la API de CloudWatch
Logs en esta cuenta**: responde `InvalidParameterException` con
`Invalid character(s) in term ':'`. Tampoco acepta regex (`%...%`). Solo
patrones simples.

Un patrón simple busca el término en el **texto crudo** del evento, y eso
tiene dos trampas:

1. **El patrón viaja dentro del request del API.** El evento
   `PutMetricFilter` que crea el filtro contiene el patrón, así que el
   filtro se cuenta a sí mismo.
2. **Con el OR (`?A ?B`) las propias queries de investigación contaban.**
   Un `StartQuery` que busca `AuthorizeSecurityGroupIngress` queda
   registrado como un evento que contiene ese texto.

Una alarma que se dispara porque la estás investigando no es una alarma.

**La solución: anclar el patrón con el `eventSource`.** Cada servicio tiene
el suyo, y las queries de investigación no lo mencionan:

```
"AuthorizeSecurityGroupIngress" "ec2.amazonaws.com"
```

Con AND, el patrón solo matchea el evento de CloudTrail de ese tipo: un
`StartQuery` o un `PutMetricFilter` son de `logs.amazonaws.com` y quedan
afuera. Y como el AND no se puede combinar con el OR de `?`, hay **un
metric filter por evento**: cada evento lo cuenta su filtro y solo el suyo,
así que la métrica no se infla.

**Verificado** (matriz de 9 casos con `TestMetricFilter`): cada patrón
matchea su evento y nada más —incluido el caso "query que menciona el
nombre del evento", que ya no matchea.

**Ruido conocido:** cada vez que se crea o modifica uno de los 13 filtros,
el evento `PutMetricFilter` se cuenta a sí mismo y la alarma dispara una
vez. Es ruido de setup, no un incidente.

### Por qué no EventBridge para el trail (y lo que se corrigió)

Lo canónico en AWS sería EventBridge: una regla con patrón JSON sobre
`detail.eventName` y un target SNS.

La primera versión de este proyecto descartó esa opción porque, con cuatro
reglas de EventBridge sobre `detail.eventName`, las métricas
(`TriggeredRules`, `Invocations`) nunca aparecieron, y con la alarma de
security group yendo a `ALARM` tampoco se notificó nada.

**Esa limitación NO se reproduce.** El 2026-11-05 se puso una regla
catch-all sobre el bus default (`{"source": [{"prefix": "aws."}]}`)
apuntando a un topic de prueba, y en 5 minutos se capturaron **106
eventos**, de los cuales **101 eran `AWS API Call via CloudTrail`**
(`source: aws.sts`, `aws.ec2`, ...) y 4 eran
`Config Configuration Item Change`. O sea: **CloudTrail sí entrega a
EventBridge en esta cuenta.**

Los avisos del trail siguen siendo metric filters, por dos razones
prácticas: ya están verificados end-to-end (la alarma de security group se
disparó y el trail tiene los eventos), y los metric filters se pueden
anclar al `eventSource` para que no se auto-alimenten. Migrar a
EventBridge sería rehacer algo que funciona, y queda documentado como
mejora posible, no como bloqueo.

> La diferencia real con los metric filters: el patrón de EventBridge
> matchea por campo y por lo tanto no tiene el problema de auto-alimentación
> que tienen los filtros de texto. Los 13 filtros de texto existen
> justamente porque la API de CloudWatch Logs de esta cuenta no acepta
> patrones JSON ni regex (§2).

> **Ojo, esto NO aplica a AWS Config.** Los eventos de Config sí llegan a
> EventBridge: es otro servicio, con otro camino. La cadena
> Config → EventBridge → SNS está verificada (§4).

---

## 3. Las cuatro alarmas de seguridad

| Alarma | Evento que la dispara | Por qué |
|---|---|---|
| `journal-api-security-sg-changed` | `AuthorizeSecurityGroupIngress`, `RevokeSecurityGroupIngress`, `ModifySecurityGroup`, `ModifySecurityGroupRules`, `DeleteSecurityGroup` | Alguien abre, cierra o borra un puerto de la API. Es el ataque clásico sobre un SG con `0.0.0.0/0`. |
| `journal-api-security-console-login-failed` | `ConsoleLogin` con `errorMessage: "Failed authentication"` | La API no tiene autenticación y el 22 está cerrado: el único "login" de esta cuenta es el de la consola de AWS. |
| `journal-api-security-secret-read` | `GetSecretValue` con `userIdentity.type = IAMUser` | Las lecturas legítimas son del rol de la app y del de la instancia, y los dos son `AssumedRole`. Una access key filtrada o un humano en la consola son `IAMUser`. |
| `journal-api-security-iam-credential-change` | `CreateAccessKey`, `CreateUser`, `CreateLoginProfile`, `AttachUserPolicy`, `PutUserPolicy`, `UpdateAssumeRolePolicy` | Escalamiento de privilegios: alguien se crea un acceso nuevo. |

Una quinta alarma, `journal-api-security-guardduty-findings`, sale de la
métrica que publica GuardDuty. Hoy queda en `OK` para siempre, porque el
detector no se puede crear (§7).

Todas notifican al topic SNS `journal-api-alarms`: **un solo canal, un solo
correo**.

> **Lo que no se vigila, a propósito:** cada `Describe*` y cada `List*` que
> hace cualquier servicio. Alerta de todo es alerta de nada.

### La latencia de entrega obliga a `evaluation_periods = 3`

Las cuatro alarmas evalúan **3 periodos de 60 segundos** y disparan con
**1** datapoint que breacha (`datapoints_to_alarm = 1`), no con 1 periodo.

No es arbitrario. Medido el 2026-11-05: el evento de CloudTrail llega al
log group ~2 minutos después de la llamada a la API, y el metric filter
publica la métrica para ese minuto un poco después. Con
`evaluation_periods = 1` la alarma evalúa el minuto anterior **en el
momento en que todavía no hay dato** y el evento se pierde: en la primera
prueba la métrica `SecurityGroupChanges` llegó a 2 y la alarma nunca salió
de `OK`.

Con 3 periodos evaluados y `datapoints_to_alarm = 1`, la alarma dispara en
el primer datapoint que breacha dentro de la ventana de 3 minutos: la
latencia de entrega deja de ser una ventana por la que se escapa un
evento. Con el cambio, la alarma disparó en las dos pruebas
(`OK → ALARM` a las 08:40:19 y a las 08:58:43).

### El topic SNS ahora tiene policy propia

Antes no la tenía: la policy por defecto de un topic SNS ya viene acotada
al dueño de la cuenta (`Condition: AWS:SourceOwner`). Ahora hace falta
porque **EventBridge tiene que poder publicar** en el topic (§4).

La policy tiene dos statements:

| Statement | Principal | Para qué |
|---|---|---|
| `AllowAccountOwnerFullAccess` | `arn:aws:iam::607856468834:root` | Control total del dueño (incluye `sns:Subscribe`, `sns:DeleteTopic`) |
| `AllowServicesToPublish` | `cloudwatch.amazonaws.com`, `events.amazonaws.com` | Que las alarmas y los eventos de Config publiquen |

**La lista de acciones está acotada a propósito.** SNS rechaza una policy
de topic que incluya acciones "out of service scope". Probadas una por una
en esta cuenta:

| Acción | ¿Aceptada por SNS? |
|---|---|
| `sns:Publish`, `sns:GetTopicAttributes`, `sns:SetTopicAttributes`, `sns:Subscribe`, `sns:ListSubscriptionsByTopic`, `sns:AddPermission`, `sns:RemovePermission`, `sns:DeleteTopic`, `sns:TagResource`, `sns:UntagResource` | ✅ |
| `sns:Unsubscribe`, `sns:ListSubscriptions`, `sns:ListTopics` | ❌ `Invalid parameter: Policy statement action out of service scope!` |
| `sns:*` | ❌ (trae `sns:Unsubscribe` adentro) |
| `sqs:SendMessage`, `sqs:ReceiveMessage` | ❌ |

Que falte `sns:Unsubscribe` **no rompe el `terraform destroy`**: el
Unsubscribe se autoriza con la *identity policy* de quien lo ejecuta (aca,
el usuario administrador de la cuenta), no con la policy del topic.
Verificado creando un topic de prueba con esta policy, suscribiendo una cola
SQS y desuscribiendo: responde OK.

**El statement de los servicios no tiene condición, a propósito.** La
primera versión acotaba cada servicio por `aws:SourceArn` (la alarma para
CloudWatch, la regla de EventBridge para EventBridge). Con la condición no
apareció ninguna publicación en el topic: ni las de las alarmas que sí
pasaron por `ALARM`, ni dos publicaciones manuales de control. Sin
condición, el comportamiento es el mismo que el de la policy por defecto
del topic (que no tiene condición y con la que las alarmas se vinieron
disparando desde el 2026-10-23).

El costo de dejarlo abierto es que cualquier alarma de la cuenta puede
publicar en **este** topic, que es del proyecto y tiene una sola
suscripción de correo. No es un riesgo real: lo que se publica es una
notificación de alarmado.

---

## 4. AWS Config: la detección de amenazas que sí funciona

### Por qué Config y no GuardDuty

El threat detection canónico de AWS es GuardDuty, y su IaC ya está escrita
en `security.tf`, pero esta cuenta (607856468834) responde
`SubscriptionRequiredException` a todos los servicios de seguridad con
precio por uso. Verificado operación por operación:

| Servicio | Respuesta en esta cuenta |
|---|---|
| GuardDuty | ❌ `SubscriptionRequiredException` |
| Security Hub | ❌ `SubscriptionRequiredException` |
| Inspector v2 | ❌ `SubscriptionRequiredException` |
| Macie | ❌ `SubscriptionRequiredException` |
| Detective | ❌ `SubscriptionRequiredException` |
| **AWS Config** | ✅ funciona (free tier de 25.000 evaluaciones/mes, sin suscripción) |
| **IAM Access Analyzer** | ✅ funciona |

La causa habitual es que la cuenta **no tiene método de pago activo**.

AWS Config no es un reemplazo de GuardDuty: Config evalúa la *postura*
(¿la configuración cumple un estándar?), GuardDuty detecta *patrones de
ataque* en el tráfico de API. Para un proyecto como este, donde el riesgo
es que alguien toque el security group o lea un secreto, Config cubre el
ground que importa, y las cuatro alarmas del trail cubren el resto.

La regla `GUARDDUTY_ENABLED_CENTRALIZED` deja el hueco visible como un
hallazgo, en lugar de dejarlo en un comentario de un documento.

### Lo que hay desplegado

```
aws_config_configuration_recorder.journal-api-recorder   [recording: true]
aws_config_delivery_channel.journal-api-delivery  ->  s3://journal-api-config-607856468834-us-east-1
13 reglas gestionadas de AWS
aws_cloudwatch_event_rule.journal-api-config-noncompliant  ->  SNS journal-api-alarms
```

El recorder observa **todos** los recursos, incluidos los globales
(`include_global_resource_types = true`), que son la superficie de ataque de
una cuenta: IAM, KMS, S3.

El historial de configuración va a un bucket **propio**
(`journal-api-config-607856468834-us-east-1`), no al de auditoría: uno es
la foto de la configuración de la cuenta, el otro es la evidencia del trail.
Son cosas distintas y no se mezclan.

### Las 13 reglas

**Conformidad (8): certifican la postura que ya existe.** Si alguna pasa a
`NON_COMPLIANT`, alguien rompió la postura. No notifican por SNS: están
visibles en la consola de Config y en el historial de S3.

| Regla | Identificador | Verifica |
|---|---|---|
| `journal-api-cloud-trail-to-cloudwatch-logs` | `CLOUD_TRAIL_CLOUD_WATCH_LOGS_ENABLED` | El trail entrega a CloudWatch Logs, no solo a S3 |
| `journal-api-cloud-trail-log-file-validation` | `CLOUD_TRAIL_LOG_FILE_VALIDATION_ENABLED` | Se escribe el digest de integridad |
| `journal-api-cloud-trail-encryption` | `CLOUD_TRAIL_ENCRYPTION_ENABLED` | El trail está cifrado con KMS |
| `journal-api-s3-public-access-block` | `S3_ACCOUNT_LEVEL_PUBLIC_ACCESS_BLOCKS` | Ningún bucket es público |
| `journal-api-s3-tls-only` | `S3_BUCKET_SSL_REQUESTS_ONLY` | Los buckets solo aceptan TLS |
| `journal-api-no-public-ssh` | `INCOMING_SSH_DISABLED` | El SG de la API no abre el 22 a Internet |
| `journal-api-imdsv2-required` | `EC2_IMDSV2_CHECK` | Las instancias exigen IMDSv2 |
| `journal-api-ebs-encrypted` | `ENCRYPTED_VOLUMES` | Los volúmenes EBS están cifrados |

**Amenaza (5): buscan problemas reales.** Estas son las que notifican.

| Regla | Identificador | Qué busca |
|---|---|---|
| `journal-api-iam-user-mfa` | `IAM_USER_MFA_ENABLED` | Usuarios IAM con acceso a consola sin MFA |
| `journal-api-iam-password-policy` | `IAM_PASSWORD_POLICY` | La cuenta sin password policy |
| `journal-api-iam-unused-credentials` | `IAM_USER_UNUSED_CREDENTIALS_CHECK` | Llaves de acceso sin usar: una credencial expuesta esperando que alguien la use |
| `journal-api-s3-bucket-versioning` | `S3_BUCKET_VERSIONING_ENABLED` | El bucket de evidencia sin versioning |
| `journal-api-guardduty-enabled` | `GUARDDUTY_ENABLED_CENTRALIZED` | El threat detection canónico apagado |

### La cadena hasta el correo

`Config → EventBridge → SNS → correo`.

Hay **dos** tipos de evento de Config, y en esta cuenta **solo llega uno**:

| Evento | ¿Llega? | Qué dice |
|---|---|---|
| `Config Configuration Item Change` | ✅ sí | "Este recurso cambió". Con el `resourceType` y el diff de la configuración. |
| `Config Rules Compliance Change` | ❌ no | "Esta regla pasó a NON_COMPLIANT". |

**Verificado el 2026-11-05**: se generaron dos cambios de conformidad
reales (crear y borrar la password policy de la cuenta, con la regla
`journal-api-iam-password-policy` pasando por NON_COMPLIANT → COMPLIANT →
NON_COMPLIANT) y, con una regla catch-all sobre el bus default, en 5
minutos de captura **no apareció ningún evento del segundo tipo**: solo
`Config Configuration Item Change`.

Por eso hay dos reglas de EventBridge, y solo una notifica:

**1. `journal-api-config-changes` (la que notifica).** El evento que llega
sí sirve para threat detection: alguien tocó un bucket, un security group,
el trail, una policy de IAM o una clave KMS.

```json
{
  "source": ["aws.config"],
  "detail-type": ["Config Configuration Item Change"],
  "detail": {
    "configurationItem": {
      "resourceType": ["AWS::IAM::Policy", "AWS::IAM::User", "AWS::EC2::SecurityGroup",
                       "AWS::S3::Bucket", "AWS::CloudTrail::Trail", "AWS::KMS::Key"]
    }
  }
}
```

Los tipos de recurso están acotados a propósito: un cambio de un
`AWS::IAM::RolePolicy` lo hace el propio pipeline en cada deploy, y
alerta de todo es alerta de nada.

**2. `journal-api-config-noncompliant` (dormida).** Es el patrón canónico
para avisar de que una regla pasó a `NON_COMPLIANT`. Se deja written y
funcionando: si AWS empieza a entregarlo en esta cuenta, suena sola, sin
tocar nada. Hoy no matchea nada.

```json
{
  "source": ["aws.config"],
  "detail-type": ["Config Rules Compliance Change"],
  "detail": {
    "configRuleName": ["journal-api-iam-user-mfa", "journal-api-iam-password-policy",
                       "journal-api-iam-unused-credentials", "journal-api-s3-bucket-versioning",
                       "journal-api-guardduty-enabled"],
    "complianceType": ["NON_COMPLIANT"],
    "messageType": ["ComplianceChangeNotification"]
  }
}
```

Tres filtros, cada uno con un motivo:

- **`complianceType = NON_COMPLIANT`**: solo el pasaje a "no conforme". Si
  también se filtrara `COMPLIANT`, cada vez que alguien arregla un
  problema llegaría otro aviso, y el aviso de "ya está arreglado" no sirve
  para responder un incidente.
- **`messageType = ComplianceChangeNotification`**: el aviso llega cuando
  cambia el estado, no en cada evaluación periódica.
- **Solo las 5 reglas de amenaza**: certificar la postura no es un
  incidente. Si una regla de conformidad pasa a `NON_COMPLIANT`, se ve en la
  consola de Config y en el historial de S3, pero no llega un correo.

> **`configRuleName` es el NOMBRE de la regla, no el identificador de la
> fuente.** El nombre es `journal-api-iam-user-mfa`; el identificador de la
> regla gestionada es `IAM_USER_MFA_ENABLED`. Con el identificador, el
> patrón no matchea nunca y la cadena no suena. Este bug pasó en la
> primera versión de `config.tf` y se detectó verificando el patrón contra
> eventos reales con `TestEventPattern`.

El estado de conformidad sigue consultable sin evento, que es lo que
importa para responder "how do we check for unauthorized access":

```bash
aws config get-compliance-details-by-config-rule --config-rule-name journal-api-iam-user-mfa
aws config get-compliance-summary-by-config-rule
```

### Lo que encontró (verificado el 2026-11-05)

| Regla | Estado | Detalle |
|---|---|---|
| `journal-api-iam-password-policy` | **NON_COMPLIANT** | La cuenta `607856468834` no tiene password policy para los usuarios IAM |
| `journal-api-iam-user-mfa` | **NON_COMPLIANT** | El usuario `rodri-dev` no tiene MFA |
| `journal-api-iam-unused-credentials` | COMPLIANT | Las dos llaves de `rodri-dev` no tienen `LastUsedDate`: nunca se usaron, así que no cuentan como "sin usar por más de 90 días" |
| Las 7 reglas de conformidad | COMPLIANT | Certifican la postura de seguridad |

Los dos hallazgos son reales y quedan como **riesgo aceptado y documentado**
(§7): un usuario administrador sin MFA es el incidente de credenciales más
probable de esta cuenta, y el mismo usuario es el que administra el
proyecto. Arreglarlos requiere una tarjeta de identidad y una decisión sobre
cómo se accede a la consola, que excede el alcance de un capstone.

---

## 5. Análisis estático: CodeQL

### Qué es y qué no es

CodeQL es el motor de análisis de seguridad de GitHub: no es un linter.
`ruff` ve estilo y errores (`F401`, imports sin usar); CodeQL ve **flujos
de datos inseguros**: una consulta que llega a una consulta SQL sin
parametrizar, un comando con `shell=True`, un `eval` sobre dato externo, un
secreto que se escribe en un archivo o se imprime en un log.

El análisis corre en `.github/workflows/codeql.yml`, que es el **advanced
setup**: el workflow queda versionado en el repo, así que se puede editar
(por ejemplo, para pasar a `security-extended`) sin volver a la consola. En
un repositorio público no cuesta nada.

### Dónde corre, y por qué

El workflow está commiteado en **los dos** repositorios:

| Repo | Estado |
|---|---|
| `amarillaRodrigo/journal-starter` (el fork) | El workflow está, pero **Actions no corre**: el repo padre `learntocloud/journal-starter` tiene Actions deshabilitado y el fork lo hereda. `POST /actions/workflows/{id}/dispatches` responde `HTTP 422: Actions has been disabled for this repository`, aunque `GET /actions/permissions` devuelva `enabled: true`. |
| `amarillaRodrigo/journal-starter-pipeline` (el repo donde corre el pipeline) | Corre, y es donde están los resultados. |

Que el fork no pueda ejecutar Actions no es una limitación del fork: es que
el repositorio de origen del que se hizo el fork tiene Actions deshabilitado
a nivel de organización, y eso no lo revierte el owner del fork. Por eso el
pipeline entero (CI, verify-capstone, CodeQL) vive en el repo espejo.

### Los hallazgos

El primer análisis encontró **2 alertas de severidad alta** en
`scripts/fetch_secrets.py`. Las dos fueron triadas y **descartadas con
motivo**, no se las dejó abiertas:

| # | Regla | Ubicación | Triaje | Motivo |
|---|---|---|---|---|
| 1 | `py/clear-text-storage-sensitive-data` | `scripts/fetch_secrets.py:110` | `mitigated` | Es el diseño del proyecto: el init container baja los secretos a un `emptyDir` con permisos `0600`. La alternativa (un Secret de Kubernetes) es **peor**: vive en etcd en base64 y lo lee cualquiera con `get pods`. El repo migró para acá justamente por eso, y `scripts/verify-security.sh` comprueba en cada deploy que los permisos sean `0600` y que no quede nada en etcd. |
| 2 | `py/clear-text-logging-sensitive-data` | `scripts/fetch_secrets.py:132` | `false positive` | La línea imprime `f"secretos descargados: {written} valores en {directory}"`: un **contador** y el **directorio**. Ningún valor de secreto. El taint llega por `written`, un entero que se incrementa dentro del loop sobre los valores del secreto. |

El motivo del descarte queda visible en el comentario del descarte, en la
pestaña *Security → Code scanning*. El detalle largo está acá.

> **Por qué no se "arregló" el código:** agregar un comentario o cambiar el
> código alrededor de esas líneas mueve los números de línea, y GitHub
> trata un alerta con otra ubicación como un alerta **nuevo**: el descarte
> no arrastra y aparecen dos alertas abiertas nuevas. La decisión de diseño
> se documenta en el descarte y acá, no metiendo ruido en el código.

### Actualizaciones de dependencias

`.github/dependabot.yml` cubre dos ecosystems:

- `github-actions`: las actions de los workflows. Una action desactualizada
  es una action con un CVE sin parchear, y el pipeline corre con permisos
  `id-token: write`.
- `uv`: las dependencias de Python. El ecosystem correcto es `uv` y no
  `pip` a propósito, porque el CI corre `uv sync --locked`: si Dependabot
  actualizara solo `pyproject.toml`, el lock quedaría atrás y el CI
  fallaría.

Al publicar la configuración, Dependabot abrió 4 PRs (2 de actions, 2 de
`uv`) y el CI los corrió en verde.

---

## 6. Cómo investigar

Las queries están guardadas en Terraform (`aws_cloudwatch_query_definition`),
así que se ejecutan desde la consola (CloudWatch → Logs Insights → query
guardada) o por CLI:

```bash
# ¿Quién leyó un secreto?
aws logs start-query \
  --log-group-name aws-cloudtrail-logs-journal-api \
  --start-time "$(($(date +%s) - 86400))" --end-time "$(date +%s)" \
  --query-string 'fields @timestamp, eventName, userIdentity.arn as principal, sourceIPAddress, requestParameters.secretId as secret
    | filter eventName = "GetSecretValue"
    | sort @timestamp desc | limit 50'

# ¿Quién tocó el security group?
aws logs start-query \
  --log-group-name aws-cloudtrail-logs-journal-api \
  --start-time "$(($(date +%s) - 86400))" --end-time "$(date +%s)" \
  --query-string 'fields @timestamp, eventName, userIdentity.arn as principal, sourceIPAddress
    | filter eventName in ["AuthorizeSecurityGroupIngress", "RevokeSecurityGroupIngress", "ModifySecurityGroup", "DeleteSecurityGroup"]
    | sort @timestamp desc | limit 50'
```

> Las queries filtran **solo** por `eventName`, a propósito: una query que
> además menciona el `eventSource` volvería a matchear el patrón de los
> filtros y dispararía la alarma (§2).

Queries guardadas (nombre completo con el prefijo del proyecto):

- `journal-api/audit-lectura-de-secretos`
- `journal-api/audit-cambios-de-sg`
- `journal-api/audit-console-login`

Para el estado de conformidad de las reglas de Config:

```bash
aws config describe-config-rules --query "ConfigRules[].[ConfigRuleName,ConfigRuleState]" --output table
aws config get-compliance-details-by-config-rule --config-rule-name journal-api-iam-user-mfa
```

El trail **completo** (incluidos los eventos globales) está en S3:

```bash
aws s3 sync s3://journal-api-audit-607856468834-us-east-1/AWSLogs/607856468834/CloudTrail/ ./trail/
```

---

## 7. Limitaciones conocidas

### GuardDuty no se puede activar en esta cuenta

`CreateDetector` responde:

```
SubscriptionRequiredException: The AWS Access Key Id needs a subscription for the service
```

La cuenta no puede suscribirse a GuardDuty (ni a Security Hub, Inspector,
Macie o Detective: los cinco responden lo mismo). La causa habitual es que
la cuenta **no tiene método de pago activo** (todos esos servicios tienen
componente de consumo).

**Para habilitarlo:**

1. Cargar un método de pago en la consola (Billing → Payment preferences).
2. Poner `enable_guardduty = true` en `terraform/terraform.tfvars`.
3. `terraform -chdir=terraform apply`.

La IaC ya está escrita y probada (`aws_guardduty_detector.this`), con
`count` para que el stack no falle mientras tanto. La alarma
`journal-api-security-guardduty-findings` ya existe y queda en `OK` (nunca
hay métricas) hasta que el detector esté activo.

**Mientras tanto, AWS Config hace de threat detection** (§4).

### El patrón de "lectura de secretos" no cubre los session tokens

La alarma dispara para `GetSecretValue` hecho por un `IAMUser`. No dispara
para un atacante que reutilice un *session token* de un rol asumido (tipo
`AssumedRole`), que es indistinguible de una lectura legítima con un patrón
de texto. Para ese caso están GuardDuty (cuando se pueda activar) y la
revisión del trail completo en S3.

### CloudTrail entrega con un par de minutos de delay

Medido el 2026-11-05: el evento de un cambio de security group llegó al log
group **2 minutos** después de la llamada a la API, y el metric filter
publicó la métrica para ese minuto poco después. La alarma no es un
detector en tiempo real: es un detector con algunos minutos de retraso. Por
eso las alarmas evalúan 3 periodos y no 1 (§3).

### CloudTrail no entrega eventos a EventBridge en esta cuenta

Ver §2. Las reglas de EventBridge no matchean nada, así que la alerta se
resuelve con metric filters. Si en el futuro la entrega funciona, la
migración es reemplazar los filtros por reglas de EventBridge con patrón
JSON (que ya se verificaron con `TestEventPattern`). Los eventos de **AWS
Config** sí llegan a EventBridge: es otro servicio (§4).

### Los patrones son de texto, no de campo

Ver §2. Un patrón simple puede matchear un término que aparece en otro
campo del mismo evento. Los patrones están escritos para ser específicos y
anclados por `eventSource`.

### Los dos hallazgos de Config no están resueltos

`journal-api-iam-user-mfa` y `journal-api-iam-password-policy` están en
`NON_COMPLIANT` y lo van a seguir estando: arreglarlos requiere MFA para el
usuario administrador y una password policy en la cuenta, dos decisiones que
no son de un capstone. Como las reglas de amenaza notifican por SNS, esto
significa que **cada vez que la cuenta cambie y una de estas reglas vuelva
a evaluarse, puede llegar un correo**. Es el comportamiento esperado: el
detalle está en la consola de Config.

### El `destroy` del bucket de auditoría

El bucket tiene `force_destroy = false`: el trail es evidencia y no debería
borrarse con un `terraform destroy`. Para destruir el stack hay que vaciar
el bucket primero.

---

## 8. Costos

| Ítem | Coste |
|---|---|
| CloudTrail (eventos de management, una trail) | $0 — la primera copia es gratis |
| S3 (archivo del trail) | centavos; el lifecycle lo baja a Glacier a los 30 días |
| CloudWatch Logs (copia consultable, 30 días) | ~$0.50/GB → centavos |
| 13 metric filters + 7 alarmas | centavos |
| AWS Config (13 reglas + recorder + historial) | $0 — 25.000 evaluaciones/mes gratis; esta cuenta usa una fracción |
| GuardDuty | 30 días gratis; después $4 por millón de eventos de management |
| CodeQL (repo público) | $0 |
| Dependabot (repo público) | $0 |

**Total estimado: < $1/mes.** El detalle está en [AWS Billing](https://us-east-1.console.aws.amazon.com/billing/home).

---

## 9. Qué queda del checklist

| Ítem del currículum | Estado |
|---|---|
| Habilitar audit logging (CloudTrail) | ✅ `terraform/security.tf` |
| Alerta por evento crítico de seguridad | ✅ 4 alarmas sobre el trail + las de Config |
| Habilitar detección de amenazas | ✅ AWS Config (13 reglas, 2 hallazgos reales) — GuardDuty: IaC lista pero bloqueada por la cuenta (§7) |
| GitHub Security Scanning (CodeQL) | ✅ `.github/workflows/codeql.yml`, run verde en `main` |
| Runbook de respuesta a incidentes | ✅ [incident-response.md](incident-response.md) |

---

## 10. Verificación end-to-end

Una alarma que nunca se vio disparar no es evidencia. Para probarla:

```bash
# Abrir y cerrar una regla de ingress (evento reversible)
aws ec2 authorize-security-group-ingress --group-id sg-03751b3f2c4b4948f \
  --ip-permissions 'IpProtocol=tcp,FromPort=8443,ToPort=8443,IpRanges=[{CidrIp=203.0.113.0/24,Description="prueba"}]'
aws ec2 revoke-security-group-ingress --group-id sg-03751b3f2c4b4948f \
  --ip-permissions 'IpProtocol=tcp,FromPort=8443,ToPort=8443,IpRanges=[{CidrIp=203.0.113.0/24}]'
```

> `203.0.113.0/24` es TEST-NET-3, un rango reservado para documentación.
> Nunca es una IP real de un atacante.

En ~2-5 minutos: el trail entrega el evento → el metric filter publica
la métrica → la alarma pasa a `ALARM` → llega el correo por SNS.

**Medido el 2026-11-05:** el evento llegó al trail a los 2 minutos
(11:39:21), la métrica se publicó para ese minuto, y la alarma pasó a
`ALARM` a los 3 minutos (11:40:19). Con `evaluation_periods = 1` la alarma
no llegaba a disparar: la métrica llega tarde para una ventana de un
minuto (§3).

Para verificar el trail sin esperar:

```bash
aws logs filter-log-events --log-group-name aws-cloudtrail-logs-journal-api \
  --filter-pattern '"AuthorizeSecurityGroupIngress"'
```

**Comprobación de que la métrica no se auto-alimenta** (el test de
regresión del diseño):

```bash
# 1. Disparar 2 eventos reales (arriba)
# 2. Correr 3 queries de investigacion que mencionen el nombre del evento
# 3. Esperar ~5 minutos
aws cloudwatch get-metric-statistics --namespace JournalSecurity \
  --metric-name SecurityGroupChanges --period 60 --statistics Sum \
  --start-time "$(date -u -d '-10 minutes' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
```

El resultado esperado es **2** (solo los eventos reales). Si las queries
sumaran, daría 5.

Para la cadena de Config:

```bash
# Forzar la evaluación de todas las reglas y ver el estado de conformidad
aws config start-config-rules-evaluation --config-rule-names $(...)
aws config get-compliance-summary-by-config-rule
```

---

## 11. Referencias

- [incident-response.md](incident-response.md): qué hacer si se filtra una credencial.
- [runbook.md](runbook.md): troubleshooting del entorno desplegado.
- [observability.md](observability.md): métricas y alarmas de la aplicación.
- [delivery.md](delivery.md): cadena de entrega y verificación commit ↔ imagen ↔ `/version`.
- [evidence-security-incident-response.md](evidence-security-incident-response.md): la verificación de todo lo de este documento, con la salida real de los comandos.
- [AWS CloudTrail User Guide](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-concepts.html).
- [Sintaxis de filter patterns](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html).
- [Reglas gestionadas de AWS Config](https://docs.aws.amazon.com/config/latest/developerguide/managed-rules-by-aws-config.html).
- [CloudTrail y EventBridge](https://docs.aws.amazon.com/eventbridge/latest/ref/events-ref-cloudtrail.html).
