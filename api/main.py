import logging
import os
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from api.config import get_settings
from api.logging_config import configure_logging
from api.repositories.postgres_repository import PostgresDB
from api.routers.journal_router import router as journal_router
from api.telemetry import instrument_app

logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None]:
    configure_logging()
    settings = get_settings()
    async with PostgresDB(settings.database_url) as database:
        app.state.database = database

        logger.info("Application startup complete and ready to receive requests")
        try:
            yield
        finally:
            del app.state.database
            logger.info("Application shutdown complete")


app = FastAPI(
    title="Journal API",
    description="A simple journal API for tracking daily work, struggles, and intentions",
    lifespan=lifespan,
)
app.include_router(journal_router)


@app.get("/version")
async def get_version():
    """Return the commit SHA the image was built from."""
    return {"commit": os.environ.get("GIT_SHA", "unknown")}


# ==========================================
# OpenTelemetry FastAPI Instrumentation
# ==========================================
instrument_app(app)
