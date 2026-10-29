#!/bin/bash
# KDM ERPNext entrypoint
#
# Runs before the main process (web / worker / scheduler).
# On first run it creates the Frappe site, installs ERPNext, then seeds the
# Authentik OIDC config.  On subsequent runs it just applies any pending
# migrations and re-seeds the OIDC config (safe to call repeatedly).
#
# Required env vars (injected by MKDM pipeline at deploy time):
#   AUTHENTIK_URL           https://auth.yourdomain.local
#   OIDC_CLIENT_ID          client ID from the Authentik OAuth2 provider app
#   OIDC_CLIENT_SECRET      client secret from the Authentik OAuth2 provider app
#   MYSQL_ROOT_PASSWORD     MariaDB root password (only needed on first run)
#   FRAPPE_ADMIN_PASSWORD   ERPNext Administrator password (only needed on first run)
#
# Optional:
#   FRAPPE_SITE_NAME        site name in bench  (default: erpnext.localhost)
#   OIDC_APP_SLUG           Authentik app slug  (default: erpnext)
#   DB_HOST                 MariaDB host        (default: db)

set -euo pipefail

SITE="${FRAPPE_SITE_NAME:-erpnext.localhost}"
DB_HOST="${DB_HOST:-db}"

BENCH="bench --site ${SITE}"

log() { echo "[KDM] $*"; }

# ── Wait for MariaDB ───────────────────────────────────────────────────────────
log "Waiting for MariaDB on ${DB_HOST}:3306 ..."
until mariadb-admin ping -h "${DB_HOST}" -u root -p"${MYSQL_ROOT_PASSWORD:-}" --silent 2>/dev/null; do
    sleep 2
done
log "MariaDB is ready."

# ── First-run: create site + install ERPNext ───────────────────────────────────
SITE_DB_CONFIG="sites/${SITE}/site_config.json"

if [ ! -f "${SITE_DB_CONFIG}" ]; then
    log "First run detected — creating site: ${SITE}"

    bench new-site "${SITE}" \
        --db-host "${DB_HOST}" \
        --db-root-username root \
        --db-root-password "${MYSQL_ROOT_PASSWORD}" \
        --admin-password "${FRAPPE_ADMIN_PASSWORD}" \
        --install-app erpnext \
        --no-mariadb-socket

    log "Site created and ERPNext installed."
else
    log "Site already exists — running migrations."
    ${BENCH} migrate
fi

# ── Disable password login ─────────────────────────────────────────────────────
log "Disabling password-based login ..."
${BENCH} set-config disable_user_pass_login 1

# ── Seed Authentik OIDC provider ───────────────────────────────────────────────
log "Seeding Authentik OIDC provider ..."
${BENCH} execute erpnext.kdm_auth.setup.seed_authentik_provider

log "OIDC configuration complete.  Starting: $*"

# ── Hand off to the main process ──────────────────────────────────────────────
exec "$@"
