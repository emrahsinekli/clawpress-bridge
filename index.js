/**
 * ClawPress Bridge
 *
 * Lightweight HTTP → CLI bridge for OpenClaw cron management.
 * WordPress plugin calls these endpoints; bridge translates to `openclaw cron` CLI.
 *
 *   GET    /clawpress/cron         → openclaw cron list --json
 *   POST   /clawpress/cron         → openclaw cron add ...
 *   PUT    /clawpress/cron/:id     → openclaw cron edit ...
 *   DELETE /clawpress/cron/:id     → openclaw cron rm ...
 *
 * Everything else is proxied to the OpenClaw gateway (127.0.0.1:18789).
 */

const http = require('http');
const { execFile } = require('child_process');
const fs = require('fs');
const path = require('path');

// ─── Config ──────────────────────────────────────────────────────────

const PORT         = parseInt(process.env.BRIDGE_PORT || '18790', 10);
const GW_HOST      = process.env.GATEWAY_HOST || '127.0.0.1';
const GW_PORT      = parseInt(process.env.GATEWAY_PORT || '18789', 10);

function readToken() {
    try {
        const p = path.join(process.env.HOME || process.env.USERPROFILE || '', '.openclaw', 'openclaw.json');
        const c = JSON.parse(fs.readFileSync(p, 'utf8'));
        return c?.gateway?.auth?.token || '';
    } catch { return ''; }
}

const TOKEN = readToken();
if (!TOKEN) {
    console.error('[bridge] Cannot read gateway token from ~/.openclaw/openclaw.json');
    console.error('[bridge] Run: openclaw configure');
    process.exit(1);
}

// ─── Helpers ─────────────────────────────────────────────────────────

const log = (m) => console.log(`[bridge] ${new Date().toISOString().slice(11,19)} ${m}`);

function json(res, code, data) {
    const b = JSON.stringify(data);
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(b);
}

function auth(req) {
    return (req.headers['authorization'] || '').replace(/^Bearer\s+/i, '') === TOKEN;
}

function body(req) {
    return new Promise(r => {
        let d = '';
        req.on('data', c => { d += c; });
        req.on('end', () => { try { r(JSON.parse(d || '{}')); } catch { r({}); } });
    });
}

function cron(args, timeout = 15000) {
    return new Promise((resolve, reject) => {
        execFile('openclaw', ['cron', ...args, '--json'], { timeout }, (err, stdout, stderr) => {
            if (err) {
                const o = stdout || stderr || '';
                try { resolve(JSON.parse(o)); } catch { reject(new Error(err.message)); }
                return;
            }
            try { resolve(JSON.parse(stdout)); } catch { resolve({ raw: stdout.trim() }); }
        });
    });
}

// ─── Cron Handlers ───────────────────────────────────────────────────

async function cronList(req, res) {
    try { json(res, 200, await cron(['list'])); }
    catch (e) { json(res, 500, { error: e.message }); }
}

async function cronCreate(req, res) {
    const b = await body(req);
    const a = ['add'];
    if (b.name)        a.push('--name', b.name);
    if (b.schedule)    a.push('--cron', typeof b.schedule === 'object' ? b.schedule.expr : b.schedule);
    if (b.timezone || b.schedule?.tz) a.push('--tz', b.timezone || b.schedule.tz);
    if (b.prompt || b.payload?.text)  a.push('--message', b.prompt || b.payload.text);
    if (b.description) a.push('--description', b.description);
    if (b.enabled === false) a.push('--disabled');
    log(`add: ${b.name || '?'}`);
    try { json(res, 200, await cron(a, 20000)); }
    catch (e) { json(res, 500, { error: e.message }); }
}

async function cronUpdate(req, res) {
    const id = req.url.split('/').pop();
    if (!id) return json(res, 400, { error: 'Missing job ID' });
    const b = await body(req);
    const a = ['edit', id];
    if (b.name)        a.push('--name', b.name);
    if (b.schedule)    a.push('--cron', typeof b.schedule === 'object' ? b.schedule.expr : b.schedule);
    if (b.timezone || b.schedule?.tz) a.push('--tz', b.timezone || b.schedule.tz);
    if (b.prompt || b.payload?.text)  a.push('--message', b.prompt || b.payload.text);
    if (b.description) a.push('--description', b.description);
    if (b.enabled === true)  a.push('--enable');
    if (b.enabled === false) a.push('--disable');
    log(`edit: ${id}`);
    try { json(res, 200, await cron(a, 20000)); }
    catch (e) { json(res, 500, { error: e.message }); }
}

async function cronDelete(req, res) {
    const id = req.url.split('/').pop();
    if (!id) return json(res, 400, { error: 'Missing job ID' });
    log(`rm: ${id}`);
    try { json(res, 200, await cron(['rm', id])); }
    catch (e) { json(res, 500, { error: e.message }); }
}

// ─── Gateway Proxy ───────────────────────────────────────────────────

function proxy(req, res) {
    const opts = {
        hostname: GW_HOST, port: GW_PORT, path: req.url,
        method: req.method, headers: { ...req.headers, host: `${GW_HOST}:${GW_PORT}` },
    };
    const p = http.request(opts, (g) => { res.writeHead(g.statusCode, g.headers); g.pipe(res); });
    p.on('error', (e) => { if (!res.headersSent) json(res, 502, { error: e.message }); });
    req.pipe(p);
}

// ─── Server ──────────────────────────────────────────────────────────

const server = http.createServer(async (req, res) => {
    const origin = req.headers['origin'] || '';
    res.setHeader('Access-Control-Allow-Origin', origin || '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,DELETE,OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type,Authorization');
    if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }

    const url = req.url.split('?')[0];

    try {
        if (url.startsWith('/clawpress/cron')) {
            if (!auth(req)) return json(res, 401, { error: 'Unauthorized' });
            if (req.method === 'GET'    && url === '/clawpress/cron')          return await cronList(req, res);
            if (req.method === 'POST'   && url === '/clawpress/cron')          return await cronCreate(req, res);
            if (req.method === 'PUT'    && url.startsWith('/clawpress/cron/')) return await cronUpdate(req, res);
            if (req.method === 'DELETE' && url.startsWith('/clawpress/cron/')) return await cronDelete(req, res);
            return json(res, 404, { error: 'Not found' });
        }
        proxy(req, res);
    } catch (e) {
        log(`Error: ${e.message}`);
        if (!res.headersSent) json(res, 500, { error: 'Internal error' });
    }
});

// WebSocket upgrade — proxy to gateway (dashboard needs this).
const net = require('net');
server.on('upgrade', (req, socket, head) => {
    const gwSocket = net.connect(GW_PORT, GW_HOST, () => {
        const reqLine = `${req.method} ${req.url} HTTP/1.1\r\n`;
        const headers = Object.entries(req.headers).map(([k,v]) => `${k}: ${v}`).join('\r\n');
        gwSocket.write(reqLine + headers + '\r\n\r\n');
        if (head.length) gwSocket.write(head);
        socket.pipe(gwSocket).pipe(socket);
    });
    gwSocket.on('error', () => socket.destroy());
    socket.on('error', () => gwSocket.destroy());
});

server.listen(PORT, '127.0.0.1', () => {
    log('ClawPress Bridge running on http://127.0.0.1:' + PORT);
    log('Proxying to OpenClaw gateway at ' + GW_HOST + ':' + GW_PORT);
});
