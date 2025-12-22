#!/bin/bash

# Run with automatic kubeconfig localhost fixing for kind/k3s/minikube
# This script modifies the kubeconfig to use host.docker.internal

KUBECONFIG_PATH="${HOME}/.kube/config"
TEMP_KUBECONFIG="/tmp/kubeconfig-docker"

echo "Creating Docker-compatible kubeconfig..."

# Copy kubeconfig and replace localhost references
cp "$KUBECONFIG_PATH" "$TEMP_KUBECONFIG"

# For Linux: replace localhost with host's docker0 bridge IP (typically 172.17.0.1)
# For Mac/Windows Docker Desktop: use host.docker.internal
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Get docker0 bridge IP
    DOCKER_HOST_IP=$(ip -4 addr show docker0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n 1)
    if [ -z "$DOCKER_HOST_IP" ]; then
        DOCKER_HOST_IP="172.17.0.1"
    fi
    echo "Using Docker bridge IP: $DOCKER_HOST_IP"
    sed -i "s|https://127.0.0.1|https://${DOCKER_HOST_IP}|g" "$TEMP_KUBECONFIG"
    sed -i "s|https://localhost|https://${DOCKER_HOST_IP}|g" "$TEMP_KUBECONFIG"
    EXTRA_ARGS="--add-host=host.docker.internal:${DOCKER_HOST_IP}"
else
    echo "Using host.docker.internal (Docker Desktop)"
    sed "s|https://127.0.0.1|https://host.docker.internal|g" "$KUBECONFIG_PATH" | \
    sed "s|https://localhost|https://host.docker.internal|g" > "$TEMP_KUBECONFIG"
    EXTRA_ARGS=""
fi

echo "Starting container with modified kubeconfig..."

docker run -d \
  -p 8080:8080 \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v "$TEMP_KUBECONFIG":/root/.kube/config:ro \
  -v $(pwd)/docker-compose.yaml:/app/docker-compose.yaml:ro \
  -v $(pwd)/config.json:/app/config.json:ro \
  $EXTRA_ARGS \
  --name deployment-app \
  deployment-app

echo ""
echo "Deployment app is running with modified kubeconfig"
echo "Access at http://localhost:8080"
echo ""
echo "Kubeconfig has been modified to use Docker-accessible addresses"
echo "Temporary kubeconfig: $TEMP_KUBECONFIG"
