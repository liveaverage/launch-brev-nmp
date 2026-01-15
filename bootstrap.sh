#!/bin/bash
# Bootstrap script for Interlude (NeMo Microservices Launcher)
# 
# Usage (non-interactive):
#   curl -fsSL https://raw.githubusercontent.com/liveaverage/launch-brev-nmp/main/bootstrap.sh | sudo -E bash
# 
# Usage (interactive):
#   curl -fsSL https://raw.githubusercontent.com/liveaverage/launch-brev-nmp/main/bootstrap.sh | bash
#
# Note: Storage extension requires sudo. Script will skip if not available.
set -e

REPO_URL="https://github.com/liveaverage/launch-brev-nmp.git"
IMAGE="ghcr.io/liveaverage/launch-brev-nmp:latest"
INSTALL_DIR="${INSTALL_DIR:-$HOME/launch-brev-nmp}"
CONTAINER_NAME="interlude"
OLD_CONTAINER_NAME="brev-launch-nmp"  # For cleanup of legacy containers
LOG_FILE="${LOG_FILE:-/var/log/interlude-bootstrap.log}"

# Detect if running as root and preserve original user
ORIGINAL_USER="${SUDO_USER:-$USER}"
ORIGINAL_HOME=$(getent passwd "$ORIGINAL_USER" | cut -d: -f6)

# If INSTALL_DIR uses $HOME and we're root, use original user's home
if [ "$EUID" -eq 0 ] && [ "$INSTALL_DIR" = "$HOME/launch-brev-nmp" ]; then
    INSTALL_DIR="$ORIGINAL_HOME/launch-brev-nmp"
fi

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

# Early sudo check if storage extension will be needed (non-interactive)
# This must happen BEFORE extend_root_storage is called
check_sudo_for_storage() {
    if mountpoint -q "/ephemeral" 2>/dev/null; then
        # Check if we have directories that would need mounting
        if [ -d "/var/lib/docker" ] || [ -d "/var/snap/microk8s/common/var/lib/containerd" ]; then
            # Check if not already mounted
            if ! mountpoint -q "/var/lib/docker" 2>/dev/null || ! mountpoint -q "/var/snap/microk8s/common/var/lib/containerd" 2>/dev/null; then
                # Check if we can run sudo commands
                if [ "$EUID" -eq 0 ]; then
                    # Already running as root, good to go
                    return 0
                elif sudo -n true 2>/dev/null; then
                    # Have passwordless sudo, good to go
                    return 0
                else
                    # No sudo access, skip storage extension
                    echo "⚠️  Storage extension requires sudo (skipping)"
                    return 1
                fi
            fi
        fi
    fi
    return 0
}

check_sudo_for_storage || SKIP_STORAGE_EXTENSION=true

# Extend root storage with ephemeral volumes
# Relocates heavy-use directories to ephemeral storage via bind mounts
extend_root_storage() {
    # Skip if explicitly disabled
    if [ "$SKIP_STORAGE_EXTENSION" = "true" ]; then
        return 0
    fi
    
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
            if [ "$EUID" -eq 0 ]; then
                echo "$EPHEMERAL_DEVICE $EPHEMERAL_BASE auto defaults,nofail 0 2" >> /etc/fstab
            else
                echo "$EPHEMERAL_DEVICE $EPHEMERAL_BASE auto defaults,nofail 0 2" | sudo tee -a /etc/fstab >/dev/null
            fi
        fi
    fi
    
    # Directories to relocate (space-hungry paths)
    local RELOCATE_DIRS=(
        "/var/lib/docker"
        "/var/snap/microk8s/common/var/lib/containerd"
    )
    
    # Check if services need to be stopped before mounting
    local NEED_DOCKER_RESTART=false
    local NEED_MICROK8S_RESTART=false
    
    for SOURCE_DIR in "${RELOCATE_DIRS[@]}"; do
        # Skip if source doesn't exist yet
        if [ ! -e "$SOURCE_DIR" ]; then
            continue
        fi
        
        # Skip if already bind mounted
        if mountpoint -q "$SOURCE_DIR" 2>/dev/null; then
            continue
        fi
        
        # Check if we need to stop services for this directory
        if [[ "$SOURCE_DIR" == "/var/lib/docker" ]] && systemctl is-active --quiet docker 2>/dev/null; then
            NEED_DOCKER_RESTART=true
        fi
        
        if [[ "$SOURCE_DIR" == *"microk8s"* ]] && snap services microk8s 2>/dev/null | grep -q "active"; then
            NEED_MICROK8S_RESTART=true
        fi
    done
    
    # Stop services if needed
    if [ "$NEED_DOCKER_RESTART" = "true" ]; then
        echo "   ⏸️  Stopping Docker for storage migration..."
        if [ "$EUID" -eq 0 ]; then
            systemctl stop docker
        else
            sudo systemctl stop docker
        fi
    fi
    
    if [ "$NEED_MICROK8S_RESTART" = "true" ]; then
        echo "   ⏸️  Stopping MicroK8s for storage migration..."
        if [ "$EUID" -eq 0 ]; then
            microk8s stop
        else
            sudo microk8s stop
        fi
        # Give it a moment to fully stop
        sleep 5
    fi
    
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
        if [ "$EUID" -eq 0 ]; then
            mkdir -p "$TARGET_DIR"
        else
            sudo mkdir -p "$TARGET_DIR"
        fi
        
        # Move existing data if any
        if [ -d "$SOURCE_DIR" ] && [ "$(ls -A $SOURCE_DIR 2>/dev/null)" ]; then
            echo "   📦 Migrating: $SOURCE_DIR → $TARGET_DIR"
            if [ "$EUID" -eq 0 ]; then
                rsync -a "$SOURCE_DIR/" "$TARGET_DIR/" 2>/dev/null || cp -a "$SOURCE_DIR"/* "$TARGET_DIR/" 2>/dev/null || true
                rm -rf "${SOURCE_DIR:?}"/*  # Clear original (keep dir)
            else
                sudo rsync -a "$SOURCE_DIR/" "$TARGET_DIR/" 2>/dev/null || sudo cp -a "$SOURCE_DIR"/* "$TARGET_DIR/" 2>/dev/null || true
                sudo rm -rf "${SOURCE_DIR:?}"/*  # Clear original (keep dir)
            fi
        fi
        
        # Ensure source directory exists
        if [ "$EUID" -eq 0 ]; then
            mkdir -p "$SOURCE_DIR"
        else
            sudo mkdir -p "$SOURCE_DIR"
        fi
        
        # Bind mount
        local MOUNT_CMD="mount --bind \"$TARGET_DIR\" \"$SOURCE_DIR\""
        if [ "$EUID" -eq 0 ]; then
            if mount --bind "$TARGET_DIR" "$SOURCE_DIR"; then
                echo "   ✓ Mounted: $SOURCE_DIR → $TARGET_DIR"
                
                # Make persistent across reboots via /etc/fstab
                local FSTAB_ENTRY="$TARGET_DIR $SOURCE_DIR none bind 0 0"
                if ! grep -qF "$SOURCE_DIR" /etc/fstab 2>/dev/null; then
                    echo "   📝 Adding to /etc/fstab for persistence"
                    echo "$FSTAB_ENTRY" >> /etc/fstab
                fi
            else
                echo "   ⚠️  Failed to mount: $SOURCE_DIR"
            fi
        else
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
        fi
    done
    
    # Restart services if they were stopped
    if [ "$NEED_MICROK8S_RESTART" = "true" ]; then
        echo "   ▶️  Starting MicroK8s with new storage location..."
        if [ "$EUID" -eq 0 ]; then
            microk8s start
        else
            sudo microk8s start
        fi
        echo "   ⏳ Waiting for MicroK8s to be ready..."
        if [ "$EUID" -eq 0 ]; then
            microk8s status --wait-ready --timeout 60 2>/dev/null || echo "   ⚠️  MicroK8s startup timeout (may need manual check)"
        else
            sudo microk8s status --wait-ready --timeout 60 2>/dev/null || echo "   ⚠️  MicroK8s startup timeout (may need manual check)"
        fi
    fi
    
    if [ "$NEED_DOCKER_RESTART" = "true" ]; then
        echo "   ▶️  Starting Docker with new storage location..."
        if [ "$EUID" -eq 0 ]; then
            systemctl start docker
        else
            sudo systemctl start docker
        fi
    fi
    
    echo ""
}

extend_root_storage

# Recovery check: If MicroK8s is running but broken due to storage migration, restart it
recover_microk8s_if_needed() {
    # Only check if MicroK8s is installed
    if ! command -v microk8s &> /dev/null; then
        return 0
    fi
    
    # Check if containerd storage is bind mounted
    if ! mountpoint -q "/var/snap/microk8s/common/var/lib/containerd" 2>/dev/null; then
        return 0  # Not bind mounted, no recovery needed
    fi
    
    local RECOVERY_PERFORMED=false
    
    # Check if MicroK8s appears to be running but cluster is broken
    if snap services microk8s 2>/dev/null | grep -q "active"; then
        echo "🔍 Checking MicroK8s cluster health..."
        if ! kubectl cluster-info --request-timeout=5s &>/dev/null; then
            echo "⚠️  MicroK8s cluster appears broken (likely due to storage migration)"
            echo "   🔄 Attempting automatic recovery..."
            
            if [ "$EUID" -eq 0 ]; then
                microk8s stop
                sleep 5
                microk8s start
                echo "   ⏳ Waiting for MicroK8s to be ready..."
                microk8s status --wait-ready --timeout 120 2>/dev/null || echo "   ⚠️  Recovery timeout (may need manual intervention)"
            else
                sudo microk8s stop
                sleep 5
                sudo microk8s start
                echo "   ⏳ Waiting for MicroK8s to be ready..."
                sudo microk8s status --wait-ready --timeout 120 2>/dev/null || echo "   ⚠️  Recovery timeout (may need manual intervention)"
            fi
            
            # Verify recovery
            if kubectl cluster-info --request-timeout=10s &>/dev/null; then
                echo "   ✅ MicroK8s cluster recovered successfully!"
                RECOVERY_PERFORMED=true
            else
                echo "   ⚠️  Cluster still unhealthy. Manual recovery may be needed:"
                echo "      sudo microk8s stop && sleep 5 && sudo microk8s start"
            fi
        else
            echo "   ✅ MicroK8s cluster is healthy"
        fi
    fi
    
    # If recovery was performed, recreate any running interlude container to pick up new kubeconfig
    if [ "$RECOVERY_PERFORMED" = "true" ]; then
        if docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$" 2>/dev/null; then
            echo "   🔄 Recreating interlude container to refresh kubeconfig mount..."
            docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
            # Note: Container will be recreated later in bootstrap if this is during initial setup
            echo "   ✅ Container will be recreated with fresh kubeconfig"
        fi
    fi
}

recover_microk8s_if_needed

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
    
    # Fix ownership if running as root via sudo
    if [ "$EUID" -eq 0 ] && [ -n "$SUDO_USER" ]; then
        echo "   📝 Fixing ownership for $SUDO_USER..."
        chown -R "$SUDO_USER:$SUDO_USER" "$INSTALL_DIR"
    fi
fi

echo ""
echo "🐳 Pulling container image..."
docker pull "$IMAGE"

echo ""
echo "🚀 Starting launcher..."
echo ""

# Run the container
bash run-container.sh "$IMAGE"

# Give it a moment to start and stabilize
sleep 3

# Always recreate container to ensure fresh kubeconfig mount
# Note: docker restart doesn't remount volumes, so we need full rm + run
# This catches any changes from storage migration, MicroK8s restarts, etc.
if docker ps -a -q -f name="^${CONTAINER_NAME}$" >/dev/null 2>&1; then
    echo "🔄 Recreating container to ensure fresh kubeconfig mount..."
    docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1
    bash run-container.sh "$IMAGE"
    echo "   ✅ Container recreated with latest configuration"
fi

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
