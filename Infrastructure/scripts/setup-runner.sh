#!/bin/bash
set -e

# ─────────────────────────────────────────
#  GitHub Actions Runner Setup Script
#  Ubuntu 22.04 | Docker + Ansible + Runner
# ─────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# ── Параметры ──────────────────────────────
RUNNER_USER="runner"
RUNNER_DIR="/home/${RUNNER_USER}/actions-runner"
RUNNER_VERSION="2.317.0"

# Передаются как аргументы скрипта:
# ./setup-runner.sh <GITHUB_URL> <RUNNER_TOKEN> <RUNNER_NAME> <DEPLOY_PRIVATE_KEY> <RUNNER_TAGS>
#
# Пример:
# ./setup-runner.sh https://github.com/your-org ghp_tokenXXX runner-01 "$(cat deploy_key)" "vpn,production"

GITHUB_URL="${1:?'Укажи GitHub URL (https://github.com/org или https://github.com/org/repo)'}"
RUNNER_TOKEN="${2:?'Укажи токен раннера из GitHub Settings → Actions → Runners → New runner'}"
RUNNER_NAME="${3:-$(hostname)}"
DEPLOY_KEY="${4:-}"  # опционально
RUNNER_TAGS="${5:-vpn}"  # опционально, по умолчанию "vpn"

# ── Проверка ОС ────────────────────────────
[[ "$(lsb_release -si)" != "Ubuntu" ]] && error "Скрипт рассчитан на Ubuntu"
[[ "$EUID" -ne 0 ]] && error "Запусти с sudo"

log "Начинаем настройку раннера: ${RUNNER_NAME}"

# ── 1. Обновление системы ──────────────────
log "Обновление пакетов..."
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
    curl wget git unzip jq \
    ca-certificates gnupg lsb-release \
    python3 python3-pip python3-venv \
    software-properties-common \
    apt-transport-https

# ── 2. Docker ──────────────────────────────
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
    apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
    systemctl enable --now docker
    log "Docker установлен: $(docker --version)"
fi

# ── 3. Пользователь раннера ─────────────────
log "Создание пользователя ${RUNNER_USER}..."
if id "${RUNNER_USER}" &>/dev/null; then
    warn "Пользователь ${RUNNER_USER} уже существует"
else
    useradd -m -s /bin/bash "${RUNNER_USER}"
fi

# Добавляем в docker группу (чтобы не нужен был sudo для docker)
usermod -aG docker "${RUNNER_USER}"
log "Пользователь ${RUNNER_USER} добавлен в группу docker"

# ── 4. Ansible ─────────────────────────────
log "Установка Ansible..."
if command -v ansible &>/dev/null; then
    warn "Ansible уже установлен, пропускаем"
else
    sudo -u "${RUNNER_USER}" pip3 install --user ansible --quiet
    # Добавляем ~/.local/bin в PATH
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> /home/${RUNNER_USER}/.bashrc
    log "Ansible установлен: $(sudo -u ${RUNNER_USER} /home/${RUNNER_USER}/.local/bin/ansible --version | head -1)"
fi

# ── 5. SSH ключ для деплоя ─────────────────
if [[ -n "${DEPLOY_KEY}" ]]; then
    log "Настройка deploy SSH ключа..."
    SSH_DIR="/home/${RUNNER_USER}/.ssh"
    mkdir -p "${SSH_DIR}"
    echo "${DEPLOY_KEY}" > "${SSH_DIR}/deploy_key"
    chmod 600 "${SSH_DIR}/deploy_key"
    chmod 700 "${SSH_DIR}"
    chown -R "${RUNNER_USER}:${RUNNER_USER}" "${SSH_DIR}"

    # Добавляем в ssh config чтобы использовался по умолчанию
    cat > "${SSH_DIR}/config" <<EOF
Host *
    IdentityFile ~/.ssh/deploy_key
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
EOF
    chmod 600 "${SSH_DIR}/config"
    log "Deploy ключ настроен"
else
    warn "Deploy ключ не передан, настрой вручную: /home/${RUNNER_USER}/.ssh/deploy_key"
fi

# ── 6. GitHub Actions Runner ───────────────
log "Установка GitHub Actions Runner v${RUNNER_VERSION}..."
mkdir -p "${RUNNER_DIR}"
chown "${RUNNER_USER}:${RUNNER_USER}" "${RUNNER_DIR}"

cd "${RUNNER_DIR}"

ARCH="x64"
[[ "$(uname -m)" == "aarch64" ]] && ARCH="arm64"

RUNNER_ARCHIVE="actions-runner-linux-${ARCH}-${RUNNER_VERSION}.tar.gz"

if [[ ! -f "${RUNNER_DIR}/run.sh" ]]; then
    sudo -u "${RUNNER_USER}" curl -sSfL \
        "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_ARCHIVE}" \
        -o "${RUNNER_ARCHIVE}"
    sudo -u "${RUNNER_USER}" tar xzf "${RUNNER_ARCHIVE}"
    rm -f "${RUNNER_ARCHIVE}"
else
    warn "Раннер уже распакован, пропускаем загрузку"
fi

# ── 7. Регистрация раннера ─────────────────
log "Регистрация раннера в GitHub..."
sudo -u "${RUNNER_USER}" "${RUNNER_DIR}/config.sh" \
    --url "${GITHUB_URL}" \
    --token "${RUNNER_TOKEN}" \
    --name "${RUNNER_NAME}" \
    --labels "self-hosted,linux,x64,${RUNNER_TAGS}" \
    --work "_work" \
    --unattended \
    --replace

# ── 8. Автоочистка Docker образов (cron) ───
log "Настройка ежедневной очистки Docker..."
CLEANUP_SCRIPT="/usr/local/bin/docker-cleanup.sh"

cat > "${CLEANUP_SCRIPT}" <<'EOF'
#!/bin/bash
# Удаляет все неиспользуемые образы, контейнеры, сети и кэш сборки
# Запускается ежедневно в 3:00

LOG="/var/log/docker-cleanup.log"
echo "=== $(date '+%Y-%m-%d %H:%M:%S') ===" >> "$LOG"

# Остановленные контейнеры
docker container prune -f >> "$LOG" 2>&1

# Образы без тега и не привязанные ни к одному контейнеру
docker image prune -af >> "$LOG" 2>&1

# Неиспользуемые сети
docker network prune -f >> "$LOG" 2>&1

# Кэш сборки старше 7 дней
docker buildx prune -f --filter "until=168h" >> "$LOG" 2>&1

echo "Disk after cleanup: $(df -h / | tail -1 | awk '{print $4}') free" >> "$LOG"
EOF

chmod +x "${CLEANUP_SCRIPT}"

# Добавляем в cron — каждый день в 3:00 ночи
(crontab -l 2>/dev/null | grep -v "docker-cleanup"; echo "0 3 * * * ${CLEANUP_SCRIPT}") | crontab -

log "Очистка Docker настроена (каждый день в 3:00, лог: /var/log/docker-cleanup.log)"

# ── 9. Systemd сервис ──────────────────────
log "Настройка автозапуска через systemd..."
"${RUNNER_DIR}/svc.sh" install "${RUNNER_USER}"
"${RUNNER_DIR}/svc.sh" start

systemctl enable "actions.runner.*" 2>/dev/null || true

# ── Итог ───────────────────────────────────
echo ""
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${GREEN}  Раннер успешно настроен!${NC}"
echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Имя раннера : ${RUNNER_NAME}"
echo "  Теги        : self-hosted,linux,x64,${RUNNER_TAGS}"
echo "  GitHub URL  : ${GITHUB_URL}"
echo "  Директория  : ${RUNNER_DIR}"
echo "  Пользователь: ${RUNNER_USER}"
echo ""
echo "  Полезные команды:"
echo "  systemctl status actions.runner.*          # статус раннера"
echo "  systemctl restart actions.runner.*         # перезапуск раннера"
echo "  journalctl -u actions.runner.* -f          # логи раннера"
echo "  cat /var/log/docker-cleanup.log            # лог очистки образов"
echo "  /usr/local/bin/docker-cleanup.sh           # запустить очистку вручную"
echo ""
echo -e "${YELLOW}  Если не передал deploy ключ — добавь вручную:${NC}"
echo "  /home/${RUNNER_USER}/.ssh/deploy_key"
echo ""
