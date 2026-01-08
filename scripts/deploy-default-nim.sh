#!/bin/bash
# Deploy a default NIM microservice after NeMo platform install
# Uses internal routing via nginx proxy or direct K8s service access
#
# Ref: https://docs.nvidia.com/nemo/microservices/latest/run-inference/deployment-management/deploy-nim.html
set -e

# Configuration (can be overridden via environment)
NIM_MODEL="${NIM_MODEL:-meta/llama-3.1-8b-instruct}"
NIM_NAME="${NIM_NAME:-default-llm}"
NIM_NAMESPACE="${NIM_NAMESPACE:-default}"
NIM_PROJECT="${NIM_PROJECT:-default}"
NIM_CONFIG="${NIM_CONFIG:-default}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

echo "🤖 Deploying default NIM: $NIM_MODEL"

# Determine the API base URL
# Priority: 1) Direct K8s ClusterIP (most reliable), 2) Docker host bridge, 3) localhost
get_deployment_url() {
    # Try to get ClusterIP of deployment-management service
    local cluster_ip
    cluster_ip=$(kubectl get svc -n nemo nemo-deployment-management -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    
    if [ -n "$cluster_ip" ] && [ "$cluster_ip" != "None" ]; then
        echo "http://${cluster_ip}:8000"
        return
    fi
    
    # Fallback to Docker host bridge (for container-to-host access)
    if [ -n "$DEPLOYMENT_BASE_URL" ]; then
        echo "$DEPLOYMENT_BASE_URL"
        return
    fi
    
    # Last resort: localhost via nginx proxy
    echo "http://127.0.0.1:9090"
}

DEPLOYMENT_BASE_URL=$(get_deployment_url)
echo "   API endpoint: $DEPLOYMENT_BASE_URL/v1/deployment/model-deployments"

# Wait for the Deployment Management service to be ready
echo "   Waiting for Deployment Management service..."
for i in $(seq 1 $((WAIT_TIMEOUT / 5))); do
    if curl -sf "${DEPLOYMENT_BASE_URL}/v1/deployment/model-deployments" -o /dev/null 2>&1; then
        echo "   ✓ Deployment Management service ready"
        break
    fi
    if [ $i -eq $((WAIT_TIMEOUT / 5)) ]; then
        echo "   ⚠️ Deployment Management not ready after ${WAIT_TIMEOUT}s, skipping NIM deployment"
        echo "   You can deploy a NIM manually via Studio or API later"
        exit 0
    fi
    sleep 5
done

# Check if a deployment with this name already exists
existing=$(curl -sf "${DEPLOYMENT_BASE_URL}/v1/deployment/model-deployments?namespace=${NIM_NAMESPACE}&name=${NIM_NAME}" 2>/dev/null || echo '{"items":[]}')
if echo "$existing" | grep -q "\"name\":\"${NIM_NAME}\""; then
    echo "   ✓ NIM deployment '${NIM_NAME}' already exists, skipping"
    exit 0
fi

# Create the NIM deployment
echo "   Creating NIM deployment..."
response=$(curl -sf -X POST \
    "${DEPLOYMENT_BASE_URL}/v1/deployment/model-deployments" \
    -H 'accept: application/json' \
    -H 'Content-Type: application/json' \
    -d "{
        \"name\": \"${NIM_NAME}\",
        \"namespace\": \"${NIM_NAMESPACE}\",
        \"description\": \"Default LLM deployed by Interlude launcher\",
        \"models\": [\"${NIM_MODEL}\"],
        \"async_enabled\": false,
        \"config\": \"${NIM_CONFIG}\",
        \"project\": \"${NIM_PROJECT}\",
        \"custom_fields\": {},
        \"ownership\": {
            \"created_by\": \"interlude\",
            \"access_policies\": {}
        }
    }" 2>&1) || {
    echo "   ⚠️ Failed to create NIM deployment: $response"
    echo "   You can deploy a NIM manually via Studio (/studio) later"
    exit 0
}

# Check response
if echo "$response" | grep -q '"name"'; then
    echo "   ✓ NIM deployment created: ${NIM_NAME}"
    echo "   Model: ${NIM_MODEL}"
    echo ""
    echo "   ℹ️ NIM deployment may take several minutes to become ready."
    echo "   Check status at: /studio → Models"
else
    echo "   ⚠️ Unexpected response: $response"
    echo "   Check /studio for deployment status"
fi

