#!/bin/bash

# Run the deployment app with host network mode
# This allows the container to access localhost Kubernetes clusters

docker run -d \
  --network host \
  -v /var/run/docker.sock:/var/run/docker.sock \
  -v ~/.kube/config:/root/.kube/config:ro \
  -v $(pwd)/docker-compose.yaml:/app/docker-compose.yaml:ro \
  -v $(pwd)/config.json:/app/config.json:ro \
  --name deployment-app \
  deployment-app

echo "Deployment app is running with host network mode"
echo "Access at http://localhost:8080"
echo ""
echo "This configuration allows:"
echo "  - Access to local Kubernetes clusters (kind, k3s, minikube, etc.)"
echo "  - Docker socket for Docker Compose operations"
echo "  - Helm deployments to local clusters"
