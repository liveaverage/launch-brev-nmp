#!/bin/bash
# Configure nginx reverse proxy after successful NeMo deployment
# Routes: / → K8s ingress (NeMo), /interlude → Flask SPA (history/status)
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
echo "🔍 Discovering K8s backend..."

# Allow manual override
if [ -n "$BACKEND" ]; then
    echo "   Using provided BACKEND=$BACKEND"
else
    # Auto-detect backend
    if kubectl get daemonset -n ingress nginx-ingress-microk8s-controller &>/dev/null; then
        BACKEND="127.0.0.1:80"
        echo "   Detected: microk8s ingress (127.0.0.1:80)"
    elif kubectl get svc -n ingress-nginx ingress-nginx-controller &>/dev/null; then
        BACKEND=$(kubectl get svc -n ingress-nginx ingress-nginx-controller -o jsonpath='{.spec.clusterIP}'):80
        echo "   Detected: nginx-ingress controller ($BACKEND)"
    else
        # Fallback - try to find the nemo-studio service
        STUDIO_IP=$(kubectl get svc -n "$NAMESPACE" -l app=nemo-studio -o jsonpath='{.items[0].spec.clusterIP}' 2>/dev/null || true)
        if [ -n "$STUDIO_IP" ] && [ "$STUDIO_IP" != "None" ]; then
            BACKEND="$STUDIO_IP:3000"
            echo "   Detected: nemo-studio service ($BACKEND)"
        else
            BACKEND="127.0.0.1:80"
            echo "⚠️  Could not auto-detect, using $BACKEND"
        fi
    fi
fi

echo "🔧 Writing nginx.conf (post-deployment mode)..."

cat > "$NGINX_CONF" << NGINX
# NeMo Reverse Proxy - POST-DEPLOYMENT MODE
# Routes:
#   $LAUNCHER_PATH/* → Flask SPA (deployment history/status)
#   /*               → K8s NeMo services (with URL rewriting)
# Backend: $BACKEND
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
    
    # Flask SPA backend (deployment UI)
    upstream flask_backend {
        server $FLASK_BACKEND;
    }
    
    # K8s NeMo backend
    upstream nemo_backend {
        server $BACKEND;
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
        # Computes base URL from browser location for Cloudflare tunnel compatibility
        sub_filter '</head>' '<script>(function(){var b=window.location.origin;window.VITE_PLATFORM_BASE_URL=b;window.VITE_ENTITY_STORE_MICROSERVICE_URL=b+"/v1";window.VITE_NIM_PROXY_URL=b;window.VITE_DATA_STORE_URL=b+"/v1";window.VITE_BASE_URL=b;console.log("[Interlude] Injected VITE vars:",b);})();</script></head>';
        
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
        
        # Everything else goes to NeMo
        location / {
            # CORS headers for cross-origin requests between studio/nim/data hostnames
            if (\$request_method = 'OPTIONS') {
                add_header 'Access-Control-Allow-Origin' '*' always;
                add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, PATCH, OPTIONS' always;
                add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization,X-Auth-Token' always;
                add_header 'Access-Control-Max-Age' 1728000;
                add_header 'Content-Type' 'text/plain; charset=utf-8';
                add_header 'Content-Length' 0;
                return 204;
            }
            
            add_header 'Access-Control-Allow-Origin' '*' always;
            add_header 'Access-Control-Allow-Methods' 'GET, POST, PUT, DELETE, PATCH, OPTIONS' always;
            add_header 'Access-Control-Allow-Headers' 'DNT,User-Agent,X-Requested-With,If-Modified-Since,Cache-Control,Content-Type,Range,Authorization,X-Auth-Token' always;
            add_header 'Access-Control-Expose-Headers' 'Content-Length,Content-Range' always;
            
            proxy_pass http://nemo_backend;
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
echo "✅ Reverse proxy configured (post-deployment mode)"
echo "   http://localhost:$HTTP_PORT/              → NeMo Studio ($BACKEND)"
echo "   http://localhost:$HTTP_PORT$LAUNCHER_PATH → Deployment UI ($FLASK_BACKEND)"
echo ""
echo "━━━ configure-proxy.sh complete ━━━"
