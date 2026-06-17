#!/usr/bin/env bash
# =============================================================================
# tacticalrmm.sh — acme.sh deploy hook for Tactical RMM
#
# Copies renewed certificates to /etc/ssl/tacticalrmm/, sets permissions,
# and restarts the Tactical RMM service stack.
#
# Usage:
#   Place this file in ~/.acme.sh/deploy/tacticalrmm.sh
#   Then run: acme.sh --deploy --deploy-hook tacticalrmm -d your-api-domain.com --ecc
#
# Variables set automatically by acme.sh at deploy time:
#   $Le_Domain           — primary domain (e.g. api.yourdomain.com)
#   $CERT_KEY_PATH       — path to the private key
#   $CERT_FULLCHAIN_PATH — path to the full chain certificate
#
# Repo: https://github.com/jevellangelo/tacticalrmm-ssl-automation
# =============================================================================

PROD_DIR="/etc/ssl/tacticalrmm"
PROD_CERT_PATH="${PROD_DIR}/fullchain.pem"
PROD_KEY_PATH="${PROD_DIR}/privkey.pem"
TRMM_USER="tactical"

tacticalrmm_deploy() {
  echo "------------------------------------------------------------"
  echo " Tactical RMM SSL Deploy Hook"
  echo " Domain : $Le_Domain"
  echo " Target : $PROD_DIR"
  echo "------------------------------------------------------------"

  # Bail out early if acme.sh didn't pass the expected variables
  if [[ -z "$CERT_FULLCHAIN_PATH" || -z "$CERT_KEY_PATH" ]]; then
    echo "ERROR: Certificate path variables are empty."
    echo "Make sure this file is in ~/.acme.sh/deploy/ and is being"
    echo "called via: acme.sh --deploy --deploy-hook tacticalrmm"
    return 1
  fi

  # Create destination directory if it doesn't exist
  if [[ ! -d "$PROD_DIR" ]]; then
    echo "Creating $PROD_DIR..."
    mkdir -p "$PROD_DIR"
  fi

  # Copy the renewed certificates into place
  echo "Copying certificates..."
  cp "$CERT_FULLCHAIN_PATH" "$PROD_CERT_PATH" || { echo "ERROR: Failed to copy fullchain cert."; return 1; }
  cp "$CERT_KEY_PATH"       "$PROD_KEY_PATH"  || { echo "ERROR: Failed to copy private key.";   return 1; }

  # Set ownership and permissions
  echo "Setting permissions (owner: ${TRMM_USER})..."
  chown "${TRMM_USER}:${TRMM_USER}" "$PROD_CERT_PATH" "$PROD_KEY_PATH"
  chmod 440 "$PROD_CERT_PATH" "$PROD_KEY_PATH"

  # Validate Nginx config before restarting
  echo "Validating Nginx config..."
  if ! nginx -t > /dev/null 2>&1; then
    echo "ERROR: Nginx config test failed. Aborting service restart."
    echo "Run 'nginx -t' to see the specific error."
    return 1
  fi

  # Reload Nginx gracefully — no dropped connections.
  # Nginx picks up new SSL certs on reload without a full restart.
  echo "  Reloading nginx..."
  if systemctl reload nginx; then
    echo "  ✓ nginx reloaded"
  else
    echo "  ✗ nginx failed to reload — check: journalctl -xeu nginx"
  fi

  # Application services need a full restart to pick up the new cert
  echo "Restarting Tactical RMM application services..."
  for svc in meshcentral rmm daphne; do
    if systemctl restart "$svc"; then
      echo "  ✓ $svc restarted"
    else
      echo "  ✗ $svc failed to restart — check: journalctl -xeu $svc"
    fi
  done

  echo "------------------------------------------------------------"
  echo " Deploy complete."
  echo "------------------------------------------------------------"
  return 0
}
