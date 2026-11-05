# Seguridad del plano de control: auditoría, detección y alertas

Documento de referencia del bloque *Monitoring & Incident Response* del
currículum. Cubre lo que está desplegado en la cuenta `607856468834`
(us-east-1), cómo se verifica y qué se decidió **no** construir.

Complementa —no reemplaza— [runbook.md](runbook.md) (que tiene el
procedimiento paso a paso) y [observability.md](observability.md) (que cubre
las métricas de la aplicación).

---

## 1. Qué hay desplegado

| Control | Recurso Terraform | Qué resuelve |
|---|---|---|
| Audit trail | `aws_cloudtrail.audit` | Quién hizo qué en la cuenta |
| Archivo durable | `aws_s3_bucket.audit` + KMS | Evidencia que sobrevive, con digest de integridad |
| Copia consultable | `aws_cloudwatch_log_group.audit` | Logs Insights sin bajar el bucket |
| Alertas de seguridad | 13 metric filters + 5 alarmas | Reacción ante eventos sospechosos |
| Detección de amenazas | `aws_guardduty_detector.this` | Patrones de ataque (ver la limitación en §5) |
| Análisis estático | `.github/workflows/codeql.yml` | Flujos de datos inseguros en Python |

Todo vive en `terraform/security.tf`, salvo CodeQL.

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
   `ObjectOwnership = BucketOwnerEnforced` (el default de S3 desde abril
   de 2023) ese header hace fallar el PUT. El trail queda logging, sin
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
vez. Es ruido de setup, no un incidente. En régimen permanente (sin tocar
los filtros) la métrica cuenta solo eventos reales.

### Por qué no EventBridge

Lo canónico en AWS sería EventBridge: una regla con patrón JSON sobre
`detail.eventName` y un target SNS. Los patrones JSON **sí** se aceptan en
EventBridge (verificado con `TestEventPattern`: `true` para los cuatro
patrones).

**Pero en esta cuenta CloudTrail no le entrega sus eventos a EventBridge.**
Se probó con cuatro reglas reales, se dispararon eventos reales de cambio
de security group, se creó el service-linked role que CloudTrail usa para
eso… y las métricas de EventBridge (`TriggeredRules`, `Invocations`)
nunca aparecieron, ni una sola vez, en 15 minutos. Sin eventos, la regla no
matchea.

Queda documentado como limitación conocida (§5). La alerta se hace con
metric filters, que sí funcionan end-to-end.

## 3. Las cinco alarmas de seguridad

| Alarma | Evento que la dispara | Por qué |
|---|---|---|
| `journal-api-security-sg-changed` | `AuthorizeSecurityGroupIngress`, `RevokeSecurityGroupIngress`, `ModifySecurityGroup`, `ModifySecurityGroupRules`, `DeleteSecurityGroup` | Alguien abre, cierra o borra un puerto de la API. Es el ataque clásico sobre un SG con `0.0.0.0/0`. |
| `journal-api-security-console-login-failed` | `ConsoleLogin` con `errorMessage: "Failed authentication"` | La API no tiene autenticación y el 22 está cerrado: el único "login" de esta cuenta es el de la consola de AWS. |
| `journal-api-security-secret-read` | `GetSecretValue` con `userIdentity.type = IAMUser` | Las lecturas legítimas son del rol de la app y del de la instancia, y los dos son `AssumedRole`. Una access key filtrada o un humano en la consola son `IAMUser`. |
| `journal-api-security-iam-credential-change` | `CreateAccessKey`, `CreateUser`, `CreateLoginProfile`, `AttachUserPolicy`, `PutUserPolicy`, `UpdateAssumeRolePolicy` | Escalamiento de privilegios: alguien se crea un acceso nuevo. |
| `journal-api-security-guardduty-findings` | cualquier hallazgo de GuardDuty (métrica `AWS/GuardDuty/GuardDutyFindings`) | Detección administrada de patrones de ataque. |

Las cuatro primeras salen de los metric filters sobre el log group del
trail. La quinta sale de la métrica que publica GuardDuty.

Todas notifican al topic SNS `journal-api-alarms` (el mismo que ya usan las
alarmas de la aplicación): **un solo canal, un solo correo**.

> **Lo que no se vigila, a propósito:** cada `Describe*` y cada `List*` que
> hace cualquier servicio. Alerta de todo es alerta de nada.

### El topic SNS no necesita policy propia

La policy por defecto de un topic SNS ya viene acotada al dueño de la
cuenta (`Condition: AWS:SourceOwner`). No hace falta `aws_sns_topic_policy`
para evitar que cualquiera publique en el topic.

Y si se quisiera agregar: **SNS no acepta `sns:Unsubscribe` ni `SNS:*` en
la policy de un topic** (`Policy statement action out of service scope`),
y `sns:Unsubscribe` es justo lo que necesita el provider para borrar la
suscripción de email en un `terraform destroy`. Una policy explícita
rompería el destroy. Por eso no está.

## 4. Cómo investigar

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
    | filter eventName in ["AuthorizeSecurityGroupIngress","RevokeSecurityGroupIngress","ModifySecurityGroup","ModifySecurityGroupRules","DeleteSecurityGroup"]
    | sort @timestamp desc | limit 50'
```

> Las queries filtran **solo** por `eventName`, a propósito: una query que
> además menciona el `eventSource` volvería a matchear el patrón de los
> filtros y dispararía la alarma (§2).

Queries guardadas (nombre completo con el prefijo del proyecto):

- `journal-api/audit-lectura-de-secretos`
- `journal-api/audit-cambios-de-sg`
- `journal-api/audit-console-login`

El trail **completo** (incluidos los eventos globales) está en S3:

```bash
aws s3 sync s3://journal-api-audit-607856468834-us-east-1/AWSLogs/607856468834/CloudTrail/ ./trail/
```

## 5. Limitaciones conocidas

### GuardDuty no se puede activar en esta cuenta

`CreateDetector` responde:

```
SubscriptionRequiredException: The AWS Access Key Id needs a subscription for the service
```

La cuenta no puede suscribirse a GuardDuty. La causa habitual es que la
cuenta **no tiene método de pago activo** (GuardDuty tiene componente de
consumo por GB) o que la cuenta es elegible solo para el plan gratuito
estricto.

**Para habilitarlo:**

1. Cargar un método de pago en la consola (Billing → Payment preferences).
2. Poner `enable_guardduty = true` en `terraform/terraform.tfvars`.
3. `terraform -chdir=terraform apply`.

La IaC ya está escrita y probada (`aws_guardduty_detector.this`), con
`count` para que el stack no falle mientras tanto. La alarma
`journal-api-security-guardduty-findings` ya existe y queda en `OK` (nunca
hay metricas) hasta que el detector esté activo.

### CloudTrail no entrega eventos a EventBridge en esta cuenta

Ver §2. Las reglas de EventBridge no matchean nada, así que la alerta se
resuelve con metric filters. Si en el futuro la entrega funciona, la
migración es reemplazar los filtros por reglas de EventBridge con patrón
JSON (que ya se verificaron con `TestEventPattern`).

### El patrón de "lectura de secretos" no cubre los session tokens

La alarma dispara para `GetSecretValue` hecho por un `IAMUser`. No dispara
para un atacante que reutilice un *session token* de un rol asumido (tipo
`AssumedRole`), que es indistinguible de una lectura legítima con un patrón
de texto. Para ese caso están GuardDuty (cuando se pueda activar) y la
revisión del trail completo en S3.

### CloudTrail entrega por lotes

Los eventos llegan a CloudWatch Logs en lotes (hasta ~5 minutos de retraso) y
las metric filters publicar la métrica ~2 minutos después. **La alarma no es
un detector en tiempo real**, es un detector con algunos minutos de retraso.

### Los patrones son de texto, no de campo

Ver §2. Un patrón simple puede matchear un término que aparece en otro
campo del mismo evento. Los patrones están escritos para ser específicos y
anclados por `eventSource`.

### El `destroy` del bucket de auditoría

El bucket tiene `force_destroy = false`: el trail es evidencia y no debería
borrarse con un `terraform destroy`. Para destruir el stack hay que vaciar
el bucket primero.

## 6. Costos

| Ítem | Coste |
|---|---|
| CloudTrail (eventos de management, una trail) | $0 — la primera copia es gratis |
| S3 (archivo del trail) | centavos; el lifecycle lo baja a Glacier a los 30 días |
| CloudWatch Logs (copia consultable, 30 días) | ~$0.50/GB → centavos |
| 13 metric filters + 5 alarmas | centavos |
| GuardDuty | 30 días gratis; después $4 por millón de eventos de management |
| CodeQL (repo público) | $0 |

**Total estimado: < $1/mes.** El detalle está en [AWS Billing](https://us-east-1.console.aws.amazon.com/billing/home).

## 7. Qué queda del checklist

| Ítem del currículum | Estado |
|---|---|
| Habilitar audit logging (CloudTrail) | ✅ `terraform/security.tf` |
| Alerta por evento crítico de seguridad | ✅ 5 alarmas (4 del trail + GuardDuty) |
| Habilitar detección de amenazas | ⚠️ IaC lista; bloqueada por la cuenta (§5) |
| GitHub Security Scanning (CodeQL) | ✅ `.github/workflows/codeql.yml` |
| Runbook de respuesta a incidentes | ✅ [runbook.md §14](runbook.md#14-se-filtró-una-credencial) |

## 8. Verificación end-to-end

Una alarma que nunca se vio disparar no es evidencia. Para probarla:

```bash
# Abrir y cerrar una regla de ingress (evento reversible)
aws ec2 authorize-security-group-ingress --group-id sg-03751b3f2c4b4948f \
  --ip-permissions 'IpProtocol=tcp,FromPort=8443,ToPort=8443,IpRanges=[{CidrIp=203.0.113.0/24,Description="prueba"}]'
aws ec2 revoke-security-group-ingress --group-id sg-03751b3f2c4b4948f \
  --ip-permissions 'IpProtocol=tcp,FromPort=8443,ToPort=8443,IpRanges=[{CidrIp=203.0.113.0/24}]'
```

En ~5-7 minutos: el trail entrega el evento → el metric filter publica la
métrica → la alarma pasa a `ALARM` → llega el correo por SNS.

> `203.0.113.0/24` es TEST-NET-3, un rango reservado para documentación.
> Nunca es una IP real de un atacante.

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

## 9. Referencias

- [runbook.md §14](runbook.md#14-se-filtró-una-credencial): qué hacer si se filtra una credencial.
- [observability.md](observability.md): métricas y alarmas de la aplicación.
- [delivery.md](delivery.md): cadena de entrega y verificación commit ↔ imagen ↔ `/version`.
- [AWS CloudTrail User Guide](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-concepts.html).
- [Sintaxis de filter patterns](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html).
- [CloudTrail y EventBridge](https://docs.aws.amazon.com/eventbridge/latest/ref/events-ref-cloudtrail.html).
