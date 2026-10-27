"""Regression tests for the tracing exclusion of probe routes.

Kubernetes probes the pod every few seconds. Without the exclusion each probe
became a span, and each span a trace stored in X-Ray, which burned the
100,000 traces/month free tier on its own.
"""

import pytest
from fastapi import FastAPI
from opentelemetry.util.http import parse_excluded_urls

from api import telemetry

pytestmark = pytest.mark.no_db

PROBE_PATHS = ["/version", "/openapi.json", "/docs", "/redoc", "/favicon.ico"]
API_PATHS = ["/entries", "/entries/1", "/entries/1/analyze"]


@pytest.mark.parametrize("path", PROBE_PATHS)
def test_probe_and_docs_paths_are_not_traced(path):
    excluded = parse_excluded_urls(telemetry.EXCLUDED_TRACE_URLS)
    assert excluded.url_disabled(f"http://10.42.0.26:8000{path}")


@pytest.mark.parametrize("path", API_PATHS)
def test_api_paths_are_still_traced(path):
    excluded = parse_excluded_urls(telemetry.EXCLUDED_TRACE_URLS)
    assert not excluded.url_disabled(f"http://10.42.0.26:8000{path}")


def test_exclusion_does_not_capture_paths_that_merely_contain_a_probe_path():
    excluded = parse_excluded_urls(telemetry.EXCLUDED_TRACE_URLS)
    assert not excluded.url_disabled("http://10.42.0.26:8000/entries/version-notes")


def test_instrument_app_forwards_the_exclusion_to_the_instrumentation(monkeypatch):
    captured = {}

    def fake_instrument_app(app, **kwargs):
        captured.update(kwargs)

    monkeypatch.setattr(telemetry, "_SDK_DISABLED", False)
    monkeypatch.setattr(telemetry.FastAPIInstrumentor, "instrument_app", fake_instrument_app)

    telemetry.instrument_app(FastAPI())

    assert captured["excluded_urls"] == telemetry.EXCLUDED_TRACE_URLS
