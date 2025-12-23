#!/bin/bash
# Launch Interlude container (NeMo deployment launcher + reverse proxy)
#
# Usage:
#   ./run-container.sh                    # Use local image
#   ./run-container.sh ghcr.io/org/repo   # Use specific image
#
# Environment variables:
#   SHOW_DRY_RUN=true       # Show dry run option (default: hidden)
#   DEPLOY_TYPE=helm-nemo   # Override deployment type from config
#   LAUNCHER_PATH=/interlude  # Subpath for deployment UI after deployment

set -e

IMAGE="${1:-ghcr.io/liveaverage/launch-brev-nmp:latest}"
CONTAINER_NAME="interlude"
CONFIG_DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="$CONFIG_DIR/.interlude-data"

# Create data directory for persistent state
mkdir -p "$DATA_DIR"

# Stop existing container if running
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

echo "Starting $CONTAINER_NAME..."
echo "  Image: $IMAGE"
echo "  Config: $CONFIG_DIR/config-helm.json"
echo "  Kubeconfig: $HOME/.kube"
echo "  State: $DATA_DIR"

# Build env var flags
ENV_FLAGS=""
[ -n "$SHOW_DRY_RUN" ] && ENV_FLAGS="$ENV_FLAGS -e SHOW_DRY_RUN=$SHOW_DRY_RUN"
[ -n "$DEPLOY_TYPE" ] && ENV_FLAGS="$ENV_FLAGS -e DEPLOY_TYPE=$DEPLOY_TYPE"
[ -n "$DEPLOY_HEADING" ] && ENV_FLAGS="$ENV_FLAGS -e DEPLOY_HEADING=$DEPLOY_HEADING"
[ -n "$LAUNCHER_PATH" ] && ENV_FLAGS="$ENV_FLAGS -e LAUNCHER_PATH=$LAUNCHER_PATH"

# Use host network for K8s API access and ingress routing
docker run -d \
  --name "$CONTAINER_NAME" \
  --network host \
  $ENV_FLAGS \
  -v "$HOME/.kube:/root/.kube:ro" \
  -v "$CONFIG_DIR/config-helm.json:/app/config.json:ro" \
  -v "$CONFIG_DIR/help-content.json:/app/help-content.json:ro" \
  -v "$CONFIG_DIR/nemo-proxy:/app/nemo-proxy:ro" \
  -v "$DATA_DIR:/app/data" \
  "$IMAGE"

echo ""
echo "✓ Container started"
echo ""
echo "  ┌─────────────────────────────────────────────────────┐"
echo "  │  First launch (pre-deployment):                     │"
echo "  │    http://localhost:80   (deployment UI)            │"
echo "  │                                                     │"
echo "  │  After deployment:                                  │"
echo "  │    http://localhost:80            (NeMo Studio)     │"
echo "  │    http://localhost:80/interlude  (deployment UI)   │"
echo "  └─────────────────────────────────────────────────────┘"
echo ""
echo "  Logs: docker logs -f $CONTAINER_NAME"
echo "  Stop: docker stop $CONTAINER_NAME"
echo ""

