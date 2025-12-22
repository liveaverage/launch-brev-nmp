#!/bin/bash

# Deployment script specifically for NeMo Microservices Quickstart
# This script runs the deployment app in the most compatible way for local development

set -e

echo "=================================================="
echo "NeMo Microservices Deployment Setup"
echo "=================================================="
echo ""

# Check prerequisites
if ! command -v docker &> /dev/null; then
    echo "ERROR: Docker is not installed or not in PATH"
    exit 1
fi

if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
    echo "ERROR: docker-compose is not installed"
    exit 1
fi

# Check if nemo directory exists
if [ ! -d "nemo-microservices-quickstart_25.12" ]; then
    echo "ERROR: nemo-microservices-quickstart_25.12 directory not found"
    echo "Please ensure the NeMo Microservices directory is in the current path"
    exit 1
fi

echo "Prerequisites check: PASSED"
echo ""

# Determine best deployment method
echo "Determining deployment method..."
echo ""

# For Docker Compose, we can run directly on host (simplest)
if [ "$1" == "--native" ]; then
    echo "Running in NATIVE mode (recommended for Docker Compose)"
    echo "----------------------------------------------------"
    echo ""

    # Install Python dependencies if needed
    if ! python3 -c "import flask" 2>/dev/null; then
        echo "Installing Python dependencies..."
        pip3 install -r requirements.txt
    fi

    # Use NeMo-specific config
    export CONFIG_FILE="$(pwd)/config-nemo.json"

    echo "Starting deployment app..."
    echo "Configuration: $CONFIG_FILE"
    echo ""
    echo "Access the deployment interface at: http://localhost:8080"
    echo ""
    echo "When prompted, enter your NGC API key from:"
    echo "  https://org.ngc.nvidia.com/setup/api-key"
    echo ""

    python3 app.py

elif [ "$1" == "--docker" ]; then
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

    # Run with Docker socket mounted
    echo "Starting container..."
    docker run -d \
      -p 8080:8080 \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v "$(pwd)/nemo-microservices-quickstart_25.12":/app/nemo-microservices-quickstart_25.12:ro \
      -v "$(pwd)/config-nemo.json":/app/config.json:ro \
      --name deployment-app \
      deployment-app

    echo ""
    echo "Deployment app is running!"
    echo "Access at: http://localhost:8080"
    echo ""
    echo "View logs: docker logs -f deployment-app"

else
    echo "Usage: $0 [--native|--docker]"
    echo ""
    echo "  --native    Run directly on host (RECOMMENDED for Docker Compose)"
    echo "  --docker    Run in Docker container"
    echo ""
    echo "For NeMo Microservices with Docker Compose, we recommend:"
    echo "  $0 --native"
    echo ""
    exit 1
fi

echo ""
echo "=================================================="
echo "Setup complete!"
echo "=================================================="
echo ""
echo "Next steps:"
echo "1. Navigate to http://localhost:8080"
echo "2. Enter your NGC API key"
echo "3. Click 'Let it rip' to start NeMo Microservices"
echo ""
echo "Get your NGC API key from:"
echo "  https://org.ngc.nvidia.com/setup/api-key"
echo ""
