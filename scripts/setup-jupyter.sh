#!/bin/bash
# Purpose: One-time setup for Jupyter pod - install Data Designer and configure networking
# Run after Jupyter pod is stable: bash scripts/setup-jupyter.sh

set -e

echo "🔧 Setting up Jupyter pod..."

# Wait for Jupyter pod to be ready
echo "⏳ Waiting for Jupyter pod to be ready..."
kubectl wait --for=condition=ready pod -l app=jupyter -n jupyter --timeout=180s || {
    echo "⚠️ Jupyter pod not ready after 3 minutes, attempting setup anyway..."
}

POD_NAME=$(kubectl get pod -n jupyter -l app=jupyter -o jsonpath='{.items[0].metadata.name}')
echo "📦 Using pod: $POD_NAME"

# Run setup commands inside the pod
kubectl exec -n jupyter "$POD_NAME" -- bash -c '
set -e

echo "=== Jupyter Setup Script ==="
echo "Starting at: $(date)"

# Wait for repo to be cloned by entrypoint
echo "Checking for NeMo-Data-Designer repo..."
for i in $(seq 1 30); do
  if [ -f /home/jovyan/work/repo/nemo/NeMo-Data-Designer/pyproject.toml ] || \
     [ -f /tmp/work/repo/nemo/NeMo-Data-Designer/pyproject.toml ]; then
    echo "✓ Found pyproject.toml after ${i} attempts"
    break
  fi
  sleep 2
done

# Find the actual work directory
if [ -f /home/jovyan/work/repo/nemo/NeMo-Data-Designer/pyproject.toml ]; then
  REPO_PATH="/home/jovyan/work/repo/nemo/NeMo-Data-Designer"
elif [ -f /tmp/work/repo/nemo/NeMo-Data-Designer/pyproject.toml ]; then
  REPO_PATH="/tmp/work/repo/nemo/NeMo-Data-Designer"
else
  echo "⚠️ NeMo-Data-Designer not found, skipping package install"
  REPO_PATH=""
fi

# Install packages
if [ -n "$REPO_PATH" ]; then
  echo "Installing Data Designer from: $REPO_PATH"
  pip install "$REPO_PATH" || echo "⚠️ Data Designer install failed"
fi

echo "Installing additional packages..."
pip install pandas datasets rich pillow || echo "⚠️ Additional packages install failed"

# Set up localhost:8080 forwarding to host nginx
echo "Setting up localhost:8080 forwarding..."
if [ -n "$K8S_NODE_IP" ]; then
  HOST_IP="$K8S_NODE_IP"
  echo "Using Kubernetes node IP: ${HOST_IP}"
else
  # Fallback to gateway
  GATEWAY_HEX=$(awk "\$2 == \"00000000\" {print \$3}" /proc/net/route | head -1)
  HOST_IP=$(printf "%d.%d.%d.%d" 0x${GATEWAY_HEX:6:2} 0x${GATEWAY_HEX:4:2} 0x${GATEWAY_HEX:2:2} 0x${GATEWAY_HEX:0:2})
  echo "Using gateway IP: ${HOST_IP}"
fi

# Test connectivity
if curl -sf --connect-timeout 2 http://${HOST_IP}:8080 -o /dev/null; then
  echo "✓ Host nginx at ${HOST_IP}:8080 is reachable"
else
  echo "⚠️ Host nginx at ${HOST_IP}:8080 not reachable"
fi

# Start socat in background
pkill socat 2>/dev/null || true
nohup socat TCP-LISTEN:8080,fork,reuseaddr TCP:${HOST_IP}:8080 >/tmp/socat.log 2>&1 &
SOCAT_PID=$!
echo "✓ Socat forwarding started (PID: $SOCAT_PID)"

echo "=== Setup complete at: $(date) ==="
' && echo "✅ Jupyter setup completed successfully!" || echo "⚠️ Setup completed with warnings"

echo ""
echo "To verify setup, run:"
echo "  kubectl exec -n jupyter deploy/jupyter -- pip list | grep -E 'pandas|datasets|rich|pillow'"
echo "  kubectl exec -n jupyter deploy/jupyter -- ps aux | grep socat"
