# ──────────────────────────────────────────────
# Patient Monitor Service - Multi-stage Dockerfile
# NeuroSphere Medical Technologies
# ──────────────────────────────────────────────

# Stage 1: Build dependencies
FROM python:3.12-slim AS builder

WORKDIR /build

COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

# Stage 2: Production image
FROM python:3.12-slim AS production

# Security: run as non-root user
RUN groupadd -r neurosphere && useradd -r -g neurosphere -s /bin/false appuser

WORKDIR /app

# Copy installed dependencies from builder
COPY --from=builder /install /usr/local

# Copy application code
COPY . .

# Set ownership
RUN chown -R appuser:neurosphere /app

USER appuser

# Environment variables
ENV PORT=5001
ENV PYTHONUNBUFFERED=1
ENV ANOMALY_RATE=0.05
ENV VITALS_UPDATE_INTERVAL=3

EXPOSE 5001

# Health check
HEALTHCHECK --interval=30s --timeout=10s --start-period=5s --retries=3 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:5001/health')" || exit 1

# Run with gunicorn for production
CMD ["gunicorn", "--bind", "0.0.0.0:5001", "--workers", "2", "--threads", "4", "--timeout", "120", "--access-logfile", "-", "app.main:app"]
