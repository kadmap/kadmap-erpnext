# KDM ERPNext — two-stage production build
#
# Stage 1 (builder): installs all tooling, clones Frappe, installs our fork as
#   the erpnext app, and compiles frontend assets.
# Stage 2 (production): copies only the finished bench into a lean runtime image.
#
# Built by the MKDM marketplace pipeline via:
#   docker build -t <registry>/kadmap/erpnext:<tag> .
#
# Required env vars at container start (injected by MKDM at deploy time):
#   AUTHENTIK_URL, OIDC_CLIENT_ID, OIDC_CLIENT_SECRET
#   MYSQL_ROOT_PASSWORD, FRAPPE_ADMIN_PASSWORD
#   See .env.example for the full list.

ARG FRAPPE_BRANCH=develop
ARG NODE_VERSION=24
ARG PYTHON_IMAGE=python:3.14-slim-trixie

# ── Stage 1: builder ───────────────────────────────────────────────────────────
FROM ${PYTHON_IMAGE} AS builder

ARG FRAPPE_BRANCH
ARG NODE_VERSION

ENV DEBIAN_FRONTEND=noninteractive \
    NVM_DIR=/opt/nvm \
    NVM_SYMLINK_CURRENT=true \
    PATH=/opt/nvm/current/bin:/home/frappe/.local/bin:${PATH}

# System build dependencies
# redis-server: bench init calls `redis-server --version` to generate Redis config
# cron: bench init calls /usr/bin/crontab to set up backup schedules
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl wget git sudo \
    build-essential pkg-config \
    libffi-dev libmariadb-dev libpq-dev \
    libldap2-dev libsasl2-dev \
    libtiff-dev libwebp-dev libjpeg-dev \
    redis-server cron \
    && rm -rf /var/lib/apt/lists/*

# Node.js via nvm (same approach as frappe_docker)
RUN mkdir -p "${NVM_DIR}" \
    && curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.6/install.sh | bash \
    && . "${NVM_DIR}/nvm.sh" \
    && nvm install "${NODE_VERSION}" \
    && nvm alias default "${NODE_VERSION}" \
    && npm install -g yarn \
    && rm -rf "${NVM_DIR}/.cache"

# frappe user + bench CLI
RUN useradd -m -s /bin/bash frappe \
    && echo "frappe ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/frappe \
    && git config --system --add safe.directory '*' \
    && pip install --no-cache-dir frappe-bench

USER frappe
WORKDIR /home/frappe

# Initialise bench with Frappe only (no assets yet — we build them after adding ERPNext)
RUN bench init \
    --skip-assets \
    --frappe-branch "${FRAPPE_BRANCH}" \
    --python "$(command -v python3)" \
    frappe-bench

WORKDIR /home/frappe/frappe-bench

# Add our KDM ERPNext fork as the erpnext app
COPY --chown=frappe:frappe . apps/erpnext/

# Install into the venv and build frontend assets
# bench setup requirements calls git.Repo() and git rev-parse --abbrev-ref HEAD on the app
# directory. .git is excluded by .dockerignore, so we seed a minimal repo with one commit
# so that HEAD resolves to a branch name (an empty init leaves HEAD unborn → exit 128).
RUN git -C apps/erpnext init -b develop \
    && git -C apps/erpnext config user.email "build@docker" \
    && git -C apps/erpnext config user.name "Docker Build" \
    && git -C apps/erpnext add -A \
    && git -C apps/erpnext commit -m "build" \
    && env/bin/pip install --no-cache-dir -e apps/erpnext \
    && bench setup requirements \
    && bench build --app erpnext

# ── Stage 2: production ────────────────────────────────────────────────────────
FROM ${PYTHON_IMAGE} AS production

ENV DEBIAN_FRONTEND=noninteractive \
    NVM_DIR=/opt/nvm \
    NVM_SYMLINK_CURRENT=true \
    PATH=/opt/nvm/current/bin:/home/frappe/.local/bin:${PATH}

# Runtime system dependencies only
# wkhtmltopdf was dropped from Debian Trixie apt repos; install from upstream .deb
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl git \
    libmariadb3 libpq5 \
    mariadb-client \
    redis-tools \
    xfonts-75dpi xfonts-base \
    && ARCH=$(dpkg --print-architecture) \
    && curl -fsSL "https://github.com/wkhtmltopdf/packaging/releases/download/0.12.6.1-3/wkhtmltox_0.12.6.1-3.bookworm_${ARCH}.deb" \
        -o /tmp/wkhtmltox.deb \
    && apt-get install -y --no-install-recommends /tmp/wkhtmltox.deb \
    && rm /tmp/wkhtmltox.deb \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -s /bin/bash frappe \
    && git config --system --add safe.directory '*'

# Newer mariadb-client packages default ssl-mode to REQUIRED. The companion db
# service uses no SSL certs, so both bench's internal mariadb CLI calls and
# mariadb-admin fail with "SSL is required, but the server does not support it".
# Writing [client] ssl=false here disables SSL enforcement for every mariadb/mysql
# client binary invoked inside this container, regardless of which user runs it.
RUN mkdir -p /etc/mysql/mariadb.conf.d \
    && printf '[client]\nssl = false\n' > /etc/mysql/mariadb.conf.d/99-no-ssl.cnf

# bench CLI is installed via pip in Stage 1 but that /usr/local/bin/bench is
# not copied to Stage 2. Reinstall here so bench is on PATH in the runtime image.
RUN pip install --no-cache-dir frappe-bench

# Copy the fully-built bench and Node runtime from the builder
COPY --from=builder --chown=frappe:frappe /home/frappe/frappe-bench /home/frappe/frappe-bench
COPY --from=builder /opt/nvm /opt/nvm

# KDM entrypoint: handles first-run site creation + Authentik OIDC seeding
COPY docker/kdm-entrypoint.sh /usr/local/bin/kdm-entrypoint
RUN chmod +x /usr/local/bin/kdm-entrypoint

USER frappe
WORKDIR /home/frappe/frappe-bench

EXPOSE 8000

ENTRYPOINT ["/usr/local/bin/kdm-entrypoint"]
CMD ["bench", "serve", "--port", "8000", "--host", "0.0.0.0"]
