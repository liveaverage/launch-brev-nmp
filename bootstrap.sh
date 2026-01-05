#!/bin/bash
# Bootstrap script for Interlude (NeMo Microservices Launcher)
# Usage: curl -fsSL https://raw.githubusercontent.com/liveaverage/launch-brev-nmp/main/bootstrap.sh | bash
set -e

REPO_URL="https://github.com/liveaverage/launch-brev-nmp.git"
IMAGE="ghcr.io/liveaverage/launch-brev-nmp:latest"
INSTALL_DIR="${INSTALL_DIR:-$HOME/launch-brev-nmp}"
CONTAINER_NAME="interlude"
OLD_CONTAINER_NAME="brev-launch-nmp"  # For cleanup of legacy containers

echo "════════════════════════════════════════════════════════════"
echo "  Interlude - NeMo Microservices Launcher"
echo "════════════════════════════════════════════════════════════"
echo ""

# Check for required tools
if ! command -v docker &> /dev/null; then
    echo "❌ Docker is required but not installed."
    echo "   Install: https://docs.docker.com/get-docker/"
    exit 1
fi

if ! command -v kubectl &> /dev/null; then
    echo "⚠️  kubectl not found - you'll need it on the host to verify deployments"
fi

# Stop any existing containers (both old and new names)
echo "🧹 Cleaning up existing containers..."
docker rm -f "$CONTAINER_NAME" 2>/dev/null && echo "   Removed: $CONTAINER_NAME" || true
docker rm -f "$OLD_CONTAINER_NAME" 2>/dev/null && echo "   Removed: $OLD_CONTAINER_NAME (legacy)" || true

# Clone or update repo
if [ -d "$INSTALL_DIR" ]; then
    echo "📁 Directory exists: $INSTALL_DIR"
    echo "   Updating..."
    cd "$INSTALL_DIR"
    git pull --quiet 2>/dev/null || echo "   (not a git repo, skipping update)"
else
    echo "📥 Cloning repository..."
    if command -v git &> /dev/null; then
        git clone --quiet "$REPO_URL" "$INSTALL_DIR"
    else
        echo "   (git not found, using tarball)"
        mkdir -p "$INSTALL_DIR"
        curl -fsSL https://github.com/liveaverage/launch-brev-nmp/archive/refs/heads/main.tar.gz | \
            tar -xz --strip-components=1 -C "$INSTALL_DIR"
    fi
    cd "$INSTALL_DIR"
fi

echo ""
echo "🐳 Pulling container image..."
docker pull "$IMAGE"

echo ""
echo "🚀 Starting launcher..."
echo ""

# Run the container
bash run-container.sh "$IMAGE"

echo ""
echo "════════════════════════════════════════════════════════════"
echo "  ✓ Launcher is running!"
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
echo "  📁 Config: $INSTALL_DIR/config-helm.json"
echo "  📋 Logs:   docker logs -f $CONTAINER_NAME"
echo "  🛑 Stop:   docker stop $CONTAINER_NAME"
echo "════════════════════════════════════════════════════════════"

