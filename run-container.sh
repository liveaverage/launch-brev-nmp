#!/bin/bash
# Launch brev-launch-nmp container with kubeconfig access
#
# Usage:
#   ./run-container.sh                    # Use local image
#   ./run-container.sh ghcr.io/org/repo   # Use specific image

set -e

IMAGE="${1:-brev-launch-nmp}"
CONTAINER_NAME="brev-launch-nmp"
CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)"

# Stop existing container if running
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

echo "Starting $CONTAINER_NAME..."
echo "  Image: $IMAGE"
echo "  Config: $CONFIG_DIR/config-helm.json"
echo "  Kubeconfig: $HOME/.kube"

# Use host network for internal K8s API access (common with k3s, microk8s, kind)
docker run -d \
  --name "$CONTAINER_NAME" \
  --network host \
  -v "$HOME/.kube:/root/.kube:ro" \
  -v "$CONFIG_DIR/config-helm.json:/app/config.json:ro" \
  -v "$CONFIG_DIR/help-content.json:/app/help-content.json:ro" \
  "$IMAGE"

echo ""
echo "✓ Container started"
echo ""
echo "  Access:  http://localhost:8080"
echo "  Logs:    docker logs -f $CONTAINER_NAME"
echo "  Stop:    docker stop $CONTAINER_NAME"
echo ""

