#!/bin/bash
# KDM ERPNext entrypoint
#
# Runs before the main process (web / worker / scheduler).
# On first run it creates the Frappe site and installs ERPNext.
# On subsequent runs it applies any pending migrations.
#
# Authentication is handled by Authentik OIDC, automatically provisioned at
# deploy time by the KDM provisioner. This script creates the Frappe Social
# Login Key from the injected env vars so the OIDC redirect flow works.
#
# Required env vars (injected by KDM provisioner):
#   MYSQL_ROOT_PASSWORD     MariaDB root password (only needed on first run)
#   FRAPPE_ADMIN_PASSWORD   ERPNext Administrator password (only needed on first run)
#   OIDC_CLIENT_ID          Authentik OAuth2 client ID
#   OIDC_CLIENT_SECRET      Authentik OAuth2 client secret
#   OIDC_APP_SLUG           Authentik application slug (e.g. erpnext-from-kadmap-ws-general)
#   AUTHENTIK_URL           Browser-facing KDM URL (e.g. https://kdm-serial.local)
#   APP_PUBLIC_URL          Public URL of this ERPNext instance
#
# Optional:
#   FRAPPE_SITE_NAME        site name in bench  (default: erpnext.localhost)
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

# ── Configure Authentik OIDC (creates/updates Social Login Key) ───────────────
# seed_authentik_provider creates the "Authentik" Social Login Key from the
# OIDC env vars injected by the provisioner.
# If env vars are missing (non-OIDC environment) the function exits with code 1
# — in that case we keep password login enabled rather than locking admins out.
log "Configuring Authentik OIDC provider ..."
if ${BENCH} execute erpnext.kdm_auth.setup.seed_authentik_provider; then
    log "Authentik OIDC configured. Disabling password-based login ..."
    ${BENCH} set-config disable_user_pass_login 1
else
    log "WARNING: OIDC not fully configured — password login remains enabled."
fi

log "KDM auth configured.  Starting: $*"

# ── Set default site so bench serve routes all requests to this site ───────────
# bench use writes default_site into common_site_config.json. bench serve
# (and Frappe's WSGI app) reads that as the fallback when no matching site
# directory exists for the incoming Host header.
bench use "${SITE}"

# ── Hand off to the main process ──────────────────────────────────────────────
exec "$@"
