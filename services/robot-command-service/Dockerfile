# ============================================================
# NeuroSphere Robot Command Service — Multi-stage Dockerfile
# ============================================================
# Stage 1: install dependencies into a virtualenv
# Stage 2: copy only the venv + app code for a slim prod image
# ============================================================

# --- Build stage ---
FROM python:3.12-slim AS builder

WORKDIR /build

COPY requirements.txt .
RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --no-cache-dir --upgrade pip \
    && /opt/venv/bin/pip install --no-cache-dir -r requirements.txt

# --- Production stage ---
FROM python:3.12-slim AS production

LABEL maintainer="NeuroSphere Platform Engineering <platform@neurosphere.io>"
LABEL service="robot-command-service"

# Non-root user for security
RUN groupadd -r neurosphere && useradd -r -g neurosphere -s /sbin/nologin neurosphere

WORKDIR /app

# Copy virtualenv from builder
COPY --from=builder /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Copy application code
COPY app/ ./app/

# Expose the service port
EXPOSE 5000

# Switch to non-root
USER neurosphere

# Health check
HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5000/health')" || exit 1

# Run with gunicorn for production (4 workers, 120 s timeout for long procedures)
CMD ["gunicorn", \
     "--bind", "0.0.0.0:5000", \
     "--workers", "4", \
     "--timeout", "120", \
     "--access-logfile", "-", \
     "app.main:create_app()"]
