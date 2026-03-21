#!/bin/bash
# ═══════════════════════════════════════════════════════════════
# ClawPress Bridge — One-Command Installer
# Run after: openclaw configure
#
# curl -fsSL https://raw.githubusercontent.com/emrahsinekli/clawpress-bridge/master/setup.sh | bash
# ═══════════════════════════════════════════════════════════════
set -e

log()  { echo -e "\033[0;32m✓\033[0m $1"; }
warn() { echo -e "\033[1;33m⚠\033[0m $1"; }
err()  { echo -e "\033[0;31m✗\033[0m $1"; exit 1; }
info() { echo -e "\033[0;36m→\033[0m $1"; }

echo ""
echo "========================================"
echo "  ClawPress Bridge Installer"
echo "========================================"
echo ""

# --- Checks ---
[ "$(uname -s)" = "Linux" ] || err "Linux only."
[ "$(id -u)" -eq 0 ] || err "Run as root."
command -v node &>/dev/null || err "Node.js not found. Install: curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs"
command -v openclaw &>/dev/null || err "OpenClaw not found. Install: npm install -g openclaw && openclaw configure"
[ -f "$HOME/.openclaw/openclaw.json" ] || err "OpenClaw not configured. Run: openclaw configure"
log "Prerequisites OK"

# --- Config ---
info "Configuring OpenClaw..."
openclaw config set gateway.http.endpoints.chatCompletions.enabled true 2>/dev/null
PUBLIC_IP=$(curl -4sf https://ifconfig.me)
DOMAIN="${PUBLIC_IP//./-}.sslip.io"
openclaw config set gateway.controlUi.allowedOrigins "[\"https://$DOMAIN\"]" 2>/dev/null
log "chatCompletions enabled, domain: $DOMAIN"

# --- Gateway Service ---
info "Setting up gateway service..."
loginctl enable-linger root 2>/dev/null || true
mkdir -p ~/.config/systemd/user
OCPATH=$(which openclaw)
cat > ~/.config/systemd/user/openclaw-gateway.service << EOF
[Unit]
Description=OpenClaw Gateway
[Service]
ExecStart=$OCPATH gateway run
Restart=always
RestartSec=5
[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now openclaw-gateway
log "Gateway service started, waiting 10s..."
sleep 10

# --- Bridge ---
info "Installing bridge..."
mkdir -p /opt/clawpress-bridge
BRIDGE_URL="https://raw.githubusercontent.com/emrahsinekli/clawpress-bridge/master/index.js"
curl -fsSL "$BRIDGE_URL" -o /opt/clawpress-bridge/index.js || err "Could not download bridge. Check internet."
log "Bridge downloaded"

NODEPATH=$(which node)
cat > /etc/systemd/system/clawpress-bridge.service << EOF
[Unit]
Description=ClawPress Bridge
After=network.target
[Service]
ExecStart=$NODEPATH /opt/clawpress-bridge/index.js
Restart=always
RestartSec=5
Environment=HOME=/root
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload
systemctl enable --now clawpress-bridge
sleep 2
log "Bridge service started"

# --- nginx + SSL ---
info "Setting up nginx + SSL..."
apt-get update -qq
apt-get install -y nginx certbot python3-certbot-nginx -qq

cat > /etc/nginx/sites-available/clawpress << NGINXCONF
server {
    listen 80;
    server_name $DOMAIN;

    location /clawpress/ {
        proxy_pass http://127.0.0.1:18790;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400;
    }

    location / {
        proxy_pass http://127.0.0.1:18789;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 86400;
    }
}
NGINXCONF

ln -sf /etc/nginx/sites-available/clawpress /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx
log "nginx configured"

ufw allow 22 >/dev/null 2>&1
ufw allow 80 >/dev/null 2>&1
ufw allow 443 >/dev/null 2>&1
ufw --force enable >/dev/null 2>&1
log "Firewall OK"

certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect 2>/dev/null && log "SSL installed" || warn "SSL failed (retry: certbot --nginx -d $DOMAIN)"

# --- Result ---
TOKEN=$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('/root/.openclaw/openclaw.json','utf8')).gateway.auth.token)}catch{console.log('TOKEN_NOT_FOUND')}")
echo ""
echo "========================================"
echo "  ClawPress Setup Complete!"
echo "========================================"
echo ""
echo "  WordPress Settings:"
echo "    Gateway URL:   https://$DOMAIN"
echo "    Gateway Token: $TOKEN"
echo ""
echo "  Dashboard (from your computer):"
echo "    ssh -N -L 18789:127.0.0.1:18789 root@$PUBLIC_IP"
echo "    then open: http://127.0.0.1:18789/#token=$TOKEN"
echo "========================================"
