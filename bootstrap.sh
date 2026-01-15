#!/bin/bash
# Bootstrap script for Interlude (NeMo Microservices Launcher)
# Usage: curl -fsSL https://raw.githubusercontent.com/liveaverage/launch-brev-nmp/main/bootstrap.sh | bash
# Note: Sudo access required for storage extension (will prompt if needed)
set -e

REPO_URL="https://github.com/liveaverage/launch-brev-nmp.git"
IMAGE="ghcr.io/liveaverage/launch-brev-nmp:latest"
INSTALL_DIR="${INSTALL_DIR:-$HOME/launch-brev-nmp}"
CONTAINER_NAME="interlude"
OLD_CONTAINER_NAME="brev-launch-nmp"  # For cleanup of legacy containers
LOG_FILE="${LOG_FILE:-/var/log/interlude-bootstrap.log}"

# Setup logging: tee to both console and log file
setup_logging() {
    # Ensure log directory exists
    local LOG_DIR=$(dirname "$LOG_FILE")
    if [ ! -d "$LOG_DIR" ]; then
        sudo mkdir -p "$LOG_DIR" 2>/dev/null || {
            # Fallback to user home if /var/log is not writable
            LOG_FILE="$HOME/.interlude-bootstrap.log"
            LOG_DIR=$(dirname "$LOG_FILE")
            mkdir -p "$LOG_DIR"
        }
    fi
    
    # Test write permissions
    if ! sudo touch "$LOG_FILE" 2>/dev/null && ! touch "$LOG_FILE" 2>/dev/null; then
        LOG_FILE="$HOME/.interlude-bootstrap.log"
        touch "$LOG_FILE"
    fi
    
    # Redirect all output to both console and log file
    exec > >(sudo tee -a "$LOG_FILE" 2>/dev/null || tee -a "$LOG_FILE")
    exec 2>&1
    
    # Log session header
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "Bootstrap session: $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo "Log file: $LOG_FILE"
    echo "════════════════════════════════════════════════════════════"
}

setup_logging

echo "════════════════════════════════════════════════════════════"
echo "  Interlude - NeMo Microservices Launcher"
echo "════════════════════════════════════════════════════════════"
echo ""

# Early sudo check if storage extension will be needed
# This must happen BEFORE extend_root_storage is called
if mountpoint -q "/ephemeral" 2>/dev/null; then
    # Check if we have directories that would need mounting
    if [ -d "/var/lib/docker" ] || [ -d "/var/snap/microk8s/common/var/lib/containerd" ]; then
        # Check if not already mounted
        if ! mountpoint -q "/var/lib/docker" 2>/dev/null || ! mountpoint -q "/var/snap/microk8s/common/var/lib/containerd" 2>/dev/null; then
            # Test if we have sudo without prompting
            if ! sudo -n true 2>/dev/null; then
                echo "🔐 Storage extension requires sudo privileges."
                echo "   You may be prompted for your password..."
                sudo -v || {
                    echo "⚠️  Warning: sudo access required for storage extension"
                    echo "   Continuing without storage extension..."
                }
            fi
        fi
    fi
fi

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
    
    # Ensure ephemeral volume persists across reboots
    local EPHEMERAL_DEVICE=$(df "$EPHEMERAL_BASE" | awk 'NR==2 {print $1}')
    if [ -n "$EPHEMERAL_DEVICE" ] && [ "$EPHEMERAL_DEVICE" != "tmpfs" ]; then
        if ! grep -qF "$EPHEMERAL_DEVICE" /etc/fstab 2>/dev/null; then
            echo "   📝 Making ephemeral volume persistent in /etc/fstab"
            echo "$EPHEMERAL_DEVICE $EPHEMERAL_BASE auto defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
        fi
    fi
    
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
        sudo mkdir -p "$TARGET_DIR"
        
        # Move existing data if any
        if [ -d "$SOURCE_DIR" ] && [ "$(ls -A $SOURCE_DIR 2>/dev/null)" ]; then
            echo "   📦 Migrating: $SOURCE_DIR → $TARGET_DIR"
            sudo rsync -a "$SOURCE_DIR/" "$TARGET_DIR/" 2>/dev/null || sudo cp -a "$SOURCE_DIR"/* "$TARGET_DIR/" 2>/dev/null || true
            sudo rm -rf "${SOURCE_DIR:?}"/*  # Clear original (keep dir)
        fi
        
        # Ensure source directory exists
        sudo mkdir -p "$SOURCE_DIR"
        
        # Bind mount
        if sudo mount --bind "$TARGET_DIR" "$SOURCE_DIR"; then
            echo "   ✓ Mounted: $SOURCE_DIR → $TARGET_DIR"
            
            # Make persistent across reboots via /etc/fstab
            local FSTAB_ENTRY="$TARGET_DIR $SOURCE_DIR none bind 0 0"
            if ! grep -qF "$SOURCE_DIR" /etc/fstab 2>/dev/null; then
                echo "   📝 Adding to /etc/fstab for persistence"
                echo "$FSTAB_ENTRY" | sudo tee -a /etc/fstab >/dev/null
            fi
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
echo "  📝 Bootstrap log: $LOG_FILE"
echo "  🛑 Stop:   docker stop $CONTAINER_NAME"
echo "════════════════════════════════════════════════════════════"

echo ""
echo "Bootstrap completed successfully at $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "════════════════════════════════════════════════════════════"
