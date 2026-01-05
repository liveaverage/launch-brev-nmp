#!/bin/bash
# Configure nginx reverse proxy after successful NeMo deployment
# Routes: Path-based routing to K8s services, /interlude → Flask SPA
set -e

NAMESPACE="${NAMESPACE:-nemo}"
NGINX_CONF="${NGINX_CONF:-/app/nginx.conf}"
LAUNCHER_PATH="${LAUNCHER_PATH:-/interlude}"
FLASK_BACKEND="${FLASK_BACKEND:-127.0.0.1:8080}"
HTTP_PORT="${HTTP_PORT:-9090}"
HTTPS_PORT="${HTTPS_PORT:-8443}"

echo "━━━ configure-proxy.sh starting ━━━"
echo "   NGINX_CONF=$NGINX_CONF"
echo "   HTTP_PORT=$HTTP_PORT"
echo "   LAUNCHER_PATH=$LAUNCHER_PATH"
echo ""
echo "🔍 Discovering K8s services for path-based routing..."

# Discover NeMo service endpoints
get_svc_endpoint() {
    local name="$1"
    local port="$2"
    local ip=$(kubectl get svc -n "$NAMESPACE" "$name" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
    if [ -n "$ip" ] && [ "$ip" != "None" ]; then
        echo "$ip:$port"
    fi
}

# Service discovery based on NVIDIA documentation:
# https://docs.nvidia.com/nemo/microservices/latest/set-up/deploy-as-platform/ingress-setup.html

# NIM Proxy (nim.test) - LLM inference: /v1/completions, /v1/chat, /v1/embeddings, /v1/models
NIM_PROXY=$(get_svc_endpoint "nemo-nim-proxy" "8000")

# Data Store (datastore.test) - HuggingFace API: /v1/hf/*
DATA_STORE=$(get_svc_endpoint "nemo-data-store" "3000")

# Default host services (nemo.test) - all documented paths:
ENTITY_STORE=$(get_svc_endpoint "nemo-entity-store" "8000")
CUSTOMIZER=$(get_svc_endpoint "nemo-customizer" "8000")
EVALUATOR=$(get_svc_endpoint "nemo-evaluator" "7331")
GUARDRAILS=$(get_svc_endpoint "nemo-guardrails" "7331")
DEPLOYMENT_MGMT=$(get_svc_endpoint "nemo-deployment-management" "8000")
DATA_DESIGNER=$(get_svc_endpoint "nemo-data-designer" "8000")
AUDITOR=$(get_svc_endpoint "nemo-auditor" "5000")
SAFE_SYNTHESIZER=$(get_svc_endpoint "nemo-safe-synthesizer" "8000")
CORE_API=$(get_svc_endpoint "nemo-core-api" "8000")
INTAKE=$(get_svc_endpoint "nemo-intake" "8000")
STUDIO=$(get_svc_endpoint "nemo-studio" "3000")

# Jupyter (optional - in separate namespace)
JUPYTER=$(kubectl get svc -n jupyter jupyter -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
[ -n "$JUPYTER" ] && JUPYTER="${JUPYTER}:8888"

# Fallback to ingress if services not found directly
INGRESS_BACKEND="127.0.0.1:80"
if kubectl get daemonset -n ingress nginx-ingress-microk8s-controller &>/dev/null; then
    INGRESS_BACKEND="127.0.0.1:80"
elif kubectl get svc -n ingress-nginx ingress-nginx-controller &>/dev/null; then
    INGRESS_BACKEND=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}'):80
fi

# Use ingress as fallback for any missing backends
[ -z "$NIM_PROXY" ] && NIM_PROXY="$INGRESS_BACKEND"
[ -z "$DATA_STORE" ] && DATA_STORE="$INGRESS_BACKEND"
[ -z "$ENTITY_STORE" ] && ENTITY_STORE="$INGRESS_BACKEND"
[ -z "$CUSTOMIZER" ] && CUSTOMIZER="$INGRESS_BACKEND"
[ -z "$EVALUATOR" ] && EVALUATOR="$INGRESS_BACKEND"
[ -z "$GUARDRAILS" ] && GUARDRAILS="$INGRESS_BACKEND"
[ -z "$DEPLOYMENT_MGMT" ] && DEPLOYMENT_MGMT="$INGRESS_BACKEND"
[ -z "$DATA_DESIGNER" ] && DATA_DESIGNER="$INGRESS_BACKEND"
[ -z "$AUDITOR" ] && AUDITOR="$INGRESS_BACKEND"
[ -z "$SAFE_SYNTHESIZER" ] && SAFE_SYNTHESIZER="$INGRESS_BACKEND"
[ -z "$CORE_API" ] && CORE_API="$INGRESS_BACKEND"
[ -z "$INTAKE" ] && INTAKE="$INGRESS_BACKEND"
[ -z "$STUDIO" ] && STUDIO="$INGRESS_BACKEND"

echo ""
echo "   Discovered services (per NVIDIA docs):"
echo "   ─────────────────────────────────────────"
echo "   NIM Proxy:       $NIM_PROXY"
echo "   Data Store:      $DATA_STORE"
echo "   Entity Store:    $ENTITY_STORE"
echo "   Customizer:      $CUSTOMIZER"
echo "   Evaluator:       $EVALUATOR"
echo "   Guardrails:      $GUARDRAILS"
echo "   Deployment Mgmt: $DEPLOYMENT_MGMT"
echo "   Data Designer:   $DATA_DESIGNER"
echo "   Auditor:         $AUDITOR"
echo "   Safe Synthesizer:$SAFE_SYNTHESIZER"
echo "   Core API:        $CORE_API"
echo "   Intake:          $INTAKE"
echo "   Studio:          $STUDIO"
echo "   Jupyter:         ${JUPYTER:-not deployed}"
echo "   Ingress:         $INGRESS_BACKEND (fallback)"

echo "🔧 Writing nginx.conf (post-deployment mode with path-based routing)..."

cat > "$NGINX_CONF" << NGINX
# NeMo Reverse Proxy - POST-DEPLOYMENT MODE (Single-Origin Path Routing)
# Routes:
#   $LAUNCHER_PATH/*                    → Flask SPA (deployment history/status)
#   /v1/completions, /v1/chat, etc.     → NIM Proxy
#   /v1/hf/*                            → Data Store
#   /v1/*                               → Entity Store (NeMo Platform)
#   /studio/*                           → NeMo Studio
#   /*                                  → Fallback to ingress
# Generated: $(date -Iseconds)

worker_processes auto;
error_log /dev/stderr warn;
pid /tmp/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;
    sendfile on;
    keepalive_timeout 65;
    client_max_body_size 50g;
    
    # Flask SPA backend (deployment UI)
    upstream flask_backend {
        server $FLASK_BACKEND;
    }
    
    # NeMo service backends (per NVIDIA ingress-setup.html documentation)
    
    # NIM Proxy host services
    upstream nim_proxy { server $NIM_PROXY; }
    
    # Data Store host services  
    upstream data_store { server $DATA_STORE; }
    
    # Default host services
    upstream entity_store { server $ENTITY_STORE; }
    upstream customizer { server $CUSTOMIZER; }
    upstream evaluator { server $EVALUATOR; }
    upstream guardrails { server $GUARDRAILS; }
    upstream deployment_mgmt { server $DEPLOYMENT_MGMT; }
    upstream data_designer { server $DATA_DESIGNER; }
    upstream auditor { server $AUDITOR; }
    upstream safe_synthesizer { server $SAFE_SYNTHESIZER; }
    upstream core_api { server $CORE_API; }
    upstream intake { server $INTAKE; }
    upstream studio { server $STUDIO; }
    
    upstream ingress_fallback { server $INGRESS_BACKEND; }
    
    # Jupyter (optional - deployed separately)
NGINX

# Conditionally add Jupyter upstream if deployed
if [ -n "$JUPYTER" ]; then
    cat >> "$NGINX_CONF" << NGINX
    upstream jupyter { server $JUPYTER; }
NGINX
fi

cat >> "$NGINX_CONF" << NGINX
    
    server {
        listen $HTTP_PORT;
        listen $HTTPS_PORT ssl;
        server_name _;
        
        ssl_certificate /app/certs/server.crt;
        ssl_certificate_key /app/certs/server.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        
        # Disable gzip for sub_filter
        proxy_set_header Accept-Encoding "";
        
        # URL rewriting for NeMo - convert internal hostnames to relative paths
        sub_filter 'http://nemo.test:3000' '';
        sub_filter 'http://nim.test:3000' '';
        sub_filter 'http://data-store.test:3000' '';
        sub_filter 'http://entity-store.test:3000' '';
        sub_filter 'http://nemo-platform.test:3000' '';
        sub_filter 'https://nemo.test:3000' '';
        sub_filter 'https://nim.test:3000' '';
        sub_filter 'https://data-store.test:3000' '';
        sub_filter 'https://entity-store.test:3000' '';
        sub_filter 'https://nemo-platform.test:3000' '';
        
        # Inject VITE environment variables for NeMo Studio
        # ALL URLs point to SAME ORIGIN to avoid CORS entirely
        # This works because nginx does path-based routing to the right backend
        sub_filter '</head>' '<script>(function(){var b=window.location.origin;window.VITE_PLATFORM_BASE_URL=b;window.VITE_ENTITY_STORE_MICROSERVICE_URL=b;window.VITE_NIM_PROXY_URL=b;window.VITE_DATA_STORE_URL=b;window.VITE_BASE_URL=b;console.log("[Interlude] Single-origin mode:",b);})();</script></head>';
        
        sub_filter_once off;
        sub_filter_types text/html text/javascript application/javascript application/json text/plain *;
        
        # Deployment UI at $LAUNCHER_PATH
        location $LAUNCHER_PATH {
            # Rewrite to remove the prefix for Flask
            rewrite ^$LAUNCHER_PATH(.*)\$ /\$1 break;
            proxy_pass http://flask_backend;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Script-Name $LAUNCHER_PATH;
        }
        
        # Flask API endpoints under $LAUNCHER_PATH
        location ~ ^$LAUNCHER_PATH/(config|help|deploy|state|uninstall|assets) {
            rewrite ^$LAUNCHER_PATH(.*)\$ \$1 break;
            proxy_pass http://flask_backend;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header X-Script-Name $LAUNCHER_PATH;
            # SSE support
            proxy_buffering off;
            proxy_cache off;
            proxy_read_timeout 86400s;
        }
        
        # ═══════════════════════════════════════════════════════════════
        # PATH-BASED ROUTING per NVIDIA ingress-setup.html documentation
        # https://docs.nvidia.com/nemo/microservices/latest/set-up/deploy-as-platform/ingress-setup.html
        # Single-origin mode - no CORS needed!
        # ═══════════════════════════════════════════════════════════════
        
        # ─── NIM Proxy routes (nim.test equivalent) ───
        location ~ ^/v1/(completions|chat|embeddings) {
            proxy_pass http://nim_proxy;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_send_timeout 600s;
            proxy_read_timeout 600s;
            proxy_buffering off;
        }
        
        # ─── Data Store routes (datastore.test equivalent) ───
        location ~ ^/v1/hf {
            proxy_pass http://data_store;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
        
        # ─── Default host routes (nemo.test equivalent) ───
        
        # Entity Store: /v1/namespaces, /v1/projects, /v1/datasets, /v1/repos, /v1/models
        location ~ ^/v1/(namespaces|projects|datasets|repos|models) {
            proxy_pass http://entity_store;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
        
        # Customizer: /v1/customization
        location /v1/customization {
            proxy_pass http://customizer;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
        
        # Evaluator: /v1/evaluation, /v2/evaluation
        location ~ ^/(v1|v2)/evaluation {
            proxy_pass http://evaluator;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
        
        # Guardrails: /v1/guardrail
        location /v1/guardrail {
            proxy_pass http://guardrails;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
        
        # Deployment Management: /v1/deployment
        location /v1/deployment {
            proxy_pass http://deployment_mgmt;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
        
        # Data Designer: /v1/data-designer
        location /v1/data-designer {
            proxy_pass http://data_designer;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
        
        # Auditor: /v1beta1/audit
        location /v1beta1/audit {
            proxy_pass http://auditor;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
        
        # Safe Synthesizer: /v1beta1/safe-synthesizer
        location /v1beta1/safe-synthesizer {
            proxy_pass http://safe_synthesizer;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
        
        # Core API: /v1/jobs, /v2/inference/gateway, /v2/inference, /v2/models
        location ~ ^/v1/jobs {
            proxy_pass http://core_api;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
        
        location ~ ^/v2/(inference|models) {
            proxy_pass http://core_api;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
        
        # Intake: /v1/intake
        location /v1/intake {
            proxy_pass http://intake;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
        
        # Studio: /studio
        location /studio {
            proxy_pass http://studio;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_buffering off;
        }
NGINX

# Conditionally add Jupyter location if deployed
if [ -n "$JUPYTER" ]; then
    cat >> "$NGINX_CONF" << 'JUPYTERNGINX'
        
        # Jupyter: /jupyter (from NVIDIA GenerativeAIExamples)
        # Rewrites /jupyter/* to /* and proxies to Jupyter service
        location /jupyter {
            rewrite ^/jupyter(.*) /$1 break;
            proxy_pass http://jupyter;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            # WebSocket support for Jupyter kernels/terminals
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_connect_timeout 60s;
            proxy_send_timeout 86400s;
            proxy_read_timeout 86400s;
            proxy_buffering off;
        }
JUPYTERNGINX
fi

cat >> "$NGINX_CONF" << NGINX
        
        # Fallback: Everything else goes to ingress
        location / {
            proxy_pass http://ingress_fallback;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            proxy_buffering off;
        }
    }
}
NGINX

echo "🔄 Reloading nginx..."
# Test config first
if nginx -t -c "$NGINX_CONF" 2>&1; then
    echo "   ✓ nginx config valid"
    # Send reload signal to the master process
    if [ -f /tmp/nginx.pid ]; then
        kill -HUP $(cat /tmp/nginx.pid) && echo "   ✓ nginx reloaded (HUP signal)" || echo "   ⚠️ reload failed"
    elif pgrep -x nginx > /dev/null; then
        nginx -s reload -c "$NGINX_CONF" 2>/dev/null && echo "   ✓ nginx reloaded" || echo "   ⚠️ reload failed"
    else
        echo "   nginx not running, config ready for next start"
    fi
else
    echo "   ❌ nginx config invalid!"
fi

echo ""
echo "✅ Reverse proxy configured (single-origin path-based routing)"
echo ""
echo "   All routes same origin - no CORS needed!"
echo ""
echo "━━━ configure-proxy.sh complete ━━━"
