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
ok()   { printf '\033[1;32mГОТОВО:\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mВНИМАНИЕ:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }
next_step() { printf '\n\033[1;36mСледующий шаг:\033[0m %s\n' "$*"; }

usage() {
    cat <<'USAGE'
Запускайте этот скрипт от root на НОВОМ сервере.

Рекомендуемый порядок:
  sudo vds-migrate --install-deps   Установить Docker и rsync, настроить SSH.
  sudo vds-migrate --check          Проверить оба сервера без изменения данных.
  sudo vds-migrate --dry-run        Показать список файлов без копирования.
  sudo vds-migrate --sync           Скопировать данные, не останавливая старые приложения.
  sudo vds-migrate --cutover        Остановить старые приложения, выполнить финальную
                                    синхронизацию и запустить приложения на новом сервере.

После ручного переключения A-записей четырёх приложений на НОВЫЙ сервер:
  sudo vds-migrate --tls            Выпустить сертификаты, настроить Nginx,
                                    проверить HTTPS и последним установить Watchtower.

Дополнительная команда:
  sudo vds-migrate --watchtower     Установить или восстановить только Watchtower.

Справка:
  sudo vds-migrate --help           Показать эту справку.

Скрипт не переносит, не заменяет и не останавливает базу данных 3X-UI.
Watchtower проверяет обновления ежедневно в 03:47 по Asia/Yekaterinburg.
USAGE
}

require_root() {
    [[ "$EUID" -eq 0 ]] || die "Запустите скрипт от root: sudo $0 $*"
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
        die "SSH не настроен. Выполните: sudo vds-migrate --install-deps"
    [[ -f "$SSH_KEY" ]] || die "Приватный SSH-ключ не найден: $SSH_KEY"
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

    log "Настройка SSH-подключения к СТАРОМУ серверу"

    read -r -p "IP-адрес старого сервера [$OLD_HOST]: " answer
    [[ -n "$answer" ]] && OLD_HOST="$answer"
    [[ -n "$OLD_HOST" ]] || die "Укажите IP-адрес старого сервера"

    read -r -p "SSH-порт старого сервера [$OLD_PORT]: " answer
    [[ -n "$answer" ]] && OLD_PORT="$answer"
    [[ "$OLD_PORT" =~ ^[0-9]+$ ]] && ((OLD_PORT >= 1 && OLD_PORT <= 65535)) ||
        die "Некорректный SSH-порт"

    read -r -p "SSH-пользователь старого сервера [$OLD_USER]: " answer
    [[ -n "$answer" ]] && OLD_USER="$answer"
    [[ "$OLD_USER" =~ ^[a-zA-Z0-9._-]+$ ]] || die "Некорректное имя SSH-пользователя"

    read -r -p "Путь к SSH-ключу миграции [$SSH_KEY]: " answer
    [[ -n "$answer" ]] && SSH_KEY="$answer"
    [[ "$SSH_KEY" == /* ]] || die "Путь к SSH-ключу должен быть абсолютным"

    local local_ip
    while read -r local_ip; do
        [[ -n "$local_ip" && "$local_ip" == "$OLD_HOST" ]] &&
            die "IP старого сервера совпадает с локальным IP. Запускайте скрипт на НОВОМ сервере"
    done < <(hostname -I 2>/dev/null | tr ' ' '\n')

    install -d -m 700 "$(dirname "$SSH_KEY")"
    if [[ ! -f "$SSH_KEY" ]]; then
        log "Создание отдельного SSH-ключа для миграции"
        ssh-keygen -q -t ed25519 -N '' -C 'vds-docker-migration' -f "$SSH_KEY"
    fi
    chmod 600 "$SSH_KEY"

    if ! ssh_old true 2>/dev/null; then
        log "Установка публичного ключа на СТАРЫЙ сервер"
        echo "Один раз может потребоваться подтвердить отпечаток сервера и ввести SSH-пароль."
        ssh-copy-id -i "${SSH_KEY}.pub" -p "$OLD_PORT" "$OLD_USER@$OLD_HOST"
    fi

    ssh_old true || die "Не удалось подключиться к СТАРОМУ серверу по SSH-ключу"
    save_config
    ok "SSH подключён. Имя удалённого сервера: $(ssh_old hostname)"
}

check_os() {
    local os_id os_version
    os_id=$(awk -F= '$1=="ID" {gsub(/"/,"",$2); print $2}' /etc/os-release)
    os_version=$(awk -F= '$1=="VERSION_ID" {gsub(/"/,"",$2); print $2}' /etc/os-release)
    [[ "$os_id" == "debian" && "$os_version" == "13" ]] ||
        die "Скрипт рассчитан на Debian 13; обнаружено: $os_id $os_version"
    [[ "$(uname -m)" == "x86_64" ]] || die "Записанные образы приложений рассчитаны на x86_64"
}

check_panel() {
    log "Проверка установленных 3X-UI и Nginx"
    systemctl is-active --quiet x-ui || die "Служба 3X-UI не активна"
    systemctl is-active --quiet nginx || die "Nginx не активен"
    command -v nginx >/dev/null || die "Команда nginx не найдена"
    command -v certbot >/dev/null || die "Certbot не найден; сначала установите панель"
    [[ -f /etc/nginx/stream-enabled/stream.conf ]] ||
        die "Файл stream.conf панели не найден"
    nginx -t
    ok "Конфигурация панели исправна; её файлы изменяться не будут"
}

install_deps() {
    check_os
    check_panel

    log "Установка необходимых пакетов на НОВЫЙ сервер"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y ca-certificates curl rsync openssh-client iproute2

    if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
        log "Добавление официального APT-репозитория Docker"
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
        log "На СТАРОМ сервере не установлен rsync"
        read -r -p "Установить rsync на СТАРЫЙ сервер сейчас? [y/N]: " answer
        [[ "$answer" =~ ^[Yy]$ ]] || die "Для миграции требуется rsync на старом сервере"
        ssh_old 'export DEBIAN_FRONTEND=noninteractive; apt-get update && apt-get install -y rsync'
    fi
    ssh_old 'rsync --version | head -n 1'
    ok "Все зависимости установлены"
    next_step "sudo vds-migrate --check"
}

check_remote_sources() {
    local src
    for src in "${PROJECT_SRC[@]}"; do
        ssh_old "test -d '$src'" || die "На старом сервере нет каталога: $src"
        ssh_old "test -f '$src/docker-compose.yml'" ||
            die "На старом сервере нет Compose-файла: $src/docker-compose.yml"
    done
    ssh_old 'command -v docker >/dev/null && docker ps --format "{{.Names}}"' ||
        die "Не удалось получить список Docker-контейнеров на СТАРОМ сервере"
    ssh_old 'command -v rsync >/dev/null' || die "На СТАРОМ сервере не установлен rsync"
}

check_free_ports() {
    local port
    for port in 8090 8888 9090 9118 45876; do
        if ss -ltnH "( sport = :$port )" | grep -q .; then
            die "Локальный TCP-порт $port уже занят"
        fi
    done
}

run_check() {
    check_os
    check_panel
    require_saved_connection

    log "Ресурсы НОВОГО сервера"
    free -h
    df -h /

    log "Docker на НОВОМ сервере"
    command -v docker >/dev/null || die "Docker не установлен; выполните --install-deps"
    docker compose version >/dev/null || die "Плагин Compose не установлен; выполните --install-deps"
    systemctl is-active --quiet docker || die "Служба Docker не активна"
    docker --version
    docker compose version

    command -v rsync >/dev/null || die "Локальный rsync не установлен; выполните --install-deps"
    check_free_ports

    log "Проверка SSH и исходных данных на СТАРОМ сервере"
    ssh_old true || die "SSH-подключение не удалось"
    check_remote_sources
    ssh_old 'printf "Удалённый сервер: "; hostname; docker ps -a --format "table {{.Names}}\t{{.Image}}\t{{.Status}}"'

    ok "Все предварительные проверки пройдены"
    next_step "sudo vds-migrate --dry-run"
}

assert_target_safe() {
    local dst="$1"
    if [[ -d "$dst" ]] && [[ -n "$(find "$dst" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
        [[ -f "$dst/$MANAGED_MARKER" ]] ||
            die "Каталог назначения не пуст и не был создан этим скриптом: $dst"
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
    local dry_run="$1" i label="СИНХРОНИЗАЦИЯ"
    [[ "$dry_run" == "yes" ]] && label="ПРОВЕРКА БЕЗ КОПИРОВАНИЯ"
    for i in "${!PROJECT_SRC[@]}"; do
        log "$label: ${PROJECT_SRC[$i]} -> ${PROJECT_DST[$i]}"
        sync_one "${PROJECT_SRC[$i]}" "${PROJECT_DST[$i]}" "$dry_run"
    done

    if [[ "$dry_run" != "yes" ]]; then
        install -d -m 0777 /opt/lampac-docker/cache
        ok "Создан пустой кэш Lampac; содержимое старого кэша не копировалось"
    fi
}

run_dry_run() {
    check_os
    check_panel
    require_saved_connection
    command -v rsync >/dev/null || die "Локальный rsync не установлен; выполните --install-deps"
    ssh_old true || die "SSH-подключение не удалось"
    check_remote_sources
    sync_projects yes

    cat <<EOF

Это только пробный запуск. Данные не скопированы, контейнеры не изменены.
Кэш Lampac, панель 3X-UI и её база данных исключены из миграции.
EOF
    next_step "sudo vds-migrate --sync"
}

prepare_images() {
    local i
    log "Загрузка точных версий образов, записанных на СТАРОМ сервере"
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
            ok "$name отвечает на 127.0.0.1:$port"
            return 0
        fi
        sleep 2
    done
    die "$name не отвечает на локальном порту $port"
}

start_new_apps() {
    log "Запуск перенесённых приложений на НОВОМ сервере"
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
        die "Beszel Agent не запущен"

    docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}'
}

OLD_STOPPED=no
CUTOVER_SUCCESS=no
cutover_exit_trap() {
    local status=$?
    trap - EXIT
    if [[ "$OLD_STOPPED" == "yes" && "$CUTOVER_SUCCESS" != "yes" ]]; then
        warn "Переключение не удалось; пытаюсь снова запустить приложения на СТАРОМ сервере"
        set +e
        ssh_old 'docker start lampac vaultwarden beszel beszel-agent twitch-miner'
    fi
    exit "$status"
}

run_cutover() {
    check_os
    check_panel
    require_saved_connection
    command -v rsync >/dev/null || die "Локальный rsync не установлен"
    systemctl is-active --quiet docker || die "Docker не активен"
    ssh_old true || die "SSH-подключение не удалось"
    check_remote_sources
    check_free_ports

    log "Предварительная синхронизация перед остановкой приложений"
    sync_projects no
    prepare_images

    cat <<'EOF'

ФИНАЛЬНОЕ ПЕРЕКЛЮЧЕНИЕ
На СТАРОМ сервере будут остановлены контейнеры:
  twitch-miner, beszel, beszel-agent, vaultwarden, lampac
Служба 3X-UI и её база данных НЕ будут остановлены.
После успешного запуска на НОВОМ сервере старые контейнеры останутся
остановленными, чтобы две копии не записывали данные одновременно.
EOF
    local confirmation
    read -r -p 'Для продолжения введите MIGRATE: ' confirmation
    [[ "$confirmation" == "MIGRATE" ]] || die "Переключение отменено"

    trap cutover_exit_trap EXIT

    log "Остановка приложений на СТАРОМ сервере"
    OLD_STOPPED=yes
    ssh_old 'docker stop twitch-miner beszel beszel-agent vaultwarden lampac'

    log "Финальная синхронизация согласованных данных приложений"
    sync_projects no
    start_new_apps

    CUTOVER_SUCCESS=yes
    trap - EXIT

    local new_ip
    new_ip=$(ip -4 route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    cat <<EOF

Приложения запущены на НОВОМ сервере. Старые контейнеры остаются остановленными.

Теперь вручную измените ТОЛЬКО DNS-записи этих приложений:
  pass.ww-host.website
  twitch.ww-host.website
  status.ww-host.website
  lampac.ww-host.website

Направьте их A-записи на IPv4 НОВОГО сервера: $new_ip
Если у доменов есть AAAA-записи, направьте их на IPv6 НОВОГО сервера
или удалите устаревшие AAAA-записи. Не оставляйте их на СТАРОМ сервере.

DNS-записи панели и Reality при этой миграции изменять не нужно.
EOF
    next_step "Дождитесь применения DNS и выполните: sudo vds-migrate --tls"
}

write_nginx_configs() {
    log "Запись отдельной конфигурации Nginx только для приложений"

    # The actual panel installer provides this include inside its SNI map:
    # include /etc/nginx/stream-sni.d/*.conf;
    # Add only map entries; do not create a competing listener on port 443.
    [[ -d /etc/nginx/stream-sni.d ]] ||
        die "Не найден каталог SNI панели: /etc/nginx/stream-sni.d"
    grep -qF 'include /etc/nginx/stream-sni.d/*.conf;' \
        /etc/nginx/stream-enabled/stream.conf ||
        die "В stream.conf панели нет include /etc/nginx/stream-sni.d/*.conf"

    # Remove the obsolete separate listener left by earlier script versions.
    rm -f /etc/nginx/stream-enabled/docker-apps.conf

    cat >/etc/nginx/stream-sni.d/docker-apps.conf <<'NGINX'
twitch.ww-host.website  www;
lampac.ww-host.website  www;
pass.ww-host.website    www;
status.ww-host.website  www;
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
    listen 127.0.0.1:7443 ssl proxy_protocol;
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
    listen 127.0.0.1:7443 ssl proxy_protocol;
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
    listen 127.0.0.1:7443 ssl proxy_protocol;
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
    listen 127.0.0.1:7443 ssl proxy_protocol;
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
    log "Установка Watchtower — последний этап миграции"
    check_panel
    systemctl is-active --quiet docker || die "Docker не активен"
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
        die "Watchtower не запустился"
    ok "Watchtower будет проверять и устанавливать обновления ежедневно в 03:47 по Asia/Yekaterinburg"
}

run_tls() {
    check_os
    check_panel
    systemctl is-active --quiet docker || die "Docker не активен"

    local container
    for container in "${APP_CONTAINERS[@]}"; do
        docker inspect -f '{{.State.Running}}' "$container" | grep -qx true ||
            die "Контейнер приложения не запущен: $container"
    done

    local new_ip new_ip6 domain resolved resolved6
    new_ip=$(ip -4 route get 8.8.8.8 | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
    new_ip6=$(ip -6 route get 2620:fe::fe 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}' || true)
    [[ -n "$new_ip" ]] || die "Не удалось определить IPv4-адрес НОВОГО сервера"

    log "Проверка DNS приложений; ожидаемый IPv4 НОВОГО сервера: $new_ip"
    for domain in "${APP_DOMAINS[@]}"; do
        resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{print $1}' | sort -u)
        if ! grep -Fxq "$new_ip" <<<"$resolved"; then
            printf 'ОШИБКА: %s разрешается в:\n%s\n' "$domain" "${resolved:-нет IPv4-записи}" >&2
            die "Сначала переключите DNS приложений. Адреса прокси Cloudflare эта проверка не поддерживает"
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
                die "У $domain есть AAAA-записи, но IPv6 НОВОГО сервера не обнаружен; удалите или обновите AAAA"
            grep -Fxq "$new_ip6" <<<"$resolved6" ||
                die "AAAA-запись $domain указывает не на НОВЫЙ сервер; обновите или удалите её"
            ok "$domain -> $new_ip6"
        fi
    done

    if [[ -z "$LETSENCRYPT_EMAIL" ]]; then
        read -r -p "E-mail для уведомлений Let's Encrypt об окончании срока сертификатов: " LETSENCRYPT_EMAIL
    fi
    [[ "$LETSENCRYPT_EMAIL" == *@*.* ]] || die "Укажите корректный e-mail"
    save_config

    log "Выпуск новых сертификатов; Nginx будет ненадолго остановлен"
    systemctl stop nginx
    local cert_status=0
    for domain in "${APP_DOMAINS[@]}"; do
        certbot certonly --standalone --non-interactive --agree-tos \
            --email "$LETSENCRYPT_EMAIL" --cert-name "$domain" -d "$domain" ||
            { cert_status=$?; break; }
    done
    systemctl start nginx
    ((cert_status == 0)) || die "Не удалось выпустить сертификаты; Nginx панели снова запущен"

    local backup_dir path
    backup_dir="/root/vds-migration-backups/nginx-$(date +%Y%m%d-%H%M%S)"
    local -a managed_paths=(
        /etc/nginx/stream-enabled/docker-apps.conf
        /etc/nginx/stream-sni.d/docker-apps.conf
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
        warn "Проверка Nginx не пройдена; восстанавливаю прежние файлы приложений"
        for path in "${managed_paths[@]}"; do
            rm -f "$path"
            if [[ -e "$backup_dir$path" || -L "$backup_dir$path" ]]; then
                cp -a "$backup_dir$path" "$path"
            fi
        done
        nginx -t || true
        die "Изменения конфигурации Nginx для приложений отменены"
    fi

    systemctl reload nginx
    ok "Nginx перезагружен; stream.conf панели не изменён"

    log "Проверка HTTPS приложений"
    for domain in "${APP_DOMAINS[@]}"; do
        curl -sS --max-time 20 -o /dev/null "https://$domain/" ||
            die "HTTPS-проверка не пройдена: $domain. Watchtower не установлен"
        ok "https://$domain/ отвечает"
    done

    # Watchtower is deliberately last: it must not update images mid-migration.
    install_watchtower

    cat <<'EOF'

Миграция завершена.
Старые контейнеры приложений остаются остановленными. Не изменяйте старый
сервер некоторое время: он понадобится для отката, пока вы проверяете входы,
сессии, базы данных и обновления.
EOF
    next_step "Проверьте состояние контейнеров: docker ps"
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
        command -v rsync >/dev/null || die "Локальный rsync не установлен"
        ssh_old true || die "SSH-подключение не удалось"
        check_remote_sources
        sync_projects no
        next_step "Когда будете готовы остановить старые приложения: sudo vds-migrate --cutover"
        ;;
    --cutover)      run_cutover ;;
    --tls)          run_tls ;;
    --watchtower)
        install_watchtower
        next_step "Проверьте состояние контейнеров: docker ps"
        ;;
esac
