# Evidencia — Monitoreo y respuesta a incidentes

Fecha: 2026-11-05
Cuenta: `607856468834` (us-east-1)
Repos: `amarillaRodrigo/journal-starter` (el fork) y
`amarillaRodrigo/journal-starter-pipeline` (donde corre el pipeline)

Este documento es la evidencia de verificación del bloque *Cloud Monitoring
Overview* del currículum. Cada ítem dice **qué se chequeó, cómo y qué
salió**. Los comandos son copiables.

| Ítem del checklist | Estado | Dónde está la evidencia |
|---|---|---|
| Habilitar audit logging (CloudTrail) | ✅ | [§1](#1-audit-logging-cloudtrail) |
| Alerta por evento crítico de seguridad | ✅ | [§2](#2-alerta-por-evento-crítico-de-seguridad) |
| Detección de amenazas | ✅ (AWS Config) | [§3](#3-detección-de-threats-aws-config) |
| GitHub Security Scanning (CodeQL) | ✅ | [§4](#4-codeql) |
| Runbook de respuesta a incidentes | ✅ | [§5](#5-runbook-de-respuesta-a-incidentes) |

---

## 1. Audit logging (CloudTrail)

```bash
aws cloudtrail describe-trails --query "trailList[].{Name:Name,S3:S3BucketName,Global:IncludeGlobalServiceEvents,Validation:LogFileValidationEnabled,KMS:KmsKeyId,Logs:CloudWatchLogsLogGroupArn}" --output table
```

Salida real:

```
Name                S3BucketName                                  IncludeGlobalServiceEvents  LogFileValidationEnabled  KmsKeyId  CloudWatchLogsLogGroupArn
journal-api-audit  journal-api-audit-607856468834-us-east-1       True                       True                     arn:...   arn:aws:logs:us-east-1:607856468834:log-group:aws-cloudtrail-logs-journal-api:*
```

La copia consultable:

```bash
aws logs describe-log-groups --query "logGroups[].[logGroupName,storedBytes]" --output table
```

```
/aws/journal-api/application                 42910057
/aws/journal-api/metrics                      29971447
aws-cloudtrail-logs-journal-api              10511286
```

Los eventos **reales** de un cambio de security group, leídos del trail
(parseando el JSON, no buscando texto):

```bash
aws logs filter-log-events --log-group-name aws-cloudtrail-logs-journal-api \
  --filter-pattern '"AuthorizeSecurityGroupIngress" "ec2.amazonaws.com"'
```

```
11:39:21  AuthorizeSecurityGroupIngress  principal=arn:aws:iam::607856468834:user/rodri-dev
          ip=186.124.133.73
          requestParameters: {"groupId": "sg-03751b3f2c4b4948f", "ipPermissions": {... "cidrIp": "203.0.113.0/24" ...}}
11:42:55  AuthorizeSecurityGroupIngress  principal=arn:aws:iam::607856468834:user/rodri-dev
```

> `203.0.113.0/24` es TEST-NET-3, un rango reservado para documentación. La
> IP `186.124.133.73` es la de salida del usuario que corrió la prueba.

**Latencia medida:** el evento llegó al log group **2 minutos** después de
la llamada a la API. No son los 15 minutos que se suponían (ver la
corrección en [security.md §7](../security.md)).

---

## 2. Alerta por evento crítico de seguridad

Las 4 alarmas sobre el trail, más la de GuardDuty y las 2 de la aplicación:

```bash
aws cloudwatch describe-alarms --alarm-name-prefix journal-api \
  --query "MetricAlarms[].[AlarmName,StateValue]" --output table
```

```
journal-api-http-5xx                         OK
journal-api-latency-p95                      OK
journal-api-security-console-login-failed    OK
journal-api-security-guardduty-findings      OK
journal-api-security-iam-credential-change   OK
journal-api-security-secret-read             OK
journal-api-security-sg-changed              ALARM
```

### La prueba end-to-end

Se abrió y se cerró una regla de ingress (evento reversible):

```bash
aws ec2 authorize-security-group-ingress --group-id sg-03751b3f2c4b4948f \
  --ip-permissions 'IpProtocol=tcp,FromPort=8443,ToPort=8443,IpRanges=[{CidrIp=203.0.113.0/24}]'
```

La métrica del metric filter:

```bash
aws cloudwatch get-metric-statistics --namespace JournalSecurity \
  --metric-name SecurityGroupChanges --period 60 --statistics Sum \
  --start-time ... --end-time ...
```

```
SecurityGroupChanges: [('08:39:00', 2.0), ('08:42:00', 1.0), ('08:57:00', 1.0), ...]
```

El historial de la alarma:

```
2026-11-05 08:40:19  Alarm updated from OK to ALARM
2026-11-05 08:47:43  Alarm updated from ALARM to OK
2026-11-05 08:58:43  Alarm updated from OK to ALARM
```

Motivo de la transición:

```
Threshold Crossed: 1 out of the last 3 datapoints [1.0 (05/11/26 11:57:00)]
was greater than or equal to the threshold (1.0)
(minimum 1 datapoint for OK -> ALARM transition).
```

### El bug que encontró esta prueba

La primera versión de las alarmas tenía `evaluation_periods = 1`. Con esa
configuración **la alarma no disparaba**: la métrica del trail tarda ~2
minutos en publicarse, y una ventana de evaluación de 1 minuto evalúa el
minuto anterior *antes* de que exista el dato. El evento se perdía.

Se cambió a `evaluation_periods = 3` con `datapoints_to_alarm = 1`: la
alarma dispara en el primer datapoint que breacha dentro de una ventana de
3 minutos. Con el cambio, la alarma disparó en las dos pruebas.

### El canal

```bash
aws sns list-subscriptions-by-topic --topic-arn arn:aws:sns:us-east-1:607856468834:journal-api-alarms
```

```
arn:aws:sns:us-east-1:607856468834:journal-api-alarms:924de5ef-...  email  amarillarodrigo14@gmail.com
```

Una sola suscripción, confirmada. **Un canal, un correo.**

### Lo que encontró la verificación: las métricas no se publican

Al intentar confirmar las notificaciones por SNS, las métricas del topic
salieron siempre vacías:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/SNS \
  --metric-name NumberOfNotificationsSent --dimensions Name=TopicName,Value=journal-api-alarms ...
# sin datapoints, incluso después de dos publicaciones manuales
```

Y lo mismo con EventBridge:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/EventBridge \
  --metric-name TriggeredRules --dimensions Name=RuleName,Value=journal-api-eb-probe-ec2 ...
# 0, con una regla que SÍ estaba matcheando
```

Para verificar de verdad se capturó el evento, con un sink descartable
(regla de EventBridge → topic SNS temporal → cola SQS → leer los mensajes):

| Prueba | Resultado |
|---|---|
| Regla catch-all `{"source": [{"prefix": "aws."}]}` | **106 eventos en 5 minutos**: 101 `AWS API Call via CloudTrail` + 4 `Config Configuration Item Change` |
| Regla `{"source": ["aws.ec2"], "detail-type": ["AWS API Call via CloudTrail"]}` + un `AuthorizeSecurityGroupIngress` real | **llegó en menos de 15 segundos**, con `eventName` y `userIdentity` intactos |

**Conclusión: CloudTrail SÍ entrega a EventBridge en esta cuenta.** El
diagnóstico anterior ("no entrega") era un falso negativo de métrica: la
regla matcheaba desde el principio y lo que no aparecía era el contador.

Esto también explica por qué las alarmas del trail están hechas con metric
filters y no con reglas de EventBridge: se llegaron a descartar EventBridge
por esa misma métrica que no se publica. Migrarlas es la mejora
pendiente, no un bloqueo.

> **Regla práctica para esta cuenta:** no verifiques nada con
> `get-metric-statistics` de EventBridge ni de SNS. Capturá el evento.

---

## 3. Detección de threats (AWS Config)

### Por qué Config y no GuardDuty

Se probó cada servicio de seguridad con precio por uso. Todos responden
`SubscriptionRequiredException` (la cuenta no tiene método de pago):

| Servicio | Respuesta |
|---|---|
| GuardDuty | `SubscriptionRequiredException` |
| Security Hub | `SubscriptionRequiredException` |
| Inspector v2 | `SubscriptionRequiredException` |
| Macie | `SubscriptionRequiredException` |
| Detective | `SubscriptionRequiredException` |
| **AWS Config** | ✅ funciona |
| **IAM Access Analyzer** | ✅ funciona |

AWS Config tiene free tier permanente y no necesita suscripción: es el
threat detection que quedó funcionando.

### Lo desplegado

```bash
aws config describe-configuration-recorder-status
aws config describe-config-rules --query "ConfigRules[].[ConfigRuleName,ConfigRuleState]" --output table
```

```
recorder: journal-api-recorder  recording=True  lastStatus=SUCCESS
aws_config_delivery_channel: journal-api-delivery -> journal-api-config-607856468834-us-east-1
13 reglas, todas en estado ACTIVE
```

### El estado de conformidad

```bash
aws config get-compliance-details-by-config-rule --config-rule-name journal-api-iam-user-mfa
```

| Regla | Estado | Recurso |
|---|---|---|
| `journal-api-cloud-trail-encryption` | COMPLIANT | journal-api-audit |
| `journal-api-cloud-trail-log-file-validation` | COMPLIANT | journal-api-audit |
| `journal-api-cloud-trail-to-cloudwatch-logs` | COMPLIANT | journal-api-audit |
| `journal-api-ebs-encrypted` | COMPLIANT | vol-0227e86151a570b07 |
| `journal-api-imdsv2-required` | COMPLIANT | i-0d3f04316b63ee928 |
| `journal-api-no-public-ssh` | COMPLIANT | sg-03751b3f2c4b4948f |
| `journal-api-iam-unused-credentials` | COMPLIANT | AIDAY3BYRUNRLFAU42BIA |
| `journal-api-iam-password-policy` | **NON_COMPLIANT** | 607856468834 |
| `journal-api-iam-user-mfa` | **NON_COMPLIANT** | AIDAY3BYRUNRLFAU42BIA |
| `journal-api-guardduty-enabled` | SIN EVALUAR | (no hay detector) |
| `journal-api-s3-bucket-versioning` | SIN EVALUAR | |
| `journal-api-s3-public-access-block` | SIN EVALUAR | |
| `journal-api-s3-tls-only` | SIN EVALUAR | |

**Los dos hallazgos son reales**, no ruido:

- **La cuenta no tiene password policy.** Se verificó con
  `aws iam get-account-password-policy` →
  `NoSuchEntity: The Password Policy with domain name 607856468834 cannot be found`.
- **El usuario `rodri-dev` no tiene MFA**, y es `AdministratorAccess`. Es
  la credencial con más impacto de toda la cuenta.

Se comprobó que el hallazgo es **vivo** (no un estado viejo): se creó una
password policy, la regla pasó a `COMPLIANT`, se borró, y la regla volvió a
`NON_COMPLIANT`. El estado original de la cuenta quedó restaurado.

### El bug que encontró la captura de pantalla

La alarma `journal-api-security-secret-read` entró en `ALARM` a las 09:05
sin que nadie hubiera leído un secreto. La pregunta del runbook ("buscar
en el trail quién leyó los secretos") llevaba a la respuesta:

```
09:04:37  FilterLogEvents  source=logs.amazonaws.com
principal=arn:aws:iam::607856468834:user/rodri-dev
requestParameters={"filterPattern": "\"GetSecretValue\" \"secretsmanager.amazonaws.com\"", ...}
```

**La query de investigación era la que disparaba la alarma**: el patrón
del filtro (`"GetSecretValue" "secretsmanager.amazonaws.com" IAMUser`) está
completo dentro de los `requestParameters` de la llamada, y el principal es
un `IAMUser`.

El fix (agregar `"secretId"` al patrón) se verificó con `TestMetricFilter`
y en vivo:

| Prueba | Antes | Después |
|---|---|---|
| Lectura real de un secreto por el IAMUser | detectada | detectada ✅ |
| Query de investigación | **dispara la alarma** ❌ | no dispara ✅ |

### La cadena de notificación

```
AWS Config --(Config Configuration Item Change)--> EventBridge --> SNS --> correo
```

El patrón de EventBridge (regla `journal-api-config-changes`):

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

**Limitación verificada:** AWS Config **no** publica en esta cuenta el
evento `Config Rules Compliance Change` (el que avisaría de que una regla
pasó a `NON_COMPLIANT`). Se generaron dos cambios de conformidad reales y
en 5 minutos de captura con una regla catch-all sobre el bus default
**no apareció ningún evento de ese tipo**: solo los
`Config Configuration Item Change`. Por eso la alerta se hace sobre el
evento que sí llega (el cambio de configuración de un recurso
relevante) y no sobre el de conformidad. El estado de conformidad sigue
disponible en la consola de Config, en la API y en el historial de S3.

---

## 4. CodeQL

```bash
gh run list --repo amarillaRodrigo/journal-starter-pipeline --branch main
```

```
CodeQL   completed  success   a3f5c1f
CI       completed  success   a3f5c1f
```

El workflow está commiteado en los dos repositorios, pero **en el fork no
corre**:

```bash
gh workflow run verify-capstone.yml --repo amarillaRodrigo/journal-starter
# HTTP 422: Actions has been disabled for this repository
```

El fork hereda la desactivación de Actions del repositorio de origen
(`learntocloud/journal-starter`), que es de otra organización. El pipeline
entero vive en `journal-starter-pipeline`, que es un repositorio normal.

### Los hallazgos y su triaje

```bash
gh api repos/amarillaRodrigo/journal-starter-pipeline/code-scanning/alerts
```

| # | Regla | Ubicación | Triaje | Motivo |
|---|---|---|---|---|
| 1 | `py/clear-text-storage-sensitive-data` | `scripts/fetch_secrets.py:110` | `mitigated` | Diseño del proyecto: el init container baja los secretos a un `emptyDir` con permisos `0600`. La alternativa (Secret de Kubernetes) es peor: vive en etcd en base64. `scripts/verify-security.sh` lo comprueba en cada deploy. |
| 2 | `py/clear-text-logging-sensitive-data` | `scripts/fetch_secrets.py:132` | `false positive` | La línea imprime un contador y el directorio. Ningún valor de secreto. |

Estado final: **0 alertas abiertas**, 2 triadas con motivo visible en la
pestaña *Security → Code scanning*.

### Dependabot

`.github/dependabot.yml` con los ecosystems `github-actions` y `uv`. Al
publicarlo se abrieron **4 PRs** (2 de actions, 2 de `uv`), y el CI los
corrió en verde.

---

## 5. Runbook de respuesta a incidentes

[`docs/incident-response.md`](../incident-response.md) responde las tres
preguntas del enunciado, en el orden en que hay que responderlas:

1. **Rotar credenciales** — con el orden correcto por tipo de credencial
   (base de datos → secret → redeploy → verificar → revocar) y la regla de
   oro: *verificar la nueva antes de revocar la vieja*.
2. **Verificar si hubo acceso no autorizado** — las tres queries de
   CloudTrail (lecturas de secretos, logins de consola fallidos, creación
   de credenciales) con la tabla de cómo leer el resultado.
3. **Notificar** — el `sns publish` con la plantilla del mensaje y el orden
   de escalamiento.

El procedimiento largo que estaba en el runbook de producción (§14, en
español) se movió a ese documento para que no haya dos versiones de lo
mismo.

---

## 6. Lo que no se pudo hacer

| Ítem | Por qué | Qué quedó |
|---|---|---|
| GuardDuty | `SubscriptionRequiredException`: la cuenta no tiene método de pago, y **no se va a agregar** (decisión: todo free tier) | IaC lista y probada en `terraform/security.tf` detrás de `enable_guardduty`; la alarma existe. AWS Config cubre el rol de threat detection. |
| Evento de conformidad de AWS Config | AWS Config no lo publica en esta cuenta (verificado con captura directa) | La alerta se hace sobre el evento que sí llega; el estado de conformidad se consulta por API. |
| Que las alarmas corran en el fork | El repositorio de origen tiene Actions deshabilitado y el fork lo hereda | El pipeline vive en `journal-starter-pipeline`; el fork tiene el mismo código y los mismos workflows. |
| Migrar las alarmas del trail a EventBridge | No es un bloqueo: es que los metric filters ya están verificados end-to-end | Las reglas de EventBridge funcionan (verificado por captura directa); la migración queda como mejora pendiente. |

---

## 7. Costos: free tier, sin tarjeta

```bash
aws ce get-cost-and-usage --time-period Start=2026-11-01,End=2026-11-05 \
  --granularity MONTHLY --metrics UnblendedCost --group-by Type=DIMENSION,Key=SERVICE
```

```
AWS CloudTrail                              0 USD
AmazonCloudWatch                            0 USD
Amazon Simple Notification Service          0 USD
Amazon Simple Storage Service    0.0000000016 USD
AWS Key Management Service       -0.0000001034 USD
AWS X-Ray                                   0 USD
Amazon Elastic Compute Cloud - Compute       0 USD
Amazon EC2 Container Registry (ECR)          0 USD
Amazon Virtual Private Cloud                 0 USD
AWS Secrets Manager              -0.0000000768 USD
AWS Glue                                    0 USD
Tax                                         0 USD
```

**Total del mes: $0,00.** Los valores negativo-diminutos son créditos del
free tier cubriendo el cargo.

```bash
aws freetier get-free-tier-usage
```

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

Los nueve usos son **"Always Free"**: gratis permanente, no una promoción
de 6 meses. El pronóstico de fin de mes está bajo cada límite.

Y lo que hace el conjunto airtight: **la cuenta no tiene método de pago**,
así que no hay ni el mecanismo para cobrar. Dos presupuestos cortan
solo, los dos en `HEALTHY` con gasto $0,00, y **sus notificaciones
publican en el topic SNS del proyecto** (por eso llegan al mismo correo
que las alarmas):

| Presupuesto | Umbral | Avisa | Canal |
|---|---|---|---|
| `journal-capstone-budget` | $10,00/mes | 80% ($8) | SNS `journal-api-alarms` → email |
| `My Zero-Spend Budget` | $1,00/mes | 50%, 80% y 100% | SNS `journal-api-alarms` → email |

Las notificaciones se recrearon con suscriptor SNS: las que había no
tenían a nadie escuchando. Un suscriptor de email directo no se puede
agregar sin una dirección de billing verificada, y esa verificación pide
método de pago: el topic de SNS lo resuelve sin costo.

**GuardDuty no se activa, a propósito**: requiere suscripción de pago
(que el free tier no cubre) y cobra $4 por millón de eventos después de
los 30 días de prueba. AWS Config cubre el mismo rol de threat detection
dentro del free tier.
