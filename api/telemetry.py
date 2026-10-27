"""OpenTelemetry configuration for Journal API.

The application exports OTLP/HTTP to ``OTEL_EXPORTER_OTLP_ENDPOINT``. In
production that endpoint is the ADOT Collector, which translates traces to
X-Ray and metrics to CloudWatch (EMF). For local verification it can point to
the Aspire Dashboard deployed from ``k8s/aspire-dashboard.yaml``.
"""

import logging
import os
import re
import time
from collections import deque
from collections.abc import Iterable
from threading import Lock

from fastapi import FastAPI, Request
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.metrics import Observation
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from starlette.middleware.base import BaseHTTPMiddleware, RequestResponseEndpoint
from starlette.responses import Response

# Visibilizar fallos de exportación en los logs del pod.
_otel_logger = logging.getLogger("opentelemetry.exporter")
_otel_logger.setLevel(logging.INFO)
if not _otel_logger.handlers:
    _handler = logging.StreamHandler()
    _handler.setFormatter(logging.Formatter("%(levelname)s [%(name)s] %(message)s"))
    _otel_logger.addHandler(_handler)


def _base_url() -> str:
    """Base del colector OTLP, sin slash final."""
    return os.getenv("OTEL_EXPORTER_OTLP_ENDPOINT", "http://aspire-dashboard:4318").rstrip("/")


# El SHA se hornea en la imagen (Dockerfile) y permite correlacionar cada traza
# con el commit que la generó sin hardcodear versiones que se desactualizan.
SERVICE_VERSION = os.getenv("GIT_SHA", "unknown")

# OTEL_SDK_DISABLED=true evita exporters y threads de red en tests/CI.
_SDK_DISABLED = os.getenv("OTEL_SDK_DISABLED", "false").lower() in {"1", "true", "yes"}

# Configurar Resource (identifica tu servicio)
resource = Resource.create(
    {
        "service.name": os.getenv("OTEL_SERVICE_NAME", "journal-api"),
        "service.version": SERVICE_VERSION,
        "deployment.environment": os.getenv("ENVIRONMENT", "production"),
    }
)

if not _SDK_DISABLED:
    # ==========================================
    # TRACING (Spans)
    # ==========================================
    # El endpoint explícito se usa tal cual: hay que incluir la ruta de la señal.
    span_exporter = OTLPSpanExporter(endpoint=f"{_base_url()}/v1/traces")

    tracer_provider = TracerProvider(resource=resource)
    tracer_provider.add_span_processor(BatchSpanProcessor(span_exporter))
    trace.set_tracer_provider(tracer_provider)

    # ==========================================
    # METRICS (Métricas)
    # ==========================================
    metric_reader = PeriodicExportingMetricReader(
        OTLPMetricExporter(endpoint=f"{_base_url()}/v1/metrics"),
        export_interval_millis=10_000,  # para ver métricas rápido en el dashboard
    )

    meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
    metrics.set_meter_provider(meter_provider)

tracer = trace.get_tracer("journal-api")
meter = metrics.get_meter("journal-api")

# Mínima cardinalidad a propósito: cada combinación de atributos se convierte
# en una métrica custom de CloudWatch (costo) y no necesitamos rutas por status.
entry_counter = meter.create_counter(
    "journal.entries.created", description="Count of journal entries created"
)

request_counter = meter.create_counter(
    "journal.http.requests.total",
    description="HTTP requests grouped by status class (2xx, 3xx, 4xx, 5xx)",
)

http_duration = meter.create_histogram(
    "journal.http.request.duration",
    unit="ms",
    description="HTTP request duration by route",
)

db_query_duration = meter.create_histogram(
    "journal.db.query.duration",
    unit="ms",
    description="PostgreSQL query duration by operation",
)

analysis_duration = meter.create_histogram(
    "journal.analysis.duration",
    unit="ms",
    description="LLM analysis duration",
)

# Percentiles calculados en proceso sobre una ventana deslizante. CloudWatch no
# deriva p50/p95 de un histograma OTLP, así que publicamos gauges explícitos.
_LATENCY_WINDOW: deque[float] = deque(maxlen=500)
_LATENCY_LOCK = Lock()

_IGNORED_PATHS = {"/version", "/openapi.json", "/docs", "/redoc", "/favicon.ico"}

# Las mismas rutas se excluyen del TRACING, no solo de las metricas.
#
# Los probes de Kubernetes (liveness/readiness) pegan contra /version cada
# pocos segundos y cada span es un trace que X-Ray guarda. El limite gratis
# son 100.000 traces al mes: sin este filtro el servicio se pasa el limite
# solo, porque el 100% del trafico de esta API son probes y no usuarios.
#
# El SDK evalua los regexes con search() contra la URL completa
# ("http://host:puerto/ruta"), asi que se ancla al final: /version$ no
# captura rutas que solo la contengan (p.ej. /entries/version-notes).
EXCLUDED_TRACE_URLS = ",".join(f"{re.escape(path)}$" for path in sorted(_IGNORED_PATHS))


def record_http_latency(duration_ms: float) -> None:
    """Agregar una medición a la ventana usada por los gauges de percentiles."""
    with _LATENCY_LOCK:
        _LATENCY_WINDOW.append(duration_ms)


def _percentile(percentile: float) -> float:
    with _LATENCY_LOCK:
        values = sorted(_LATENCY_WINDOW)
    if not values:
        return 0.0
    index = round((percentile / 100) * (len(values) - 1))
    return values[min(len(values) - 1, max(0, index))]


def _observe_p50(_options: metrics.CallbackOptions) -> Iterable[Observation]:
    return [Observation(round(_percentile(50), 2))]


def _observe_p95(_options: metrics.CallbackOptions) -> Iterable[Observation]:
    return [Observation(round(_percentile(95), 2))]


meter.create_observable_gauge(
    "journal.http.latency.p50",
    callbacks=[_observe_p50],
    unit="ms",
    description="Rolling p50 HTTP latency (last 500 requests)",
)
meter.create_observable_gauge(
    "journal.http.latency.p95",
    callbacks=[_observe_p95],
    unit="ms",
    description="Rolling p95 HTTP latency (last 500 requests)",
)


class TelemetryMiddleware(BaseHTTPMiddleware):
    """Cuenta requests y alimenta latencia sin depender de cada router."""

    async def dispatch(self, request: Request, call_next: RequestResponseEndpoint) -> Response:
        started = time.perf_counter()
        status_code = 500
        try:
            response = await call_next(request)
            status_code = response.status_code
            return response
        finally:
            elapsed_ms = (time.perf_counter() - started) * 1000
            route = request.scope.get("route")
            route_path = getattr(route, "path", "unmatched")
            if route_path not in _IGNORED_PATHS:
                request_counter.add(1, {"status_class": f"{status_code // 100}xx"})
                http_duration.record(elapsed_ms, {"route": route_path})
                record_http_latency(elapsed_ms)


def instrument_app(app: FastAPI) -> None:
    """Instrumentar FastAPI con OpenTelemetry."""
    app.add_middleware(TelemetryMiddleware)
    if not _SDK_DISABLED:
        FastAPIInstrumentor.instrument_app(app, excluded_urls=EXCLUDED_TRACE_URLS)
