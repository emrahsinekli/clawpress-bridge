---
name: setup-final-working
description: Final working setup flow - OpenClaw + Bridge + nginx + SSL. Pairing issue solved with SSH tunnel for dashboard.
type: project
---

## Final Working Setup (2026-03-21)

OpenClaw sıfırdan kurulum tamamlandı ve çalışıyor.

**Çalışan akış:**
1. Node.js 22 kur
2. `npm install -g openclaw`
3. `openclaw configure` (interaktif — DeepSeek key gir)
4. Tek blok script çalıştır: chatCompletions + gateway servisi + bridge + nginx + SSL
5. WordPress'e URL + Token yapıştır
6. Dashboard'a SSH tunnel ile bağlan

**Kritik bulgular:**
- OpenClaw pairing HTTPS dashboard bağlantısını engelliyor — config'den kapatılamıyor
- SSH tunnel ile localhost bağlantısı pairing bypass ediyor
- `openclaw cron` CLI de WebSocket ile bağlandığı için pairing lazım — bridge'in ilk çalışması için gateway restart sonrası bekleme gerekiyor
- Gateway yavaş başlıyor (10-20sn) — script'te `sleep` gerekli
- `ExecStart` path: `$(which openclaw)` kullan, hardcode etme — `/usr/bin/` veya `/usr/local/bin/` olabilir
- nginx: `/clawpress/*` → bridge (18790), geri kalan → gateway (18789) doğrudan
- `gateway.controlUi.allowedOrigins` ayarlanmalı
- `gateway.http.endpoints.chatCompletions.enabled true` şart

**Sunucu bilgileri:**
- IP: 37.148.211.92
- Token: 7ba127f11ceed23f556e2b78e62d4c58ff2535e793e3112e
- Domain: 37-148-211-92.sslip.io

**How to apply:** Bu bilgileri setup scriptinde ve guide'da kullan. Pairing sorununu kullanıcılara SSH tunnel olarak anlat.
