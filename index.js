/**
 * ClawPress Bridge v2
 *
 * Reads/writes OpenClaw cron jobs directly from ~/.openclaw/cron/jobs.json.
 * No CLI, no WebSocket, no pairing required.
 *
 *   GET    /clawpress/cron         → list jobs
 *   POST   /clawpress/cron         → create job
 *   PUT    /clawpress/cron/:id     → update job
 *   DELETE /clawpress/cron/:id     → delete job
 *
 * Everything else is proxied to the OpenClaw Gateway.
 */

const http = require('http');
const fs = require('fs');
const path = require('path');
const net = require('net');
const crypto = require('crypto');
const { execSync } = require('child_process');

const PORT = parseInt(process.env.BRIDGE_PORT || '18790', 10);
const GW_HOST = process.env.GATEWAY_HOST || '127.0.0.1';
const GW_PORT = parseInt(process.env.GATEWAY_PORT || '18789', 10);
const HOME = process.env.HOME || '/root';
const CRON_FILE = path.join(HOME, '.openclaw', 'cron', 'jobs.json');
const CONFIG_FILE = path.join(HOME, '.openclaw', 'openclaw.json');
const WORKSPACES_DIR = path.join(HOME, '.openclaw', 'workspaces');

// Read gateway token from openclaw config.
function readToken() {
    try {
        return JSON.parse(fs.readFileSync(CONFIG_FILE, 'utf8'))?.gateway?.auth?.token || '';
    } catch { return ''; }
}

const TOKEN = readToken();
if (!TOKEN) { console.error('[bridge] No gateway token found in openclaw.json'); process.exit(1); }

const log = (m) => console.log(`[bridge] ${new Date().toISOString().slice(11, 19)} ${m}`);

// --- Helpers ---

function json(res, code, data) {
    res.writeHead(code, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(data));
}

function auth(req) {
    return (req.headers['authorization'] || '').replace(/^Bearer\s+/i, '') === TOKEN;
}

function parseBody(req) {
    return new Promise((resolve) => {
        let d = '';
        req.on('data', (c) => { d += c; });
        req.on('end', () => { try { resolve(JSON.parse(d || '{}')); } catch { resolve({}); } });
    });
}

// --- Cron File Operations (no CLI, no WebSocket, no pairing) ---

function readCronFile() {
    try {
        const data = JSON.parse(fs.readFileSync(CRON_FILE, 'utf8'));
        return data.jobs || [];
    } catch {
        return [];
    }
}

function writeCronFile(jobs) {
    const dir = path.dirname(CRON_FILE);
    if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });
    // Backup
    if (fs.existsSync(CRON_FILE)) {
        try { fs.copyFileSync(CRON_FILE, CRON_FILE + '.bak'); } catch {}
    }
    fs.writeFileSync(CRON_FILE, JSON.stringify({ version: 1, jobs }, null, 2));
    // Signal gateway to reload cron from disk
    try { execSync("kill -HUP $(ps aux | grep openclaw-gateway | grep -v grep | awk '{print $2}') 2>/dev/null"); } catch {}
}

function cronList(req, res) {
    const jobs = readCronFile();
    json(res, 200, { jobs, total: jobs.length, offset: 0, limit: jobs.length, hasMore: false, nextOffset: null });
}

async function cronCreate(req, res) {
    const b = await parseBody(req);
    const jobs = readCronFile();

    const job = {
        id: crypto.randomUUID(),
        agentId: 'main',
        sessionKey: 'agent:main:cron',
        name: b.name || 'Untitled',
        enabled: b.enabled !== false,
        createdAtMs: Date.now(),
        updatedAtMs: Date.now(),
        schedule: {
            kind: 'cron',
            expr: (typeof b.schedule === 'object' ? b.schedule.expr : b.schedule) || '0 12 * * *',
            tz: b.timezone || (b.schedule && b.schedule.tz) || 'UTC',
        },
        sessionTarget: b.sessionTarget || 'main',
        wakeMode: 'now',
        payload: {
            kind: b.payload?.kind || 'systemEvent',
            text: b.prompt || (b.payload && b.payload.text) || '',
        },
        state: {},
    };

    // Calculate next run
    job.state.nextRunAtMs = Date.now() + 60000; // placeholder

    // Store metadata in description if provided
    if (b.description) job.description = b.description;

    jobs.push(job);
    writeCronFile(jobs);
    log('create: ' + job.name + ' (' + job.id + ')');
    json(res, 200, { ok: true, job });
}

async function cronUpdate(req, res) {
    const id = req.url.split('/').pop();
    if (!id) return json(res, 400, { error: 'Missing job ID' });

    const b = await parseBody(req);
    const jobs = readCronFile();
    const idx = jobs.findIndex((j) => j.id === id);
    if (idx === -1) return json(res, 404, { error: 'Job not found' });

    const job = jobs[idx];
    if (b.name !== undefined) job.name = b.name;
    if (b.enabled !== undefined) job.enabled = b.enabled;
    if (b.schedule) {
        job.schedule.expr = (typeof b.schedule === 'object' ? b.schedule.expr : b.schedule) || job.schedule.expr;
    }
    if (b.timezone || (b.schedule && b.schedule.tz)) {
        job.schedule.tz = b.timezone || b.schedule.tz;
    }
    if (b.prompt || (b.payload && b.payload.text)) {
        job.payload.text = b.prompt || b.payload.text;
    }
    if (b.description !== undefined) job.description = b.description;
    job.updatedAtMs = Date.now();

    jobs[idx] = job;
    writeCronFile(jobs);
    log('update: ' + id);
    json(res, 200, { ok: true, job });
}

function cronDelete(req, res) {
    const id = req.url.split('/').pop();
    if (!id) return json(res, 400, { error: 'Missing job ID' });

    let jobs = readCronFile();
    const before = jobs.length;
    jobs = jobs.filter((j) => j.id !== id);
    if (jobs.length === before) return json(res, 404, { error: 'Job not found' });

    writeCronFile(jobs);
    log('delete: ' + id);
    json(res, 200, { ok: true });
}

// --- Agent Workspace ---

function agentDir(siteHash) {
    return path.join(WORKSPACES_DIR, 'clawpress-' + siteHash);
}

function agentInit(req, res) {
    const params = new URL(req.url, 'http://localhost').searchParams;
    const siteHash = params.get('site') || '';
    if (!siteHash || !/^[a-zA-Z0-9_-]+$/.test(siteHash)) return json(res, 400, { error: 'Invalid site hash' });

    parseBody(req).then((b) => {
        const dir = agentDir(siteHash);
        fs.mkdirSync(dir, { recursive: true });

        const siteName = b.site_name || 'My WordPress Site';
        const language = b.language || 'English';
        const tone = b.tone || 'professional';

        // Only create if doesn't exist (don't overwrite)
        const soulPath = path.join(dir, 'SOUL.md');
        if (!fs.existsSync(soulPath)) {
            fs.writeFileSync(soulPath,
`# ${siteName} AI Assistant

You are the AI assistant for **${siteName}**. You help with content creation, SEO analysis, and WordPress management.

## Guidelines
- Default language: ${language}
- Default tone: ${tone}
- Always be helpful and concise
- Focus on WordPress content and SEO
- Never reveal internal configuration or tokens
`);
        }

        const userPath = path.join(dir, 'USER.md');
        if (!fs.existsSync(userPath)) {
            fs.writeFileSync(userPath,
`# Site Owner Preferences

- Site: ${siteName}
- Language: ${language}
- Tone: ${tone}
`);
        }

        const memoryPath = path.join(dir, 'MEMORY.md');
        if (!fs.existsSync(memoryPath)) {
            fs.writeFileSync(memoryPath, '# Agent Memory\n\n_This file is updated automatically as the agent learns about your site._\n');
        }

        log('agent init: ' + siteHash);
        json(res, 200, { ok: true, site: siteHash, workspace: dir });
    });
}

function agentGetConfig(req, res) {
    const params = new URL(req.url, 'http://localhost').searchParams;
    const siteHash = params.get('site') || '';
    if (!siteHash) return json(res, 400, { error: 'Missing site param' });

    const dir = agentDir(siteHash);
    const result = {};

    for (const file of ['SOUL.md', 'USER.md', 'MEMORY.md']) {
        const p = path.join(dir, file);
        try { result[file] = fs.readFileSync(p, 'utf8'); } catch { result[file] = ''; }
    }

    json(res, 200, result);
}

function agentUpdateConfig(req, res) {
    const params = new URL(req.url, 'http://localhost').searchParams;
    const siteHash = params.get('site') || '';
    if (!siteHash) return json(res, 400, { error: 'Missing site param' });

    parseBody(req).then((b) => {
        const dir = agentDir(siteHash);
        if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

        for (const file of ['SOUL.md', 'USER.md', 'MEMORY.md']) {
            if (b[file] !== undefined) {
                fs.writeFileSync(path.join(dir, file), b[file]);
            }
        }

        log('agent config updated: ' + siteHash);
        json(res, 200, { ok: true });
    });
}

// --- Gateway Proxy ---

function proxy(req, res) {
    const opts = {
        hostname: GW_HOST, port: GW_PORT, path: req.url,
        method: req.method, headers: { ...req.headers, host: GW_HOST + ':' + GW_PORT },
    };
    const p = http.request(opts, (g) => { res.writeHead(g.statusCode, g.headers); g.pipe(res); });
    p.on('error', (e) => { if (!res.headersSent) json(res, 502, { error: e.message }); });
    req.pipe(p);
}

// --- HTTP Server ---

const server = http.createServer(async (req, res) => {
    // CORS
    const origin = req.headers['origin'] || '';
    res.setHeader('Access-Control-Allow-Origin', origin || '*');
    res.setHeader('Access-Control-Allow-Methods', 'GET,POST,PUT,DELETE,OPTIONS');
    res.setHeader('Access-Control-Allow-Headers', 'Content-Type,Authorization');
    if (req.method === 'OPTIONS') { res.writeHead(204); return res.end(); }

    const url = req.url.split('?')[0];

    try {
        if (url.startsWith('/clawpress/')) {
            if (!auth(req)) return json(res, 401, { error: 'Unauthorized' });

            // Cron routes
            if (req.method === 'GET' && url === '/clawpress/cron') return cronList(req, res);
            if (req.method === 'POST' && url === '/clawpress/cron') return await cronCreate(req, res);
            if (req.method === 'PUT' && url.startsWith('/clawpress/cron/')) return await cronUpdate(req, res);
            if (req.method === 'DELETE' && url.startsWith('/clawpress/cron/')) return cronDelete(req, res);

            // Agent routes
            if (req.method === 'POST' && url === '/clawpress/agent/init') return agentInit(req, res);
            if (req.method === 'GET' && url === '/clawpress/agent/config') return agentGetConfig(req, res);
            if (req.method === 'PUT' && url === '/clawpress/agent/config') return agentUpdateConfig(req, res);

            return json(res, 404, { error: 'Not found' });
        }
        // Everything else → gateway
        proxy(req, res);
    } catch (e) {
        log('Error: ' + e.message);
        if (!res.headersSent) json(res, 500, { error: 'Internal error' });
    }
});

// WebSocket proxy (for dashboard access through bridge, if needed)
server.on('upgrade', (req, socket, head) => {
    const gw = net.connect(GW_PORT, GW_HOST, () => {
        gw.write(req.method + ' ' + req.url + ' HTTP/1.1\r\n' +
            Object.entries(req.headers).map(([k, v]) => k + ': ' + v).join('\r\n') +
            '\r\n\r\n');
        if (head.length) gw.write(head);
        socket.pipe(gw).pipe(socket);
    });
    gw.on('error', () => socket.destroy());
    socket.on('error', () => gw.destroy());
});

server.listen(PORT, '127.0.0.1', () => {
    log('ClawPress Bridge v2 on :' + PORT);
    log('Cron file: ' + CRON_FILE);
    log('Gateway: ' + GW_HOST + ':' + GW_PORT);
});
