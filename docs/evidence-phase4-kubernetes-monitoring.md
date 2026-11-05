# Evidencia — Temas 4 y 5 (Kubernetes + Observabilidad)

Fecha: 2026-10-20
Repo: `journal-starter` — rama `docs/phase-4-evidence`
Cluster: **EKS `journal-eks`** (us-east-1, Kubernetes 1.31, 6 nodos `t3.micro`)

## Despliegue en EKS

```
NAME                             STATUS   ROLES    AGE    VERSION
ip-192-168-20-39.ec2.internal    Ready    <none>   156m   v1.31.14-eks-b9510e3
ip-192-168-22-205.ec2.internal   Ready    <none>   150m   v1.31.14-eks-b9510e3
ip-192-168-30-180.ec2.internal   Ready    <none>   150m   v1.31.14-eks-b9510e3
ip-192-168-34-117.ec2.internal   Ready    <none>   156m   v1.31.14-eks-b9510e3
ip-192-168-39-230.ec2.internal   Ready    <none>   150m   v1.31.14-eks-b9510e3
ip-192-168-42-198.ec2.internal   Ready    <none>   150m   v1.31.14-eks-b9510e3

NAME                               READY   STATUS    RESTARTS   AGE
aspire-dashboard-997477f5c-r4jcb   1/1     Running   0          72m
journal-api-869588f554-7spwz       1/1     Running   0          6m55s
journal-api-869588f554-wr6rx       1/1     Running   0          7m7s
postgres-7b77644bbf-td4j4          1/1     Running   0          142m
```

```
NAME               TYPE           EXTERNAL-IP                                                              PORT(S)
aspire-dashboard   LoadBalancer   a71e3b6c...us-east-1.elb.amazonaws.com                                     18888:30921/TCP,4317:31058/TCP,4318:32348/TCP
journal-api-lb     LoadBalancer   a1d72d07...us-east-1.elb.amazonaws.com                                     80:30501/TCP
postgres           ClusterIP      <none>                                                                   5432/TCP
```

Verificación funcional por el LoadBalancer público:

| Check | Resultado |
|---|---|
| `GET http://<elb>/docs` (Swagger UI) | **200** |
| `GET http://<elb>/entries` | **142 entries** |
| `POST http://<elb>/entries` x12 | **201 Created** |

## Observabilidad (Tema 5)

Instrumentación en `api/telemetry.py`:

- `TracerProvider` con `BatchSpanProcessor` → `OTLPSpanExporter` (`/v1/traces`)
- `MeterProvider` con `PeriodicExportingMetricReader` (10 s) → `OTLPMetricExporter` (`/v1/metrics`)
- Spans automáticos de FastAPI (`FastAPIInstrumentor`) + span custom `create_entry`
- Métricas custom: `journal.entries.created`, `http.requests.total`

Evidencia en Aspire Dashboard (vía `kubectl port-forward`, puerto 18888):

- 12 trazas `journal-api: POST /entries`, cada una con **5 spans** (HTTP server → `create_entry` → DB)
- Span de control `manual-probe-span` exportado con `SpanExportResult.SUCCESS`
- Duración típica por request: **0.16 s**

## Bugs encontrados y corregidos (ambos silenciosos)

1. **Service con `targetPort` incorrecto**
   `k8s/aspire-dashboard.yaml` exponía `4317/4318` con `targetPort: 4317/4318`, pero el
   contenedor escucha OTLP en `18889` (gRPC) y `18890` (HTTP).
   → Corregido a `targetPort: 18889/18890`.
   Síntoma: exporter con *connection refused*, sin ningún log visible.

2. **Falta el path de la señal OTLP**
   `OTLPSpanExporter(endpoint="http://aspire-dashboard:4318")` usa el endpoint **tal cual**;
   el SDK no agrega `/v1/traces` cuando el endpoint se pasa explícito.
   El POST caía en `/` → 404 descartado en silencio.
   → Corregido a `endpoint=f"{base}/v1/traces"` y `.../v1/metrics`.

Verificación del fix (sin depender de la UI):

```
POST http://127.0.0.1:18890/v1/traces -> 200   (directo al pod)
POST http://127.0.0.1:4318/v1/traces  -> 200   (vía Service)
EXPORT RESULT: SpanExportResult.SUCCESS        (span real exportado desde el pod)
```

Lección: un exporter que falla no rompe la app — por eso se agregó un handler de logging
para que los errores de export aparezcan en `kubectl logs`.

## Screenshots pendientes de adjuntar

- [ ] `kubectl get pods` / `kubectl get svc` en EKS
- [ ] Swagger UI por el ELB (`/docs`)
- [ ] Aspire Dashboard → Traces (12 POST + `manual-probe-span`)
- [ ] Una traza abierta mostrando los 5 spans
