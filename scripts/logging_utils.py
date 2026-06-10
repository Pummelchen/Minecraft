#!/usr/bin/env python3
"""Structured logging utilities with JSON output and correlation IDs."""

from __future__ import annotations

import contextlib
import datetime as dt
import json
import logging
import os
import sys
import threading
import time
import uuid
from pathlib import Path
from typing import Any


# Thread-local storage for correlation IDs
_local = threading.local()


def generate_correlation_id() -> str:
    """Generate a new correlation ID."""
    return f"pum-{uuid.uuid4().hex[:12]}"


def get_correlation_id() -> str:
    """Get the current correlation ID, generating one if needed."""
    if not hasattr(_local, 'correlation_id'):
        _local.correlation_id = generate_correlation_id()
    return _local.correlation_id


def set_correlation_id(cid: str | None = None) -> str:
    """Set a specific correlation ID."""
    _local.correlation_id = cid or generate_correlation_id()
    return _local.correlation_id


def clear_correlation_id() -> None:
    """Clear the correlation ID."""
    if hasattr(_local, 'correlation_id'):
        del _local.correlation_id


class JsonFormatter(logging.Formatter):
    """JSON log formatter with correlation ID support."""

    def format(self, record: logging.LogRecord) -> str:
        log_data = {
            "timestamp": dt.datetime.fromtimestamp(record.created, tz=dt.timezone.utc).isoformat(timespec="milliseconds"),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
            "correlation_id": getattr(record, 'correlation_id', get_correlation_id()),
            "module": record.module,
            "function": record.funcName,
            "line": record.lineno,
        }

        # Add extra fields if present
        for key, value in record.__dict__.items():
            if key not in {
                'name', 'msg', 'args', 'created', 'filename', 'funcName',
                'levelname', 'levelno', 'lineno', 'module', 'msecs',
                'message', 'name', 'pathname', 'process', 'processName',
                'relativeCreated', 'thread', 'threadName', 'exc_info',
                'exc_text', 'stack_info', 'correlation_id'
            }:
                log_data[key] = value

        # Add exception info if present
        if record.exc_info:
            log_data['exception'] = self.formatException(record.exc_info)

        return json.dumps(log_data, default=str)


class StructuredLogger:
    """Wrapper for structured logging with correlation IDs."""

    def __init__(self, name: str):
        self.logger = logging.getLogger(name)
        self._configured = False

    def _configure(self, level: int = logging.INFO, json_output: bool = True):
        if self._configured:
            return
        self.logger.setLevel(level)
        self.logger.propagate = False

        handler = logging.StreamHandler(sys.stdout)
        if json_output:
            handler.setFormatter(JsonFormatter())
        else:
            handler.setFormatter(logging.Formatter(
                '%(asctime)s [%(levelname)s] %(name)s: %(message)s [cid=%(correlation_id)s]'
            ))
        self.logger.addHandler(handler)
        self._configured = True

    def _log(self, level: int, msg: str, **kwargs):
        if not self._configured:
            self._configure()
        extra = {'correlation_id': get_correlation_id()}
        extra.update(kwargs)
        self.logger.log(level, msg, extra=extra)

    def debug(self, msg: str, **kwargs) -> None:
        self._log(logging.DEBUG, msg, **kwargs)

    def info(self, msg: str, **kwargs) -> None:
        self._log(logging.INFO, msg, **kwargs)

    def warning(self, msg: str, **kwargs) -> None:
        self._log(logging.WARNING, msg, **kwargs)

    def error(self, msg: str, **kwargs) -> None:
        self._log(logging.ERROR, msg, **kwargs)

    def critical(self, msg: str, **kwargs) -> None:
        self._log(logging.CRITICAL, msg, **kwargs)

    def exception(self, msg: str, **kwargs) -> None:
        if not self._configured:
            self._configure()
        extra = {'correlation_id': get_correlation_id()}
        extra.update(kwargs)
        self.logger.exception(msg, extra=extra)


# Global loggers
_loggers: dict[str, StructuredLogger] = {}


def get_logger(name: str) -> StructuredLogger:
    """Get or create a structured logger."""
    if name not in _loggers:
        _loggers[name] = StructuredLogger(name)
    return _loggers[name]


@contextlib.contextmanager
def correlation_context(cid: str | None = None):
    """Context manager for correlation ID."""
    old_cid = getattr(_local, 'correlation_id', None)
    new_cid = cid or generate_correlation_id()
    set_correlation_id(new_cid)
    try:
        yield new_cid
    finally:
        if old_cid:
            set_correlation_id(old_cid)
        else:
            clear_correlation_id()


def log_event(logger: StructuredLogger, event_type: str, **data):
    """Log a structured event with type and data."""
    logger.info(event_type, event_type=event_type, **data)


def log_timing(logger: StructuredLogger, operation: str, duration_ms: float, **data):
    """Log an operation timing."""
    logger.info("timing", operation=operation, duration_ms=round(duration_ms, 2), **data)


class Timer:
    """Context manager for timing operations."""

    def __init__(self, logger: StructuredLogger, operation: str, **data):
        self.logger = logger
        self.operation = operation
        self.data = data
        self.start = time.perf_counter()

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc_val, exc_tb):
        duration_ms = (time.perf_counter() - self.start) * 1000
        if exc_type:
            self.logger.error(
                f"{self.operation} failed",
                operation=self.operation,
                duration_ms=round(duration_ms, 2),
                error=str(exc_val),
                **self.data
            )
        else:
            log_timing(self.logger, self.operation, duration_ms, **self.data)


# Convenience functions
def get_script_logger(script_name: str) -> StructuredLogger:
    """Get a logger for a script."""
    return get_logger(f"pummelchen.{script_name}")