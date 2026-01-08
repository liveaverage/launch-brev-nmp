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
# Service named 'jupyter-svc' to avoid K8s JUPYTER_PORT env var collision
JUPYTER=$(kubectl get svc -n jupyter jupyter-svc -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)
[ -n "$JUPYTER" ] && JUPYTER="${JUPYTER}:8888"

# Fallback for missing services - use a dummy backend that will return 502
# This prevents nginx config errors from empty server directives
DUMMY_BACKEND="127.0.0.1:1"  # Will fail immediately (nothing listens on port 1)

# Set fallbacks and warn for critical missing services
[ -z "$NIM_PROXY" ] && NIM_PROXY="$DUMMY_BACKEND" && echo "   ⚠️ NIM Proxy not found"
[ -z "$DATA_STORE" ] && DATA_STORE="$DUMMY_BACKEND" && echo "   ⚠️ Data Store not found - dataset uploads will fail"
[ -z "$ENTITY_STORE" ] && ENTITY_STORE="$DUMMY_BACKEND" && echo "   ⚠️ Entity Store not found"
[ -z "$CUSTOMIZER" ] && CUSTOMIZER="$DUMMY_BACKEND" && echo "   ⚠️ Customizer not found"
[ -z "$EVALUATOR" ] && EVALUATOR="$DUMMY_BACKEND" && echo "   ⚠️ Evaluator not found"
[ -z "$GUARDRAILS" ] && GUARDRAILS="$DUMMY_BACKEND" && echo "   ⚠️ Guardrails not found"
[ -z "$DEPLOYMENT_MGMT" ] && DEPLOYMENT_MGMT="$DUMMY_BACKEND" && echo "   ⚠️ Deployment Management not found"
[ -z "$DATA_DESIGNER" ] && DATA_DESIGNER="$DUMMY_BACKEND" && echo "   ⚠️ Data Designer not found"
[ -z "$AUDITOR" ] && AUDITOR="$DUMMY_BACKEND" && echo "   ⚠️ Auditor not found"
[ -z "$SAFE_SYNTHESIZER" ] && SAFE_SYNTHESIZER="$DUMMY_BACKEND" && echo "   ⚠️ Safe Synthesizer not found"
[ -z "$CORE_API" ] && CORE_API="$DUMMY_BACKEND" && echo "   ⚠️ Core API not found"
[ -z "$INTAKE" ] && INTAKE="$DUMMY_BACKEND" && echo "   ⚠️ Intake not found"
[ -z "$STUDIO" ] && STUDIO="$DUMMY_BACKEND" && echo "   ⚠️ Studio not found - /studio will return 502"

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
echo ""
echo "   Fallback (/*):   Data Store (per NVIDIA docs)"

echo "🔧 Writing nginx.conf (post-deployment mode with path-based routing)..."

cat > "$NGINX_CONF" << NGINX
# NeMo Reverse Proxy - POST-DEPLOYMENT MODE (Single-Origin Path Routing)
# After deployment, Flask SPA moves to /interlude only. Root goes to Data Store.
#
# Routes:
#   $LAUNCHER_PATH/*                    → Flask SPA (deployment UI)
#   /studio/*                           → NeMo Studio
#   /jupyter/*                          → Jupyter (optional)
#   /v1/completions, /v1/chat, etc.     → NIM Proxy
#   /v1/hf/*                            → Data Store
#   /v1/*                               → Entity Store (NeMo Platform)
#   /*                                  → Data Store (fallback for Git LFS, etc.)
#
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
    
    # Conditional Connection header for WebSocket vs regular HTTP
    # - WebSocket requests (Upgrade header present): Connection = "upgrade"
    # - Regular HTTP requests: Connection = "" (enables keep-alive, fixes cloudflared EOF)
    map \$http_upgrade \$connection_upgrade {
        default "";
        websocket "upgrade";
    }
    
    # Flask SPA backend (deployment UI)
    upstream flask_backend {
        server $FLASK_BACKEND;
    }
    
    # NeMo service backends (per NVIDIA ingress-setup.html documentation)
    
    # NIM Proxy host services
    upstream nim_proxy { server $NIM_PROXY; }
    
    # Data Store host services (with keepalive for connection reuse)
    upstream data_store {
        server $DATA_STORE;
        keepalive 32;
        keepalive_requests 1000;
        keepalive_timeout 60s;
    }
    
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
        
        # Disable gzip for sub_filter to work on HTML
        proxy_set_header Accept-Encoding "";
        
        # Rewrite internal NeMo hostnames to relative paths (HTML only, safe)
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
        
        # Inject VITE environment variables for NeMo Studio (HTML only)
        # ALL URLs point to SAME ORIGIN to avoid CORS entirely
        # This works because nginx does path-based routing to the right backend
        sub_filter '</head>' '<script>(function(){var b=window.location.origin;window.VITE_PLATFORM_BASE_URL=b;window.VITE_ENTITY_STORE_MICROSERVICE_URL=b;window.VITE_NIM_PROXY_URL=b;window.VITE_DATA_STORE_URL=b;window.VITE_BASE_URL=b;console.log("[Interlude] Single-origin mode:",b);})();</script></head>';
        
        # Fix Location headers from upstream (http->https)
        proxy_redirect http://\$host/ https://\$host/;
        proxy_redirect http://\$host:\$server_port/ https://\$host/;
        
        sub_filter_once off;
        sub_filter_types text/html;
        
        # ─── Deployment UI (Flask SPA) ───
        # POST-DEPLOYMENT: Flask SPA only at $LAUNCHER_PATH
        # Root (/) now goes to Data Store for Git LFS operations
        
        # Flask SPA at $LAUNCHER_PATH
        location $LAUNCHER_PATH {
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
        # HuggingFace API - LFS batch endpoint returns JSON with http:// URLs
        # Must rewrite these to https:// to avoid mixed content errors
        # BUFFERING ENABLED: Prevents "unexpected EOF" errors with cloudflared
        location ~ ^/v1/hf {
            proxy_pass http://data_store;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Accept-Encoding "";
            proxy_set_header Connection "";
            proxy_connect_timeout 60s;
            proxy_send_timeout 300s;
            proxy_read_timeout 300s;
            
            # Retry on connection errors (helps with flaky Data Store)
            proxy_next_upstream error timeout http_502 http_503;
            proxy_next_upstream_tries 3;
            proxy_next_upstream_timeout 30s;
            
            # Enable buffering to prevent cloudflared "unexpected EOF" on slow responses
            proxy_buffering on;
            proxy_buffer_size 128k;
            proxy_buffers 8 256k;
            proxy_busy_buffers_size 512k;
            proxy_temp_file_write_size 512k;
            
            # Rewrite http:// to https:// in JSON responses (LFS batch returns upload URLs)
            sub_filter '"http://' '"https://';
            sub_filter_once off;
            sub_filter_types application/json application/vnd.git-lfs+json;
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
            proxy_set_header Connection \$connection_upgrade;
            proxy_buffering off;
        }
NGINX

# Conditionally add Jupyter location if deployed
if [ -n "$JUPYTER" ]; then
    cat >> "$NGINX_CONF" << 'JUPYTERNGINX'
        
        # Jupyter: /jupyter/* (configured with base_url=/jupyter via NOTEBOOK_ARGS)
        # No rewriting needed - Jupyter serves directly at /jupyter/*
        location /jupyter/ {
            proxy_pass http://jupyter;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            # WebSocket support for Jupyter kernels/terminals (conditional)
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_connect_timeout 60s;
            proxy_send_timeout 86400s;
            proxy_read_timeout 86400s;
            proxy_buffering off;
        }
        
        # Redirect /jupyter to /jupyter/lab for convenience
        location = /jupyter {
            return 301 /jupyter/lab;
        }
JUPYTERNGINX
fi

cat >> "$NGINX_CONF" << NGINX
        
        # ─── Fallback: Data Store (per NVIDIA docs, dataStore gets root path) ───
        # This catches Git LFS operations, HuggingFace API, and any other Data Store paths
        # Data Store returns http:// URLs - rewrite to https:// for browser compatibility
        location / {
            proxy_pass http://data_store;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Accept-Encoding "";
            # Conditional WebSocket support: "upgrade" only when Upgrade header present
            # Empty string for regular HTTP (fixes cloudflared "unexpected EOF")
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection \$connection_upgrade;
            proxy_connect_timeout 60s;
            proxy_send_timeout 600s;
            proxy_read_timeout 600s;
            
            # Retry on connection errors (helps with flaky Data Store)
            proxy_next_upstream error timeout http_502 http_503;
            proxy_next_upstream_tries 3;
            proxy_next_upstream_timeout 30s;
            
            # Enable BOTH request and response buffering for cloudflared
            proxy_request_buffering on;
            proxy_buffering on;
            proxy_buffer_size 128k;
            proxy_buffers 8 256k;
            proxy_busy_buffers_size 512k;
            proxy_temp_file_write_size 512k;
            
            # Rewrite http:// to https:// in Location headers (Git LFS redirects)
            proxy_redirect http://\$host/ https://\$host/;
            proxy_redirect http://\$host:\$server_port/ https://\$host/;
            
            # Rewrite http:// to https:// in JSON responses (LFS batch returns upload URLs)
            sub_filter '"http://' '"https://';
            sub_filter_once off;
            sub_filter_types application/json application/vnd.git-lfs+json;
        }
    }
}
NGINX

echo "🔄 Reloading nginx..."
# Test config first
if nginx -t -c "$NGINX_CONF" 2>&1; then
    echo "   ✓ nginx config valid"
    # Try multiple methods to reload nginx
    RELOADED=false
    
    # Method 1: Use pid file
    if [ -f /tmp/nginx.pid ] && [ -s /tmp/nginx.pid ]; then
        NGINX_PID=$(cat /tmp/nginx.pid)
        if kill -0 "$NGINX_PID" 2>/dev/null; then
            kill -HUP "$NGINX_PID" && RELOADED=true && echo "   ✓ nginx reloaded (HUP to PID $NGINX_PID)"
        fi
    fi
    
    # Method 2: Find nginx master process
    if [ "$RELOADED" = "false" ]; then
        NGINX_PID=$(pgrep -o nginx 2>/dev/null || true)
        if [ -n "$NGINX_PID" ]; then
            kill -HUP "$NGINX_PID" && RELOADED=true && echo "   ✓ nginx reloaded (HUP to pgrep PID $NGINX_PID)"
        fi
    fi
    
    # Method 3: nginx -s reload
    if [ "$RELOADED" = "false" ] && pgrep nginx > /dev/null; then
        nginx -s reload -c "$NGINX_CONF" 2>/dev/null && RELOADED=true && echo "   ✓ nginx reloaded (nginx -s reload)"
    fi
    
    if [ "$RELOADED" = "false" ]; then
        echo "   ⚠️ nginx not running or reload failed, config ready for next start"
    fi
else
    echo "   ❌ nginx config invalid!"
    nginx -t -c "$NGINX_CONF"
fi

echo ""
echo "✅ Reverse proxy configured (POST-DEPLOYMENT mode)"
echo ""
echo "   Routing:"
echo "   ├─ $LAUNCHER_PATH/*  → Flask SPA (deployment status)"
echo "   ├─ /studio/*         → NeMo Studio"
echo "   ├─ /jupyter/*        → Jupyter (if deployed)"
echo "   ├─ /v1/*, /v2/*      → NeMo API services"
echo "   └─ /*                → Data Store (Git LFS, fallback)"
echo ""
echo "   All routes same origin - no CORS needed!"
echo ""
echo "━━━ configure-proxy.sh complete ━━━"
