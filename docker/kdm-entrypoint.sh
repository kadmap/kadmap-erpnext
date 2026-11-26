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
until mariadb-admin ping -h "${DB_HOST}" -u root --password="${MYSQL_ROOT_PASSWORD:-}" --skip-ssl --silent 2>/dev/null; do
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

# ── Set public server URL ──────────────────────────────────────────────────────
# APP_PUBLIC_URL is injected by the KDM provisioner and is the URL the browser
# uses to reach this ERPNext instance.
#
# frappe_server_url — used by Frappe for OAuth2 redirects and email links.
# cdn_url           — used by Frappe to build ALL static asset URLs in HTML.
#                     Without this, Frappe emits /assets/... paths that the
#                     browser requests without the KDM sub-path prefix, causing
#                     CSS/JS to 404 through the KDM nginx gateway.
if [ -n "${APP_PUBLIC_URL:-}" ]; then
    log "Setting frappe_server_url and cdn_url to ${APP_PUBLIC_URL} ..."
    ${BENCH} set-config frappe_server_url "${APP_PUBLIC_URL}"
    ${BENCH} set-config cdn_url "${APP_PUBLIC_URL}"
fi

# ── Disable password login ─────────────────────────────────────────────────────
log "Disabling password-based login ..."
${BENCH} set-config disable_user_pass_login 1

# ── Seed Authentik OIDC provider ───────────────────────────────────────────────
log "Seeding Authentik OIDC provider ..."
${BENCH} execute erpnext.kdm_auth.setup.seed_authentik_provider

log "OIDC configuration complete.  Starting: $*"

# ── Set default site so bench serve routes all requests to this site ───────────
# bench use writes default_site into common_site_config.json. bench serve
# (and Frappe's WSGI app) reads that as the fallback when no matching site
# directory exists for the incoming Host header.
bench use "${SITE}"

# ── Hand off to the main process ──────────────────────────────────────────────
exec "$@"
