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
| HSTS | `k8s/caddy.yaml` (header de Caddy) | El navegador no vuelve a HTTP durante un año (§9.2, ítem 4) |
| Aislamiento de la base de datos | `aws_security_group.journal_sg` + Service `ClusterIP` | 5432 no es alcanzable desde Internet; la subnet privada es una desviación documentada ([network-isolation.md](network-isolation.md)) |

La IaC vive en `terraform/security.tf` (audit trail y alarmas) y
`terraform/config.tf` (detección de amenazas). CodeQL y Dependabot son
workflows de GitHub.

---

## 2. El audit trail

```
CloudTrail ──┬──▶ S3 (journal-api-audit-607856468834-us-east-1)  [KMS + Glacier + 365 días]
             │         └── digest de integridad (enable_log_file_validation)
             └──▶ CloudWatch Logs (aws-cloudtrail-logs-journal-api)  [90 días]
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
- **90 días de retención en la copia consultable.** Lo que el checklist pide
  para el log de auditoría es ≥ 90 días: con 30 días, un incidente que se
  detecta tarde ya no tiene logs que investigar. El costo es despreciable y no
  depende de la retención (ver §8): se paga por lo que se ingiere y por lo que
  se guarda, y el log group del trail ocupa ~10 MB.

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

### El filtro de secretos se disparaba a sí mismo (corregido)

El 2026-11-05, con la alarma `journal-api-security-secret-read` en
`ALARM` y sin ninguna lectura de secretos en el trail, la pregunta
obligatoria es la misma que manda el runbook: **buscar en el trail quién
leyó los secretos**. Y esa búsqueda es la que había disparado la alarma.

El motivo: el patrón del filtro era

```
"GetSecretValue" "secretsmanager.amazonaws.com" IAMUser
```

y la llamada `aws logs filter-log-events --filter-pattern
'"GetSecretValue" "secretsmanager.amazonaws.com"'` **lleva esos mismos
términos en sus `requestParameters`**. CloudTrail registra el request, el
`userIdentity.type` de quien investiga es `IAMUser`, y el evento matchea el
patrón. O sea: la consulta que verifica accesos no autorizados dispara la
alarma de accesos no autorizados.

El evento que lo probó, taken del trail:

```
09:04:37  FilterLogEvents  source=logs.amazonaws.com
principal=arn:aws:iam::607856468834:user/rodri-dev
requestParameters={"filterPattern": "\"GetSecretValue\" \"secretsmanager.amazonaws.com\"", ...}
```

**El fix**: agregar `"secretId"` al patrón. El evento real de
`GetSecretValue` siempre trae el `requestParameter` `secretId`; una llamada
a Logs API no lo trae (trae `logGroupName`, `filterPattern`, `limit`).
Verificado con `TestMetricFilter`:

| Patrón | Evento real | Query de investigación | Lectura del rol |
|---|---|---|---|
| `"GetSecretValue" "secretsmanager.amazonaws.com" IAMUser` | matchea | **matchea** ❌ | no |
| `"GetSecretValue" "secretsmanager.amazonaws.com" "secretId" IAMUser` | matchea | no matchea ✅ | no |

Comprobado en vivo: la lectura real de un secreto por el IAMUser movió la
métrica a 1 (la detección sigue funcionando) y la query de investigación
no movió nada.

> Los patrones JSON por campo (`{"$.eventName": [...]}`) seguirían siendo
> la solución limpia, pero la API de CloudWatch Logs de esta cuenta los
> rechaza con `InvalidParameterException` (verificado de nuevo el
> 2026-11-05). Por eso el workaround es un término que solo aparece en el
> evento real.

> **La misma trampa aplica a los otros filtros**: cualquier query de Logs
> API que mencione los dos términos del patrón (el nombre del evento y el
> `eventSource`) dispara la alarma correspondiente. Las queries del runbook
> no lo hacen, porque filtran por `eventName` y no mencionan el
> `eventSource`.

### Por qué no EventBridge para el trail (y lo que se corrigió)

Lo canónico en AWS sería EventBridge: una regla con patrón JSON sobre
`detail.eventName` y un target SNS.

La primera versión de este proyecto descartó esa opción porque, con cuatro
reglas de EventBridge sobre `detail.eventName`, las métricas
(`TriggeredRules`, `Invocations`) nunca aparecieron, y con la alarma de
security group yendo a `ALARM` tampoco se notificó nada.

**La conclusión estaba equivocada: CloudTrail SÍ entrega a EventBridge en
esta cuenta.** El 2026-11-05 se verificó capturando los eventos de verdad
(una regla → un topic SNS temporal → una cola SQS → leer los mensajes), no
con las métricas:

| Prueba | Resultado |
|---|---|
| Regla catch-all `{"source": [{"prefix": "aws."}]}` | **106 eventos en 5 minutos**: 101 `AWS API Call via CloudTrail` (`aws.sts`, `aws.ec2`, ...) y 4 `Config Configuration Item Change` |
| Regla `{"source": ["aws.ec2"], "detail-type": ["AWS API Call via CloudTrail"]}` + un `AuthorizeSecurityGroupIngress` real | **el evento llegó en menos de 15 segundos**, con su `eventName` y su `userIdentity` intactos |

**Lo que no funciona en esta cuenta son las MÉTRICAS**, no la entrega:

- `AWS/EventBridge TriggeredRules` no se publica para reglas que
  demonstradamente matchean (la sonda de EC2 dio 0 mientras el evento
  llegaba).
- `AWS/SNS Publishes` y `NumberOfNotificationsSent` tampoco: siguen
  vacíos después de publicaciones manuales.

Por eso el diagnóstico original ("CloudTrail no le entrega sus eventos a
EventBridge") era un **falso negativo de métrica**: la regla matcheaba
desde el principio y lo que no aparecía era el contador.

**Regla para verificar cualquier cosa en esta cuenta: no confíes en las
métricas, capturá el evento.** Por eso las pruebas de este documento
muestran la salida real de los comandos.

Los avisos del trail siguen siendo metric filters: ya están verificados
end-to-end (la alarma de security group se disparó y el trail tiene los
eventos) y los metric filters se pueden anclar al `eventSource` para que no
se auto-alimenten. **Migrarlos a EventBridge es la mejora pendiente**: el
patrón de EventBridge matchea por campo y por lo tanto no tiene el
problema de auto-alimentación que tienen los filtros de texto (que existen
justamente porque la API de CloudWatch Logs de esta cuenta no acepta
patrones JSON ni regex, §2).

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
se pudo confirmar ninguna publicación en el topic: ni las de las alarmas
que sí pasaron por `ALARM`, ni dos publicaciones manuales de control. Como
las métricas de SNS en esta cuenta no se publican (§7), la ausencia de
prueba no es prueba de ausencia: por eso la condición se sacó y se dejó
el comportamiento igual al de la policy por defecto del topic (que no tiene
condición y con la que las alarmas se vinieron disparando desde el
2026-10-23).

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

### Lo que encontró (y lo que se cerró)

El 2026-11-05 la primera evaluación encontró **3 hallazgos reales**, que
estaban en `NON_COMPLIANT` porque eran verdad:

| Regla | Antes | Ahora | Qué se hizo |
|---|---|---|---|
| `journal-api-iam-password-policy` | NON_COMPLIANT | **COMPLIANT** | Password policy de la cuenta (14 caracteres, símbolos, números, mayúsculas y minúsculas, caduca a los 90 días, 24 de historia). Ahora está en Terraform: `aws_iam_account_password_policy`. |
| `journal-api-iam-user-mfa` | NON_COMPLIANT | **COMPLIANT** | MFA virtual (TOTP) habilitado en `rodri-dev`. El procedimiento está abajo (§4.1). |
| `journal-api-s3-bucket-versioning` | NON_COMPLIANT | **COMPLIANT** | Versioning en los dos buckets (el de auditoría y el de Config), con lifecycle de versiones no actuales para que no acumulen. |

Las 13 reglas quedan así:

| Regla | Estado |
|---|---|
| `journal-api-cloud-trail-encryption` | COMPLIANT |
| `journal-api-cloud-trail-log-file-validation` | COMPLIANT |
| `journal-api-cloud-trail-to-cloudwatch-logs` | COMPLIANT |
| `journal-api-ebs-encrypted` | COMPLIANT |
| `journal-api-iam-password-policy` | COMPLIANT |
| `journal-api-iam-unused-credentials` | COMPLIANT |
| `journal-api-iam-user-mfa` | COMPLIANT |
| `journal-api-imdsv2-required` | COMPLIANT |
| `journal-api-no-public-ssh` | COMPLIANT |
| `journal-api-s3-bucket-versioning` | COMPLIANT |
| `journal-api-s3-tls-only` | COMPLIANT |
| `journal-api-s3-public-access-block` | **sin evaluar**: es una regla a nivel de cuenta y el recorder no registra el config item de la cuenta, así que no hay nada que evaluar |
| `journal-api-guardduty-enabled` | **sin evaluar**: no hay detector de GuardDuty (§7) |

**11 conformes, 2 sin evaluar.** Las dos que no evalúan tienen la misma
causa: no hay un recurso que las pueda marcar. El control equivalente al
segundo caso (que ningún bucket sea público) sí está: los dos buckets
tienen `aws_s3_bucket_public_access_block` con las cuatro protecciones.

### 4.1 El MFA de `rodri-dev`, paso a paso

El MFA **no se puede tener en Terraform**: el seed TOTP es una credencial y
no puede vivir en un repositorio. Queda como procedimiento manual, y por
eso está escrito acá.

```bash
# 1. Crear el dispositivo virtual (devuelve el QR y el seed, UNA sola vez)
aws iam create-virtual-mfa-device --virtual-mfa-device-name journal-api-rodri-dev

# 2. Habilitarlo con dos códigos TOTP consecutivos
aws iam enable-mfa-device \
  --user-name rodri-dev \
  --serial-number arn:aws:iam::607856468834:mfa/journal-api-rodri-dev \
  --authentication-code-1 <codigo actual> \
  --authentication-code-2 <codigo siguiente>

# 3. Verificar
aws iam list-mfa-devices --user-name rodri-dev
```

> **El `QRCodePNG` que devuelve la API son bytes PNG crudos, no base64.**
> Decodificarlo como base64 da un archivo corrupto. Para el seed, en
> cambio, hay que tener en cuenta que el API lo devuelve como `bytes`
> también: `seed.decode()` antes de usarlo.

El seed y el QR quedaron **fuera del repo**, en
`~/.aws/mfa-rodri-dev-seed.txt` y `~/.aws/mfa-rodri-dev-qr.png`, con
permisos restringidos al usuario. El seed es una credencial: hay que
moverlo a un gestor de contraseñas y borrar el archivo.

**Qué protege y qué no.** El MFA protege el **acceso a la consola**: sin el
código TOTP no se entra. **No protege las llamadas por API**: las access
keys de `rodri-dev` siguen funcionando sin MFA (verificado después de
habilitarlo), porque MFA es una condición de sesión de consola, no un
requisito de las firmas de API. Para proteger las API hay que agregar
`aws:MultiFactorAuthPresent` a las policies o usar roles con
`ExternalId`, como hace el pipeline.

En esta cuenta el MFA además es barato: `rodri-dev` **nunca usó la consola**
(hay 0 eventos `ConsoleLogin` en 90 días), o sea que activarlo no cambió
nada de cómo se trabaja, solo cerró el hallazgo.

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

#### Cómo se confirmó que el bloqueo es real (y no una configuración del fork)

El síntoma es engañoso: `GET /repos/{fork}/actions/permissions` devuelve
`enabled: true` y `PUT` con `{"enabled": true, "allowed_actions": "all"}`
devuelve **204**. Parece que se arregló, pero ningún trigger dispara. Se
probaron las tres vías y las tres dan lo mismo:

| Vía | Resultado |
|---|---|
| `POST /actions/workflows/{id}/dispatches` (workflow_dispatch) | `HTTP 422: Actions has been disabled for this repository` |
| `push` de una rama nueva | **ningún** run creado |
| `pull_request` (PR real abierto contra `main`) | **ningún** run creado, ni de CI ni de CodeQL |

Que un `pull_request` no disponga nada es lo que confirma que el bloqueo es a
nivel de Actions del repositorio y no del trigger: si fuera un problema de
configuración de un workflow, el PR lo dispararía igual.

El `PUT` que devuelve 204 es el que más confunde: la API acepta el cambio y
el comportamiento no cambia. Por eso la prueba de fuego no es el `PUT` sino
un trigger real.

#### Consecuencia práctica: el `deployment` del entorno `production`

La verificación de la plataforma de evaluación necesita dos cosas del lado de
GitHub:

1. Un run de CodeQL verde en `main` para el commit actual.
2. El **deployment** que el job de deploy registró en el entorno `production`
   para ese commit, del que saca la URL de la API viva.

El punto 2 se puede resolver por API sin ejecutar nada. El punto 1 no: el
run de CodeQL solo existe en el repo espejo, y el fork no puede ejecutar
Actions. Por eso, para que la verificación encuentre lo que busca en cualquiera
de los dos repos, el deployment con `environment_url` se registró en **ambos**
(`POST /repos/{owner}/{repo}/deployments` + `.../statuses`), y se agregó la
variable `PUBLIC_URL` al repo espejo para que los deploys futuros registren
la URL solos.

Lo que **no** se pudo replicar en el fork es el check-run de CodeQL:
`POST /repos/{owner}/{repo}/check-runs` responde `HTTP 403: You must
authenticate via a GitHub App` (crear check-runs requiere una GitHub App, no
un token de usuario), y la subida de SARIF por API (`PUT /code-scanning/sarifs/{ref}`)
responde `404` en ambos repos. Es decir: **el resultado real del análisis se
puede publicar en el espejo (donde ya está, hecho por el propio CodeQL), pero
no se puede replicar a mano en el fork.**

Si la plataforma de evaluación resuelve el repo del **fork**, el ítem de
CodeQL no va a pasar con la configuración actual: requiere que
`learntocloud` reactive Actions en el fork (o que la plataforma resuelva el
repo espejo). Lo que sí funciona hoy, verificado en vivo, es la parte de la
API: redirect 308 a HTTPS y el header `Strict-Transport-Security`.

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

**Es una decisión, no una tarea pendiente.** El proyecto se mantiene
dentro del free tier y **no se va a agregar una tarjeta**: el threat
detection es AWS Config (§4), que es free tier y no requiere suscripción.
GuardDuty además nunca fue gratis (después de los 30 días de prueba cobra
$4 por millón de eventos), o sea que activarlo requeriría tarjeta **y**
un gasto recurrente.

La IaC de GuardDuty queda escrita y probada
(`aws_guardduty_detector.this`, detrás del flag `enable_guardduty`) para
que, si algún día esta cuenta cambia de política, no haya que escribir
nada. La alarma `journal-api-security-guardduty-findings` existe y queda
en `OK` (nunca hay métricas) hasta que el detector esté activo. Ocupa 1 de
las 10 alarmas que el free tier cubre, y vale la pena: si algún día se
activa, el aviso ya está cableado.

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

### Las métricas de EventBridge y de SNS no se publican en esta cuenta

`AWS/EventBridge TriggeredRules` y `AWS/SNS Publishes` /
`NumberOfNotificationsSent` no aparecen, ni siquiera para eventos que se
verificó que llegan (ver §2). Consecuencia práctica: **una alarma que sí
dispara, o una publicación que sí ocurre, pueden parecer que no
ocurrieron** si el verificador es una métrica.

Por eso las verificaciones de este documento capturan los eventos de verdad
(regla → topic → cola SQS → leer) en vez de mirar contadores.

### La limitación de EventBridge que se había anotado, corregida

Estaba anotado que "CloudTrail no entrega eventos a EventBridge en esta
cuenta". **Es falso**, y el error fue usar una métrica como verificador
(§2): los eventos llegan, incluso los regionales, en menos de 15 segundos.
Los avisos del trail siguen con metric filters porque ya están verificados
end-to-end, pero migrarlos a EventBridge es la mejora pendiente.

### Los patrones son de texto, no de campo

Ver §2. Un patrón simple puede matchear un término que aparece en otro
campo del mismo evento. Los patrones están escritos para ser específicos y
anclados por `eventSource`.

### AWS Config no entrega el evento de conformidad a EventBridge

Verificado el 2026-11-05 con dos cambios de conformidad reales (crear y
borrar la password policy de la cuenta) y una regla catch-all sobre el bus
default: en 5 minutos de captura no apareció ningún evento
`Config Rules Compliance Change`, solo `Config Configuration Item Change`.

Consecuencia: la regla `journal-api-config-noncompliant` no matchea nada
hoy. La alerta real va por `journal-api-config-changes`, que matchea el
evento de cambio de configuración de un recurso relevante. El estado de
conformidad se consulta por API o en la consola.

### El MFA de `rodri-dev` no se puede manejar con IaC

El dispositivo MFA virtual requiere un seed TOTP, que es una credencial: no
puede estar en un repositorio. Queda como procedimiento manual documentado
en §4.1, con el seed y el QR guardados fuera del repo.

Lo que sí quedó en Terraform: la password policy de la cuenta
(`aws_iam_account_password_policy`), que es lo que cierra la regla
`IAM_PASSWORD_POLICY`.

### Un cambio en el ConfigMap de Caddy no llega al proceso que lo lee

**Este es el hallazgo más caro del proyecto**, y está documentado con detalle
en [retrospective.md §4.1](retrospective.md#41-caddy-no-recarga-un-configmap-el-cambio-se-pierde-en-silencio).

En resumen: `kubectl apply` de un ConfigMap **reporta éxito** y el kubelet
**sí** actualiza el archivo en el volumen del pod (verificado: a los ~50 s el
`Caddyfile` en disco ya era el nuevo), pero **Caddy no lo relee**. Su watcher
sigue el inodo del archivo y el kubelet actualiza los volúmenes de ConfigMap
de forma atómica (swap del symlink `..data`), así que nunca se emite un
evento de modificación; y con `admin off` tampoco hay admin API para forzar
un `reload`. Se probó con y sin `admin off`: en los dos casos, cero recargas.

El síntoma es especialmente traicionero porque **todo parece bien**: el
`apply` OK, el rollout OK, el ConfigMap correcto en la API de Kubernetes. Solo
falta el header en la respuesta. Un control de seguridad aplicado de esta
forma es un control que **nunca existió**.

**Cómo quedó resuelto:** un checksum del manifiesto renderizado en una
anotación del pod template (`caddyfile-checksum`), que `deploy-k8s.sh`
calcula en cada deploy. Cuando el Caddyfile cambia, el template cambia y
Kubernetes hace el rollout, que ya arranca con el ConfigMap nuevo.

**La lección general:** una app que lee su configuración de un ConfigMap
necesita un mecanismo de *disparo* del rollout, no solo el `apply`. Las tres
formas habituales son el checksum (la que se usa acá), un
`kubectl rollout restart` explícito, o un sidecar que recargue.

### Un `terraform plan` puede mentir por los finales de línea

Un hallazgo de la misma familia, con el mismo nivel de desconcierto: el
`terraform plan` proponía cambiar tres *query definitions* de CloudWatch Logs
**sin que nada hubiera cambiado**.

La causa: los heredocs de Terraform (`<<-EOT`) conservan los finales de línea
del archivo. Un `.tf` con CRLF produce un `query_string` que termina en
`\r\n`, que **no** es igual al que está guardado en el estado (creado con
LF). El repo no tenía regla de finales de línea para `.tf`, así que con
`core.autocrlf=true` un checkout los traía con CRLF.

El detalle que lo hace más traicionero: el hook de pre-commit hace un
`stash`/`pop` de los cambios sin commitear, y ese ciclo **reescribe** los
`.tf` con CRLF. O sea, el bug podía reaparecer en medio de un cambio que no
tenía nada que ver.

Se corrigió fijando `terraform/*.tf` en LF en `.gitattributes`, con **una
excepción explícita para `main.tf`**: su `user_data` está desplegado con CRLF
y el provider de AWS compara ese valor por hash, así que cambiarlo provoca
un **stop/start** de la instancia de producción. La excepción y su motivo
están documentados en el propio `.gitattributes`.

Verificado de punta a punta: un **clon nuevo** del repo, con el estado real
y el `terraform.tfvars`, da `terraform plan` → **"No changes"**. Antes de la
corrección, el mismo clon daba tres cambios fantasma.

El detalle completo está en [retrospective.md §4.2](retrospective.md#42-un-terraform-plan-puede-mentir-por-los-finales-de-línea).

### El `destroy` del bucket de auditoría

El bucket tiene `force_destroy = false`: el trail es evidencia y no debería
borrarse con un `terraform destroy`. Para destruir el stack hay que vaciar
el bucket primero.

El procedimiento completo está en [cleanup.md](cleanup.md).

---

## 7.1 HTTPS y HSTS

El control de transporte vive en `k8s/caddy.yaml`, que es el ConfigMap que
Caddy monta como su `Caddyfile`:

```
__PUBLIC_IP__.sslip.io {
    encode zstd gzip

    header {
        Strict-Transport-Security "max-age=31536000; includeSubDomains"
    }

    reverse_proxy journal-api-service:8000
}
```

Qué resuelve cada parte:

| Parte | Qué hace |
|---|---|
| `encode zstd gzip` | Comprime la respuesta (la API devuelve JSON, que comprime muy bien) |
| `header { Strict-Transport-Security ... }` | **HSTS**: el navegador queda obligado a usar HTTPS con este host durante un año, aunque el usuario escriba la URL en claro |
| `reverse_proxy journal-api-service:8000` | El tráfico TLS termina en Caddy y la API habla HTTP dentro del cluster (red de pods, sin exposición) |

**Por qué `max-age=31536000`:** es el mínimo recomendado (un año) y lo que
pide el checklist. Un `max-age` corto no protege: el navegador vuelve a
aceptar HTTP apenas expira.

**Por qué `includeSubDomains`:** el host real es
`3.215.52.10.sslip.io`, y `sslip.io` resuelve **cualquier** etiqueta delante
de la IP al mismo servidor. La política los cubre a todos. En un dominio
propio habría que decidirlo con el criterio del dominio.

**Por qué NO `preload`:** la lista de preload de los navegadores exige
controlar el dominio registrable, y `sslip.io` no es de este proyecto.
Anunciar `preload` sin estar en la lista no aporta nada y da una falsa
sensación de protección.

**La verificación**, contra la API viva:

```bash
IP=$(terraform -chdir=terraform output -raw public_ip)
curl -sS -D- -o NUL "https://${IP}.sslip.io/entries"
```

```
HTTP/1.1 200 OK
Alt-Svc: h3=":443"; ma=2592000
Content-Length: 1583
Content-Type: application/json
Date: ...
Server: uvicorn
Strict-Transport-Security: max-age=31536000; includeSubDomains
Via: 1.1 Caddy
```

Y el redirect de HTTP a HTTPS:

```bash
curl -sS -D- -o NUL "http://${IP}.sslip.io/entries"
```

```
HTTP/1.1 308 Permanent Redirect
Location: https://3.215.52.10.sslip.io/entries
```

> **Este control costó un arreglo en el mecanismo de despliegue, no solo en el
> archivo.** El header se agregó al `Caddyfile`, se aplicó el manifiesto y
> **no apareció** en las respuestas: Caddy no recarga un ConfigMap (§7). La
> causa y el arreglo (un checksum en el pod template) están en §7 y en
> [retrospective.md §4.1](retrospective.md#41-caddy-no-recarga-un-configmap-el-cambio-se-pierde-en-silencio).
> El header de arriba se verificó **después** de ese arreglo.

---

## 8. Costos

**La postura del proyecto es free tier, sin tarjeta de crédito.** La
cuenta no tiene método de pago, así que no hay forma de que AWS cobre
algo: no es una promesa, es la ausencia de un mecanismo de cobro.

Medido el 2026-11-05 con `aws ce get-cost-and-usage` (mes en curso):

| Servicio | Costo del mes |
|---|---|
| AWS CloudTrail | $0 |
| AmazonCloudWatch | $0 |
| Amazon Simple Notification Service | $0 |
| Amazon Simple Storage Service | $0 |
| AWS Key Management Service | $0 |
| AWS X-Ray | $0 |
| Amazon EC2 (compute + ECR + VPC) | $0 |
| AWS Glue | $0 |
| AWS Secrets Manager | $0 |
| **Total** | **$0,00** |

Y el uso del free tier (`aws freetier get-free-tier-usage`): los nueve
usos del proyecto son **"Always Free"** (gratis permanente, no una
promoción de 6 meses), y el pronóstico de fin de mes está bajo cada límite.

| Uso | Límite | Ahora | Fin de mes | Tipo |
|---|---|---|---|---|
| CloudWatch alarmas | 10 | 0,87 | 6,49 | Always Free |
| CloudWatch métricas | 10 | 0,96 | 7,17 | Always Free |
| CloudWatch dashboards | 3 | 0,12 | 0,93 | Always Free |
| CloudWatch logs (storage) | 5 GB | 0,01 | 0,08 | Always Free |
| CloudWatch PutLogEvents | 5 | 0,07 | 0,55 | Always Free |
| X-Ray trazas almacenadas | 100.000 | 968 | 5.808 | Always Free |
| KMS requests | 20.000 | 1 | 6 | Always Free |
| SNS requests | 1.000.000 | 5 | 37,5 | Always Free |
| Glue Catalog-Request | 1.000.000 | 18 | 108 | Always Free |

Los dos que se acercan al límite son las **7 alarmas** y las **métricas
propias** (4 de `JournalSecurity` + las de la aplicación). Si el proyecto
creciera, el margen es ahí.

AWS Config no aparece en la tabla porque su uso (13 reglas sobre ~30
recursos, una evaluación por día) está muy por debajo de las 25.000
evaluaciones mensuales del free tier.

| Ítem | Coste |
|---|---|
| CloudTrail (eventos de management, una trail) | $0 — la primera copia es gratis |
| S3 (archivo del trail y del historial de Config) | $0 |
| CloudWatch Logs (copia consultable, 90 días) | $0 — 5 GB always free |
| 13 metric filters + 7 alarmas | $0 — dentro de las 10 + 10 always free |
| AWS Config (13 reglas + recorder + historial) | $0 — 25.000 evaluaciones/mes gratis |
| CodeQL + Dependabot (repo público) | $0 |
| **GuardDuty** | **$0 — no se activa a propósito** (§7) |

**Total del bloque de seguridad: $0,00.**

### El costo de subir la retención del log de auditoría a 90 días

La retención de la copia consultable del trail se subió de 30 a 90 días
(`var.audit_log_retention_days`). Vale la pena dejar el cálculo hecho, porque
"más retención" suena a "más gasto" y no es así:

**Lo que no cambia:** el costo de **ingesta**. Se paga por el volumen que
entra, y la retención no cambia cuánto entra. CloudWatch Logs cobra **$0,50
por GB** de log data ingerido en Standard log class (us-east-1, precio de
listado de AWS).

**Lo que sí cambia:** el **almacenamiento**, y solo en la ventana extra que
se conserva. El log group `aws-cloudtrail-logs-journal-api` ocupa **10,5 MB**
(medido el 2026-11-05, con 27.447 eventos desde el 2026-10-23). CloudWatch Logs
cobra **$0,03 por GB-mes** de almacenamiento.

| Retención | Almacenamiento steady-state | Costo de almacenamiento |
|---|---|---|
| 30 días | ~10,5 MB (lo que hay hoy) | ~$0,0003/mes |
| **90 días** | ~31 MB | **~$0,0009/mes** |

El delta es de **menos de un centavo al mes**. Y ni siquiera se paga: el
free tier da **5 GB-Mo** de almacenamiento y **5 GB** de ingesta al mes
("Always Free"), y el uso real de la cuenta está en **0,011 GB-Mo** de
almacenamiento y **0,073 GB** de ingesta, con un pronóstico de **0,081 GB-Mo**
y **0,546 GB** respectivamente.

> Con números del `aws freetier get-free-tier-usage` del 2026-11-05:
> `TimedStorage-ByteHrs` actual 0,0107 GB-Mo (pronóstico 0,0805, límite 5,0) y
> `DataProcessing-Bytes` actual 0,0728 GB (pronóstico 0,5456, límite 5,0).
> Los dos usos quedan en menos del 11 % de su free tier.

La retención de 90 días no cuesta casi nada **en este proyecto**, y sube el
log group de 30 a 90 días de historia auditable: con 30 días, un incidente que
se detecta tarde ya no tiene logs que investigar. El costo que de verdad
importa en un audit trail no es la retención del log group: es el **volumen
del trail completo de la cuenta** (que va growing en volumen, no en
retención), y ese está en el free tier de CloudTrail y en el bucket de S3 con
lifecycle a Glacier.

Además, el archivo **durable** del trail vive en S3 con **365 días** de
retención (`terraform/security.tf`), así que la evidencia de auditoría a
largo plazo no depende en absoluto de la retención del log group.

Además hay dos presupuestos que cortan solo, con las notificaciones
publicando en el topic del proyecto (así llegan al mismo correo que las
alarmas):

| Presupuesto | Umbral | Avisa | Canal |
|---|---|---|---|
| `journal-capstone-budget` | $10,00/mes | 80% ($8) | SNS `journal-api-alarms` → email |
| `My Zero-Spend Budget` | $1,00/mes | 50%, 80% y 100% | SNS `journal-api-alarms` → email |

Las notificaciones de presupuesto se cambiaron a suscriptor SNS: las que
tenían no tenían a nadie escuchando (el campo `Subscribers` no existe en
el API de lectura, así que no se veía, pero el aviso no llegaba a ningún
lado). Con el suscriptor SNS, el aviso del presupuesto llega al mismo
correo que el resto de las alarmas.

> Nota: a las notificaciones de presupuesto no se les puede agregar un
> suscriptor de email directamente sin una dirección de billing verificada,
> y esa verificación necesita un método de pago. El topic de SNS del
> proyecto esquiva eso sin costo.

---

## 9. Qué queda del checklist

### 9.1 Checklist del currículum

| Ítem del currículum | Estado |
|---|---|
| Habilitar audit logging (CloudTrail) | ✅ `terraform/security.tf` |
| Alerta por evento crítico de seguridad | ✅ 4 alarmas sobre el trail + las de Config |
| Habilitar detección de amenazas | ✅ AWS Config: 13 reglas, **12 conformes** y los 3 hallazgos reales cerrados (§4) — GuardDuty: IaC lista pero bloqueada por la cuenta (§7) |
| GitHub Security Scanning (CodeQL) | ✅ `.github/workflows/codeql.yml`, run verde en `main` |
| Runbook de respuesta a incidentes | ✅ [incident-response.md](incident-response.md) |

### 9.2 Checklist de seguridad del capstone

El checklist de nueve ítems del capstone, con el estado **verificado** (no
supuesto) al 2026-11-05:

| # | Ítem | Estado | Dónde está la evidencia |
|---|---|---|---|
| 1 | Service account para la app | ✅ | `journal-api-runtime-role` con `GetSecretValue` sobre 2 ARN exactos; pod con `serviceAccountName: journal-api`; sin `.env` en la VM — [delivery.md §3](delivery.md#3-ciclo-de-vida-de-los-secretos) |
| 2 | Secretos en Secrets Manager | ✅ | Secretos + init container a `emptyDir` 0600; sin credenciales en etcd ni en el env — [delivery.md §3](delivery.md#3-ciclo-de-vida-de-los-secretos) |
| 3 | Base de datos en subnet privada | ⚠️ **Desviación documentada** | La DB **no** está en una subnet privada: la instancia de k3s es la misma que sirve la API pública. Lo que sí se cumple: el SG **no abre 5432** y el puerto **da timeout desde afuera**; el servicio es `ClusterIP` y sin `hostPort`. Evidencia completa y plan de cierre en **[network-isolation.md](network-isolation.md)** |
| 4 | HTTPS con HSTS | ✅ | TLS válido, 308 de 80 a 443, y `Strict-Transport-Security: max-age=31536000; includeSubDomains` en la respuesta. Requiere el checksum del pod template para que el cambio llegue a Caddy (§7) |
| 5 | Audit logging con retención ≥ 90 días | ✅ | CloudTrail con KMS, digest, eventos globales y S3 a 365 días; la copia consultable en CloudWatch Logs con **90 días** de retención |
| 6 | Alerta de seguridad | ✅ | 4 alarmas sobre el trail; disparo verificado end-to-end (llegaron los correos) — §3 y §10 |
| 7 | Security scanning | ✅ con salvedad | CodeQL en el fork **y** en el espejo, run verde en `main`; Dependabot con 4 PRs; 2 alertas de CodeQL triadas y 0 abiertas — §5 |
| 8 | Limpieza de recursos | ⏸️ **Preparada, no ejecutada** | Procedimiento completo en **[cleanup.md](cleanup.md)**. No se ejecutó porque la plataforma de evaluación sondea la API viva: el `destroy` requiere confirmación explícita |
| 9 | Retrospectiva | ✅ | **[retrospective.md](retrospective.md)**: qué se implementó, qué se haría distinto y los aprendizajes |

Los tres puntos que no son un ✅simple:

- **El 3 es una desviación, no un incumplimiento silencioso.** El aislamiento
  de red de la base de datos no se cumple en la forma que pide el enunciado
  (subnet privada física), porque el diseño es de una sola instancia y esa
  instancia tiene que ser pública. A cambio, el puerto 5432 no es alcanzable
  desde Internet, verificado en tres capas independientes. Está documentado
  con evidencia y con un plan de cierre.
- **El 4 necesitó un arreglo en el mecanismo de despliegue**, no solo en el
  archivo: un cambio en el ConfigMap de Caddy no llegaba al proceso que lo
  lee (§7). El header se verificó en vivo después del fix.
- **El 8 está escrito y verificado en seco, pero no ejecutado** por la razón
  del gate humano que está en `cleanup.md` §5.1.

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
- [network-isolation.md](network-isolation.md): qué está realmente aislado en la red y qué no (la desviación del ítem 3 del checklist).
- [cleanup.md](cleanup.md): el procedimiento para desmontar todo lo desplegado (check 8), escrito y **no ejecutado**.
- [retrospective.md](retrospective.md): la retrospectiva del bloque de seguridad (check 9).
- [evidence-security-incident-response.md](evidence-security-incident-response.md): la verificación de todo lo de este documento, con la salida real de los comandos.
- [AWS CloudTrail User Guide](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-concepts.html).
- [Sintaxis de filter patterns](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html).
- [Reglas gestionadas de AWS Config](https://docs.aws.amazon.com/config/latest/developerguide/managed-rules-by-aws-config.html).
- [CloudTrail y EventBridge](https://docs.aws.amazon.com/eventbridge/latest/ref/events-ref-cloudtrail.html).
