#!/usr/bin/env bash
# Migrate selected Docker applications from an old Debian server to a new one.
# Run on the NEW server. The 3X-UI installation and its database are not migrated.
set -Eeuo pipefail
umask 077

CONFIG_FILE="/root/.vds-docker-migration.conf"
MANAGED_MARKER=".vds-docker-migration-managed"
WATCHTOWER_SCHEDULE="0 47 3 * * *"
WATCHTOWER_TZ="Asia/Yekaterinburg"

OLD_HOST="${OLD_HOST:-}"
OLD_PORT="${OLD_PORT:-22}"
OLD_USER="${OLD_USER:-root}"
SSH_KEY="${SSH_KEY:-/root/.ssh/vds-docker-migration-ed25519}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"

PROJECT_SRC=(
    "/root/twitch-miner"
    "/root/beszel"
    "/root/beszel-agent"
    "/root/vaultwarden"
    "/opt/lampac-docker"
)
PROJECT_DST=("${PROJECT_SRC[@]}")
APP_CONTAINERS=(twitch-miner beszel beszel-agent vaultwarden lampac)
APP_DOMAINS=(
    pass.ww-host.website
    twitch.ww-host.website
    status.ww-host.website
    lampac.ww-host.website
)

# Pull the exact images that were running during inventory, then tag them as
# the tags used by the Compose files. Watchtower can update them after migration.
IMAGE_REFS=(
    "rangermix/twitch-drops-miner@sha256:81c93729ab95135dc50264be49bbbc18d418f3563ff57b4e2e73345707f9346a"
    "henrygd/beszel@sha256:8514a69d9bbbcb74f371a3205561ee231fc0289739cea64e8131f341d695b770"
    "henrygd/beszel-agent@sha256:cb6868012964d7a68debaa2c84bb72285e5f08531e81f506bd4c493bf052e41c"
    "vaultwarden/server@sha256:4fe17f415f90087377d37c755e0ea3cf189dcc6794e49cdd2a9adbb4937d9e1f"
    "ghcr.io/lampac-nextgen/lampac@sha256:9d1c6ea91b73272a3c899d100f96099260b663fe9a34a7f80f20d40549c045f9"
)
IMAGE_TAGS=(
    "rangermix/twitch-drops-miner:latest"
    "henrygd/beszel:latest"
    "henrygd/beszel-agent:latest"
    "vaultwarden/server:latest"
    "ghcr.io/lampac-nextgen/lampac:latest"
)

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32mOK:\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Run this script on the NEW server as root.

Recommended order:
  sudo ./migrate.sh --install-deps   Install Docker/rsync and configure SSH.
  sudo ./migrate.sh --check          Read-only local and remote checks.
  sudo ./migrate.sh --dry-run        Show files to copy; do not copy them.
  sudo ./migrate.sh --sync           Initial copy while old apps keep running.
  sudo ./migrate.sh --cutover        Stop old apps, final copy, start new apps.

After manually moving the four application DNS A records to the NEW server:
  sudo ./migrate.sh --tls            Issue certificates, configure Nginx,
                                     test HTTPS, then install Watchtower last.

Additional command:
  sudo ./migrate.sh --watchtower     Install/repair only Watchtower.

Options:
  --help                             Show this help.

The script does not migrate, replace, or stop the 3X-UI database.
Watchtower schedule: 03:47 Asia/Yekaterinburg every day.
USAGE
}

require_root() {
    [[ "$EUID" -eq 0 ]] || die "Run as root: sudo $0 $*"
}

load_config() {
    if [[ -r "$CONFIG_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$CONFIG_FILE"
    fi
}

save_config() {
    local tmp="${CONFIG_FILE}.tmp"
    {
        printf 'OLD_HOST=%q\n' "$OLD_HOST"
        printf 'OLD_PORT=%q\n' "$OLD_PORT"
        printf 'OLD_USER=%q\n' "$OLD_USER"
        printf 'SSH_KEY=%q\n' "$SSH_KEY"
        printf 'LETSENCRYPT_EMAIL=%q\n' "$LETSENCRYPT_EMAIL"
    } >"$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$CONFIG_FILE"
}

require_saved_connection() {
    [[ -n "$OLD_HOST" && -n "$OLD_PORT" && -n "$OLD_USER" && -n "$SSH_KEY" ]] ||
        die "SSH is not configured. Run: sudo $0 --install-deps"
    [[ -f "$SSH_KEY" ]] || die "SSH private key not found: $SSH_KEY"
}

ssh_old() {
    ssh -i "$SSH_KEY" -p "$OLD_PORT" \
        -o BatchMode=yes -o ConnectTimeout=10 \
        "$OLD_USER@$OLD_HOST" "$@"
}

rsync_ssh_command() {
    printf 'ssh -i %s -p %s -o BatchMode=yes -o ConnectTimeout=10' \
        "$SSH_KEY" "$OLD_PORT"
}

configure_ssh() {
    local answer

    log "SSH connection to the OLD server"

    read -r -p "Old server IP [$OLD_HOST]: " answer
    [[ -n "$answer" ]] && OLD_HOST="$answer"
    [[ -n "$OLD_HOST" ]] || die "Old server IP is required"

    read -r -p "Old server SSH port [$OLD_PORT]: " answer
    [[ -n "$answer" ]] && OLD_PORT="$answer"
    [[ "$OLD_PORT" =~ ^[0-9]+$ ]] && ((OLD_PORT >= 1 && OLD_PORT <= 65535)) ||
        die "Invalid SSH port"

    read -r -p "Old server SSH user [$OLD_USER]: " answer
    [[ -n "$answer" ]] && OLD_USER="$answer"
    [[ "$OLD_USER" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Invalid SSH user"

    read -r -p "Migration SSH key [$SSH_KEY]: " answer
    [[ -n "$answer" ]] && SSH_KEY="$answer"
    [[ "$SSH_KEY" == /* ]] || die "SSH key path must be absolute"

    local local_ip
    while read -r local_ip; do
        [[ -n "$local_ip" && "$local_ip" == "$OLD_HOST" ]] &&
            die "OLD server IP equals a local IP. Run this script on the NEW server"
    done < <(hostname -I 2>/dev/null | tr ' ' '\n')

    install -d -m 700 "$(dirname "$SSH_KEY")"
    if [[ ! -f "$SSH_KEY" ]]; then
        log "Creating a dedicated migration SSH key"
        ssh-keygen -q -t ed25519 -N '' -C 'vds-docker-migration' -f "$SSH_KEY"
    fi
    chmod 600 "$SSH_KEY"

    if ! ssh_old true 2>/dev/null; then
        log "Installing the public key on the OLD server"
        echo "You may be asked to verify the host fingerprint and enter the SSH password once."
        ssh-copy-id -i "${SSH_KEY}.pub" -p "$OLD_PORT" "$OLD_USER@$OLD_HOST"
    fi

    ssh_old true || die "SSH key authentication to the OLD server failed"
    save_config
    ok "SSH connected. Remote hostname: $(ssh_old hostname)"
}

check_os() {
    local os_id os_version
    os_id=$(awk -F= '$1=="ID" {gsub(/"/,"",$2); print $2}' /etc/os-release)
    os_version=$(awk -F= '$1=="VERSION_ID" {gsub(/"/,"",$2); print $2}' /etc/os-release)
    [[ "$os_id" == "debian" && "$os_version" == "13" ]] ||
        die "This migration targets Debian 13; detected: $os_id $os_version"
    [[ "$(uname -m)" == "x86_64" ]] || die "The recorded application images target x86_64"
}

check_panel() {
    log "Checking the existing 3X-UI and Nginx installation"
    systemctl is-active --quiet x-ui || die "3X-UI service is not active"
    systemctl is-active --quiet nginx || die "Nginx is not active"
    command -v nginx >/dev/null || die "Nginx command not found"
    command -v certbot >/dev/null || die "Certbot not found; install the panel first"
    [[ -f /etc/nginx/stream-enabled/stream.conf ]] ||
        die "Panel stream.conf not found"
    nginx -t
    ok "The panel configuration is healthy; its files will not be modified"
}

install_deps() {
    check_os
    check_panel

    log "Installing local prerequisites"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl rsync openssh-client iproute2

    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        log "Adding the official Docker APT repository"
        install -m 0755 -d /etc/apt/keyrings
        curl -fsSL https://download.docker.com/linux/debian/gpg \
            -o /etc/apt/keyrings/docker.asc
        chmod a+r /etc/apt/keyrings/docker.asc

        local codename arch
        codename=$(awk -F= '$1=="VERSION_CODENAME" {print $2}' /etc/os-release)
        arch=$(dpkg --print-architecture)
        printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian %s stable\n' \
            "$arch" "$codename" >/etc/apt/sources.list.d/docker.list
        chmod 644 /etc/apt/sources.list.d/docker.list

        apt-get update
        apt-get install -y docker-ce docker-ce-cli containerd.io \
            docker-buildx-plugin docker-compose-plugin
    fi

    systemctl enable --now docker
    docker --version
    docker compose version

    configure_ssh

    if ! ssh_old 'command -v rsync >/dev/null 2>&1'; then
        log "rsync is missing on the OLD server"
        read -r -p "Install rsync on the OLD server now? [y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] || die "Remote rsync is required"
        ssh_old 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y rsync'
    fi
    ssh_old 'rsync --version | head -n 1'
    ok "Dependencies are ready"
}

check_remote_sources() {
    local src
    for src in "${PROJECT_SRC[@]}"; do
        ssh_old "test -d '$src'" || die "Missing remote directory: $src"
        ssh_old "test -f '$src/docker-compose.yml'" ||
            die "Missing remote Compose file: $src/docker-compose.yml"
    done
    ssh_old 'command -v docker >/dev/null && docker ps --format "{{.Names}}"' ||
        die "Cannot inspect Docker on the OLD server"
    ssh_old 'command -v rsync >/dev/null' || die "rsync is missing on the OLD server"
}

check_free_ports() {
    local port
    for port in 8090 8888 9090 9118 45876; do
        if ss -ltnH "( sport = :$port )" | grep -q .; then
            die "Local TCP port $port is already in use"
        fi
    done
}

run_check() {
    check_os
    check_panel
    require_saved_connection

    log "Local resources"
    free -h
    df -h /

    log "Local Docker"
    command -v docker >/dev/null || die "Docker missing; run --install-deps"
    docker compose version >/dev/null || die "Compose plugin missing; run --install-deps"
    systemctl is-active --quiet docker || die "Docker service is not active"
    docker --version
    docker compose version

    command -v rsync >/dev/null || die "Local rsync missing; run --install-deps"
    check_free_ports

    log "Remote SSH and source data"
    ssh_old true || die "SSH connection failed"
    check_remote_sources
    ssh_old 'printf "Remote host: "; hostname; docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"'

    ok "All preflight checks passed"
}

assert_target_safe() {
    local dst="$1"
    if [[ -d "$dst" ]] && [[ -n "$(find "$dst" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        [[ -f "$dst/$MANAGED_MARKER" ]] ||
            die "Target is non-empty and not managed by this script: $dst"
    fi
}

sync_one() {
    local src="$1" dst="$2" dry_run="$3"
    local -a extra=()

    if [[ "$src" == "/opt/lampac-docker" ]]; then
        extra+=(--exclude=/cache/)
    fi
    extra+=(--exclude="/$MANAGED_MARKER")

    local -a mode=()
    [[ "$dry_run" == "yes" ]] && mode+=(--dry-run --itemize-changes)

    if [[ "$dry_run" != "yes" ]]; then
        assert_target_safe "$dst"
        # Do not chmod an existing system parent such as /opt.
        mkdir -p "$(dirname "$dst")"
    fi

    rsync -aHAX --numeric-ids --delete "${mode[@]}" "${extra[@]}" \
        -e "$(rsync_ssh_command)" \
        "$OLD_USER@$OLD_HOST:$src/" "$dst/"

    if [[ "$dry_run" != "yes" ]]; then
        touch "$dst/$MANAGED_MARKER"
        chmod 600 "$dst/$MANAGED_MARKER"
    fi
}

sync_projects() {
    local dry_run="$1" i label="SYNC"
    [[ "$dry_run" == "yes" ]] && label="DRY-RUN"
    for i in "${!PROJECT_SRC[@]}"; do
        log "$label: ${PROJECT_SRC[$i]} -> ${PROJECT_DST[$i]}"
        sync_one "${PROJECT_SRC[$i]}" "${PROJECT_DST[$i]}" "$dry_run"
    done

    if [[ "$dry_run" != "yes" ]]; then
        install -d -m 0777 /opt/lampac-docker/cache
        ok "Lampac cache was created empty; old cache contents were excluded"
    fi
}

run_dry_run() {
    check_os
    check_panel
    require_saved_connection
    command -v rsync >/dev/null || die "Local rsync missing; run --install-deps"
    ssh_old true || die "SSH connection failed"
    check_remote_sources
    sync_projects yes

    cat <<EOF

Dry run only. No application data was copied and no containers were changed.
Lampac cache contents are excluded. 3X-UI and its database are excluded.
EOF
}

prepare_images() {
    local i
    log "Pulling the exact image digests recorded on the OLD server"
    for i in "${!IMAGE_REFS[@]}"; do
        docker pull "${IMAGE_REFS[$i]}"
        docker tag "${IMAGE_REFS[$i]}" "${IMAGE_TAGS[$i]}"
    done
}

compose_up() {
    local dir="$1"
    docker compose -f "$dir/docker-compose.yml" up -d --pull never --no-build
}

wait_http() {
    local name="$1" port="$2" attempt
    for attempt in {1..30}; do
        if curl -sS --max-time 3 -o /dev/null "http://127.0.0.1:$port/"; then
            ok "$name answers on 127.0.0.1:$port"
            return 0
        fi
        sleep 2
    done
    die "$name did not answer on local port $port"
}

start_new_apps() {
    log "Starting migrated applications on the NEW server"
    install -d -m 0777 /opt/lampac-docker/cache

    compose_up /root/beszel
    compose_up /root/vaultwarden
    compose_up /root/twitch-miner
    compose_up /opt/lampac-docker
    compose_up /root/beszel-agent

    wait_http "Beszel" 8090
    wait_http "Vaultwarden" 8888
    wait_http "Twitch Miner" 9090
    wait_http "Lampac" 9118
    docker inspect -f '{{.State.Running}}' beszel-agent | grep -qx true ||
        die "Beszel agent is not running"

    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

OLD_STOPPED=no
CUTOVER_SUCCESS=no
cutover_exit_trap() {
    local status=$?
    trap - EXIT
    if [[ "$OLD_STOPPED" == "yes" && "$CUTOVER_SUCCESS" != "yes" ]]; then
        warn "Cutover failed; attempting to restart applications on the OLD server"
        set +e
        ssh_old 'docker start lampac vaultwarden beszel beszel-agent twitch-miner'
    fi
    exit "$status"
}

run_cutover() {
    check_os
    check_panel
    require_saved_connection
    command -v rsync >/dev/null || die "Local rsync missing"
    systemctl is-active --quiet docker || die "Docker is not active"
    ssh_old true || die "SSH connection failed"
    check_remote_sources
    check_free_ports

    log "Initial synchronization before downtime"
    sync_projects no
    prepare_images

    cat <<'EOF'

FINAL CUTOVER
The following containers will be stopped on the OLD server:
  twitch-miner, beszel, beszel-agent, vaultwarden, lampac
The 3X-UI service and its database will NOT be stopped.
After a successful start on the NEW server, old application containers
will remain stopped to prevent two copies from writing to different data.
EOF
    local confirmation
    read -r -p 'Type MIGRATE to continue: ' confirmation
    [[ "$confirmation" == "MIGRATE" ]] || die "Cutover cancelled"

    trap cutover_exit_trap EXIT

    log "Stopping applications on the OLD server"
    OLD_STOPPED=yes
    ssh_old 'docker stop twitch-miner beszel beszel-agent vaultwarden lampac'

    log "Final synchronization of consistent application data"
    sync_projects no
    start_new_apps

    CUTOVER_SUCCESS=yes
    trap - EXIT

    local new_ip
    new_ip=$(ip -4 route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    cat <<EOF

Applications are running on the NEW server. Old application containers remain stopped.

Now manually change ONLY these application DNS records:
  pass.ww-host.website
  twitch.ww-host.website
  status.ww-host.website
  lampac.ww-host.website

Point their A records to the NEW server IP: $new_ip
If any of these domains has an AAAA record, point it to the NEW server IPv6
address or remove the stale AAAA record. Do not leave it on the OLD server.

Do not change panel or Reality DNS records for this Docker migration.
After DNS changes run:
  sudo $0 --tls
EOF
}

write_nginx_configs() {
    log "Writing application-only Nginx configuration"

    cat >/etc/nginx/stream-enabled/docker-apps.conf <<'NGINX'
server {
    listen 443;
    listen [::]:443;
    server_name
        twitch.ww-host.website
        lampac.ww-host.website
        pass.ww-host.website
        status.ww-host.website;
    ssl_preread on;
    proxy_protocol on;
    proxy_pass 127.0.0.1:7443;
}
NGINX

    cat >/etc/nginx/sites-available/docker-apps-80.conf <<'NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name
        twitch.ww-host.website
        lampac.ww-host.website
        pass.ww-host.website
        status.ww-host.website;
    return 301 https://$host$request_uri;
}
NGINX

    cat >/etc/nginx/sites-available/pass.conf <<'NGINX'
server {
    server_tokens off;
    server_name pass.ww-host.website;
    listen 7443 ssl proxy_protocol;
    listen [::]:7443 ssl proxy_protocol;
    http2 on;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    absolute_redirect off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate /etc/letsencrypt/live/pass.ww-host.website/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/pass.ww-host.website/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8888;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $proxy_protocol_addr;
        proxy_set_header X-Forwarded-For $proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
    location /notifications/hub {
        proxy_pass http://127.0.0.1:8888;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP $proxy_protocol_addr;
        proxy_set_header X-Forwarded-For $proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NGINX

    cat >/etc/nginx/sites-available/twitchminer.conf <<'NGINX'
map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
}
server {
    server_tokens off;
    server_name twitch.ww-host.website;
    listen 7443 ssl proxy_protocol;
    listen [::]:7443 ssl proxy_protocol;
    http2 on;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    absolute_redirect off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate /etc/letsencrypt/live/twitch.ww-host.website/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/twitch.ww-host.website/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:9090;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Origin $http_origin;
        proxy_set_header X-Real-IP $proxy_protocol_addr;
        proxy_set_header X-Forwarded-For $proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Port 443;
        proxy_buffering off;
        proxy_read_timeout 86400s;
        proxy_send_timeout 86400s;
    }
}
NGINX

    cat >/etc/nginx/sites-available/beszel.conf <<'NGINX'
server {
    server_tokens off;
    server_name status.ww-host.website;
    listen 7443 ssl proxy_protocol;
    listen [::]:7443 ssl proxy_protocol;
    http2 on;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    absolute_redirect off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate /etc/letsencrypt/live/status.ww-host.website/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/status.ww-host.website/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:8090;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header X-Real-IP $proxy_protocol_addr;
        proxy_set_header X-Forwarded-For $proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NGINX

    cat >/etc/nginx/sites-available/lampac.conf <<'NGINX'
server {
    server_tokens off;
    server_name lampac.ww-host.website;
    listen 7443 ssl proxy_protocol;
    listen [::]:7443 ssl proxy_protocol;
    http2 on;
    real_ip_header proxy_protocol;
    set_real_ip_from 127.0.0.1;
    set_real_ip_from ::1;
    absolute_redirect off;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_certificate /etc/letsencrypt/live/lampac.ww-host.website/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/lampac.ww-host.website/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:9118/;
        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header Connection "";
        proxy_set_header X-Real-IP $proxy_protocol_addr;
        proxy_set_header X-Forwarded-For $proxy_protocol_addr;
        proxy_set_header X-Forwarded-Proto https;
    }
}
NGINX

    local name
    for name in docker-apps-80.conf pass.conf twitchminer.conf beszel.conf lampac.conf; do
        ln -sfn "/etc/nginx/sites-available/$name" "/etc/nginx/sites-enabled/$name"
    done
}

install_watchtower() {
    log "Installing Watchtower as the final migration step"
    check_panel
    systemctl is-active --quiet docker || die "Docker is not active"
    install -d -m 700 /root/watchtower

    cat >/root/watchtower/docker-compose.yml <<EOF
services:
  watchtower:
    image: containrrr/watchtower:latest
    container_name: watchtower
    restart: unless-stopped
    environment:
      TZ: $WATCHTOWER_TZ
      WATCHTOWER_SCHEDULE: "$WATCHTOWER_SCHEDULE"
      WATCHTOWER_CLEANUP: "true"
      WATCHTOWER_ROLLING_RESTART: "true"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
EOF
    chmod 600 /root/watchtower/docker-compose.yml
    docker compose -f /root/watchtower/docker-compose.yml up -d
    docker inspect -f '{{.State.Running}}' watchtower | grep -qx true ||
        die "Watchtower did not start"
    ok "Watchtower will check and update applications daily at 03:47 Asia/Yekaterinburg"
}

run_tls() {
    check_os
    check_panel
    systemctl is-active --quiet docker || die "Docker is not active"

    local container
    for container in "${APP_CONTAINERS[@]}"; do
        docker inspect -f '{{.State.Running}}' "$container" | grep -qx true ||
            die "Application container is not running: $container"
    done

    local new_ip new_ip6 domain resolved resolved6
    new_ip=$(ip -4 route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    new_ip6=$(ip -6 route get 2620:fe::fe 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
    [[ -n "$new_ip" ]] || die "Cannot determine the NEW server IPv4 address"

    log "Checking application DNS records; expected NEW IPv4: $new_ip"
    for domain in "${APP_DOMAINS[@]}"; do
        resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
        if ! grep -Fxq "$new_ip" <<<"$resolved"; then
            printf 'ERROR: %s resolves to:\n%s\n' "$domain" "${resolved:-no IPv4 record}" >&2
            die "Move application DNS first. Cloudflare proxy addresses are not supported by this check"
        fi
        ok "$domain -> $new_ip"

        # A stale AAAA record would send IPv6 clients and ACME validation back
        # to the old server even after the A record has been moved.
        # getent ahostsv6 may synthesize ::ffff:A.B.C.D from an A record.
        # Such IPv4-mapped results are not real AAAA records and must be ignored.
        resolved6=$(getent ahostsv6 "$domain" 2>/dev/null |
            awk 'tolower($1) !~ /^::ffff:/ {print $1}' | sort -u || true)
        if [[ -n "$resolved6" ]]; then
            [[ -n "$new_ip6" ]] ||
                die "$domain has AAAA records, but the NEW server has no detected IPv6; remove or update AAAA"
            grep -Fxq "$new_ip6" <<<"$resolved6" ||
                die "$domain has an AAAA record not pointing to the NEW server; update or remove it"
            ok "$domain -> $new_ip6"
        fi
    done

    if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
        read -r -p "E-mail for Let's Encrypt expiry notices: " LETSENCRYPT_EMAIL
    fi
    [[ "$LETSENCRYPT_EMAIL" == *@*.* ]] || die "A valid e-mail is required"
    save_config

    log "Issuing fresh certificates; Nginx will be stopped briefly"
    systemctl stop nginx
    local cert_status=0
    for domain in "${APP_DOMAINS[@]}"; do
        certbot certonly --standalone --non-interactive --agree-tos \
            --email "$LETSENCRYPT_EMAIL" --cert-name "$domain" -d "$domain" ||
            { cert_status=$?; break; }
    done
    systemctl start nginx
    ((cert_status == 0)) || die "Certificate issuance failed; panel Nginx was started again"

    local backup_dir path
    backup_dir="/root/vds-migration-backups/nginx-$(date +%Y%m%d-%H%M%S)"
    local -a managed_paths=(
        /etc/nginx/stream-enabled/docker-apps.conf
        /etc/nginx/sites-available/docker-apps-80.conf
        /etc/nginx/sites-available/pass.conf
        /etc/nginx/sites-available/twitchminer.conf
        /etc/nginx/sites-available/beszel.conf
        /etc/nginx/sites-available/lampac.conf
        /etc/nginx/sites-enabled/docker-apps-80.conf
        /etc/nginx/sites-enabled/pass.conf
        /etc/nginx/sites-enabled/twitchminer.conf
        /etc/nginx/sites-enabled/beszel.conf
        /etc/nginx/sites-enabled/lampac.conf
    )
    install -d -m 700 "$backup_dir"
    for path in "${managed_paths[@]}"; do
        if [[ -e "$path" || -L "$path" ]]; then
            cp --parents -a "$path" "$backup_dir"
        fi
    done

    write_nginx_configs

    if ! nginx -t; then
        warn "Nginx test failed; rolling back application Nginx files"
        for path in "${managed_paths[@]}"; do
            rm -f "$path"
            if [[ -e "$backup_dir$path" || -L "$backup_dir$path" ]]; then
                cp -a "$backup_dir$path" "$path"
            fi
        done
        nginx -t || true
        die "Application Nginx configuration was rolled back"
    fi

    systemctl reload nginx
    ok "Nginx reloaded; panel stream.conf was not changed"

    log "Checking HTTPS applications"
    for domain in "${APP_DOMAINS[@]}"; do
        curl -sS --max-time 20 -o /dev/null "https://$domain/" ||
            die "HTTPS check failed: $domain. Watchtower was not installed"
        ok "https://$domain/ answers"
    done

    # Watchtower is deliberately last: it must not update images mid-migration.
    install_watchtower

    cat <<'EOF'

Migration is complete.
The old application containers remain stopped. Keep the old server unchanged
for a rollback window while you verify logins, sessions, databases and updates.
EOF
}

ACTION="${1:-}"
case "$ACTION" in
    -h|--help)
        usage
        exit 0
        ;;
    --install-deps|--check|--dry-run|--sync|--cutover|--tls|--watchtower)
        require_root "$ACTION"
        load_config
        ;;
    *)
        usage
        exit 1
        ;;
esac

case "$ACTION" in
    --install-deps) install_deps ;;
    --check)        run_check ;;
    --dry-run)      run_dry_run ;;
    --sync)
        check_os
        check_panel
        require_saved_connection
        command -v rsync >/dev/null || die "Local rsync missing"
        ssh_old true || die "SSH connection failed"
        check_remote_sources
        sync_projects no
        ;;
    --cutover)      run_cutover ;;
    --tls)          run_tls ;;
    --watchtower)   install_watchtower ;;
esac
