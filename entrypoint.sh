#!/bin/bash
# Entrypoint: nginx (reverse proxy on :80/:443) + Flask (SPA on :8080 internal)
# 
# Routing modes:
#   PRE-DEPLOYMENT:  / → Flask SPA (enter API key, deploy)
#   POST-DEPLOYMENT: / → NeMo, /interlude → Flask SPA (history/status)
set -e

LAUNCHER_PATH="${LAUNCHER_PATH:-/interlude}"
STATE_FILE="${STATE_FILE:-/app/data/deployment.state}"
HTTP_PORT="${HTTP_PORT:-8888}"
HTTPS_PORT="${HTTPS_PORT:-8443}"

# Stop any existing nginx (from package install)
pkill nginx 2>/dev/null || true
sleep 0.5

# Generate self-signed cert for :443
if [ ! -f /app/certs/server.crt ]; then
    mkdir -p /app/certs
    openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
        -keyout /app/certs/server.key \
        -out /app/certs/server.crt \
        -subj "/CN=interlude/O=brev-launch" \
        2>/dev/null
    echo "✓ Generated self-signed certificate"
fi

# Create data directory for state
mkdir -p /app/data

# Check if already deployed (state file exists and deployed=true)
is_deployed() {
    if [ -f "$STATE_FILE" ]; then
        grep -q '"deployed": true' "$STATE_FILE" 2>/dev/null && return 0
    fi
    return 1
}

# Write nginx config based on deployment state
write_nginx_config() {
    local mode="$1"
    
    if [ "$mode" = "pre" ]; then
        echo "📝 Writing nginx config (pre-deployment mode: :$HTTP_PORT → Flask SPA)"
        cat > /app/nginx.conf << NGINX
# PRE-DEPLOYMENT MODE: All traffic goes to Flask SPA
worker_processes auto;
error_log /dev/stderr warn;
pid /tmp/nginx.pid;

events { worker_connections 1024; }

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log /dev/stdout;
    sendfile on;
    keepalive_timeout 65;
    
    upstream flask_backend {
        server 127.0.0.1:8080;
    }
    
    server {
        listen $HTTP_PORT;
        listen $HTTPS_PORT ssl;
        server_name _;
        
        ssl_certificate /app/certs/server.crt;
        ssl_certificate_key /app/certs/server.key;
        ssl_protocols TLSv1.2 TLSv1.3;
        
        # All requests go to Flask
        location / {
            proxy_pass http://flask_backend;
            proxy_http_version 1.1;
            proxy_set_header Host \$host;
            proxy_set_header X-Real-IP \$remote_addr;
            proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto \$scheme;
            # SSE support for streaming logs
            proxy_buffering off;
            proxy_cache off;
            proxy_read_timeout 86400s;
        }
    }
}
NGINX
    else
        echo "📝 nginx config exists for post-deployment mode"
    fi
}

# Determine initial mode
if is_deployed; then
    echo "🔄 Previously deployed - keeping post-deployment routing"
    # nginx.conf should already be configured by configure-proxy.sh
    if [ ! -f /app/nginx.conf ]; then
        echo "⚠️ Missing nginx.conf, writing pre-deployment config"
        write_nginx_config "pre"
    fi
else
    write_nginx_config "pre"
fi

# Test nginx config
echo "🔍 Testing nginx config..."
if ! nginx -t -c /app/nginx.conf 2>&1; then
    echo "❌ nginx config test failed!"
    cat /app/nginx.conf
    exit 1
fi
echo "   ✓ nginx config OK"

# Start Flask FIRST (internal, not exposed directly)
echo "🚀 Starting Flask SPA on :8080 (internal)..."
cd /app
python app.py &
FLASK_PID=$!

# Wait for Flask to be ready
echo "   Waiting for Flask..."
for i in {1..30}; do
    if curl -s http://127.0.0.1:8080/ > /dev/null 2>&1; then
        echo "   ✓ Flask ready"
        break
    fi
    sleep 0.5
done

# Start nginx
echo "🌐 Starting nginx on :$HTTP_PORT/:$HTTPS_PORT..."
nginx -c /app/nginx.conf -g 'daemon off;' &
NGINX_PID=$!

# Banner
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Interlude - NeMo Deployment Launcher                          ║"
echo "╠════════════════════════════════════════════════════════════════╣"
if is_deployed; then
echo "║  Mode: POST-DEPLOYMENT                                         ║"
echo "║  NeMo:       http://localhost:$HTTP_PORT                                ║"
echo "║  Launcher:   http://localhost:$HTTP_PORT$LAUNCHER_PATH                        ║"
else
echo "║  Mode: PRE-DEPLOYMENT (first launch)                           ║"
echo "║  Launcher:   http://localhost:$HTTP_PORT  (https://:$HTTPS_PORT)              ║"
fi
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Handle shutdown
cleanup() {
    echo "Shutting down..."
    kill $NGINX_PID $FLASK_PID 2>/dev/null
    exit 0
}
trap cleanup EXIT SIGTERM SIGINT

# Wait for either to exit
wait -n $NGINX_PID $FLASK_PID
