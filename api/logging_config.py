"""Application logging configuration, completed in Task 3."""

import logging


def configure_logging(level: int = logging.INFO) -> None:
    """Configure application logging at the requested level, defaulting to INFO."""
    logging.basicConfig(
        level=level,
        format="%(levelname)s %(name)s %(message)s",
    )
    logging.getLogger().setLevel(level)
