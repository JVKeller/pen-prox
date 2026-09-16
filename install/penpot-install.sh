#!/usr/bin/env bash
# Copyright (c) 2021-2026 community-scripts ORG
# Author: Jeff Keller (mahoutcomputer)
# License: MIT | https://github.com/community-scripts/ProxmoxVED/raw/main/LICENSE
# Source: https://penpot.app | https://github.com/penpot/penpot

source /dev/stdin <<<"$FUNCTIONS_FILE_PATH"
color
verb_ip6
catch_errors
setting_up_container
network_check
update_os

# Toolchain pins from docker/devenv/Dockerfile at tag 2.17.2 — recheck on upstream bumps
RUST_VERSION="1.91.0"
EMSCRIPTEN_VERSION="4.0.6"
JAVA_MAJOR="26"

msg_info "Installing Dependencies"
$STD apt install -y \
  build-essential git rsync jq openssl sudo \
  python3 python3-tabulate fontforge woff2 imagemagick \
  fontconfig libfreetype6 \
  nginx valkey-server
# Backend shells out to `magick` (ImageMagick 7)
if ! command -v magick >/dev/null 2>&1; then
  ln -sf "$(command -v convert)" /usr/local/bin/magick
fi
msg_ok "Installed Dependencies"

PG_VERSION="16" setup_postgresql
NODE_VERSION="24" setup_nodejs
$STD corepack enable

msg_info "Installing Azul Zulu JDK ${JAVA_MAJOR}"
ZULU_URL=$(curl -fsSL "https://api.azul.com/metadata/v1/zulu/packages/?java_version=${JAVA_MAJOR}&os=linux-glibc&arch=x64&archive_type=tar.gz&java_package_type=jdk&latest=true&release_status=ga" | jq -r '.[0].download_url')
mkdir -p /opt/jdk
curl -fsSL "$ZULU_URL" | tar -xz -C /opt/jdk --strip-components=1
msg_ok "Installed Zulu JDK ${JAVA_MAJOR}"

msg_info "Installing Clojure CLI and Babashka"
curl -fsSL -o /tmp/clj-install.sh https://github.com/clojure/brew-install/releases/latest/download/linux-install.sh
chmod +x /tmp/clj-install.sh
$STD /tmp/clj-install.sh --prefix /opt/clojure
curl -fsSL -o /tmp/bb-install https://raw.githubusercontent.com/babashka/babashka/master/install
chmod +x /tmp/bb-install
$STD /tmp/bb-install --dir /usr/local/bin
rm -f /tmp/clj-install.sh /tmp/bb-install
msg_ok "Installed Clojure CLI and Babashka"

msg_info "Installing Rust ${RUST_VERSION} and Emscripten ${EMSCRIPTEN_VERSION}"
export RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
curl -fsSL https://sh.rustup.rs | $STD sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_VERSION"
$STD /opt/cargo/bin/rustup target add wasm32-unknown-emscripten
$STD git clone --depth 1 https://github.com/emscripten-core/emsdk.git /opt/emsdk
$STD /opt/emsdk/emsdk install "$EMSCRIPTEN_VERSION"
$STD /opt/emsdk/emsdk activate "$EMSCRIPTEN_VERSION"
msg_ok "Installed Rust and Emscripten"

msg_info "Setting up PostgreSQL"
DB_NAME=penpot
DB_USER=penpot
DB_PASS=$(openssl rand -base64 18 | tr -dc 'a-zA-Z0-9' | head -c16)
$STD sudo -u postgres psql -c "CREATE ROLE $DB_USER WITH LOGIN PASSWORD '$DB_PASS';"
$STD sudo -u postgres psql -c "CREATE DATABASE $DB_NAME WITH OWNER $DB_USER ENCODING 'UTF8' TEMPLATE template0;"
{
  echo "Penpot Credentials"
  echo "Database User: $DB_USER"
  echo "Database Password: $DB_PASS"
  echo "Database Name: $DB_NAME"
} >>~/penpot.creds
msg_ok "Set up PostgreSQL"

systemctl enable -q --now valkey-server

fetch_and_deploy_gh_release "penpot" "penpot/penpot" "tarball" "latest" "/opt/penpot-src"

msg_info "Configuring Penpot"
useradd -r -U -M -d /opt/penpot -s /usr/sbin/nologin penpot
mkdir -p /opt/penpot/data/assets /opt/penpot/browsers
SECRET_KEY=$(openssl rand -base64 48 | tr -d '\n')
cat <<ENV >/opt/penpot/penpot.env
PENPOT_PUBLIC_URI=http://${LOCAL_IP}
PENPOT_INTERNAL_URI=http://127.0.0.1
PENPOT_SECRET_KEY=${SECRET_KEY}
PENPOT_FLAGS="enable-registration enable-login-with-password disable-email-verification disable-secure-session-cookies disable-onboarding-questions enable-mcp"
PENPOT_DATABASE_URI=postgresql://127.0.0.1/${DB_NAME}
PENPOT_DATABASE_USERNAME=${DB_USER}
PENPOT_DATABASE_PASSWORD=${DB_PASS}
PENPOT_REDIS_URI=redis://127.0.0.1/0
PENPOT_OBJECTS_STORAGE_BACKEND=fs
PENPOT_OBJECTS_STORAGE_FS_DIRECTORY=/opt/penpot/data/assets
PENPOT_HTTP_SERVER_MAX_BODY_SIZE=367001600
PENPOT_HTTP_SERVER_MAX_MULTIPART_BODY_SIZE=367001600
PENPOT_TELEMETRY_ENABLED=false
JAVA_HOME=/opt/jdk
JVM_OPTS=-Xmx2g
PLAYWRIGHT_BROWSERS_PATH=/opt/penpot/browsers
PENPOT_MCP_SERVER_HOST=127.0.0.1
PENPOT_MCP_REDIS_URI=redis://127.0.0.1/0
ENV
chmod 640 /opt/penpot/penpot.env

cat <<'JS' >/opt/penpot/config.js
var penpotFlags = "enable-registration enable-login-with-password disable-email-verification disable-onboarding-questions enable-mcp";
JS

# Build + deploy script, reused by update_script in ct/penpot.sh
cat <<'BUILD' >/opt/penpot/build.sh
#!/usr/bin/env bash
set -euo pipefail
VERSION="${1:-latest}"
SRC=/opt/penpot-src
export JAVA_HOME=/opt/jdk RUSTUP_HOME=/opt/rustup CARGO_HOME=/opt/cargo
export PATH="/opt/jdk/bin:/opt/clojure/bin:/opt/cargo/bin:$PATH"
export PLAYWRIGHT_BROWSERS_PATH=/opt/penpot/browsers

cd "$SRC/frontend" && ./scripts/build "$VERSION"
cd "$SRC/backend" && ./scripts/build "$VERSION"
cd "$SRC/exporter" && ./scripts/build "$VERSION"
cd "$SRC/mcp" && ./scripts/build

rm -rf /opt/penpot/frontend /opt/penpot/backend /opt/penpot/exporter /opt/penpot/mcp
cp -a "$SRC/frontend/target/dist" /opt/penpot/frontend
cp -a "$SRC/backend/target/dist" /opt/penpot/backend
cp -a "$SRC/exporter/target" /opt/penpot/exporter
cp -a "$SRC/mcp/dist" /opt/penpot/mcp
cp /opt/penpot/config.js /opt/penpot/frontend/js/config.js

cd /opt/penpot/exporter && ./setup
pnpm exec playwright install-deps chromium
cd /opt/penpot/mcp && ./setup

chown -R penpot:penpot /opt/penpot
chmod 755 /opt/penpot /opt/penpot/data /opt/penpot/data/assets
rm -rf /tmp/emsdk_cache
BUILD
chmod +x /opt/penpot/build.sh
msg_ok "Configured Penpot"

msg_info "Building Penpot from source (30-90 min depending on CPU)"
$STD /opt/penpot/build.sh "$(cat ~/.penpot 2>/dev/null || echo latest)"
msg_ok "Built Penpot"

msg_info "Configuring Nginx"
cat <<'NGINX' >/etc/nginx/sites-available/penpot
map $http_upgrade $connection_upgrade { default upgrade; '' close; }
server {
    listen 80 default_server;
    server_name _;
    client_max_body_size 367001600;
    charset utf-8;
    etag off;
    root /opt/penpot/frontend;

    proxy_http_version 1.1;
    proxy_set_header Host $http_host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_read_timeout 300s;

    location /assets           { proxy_pass http://127.0.0.1:6060/assets; }
    location /internal/assets  { internal; alias /opt/penpot/data/assets; }
    location = /link-preview   { proxy_pass http://127.0.0.1:6060/link-preview$is_args$args; }
    location /api/export       { proxy_pass http://127.0.0.1:6061; }
    location /api              { proxy_pass http://127.0.0.1:6060/api; proxy_buffering off; }
    location /readyz           { access_log off; proxy_pass http://127.0.0.1:6060$request_uri; }
    location /ws/notifications {
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_pass http://127.0.0.1:6060/ws/notifications;
    }
    location /mcp/ws {
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_pass http://127.0.0.1:4402;
    }
    location /mcp/stream       { proxy_pass http://127.0.0.1:4401/mcp; proxy_buffering off; }
    location /mcp/sse          { proxy_pass http://127.0.0.1:4401/sse; proxy_buffering off; }
    location /plugins          { alias /opt/penpot/frontend/plugins; }
    location = /js/config.js   { add_header Cache-Control "no-store" always; }
    location / {
        add_header Cache-Control "no-store, no-cache, max-age=0" always;
        try_files $uri /index.html$is_args$args /index.html =404;
    }
}
NGINX
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/penpot /etc/nginx/sites-enabled/penpot
$STD nginx -t
systemctl reload nginx
msg_ok "Configured Nginx"

msg_info "Creating Services"
cat <<'SVC' >/etc/systemd/system/penpot-backend.service
[Unit]
Description=Penpot Backend
After=network.target postgresql.service valkey-server.service
Requires=postgresql.service valkey-server.service

[Service]
Type=simple
User=penpot
Group=penpot
WorkingDirectory=/opt/penpot/backend
EnvironmentFile=/opt/penpot/penpot.env
ExecStart=/bin/bash run.sh
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVC

cat <<'SVC' >/etc/systemd/system/penpot-exporter.service
[Unit]
Description=Penpot Exporter
After=network.target penpot-backend.service

[Service]
Type=simple
User=penpot
Group=penpot
WorkingDirectory=/opt/penpot/exporter
EnvironmentFile=/opt/penpot/penpot.env
ExecStart=/usr/bin/node app.js
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVC
cat <<'SVC' >/etc/systemd/system/penpot-mcp.service
[Unit]
Description=Penpot MCP Server
After=network.target penpot-backend.service

[Service]
Type=simple
User=penpot
Group=penpot
WorkingDirectory=/opt/penpot/mcp
EnvironmentFile=/opt/penpot/penpot.env
ExecStart=/usr/bin/node index.js --multi-user
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
SVC
systemctl daemon-reload
systemctl enable -q --now penpot-backend penpot-exporter penpot-mcp
msg_ok "Created Services"

motd_ssh
customize

msg_info "Cleaning up"
$STD apt -y autoremove
$STD apt -y autoclean
$STD apt -y clean
msg_ok "Cleaned"
