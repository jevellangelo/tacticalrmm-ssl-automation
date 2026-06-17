# tacticalrmm-ssl-automation

Automated SSL certificate renewal for [Tactical RMM](https://docs.tacticalrmm.com) using **acme.sh**, **acme-dns**, and **Let's Encrypt** — with a deploy hook that copies certs, fixes permissions, and restarts services automatically.

> 📖 **Full write-up:** [Never Manually Renew an SSL Certificate Again — Tactical RMM + acme.sh + acme-dns](https://lab.acebedo.us/never-manually-renew-an-ssl-certificate-again-tactical-rmm-acme-sh-acme-dns/)

---

## What This Does

Replaces Certbot with a zero-touch renewal pipeline:

```
Daily cron → acme.sh → acme-dns (DNS-01 challenge) → Let's Encrypt
                                                            ↓
                                                   deploy hook runs
                                                            ↓
                                          certs copied to /etc/ssl/tacticalrmm/
                                          services restarted
                                          Slack notification sent ✓
```

**Why acme-dns instead of a direct DNS API?**
Storing Cloudflare or Route53 API keys on your RMM server means a compromised host can modify your entire DNS zone. acme-dns isolates that risk — it can only update `_acme-challenge` TXT records, and your registrar credentials never touch the RMM box.

---

## Repo Structure

```
tacticalrmm-ssl-automation/
├── deploy/
│   └── tacticalrmm.sh   ← acme.sh deploy hook (copy to ~/.acme.sh/deploy/)
├── scripts/
│   └── install.sh       ← guided interactive setup script
└── README.md
```

---

## Quick Start

### Option A — Guided install script (recommended)

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/tacticalrmm-ssl-automation.git
cd tacticalrmm-ssl-automation
sudo bash scripts/install.sh
```

The script walks through every step interactively, prompts you to add CNAME records at the right moment, and runs a test renewal at the end.

**Prerequisites before running:**
- Tactical RMM installed and running
- A self-hosted [acme-dns](https://github.com/joohoi/acme-dns) server reachable from the RMM host
- Root access to the RMM server

---

### Option B — Manual setup (condensed)

**1. Install acme.sh and set Let's Encrypt as default CA**
```bash
curl https://get.acme.sh | sh -s email=you@example.com
source ~/.bashrc
acme.sh --set-default-ca --server letsencrypt
```

**2. Persist your acme-dns URL**
```bash
echo 'export ACMEDNS_BASE_URL="http://your-acmedns-server:8181"' >> /root/.bashrc
echo 'export ACMEDNS_BASE_URL="http://your-acmedns-server:8181"' >> /root/.acme.sh/acme.sh.env
source /root/.bashrc
```

> **HTTP vs HTTPS:** If your acme-dns server is on a separate, network-exposed machine, prefer `https://` and put acme-dns behind a reverse proxy with a valid cert. HTTP is acceptable if access to port 8181 is restricted by firewall rules, if traffic runs over a WireGuard/Tailscale tunnel, or if acme-dns is bound to localhost on the same host.

**3. Register each subdomain individually**

> ⚠️ Do these **one at a time**. After each command, acme.sh prints a CNAME record — add it to your registrar before pressing Enter. Each subdomain needs its own unique CNAME target.

```bash
acme.sh --issue --dns dns_acmedns -d api.yourdomain.com --server letsencrypt
acme.sh --issue --dns dns_acmedns -d rmm.yourdomain.com --server letsencrypt
acme.sh --issue --dns dns_acmedns -d mesh.yourdomain.com --server letsencrypt
```

**4. Issue the unified SAN certificate**
```bash
acme.sh --issue --dns dns_acmedns \
  -d api.yourdomain.com \
  -d rmm.yourdomain.com \
  -d mesh.yourdomain.com \
  --server letsencrypt \
  --dnssleep 0
```

**5. Install the deploy hook**
```bash
cp deploy/tacticalrmm.sh /root/.acme.sh/deploy/tacticalrmm.sh

# First-time manual copy
mkdir -p /etc/ssl/tacticalrmm
cp /root/.acme.sh/api.yourdomain.com_ecc/fullchain.cer /etc/ssl/tacticalrmm/fullchain.pem
cp /root/.acme.sh/api.yourdomain.com_ecc/api.yourdomain.com.key /etc/ssl/tacticalrmm/privkey.pem
chown tactical:tactical /etc/ssl/tacticalrmm/*.pem
chmod 440 /etc/ssl/tacticalrmm/*.pem

# Bind the hook permanently
acme.sh --deploy --deploy-hook tacticalrmm -d api.yourdomain.com --ecc
```

> **Note:** The deploy hook uses `systemctl reload nginx` (graceful, no dropped connections) and `systemctl restart` for meshcentral, rmm, and daphne (full restart required for those services to pick up the new cert).

**6. Update Nginx to point at the new cert location**

In each file under `/etc/nginx/sites-enabled/`, replace:
```nginx
ssl_certificate /etc/letsencrypt/live/yourdomain.com/fullchain.pem;
ssl_certificate_key /etc/letsencrypt/live/yourdomain.com/privkey.pem;
```
With:
```nginx
ssl_certificate /etc/ssl/tacticalrmm/fullchain.pem;
ssl_certificate_key /etc/ssl/tacticalrmm/privkey.pem;
```

Then test and reload:
```bash
nginx -t && systemctl reload nginx
```

**7. Update Tactical RMM's internal cert paths**

> Tactical RMM's `update.sh` rebuilds Nginx configs from its database. If you skip this, the next upgrade will reset your cert paths back to the Certbot location.

```bash
cd /rmm/api/tacticalrmm
source ../env/bin/activate

# Check if set_config is available on your install first:
python manage.py help | grep config

python manage.py set_config certfile /etc/ssl/tacticalrmm/fullchain.pem
python manage.py set_config keyfile /etc/ssl/tacticalrmm/privkey.pem
deactivate
```

If `set_config` isn't available, append to `local_settings.py` instead:
```python
CERT_FILE = "/etc/ssl/tacticalrmm/fullchain.pem"
KEY_FILE  = "/etc/ssl/tacticalrmm/privkey.pem"
```

**8. (Optional) Slack notifications**
```bash
export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
acme.sh --set-notify --notify-hook slack
```

**9. Test the full pipeline**
```bash
acme.sh --renew -d api.yourdomain.com --force --ecc
```

---

## Common Gotchas

| Problem | Cause | Fix |
|---|---|---|
| `NXDOMAIN` on second/third domain | Registered all three domains in a single command on first run | Register each subdomain individually (Step 3) |
| `retryafter=86400` error | ZeroSSL is the default CA | Run `acme.sh --set-default-ca --server letsencrypt` |
| Empty `cp` in deploy hook | Hook called with wrong variable names | Ensure the file is in `~/.acme.sh/deploy/` and uses `$CERT_FULLCHAIN_PATH` / `$CERT_KEY_PATH` |
| Nginx cert paths reset after `update.sh` | Database cert paths not updated, or `local_settings.py` overwritten by upgrade | Update via `set_config`; if using `local_settings.py`, verify those lines survive every upgrade |
| Agent connections dropping | Leaf cert served instead of fullchain | Always use `fullchain.cer`, not `api.yourdomain.com.cer` |
| `--ecc` flag errors | ECC and RSA certs stored in separate directories | Pass `--ecc` to every acme.sh command for this domain |
| `--ecc` flag errors | ECC and RSA certs stored in separate directories | Pass `--ecc` to every acme.sh command for this domain |

---

## Checking Renewal Logs

```bash
# acme.sh's own log
tail -f /root/.acme.sh/acme.sh.log

# Verify the cron job is active
crontab -l | grep acme.sh

# Capture cron output to a file (edit crontab -e)
# 48 18 * * * "/root/.acme.sh"/acme.sh --cron --home "/root/.acme.sh" >> /var/log/tactical-ssl-renew.log 2>&1
```

---

## References

- [acme.sh](https://github.com/acmesh-official/acme.sh)
- [acme-dns](https://github.com/joohoi/acme-dns)
- [Tactical RMM Documentation](https://docs.tacticalrmm.com)
- [Full blog post](https://lab.acebedo.us/never-manually-renew-an-ssl-certificate-again-tactical-rmm-acme-sh-acme-dns/)

---

## Contributing

Issues and PRs welcome — especially if acme.sh changes its deploy hook variable names or Tactical RMM changes its cert path management between versions.
