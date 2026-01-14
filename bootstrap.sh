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

# Extend root storage with ephemeral volumes
# Relocates heavy-use directories to ephemeral storage via bind mounts
extend_root_storage() {
    local EPHEMERAL_BASE="/ephemeral"
    local EPHEMERAL_DATA="${EPHEMERAL_BASE}/data"
    
    # Check if ephemeral volume exists and has space
    if ! mountpoint -q "$EPHEMERAL_BASE" 2>/dev/null; then
        return 0  # No ephemeral volume, skip
    fi
    
    local EPHEMERAL_AVAIL=$(df -BG "$EPHEMERAL_BASE" | awk 'NR==2 {print $4}' | sed 's/G//')
    if [ "$EPHEMERAL_AVAIL" -lt 50 ]; then
        return 0  # Less than 50GB available, not worth it
    fi
    
    echo "💾 Extending root storage with ephemeral volume..."
    echo "   Available: ${EPHEMERAL_AVAIL}GB at $EPHEMERAL_BASE"
    
    # Directories to relocate (space-hungry paths)
    local RELOCATE_DIRS=(
        "/var/lib/docker"
        "/var/snap/microk8s/common/var/lib/containerd"
    )
    
    for SOURCE_DIR in "${RELOCATE_DIRS[@]}"; do
        # Skip if source doesn't exist yet
        if [ ! -e "$SOURCE_DIR" ]; then
            continue
        fi
        
        local TARGET_DIR="${EPHEMERAL_DATA}${SOURCE_DIR}"
        
        # Skip if already bind mounted
        if mountpoint -q "$SOURCE_DIR" 2>/dev/null; then
            echo "   ✓ Already mounted: $SOURCE_DIR"
            continue
        fi
        
        # Create target directory
        mkdir -p "$TARGET_DIR"
        
        # Move existing data if any
        if [ -d "$SOURCE_DIR" ] && [ "$(ls -A $SOURCE_DIR 2>/dev/null)" ]; then
            echo "   📦 Migrating: $SOURCE_DIR → $TARGET_DIR"
            rsync -a "$SOURCE_DIR/" "$TARGET_DIR/" 2>/dev/null || cp -a "$SOURCE_DIR"/* "$TARGET_DIR/" 2>/dev/null || true
            rm -rf "${SOURCE_DIR:?}"/*  # Clear original (keep dir)
        fi
        
        # Ensure source directory exists
        mkdir -p "$SOURCE_DIR"
        
        # Bind mount
        if mount --bind "$TARGET_DIR" "$SOURCE_DIR"; then
            echo "   ✓ Mounted: $SOURCE_DIR → $TARGET_DIR"
        else
            echo "   ⚠️  Failed to mount: $SOURCE_DIR"
        fi
    done
    
    echo ""
}

extend_root_storage

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
echo "  📁 Config: $INSTALL_DIR/config.json"
echo "  📋 Logs:   docker logs -f $CONTAINER_NAME"
echo "  🛑 Stop:   docker stop $CONTAINER_NAME"
echo "════════════════════════════════════════════════════════════"

