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

# Verify socat forwarding is running (set up by lifecycle postStart hook)
echo "Checking localhost:8080 forwarding..."
if ps aux | grep -q "[s]ocat.*8080"; then
  echo "✓ Socat is running"
  ps aux | grep "[s]ocat.*8080"
else
  echo "⚠️ Socat not running - may still be starting up"
fi

# Test connectivity to host nginx
if curl -sf --connect-timeout 2 http://localhost:8080 -o /dev/null 2>&1; then
  echo "✓ localhost:8080 forwarding is working"
else
  echo "⚠️ localhost:8080 not yet accessible"
fi

echo "=== Setup complete at: $(date) ==="
' && echo "✅ Jupyter setup completed successfully!" || echo "⚠️ Setup completed with warnings"

echo ""
echo "To verify setup, run:"
echo "  kubectl exec -n jupyter deploy/jupyter -- pip list | grep -E 'pandas|datasets|rich|pillow'"
echo "  kubectl exec -n jupyter deploy/jupyter -- ps aux | grep socat"
