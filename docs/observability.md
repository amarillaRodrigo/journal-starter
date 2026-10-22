# Observabilidad de Journal API en AWS

Pipeline de telemetría del capstone: la API emite OpenTelemetry por OTLP, el
**ADOT Collector** lo traduce a **X-Ray** (trazas) y **CloudWatch** (métricas
EMF), y **Fluent Bit** envía los logs de los pods a **CloudWatch Logs**.
Todo lo nuevo se crea con Terraform (`terraform/monitoring.tf`) y no hay
credenciales en el repositorio: los pods usan el instance profile vía IMDS
(hop limit 2) y los valores sensibles viven en SSM Parameter Store.

## Arquitectura del pipeline

```text
        journal-api pod (FastAPI + OTel SDK)
                 │  OTLP/HTTP :4318
                 ▼
        adot-collector (Deployment, namespace journal-api)
          ├── awsxray  ──────────────► AWS X-Ray
          └── awsemf   ──────────────► CloudWatch Logs (/aws/journal-api/metrics)
                                          └─ EMF ─► CloudWatch metrics (JournalAPI)

        stdout de los pods
                 │  /var/log/containers/*.log (hostPath)
                 ▼
        fluent-bit (DaemonSet)
          └── cloudwatch_logs ───────► CloudWatch Logs (/aws/journal-api/application)

        CloudWatch ──► dashboard journal-api
                   └─► alarmas journal-api-http-5xx / journal-api-latency-p95
                          └─► SNS journal-api-alarms ─► email
```

| Recurso | Identificador |
|---|---|
| Dashboard | `arn:aws:cloudwatch::607856468834:dashboard/journal-api` |
| Alarma 5xx | `arn:aws:cloudwatch:us-east-1:607856468834:alarm:journal-api-http-5xx` |
| Alarma latencia | `arn:aws:cloudwatch:us-east-1:607856468834:alarm:journal-api-latency-p95` |
| Topic SNS | `arn:aws:sns:us-east-1:607856468834:journal-api-alarms` |
| Log group app | `/aws/journal-api/application` (retención 7 días) |
| Log group métricas | `/aws/journal-api/metrics` (retención 7 días) |
| Namespace de métricas | `JournalAPI` |

Dashboard:
<https://us-east-1.console.aws.amazon.com/cloudwatch/home?region=us-east-1#dashboards:name=journal-api>

## 5.1 Instrumentación de la aplicación

Todo el SDK se configura en `api/telemetry.py` y se activa desde `api/main.py`
con `instrument_app(app)`.

**Resource** (identifica cada señal con el commit que la produjo):

| Atributo | Valor |
|---|---|
| `service.name` | `journal-api` (`OTEL_SERVICE_NAME`) |
| `service.version` | `GIT_SHA` inyectado en el build (`--build-arg GIT_SHA=<sha>`) |
| `deployment.environment` | `production` (`ENVIRONMENT`) |

**Spans**

- Automáticos: `FastAPIInstrumentor` (HTTP server, `http send`/`http receive`).
- Custom de base de datos (`api/repositories/postgres_repository.py`):
  `db.entries.insert`, `db.entries.select`, `db.entries.select_all`,
  `db.entries.update`, `db.entries.delete`, `db.entries.delete_all`.
  Metadata: `db.sql.table`, `db.operation`, `db.rows_returned`, `entry.id`.
- Custom de LLM (`api/services/llm_service.py`): `llm.analyze_entry` con
  `llm.provider`, `llm.model`, `entry.id`; marca `fault` cuando el proveedor falla.

**Métricas** (`meter = get_meter("journal-api")`)

| Métrica | Tipo | Dimensiones |
|---|---|---|
| `journal.http.requests.total` | Counter | `status_class` (2xx/3xx/4xx/5xx) |
| `journal.http.request.duration` | Histogram (ms) | `route` |
| `journal.http.latency.p50` / `.p95` | ObservableGauge (ms) | — (ventana de 500 requests) |
| `journal.entries.created` | Counter | — |
| `journal.db.query.duration` | Histogram (ms) | `db_operation` |
| `journal.analysis.duration` | Histogram (ms) | `llm_model` |

El middleware `TelemetryMiddleware` cuenta requests y alimenta la ventana de
percentiles; excluye `/version`, `/openapi.json`, `/docs`, `/redoc` y
`/favicon.ico` para que los probes de Kubernetes no ensucien las métricas de
negocio. `OTEL_SDK_DISABLED=true` desactiva exporters y threads de red (lo usa
el job `test` de CI).

## 5.2 Trazas en X-Ray

El collector exporta al backend `awsxray`; los spans quedan agrupados por traza
con el segmento `journal-api` y los subsegmentos custom.

Ejemplo real (`BatchGetTraces`, PATCH de una entrada):

```text
SEG journal-api  http://3.216.116.179.sslip.io/entries/a53812e8-...
  SUB PATCH /entries/entry_id       http send
  SUB PATCH /entries/entry_id       http send
  SUB PATCH /entries/entry_id       http receive
  SUB db.entries.update             dur=2.7 ms
  SUB PATCH /entries/entry_id       http send
```

Y el camino del análisis con LLM (proveedor sin crédito, por eso `fault`):

```text
SUB llm.analyze_entry   fault=True
    llm.provider=openai  llm.model=gpt-4o-mini  entry.id=a53812e8-...
SUB db.entries.select   db.operation=SELECT  db.rows_returned=1
```

Consulta usada:

```bash
aws xray get-trace-summaries \
  --start-time "$(date -u -d '-60 min' +%s)" \
  --end-time "$(date -u +%s)" \
  --filter-expression 'service("journal-api")' \
  --region us-east-1
```

En la ventana de verificación X-Ray devolvió **128 trazas** con
`service("journal-api")`, incluyendo `GET /entries`, `GET /entries/{id}`,
`POST /entries`, `PATCH /entries/{id}` y `POST /entries/{id}/analyze`.

## 5.3 Métricas en CloudWatch

El exporter `awsemf` escribe documentos EMF en `/aws/journal-api/metrics` y
CloudWatch los extrae al namespace `JournalAPI`. Se configuró
`dimension_rollup_option: NoDimensionRollup` y
`resource_to_telemetry_conversion: false` para no multiplicar series (costo).

> **Detalle importante:** el exporter agrega siempre la dimensión `OTelLib`
> (nombre del scope de OpenTelemetry, `journal-api`). CloudWatch exige que el
> set de dimensiones coincida **exacto**, así que tanto el dashboard como las
> alarmas la declaran de forma explícita (`OTelLib = var.project`). Sin eso las
> alarmas quedan en `OK` para siempre aunque haya errores.

Series publicadas (15 combinaciones métrica + dimensiones), por ejemplo:

```text
journal.http.requests.total        OTelLib=journal-api, status_class=2xx|3xx|4xx|5xx
journal.http.request.duration      OTelLib=journal-api, route=/entries|/entries/{entry_id}|/entries/{entry_id}/analyze
journal.db.query.duration          OTelLib=journal-api, db_operation=INSERT|SELECT|SELECT_ALL|UPDATE
journal.analysis.duration          OTelLib=journal-api, llm_model=gpt-4o-mini
journal.entries.created            OTelLib=journal-api
journal.http.latency.p50 / p95     OTelLib=journal-api
```

Valores observados durante la verificación:

| Métrica | Valor |
|---|---|
| `journal.http.requests.total{status_class=2xx}` | 3 requests/min |
| `journal.http.requests.total{status_class=4xx}` | 3 requests/min |
| `journal.http.request.duration{route=/entries}` | ~3 ms (avg) |
| `journal.db.query.duration{db_operation=SELECT_ALL}` | ~1.5 ms (avg) |
| `journal.analysis.duration{llm_model=gpt-4o-mini}` | ~11.5 s (timeout del proveedor) |
| `journal.http.latency.p95` | ~15 ms |

```bash
aws cloudwatch list-metrics --namespace JournalAPI --region us-east-1
aws cloudwatch get-metric-statistics --namespace JournalAPI \
  --metric-name journal.http.requests.total \
  --dimensions Name=OTelLib,Value=journal-api Name=status_class,Value=5xx \
  --start-time "$(date -u -d '-30 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 60 --statistics Sum --region us-east-1
```

## 5.4 Logs en CloudWatch Logs

`k8s/fluent-bit.yaml` despliega un **DaemonSet** con
`public.ecr.aws/aws-observability/aws-for-fluent-bit:stable`. El input `tail`
lee `/var/log/containers/*.log` del nodo (por eso hace falta `hostPath`) y un
filtro `rewrite_tag` deja pasar **solo** el namespace `journal-api`, de modo
que no se envían (ni se pagan) los logs de `kube-system`.

- Log group: `/aws/journal-api/application`
- Prefijo de stream: `journal-api-kube.var.log.containers.<pod>_journal-api_...`
- Retención: 7 días (`var.log_retention_days`)

Ejemplo de evento (access log de uvicorn enriquecido por el filtro
`kubernetes`):

```json
{"time":"2026-10-22T17:16:15.179828929Z","stream":"stdout",
 "log":"INFO: 10.42.0.16:57986 - \"GET /entries HTTP/1.1\" 500 Internal Server Error",
 "kubernetes":{"pod_name":"journal-api-8c858df5-ckx4l","namespace_name":"journal-api"}}
```

## 5.5 Verificación local con Aspire Dashboard

Antes de apuntar la app al collector se validó la instrumentación contra el
Aspire Dashboard (`k8s/aspire-dashboard.yaml`, solo para verificación local:
`scripts/deploy-k8s.sh` **no** lo aplica en producción).

- **229 spans** capturados, con todos los `db.entries.*`, `llm.analyze_entry`
  y los atributos de resource `service.name=journal-api`,
  `service.version=11e519e...`, `deployment.environment=aspire-verification`.
- `/api/telemetry/resources` reportó `hasMetrics: true`.
- Al terminar la verificación el Deployment y el Service se eliminaron del
  cluster para liberar memoria en la instancia.

## 5.6 Dashboard

`aws_cloudwatch_dashboard.journal` (nombre `journal-api`) con 5 widgets:

1. Requests por status class (2xx/3xx/4xx/5xx).
2. Error rate 5xx (%) con métrica matemática
   `100 * e5 / (e2 + e3 + e4 + e5)`.
3. Latencia HTTP p50 / p95 (ms).
4. Entradas creadas (`journal.entries.created`).
5. Tabla de errores recientes vía Logs Insights sobre el log group de la app.

## 5.7 Alarmas

| Alarma | Métrica | Umbral | Evaluación |
|---|---|---|---|
| `journal-api-http-5xx` | `journal.http.requests.total{status_class=5xx}` (Sum) | > 5 por minuto | 1 periodo, 1 datapoint |
| `journal-api-latency-p95` | `journal.http.latency.p95` (Average) | > 2000 ms | 3 periodos consecutivos |

Ambas usan `treat_missing_data = notBreaching` y notifican a `alarm_actions` y
`ok_actions` del topic SNS.

## 5.8 Notificaciones SNS

- Topic: `arn:aws:sns:us-east-1:607856468834:journal-api-alarms`
- Suscripción email: definida en `var.alarm_email` (se pasa por
  `terraform/terraform.tfvars`, **gitignored**; el email no está en el repo).
- Estado actual: `PendingConfirmation` — hay que abrir el mail de AWS y
  confirmar la suscripción para recibir los avisos. La transición de estado de
  las alarmas se verifica igual con `describe-alarms`.

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn arn:aws:sns:us-east-1:607856468834:journal-api-alarms --region us-east-1
```

## 5.9 Consultas guardadas (Logs Insights)

Definidas en Terraform (`aws_cloudwatch_query_definition`), visibles en
CloudWatch → Logs Insights → *Saved queries*:

| Nombre | Propósito |
|---|---|
| `journal-api/errores-5xx` | Últimos 50 eventos con `ERROR` o status 5xx |
| `journal-api/requests-por-ruta` | Conteo de requests agrupado por ruta y status |

Resultado real de `requests-por-ruta` sobre la última hora:

```text
path        status  requests
/version    200     20
/entries    200     14
```

Resultado de `errores-5xx` durante la prueba de alarma: eventos
`ERROR: Exception in ASGI application` junto con los `500 Internal Server Error`
del access log.

Ejecución por CLI:

```bash
QID=$(aws logs start-query \
  --log-group-names /aws/journal-api/application \
  --start-time "$(date -u -d '-1 hour' +%s)" --end-time "$(date -u +%s)" \
  --query-string 'fields @timestamp, @message | filter @message like /ERROR/ | sort @timestamp desc | limit 20' \
  --query queryId --output text --region us-east-1)

aws logs get-query-results --query-id "$QID" --region us-east-1
```

## 5.10 Infraestructura como código

`terraform/monitoring.tf` crea: topic y suscripción SNS, los dos log groups,
la política IAM inline del instance role (X-Ray write, `cloudwatch:PutMetricData`
restringido por condición al namespace `JournalAPI`, y escritura de logs solo
bajo `/aws/journal-api/*`), el dashboard, las dos alarmas y las dos consultas
guardadas.

```powershell
cd terraform
terraform plan    # debe terminar en "No changes"
```

## 5.11 Prueba end-to-end de la alarma

Procedimiento reproducible (sin abrir puertos: todo por SSM):

```bash
# 1. Romper la dependencia para forzar 5xx
kubectl -n journal-api scale deploy/postgres --replicas=0

# 2. Generar tráfico (cada request falla con 500)
for i in $(seq 1 20); do curl -s -o /dev/null https://3.216.116.179.sslip.io/entries; sleep 5; done

# 3. Observar la métrica y el estado
aws cloudwatch get-metric-statistics --namespace JournalAPI \
  --metric-name journal.http.requests.total \
  --dimensions Name=OTelLib,Value=journal-api Name=status_class,Value=5xx \
  --start-time "$(date -u -d '-15 min' +%FT%TZ)" --end-time "$(date -u +%FT%TZ)" \
  --period 60 --statistics Sum --region us-east-1
aws cloudwatch describe-alarms --alarm-names journal-api-http-5xx --region us-east-1

# 4. Restaurar
kubectl -n journal-api scale deploy/postgres --replicas=1
```

Evidencia obtenida:

| Hora (UTC) | Hecho |
|---|---|
| 17:11 | primer pico: `journal.http.requests.total{5xx} = 10` |
| 17:12:06 | `OK → ALARM` |
| 17:13:06 | `ALARM → OK` (tráfico detenido) |
| 17:14 | tráfico sostenido: `5xx = 16` |
| 17:15:06 | `OK → ALARM` (`Threshold Crossed: 1 out of the last 1 datapoints [16.0] was greater than the threshold (5.0)`) |
| 17:17 | Postgres restaurado → `5xx = 2` |
| 17:18:06 | `ALARM → OK` |

`describe-alarm-history` devuelve la secuencia completa
(`INSUFFICIENT_DATA → OK → ALARM → OK → ALARM → OK`), que es la prueba de que
la alarma evalúa la métrica real y no un estado vacío.

## Costos incrementales

| Ítem | Estimación |
|---|---|
| EC2 `t3.small` vs `t3.micro` | +$7.59/mes |
| CloudWatch métricas custom (15 series) | ~$0.45/mes |
| CloudWatch Logs ingesta (~50 MB/mes) + almacenamiento 7 días | ~$0.30/mes |
| Alarmas (2) | $0.20/mes |
| X-Ray (trazas muestreadas) | < $0.10/mes |
| **Total incremental** | **≈ $8.6 – 9/mes** |

## Limitaciones conocidas

- El proveedor LLM devuelve `429 insufficient_quota` (sin crédito), por lo que
  `POST /entries/{id}/analyze` responde `503`. La traza y la métrica
  `journal.analysis.duration` se generan igual; el span queda con `fault`.
- La suscripción SNS sigue `PendingConfirmation` hasta confirmar el email.
- Las métricas EMF tardan ~1–2 minutos en aparecer en CloudWatch; una alarma de
  1 periodo reacciona en ese orden de magnitud.
- Un solo nodo (`t3.small`) corre k3s + app + Postgres + ADOT + Fluent Bit. Es
  suficiente para el capstone, pero no es alta disponibilidad.
