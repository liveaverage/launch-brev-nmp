#!/bin/bash

# Run the deployment app natively on the host (no container)
# This is the simplest approach for local Kubernetes orchestration

echo "Installing Python dependencies..."
pip install -r requirements.txt

echo ""
echo "Starting deployment app natively on host..."
echo "This approach provides:"
echo "  - Direct access to Docker socket"
echo "  - Direct access to kubectl/helm with your kubeconfig"
echo "  - No network isolation issues"
echo ""
echo "Access at http://localhost:8080"
echo ""

python3 app.py
