"""OpenTelemetry configuration for Journal API."""
import logging
import os

from fastapi import FastAPI
from opentelemetry import metrics, trace
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor

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


# Configurar Resource (identifica tu servicio)
resource = Resource.create(
    {
        "service.name": os.getenv("OTEL_SERVICE_NAME", "journal-api"),
        "service.version": "1.0.0",
        "deployment.environment": os.getenv("ENVIRONMENT", "production"),
    }
)

# ==========================================
# TRACING (Spans)
# ==========================================
# El endpoint explícito se usa tal cual: hay que incluir la ruta de la señal.
span_exporter = OTLPSpanExporter(endpoint=f"{_base_url()}/v1/traces")

tracer_provider = TracerProvider(resource=resource)
tracer_provider.add_span_processor(BatchSpanProcessor(span_exporter))
trace.set_tracer_provider(tracer_provider)

tracer = trace.get_tracer("journal-api")

# ==========================================
# METRICS (Métricas)
# ==========================================
metric_reader = PeriodicExportingMetricReader(
    OTLPMetricExporter(endpoint=f"{_base_url()}/v1/metrics"),
    export_interval_millis=10_000,  # para ver métricas rápido en el dashboard
)

meter_provider = MeterProvider(resource=resource, metric_readers=[metric_reader])
metrics.set_meter_provider(meter_provider)

meter = metrics.get_meter("journal-api")

# Métricas personalizadas
entry_counter = meter.create_counter(
    "journal.entries.created", description="Count of journal entries created"
)

request_counter = meter.create_counter(
    "http.requests.total", description="Total HTTP requests"
)


def instrument_app(app: FastAPI) -> None:
    """Instrumentar FastAPI con OpenTelemetry."""
    FastAPIInstrumentor.instrument_app(app)
