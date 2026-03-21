#!/usr/bin/env node
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');
const os = require('os');

const cmd = process.argv[2] || 'start';

const SERVICE_NAME = 'clawpress-bridge';
const BRIDGE_PATH = path.resolve(__dirname, '..', 'index.js');

if (cmd === 'start' || cmd === undefined) {
    console.log('Starting ClawPress Bridge...');
    require('../index.js');

} else if (cmd === 'install') {
    if (os.platform() !== 'linux' && os.platform() !== 'darwin') {
        console.log('Auto-install is for Linux/macOS.');
        console.log('On Windows, run: clawpress-bridge start');
        process.exit(0);
    }

    if (os.platform() === 'linux') {
        const serviceDir = path.join(os.homedir(), '.config', 'systemd', 'user');
        const servicePath = path.join(serviceDir, `${SERVICE_NAME}.service`);
        const nodePath = execSync('which node').toString().trim();

        const unit = `[Unit]
Description=ClawPress Bridge
After=network.target

[Service]
ExecStart=${nodePath} ${BRIDGE_PATH}
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=default.target
`;
        fs.mkdirSync(serviceDir, { recursive: true });
        fs.writeFileSync(servicePath, unit);
        execSync('systemctl --user daemon-reload');
        execSync(`systemctl --user enable --now ${SERVICE_NAME}`);
        console.log('ClawPress Bridge installed and running.');
        console.log('');
        console.log('  Status:  systemctl --user status clawpress-bridge');
        console.log('  Restart: systemctl --user restart clawpress-bridge');
        console.log('  Stop:    systemctl --user stop clawpress-bridge');
    }

} else if (cmd === 'uninstall') {
    if (os.platform() === 'linux') {
        try { execSync(`systemctl --user stop ${SERVICE_NAME} 2>/dev/null`); } catch {}
        try { execSync(`systemctl --user disable ${SERVICE_NAME} 2>/dev/null`); } catch {}
        const sp = path.join(os.homedir(), '.config', 'systemd', 'user', `${SERVICE_NAME}.service`);
        if (fs.existsSync(sp)) fs.unlinkSync(sp);
        try { execSync('systemctl --user daemon-reload'); } catch {}
        console.log('ClawPress Bridge uninstalled.');
    }

} else if (cmd === 'status') {
    if (os.platform() === 'linux') {
        try {
            console.log(execSync(`systemctl --user status ${SERVICE_NAME} 2>&1`).toString());
        } catch (e) {
            console.log(e.stdout?.toString() || 'Not installed. Run: clawpress-bridge install');
        }
    }

} else if (cmd === 'help' || cmd === '--help' || cmd === '-h') {
    console.log(`
ClawPress Bridge — connects WordPress to OpenClaw cron API

Usage:
  clawpress-bridge              Start bridge (foreground)
  clawpress-bridge install      Install as system service (Linux)
  clawpress-bridge uninstall    Remove system service
  clawpress-bridge status       Show service status

The bridge reads your OpenClaw token from ~/.openclaw/openclaw.json
and listens on port 18790 (configurable via BRIDGE_PORT env var).

Your nginx should proxy /clawpress/* to port 18790.
`);

} else {
    console.error(`Unknown command: ${cmd}. Run: clawpress-bridge help`);
    process.exit(1);
}
