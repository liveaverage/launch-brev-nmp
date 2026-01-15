#!/bin/bash
# Recovery script for MicroK8s after storage migration
# Run this if your MicroK8s cluster became unresponsive after bind mounting storage

set -e

echo "════════════════════════════════════════════════════════════"
echo "  MicroK8s Storage Migration Recovery"
echo "════════════════════════════════════════════════════════════"
echo ""

# Check if MicroK8s is installed
if ! command -v microk8s &> /dev/null; then
    echo "❌ MicroK8s not found"
    exit 1
fi

# Check if containerd storage is bind mounted
if mountpoint -q "/var/snap/microk8s/common/var/lib/containerd" 2>/dev/null; then
    echo "✅ Containerd storage is bind mounted to ephemeral volume"
    
    # Show current mount
    echo ""
    echo "Current mount:"
    findmnt /var/snap/microk8s/common/var/lib/containerd
    echo ""
else
    echo "⚠️  Containerd storage is NOT bind mounted"
    echo "   This script is only needed if storage was migrated."
    exit 0
fi

# Check cluster health
echo "🔍 Testing cluster connectivity..."
if kubectl cluster-info --request-timeout=5s &>/dev/null; then
    echo "✅ Cluster is healthy! No recovery needed."
    kubectl cluster-info
    exit 0
else
    echo "❌ Cluster is unresponsive. Starting recovery..."
fi

echo ""
echo "Step 1: Stopping MicroK8s..."
sudo microk8s stop
echo "   ✓ Stopped"

echo ""
echo "Step 2: Waiting for clean shutdown..."
sleep 5
echo "   ✓ Complete"

echo ""
echo "Step 3: Starting MicroK8s with new storage location..."
sudo microk8s start
echo "   ✓ Started"

echo ""
echo "Step 4: Waiting for cluster to be ready (this may take 1-2 minutes)..."
if sudo microk8s status --wait-ready --timeout 120; then
    echo "   ✓ MicroK8s is ready"
else
    echo "   ⚠️  Timeout waiting for MicroK8s. Check status with:"
    echo "      sudo microk8s status"
    exit 1
fi

echo ""
echo "Step 5: Verifying cluster health..."
if kubectl cluster-info --request-timeout=10s; then
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  ✅ Recovery Complete!"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "Cluster is now healthy and using ephemeral storage."
    echo ""
    
    # Recreate interlude container if running (to pick up new kubeconfig)
    if docker ps -a --format '{{.Names}}' | grep -q "^interlude$"; then
        echo "🔄 Recreating interlude container to refresh kubeconfig mount..."
        INSTALL_DIR=$(docker inspect interlude --format '{{range .Mounts}}{{if eq .Destination "/app/config.json"}}{{.Source}}{{end}}{{end}}' | xargs dirname)
        IMAGE=$(docker inspect interlude --format '{{.Config.Image}}')
        
        docker rm -f interlude >/dev/null 2>&1
        
        # Recreate using run-container.sh if available
        if [ -f "$INSTALL_DIR/run-container.sh" ]; then
            cd "$INSTALL_DIR"
            bash run-container.sh "$IMAGE"
            echo "   ✅ Container recreated"
        else
            echo "   ⚠️  Could not find run-container.sh"
            echo "      Manually restart: cd ~/launch-brev-nmp && bash run-container.sh"
        fi
        echo ""
    fi
    
    # Show resource usage
    echo "Storage location:"
    df -h /var/snap/microk8s/common/var/lib/containerd
    echo ""
    
    # Show running pods
    echo "Running pods:"
    kubectl get pods -A
else
    echo ""
    echo "════════════════════════════════════════════════════════════"
    echo "  ⚠️  Recovery Failed"
    echo "════════════════════════════════════════════════════════════"
    echo ""
    echo "Cluster is still unresponsive. Try:"
    echo "  1. Check MicroK8s logs: sudo microk8s inspect"
    echo "  2. Full reset: sudo microk8s stop && sudo microk8s start"
    echo "  3. Check system logs: journalctl -u snap.microk8s.daemon-kubelite"
    echo ""
    exit 1
fi
