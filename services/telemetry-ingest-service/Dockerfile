# ===========================================================================
# NeuroSphere — Telemetry Ingest Service
# Multi-stage Docker build for minimal production image
# ===========================================================================

# ---------------------------------------------------------------------------
# Stage 1: Builder — install Python dependencies into a virtualenv
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS builder

WORKDIR /build

COPY requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# ---------------------------------------------------------------------------
# Stage 2: Production — copy venv + app code only
# ---------------------------------------------------------------------------
FROM python:3.12-slim AS production

LABEL maintainer="NeuroSphere Platform Team"
LABEL service="telemetry-ingest-service"
LABEL description="Central telemetry collector for NeuroSphere robotic surgery systems"

# Non-root user for security
RUN groupadd -r neurosphere && useradd -r -g neurosphere -s /sbin/nologin telemetry

WORKDIR /app

# Copy virtualenv from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy application code
COPY app/ ./app/

# Expose HTTP port
EXPOSE 5002

# Health check
HEALTHCHECK --interval=15s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5002/health')" || exit 1

USER telemetry

# Run with gunicorn
CMD ["gunicorn", \
     "--bind", "0.0.0.0:5002", \
     "--workers", "4", \
     "--worker-class", "gthread", \
     "--threads", "4", \
     "--timeout", "120", \
     "--access-logfile", "-", \
     "--error-logfile", "-", \
     "app.main:create_app()"]
