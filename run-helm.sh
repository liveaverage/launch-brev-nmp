#!/bin/bash

# Deployment script for NeMo Microservices Helm Chart
# Supports auto-fetch from NGC with version selection

set -e

echo "=================================================="
echo "NeMo Microservices Helm Deployment"
echo "=================================================="
echo ""

# Check prerequisites
echo "Checking prerequisites..."

if ! command -v kubectl &> /dev/null; then
    echo "ERROR: kubectl is not installed"
    exit 1
fi

if ! command -v helm &> /dev/null; then
    echo "ERROR: helm is not installed"
    exit 1
fi

# Check Kubernetes cluster connectivity
if ! kubectl cluster-info &> /dev/null; then
    echo "ERROR: Cannot connect to Kubernetes cluster"
    echo "Please ensure:"
    echo "  - Your kubeconfig is properly configured"
    echo "  - Your Kubernetes cluster is running"
    echo "  - kubectl can access the cluster"
    exit 1
fi

echo "✓ kubectl: OK"
echo "✓ helm: OK"
echo "✓ Kubernetes cluster: Connected"
echo ""

# Determine deployment method
echo "Select deployment method:"
echo "  1. Native mode (recommended for local K8s)"
echo "  2. Docker container mode"
echo ""

if [ -z "$1" ]; then
    read -p "Enter choice [1]: " choice
    choice=${choice:-1}
else
    if [ "$1" == "--native" ]; then
        choice=1
    elif [ "$1" == "--docker" ]; then
        choice=2
    else
        echo "Usage: $0 [--native|--docker]"
        exit 1
    fi
fi

export CONFIG_FILE="$(pwd)/config-helm.json"
export HELP_CONTENT_FILE="$(pwd)/help-content.json"

if [ "$choice" == "1" ]; then
    echo ""
    echo "Running in NATIVE mode"
    echo "----------------------"
    echo ""

    # Check Python dependencies
    if ! python3 -c "import flask" 2>/dev/null; then
        echo "Installing Python dependencies..."
        pip3 install -r requirements.txt
    fi

    echo "Starting deployment app..."
    echo "Configuration: $CONFIG_FILE"
    echo "Help content: $HELP_CONTENT_FILE"
    echo ""
    echo "=================================================="
    echo "Access the deployment interface at:"
    echo "  http://localhost:8080"
    echo "=================================================="
    echo ""
    echo "When prompted:"
    echo "  1. Enter your NGC API key from: https://org.ngc.nvidia.com/setup/api-key"
    echo "  2. Select 'Helm with Auto-Fetch'"
    echo "  3. Choose version (25.12.0 recommended)"
    echo "  4. Click 'Let it rip'"
    echo ""
    echo "The app will:"
    echo "  • Fetch the Helm chart from NGC"
    echo "  • Install it to your Kubernetes cluster"
    echo "  • Configure NGC API key for image pulls"
    echo ""

    python3 app.py

elif [ "$choice" == "2" ]; then
    echo ""
    echo "Running in DOCKER mode"
    echo "----------------------"
    echo ""

    # Build image if needed
    if ! docker images | grep -q deployment-app; then
        echo "Building Docker image..."
        docker build -t deployment-app .
    fi

    # Stop existing container
    docker rm -f deployment-app 2>/dev/null || true

    # Determine if we should use host network
    if [[ "$OSTYPE" == "linux-gnu"* ]]; then
        echo "Using host network mode (Linux detected)"
        NETWORK_FLAG="--network host"
        PORT_FLAG=""
        URL="http://localhost:8080"
    else
        echo "Using port mapping (Mac/Windows detected)"
        NETWORK_FLAG=""
        PORT_FLAG="-p 8080:8080"
        URL="http://localhost:8080"
    fi

    echo "Starting container..."
    docker run -d \
      $NETWORK_FLAG \
      $PORT_FLAG \
      -v ~/.kube/config:/root/.kube/config:ro \
      -v "$(pwd)/config-helm.json":/app/config.json:ro \
      -v "$(pwd)/help-content.json":/app/help-content.json:ro \
      --name deployment-app \
      deployment-app

    echo ""
    echo "=================================================="
    echo "Deployment app is running!"
    echo "=================================================="
    echo ""
    echo "Access at: $URL"
    echo ""
    echo "View logs: docker logs -f deployment-app"
    echo "Stop app: docker stop deployment-app"
    echo ""

else
    echo "Invalid choice: $choice"
    exit 1
fi

echo ""
echo "=================================================="
echo "For detailed information about the Helm flow:"
echo "  cat HELM-FLOW.md"
echo ""
echo "For help and troubleshooting:"
echo "  Click the (?) button in the web interface"
echo "=================================================="
