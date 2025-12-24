#!/bin/bash
# Configure nginx reverse proxy after successful NeMo deployment
# Routes: Path-based routing to K8s services, /interlude → Flask SPA
set -e

NAMESPACE="${NAMESPACE:-nemo}"
NGINX_CONF="${NGINX_CONF:-/app/nginx.conf}"
LAUNCHER_PATH="${LAUNCHER_PATH:-/interlude}"
FLASK_BACKEND="${FLASK_BACKEND:-127.0.0.1:8080}"
HTTP_PORT="${HTTP_PORT:-8888}"
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

# Find services (try common naming patterns)
NIM_BACKEND=$(get_svc_endpoint "nemo-nim-proxy" "8000")
[ -z "$NIM_BACKEND" ] && NIM_BACKEND=$(get_svc_endpoint "nim-proxy" "8000")
[ -z "$NIM_BACKEND" ] && NIM_BACKEND=$(get_svc_endpoint "nemo-microservices-helm-chart-nim-proxy" "8000")

DATA_BACKEND=$(get_svc_endpoint "nemo-data-store" "8000")
[ -z "$DATA_BACKEND" ] && DATA_BACKEND=$(get_svc_endpoint "data-store" "8000")
[ -z "$DATA_BACKEND" ] && DATA_BACKEND=$(get_svc_endpoint "nemo-microservices-helm-chart-data-store" "8000")

NEMO_BACKEND=$(get_svc_endpoint "nemo-entity-store" "8000")
[ -z "$NEMO_BACKEND" ] && NEMO_BACKEND=$(get_svc_endpoint "entity-store" "8000")
[ -z "$NEMO_BACKEND" ] && NEMO_BACKEND=$(get_svc_endpoint "nemo-microservices-helm-chart-entity-store" "8000")

STUDIO_BACKEND=$(get_svc_endpoint "nemo-studio" "3000")
[ -z "$STUDIO_BACKEND" ] && STUDIO_BACKEND=$(get_svc_endpoint "studio" "3000")
[ -z "$STUDIO_BACKEND" ] && STUDIO_BACKEND=$(get_svc_endpoint "nemo-microservices-helm-chart-studio" "3000")

# Fallback to ingress if services not found directly
INGRESS_BACKEND="127.0.0.1:80"
if kubectl get daemonset -n ingress nginx-ingress-microk8s-controller &>/dev/null; then
    INGRESS_BACKEND="127.0.0.1:80"
elif kubectl get svc -n ingress-nginx ingress-nginx-controller &>/dev/null; then
    INGRESS_BACKEND=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}'):80
fi

# Use ingress as fallback for any missing backends
[ -z "$NIM_BACKEND" ] && NIM_BACKEND="$INGRESS_BACKEND"
[ -z "$DATA_BACKEND" ] && DATA_BACKEND="$INGRESS_BACKEND"
[ -z "$NEMO_BACKEND" ] && NEMO_BACKEND="$INGRESS_BACKEND"
[ -z "$STUDIO_BACKEND" ] && STUDIO_BACKEND="$INGRESS_BACKEND"

echo "   NIM Proxy:   $NIM_BACKEND (completions, chat, embeddings, classify)"
echo "   Data Store:  $DATA_BACKEND (/v1/hf/*)"
echo "   Entity Store: $NEMO_BACKEND (/v1/* other)"
echo "   Studio:      $STUDIO_BACKEND (/studio/*)"
echo "   Ingress:     $INGRESS_BACKEND (fallback)"

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
    
    # NeMo service backends
    upstream nim_backend {
        server $NIM_BACKEND;
    }
    
    upstream data_backend {
        server $DATA_BACKEND;
    }
    
    upstream nemo_backend {
        server $NEMO_BACKEND;
    }
    
    upstream studio_backend {
        server $STUDIO_BACKEND;
    }
    
    upstream ingress_backend {
        server $INGRESS_BACKEND;
    }
    
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
        # PATH-BASED ROUTING (Single-origin mode - no CORS needed!)
        # ═══════════════════════════════════════════════════════════════
        
        # NIM Proxy: LLM inference endpoints
        location ~ ^/v1/(completions|chat|embeddings|classify|ranking) {
            proxy_pass http://nim_backend;
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
        
        # Data Store: HuggingFace-compatible file/dataset API
        location ~ ^/v1/hf {
            proxy_pass http://data_backend;
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
        
        # Entity Store / NeMo Platform: All other /v1/* APIs
        location ~ ^/v1/ {
            proxy_pass http://nemo_backend;
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
        
        # NeMo Studio frontend
        location /studio {
            proxy_pass http://studio_backend;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_buffering off;
        }
        
        # Fallback: Everything else goes to ingress (handles /assets, etc.)
        location / {
            proxy_pass http://ingress_backend;
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
echo "   Routes (all same origin - no CORS!):"
echo "   /v1/completions,chat,embeddings,classify → NIM Proxy ($NIM_BACKEND)"
echo "   /v1/hf/*                                 → Data Store ($DATA_BACKEND)"
echo "   /v1/*                                    → Entity Store ($NEMO_BACKEND)"
echo "   /studio/*                                → NeMo Studio ($STUDIO_BACKEND)"
echo "   $LAUNCHER_PATH/*                         → Interlude UI ($FLASK_BACKEND)"
echo "   /*                                       → Ingress fallback ($INGRESS_BACKEND)"
echo ""
echo "━━━ configure-proxy.sh complete ━━━"
