#!/usr/bin/env bash
set -Eeuo pipefail
trap 'echo; echo "[ERROR] 安裝失敗，行號: $LINENO，指令: $BASH_COMMAND" >&2' ERR

# ============================================================
# Pterodactyl Panel + Wings Interactive Installer
# Ubuntu 22.04 / 24.04
# - Panel dependencies, MariaDB, Redis, PHP 8.3, Nginx, Composer
# - Queue worker + scheduler
# - Optional Let's Encrypt
# - Optional Wings + Docker
# - Optional FRP-friendly Wings local ports
# - systemd auto-start
# ============================================================

C_RESET='\033[0m'
C_GREEN='\033[1;32m'
C_YELLOW='\033[1;33m'
C_RED='\033[1;31m'
C_CYAN='\033[1;36m'

info(){ echo -e "${C_CYAN}[INFO]${C_RESET} $*"; }
ok(){ echo -e "${C_GREEN}[OK]${C_RESET} $*"; }
warn(){ echo -e "${C_YELLOW}[WARN]${C_RESET} $*"; }
die(){ echo -e "${C_RED}[ERROR]${C_RESET} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "請使用 root 執行：sudo -i"

source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "目前腳本只支援 Ubuntu 22.04 / 24.04。"
case "${VERSION_ID:-}" in
  "22.04"|"24.04") ;;
  *) die "不支援的 Ubuntu 版本：${VERSION_ID:-unknown}" ;;
esac

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64) WINGS_ARCH="amd64" ;;
  aarch64|arm64) WINGS_ARCH="arm64" ;;
  *) die "不支援的 CPU 架構：$ARCH" ;;
esac

prompt_default() {
  local __var="$1" __text="$2" __default="$3" __value
  read -r -p "$__text [$__default]: " __value
  printf -v "$__var" '%s' "${__value:-$__default}"
}

prompt_required() {
  local __var="$1" __text="$2" __value=""
  while [[ -z "$__value" ]]; do
    read -r -p "$__text: " __value
  done
  printf -v "$__var" '%s' "$__value"
}

prompt_secret() {
  local __var="$1" __text="$2" __value=""
  while [[ -z "$__value" ]]; do
    read -r -s -p "$__text: " __value
    echo
  done
  printf -v "$__var" '%s' "$__value"
}

confirm() {
  local text="$1" default="${2:-N}" ans
  if [[ "$default" == "Y" ]]; then
    read -r -p "$text [Y/n]: " ans
    ans="${ans:-Y}"
  else
    read -r -p "$text [y/N]: " ans
    ans="${ans:-N}"
  fi
  [[ "$ans" =~ ^[Yy]$ ]]
}

valid_admin_password() {
  local p="$1"
  [[ ${#p} -ge 8 ]] &&
  [[ "$p" =~ [A-Z] ]] &&
  [[ "$p" =~ [a-z] ]] &&
  [[ "$p" =~ [0-9] ]]
}

install_base_deps() {
  info "安裝基礎工具..."
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y software-properties-common curl ca-certificates gnupg lsb-release \
    apt-transport-https tar unzip git cron openssl sqlite3 jq

  if [[ "$VERSION_ID" == "22.04" ]]; then
    info "Ubuntu 22.04：加入 PHP 8.3 套件庫..."
    LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php
    apt-get update -y
  fi

  info "安裝 Panel 所有必要依賴..."
  apt-get install -y \
    php8.3 php8.3-common php8.3-cli php8.3-gd php8.3-mysql php8.3-mbstring \
    php8.3-bcmath php8.3-xml php8.3-fpm php8.3-curl php8.3-zip \
    mariadb-server nginx redis-server certbot python3-certbot-nginx

  systemctl enable --now mariadb redis-server php8.3-fpm nginx cron
}

install_composer() {
  if ! command -v composer >/dev/null 2>&1; then
    info "安裝 Composer 2..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer-setup.php
  fi
  composer --version
}

configure_database() {
  info "建立 MariaDB 資料庫與使用者..."
  mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS_SQL}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${DB_PASS_SQL}';
CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS_SQL}';
ALTER USER '${DB_USER}'@'localhost' IDENTIFIED BY '${DB_PASS_SQL}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'localhost';
FLUSH PRIVILEGES;
SQL
}

download_panel() {
  info "下載最新穩定版 Pterodactyl Panel..."
  mkdir -p /var/www/pterodactyl
  cd /var/www/pterodactyl

  if [[ -f artisan || -f .env ]]; then
    BACKUP="/root/pterodactyl-panel-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    warn "偵測到既有 Panel 檔案，先備份至 $BACKUP"
    tar -czf "$BACKUP" -C /var/www pterodactyl
    rm -rf /var/www/pterodactyl/*
    rm -rf /var/www/pterodactyl/.[!.]* /var/www/pterodactyl/..?* 2>/dev/null || true
  fi

  curl -fL "https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz" -o /tmp/panel.tar.gz
  tar -xzf /tmp/panel.tar.gz -C /var/www/pterodactyl
  rm -f /tmp/panel.tar.gz

  chmod -R 755 storage bootstrap/cache
  cp .env.example .env

  info "安裝 PHP 套件..."
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction

  php artisan key:generate --force
}

configure_panel_env() {
  cd /var/www/pterodactyl

  info "設定 Pterodactyl 環境..."
  php artisan p:environment:setup -n \
    --author="$PANEL_EMAIL" \
    --url="$APP_URL" \
    --timezone="$TIMEZONE" \
    --cache=redis \
    --session=database \
    --queue=redis \
    --redis-host=127.0.0.1 \
    --redis-port=6379

  php artisan p:environment:database -n \
    --host=127.0.0.1 \
    --port=3306 \
    --database="$DB_NAME" \
    --username="$DB_USER" \
    --password="$DB_PASS"

  # 不強迫 SMTP；預設寫入 log，之後可在 .env 自行改郵件設定。
  sed -i 's/^MAIL_MAILER=.*/MAIL_MAILER=log/' .env 2>/dev/null || true

  php artisan migrate --seed --force

  info "建立管理員帳號..."
  php artisan p:user:make \
    --email="$ADMIN_EMAIL" \
    --username="$ADMIN_USER" \
    --name-first="$ADMIN_FIRST" \
    --name-last="$ADMIN_LAST" \
    --password="$ADMIN_PASS" \
    --admin=1
}

configure_nginx_http() {
  cat >/etc/nginx/sites-available/pterodactyl.conf <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_DOMAIN};

    root /var/www/pterodactyl/public;
    index index.php;

    access_log /var/log/nginx/pterodactyl.app-access.log;
    error_log  /var/log/nginx/pterodactyl.app-error.log error;

    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param PHP_VALUE "upload_max_filesize = 100M \n post_max_size=100M";
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_intercept_errors off;
        fastcgi_buffer_size 16k;
        fastcgi_buffers 4 16k;
        fastcgi_connect_timeout 300;
        fastcgi_send_timeout 300;
        fastcgi_read_timeout 300;
    }

    location ~ /\.ht {
        deny all;
    }
}
NGINX

  rm -f /etc/nginx/sites-enabled/default
  ln -sfn /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
  nginx -t
  systemctl restart nginx
}

configure_panel_services() {
  info "建立 Pterodactyl Queue Worker 與 Scheduler..."

  cat >/etc/systemd/system/pteroq.service <<'EOF'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service mariadb.service
Wants=redis-server.service mariadb.service

[Service]
User=www-data
Group=www-data
Restart=always
ExecStart=/usr/bin/php /var/www/pterodactyl/artisan queue:work --queue=high,standard,low --sleep=3 --tries=3
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  cat >/etc/cron.d/pterodactyl <<'EOF'
* * * * * www-data /usr/bin/php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1
EOF
  chmod 644 /etc/cron.d/pterodactyl

  chown -R www-data:www-data /var/www/pterodactyl
  chmod -R 755 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache

  systemctl daemon-reload
  systemctl enable --now pteroq.service
  systemctl enable --now nginx mariadb redis-server php8.3-fpm cron
}

configure_panel_ssl() {
  case "$PANEL_MODE" in
    1)
      info "使用 Let's Encrypt 為 Panel 申請 HTTPS..."
      warn "這需要 ${PANEL_DOMAIN}:80 和 :443 能從 Internet 直接連入此機器。"
      certbot --nginx --non-interactive --agree-tos --redirect \
        -m "$PANEL_EMAIL" -d "$PANEL_DOMAIN"
      ;;
    2)
      info "Panel 使用反向代理 / Cloudflare Tunnel 模式：Origin 保持 HTTP。"
      warn "請讓反向代理把 https://${PANEL_DOMAIN} 轉到此機器的 http://127.0.0.1:80 或 http://主機IP:80。"
      ;;
    3)
      info "Panel 保持純 HTTP。"
      ;;
  esac
}

install_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    info "安裝 Docker CE..."
    curl -fsSL https://get.docker.com/ | CHANNEL=stable bash
  fi
  systemctl enable --now docker
  docker info >/dev/null
}

install_wings_binary() {
  info "下載最新穩定版 Wings..."
  mkdir -p /etc/pterodactyl /var/lib/pterodactyl/volumes
  curl -fL -o /usr/local/bin/wings \
    "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WINGS_ARCH}"
  chmod +x /usr/local/bin/wings
  wings --version || true
}

create_wings_service() {
  cat >/etc/systemd/system/wings.service <<'EOF'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
PartOf=docker.service

[Service]
User=root
WorkingDirectory=/etc/pterodactyl
LimitNOFILE=4096
PIDFile=/var/run/wings/daemon.pid
ExecStart=/usr/local/bin/wings
Restart=on-failure
StartLimitInterval=180
StartLimitBurst=30
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

obtain_node_cert_cloudflare() {
  apt-get install -y python3-certbot-dns-cloudflare
  mkdir -p /root/.secrets/certbot
  chmod 700 /root/.secrets/certbot

  prompt_secret CF_TOKEN "Cloudflare API Token（Zone DNS Edit + Zone Read）"
  cat >/root/.secrets/certbot/cloudflare.ini <<EOF
dns_cloudflare_api_token = ${CF_TOKEN}
EOF
  chmod 600 /root/.secrets/certbot/cloudflare.ini

  certbot certonly --non-interactive --agree-tos \
    --dns-cloudflare \
    --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini \
    -m "$PANEL_EMAIL" \
    -d "$NODE_FQDN"

  NODE_CERT="/etc/letsencrypt/live/${NODE_FQDN}/fullchain.pem"
  NODE_KEY="/etc/letsencrypt/live/${NODE_FQDN}/privkey.pem"
}

install_node_flow() {
  echo
  echo "============================================================"
  echo "                 Wings / Node 部署"
  echo "============================================================"

  install_docker
  install_wings_binary
  create_wings_service

  prompt_default NODE_NAME "Node 名稱（只作提示用途）" "node1"
  prompt_required NODE_FQDN "Node FQDN，例如 node1.example.com"
  prompt_default NODE_API_LOCAL "Wings 本機 API Port" "8080"
  prompt_default NODE_SFTP_LOCAL "Wings 本機 SFTP Port" "2022"
  prompt_default NODE_DATA "遊戲資料目錄" "/var/lib/pterodactyl/volumes"

  echo
  if confirm "這個 Node 是否透過 FRP/NAT 對外？" "Y"; then
    NODE_FRP="yes"
    prompt_default NODE_API_EXTERNAL "FRP 對外 Wings API Port" "20020"
    prompt_default NODE_SFTP_EXTERNAL "FRP 對外 SFTP Port" "20021"
  else
    NODE_FRP="no"
    NODE_API_EXTERNAL="$NODE_API_LOCAL"
    NODE_SFTP_EXTERNAL="$NODE_SFTP_LOCAL"
  fi

  echo
  echo "Wings SSL 模式："
  echo "  [1] HTTP（Panel 若是 HTTPS，瀏覽器可能會擋 Mixed Content）"
  echo "  [2] Cloudflare DNS-01 自動簽 Node 憑證（推薦內網/FRP）"
  echo "  [3] 使用既有憑證檔案"
  read -r -p "選擇 [1-3]: " NODE_SSL_MODE
  case "${NODE_SSL_MODE:-1}" in
    1)
      NODE_SSL="false"
      NODE_CERT=""
      NODE_KEY=""
      ;;
    2)
      NODE_SSL="true"
      obtain_node_cert_cloudflare
      ;;
    3)
      NODE_SSL="true"
      prompt_required NODE_CERT "fullchain.pem 完整路徑"
      prompt_required NODE_KEY "privkey.pem 完整路徑"
      [[ -f "$NODE_CERT" ]] || die "找不到憑證：$NODE_CERT"
      [[ -f "$NODE_KEY" ]] || die "找不到私鑰：$NODE_KEY"
      ;;
    *)
      die "無效選項。"
      ;;
  esac

  echo
  echo -e "${C_YELLOW}現在請到 Panel 建立 Node：${C_RESET}"
  echo "  1. ${APP_URL}/admin → Locations 建立 Location（若尚未建立）"
  echo "  2. Nodes → Create New"
  echo "  3. FQDN：${NODE_FQDN}"
  if [[ "$NODE_SSL" == "true" ]]; then
    echo "  4. Communicate Over SSL：Use SSL Connection"
  else
    echo "  4. Communicate Over SSL：Use HTTP Connection"
  fi
  echo "  5. Daemon Port：${NODE_API_EXTERNAL}"
  echo "  6. Daemon SFTP Port：${NODE_SFTP_EXTERNAL}"
  if [[ "$NODE_FRP" == "yes" ]]; then
    echo "  7. FRP：外部 ${NODE_API_EXTERNAL} → 本機 ${NODE_API_LOCAL}"
    echo "          外部 ${NODE_SFTP_EXTERNAL} → 本機 ${NODE_SFTP_LOCAL}"
  fi
  echo
  echo "建立完成後，打開 Node → Configuration。"
  echo "請從那份 config.yml 複製以下 3 個值。"
  read -r -p "準備好後按 Enter 繼續..."

  prompt_required NODE_UUID "uuid"
  prompt_required NODE_TOKEN_ID "token_id"
  prompt_secret NODE_TOKEN "token"

  cat >/etc/pterodactyl/config.yml <<EOF
debug: false
uuid: ${NODE_UUID}
token_id: ${NODE_TOKEN_ID}
token: ${NODE_TOKEN}

api:
  host: 0.0.0.0
  port: ${NODE_API_LOCAL}
  ssl:
    enabled: ${NODE_SSL}
EOF

  if [[ "$NODE_SSL" == "true" ]]; then
    cat >>/etc/pterodactyl/config.yml <<EOF
    cert: ${NODE_CERT}
    key: ${NODE_KEY}
EOF
  fi

  cat >>/etc/pterodactyl/config.yml <<EOF
  upload_limit: 100

system:
  data: ${NODE_DATA}
  sftp:
    bind_port: ${NODE_SFTP_LOCAL}

allowed_mounts: []

remote: '${APP_URL}'
EOF

  chmod 600 /etc/pterodactyl/config.yml

  systemctl reset-failed wings 2>/dev/null || true
  systemctl enable --now wings
  sleep 2

  if systemctl is-active --quiet wings; then
    ok "Wings 已啟動並設為開機自啟。"
  else
    warn "Wings 沒有成功啟動。最近日誌："
    journalctl -u wings -n 50 --no-pager -l || true
    return 1
  fi

  echo
  ss -lntp | grep -E ":(${NODE_API_LOCAL}|${NODE_SFTP_LOCAL})\b" || true

  if [[ "$NODE_FRP" == "yes" ]]; then
    echo
    warn "FRP 還需要在你的 FRP Panel 建立："
    echo "  TCP ${NODE_API_EXTERNAL}  →  127.0.0.1:${NODE_API_LOCAL}"
    echo "  TCP ${NODE_SFTP_EXTERNAL} → 127.0.0.1:${NODE_SFTP_LOCAL}"
    echo "如果 Pterodactyl Docker allocation 綁在 docker bridge（例如 172.18.0.1），遊戲 Port 的 FRP localIP 要用實際 bridge IP，不要固定寫 127.0.0.1。"
  fi
}

panel_questions() {
  clear || true
  echo "============================================================"
  echo "       Pterodactyl Panel + Wings 一鍵互動安裝器"
  echo "============================================================"
  echo
  echo "Panel 需要的資料會先全部問完；Panel 裝好後才會詢問 Node。"
  echo

  prompt_required PANEL_DOMAIN "Panel 網域，例如 panel.example.com"
  PANEL_DOMAIN="${PANEL_DOMAIN#http://}"
  PANEL_DOMAIN="${PANEL_DOMAIN#https://}"
  PANEL_DOMAIN="${PANEL_DOMAIN%%/*}"

  prompt_default PANEL_EMAIL "Let's Encrypt / Panel Email" "admin@example.com"
  prompt_default TIMEZONE "時區" "Asia/Taipei"

  echo
  echo "Panel 對外方式："
  echo "  [1] 公網直連 + Let's Encrypt HTTPS（80/443 必須能從外網連入）"
  echo "  [2] Cloudflare Tunnel / 反向代理（Origin HTTP，外部 HTTPS）"
  echo "  [3] 純 HTTP"
  read -r -p "選擇 [1-3]: " PANEL_MODE
  case "${PANEL_MODE:-}" in
    1|2) APP_URL="https://${PANEL_DOMAIN}" ;;
    3) APP_URL="http://${PANEL_DOMAIN}" ;;
    *) die "無效選項。" ;;
  esac

  prompt_default DB_NAME "資料庫名稱" "panel"
  prompt_default DB_USER "資料庫使用者" "pterodactyl"

  read -r -s -p "資料庫密碼（留空自動產生）: " DB_PASS
  echo
  if [[ -z "$DB_PASS" ]]; then
    DB_PASS="$(tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
    ok "已自動產生資料庫密碼。"
  fi
  DB_PASS_SQL="${DB_PASS//\'/\'\'}"

  echo
  echo "第一個管理員帳號："
  prompt_default ADMIN_EMAIL "管理員 Email" "$PANEL_EMAIL"
  prompt_default ADMIN_USER "管理員 Username" "admin"
  prompt_default ADMIN_FIRST "First name" "Admin"
  prompt_default ADMIN_LAST "Last name" "User"

  while true; do
    prompt_secret ADMIN_PASS "管理員密碼（至少8碼、大小寫英文字母+數字）"
    if valid_admin_password "$ADMIN_PASS"; then break; fi
    warn "密碼不符合要求：至少 8 碼，包含大寫、小寫、數字。"
  done

  echo
  echo "---------------- 安裝摘要 ----------------"
  echo "Panel URL     : $APP_URL"
  echo "Timezone      : $TIMEZONE"
  echo "DB            : $DB_NAME / $DB_USER"
  echo "Admin         : $ADMIN_EMAIL ($ADMIN_USER)"
  echo "Ubuntu        : $VERSION_ID"
  echo "------------------------------------------"
  confirm "開始安裝 Panel？" "Y" || exit 0
}

install_panel_flow() {
  panel_questions
  install_base_deps
  install_composer
  configure_database
  download_panel
  configure_panel_env
  configure_nginx_http
  configure_panel_services
  configure_panel_ssl

  cd /var/www/pterodactyl
  php artisan optimize:clear >/dev/null || true

  ok "Pterodactyl Panel 安裝完成！"
  echo
  echo "Panel：$APP_URL"
  echo "管理員：$ADMIN_EMAIL"
  echo "資料庫密碼已寫入 /var/www/pterodactyl/.env（不另外輸出密碼）。"
  echo

  systemctl --no-pager --full status nginx pteroq redis-server mariadb php8.3-fpm 2>/dev/null | grep -E '●|Active:' || true

  echo
  if confirm "Panel 已完成。現在要在『這台機器』部署 Wings Node 嗎？" "Y"; then
    install_node_flow
  else
    info "略過 Wings。之後可重新執行本腳本並選 Node-only。"
  fi
}

node_only_flow() {
  # Node-only 也需要 Panel URL 作為 remote。
  echo "============================================================"
  echo "                 Wings Node-only 安裝"
  echo "============================================================"
  prompt_required APP_URL "Panel 完整網址，例如 https://panel.example.com"
  APP_URL="${APP_URL%/}"
  prompt_default PANEL_EMAIL "憑證 Email（若使用 DNS-01）" "admin@example.com"
  install_base_node_packages
  install_node_flow
}

install_base_node_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg openssl certbot
}

main() {
  echo "選擇模式："
  echo "  [1] 安裝 Panel，成功後再詢問是否部署 Node（推薦）"
  echo "  [2] 只部署 Wings Node"
  read -r -p "選擇 [1-2] [1]: " MODE
  MODE="${MODE:-1}"

  case "$MODE" in
    1) install_panel_flow ;;
    2) node_only_flow ;;
    *) die "無效選項。" ;;
  esac

  echo
  ok "全部完成。"
  echo "自啟服務可用以下指令確認："
  echo "  systemctl is-enabled nginx mariadb redis-server php8.3-fpm pteroq docker wings 2>/dev/null"
}

main "$@"
