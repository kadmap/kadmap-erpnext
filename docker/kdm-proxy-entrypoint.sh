#!/bin/sh
# KDM nginx proxy entrypoint for Frappe/ERPNext.
#
# Renders kdm-frappe-proxy.conf.template → /etc/nginx/conf.d/default.conf,
# substituting ONLY ${APP_SLUG} and ${WORKSPACE_SLUG_SAFE} from the environment.
# All other $var tokens (nginx request-time variables like $1, $host, $is_args,
# etc.) are intentionally left untouched so they resolve at nginx request time.
set -e

: "${APP_SLUG:?APP_SLUG must be set}"
: "${WORKSPACE_SLUG_SAFE:?WORKSPACE_SLUG_SAFE must be set}"

envsubst '${APP_SLUG} ${WORKSPACE_SLUG_SAFE}' \
    < /templates/kdm-frappe-proxy.conf.template \
    > /etc/nginx/conf.d/default.conf

exec nginx -g "daemon off;"
