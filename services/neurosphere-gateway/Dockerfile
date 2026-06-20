# ============================================================================
# NeuroSphere API Gateway — Dockerfile
# Lightweight Nginx reverse-proxy for the medical robotics platform
# ============================================================================
FROM nginx:1.25-alpine

LABEL maintainer="NeuroSphere Platform Engineering <platform@neurosphere.io>"
LABEL description="API Gateway for NeuroSphere Medical Robotics Platform"
LABEL version="1.0.0"

# Remove default Nginx config
RUN rm /etc/nginx/conf.d/default.conf

# Copy custom gateway configuration
COPY nginx.conf /etc/nginx/nginx.conf

# Create log directory with correct permissions
RUN mkdir -p /var/log/nginx && \
    chown -R nginx:nginx /var/log/nginx

# Note: nginx -t is skipped at build time because upstream hostnames
# (robot-command-service, etc.) are only resolvable at runtime via Docker network.
# Nginx validates config automatically on startup.

EXPOSE 80

# Use exec form so Nginx receives signals correctly
CMD ["nginx", "-g", "daemon off;"]
