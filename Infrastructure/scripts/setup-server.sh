#!/bin/bash
set -e

# ─────────────────────────────────────────
#  Server Setup Script
#  Ubuntu 22.04/24.04
#  Docker + Ansible deps + Swarm + Traefik + Yandex CR
# ─────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()   { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── Параметры ──────────────────────────────────────────────────────────────────
# ./setup-server.sh <YCR_TOKEN> [--swarm] [--swarm-advertise-addr <IP>]
#
# Примеры:
#   Только Docker + deps:
#     ./setup-server.sh "ycr_token_xxx"
#
#   Docker + Swarm + Traefik:
#     ./setup-server.sh "ycr_token_xxx" --swarm
#
#   Docker + Swarm + Traefik с явным IP (если несколько сетевых интерфейсов):
#     ./setup-server.sh "ycr_token_xxx" --swarm --swarm-advertise-addr 10.0.0.5

YCR_TOKEN="${1:?'Укажи токен Yandex Container Registry (IAM или OAuth)'}"
SETUP_SWARM=false
SWARM_ADVERTISE_ADDR=""

# Автоопределение типа токена
# IAM токен начинается с t1. — остальное OAuth
if [[ "${YCR_TOKEN}" == t1.* ]]; then
    YCR_TOKEN_TYPE="iam"
else
    YCR_TOKEN_TYPE="oauth"
fi

# Парсим остальные аргументы
shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --swarm)
            SETUP_SWARM=true
            shift
            ;;
        --swarm-advertise-addr)
            SWARM_ADVERTISE_ADDR="$2"
            shift 2
            ;;
        *)
            warn "Неизвестный аргумент: $1"
            shift
            ;;
    esac
done

[[ "$(lsb_release -si)" != "Ubuntu" ]] && error "Скрипт рассчитан на Ubuntu"
[[ "$EUID" -ne 0 ]] && error "Запусти с sudo"

log "Начинаем настройку сервера..."
log "Swarm: ${SETUP_SWARM}"

# ── 1. Обновление системы ───────────────────────────────────────────────────────
log "Обновление пакетов..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget git unzip jq \
    ca-certificates gnupg lsb-release \
    software-properties-common \
    apt-transport-https \
    python3 python3-pip python3-venv \
    python3-apt python3-docker \
    sshpass \
    acl

# ── 2. Docker ───────────────────────────────────────────────────────────────────
log "Установка Docker..."
if command -v docker &>/dev/null; then
    warn "Docker уже установлен, пропускаем"
else
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
        | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
        https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
        > /etc/apt/sources.list.d/docker.list

    apt-get update -qq
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
    systemctl enable --now docker
    log "Docker установлен: $(docker --version)"
fi

# ── 3. Авторизация в Yandex Container Registry ─────────────────────────────────
log "Авторизация в Yandex Container Registry (тип токена: ${YCR_TOKEN_TYPE})..."
echo "${YCR_TOKEN}" | docker login --username "${YCR_TOKEN_TYPE}" --password-stdin cr.yandex
log "Авторизация успешна"

# Чтобы авторизация сохранялась после перезагрузки — прописываем в cron
CRON_CMD="echo '${YCR_TOKEN}' | docker login --username ${YCR_TOKEN_TYPE} --password-stdin cr.yandex"
(crontab -l 2>/dev/null | grep -v "cr.yandex"; echo "@reboot ${CRON_CMD}") | crontab -
log "Авторизация YCR настроена при перезагрузке"

# ── 4. Swarm + Traefik ─────────────────────────────────────────────────────────
if [[ "${SETUP_SWARM}" == "true" ]]; then

    # Инициализация Swarm
    if docker info 2>/dev/null | grep -q "Swarm: active"; then
        warn "Swarm уже активен, пропускаем инициализацию"
    else
        log "Инициализация Docker Swarm..."
        if [[ -n "${SWARM_ADVERTISE_ADDR}" ]]; then
            docker swarm init --advertise-addr "${SWARM_ADVERTISE_ADDR}"
        else
            docker swarm init --advertise-addr "$(hostname -I | awk '{print $1}')"
        fi
        log "Swarm инициализирован"
    fi

    # Сеть для Traefik
    if ! docker network ls | grep -q "traefik-public"; then
        log "Создание сети traefik-public..."
        docker network create --driver overlay --attachable traefik-public
    else
        warn "Сеть traefik-public уже существует"
    fi

    # Деплой Traefik
    if docker service ls | grep -q "traefik"; then
        warn "Traefik уже запущен, пропускаем"
    else
        log "Деплой Traefik..."

        # Создаём volume для сертификатов
        docker volume create traefik-certificates 2>/dev/null || true

        docker service create \
            --name traefik \
            --constraint "node.role==manager" \
            --publish published=80,target=80 \
            --publish published=443,target=443 \
            --publish published=8080,target=8080 \
            --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
            --mount type=volume,source=traefik-certificates,target=/certificates \
            --network traefik-public \
            --label "traefik.enable=true" \
            --label "traefik.constraint-label=traefik-public" \
            --label "traefik.http.routers.traefik-dashboard-http.rule=Host(\`traefik.localhost\`)" \
            --label "traefik.http.routers.traefik-dashboard-http.entrypoints=http" \
            --label "traefik.http.services.traefik-dashboard.loadbalancer.server.port=8080" \
            traefik:v3.0 \
            --providers.swarm=true \
            --providers.swarm.exposedByDefault=false \
            --providers.swarm.constraints="Label(\`traefik.constraint-label\`, \`traefik-public\`)" \
            --entrypoints.http.address=:80 \
            --entrypoints.https.address=:443 \
            --certificatesresolvers.le.acme.email=admin@localhost.ru \
            --certificatesresolvers.le.acme.storage=/certificates/acme.json \
            --certificatesresolvers.le.acme.tlschallenge=true \
            --accesslog \
            --log \
            --log.level=INFO

        log "Traefik запущен"
    fi

fi

# ── 5. Публичный ключ для Ansible ──────────────────────────────────────────────
# Ищем публичный ключ в стандартных местах
DEPLOY_PUB_KEY=""
for PUB_PATH in /tmp/deploy_key/deploy_key.pub /tmp/deploy_key.pub /root/deploy_key.pub; do
    if [[ -f "${PUB_PATH}" ]]; then
        DEPLOY_PUB_KEY="$(cat "${PUB_PATH}")"
        log "Публичный deploy ключ найден: ${PUB_PATH}"
        break
    fi
done

if [[ -n "${DEPLOY_PUB_KEY}" ]]; then
    DEPLOY_USER="${SUDO_USER:-ubuntu}"
    DEPLOY_HOME=$(getent passwd "${DEPLOY_USER}" | cut -d: -f6)
    mkdir -p "${DEPLOY_HOME}/.ssh"
    # Добавляем только если ещё нет
    if ! grep -qF "${DEPLOY_PUB_KEY}" "${DEPLOY_HOME}/.ssh/authorized_keys" 2>/dev/null; then
        echo "${DEPLOY_PUB_KEY}" >> "${DEPLOY_HOME}/.ssh/authorized_keys"
        chmod 600 "${DEPLOY_HOME}/.ssh/authorized_keys"
        chown -R "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_HOME}/.ssh"
        log "Публичный ключ добавлен в authorized_keys для ${DEPLOY_USER}"
    else
        warn "Публичный ключ уже есть в authorized_keys"
    fi
else
    warn "Публичный deploy ключ не найден, добавь вручную в ~/.ssh/authorized_keys"
    warn "Положи deploy_key.pub в /tmp/ и запусти скрипт снова, или добавь вручную:"
    warn "  echo 'ssh-ed25519 AAAA...' >> ~/.ssh/authorized_keys"
fi

# ── Итог ───────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Сервер успешно настроен!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Docker       : $(docker --version)"
echo "  YCR          : авторизован в cr.yandex"
if [[ "${SETUP_SWARM}" == "true" ]]; then
echo "  Swarm        : активен"
echo "  Traefik      : запущен"
echo "  Сеть         : traefik-public"
fi
echo ""
echo "  Полезные команды:"
echo "  docker service ls                  # список сервисов"
echo "  docker service logs traefik -f     # логи Traefik"
echo "  docker network ls                  # список сетей"
echo ""
if [[ "${SETUP_SWARM}" == "true" ]]; then
echo -e "${YELLOW}  Не забудь поменять email для Let's Encrypt в Traefik!${NC}"
echo "  Сейчас стоит: admin@localhost.ru"
echo ""
fi
