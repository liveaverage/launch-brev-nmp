#!/bin/bash

# Quick run script - handles virtual environment automatically

if [ -d "venv" ]; then
    echo "Using virtual environment..."
    source venv/bin/activate
fi

# Set which config to use (defaults to Helm with auto-fetch)
# You can override: DEPLOY_TYPE=helm-nemo-local ./run-local-quick.sh
export DEPLOY_TYPE=${DEPLOY_TYPE:-helm-nemo}

echo "=========================================="
echo "Starting Deployment App"
echo "=========================================="
echo ""
echo "Active deployment: $DEPLOY_TYPE"

if [ "$DRY_RUN" = "true" ]; then
    echo "Mode: DRY RUN (no actual deployments)"
else
    echo "Mode: Normal"
fi

echo ""
echo "Access at: http://localhost:8080"
echo "Press Ctrl+C to stop"
echo ""
echo "Tip: Click the (?) button for help"
echo ""

python3 app.py
