# Retrospectiva: qué se construyó, qué se haría distinto y qué se aprendió

Cierre del bloque de **seguridad del capstone** (Learn to Cloud, Fase 3).

Fecha: 2026-11-05
Cuenta: `607856468834` (us-east-1)
Repos: `amarillaRodrigo/journal-starter` (fork canónico) y
`amarillaRodrigo/journal-starter-pipeline` (espejo, donde corre el pipeline)

---

## 1. Qué se implementó

### 1.1 Identidad y secretos

| Control | Cómo se resolvió | Dónde |
|---|---|---|
| La app no usa el rol de la instancia | Rol de servicio propio `journal-api-runtime-role` con `GetSecretValue`/`DescribeSecret` sobre **dos ARN exactos** | `terraform/secrets.tf` |
| El rol de la instancia no puede leer secretos | `Deny` explícito de `GetSecretValue`/`DescribeSecret` sobre `*`; solo puede **delegar** en el rol de la app con un `ExternalId` | `terraform/secrets.tf` |
| La credencial nunca está en etcd ni en el spec | Init container la baja de Secrets Manager a un `emptyDir` (`medium: Memory`), permisos `0600` | `k8s/deployment.yaml`, `k8s/postgresql.yaml` |
| La credencial nunca está en el estado de Terraform | Terraform crea solo el "cascarón" del secreto; el valor se siembra **fuera de banda** con `scripts/migrate-secrets.sh` | `terraform/secrets.tf` |
| El CI/CD no tiene llaves estáticas | OIDC de GitHub Actions contra `journal-github-actions`, con la condición de `sub` atada a repo + rama + environment | `terraform/main.tf` |
| El pipeline verifica la seguridad, no solo que el deploy fue verde | `scripts/verify-security.sh` corre **dentro** de la instancia y comprueba 11 invariantes; su exit code decide si el job pasa | `.github/workflows/ci.yml` |

La idea que ordena todo esto: **la app tiene su propia identidad**, y la
identidad de la instancia se reduces a "puede delegar, no puede leer". El
`ExternalId` es el `sub` del token de ServiceAccount del pod, así que un pod
de otro namespace no puede asumir el rol.

### 1.2 Auditoría y detección

| Control | Implementación |
|---|---|
| Audit trail | CloudTrail regional en us-east-1, con `include_global_service_events = true` (los eventos de IAM y STS son globales) y `enable_log_file_validation` (digest de integridad) |
| Archivo durable | Bucket S3 con SSE-KMS, versioning, lifecycle a Glacier y expiración a 365 días |
| Copia consultable | Log group en CloudWatch Logs con **13 metric filters** y **4 alarmas** de seguridad |
| Detección de amenazas | AWS Config: recorder + delivery channel + **13 reglas gestionadas**, 11 conformes y 3 hallazgos reales cerrados |
| Alerta de cambios de configuración | Regla de EventBridge sobre `Config Configuration Item Change` → SNS |
| Análisis estático | CodeQL + Dependabot (4 PRs abiertos), 2 alertas triadas |
| Costos | Dos presupuestos con notificaciones por SNS, cut-only |

### 1.3 Lo que se decidió **no** construir

- **GuardDuty, Security Hub, Inspector, Macie, Detective**: los cinco responden
  `SubscriptionRequiredException` porque la cuenta no tiene método de pago. Se
  dejó la IaC de GuardDuty escrita detrás de un flag, y AWS Config pasó a ser
  el threat detection (free tier, sin suscripción). **El requisito de no
  agregar una tarjeta es el que define esta arquitectura**, no al revés.
- **MFA del usuario en IaC**: el seed TOTP es una credencial y no puede vivir en
  un repositorio. Quedó como procedimiento manual documentado, con el seed
  fuera del repo.

---

## 2. Lo que se haría distinto

### 2.1 Habría exigido una VPC de dos capas desde el principio

La desviación más grande del proyecto (ítem 3 del checklist: base de datos en
subnet privada) no es un error de ejecución: es una decisión de **costo y
alcance** tomada al principio, cuando el proyecto todavía era "una instancia
que corre todo". Crear la subnet privada requiere una NAT Gateway (~$32/mes)
o mover la base a RDS (fuera del free tier), y las dos cosas rompen el
requisito de `$0,00`.

**Lo que habría que hacer distinto:** decidir explícitamente, al inicio, si
"aislamiento de red de la base de datos" es un requisito duro o un objetivo
documentado. Se decidió implícitamente por el costo, y el desvío apareció
al final, cuando ya no había margen. La subnet privada tampoco habría sido
mucho más difícil: el grueso del trabajo es el NAT y mover el secreto de la
base a la instancia privada, y el resto (SG con origen restringido, la base
lejos de la IP pública) es incremental.

La lección general: **una topología de una sola instancia tiene un techo de
seguridad**, y conviene saber dónde está ese techo antes de empezar, no
después.

### 2.2 Habría separado "verificar" de "verificar que el verificador funciona"

Varias veces durante el proyecto, una verificación dio un resultado que
resultó ser **falso negativo por culpa del verificador**, no del sistema:

- **EventBridge y SNS no publican métricas en esta cuenta.** `TriggeredRules`,
  `Publishes` y `NumberOfNotificationsSent` salían vacías, aunque los eventos
  llegaban. El diagnóstico original ("CloudTrail no entrega a EventBridge") era
  **falso**: la captura directa (regla → topic → cola SQS → leer la cola)
  mostró que los eventos llegan en menos de 15 segundos.

- **Un metric filter se auto-alimenta.** El patrón viaja dentro del request
  del API que crea el filtro, así que el filtro se contaba a sí mismo, y una
  alarma de "lectura no autorizada de secretos" disparaba **cuando alguien
  investigaba una lectura no autorizada**.

- **CloudTrail se pagina.** `filter_log-events` con `limit=200` devuelve los
  más recientes: los eventos viejos se pierden. Y filtrar por texto matchea
  eventos que mencionan el término (incluidas las propias queries).

**Lo que habría que hacer distinto:** todo verificador de seguridad debería
tener, desde el día uno, un **test de regresión** que demuestre que detecta lo
que dice detectar *y* que no dispara ante su propia investigación. En este
proyecto eso se terminó haciendo tarde y a mano (el patrón con `secretId` en
el filtro de secretos, los 3 periodos de evaluación en las alarmas). El
`verify-security.sh` del pipeline es el ejemplo de lo que debería haberse
escrito primero.

### 2.3 Habría automatizado antes la verificación en vivo

Casi todo el diagnóstico del proyecto se hizo **a mano**, con comandos
sueltos, en la consola. La mayor parte de ese conocimiento está hoy en los
documentos, pero no en **código que se pueda volver a correr**. Concreto:

- El chequeo de que el header HSTS está presente, que el SG no tiene 5432, que
  la retención del log group es 90 días y que 5432 da timeout desde afuera
  son todos comandos de una línea. Juntarlos en un `scripts/verify-posture.sh`
  los haría reproducibles y los dejaría listos para el `verify-security.sh`
  que ya corre en cada deploy.

- El hallazgo de que **Caddy no recarga un ConfigMap** (§4.1) se discovered
  por casualidad, al agregar HSTS y ver que el header no aparecía. Esa
  investigación debería haber sido un test automatizado.

### 2.4 Habría separado los "restos" de diagnóstico desde el principio

Los topics SNS `journal-api-eb-debug-*` y `journal-api-scratch-policy-test`, y
las colas SQS temporales, se crearon **fuera de Terraform** para capturar
eventos. Sobreviven a un `terraform destroy` y hubo que inventariarlos a mano
para el procedimiento de limpieza (`docs/cleanup.md` §4).

**Lo que habría que hacer distinto:** crear esos recursos de diagnóstico con
Terraform (o con un `terraform destroy -target` después), para que el
procedimiento de limpieza sea un `destroy` y no un `destroy` + una lista de
limpieza manual. La lista de §4 existe porque el inventario se hizo a mano:
es un trabajo que la IaC hace gratis.

### 2.5 Habría usado `includeSubDomains` con más cuidado

La decisión de **no** incluir `preload` en el header HSTS fue correcta (la
lista de preload exige controlar el dominio registrable, y
`3.215.52.10.sslip.io` no es de este proyecto). Pero `includeSubDomains` sí
se incluyó, y en un host de `sslip.io` eso tiene un efecto que merece
pensarse: `sslip.io` resuelve **cualquier** etiqueta delante de la IP al mismo
servidor, así que la política HSTS alcanza a todos esos subdominios. Aquí es
inofensivo (son todos el mismo servidor), pero en un dominio real sería una
decisión a tomar con el criterio del dominio, no por defecto.

---

## 3. Los aprendizajes

### 3.1 Los que dejó el proyecto

**1. Un "no" bien justificado vale más que un "sí" incompleto.** GuardDuty,
Security Hub, Inspector, Macie y Detective son el threat detection canónico
de AWS. No se pudieron activar. La decisión no fue "dejar el ítem sin hacer",
sino documentar por qué, dejar la IaC lista, y poner AWS Config en su lugar
con una justificación de costo explícita. Un capstone que dice "no se puede,
y esto es lo que hice en su lugar, y por qué" enseña más que uno que dice
"no se puede".

**2. Un control que no se puede medir no es un control.** Entregar un
`Caddyfile` con HSTS sin verificar que el navegador lo recibiera habría sido
"implementado" y "no funcionando". Lo mismo con las alarmas: una alarma que
nunca se vio disparar no es evidencia de nada. La disciplina de *verificar el
verificador* (§2.2) fue el hilo conductor de todo el bloque.

**3. La seguridad real es una cadena, y se rompe en el eslabón más barato.**
En este proyecto el eslabón más barato era el **spec del pod**: legible por
cualquiera con `get pods`. Toda la arquitectura de Secrets Manager sirve
precisamente para que ese eslabón no exista. Y el segundo eslabón barato era
la **tabla de Terraform**: un secreto en `terraform.tfstate` es un secreto en
un archivo de texto.

**4. Un `destroy` es un diseño, no un comando.** Los buckets con
`force_destroy = false`, la ventana de 30 días de la clave KMS y la de 7 días
de los secretos son decisiones que alguien tomó pensando en el día en que se
borra todo. Que el procedimiento de limpieza exista y esté escrito (y que
diga exactamente qué se rompe y por qué) es parte del trabajo de seguridad,
no un extra.

### 3.2 Los que son técnicos y transferibles

**5. `kubectl apply` de un ConfigMap no recarga una app que lo lee desde
disco.** Este es el hallazgo más caro del proyecto y el que más tiempo
consumió. Está documentado en detalle en §4.1 porque la estrategia del
sistema (checksum en el pod template) es la que se va a necesitar en
cualquier proyecto que sirva su configuración desde un ConfigMap.

**6. El tráfico de red se corta en el grupo de seguridad, no en el
proceso.** El Postgres escuchaba en `0.0.0.0:5432` **dentro del pod**, y el
nodo no tenía ningún listener en 5432. Lo que hacía imposible el acceso
externo eran tres capas independientes: el SG (no abre 5432), el tipo de
servicio (`ClusterIP`, sin `NodePort`) y la ausencia de `hostPort`. **Cada
capa sola habría bastado**; las tres juntas es lo que hace que la
verificación sea concluyente.

**7. Un único plano de fallo es un plano de fallo.** La instancia, el cluster
de k3s, la base de datos, la red y el ingress están todos en el mismo lugar.
Eso no es una decisión de seguridad sino de simplicidad, y tiene un precio
concreto: no hay forma de que la base de datos esté aislada sin que el
ingress también lo esté, porque **son la misma máquina**.

**8. Lo que no se puede automatizar tiene que estar documentado con el mismo
cuidado que lo que sí.** El MFA del usuario no se puede manejar en Terraform
(el seed TOTP es una credencial). Quedó como procedimiento manual, con el
seed en `~/.aws/` con permisos restringidos y fuera del repo. La regla que
surgió: *si un paso del checklist no puede ser IaC, entonces el procedimiento
manual es parte del entregable y tiene el mismo nivel de detalle que el
código*.

**9. Los entornos reales rompen las herramientas.** En esta cuenta: las
métricas de EventBridge y de SNS no se publican; el `boto3` local exige
parámetros en PascalCase en algunos servicios y devuelve `dict`s en vez de
strings; el AWS CLI local no tiene el servicio `config`; los QR de MFA son
bytes PNG crudos. **La lección:** un verificador que depende de una
herramienta del entorno es un verificador frágil, y hay que tener un segundo
camino (captura directa en vez de métrica, `boto3` en vez de CLI) para cuando
el primero falla. La mitad de los "hallazgos" iniciales de este proyecto
eran fallas del verificador.

---

## 4. La lección técnica del proyecto, en detalle

### 4.1 Caddy no recarga un ConfigMap: el cambio se pierde en silencio

**Síntoma:** se agregó el header `Strict-Transport-Security` al `Caddyfile`
(`k8s/caddy.yaml`), se aplicó el manifiesto y el header **no apareció** en las
respuestas.

**Diagnóstico** (con un pod de prueba, no en producción):

1. El kubelet **sí** actualiza el archivo en el volumen del pod: se verificó
   que a los ~50 s el `Caddyfile` en disco ya tenía el contenido nuevo.
2. Caddy **no** lo releía: la respuesta seguía siendo la vieja.
3. Se repitió el experimento **con `admin off` y con el admin API activo**, y
   el resultado fue el mismo: cero mensajes de recarga en los logs.

**Causa raíz:** el watcher de Caddy sigue el **inodo** del archivo de
configuración, y el kubelet actualiza los volúmenes de ConfigMap de forma
**atómica**: escribe en un directorio nuevo y hace un *swap* del symlink
`..data`. El inodo que Caddy tenía abierto desaparece y nunca se emite un
evento de modificación sobre el archivo nuevo. Con `admin off` tampoco hay
la vía alternativa (el admin API) para forzar un `reload`.

**Por qué es peligroso:** el `kubectl apply` **reporta éxito**, el rollout
**reporta éxito**, el ConfigMap **está actualizado** en la API de
Kubernetes... y el servidor sigue sirviendo la configuración vieja. Un cambio
de seguridad aplicado de esta forma es un cambio que **nunca existió**, y
nadie se entera salvo que alguien mire los headers.

**Solución implementada:** un **checksum del manifiesto renderizado** en una
anotación del pod template:

```yaml
template:
  metadata:
    annotations:
      caddyfile-checksum: "__CADDY_CHECKSUM__"
```

`scripts/deploy-k8s.sh` renderiza el manifiesto, le calcula el `sha256` y lo
sustituye antes de aplicar. Cuando el Caddyfile cambia, la anotación cambia,
el pod template cambia y Kubernetes hace el rollout: el pod nuevo arranca con
el ConfigMap nuevo.

El rollout es barato: Caddy es stateless salvo el PVC de certificados (que
sobrevive al `Recreate`).

**Generalización:** cualquier aplicación que lea su configuración de un
ConfigMap necesita un mecanismo de *disparo* del rollout, no solo el
`apply`. Las tres formas habituales son el checksum (la que se usó acá), un
`kubectl rollout restart` explícito, o un sidecar que recargue.

### 4.2 Un group de seguridad con dos puertos abiertos protege más de lo que parece

El caso del ítem 3 (base de datos en subnet privada) se resolvió documentando
la desviación, pero el trabajo de verificación **sí** dio un resultado
sólido: la base de datos **no es alcanzable desde Internet**, y eso se
comprueba en tres capas independientes (SG sin 5432, `ClusterIP` sin
`NodePort`, sin `hostPort`). Está en `docs/network-isolation.md`.

Lo interesante del caso es que **la subnet privada no habría protegido
mucho más**: un atacante que compromete el nodo igual llega a Postgres por la
red de pods. Lo que realmente protege los datos es que **la password no esté
en el pod**. La subnet privada es la segunda capa; esa es la primera.

---

## 5. Lo que queda

| Ítem | Estado | Dónde |
|---|---|---|
| Ejecución del cleanup | **Pendiente**, a la espera del gate humano | `docs/cleanup.md` |
| Cerrar el desvío del ítem 3 (subnet privada) | Documentado, no implementado | `docs/network-isolation.md` §5 |
| Activar GuardDuty | Requiere método de pago | `terraform/security.tf` (flag `enable_guardduty`) |
| Migrar las alertas a EventBridge | Pendiente: el trail **sí** entrega a EventBridge (el diagnóstico anterior era falso) | `docs/security.md` §7 |
| Migrar la base a RDS y el ingress a un ALB | Fuera del free tier | `docs/network-isolation.md` §5 |

---

## 6. Las tres frases que resumen el proyecto

1. **La seguridad que no se verifica no existe; y la verificación que no se
   prueba, tampoco.**
2. **Decir "no" con una justificación medible vale más que decir "sí" a
   medias.**
3. **Un plan de limpieza es parte del plan de seguridad.**
