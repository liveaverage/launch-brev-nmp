#!/bin/bash
# Deploy a default NIM microservice after NeMo platform install
# Single API call with inline config
set -e

# Configuration (can be overridden via environment)
NIM_MODEL="${NIM_MODEL:-meta/llama-3.1-8b-instruct}"
NIM_NAME="${NIM_NAME:-llama-3.1-8b-instruct}"
NIM_NAMESPACE="${NIM_NAMESPACE:-meta}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct}"
NIM_IMAGE_TAG="${NIM_IMAGE_TAG:-latest}"
NIM_GPU="${NIM_GPU:-1}"
NIM_PVC_SIZE="${NIM_PVC_SIZE:-25Gi}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

echo "🤖 Deploying NIM: $NIM_MODEL"

# Get Deployment Management service URL
get_service_url() {
    local cluster_ip
    cluster_ip=$(kubectl get svc -n nemo nemo-deployment-management -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [ -n "$cluster_ip" ] && [ "$cluster_ip" != "None" ]; then
        echo "http://${cluster_ip}:8000"
    else
        echo "http://127.0.0.1:9090"
    fi
}

DEPLOYMENT_URL=$(get_service_url)
echo "   Deployment API: $DEPLOYMENT_URL"

# Wait for service to be ready
echo "   Waiting for Deployment Management service..."
for i in $(seq 1 $((WAIT_TIMEOUT / 5))); do
    if curl -sf "${DEPLOYMENT_URL}/v1/deployment/model-deployments" -o /dev/null 2>&1; then
        echo "   ✓ Service ready"
        break
    fi
    if [ $i -eq $((WAIT_TIMEOUT / 5)) ]; then
        echo "   ⚠️ Service not ready after ${WAIT_TIMEOUT}s"
        exit 1
    fi
    sleep 5
done

# Check if deployment already exists
existing=$(curl -sf "${DEPLOYMENT_URL}/v1/deployment/model-deployments/${NIM_NAMESPACE}/${NIM_NAME}" 2>/dev/null || true)
if [ -n "$existing" ] && echo "$existing" | grep -q "\"name\""; then
    echo "   ✓ NIM deployment '${NIM_NAME}' already exists"
    exit 0
fi

# Create deployment with inline config
echo "🚀 Creating deployment..."
response=$(curl -s -w "\n%{http_code}" \
    --connect-timeout 10 \
    --max-time 30 \
    "${DEPLOYMENT_URL}/v1/deployment/model-deployments" \
    -H 'accept: application/json' \
    -H 'Content-Type: application/json' \
    -d "{
        \"name\": \"${NIM_NAME}\",
        \"namespace\": \"${NIM_NAMESPACE}\",
        \"config\": {
            \"model\": \"${NIM_MODEL}\",
            \"nim_deployment\": {
                \"image_name\": \"${NIM_IMAGE}\",
                \"image_tag\": \"${NIM_IMAGE_TAG}\",
                \"pvc_size\": \"${NIM_PVC_SIZE}\",
                \"gpu\": ${NIM_GPU},
                \"additional_envs\": {
                    \"NIM_GUIDED_DECODING_BACKEND\": \"auto\"
                }
            }
        }
    }" 2>&1)

status=$(echo "$response" | tail -n1)
body=$(echo "$response" | sed '$d')

if [ -n "$status" ] && [ "$status" -ge 200 ] && [ "$status" -lt 300 ]; then
    echo "✅ NIM deployment created: ${NIM_NAME}"
    echo "   Model: ${NIM_MODEL}"
    echo "   ⏳ Takes 5-15 minutes to pull image and start"
elif [ "$status" = "409" ]; then
    echo "✓ NIM deployment already exists"
else
    echo "⚠️ Failed (HTTP $status): $body"
    exit 1
fi
