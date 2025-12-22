#!/bin/bash
# Bootstrap script for NeMo Microservices Launcher
# Usage: curl -fsSL https://raw.githubusercontent.com/liveaverage/launch-brev-nmp/main/bootstrap.sh | bash
set -e

REPO_URL="https://github.com/liveaverage/launch-brev-nmp.git"
IMAGE="ghcr.io/liveaverage/launch-brev-nmp:latest"
INSTALL_DIR="${INSTALL_DIR:-$HOME/launch-brev-nmp}"

echo "════════════════════════════════════════════════════════════"
echo "  NeMo Microservices Launcher - Bootstrap"
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
echo "  🌐 Open: http://localhost:8080"
echo ""
echo "  📁 Config: $INSTALL_DIR/config-helm.json"
echo "  📋 Logs:   docker logs -f brev-launch-nmp"
echo "  🛑 Stop:   docker stop brev-launch-nmp"
echo "════════════════════════════════════════════════════════════"

