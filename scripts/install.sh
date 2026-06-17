#!/usr/bin/env bash
# =============================================================================
# install.sh — Guided setup for Tactical RMM SSL automation
#              using acme.sh + acme-dns + Let's Encrypt
#
# Run as root on your Tactical RMM server.
# Repo: https://github.com/jevellangelo/tacticalrmm-ssl-automation
# =============================================================================

set -euo pipefail

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
prompt()  { echo -e "${BOLD}$*${NC}"; }

divider() { echo -e "\n${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}\n"; }

confirm() {
  local msg="$1"
  read -rp "$(echo -e "${YELLOW}${msg} [y/N]: ${NC}")" ans
  [[ "${ans,,}" == "y" ]]
}

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "This script must be run as root. Try: sudo bash install.sh"
fi

# ── Banner ────────────────────────────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ████████╗██████╗ ███╗   ███╗███╗   ███╗    ███████╗███████╗██╗
  ╚══██╔══╝██╔══██╗████╗ ████║████╗ ████║    ██╔════╝██╔════╝██║
     ██║   ██████╔╝██╔████╔██║██╔████╔██║    ███████╗███████╗██║
     ██║   ██╔══██╗██║╚██╔╝██║██║╚██╔╝██║    ╚════██║╚════██║██║
     ██║   ██║  ██║██║ ╚═╝ ██║██║ ╚═╝ ██║    ███████║███████║███████╗
     ╚═╝   ╚═╝  ╚═╝╚═╝     ╚═╝╚═╝     ╚═╝    ╚══════╝╚══════╝╚══════╝
EOF
echo -e "${NC}"
echo -e "${BOLD}  Tactical RMM SSL Automation — Guided Setup${NC}"
echo -e "  acme.sh + acme-dns + Let's Encrypt + Deploy Hook\n"
echo -e "  This script will walk you through replacing Certbot with a"
echo -e "  fully automated, zero-touch SSL renewal pipeline.\n"
divider

# ── Preflight checks ──────────────────────────────────────────────────────────
info "Running preflight checks..."

command -v nginx    >/dev/null 2>&1 || error "Nginx not found. Is Tactical RMM installed?"
command -v systemctl>/dev/null 2>&1 || error "systemd not found."
[[ -d /rmm ]]                       || error "/rmm directory not found. Is Tactical RMM installed?"
id tactical >/dev/null 2>&1         || error "'tactical' user not found."

success "Preflight checks passed."
divider

# ── Collect inputs ────────────────────────────────────────────────────────────
prompt "Step 1 of 9 — Your domain information\n"

read -rp "$(echo -e "${BOLD}API subdomain${NC}      (e.g. api.yourdomain.com): ")" API_DOMAIN
read -rp "$(echo -e "${BOLD}RMM subdomain${NC}      (e.g. rmm.yourdomain.com): ")" RMM_DOMAIN
read -rp "$(echo -e "${BOLD}Mesh subdomain${NC}     (e.g. mesh.yourdomain.com): ")" MESH_DOMAIN
read -rp "$(echo -e "${BOLD}Email address${NC}      (for Let's Encrypt account): ")" ACME_EMAIL
read -rp "$(echo -e "${BOLD}acme-dns server URL${NC} (e.g. https://acmedns.example.com): ")" ACMEDNS_URL

echo ""
info "Summary of what will be configured:"
echo -e "  API domain   : ${CYAN}${API_DOMAIN}${NC}"
echo -e "  RMM domain   : ${CYAN}${RMM_DOMAIN}${NC}"
echo -e "  Mesh domain  : ${CYAN}${MESH_DOMAIN}${NC}"
echo -e "  Email        : ${CYAN}${ACME_EMAIL}${NC}"
echo -e "  acme-dns URL : ${CYAN}${ACMEDNS_URL}${NC}"
echo ""
confirm "Does this look correct?" || error "Aborted. Re-run the script to start over."
divider

# ── Step 1: Install acme.sh ───────────────────────────────────────────────────
prompt "Step 2 of 9 — Install acme.sh\n"

if [[ -f /root/.acme.sh/acme.sh ]]; then
  success "acme.sh is already installed."
else
  info "Installing acme.sh..."
  curl -fsSL https://get.acme.sh | sh -s "email=${ACME_EMAIL}"
  success "acme.sh installed."
fi

# Ensure acme.sh is on PATH for this session
export PATH="$PATH:/root/.acme.sh"
divider

# ── Step 2: Set Let's Encrypt as default CA ───────────────────────────────────
prompt "Step 3 of 9 — Set Let's Encrypt as default CA\n"
info "Switching default CA from ZeroSSL to Let's Encrypt..."
acme.sh --set-default-ca --server letsencrypt
success "Let's Encrypt set as default CA."
divider

# ── Step 3: Persist acme-dns URL ──────────────────────────────────────────────
prompt "Step 4 of 9 — Configure acme-dns\n"
info "Persisting ACMEDNS_BASE_URL to shell profile and acme.sh environment..."

grep -q "ACMEDNS_BASE_URL" /root/.bashrc 2>/dev/null || \
  echo "export ACMEDNS_BASE_URL=\"${ACMEDNS_URL}\"" >> /root/.bashrc

grep -q "ACMEDNS_BASE_URL" /root/.acme.sh/acme.sh.env 2>/dev/null || \
  echo "export ACMEDNS_BASE_URL=\"${ACMEDNS_URL}\"" >> /root/.acme.sh/acme.sh.env

export ACMEDNS_BASE_URL="${ACMEDNS_URL}"
success "ACMEDNS_BASE_URL set to: ${ACMEDNS_URL}"

if [[ "$ACMEDNS_URL" == http://* ]] && [[ "$ACMEDNS_URL" != *"127.0.0.1"* ]] && [[ "$ACMEDNS_URL" != *"localhost"* ]]; then
  warn "You are using plaintext HTTP for a remote acme-dns server."
  warn "Registration credentials will travel unencrypted over the network."
  warn "Strongly consider putting acme-dns behind HTTPS or a VPN tunnel."
  confirm "Continue anyway?" || error "Aborted. Update ACMEDNS_BASE_URL to an HTTPS address and re-run."
fi
divider

# ── Step 4: Register each subdomain individually ──────────────────────────────
prompt "Step 5 of 9 — Register subdomains with acme-dns\n"
warn "Each subdomain must be registered separately."
warn "After each command, acme.sh will print a CNAME record."
warn "Add it to your DNS registrar BEFORE pressing Enter to continue.\n"

for DOMAIN in "$API_DOMAIN" "$RMM_DOMAIN" "$MESH_DOMAIN"; do
  DOMAIN_DIR="/root/.acme.sh/${DOMAIN}_ecc"
  if [[ -f "${DOMAIN_DIR}/${DOMAIN}.conf" ]] && grep -q "ACMEDNS_USERNAME" "${DOMAIN_DIR}/${DOMAIN}.conf" 2>/dev/null; then
    success "${DOMAIN} is already registered with acme-dns — skipping."
  else
    info "Registering ${DOMAIN}..."
    echo ""
    acme.sh --issue --dns dns_acmedns -d "$DOMAIN" --server letsencrypt || true
    echo ""
    warn "Add the CNAME record shown above to your DNS registrar for ${DOMAIN}."
    read -rp "$(echo -e "${YELLOW}Press Enter once the CNAME record has been added...${NC}")"
  fi
done

success "All three subdomains registered."
divider

# ── Step 5: Issue the unified SAN certificate ─────────────────────────────────
prompt "Step 6 of 9 — Issue unified SAN certificate\n"
info "Issuing a single certificate covering all three subdomains..."

acme.sh --issue --dns dns_acmedns \
  -d "$API_DOMAIN" \
  -d "$RMM_DOMAIN" \
  -d "$MESH_DOMAIN" \
  --server letsencrypt \
  --dnssleep 0 || true

success "Certificate issued."
divider

# ── Step 6: Install the deploy hook ──────────────────────────────────────────
prompt "Step 7 of 9 — Install deploy hook\n"

DEPLOY_DIR="/root/.acme.sh/deploy"
HOOK_SRC="$(dirname "$0")/../deploy/tacticalrmm.sh"
HOOK_DST="${DEPLOY_DIR}/tacticalrmm.sh"

mkdir -p "$DEPLOY_DIR"

if [[ -f "$HOOK_SRC" ]]; then
  cp "$HOOK_SRC" "$HOOK_DST"
  info "Copied deploy hook from repo."
else
  # Fallback: write the hook inline if the file isn't alongside this script
  warn "deploy/tacticalrmm.sh not found next to this script — writing inline fallback."
  cat > "$HOOK_DST" << 'HOOK'
#!/usr/bin/env bash
PROD_DIR="/etc/ssl/tacticalrmm"
PROD_CERT_PATH="${PROD_DIR}/fullchain.pem"
PROD_KEY_PATH="${PROD_DIR}/privkey.pem"
TRMM_USER="tactical"

tacticalrmm_deploy() {
  if [[ -z "$CERT_FULLCHAIN_PATH" || -z "$CERT_KEY_PATH" ]]; then
    echo "ERROR: Certificate path variables are empty."; return 1
  fi
  mkdir -p "$PROD_DIR"
  cp "$CERT_FULLCHAIN_PATH" "$PROD_CERT_PATH" || return 1
  cp "$CERT_KEY_PATH"       "$PROD_KEY_PATH"  || return 1
  chown "${TRMM_USER}:${TRMM_USER}" "$PROD_CERT_PATH" "$PROD_KEY_PATH"
  chmod 440 "$PROD_CERT_PATH" "$PROD_KEY_PATH"
  nginx -t > /dev/null 2>&1 || { echo "ERROR: Nginx config invalid."; return 1; }
  systemctl reload nginx
  for svc in meshcentral rmm daphne; do systemctl restart "$svc"; done
  return 0
}
HOOK
fi

chmod +x "$HOOK_DST"
success "Deploy hook installed at ${HOOK_DST}"

# Do first-run manual copy so Nginx doesn't fail before hook runs
info "Copying certificates to /etc/ssl/tacticalrmm/ for the first time..."
mkdir -p /etc/ssl/tacticalrmm
ACME_DIR="/root/.acme.sh/${API_DOMAIN}_ecc"
cp "${ACME_DIR}/fullchain.cer"      /etc/ssl/tacticalrmm/fullchain.pem
cp "${ACME_DIR}/${API_DOMAIN}.key"  /etc/ssl/tacticalrmm/privkey.pem
chown tactical:tactical /etc/ssl/tacticalrmm/*.pem
chmod 440 /etc/ssl/tacticalrmm/*.pem
success "Certificates copied to /etc/ssl/tacticalrmm/"

# Link the hook permanently
info "Binding deploy hook to certificate..."
acme.sh --deploy --deploy-hook tacticalrmm -d "$API_DOMAIN" --ecc
success "Deploy hook linked."
divider

# ── Step 7: Update Nginx configs ──────────────────────────────────────────────
prompt "Step 8 of 9 — Update Nginx certificate paths\n"
info "Updating ssl_certificate paths in /etc/nginx/sites-enabled/..."

CHANGED=0
for conf in /etc/nginx/sites-enabled/*.conf; do
  if grep -q "/etc/letsencrypt" "$conf" 2>/dev/null; then
    sed -i \
      -e 's|ssl_certificate .*letsencrypt.*fullchain.*|ssl_certificate /etc/ssl/tacticalrmm/fullchain.pem;|g' \
      -e 's|ssl_certificate_key .*letsencrypt.*privkey.*|ssl_certificate_key /etc/ssl/tacticalrmm/privkey.pem;|g' \
      "$conf"
    success "Updated: $conf"
    CHANGED=$((CHANGED + 1))
  fi
done

if [[ $CHANGED -eq 0 ]]; then
  warn "No Nginx configs with Certbot paths found — you may need to update them manually."
  warn "Look for ssl_certificate lines in /etc/nginx/sites-enabled/*.conf"
fi

info "Validating Nginx config..."
nginx -t && systemctl reload nginx
success "Nginx reloaded."

info "Restarting Tactical RMM application services..."
for svc in meshcentral rmm daphne; do
  if systemctl restart "$svc"; then
    success "$svc restarted"
  else
    warn "$svc failed to restart — check: journalctl -xeu $svc"
  fi
done
divider

# ── Step 8: Done ──────────────────────────────────────────────────────────────
prompt "Step 9 of 9 — Verify\n"
info "Running a forced renewal to test the full pipeline..."
acme.sh --renew -d "$API_DOMAIN" --force --ecc

divider
echo -e "${GREEN}${BOLD}  Setup complete!${NC}\n"
echo -e "  Your certificates live at:"
echo -e "    ${CYAN}/etc/ssl/tacticalrmm/fullchain.pem${NC}"
echo -e "    ${CYAN}/etc/ssl/tacticalrmm/privkey.pem${NC}\n"
echo -e "  acme.sh will check for renewals daily via cron."
echo -e "  Check the renewal log anytime with:\n"
echo -e "    ${CYAN}tail -f /root/.acme.sh/acme.sh.log${NC}\n"
echo -e "  To enable Slack notifications, run:"
echo -e "    ${CYAN}export SLACK_WEBHOOK_URL=\"https://hooks.slack.com/services/...\"\n    acme.sh --set-notify --notify-hook slack${NC}\n"
divider
