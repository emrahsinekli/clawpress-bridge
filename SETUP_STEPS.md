# ClawPress Kurulum Adımları (Kesin Çalışan)

## Sorunlar ve Çözümler Log

### Pairing Sorunu
- OpenClaw dashboard'a dışarıdan HTTPS ile bağlanınca "pairing required" hatası veriyor
- Config'den kapatılamıyor (`requirePairing` key tanınmıyor)
- Her Connect'te yeni pairing request oluşuyor, onaylansa bile tekrar soruyor
- **ÇÖZÜM:** SSH tunnel ile localhost üzerinden bağlanmak — pairing bypass ediliyor

### Dashboard Erişimi (SSH Tunnel)
Kullanıcı kendi bilgisayarında:
```bash
ssh -N -L 18789:127.0.0.1:18789 root@SUNUCU_IP
```
Sonra tarayıcıda:
```
http://127.0.0.1:18789/#token=GATEWAY_TOKEN
```
Bu şekilde sunucunun localhost'una doğrudan bağlanıyor — nginx yok, bridge yok, pairing yok.

---

## Sunucu Kurulum (Sıfırdan)

### Ön Koşullar
- Linux VPS (Ubuntu 20.04+)
- Root SSH erişimi
- DeepSeek API key

### Adım 1: Node.js Kur
```bash
curl -fsSL https://deb.nodesource.com/setup_22.x | bash - && apt-get install -y nodejs
```

### Adım 2: OpenClaw Kur
```bash
npm install -g openclaw
```

### Adım 3: OpenClaw Yapılandır (interaktif)
```bash
openclaw configure
```
- Model: DeepSeek seç
- API key yapıştır
- Gateway ayarları: default kabul et

### Adım 4: Tek Seferde Geri Kalanı Kur
```bash
# chatCompletions aç
openclaw config set gateway.http.endpoints.chatCompletions.enabled true

# allowedOrigins ekle
PUBLIC_IP=$(curl -4sf https://ifconfig.me)
DOMAIN="${PUBLIC_IP//./-}.sslip.io"
openclaw config set gateway.controlUi.allowedOrigins "[\"https://$DOMAIN\"]"

# Gateway servisi
loginctl enable-linger root
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
sleep 5

# Bridge kur (Schedule/Cron özelliği için)
mkdir -p /opt/clawpress-bridge
cat > /opt/clawpress-bridge/index.js << 'BRIDGEOF'
const http=require('http'),{execFile}=require('child_process'),fs=require('fs'),path=require('path'),net=require('net');const PORT=parseInt(process.env.BRIDGE_PORT||'18790',10),GW_HOST=process.env.GATEWAY_HOST||'127.0.0.1',GW_PORT=parseInt(process.env.GATEWAY_PORT||'18789',10);function readToken(){try{return JSON.parse(fs.readFileSync(path.join(process.env.HOME||'/root','.openclaw','openclaw.json'),'utf8'))?.gateway?.auth?.token||''}catch{return''}}const TOKEN=readToken();if(!TOKEN){console.error('[bridge] No token');process.exit(1)}const log=m=>console.log(`[bridge] ${new Date().toISOString().slice(11,19)} ${m}`);function json(r,c,d){r.writeHead(c,{'Content-Type':'application/json'});r.end(JSON.stringify(d))}function auth(r){return(r.headers['authorization']||'').replace(/^Bearer\s+/i,'')===TOKEN}function body(r){return new Promise(v=>{let d='';r.on('data',c=>{d+=c});r.on('end',()=>{try{v(JSON.parse(d||'{}'))}catch{v({})}})})}function cron(a,t=15000){return new Promise((v,j)=>{execFile('openclaw',['cron',...a,'--json'],{timeout:t},(e,o,s)=>{if(e){try{v(JSON.parse(o||s||''))}catch{j(new Error(e.message))}return}try{v(JSON.parse(o))}catch{v({raw:o.trim()})}})})}async function CL(q,r){try{json(r,200,await cron(['list']))}catch(e){json(r,500,{error:e.message})}}async function CC(q,r){const b=await body(q),a=['add'];if(b.name)a.push('--name',b.name);if(b.schedule)a.push('--cron',typeof b.schedule==='object'?b.schedule.expr:b.schedule);if(b.timezone||b.schedule?.tz)a.push('--tz',b.timezone||b.schedule.tz);if(b.prompt||b.payload?.text)a.push('--message',b.prompt||b.payload.text);if(b.description)a.push('--description',b.description);if(b.enabled===false)a.push('--disabled');log('add: '+(b.name||'?'));try{json(r,200,await cron(a,20000))}catch(e){json(r,500,{error:e.message})}}async function CU(q,r){const id=q.url.split('/').pop();if(!id)return json(r,400,{error:'Missing ID'});const b=await body(q),a=['edit',id];if(b.name)a.push('--name',b.name);if(b.schedule)a.push('--cron',typeof b.schedule==='object'?b.schedule.expr:b.schedule);if(b.timezone||b.schedule?.tz)a.push('--tz',b.timezone||b.schedule.tz);if(b.prompt||b.payload?.text)a.push('--message',b.prompt||b.payload.text);if(b.description)a.push('--description',b.description);if(b.enabled===true)a.push('--enable');if(b.enabled===false)a.push('--disable');log('edit: '+id);try{json(r,200,await cron(a,20000))}catch(e){json(r,500,{error:e.message})}}async function CD(q,r){const id=q.url.split('/').pop();if(!id)return json(r,400,{error:'Missing ID'});log('rm: '+id);try{json(r,200,await cron(['rm',id]))}catch(e){json(r,500,{error:e.message})}}function proxy(q,r){const p=http.request({hostname:GW_HOST,port:GW_PORT,path:q.url,method:q.method,headers:{...q.headers,host:GW_HOST+':'+GW_PORT}},g=>{r.writeHead(g.statusCode,g.headers);g.pipe(r)});p.on('error',e=>{if(!r.headersSent)json(r,502,{error:e.message})});q.pipe(p)}const S=http.createServer(async(q,r)=>{const o=q.headers['origin']||'';r.setHeader('Access-Control-Allow-Origin',o||'*');r.setHeader('Access-Control-Allow-Methods','GET,POST,PUT,DELETE,OPTIONS');r.setHeader('Access-Control-Allow-Headers','Content-Type,Authorization');if(q.method==='OPTIONS'){r.writeHead(204);return r.end()}const u=q.url.split('?')[0];try{if(u.startsWith('/clawpress/cron')){if(!auth(q))return json(r,401,{error:'Unauthorized'});if(q.method==='GET'&&u==='/clawpress/cron')return await CL(q,r);if(q.method==='POST'&&u==='/clawpress/cron')return await CC(q,r);if(q.method==='PUT'&&u.startsWith('/clawpress/cron/'))return await CU(q,r);if(q.method==='DELETE'&&u.startsWith('/clawpress/cron/'))return await CD(q,r);return json(r,404,{error:'Not found'})}proxy(q,r)}catch(e){log('Error: '+e.message);if(!r.headersSent)json(r,500,{error:'Internal error'})}});S.on('upgrade',(q,s,h)=>{const g=net.connect(GW_PORT,GW_HOST,()=>{g.write(q.method+' '+q.url+' HTTP/1.1\r\n'+Object.entries(q.headers).map(([k,v])=>k+': '+v).join('\r\n')+'\r\n\r\n');if(h.length)g.write(h);s.pipe(g).pipe(s)});g.on('error',()=>s.destroy());s.on('error',()=>g.destroy())});S.listen(PORT,'127.0.0.1',()=>{log('Bridge on :'+PORT);log('Gateway: '+GW_HOST+':'+GW_PORT)});
BRIDGEOF

# Bridge servisi
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

# nginx + SSL
apt-get update -qq && apt-get install -y nginx certbot python3-certbot-nginx

cat > /etc/nginx/sites-available/clawpress << NGINX
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
NGINX

ln -sf /etc/nginx/sites-available/clawpress /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl enable --now nginx

ufw allow 80 && ufw allow 443 && ufw --force enable

certbot --nginx -d $DOMAIN --non-interactive --agree-tos --register-unsafely-without-email --redirect 2>/dev/null

# Sonuç
TOKEN=$(node -e "try{console.log(JSON.parse(require('fs').readFileSync('/root/.openclaw/openclaw.json','utf8')).gateway.auth.token)}catch{console.log('TOKEN_NOT_FOUND')}")
echo ""
echo "========================================"
echo "  ClawPress Setup Complete!"
echo "========================================"
echo ""
echo "  Gateway URL:   https://$DOMAIN"
echo "  Gateway Token: $TOKEN"
echo ""
echo "  WordPress:  Paste URL+Token into ClawPress -> Settings"
echo "  Dashboard:  ssh -N -L 18789:127.0.0.1:18789 root@$PUBLIC_IP"
echo "              then open http://127.0.0.1:18789/#token=$TOKEN"
echo "========================================"
```

### Adım 5: WordPress'e Bağla
ClawPress → Settings:
- Gateway URL: `https://IP.sslip.io` (Adım 4 sonunda gösterilir)
- Gateway Token: (Adım 4 sonunda gösterilir)

### Adım 6: Dashboard'a Bağlan (SSH Tunnel)
Kendi bilgisayarında:
```bash
ssh -N -L 18789:127.0.0.1:18789 root@SUNUCU_IP
```
Sonra tarayıcıda:
```
http://127.0.0.1:18789/#token=GATEWAY_TOKEN
```

---

## Mimari

```
WordPress (hosting)
    ↓ HTTPS
  nginx (:443)
    ├── /clawpress/cron  →  Bridge (:18790)  →  openclaw cron CLI
    └── /v1/*            →  Gateway (:18789)  →  DeepSeek API

Dashboard (SSH tunnel)
    ↓ localhost:18789
  Gateway (:18789) doğrudan — pairing yok
```

## Önemli Notlar
- OpenClaw pairing HTTPS üzerinden dashboard bağlantısını engelliyor
- SSH tunnel ile localhost üzerinden bağlanınca pairing bypass ediliyor
- WordPress chat/cron API'leri HTTPS üzerinden sorunsuz çalışıyor (pairing sadece WebSocket dashboard için)
- Bridge sadece Schedule/Cron için gerekli — chat, SEO, content generation bridge olmadan da çalışır
- `openclaw cron` CLI de gateway'e WebSocket ile bağlandığı için pairing gerekiyor — bridge kurulunca ilk bağlantıda approve lazım
