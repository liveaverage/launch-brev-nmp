FROM python:3.11-slim

# OCI labels for GHCR
LABEL org.opencontainers.image.description="Interlude - NeMo Microservices deployment launcher with integrated reverse proxy"
LABEL org.opencontainers.image.licenses="MIT"

# Install Docker CLI, Docker Compose, Helm, kubectl, nginx, and openssl
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    gnupg \
    lsb-release \
    openssl \
    procps \
    debian-keyring \
    debian-archive-keyring \
    apt-transport-https \
    && mkdir -p /etc/apt/keyrings \
    # Docker CLI
    && curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(lsb_release -cs) stable" | tee /etc/apt/sources.list.d/docker.list > /dev/null \
    && apt-get update \
    && apt-get install -y docker-ce-cli docker-compose-plugin \
    # Helm
    && curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash \
    # kubectl
    && curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" \
    && chmod +x kubectl \
    && mv kubectl /usr/local/bin/ \
    # nginx (has sub_filter for response body rewriting)
    && apt-get install -y nginx \
    # Disable default nginx site and service
    && rm -f /etc/nginx/sites-enabled/default \
    && update-rc.d nginx disable 2>/dev/null || true \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Set working directory
WORKDIR /app

# Copy application files
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY index.html .
COPY config.json .
COPY config-helm.json .
COPY help-content.json .
COPY assets ./assets
COPY nemo-proxy ./nemo-proxy
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh nemo-proxy/*.sh 2>/dev/null || true

# Expose ports:
# 80   - nginx HTTP (single entry point)
# 443  - nginx HTTPS (single entry point)
# Flask runs on internal :8080, not exposed
EXPOSE 80 443

# Create data directory for persistent state
RUN mkdir -p /app/data

# Run nginx + Flask via entrypoint
CMD ["./entrypoint.sh"]
