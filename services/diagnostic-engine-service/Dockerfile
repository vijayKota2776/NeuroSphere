# ──────────────────────────────────────────────────────────────────────────────
# Dockerfile — NeuroSphere Diagnostic Engine Service
# Multi-stage build for minimal production image size.
# ──────────────────────────────────────────────────────────────────────────────

# ── Stage 1: Install dependencies ────────────────────────────────────────────
FROM node:20-alpine AS deps

WORKDIR /app

# Copy only package files first to leverage Docker layer caching.
COPY package.json package-lock.json* ./

# Install production dependencies only (no devDependencies).
RUN npm ci --omit=dev 2>/dev/null || npm install --omit=dev && npm cache clean --force

# ── Stage 2: Production image ────────────────────────────────────────────────
FROM node:20-alpine AS production

# Security: run as non-root user.
RUN addgroup -S neurosphere && adduser -S diagnostic -G neurosphere

WORKDIR /app

# Copy production node_modules from deps stage.
COPY --from=deps /app/node_modules ./node_modules

# Copy application source.
COPY package.json ./
COPY src/ ./src/

# Metadata labels.
LABEL org.opencontainers.image.title="diagnostic-engine-service" \
      org.opencontainers.image.description="NeuroSphere AI Diagnostic Image Processing Pipeline" \
      org.opencontainers.image.vendor="NeuroSphere Medical Robotics"

# Switch to non-root user.
USER diagnostic

# Set port via environment variable
ENV PORT=3000

# Expose the service port.
EXPOSE 3000

# Health check: ensure the liveness endpoint responds.
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD wget --quiet --tries=1 --spider http://localhost:3000/health || exit 1

# Start the service.
CMD ["node", "src/index.js"]
