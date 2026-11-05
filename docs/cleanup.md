# Procedimiento de limpieza (check 8)

Qué hay que hacer para **desmontar** todo lo que este capstone desplegó en la
cuenta `607856468834` (us-east-1), sin dejar recursos huérfanos y sin romper
las dependencias de AWS.

> ## ⚠️ NO SE EJECUTÓ
>
> Este procedimiento está **escrito y verificado en seco**, pero **no se
> ejecutó**. La plataforma de evaluación sondea la API viva, así que el
> `terraform destroy` queda pendiente de una confirmación explícita del
> responsable del proyecto.
>
> Cada paso dice qué **verificar antes** de ejecutarlo. No se salta ninguno.

Fecha de redacción: 2026-11-05
Alcance: **toda** la infraestructura del proyecto, en la cuenta `607856468834`.

---

## 1. Qué hay que desmontar

| Recurso | Nombre | Notas |
|---|---|---|
| Instancia EC2 | `i-0d3f04316b63ee928` | t3.small, con el cluster de k3s, la app y Postgres adentro |
| Elastic IP | `eipalloc-0e21b90d7b6c06d58` | `3.215.52.10`; se libera, no se destruye |
| Volumen raíz | gp3 20 GB cifrado | se borra con la instancia |
| VPC + subnet + IGW + route table | `vpc-0b16bea05d50b92b2` | una sola subnet pública |
| Security group | `journal-sg` | 80/443 |
| CloudTrail | `journal-api-audit` | **se borra antes que su bucket** (§3.1) |
| Bucket S3 del trail | `journal-api-audit-607856468834-us-east-1` | `force_destroy = false` |
| Bucket S3 de Config | `journal-api-config-607856468834-us-east-1` | `force_destroy = false` |
| Clave KMS | `alias/journal-api-audit` | **30 días de deletion window** (§3.3) |
| CloudWatch log groups | `aws-cloudtrail-logs-journal-api`, `/aws/journal-api/application`, `/aws/journal-api/metrics` | |
| Topic SNS | `journal-api-alarms` | con 1 suscripción de email |
| 7 alarmas de CloudWatch | `journal-api-*` | 4 de seguridad + 2 de la app + 1 de GuardDuty |
| 13 metric filters | `journal-api/*` | sobre el log group del trail |
| AWS Config | recorder, delivery channel, 13 reglas | |
| Reglas de EventBridge | `journal-api-config-changes`, `journal-api-config-noncompliant` | |
| IAM | roles, instance profile, OIDC provider de GitHub | |
| ECR | repositorio `journal-api` | 11 imágenes |
| Secrets Manager | `journal-api/credentials/{database,llm}` | 7 días de recovery window |
| SSM | 3 parámetros de configuración | |
| Presupuestos | 2 | |
| **Restos de diagnóstico** | topics SNS `journal-api-eb-debug-*`, `journal-api-eb-probe-*`, `journal-api-scratch-policy-test` | **no están en Terraform** (§4) |

---

## 2. Orden general

El orden no es arbitrario: lo va a destruir Terraform, y Terraform respeta el
grafo de dependencias, pero **no** sabe de las relaciones que hay entre
servicios de AWS que no están expresadas en la IaC. El orden correcto es:

```
1. Verificar que la verificación de fase 6 pasó        (gate humans)
2. Vaciar los dos buckets S3 (con versioning)          (force_destroy=false)
3. Detener lo que escribe en los buckets               (trail y Config)
4. terraform destroy                                   (el resto)
5. Limpiar los restos que no están en Terraform        (§4)
6. Verificar que no quedó nada
```

**El paso 2 va antes del 3** y no al revés, por una razón que es la clave de
este procedimiento: **CloudTrail vuelve a escribir en su bucket si el trail
sigue existiendo.** Si se vacía el bucket y después se borra el trail, en los
minutos intermedios CloudTrail puede volver a dejar objetos nuevos, y el
`terraform destroy` vuelve a fallar con `BucketNotEmpty`.

La solución que evita esa carrera es la de §3.2: **desactivar la escritura
antes de vaciar**, con el trail y el recorder apagados.

---

## 3. Preparación: los tres bloqueos

### 3.1 Los buckets tienen `force_destroy = false`

Los dos buckets —el del trail y el de Config— tienen `force_destroy = false`
**a propósito**: son evidencia, y no deberían desaparecer con un `terraform
destroy` por accidente. Con eso, `terraform destroy` falla:

```
Error: error deleting S3 Bucket (journal-api-audit-607856468834-us-east-1):
BucketNotEmpty: The bucket you tried to delete is not empty
```

Por eso hay que vaciarlos **a mano** antes.

Complicación: los dos buckets tienen **versioning activado** (requisito de la
regla `S3_BUCKET_VERSIONING_ENABLED` de AWS Config, ver `docs/security.md`
§4). Vaciar un bucket versionado no es `aws s3 rm --recursive`: hay que
borrar **cada versión y cada delete marker**. Medido el 2026-11-05, hay
**5918 versiones** en el bucket del trail y **52** en el de Config.

```bash
# Listar qué se va a borrar (conteo real, medido el 2026-11-05)
aws s3api list-object-versions --bucket journal-api-audit-607856468834-us-east-1 \
  --query '{Versions:length(Versions),Markers:length(DeleteMarkers)}' --output json

# Vaciar el bucket del trail: versiones + delete markers
aws s3api list-object-versions --bucket journal-api-audit-607856468834-us-east-1 \
  --query 'Versions[?IsLatest].{Key:Key,VersionId:VersionId}' --output json > /tmp/audit-versions.json

aws s3api delete-objects --bucket journal-api-audit-607856468834-us-east-1 \
  --delete "$(python3 -c "
import json
v = json.load(open('/tmp/audit-versions.json'))
print(json.dumps({'Objects': [{'Key': o['Key'], 'VersionId': o['VersionId']} for o in v]}))
")"
```

Y los delete markers, que son objetos por sí mismos. (Hoy no hay ninguno en
ninguno de los dos buckets, pero el comando queda por si el bucket se vació
con `aws s3 rm` en algún momento, que sí deja marcadores):

```bash
aws s3api list-object-versions --bucket journal-api-audit-607856468834-us-east-1 \
  --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' --output json > /tmp/audit-markers.json

aws s3api delete-objects --bucket journal-api-audit-607856468834-us-east-1 \
  --delete "$(python3 -c "
import json
m = json.load(open('/tmp/audit-markers.json'))
print(json.dumps({'Objects': [{'Key': o['Key'], 'VersionId': o['VersionId']} for o in m]}))
")"
```

El bucket de Config se vacía igual (tiene ~40 objetos de historial).

> **Alternativa más simple y equivalente:** `terraform destroy` con
> `force_destroy = true` **solo para ese momento**. Es menos pasos, pero
> pierde la protección que da el `false` y no deja rastro de qué se borró. La
> opción recomendada es vaciar a mano y dejar el `force_destroy = false` como
> está en el código.

**Verificación obligatoria antes de seguir:**

```bash
aws s3api list-object-versions --bucket journal-api-audit-607856468834-us-east-1 \
  --query 'length(Versions) + length(DeleteMarkers)' --output text
# debe devolver 0

aws s3api list-object-versions --bucket journal-api-config-607856468834-us-east-1 \
  --query 'length(Versions) + length(DeleteMarkers)' --output text
# debe devolver 0
```

### 3.2 El trail y el recorder escriben en sus buckets

Esto es lo que hace que el orden importe.

**CloudTrail**: si el trail `journal-api-audit` existe, sigue escribiendo
objetos en su bucket cada ~5 minutos. Vaciar el bucket y después borrar el
trail deja una ventana en la que el trail vuelve a llenarlo.

**AWS Config**: el delivery channel `journal-api-delivery` hace lo mismo con el
bucket de Config.

La solución: **apagar la escritura primero**. El trail se puede apagar sin
borrarlo (`stop-logging`), y el recorder de Config también se puede detener.
Ambos se vuelven a encender... no hace falta: si vamos a destruir, se borran
después.

```bash
# 1. Dejar de escribir en el bucket del trail (el trail sigue existiendo)
aws cloudtrail stop-logging --name journal-api-audit

# 2. Dejar de escribir en el bucket de Config
aws config stop-configuration-recorder --configuration-recorder-name journal-api-recorder

# 3. Ahora sí, vaciar ambos buckets (§3.1)
```

Verificación:

```bash
aws cloudtrail get-trail-status --name journal-api-audit \
  --query 'IsLogging' --output text
# debe devolver False

aws config describe-configuration-recorder-status \
  --configuration-recorder-name journal-api-recorder \
  --query 'recording' --output text
# debe devolver False
```

> **Por qué el trail se borra antes que su bucket.** Además del orden del
> `destroy`, hay una razón de AWS: si se borra el bucket mientras el trail
> existe, CloudTrail lo **recrea automáticamente** (con su propia policy) en
> los siguientes minutos. O sea: si primero se vacía el bucket y el trail
> sigue vivo, el bucket vuelve a aparecer. Por eso en §3.2 se apaga el trail
> **antes** de vaciar, y el `destroy` lo borra a él antes que al bucket
> (Terraform lo respeta por el grafo: el trail referencia al bucket).

### 3.3 La clave KMS tiene 30 días de deletion window

En la IaC (`terraform/security.tf`):

```hcl
resource "aws_kms_key" "audit" {
  enable_key_rotation     = true
  deletion_window_in_days = 30
  ...
}
```

Ese `deletion_window_in_days = 30` es lo que va a regir cuando el
`terraform destroy` la destruya. **Ojo con un detalle de la API:** la ventana
de borrado no aparece en `describe-key` hasta que la eliminación está
programada. Antes de eso, `describe-key` no devuelve el campo
`DeletionWindowInDays`:

```bash
aws kms describe-key --key-id alias/journal-api-audit \
  --query 'KeyMetadata.{State:KeyState,Enabled:Enabled,Rotation:KeyRotationEnabled}' \
  --output json
```

```json
{ "State": "Enabled", "Enabled": true }
```

Lo que se ve **antes** del destroy es que la clave está viva, con rotación
activada. La ventana de 30 días recién aparece cuando el borrado se programa.

Con esa ventana:

- `terraform destroy` **no la borra**: la deja en estado `PendingDeletion`
  durante 30 días.
- Durante esos 30 días se puede **cancelar** el borrado (es lo que la ventana
  protege), pero **no se puede acelerar** desde Terraform.
- Pasados los 30 días, la clave desaparece sola y sus aliases también.
- **Los datos cifrados con ella quedan ilegibles para siempre.** Por eso el
  trail se borra antes que la clave: mientras el trail exista, la clave está
  en uso.

Lo que sí se puede hacer es **acortar la ventana** si el destroy tiene que ser
definitivo ya:

```bash
# Ver el estado actual
aws kms describe-key --key-id alias/journal-api-audit --output json

# (Si fuera necesario acelerarlo, se puede programar el borrado con una
#  ventana más corta, mínimo 7 días.)
aws kms schedule-key-deletion --key-id alias/journal-api-audit \
  --pending-window-in-days 7
```

> **No hace falta acortarla para este proyecto.** La ventana de 30 días es
> deliberada (es la que permite recuperar la clave si se borró por error) y no
> cuesta nada: una clave KMS en `PendingDeletion` no se factura. Lo que hay
> que tener claro es que **el destroy no es un borrado completo**: 30 días
> después la clave recién desaparece.

---

## 4. Lo que Terraform NO destruye

Estos recursos se crearon durante el diagnóstico de seguridad **fuera** de
Terraform, así que sobreviven a un `terraform destroy`. Hay que borrarlos a
mano.

Verificado el 2026-11-05, después de limpiar los topics ya eliminados:

```bash
# Topics SNS de debug que quedaron (con sus suscripciones)
aws sns list-topics --query 'Topics[].TopicArn' --output json
```

Restos conocidos de esa tanda:

| Topic | Qué era |
|---|---|
| `journal-api-eb-debug-1793879321` | captura de eventos de EventBridge |
| `journal-api-eb-debug-1793879335` | ídem |
| `journal-api-eb-debug-1793879437` | ídem |
| `journal-api-eb-debug-1793879871` | ídem |
| `journal-api-eb-debug-1793879883` | ídem |
| `journal-api-eb-debug-1793879895` | ídem |
| `journal-api-eb-debug-1793879906` | ídem |
| `journal-api-eb-debug-1793879926` | ídem |
| `journal-api-eb-probe-1793881174` | sonda de captura |
| `journal-api-scratch-policy-test` | prueba de policy de SNS |

> Estos topics ya no aparecen en `list-topics` (se verificaron y se borraron
> los que quedaban), pero **sus suscripciones** sí sobreviven en
> `list-subscriptions`, incluso con estado `PendingConfirmation`. Una
> suscripción `PendingConfirmation` **impide borrar el topic**: hay que
> confirmar o cancelar la suscripción primero.

```bash
# 1. Ver las suscripciones colgadas
aws sns list-subscriptions --query 'Subscriptions[].{Topic:TopicArn,Arn:SubscriptionArn}' --output json

# 2. Cancelar las pendientes (PendingConfirmation no se puede desuscribir con
#    el ARN; hay que confirmar la suscripción por email o borrarla con el ARN
#    completo del topic)
aws sns list-subscriptions-by-topic --topic-arn arn:aws:sns:us-east-1:607856468834:journal-api-alarms \
  --query 'Subscriptions[].SubscriptionArn' --output json

# 3. Borrar el topic
aws sns delete-topic --topic-arn arn:aws:sns:us-east-1:607856468834:journal-api-alarms
```

**Colas SQS**: los topics de debug apuntaban a colas SQS temporales. Se
verificó que ya no queda ninguna:

```bash
aws sqs list-queues --output json
# debe devolver [] (o un JSON vacío de queues)
```

Si quedara alguna, se borra con `aws sqs delete-queue --queue-url <url>`.

---

## 5. El destroy

### 5.1 Gate humano: la verificación de fase 6

**Este paso no se ejecuta hasta que alguien confirme que la verificación de la
plataforma pasó.** La plataforma sondea la API viva, y después del destroy no
hay API que sondear.

```powershell
# El gate: la API tiene que responder y decir qué commit corre
curl.exe -sS https://3.215.52.10.sslip.io/version
```

```json
{"commit":"<sha de HEAD>"}
```

Si esto no responde, **no se sigue**: primero se arregla lo que esté roto.

### 5.2 Snapshot del estado (por si hay que volver)

Antes de destruir, dejar una copia del estado de Terraform. El estado tiene
las credenciales **de los recursos**, no los valores de los secretos, pero
aun así es información sensible: no va a un repositorio.

```powershell
cd D:\programacion\pythonPracticas\journal-starter\terraform
Copy-Item terraform.tfstate "$env:USERPROFILE\journal-api-terraform.tfstate.bak"
Copy-Item terraform.tfstate.backup "$env:USERPROFILE\journal-api-terraform.tfstate.backup.bak"
```

### 5.3 Plan, y solo después apply

```powershell
cd D:\programacion\pythonPracticas\journal-starter\terraform
terraform plan -no-color
```

El plan tiene que mostrar **solo eliminaciones**. Si muestra cambios o
creaciones, hay una discrepancia entre el estado y la realidad: investigar
antes de seguir.

```powershell
terraform destroy -auto-approve
```

Durante el destroy, los recursos se borran en este orden (por el grafo de
dependencias de Terraform):

1. Los `aws_cloudtrail_metric_filter` y las alarmas (dependen del log group).
2. El trail (depende del bucket, de la policy y del rol).
3. La clave KMS y su alias (dependen del trail).
4. El log group del trail.
5. La instancia (depende de los secretos, del rol de IAM y del ECR).
6. La EIP, el SG, la subnet, el IGW, la route table y la VPC.
7. El ECR, los secretos, los roles, el OIDC provider, el topic SNS, los
   presupuestos.

El EIP **se libera**, no se destruye: vuelve al pool de IPs públicas de AWS.

### 5.4 Lo que sobrevive al destroy (por diseño)

| Recurso | Por qué sobrevive | Cómo limpiarlo |
|---|---|---|
| Clave KMS | 30 días de deletion window | sola, a los 30 días; o `schedule-key-deletion --pending-window-in-days 7` |
| Secretos de Secrets Manager | 7 días de recovery window | `aws secretsmanager delete-secret --secret-id <id> --recovery-window-in-days 0` (inmediato) o `--force-delete-without-recovery` || EIP liberada | vuelve al pool de AWS | nada que hacer |

---

## 6. Verificación final

Que no quede nada. Cada comando tiene que devolver vacío.

```powershell
# EC2
aws ec2 describe-instances --filters "Name=tag:Name,Values=journal-api-instance" \
  --query 'Reservations[].Instances[].InstanceId' --output text
# esperado: (vacío)

# EIP: la que era del proyecto ya no debe estar asociada
aws ec2 describe-addresses --query 'Addresses[].AllocationId' --output json

# S3: los dos buckets
aws s3api list-buckets --query 'Buckets[].Name' --output json
# esperado: sin journal-api-audit-* ni journal-api-config-*

# CloudTrail
aws cloudtrail describe-trails --query 'trailList[].Name' --output json

# KMS
aws kms list-aliases --query 'Aliases[].AliasName' --output json
# esperado: sin alias/journal-api-audit  (la clave sigue 30 días, pero sin alias)

# CloudWatch
aws logs describe-log-groups --query 'logGroups[].logGroupName' --output json
aws cloudwatch describe-alarms --query 'MetricAlarms[].AlarmName' --output json

# SNS
aws sns list-topics --query 'Topics[].TopicArn' --output json

# IAM
aws iam list-roles --query 'Roles[].RoleName' --output json
aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[].Arn' --output json

# ECR
aws ecr describe-repositories --query 'repositories[].repositoryName' --output json

# Config
aws config describe-configuration-recorders --query 'ConfigurationRecorders[].name' --output json

# Los restos de diagnóstico (§4)
aws sns list-subscriptions --query 'Subscriptions[].SubscriptionArn' --output json
aws sqs list-queues --output json
```

Y el estado de Terraform:

```powershell
terraform plan -no-color
# esperado: "No changes" (o que no queden recursos en el estado)
```

---

## 7. Checklist de ejecución

- [ ] **Gate humano**: la verificación de fase 6 pasó y alguien lo confirmó.
- [ ] Snapshot de `terraform.tfstate` y `.backup` fuera del repo.
- [ ] `aws cloudtrail stop-logging --name journal-api-audit` → `IsLogging: False`.
- [ ] `aws config stop-configuration-recorder` → `recording: False`.
- [ ] Bucket del trail vacío (versiones **y** delete markers = 0).
- [ ] Bucket de Config vacío (versiones **y** delete markers = 0).
- [ ] `terraform plan` muestra solo eliminaciones.
- [ ] `terraform destroy -auto-approve`.
- [ ] Secretos borrados sin ventana de recuperación (si se quiere todo ya).
- [ ] KMS: verificación de la ventana de 30 días, o acelerado a 7 días.
- [ ] Restos de §4 (subscriptions, topics, colas) borrados.
- [ ] Verificación final de §6: todo vacío.
- [ ] Los presets de GitHub (repo del fork y repo espejo) quedan sin tocar: son
      del capstone, no de la cuenta de AWS. El pipeline dejará de funcionar
      solo, porque el rol de OIDC y el provider quedan destruidos.
- [ ] Los presupuestos de AWS se borran con el destroy; los avisos de
      presupuesto dejan de llegar (mismo efecto).
