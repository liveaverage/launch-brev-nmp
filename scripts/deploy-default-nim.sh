#!/bin/bash
# Deploy a default NIM microservice after NeMo platform install
# Prerequisites: Register model, create deployment config, then deploy
#
# Ref: https://docs.nvidia.com/nemo/microservices/latest/run-inference/deployment-management/deploy-nim.html
set -e

# Configuration (can be overridden via environment)
NIM_MODEL="${NIM_MODEL:-meta/llama-3.1-8b-instruct}"
NIM_MODEL_NAME="${NIM_MODEL_NAME:-llama-3.1-8b-instruct}"
NIM_NAME="${NIM_NAME:-default-llm}"
NIM_NAMESPACE="${NIM_NAMESPACE:-default}"
NIM_PROJECT="${NIM_PROJECT:-default}"
NIM_CONFIG="${NIM_CONFIG:-default}"
NIM_IMAGE="${NIM_IMAGE:-nvcr.io/nim/meta/llama-3.1-8b-instruct}"
NIM_IMAGE_TAG="${NIM_IMAGE_TAG:-latest}"
NIM_GPU="${NIM_GPU:-1}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-300}"

echo "🤖 Deploying default NIM: $NIM_MODEL"
echo "   Steps: 1) Register model → 2) Create config → 3) Deploy"
echo ""

# Determine the API base URLs
# Priority: 1) Direct K8s ClusterIP (most reliable), 2) Docker host bridge, 3) localhost
get_service_url() {
    local service_name="$1"
    local port="$2"
    local cluster_ip
    cluster_ip=$(kubectl get svc -n nemo "$service_name" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    
    if [ -n "$cluster_ip" ] && [ "$cluster_ip" != "None" ]; then
        echo "http://${cluster_ip}:${port}"
        return
    fi
    
    # Fallback to localhost via nginx proxy
    echo "http://127.0.0.1:9090"
}

ENTITY_STORE_URL=$(get_service_url "nemo-entity-store" "8000")
DEPLOYMENT_URL=$(get_service_url "nemo-deployment-management" "8000")

echo "   Entity Store: $ENTITY_STORE_URL"
echo "   Deployment Management: $DEPLOYMENT_URL"
echo ""

# ═══════════════════════════════════════════════════════════════
# STEP 1: Register Model in Entity Store
# ═══════════════════════════════════════════════════════════════
echo "📋 Step 1: Registering model in Entity Store..."

# Check if model already exists
existing_model=$(curl -sf "${ENTITY_STORE_URL}/v1/models?namespace=${NIM_NAMESPACE}&name=${NIM_MODEL_NAME}" 2>/dev/null || echo '{"models":[]}')
if echo "$existing_model" | grep -q "\"name\":\"${NIM_MODEL_NAME}\""; then
    echo "   ✓ Model '${NIM_MODEL_NAME}' already registered"
else
    # Register the model
    model_response=$(curl -s -w "\n%{http_code}" -X POST \
        "${ENTITY_STORE_URL}/v1/models" \
        -H 'Content-Type: application/json' \
        -d "{
            \"name\": \"${NIM_MODEL_NAME}\",
            \"namespace\": \"${NIM_NAMESPACE}\",
            \"model_id\": \"${NIM_MODEL}\",
            \"description\": \"${NIM_MODEL_NAME} registered by Interlude launcher\"
        }" 2>&1)
    
    model_status=$(echo "$model_response" | tail -n1)
    model_body=$(echo "$model_response" | sed '$d')
    
    if [ -n "$model_status" ] && [ "$model_status" -ge 200 ] && [ "$model_status" -lt 300 ]; then
        echo "   ✓ Model registered: ${NIM_MODEL_NAME}"
    elif [ "$model_status" = "409" ] || echo "$model_body" | grep -qi "already exists"; then
        echo "   ✓ Model already exists (409)"
    else
        echo "   ⚠️ Failed to register model (HTTP $model_status): $model_body"
        echo "   Continuing anyway - model may already exist..."
    fi
fi

# ═══════════════════════════════════════════════════════════════
# STEP 2: Create Deployment Config
# ═══════════════════════════════════════════════════════════════
echo ""
echo "⚙️  Step 2: Creating deployment config..."

# Wait for Deployment Management service
echo "   Waiting for Deployment Management service..."
for i in $(seq 1 $((WAIT_TIMEOUT / 5))); do
    if curl -sf "${DEPLOYMENT_URL}/v1/deployment/configs" -o /dev/null 2>&1; then
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

# Check if config already exists
existing_config=$(curl -sf "${DEPLOYMENT_URL}/v1/deployment/configs?namespace=${NIM_NAMESPACE}&name=${NIM_CONFIG}" 2>/dev/null || echo '{"configs":[]}')
if echo "$existing_config" | grep -q "\"name\":\"${NIM_CONFIG}\""; then
    echo "   ✓ Deployment config '${NIM_CONFIG}' already exists"
else
    # Create deployment config
    config_response=$(curl -s -w "\n%{http_code}" -X POST \
        "${DEPLOYMENT_URL}/v1/deployment/configs" \
        -H 'Content-Type: application/json' \
        -d "{
            \"name\": \"${NIM_CONFIG}\",
            \"namespace\": \"${NIM_NAMESPACE}\",
            \"model\": \"${NIM_MODEL}\",
            \"nim_deployment\": {
                \"image_name\": \"${NIM_IMAGE}\",
                \"image_tag\": \"${NIM_IMAGE_TAG}\",
                \"gpu\": ${NIM_GPU},
                \"pvc_size\": \"25Gi\",
                \"additional_envs\": {
                    \"NIM_GUIDED_DECODING_BACKEND\": \"fast_outlines\"
                }
            }
        }" 2>&1)
    
    config_status=$(echo "$config_response" | tail -n1)
    config_body=$(echo "$config_response" | sed '$d')
    
    if [ -n "$config_status" ] && [ "$config_status" -ge 200 ] && [ "$config_status" -lt 300 ]; then
        echo "   ✓ Deployment config created: ${NIM_CONFIG}"
    elif [ "$config_status" = "409" ] || echo "$config_body" | grep -qi "already exists"; then
        echo "   ✓ Deployment config already exists (409)"
    else
        echo "   ⚠️ Failed to create deployment config (HTTP $config_status): $config_body"
        echo "   Continuing anyway - config may already exist..."
    fi
fi

# ═══════════════════════════════════════════════════════════════
# STEP 3: Create Model Deployment
# ═══════════════════════════════════════════════════════════════
echo ""
echo "🚀 Step 3: Creating model deployment..."

# Check if deployment already exists
existing_deployment=$(curl -sf "${DEPLOYMENT_URL}/v1/deployment/model-deployments?namespace=${NIM_NAMESPACE}&name=${NIM_NAME}" 2>/dev/null || echo '{"deployments":[]}')
if echo "$existing_deployment" | grep -q "\"name\":\"${NIM_NAME}\""; then
    echo "   ✓ NIM deployment '${NIM_NAME}' already exists"
    exit 0
fi

# Create the deployment
deploy_response=$(curl -s -w "\n%{http_code}" -X POST \
    "${DEPLOYMENT_URL}/v1/deployment/model-deployments" \
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
    }" 2>&1)

deploy_status=$(echo "$deploy_response" | tail -n1)
deploy_body=$(echo "$deploy_response" | sed '$d')

echo "   HTTP Status: $deploy_status"

# Check for success
if [ -n "$deploy_status" ] && [ "$deploy_status" -ge 200 ] && [ "$deploy_status" -lt 300 ]; then
    echo "   ✓ NIM deployment created: ${NIM_NAME}"
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ NIM deployment initiated successfully!"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "   Model:  ${NIM_MODEL}"
    echo "   Name:   ${NIM_NAME}"
    echo "   Config: ${NIM_CONFIG}"
    echo ""
    echo "   ⏳ NIM deployment takes 5-15 minutes to pull the image and start."
    echo "   Check status at: /studio → Models"
    echo ""
elif [ "$deploy_status" = "409" ] || echo "$deploy_body" | grep -qi "already exists"; then
    echo "   ✓ NIM deployment already exists"
else
    echo "   ⚠️ Failed to create NIM deployment (HTTP $deploy_status)"
    echo "   Response: $deploy_body"
    echo ""
    echo "   Possible causes:"
    echo "   - NGC_API_KEY not set or invalid"
    echo "   - Model '${NIM_MODEL}' not available"
    echo "   - Insufficient GPU resources"
    echo ""
    echo "   You can deploy a NIM manually via Studio (/studio) later"
    exit 0
fi
