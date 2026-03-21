#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════
# ClawPress Bridge — One-Command Installer
#
# Connects your WordPress ClawPress plugin to your OpenClaw gateway.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/clawpress/clawpress-bridge/main/setup.sh | bash
#
# What it does:
#   1. Checks prerequisites (Node.js, OpenClaw)
#   2. Installs the ClawPress Bridge (HTTP → CLI translator)
#   3. Sets up nginx with free SSL (sslip.io + Let's Encrypt)
#   4. Enables the chatCompletions endpoint
#   5. Prints your Gateway URL + Token for WordPress
#
# Flags:
#   --domain example.com   Use a custom domain instead of sslip.io
#   --no-ssl               Skip SSL setup
#   --uninstall             Remove everything
# ═══════════════════════════════════════════════════════════════════════
set -euo pipefail

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'
log()  { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
err()  { echo -e "${RED}✗${NC} $1"; exit 1; }
info() { echo -e "${CYAN}→${NC} $1"; }

CUSTOM_DOMAIN=""
NO_SSL=false
UNINSTALL=false

for arg in "$@"; do
    case "$arg" in
        --domain=*) CUSTOM_DOMAIN="${arg#*=}" ;;
        --no-ssl)   NO_SSL=true ;;
        --uninstall) UNINSTALL=true ;;
    esac
done

# ─── Uninstall ────────────────────────────────────────────────────────
if [ "$UNINSTALL" = true ]; then
    info "Uninstalling ClawPress Bridge..."
    systemctl stop clawpress-bridge 2>/dev/null || true
    systemctl disable clawpress-bridge 2>/dev/null || true
    rm -f /etc/systemd/system/clawpress-bridge.service
    rm -rf /opt/clawpress-bridge
    rm -f /etc/nginx/sites-enabled/clawpress
    rm -f /etc/nginx/sites-available/clawpress
    systemctl daemon-reload 2>/dev/null || true
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null || true
    log "ClawPress Bridge uninstalled."
    exit 0
fi

# ─── Banner ───────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  🦀 ClawPress Bridge Installer${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""

# ─── Phase 1: Prerequisites ──────────────────────────────────────────
info "Checking prerequisites..."

# Must be Linux
[ "$(uname -s)" = "Linux" ] || err "This installer is for Linux only."

# Must be root
[ "$(id -u)" -eq 0 ] || err "Run as root: sudo bash or su -c 'bash setup.sh'"

# Node.js >= 18
if ! command -v node &>/dev/null; then
    err "Node.js not found. Install it first:\n  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs"
fi
NODE_VER=$(node -v | sed 's/v//' | cut -d. -f1)
[ "$NODE_VER" -ge 18 ] || err "Node.js 18+ required (found v$NODE_VER). Update: https://nodejs.org"
log "Node.js v$(node -v | sed 's/v//')"

# OpenClaw installed
command -v openclaw &>/dev/null || err "OpenClaw not found. Install it first:\n  npm install -g openclaw && openclaw configure"
log "OpenClaw $(openclaw -V 2>/dev/null || echo 'installed')"

# OpenClaw configured
OPENCLAW_CONFIG="$HOME/.openclaw/openclaw.json"
[ -f "$OPENCLAW_CONFIG" ] || err "OpenClaw not configured. Run: openclaw configure"
log "OpenClaw config found"

# Gateway token
GATEWAY_TOKEN=$(node -e "
    try {
        const c = require('$OPENCLAW_CONFIG');
        console.log(c?.gateway?.auth?.token || '');
    } catch { console.log(''); }
" 2>/dev/null)
[ -n "$GATEWAY_TOKEN" ] || err "No gateway token set. Run:\n  openclaw config set gateway.auth.mode token\n  openclaw config set gateway.auth.token \$(openssl rand -hex 24)"
log "Gateway token found (${GATEWAY_TOKEN:0:8}...)"

# Public IP
PUBLIC_IP=$(curl -4sf https://ifconfig.me 2>/dev/null || curl -4sf https://api.ipify.org 2>/dev/null || echo "")
[ -n "$PUBLIC_IP" ] || err "Could not detect public IP. Check your internet connection."
log "Public IP: $PUBLIC_IP"

# ─── Phase 2: Enable chatCompletions ─────────────────────────────────
info "Enabling chatCompletions endpoint..."
openclaw config set gateway.http.endpoints.chatCompletions.enabled true 2>/dev/null || warn "Could not set chatCompletions (may already be enabled)"
log "chatCompletions enabled"

# ─── Phase 3: Install Bridge ─────────────────────────────────────────
info "Installing ClawPress Bridge..."

BRIDGE_DIR="/opt/clawpress-bridge"
mkdir -p "$BRIDGE_DIR"

# Download bridge script (or copy from npm)
if npm list -g clawpress-bridge &>/dev/null 2>&1; then
    BRIDGE_PATH="$(npm root -g)/clawpress-bridge/index.js"
    log "clawpress-bridge already installed via npm"
else
    # Download directly from GitHub
    BRIDGE_URL="https://raw.githubusercontent.com/emrahsinekli/clawpress-bridge/master/index.js"
    if curl -fsSL "$BRIDGE_URL" -o "$BRIDGE_DIR/index.js" 2>/dev/null; then
        BRIDGE_PATH="$BRIDGE_DIR/index.js"
        log "Bridge downloaded from GitHub"
    else
        err "Could not download bridge from GitHub. Check your internet connection."
    fi
fi

# ─── Phase 4: Systemd Service ────────────────────────────────────────
info "Setting up systemd service..."

NODE_PATH=$(which node)

cat > /etc/systemd/system/clawpress-bridge.service << EOF
[Unit]
Description=ClawPress Bridge
After=network.target

[Service]
Type=simple
ExecStart=$NODE_PATH $BRIDGE_PATH
Restart=always
RestartSec=5
Environment=NODE_ENV=production
Environment=BRIDGE_PORT=18790
Environment=GATEWAY_HOST=127.0.0.1
Environment=GATEWAY_PORT=18789
Environment=HOME=$HOME

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now clawpress-bridge
sleep 2

if systemctl is-active --quiet clawpress-bridge; then
    log "Bridge service running on port 18790"
else
    err "Bridge failed to start. Check: journalctl -u clawpress-bridge -n 20"
fi

# ─── Phase 5: nginx + SSL ────────────────────────────────────────────
info "Setting up nginx..."

# Install nginx + certbot if needed
if ! command -v nginx &>/dev/null; then
    apt-get update -qq && apt-get install -y nginx
fi
log "nginx installed"

# Determine domain
if [ -n "$CUSTOM_DOMAIN" ]; then
    DOMAIN="$CUSTOM_DOMAIN"
else
    DOMAIN="${PUBLIC_IP//./-}.sslip.io"
fi
log "Domain: $DOMAIN"

# Create nginx config
cat > /etc/nginx/sites-available/clawpress << NGINXEOF
server {
    listen 80;
    server_name $DOMAIN;

    location / {
        proxy_pass http://127.0.0.1:18790;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_read_timeout 86400;
    }
}
NGINXEOF

ln -sf /etc/nginx/sites-available/clawpress /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default 2>/dev/null || true

if nginx -t 2>/dev/null; then
    systemctl reload nginx
    log "nginx configured"
else
    err "nginx config test failed. Check: nginx -t"
fi

# Firewall
if command -v ufw &>/dev/null && ufw status | grep -q "active"; then
    ufw allow 80 >/dev/null 2>&1
    ufw allow 443 >/dev/null 2>&1
    log "Firewall ports 80/443 opened"
fi

# SSL (unless --no-ssl)
GATEWAY_URL="http://$DOMAIN"
if [ "$NO_SSL" = false ]; then
    info "Setting up SSL certificate..."
    if ! command -v certbot &>/dev/null; then
        apt-get install -y certbot python3-certbot-nginx 2>/dev/null || apt-get install -y certbot 2>/dev/null
    fi

    if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos --register-unsafely-without-email --redirect 2>/dev/null; then
        GATEWAY_URL="https://$DOMAIN"
        log "SSL certificate installed"
    else
        warn "SSL setup failed (sslip.io rate limit?). Using HTTP for now."
        warn "Retry later: certbot --nginx -d $DOMAIN"
    fi
fi

# ─── Phase 6: Restart Gateway ────────────────────────────────────────
info "Restarting OpenClaw gateway..."

if systemctl is-active --quiet openclaw-gateway 2>/dev/null; then
    systemctl restart openclaw-gateway
    sleep 3
    log "Gateway restarted (system service)"
elif systemctl --user is-active --quiet openclaw-gateway 2>/dev/null; then
    systemctl --user restart openclaw-gateway
    sleep 3
    log "Gateway restarted (user service)"
else
    warn "Gateway service not found. Start it manually: openclaw gateway run"
fi

# ─── Phase 7: Verify ─────────────────────────────────────────────────
info "Verifying setup..."

ERRORS=0

# Bridge reachable
if curl -sf http://127.0.0.1:18790/ -o /dev/null 2>/dev/null; then
    log "Bridge reachable"
else
    warn "Bridge not reachable on port 18790"
    ERRORS=$((ERRORS+1))
fi

# Cron API works
CRON_TEST=$(curl -sf -H "Authorization: Bearer $GATEWAY_TOKEN" http://127.0.0.1:18790/clawpress/cron 2>/dev/null || echo "FAIL")
if echo "$CRON_TEST" | grep -q "jobs"; then
    log "Cron API working"
else
    warn "Cron API not responding"
    ERRORS=$((ERRORS+1))
fi

# nginx proxying
if curl -sf "http://$DOMAIN/" -o /dev/null 2>/dev/null; then
    log "nginx proxy working"
else
    warn "nginx proxy not reachable from outside"
    ERRORS=$((ERRORS+1))
fi

# ─── Phase 8: Summary ────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo -e "${BOLD}  🦀 ClawPress Bridge Setup Complete!${NC}"
echo -e "${BOLD}═══════════════════════════════════════════════════${NC}"
echo ""
echo -e "  Paste these into your WordPress ${BOLD}ClawPress → Settings${NC}:"
echo ""
echo -e "  ${BOLD}Gateway URL:${NC}   ${CYAN}$GATEWAY_URL${NC}"
echo -e "  ${BOLD}Gateway Token:${NC} ${CYAN}$GATEWAY_TOKEN${NC}"
echo ""
echo -e "  ${BOLD}Useful commands:${NC}"
echo -e "    Bridge status:  systemctl status clawpress-bridge"
echo -e "    Gateway status: systemctl status openclaw-gateway"
echo -e "    Bridge logs:    journalctl -u clawpress-bridge -f"
echo -e "    Uninstall:      curl -fsSL <url> | bash -s -- --uninstall"
echo ""

if [ $ERRORS -gt 0 ]; then
    warn "$ERRORS verification(s) failed. Check the warnings above."
else
    log "All checks passed. Your WordPress is ready to connect!"
fi

exit 0

# ─── Embedded Bridge Code (do not edit below) ────────────────────────
##BRIDGE_START##
const http = require('http');
const { execFile } = require('child_process');
const fs = require('fs');
const path = require('path');
const net = require('net');

const PORT    = parseInt(process.env.BRIDGE_PORT || '18790', 10);
const GW_HOST = process.env.GATEWAY_HOST || '127.0.0.1';
const GW_PORT = parseInt(process.env.GATEWAY_PORT || '18789', 10);

function readToken() {
    try {
        const p = path.join(process.env.HOME || process.env.USERPROFILE || '', '.openclaw', 'openclaw.json');
        return JSON.parse(fs.readFileSync(p, 'utf8'))?.gateway?.auth?.token || '';
    } catch { return ''; }
}
const TOKEN = readToken();
if (!TOKEN) { console.error('[bridge] No token in ~/.openclaw/openclaw.json'); process.exit(1); }

const log = m => console.log(`[bridge] ${new Date().toISOString().slice(11,19)} ${m}`);
function json(res, code, data) { res.writeHead(code, {'Content-Type':'application/json'}); res.end(JSON.stringify(data)); }
function auth(req) { return (req.headers['authorization']||'').replace(/^Bearer\s+/i,'') === TOKEN; }
function body(req) { return new Promise(r => { let d=''; req.on('data',c=>{d+=c}); req.on('end',()=>{ try{r(JSON.parse(d||'{}'))}catch{r({})} }); }); }
function cron(args, timeout=15000) {
    return new Promise((resolve, reject) => {
        execFile('openclaw', ['cron', ...args, '--json'], {timeout}, (err, stdout, stderr) => {
            if (err) { try{resolve(JSON.parse(stdout||stderr||''))}catch{reject(new Error(err.message))} return; }
            try{resolve(JSON.parse(stdout))}catch{resolve({raw:stdout.trim()})}
        });
    });
}

async function cronList(req,res) { try{json(res,200,await cron(['list']))}catch(e){json(res,500,{error:e.message})} }
async function cronCreate(req,res) {
    const b=await body(req), a=['add'];
    if(b.name) a.push('--name',b.name);
    if(b.schedule) a.push('--cron', typeof b.schedule==='object'?b.schedule.expr:b.schedule);
    if(b.timezone||b.schedule?.tz) a.push('--tz',b.timezone||b.schedule.tz);
    if(b.prompt||b.payload?.text) a.push('--message',b.prompt||b.payload.text);
    if(b.description) a.push('--description',b.description);
    if(b.enabled===false) a.push('--disabled');
    log(`add: ${b.name||'?'}`);
    try{json(res,200,await cron(a,20000))}catch(e){json(res,500,{error:e.message})}
}
async function cronUpdate(req,res) {
    const id=req.url.split('/').pop(); if(!id) return json(res,400,{error:'Missing ID'});
    const b=await body(req), a=['edit',id];
    if(b.name) a.push('--name',b.name);
    if(b.schedule) a.push('--cron', typeof b.schedule==='object'?b.schedule.expr:b.schedule);
    if(b.timezone||b.schedule?.tz) a.push('--tz',b.timezone||b.schedule.tz);
    if(b.prompt||b.payload?.text) a.push('--message',b.prompt||b.payload.text);
    if(b.description) a.push('--description',b.description);
    if(b.enabled===true) a.push('--enable');
    if(b.enabled===false) a.push('--disable');
    log(`edit: ${id}`);
    try{json(res,200,await cron(a,20000))}catch(e){json(res,500,{error:e.message})}
}
async function cronDelete(req,res) {
    const id=req.url.split('/').pop(); if(!id) return json(res,400,{error:'Missing ID'});
    log(`rm: ${id}`);
    try{json(res,200,await cron(['rm',id]))}catch(e){json(res,500,{error:e.message})}
}
function proxy(req,res) {
    const p=http.request({hostname:GW_HOST,port:GW_PORT,path:req.url,method:req.method,headers:{...req.headers,host:`${GW_HOST}:${GW_PORT}`}},g=>{res.writeHead(g.statusCode,g.headers);g.pipe(res)});
    p.on('error',e=>{if(!res.headersSent)json(res,502,{error:e.message})});
    req.pipe(p);
}

const server = http.createServer(async(req,res)=>{
    const origin=req.headers['origin']||'';
    res.setHeader('Access-Control-Allow-Origin',origin||'*');
    res.setHeader('Access-Control-Allow-Methods','GET,POST,PUT,DELETE,OPTIONS');
    res.setHeader('Access-Control-Allow-Headers','Content-Type,Authorization');
    if(req.method==='OPTIONS'){res.writeHead(204);return res.end()}
    const url=req.url.split('?')[0];
    try{
        if(url.startsWith('/clawpress/cron')){
            if(!auth(req)) return json(res,401,{error:'Unauthorized'});
            if(req.method==='GET'&&url==='/clawpress/cron') return await cronList(req,res);
            if(req.method==='POST'&&url==='/clawpress/cron') return await cronCreate(req,res);
            if(req.method==='PUT'&&url.startsWith('/clawpress/cron/')) return await cronUpdate(req,res);
            if(req.method==='DELETE'&&url.startsWith('/clawpress/cron/')) return await cronDelete(req,res);
            return json(res,404,{error:'Not found'});
        }
        proxy(req,res);
    }catch(e){log(`Error: ${e.message}`);if(!res.headersSent)json(res,500,{error:'Internal error'})}
});
server.on('upgrade',(req,socket,head)=>{
    const gw=net.connect(GW_PORT,GW_HOST,()=>{
        gw.write(`${req.method} ${req.url} HTTP/1.1\r\n${Object.entries(req.headers).map(([k,v])=>`${k}: ${v}`).join('\r\n')}\r\n\r\n`);
        if(head.length) gw.write(head);
        socket.pipe(gw).pipe(socket);
    });
    gw.on('error',()=>socket.destroy());
    socket.on('error',()=>gw.destroy());
});
server.listen(PORT,'127.0.0.1',()=>{log('ClawPress Bridge on :'+PORT);log('Gateway: '+GW_HOST+':'+GW_PORT)});
##BRIDGE_END##
