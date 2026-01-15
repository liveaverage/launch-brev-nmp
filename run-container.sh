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

# Detect if running via sudo and use original user's home
if [ "$EUID" -eq 0 ] && [ -n "$SUDO_USER" ]; then
    REAL_USER="$SUDO_USER"
    REAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    REAL_USER="$USER"
    REAL_HOME="$HOME"
fi

KUBE_CONFIG_DIR="$REAL_HOME/.kube"

# Create data directory for persistent state
mkdir -p "$DATA_DIR"

# Clear any existing kubectl cache to ensure fresh start
rm -rf "$KUBE_CONFIG_DIR/cache" 2>/dev/null || true

# Stop existing container if running
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

echo "Starting $CONTAINER_NAME..."
echo "  Image: $IMAGE"
echo "  Config: $CONFIG_DIR/config.json"
echo "  User: $REAL_USER"
echo "  Kubeconfig: $KUBE_CONFIG_DIR"
echo "  State: $DATA_DIR"

# Validate kubeconfig exists before mounting
if [ ! -f "$KUBE_CONFIG_DIR/config" ]; then
    echo ""
    echo "❌ ERROR: Kubeconfig not found at $KUBE_CONFIG_DIR/config"
    echo ""
    echo "   Detected user: $REAL_USER (home: $REAL_HOME)"
    if [ "$EUID" -eq 0 ]; then
        echo "   Running as: root (via sudo)"
    else
        echo "   Running as: $USER"
    fi
    echo ""
    echo "   This usually means MicroK8s hasn't generated it yet."
    echo "   Try:"
    echo "     mkdir -p $KUBE_CONFIG_DIR"
    echo "     sudo microk8s config > $KUBE_CONFIG_DIR/config"
    if [ "$EUID" -eq 0 ] && [ -n "$SUDO_USER" ]; then
        echo "     chown $SUDO_USER:$SUDO_USER $KUBE_CONFIG_DIR/config"
    fi
    echo ""
    exit 1
fi

echo "  ✓ Kubeconfig validated"
echo ""

# Build env var flags
ENV_FLAGS=""
[ -n "$SHOW_DRY_RUN" ] && ENV_FLAGS="$ENV_FLAGS -e SHOW_DRY_RUN=$SHOW_DRY_RUN"
[ -n "$DEPLOY_TYPE" ] && ENV_FLAGS="$ENV_FLAGS -e DEPLOY_TYPE=$DEPLOY_TYPE"
[ -n "$DEPLOY_HEADING" ] && ENV_FLAGS="$ENV_FLAGS -e DEPLOY_HEADING=$DEPLOY_HEADING"
[ -n "$LAUNCHER_PATH" ] && ENV_FLAGS="$ENV_FLAGS -e LAUNCHER_PATH=$LAUNCHER_PATH"

# Use host network for K8s API access and ingress routing
docker run -d \
  --name "$CONTAINER_NAME" \
  --restart always \
  --network host \
  $ENV_FLAGS \
  -v "$KUBE_CONFIG_DIR:/root/.kube:ro" \
  -v "$CONFIG_DIR/config.json:/app/config.json:ro" \
  -v "$CONFIG_DIR/help-content.json:/app/help-content.json:ro" \
  -v "$CONFIG_DIR/nemo-proxy:/app/nemo-proxy:ro" \
  -v "$DATA_DIR:/app/data" \
  "$IMAGE"

# Give container moment to start
sleep 2

# Clear kubectl cache inside container to force fresh read
docker exec "$CONTAINER_NAME" rm -rf /root/.kube/cache 2>/dev/null || true
docker exec "$CONTAINER_NAME" rm -rf /root/.kube/http-cache 2>/dev/null || true

# Validate cluster connectivity from container
echo "Validating cluster connectivity from container..."
if docker exec "$CONTAINER_NAME" kubectl cluster-info --request-timeout=5s >/dev/null 2>&1; then
    echo "✓ Cluster connectivity verified"
else
    echo "⚠️  Warning: Cluster connectivity check failed (may need moment to stabilize)"
fi

echo ""
echo "✓ Container started"
echo ""
echo "  ┌───────────────────────────────────────────────────────┐"
echo "  │  First launch (pre-deployment):                       │"
echo "  │    http://localhost:9090   (deployment UI)            │"
echo "  │                                                       │"
echo "  │  After deployment:                                    │"
echo "  │    http://localhost:9090            (NeMo Studio)     │"
echo "  │    http://localhost:9090/interlude  (deployment UI)   │"
echo "  │    https://localhost:8443           (HTTPS)           │"
echo "  └───────────────────────────────────────────────────────┘"
echo ""
echo "  Logs: docker logs -f $CONTAINER_NAME"
echo "  Stop: docker stop $CONTAINER_NAME"
echo ""

