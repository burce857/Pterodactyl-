#!/usr/bin/env bash
set -Eeuo pipefail
trap 'rc=$?; echo; echo "[ERROR] line=$LINENO cmd=$BASH_COMMAND exit=$rc" >&2; exit $rc' ERR

GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; CYAN='\033[1;36m'; RESET='\033[0m'
info(){ echo -e "${CYAN}[INFO]${RESET} $*"; }
ok(){ echo -e "${GREEN}[OK]${RESET} $*"; }
warn(){ echo -e "${YELLOW}[WARN]${RESET} $*"; }
die(){ echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "請用 root 執行：sudo -i"
source /etc/os-release
[[ "${ID:-}" == ubuntu ]] || die "只支援 Ubuntu 22.04 / 24.04"
case "${VERSION_ID:-}" in 22.04|24.04) ;; *) die "不支援 Ubuntu ${VERSION_ID:-unknown}";; esac
case "$(uname -m)" in x86_64) WINGS_ARCH=amd64; CF_ARCH=amd64;; aarch64|arm64) WINGS_ARCH=arm64; CF_ARCH=arm64;; *) die "不支援 CPU 架構";; esac

prompt_default(){ local v="$1" m="$2" d="$3" x=""; read -r -p "$m [$d]: " x; printf -v "$v" '%s' "${x:-$d}"; }
prompt_required(){ local v="$1" m="$2" x=""; while [[ -z "$x" ]]; do read -r -p "$m: " x; done; printf -v "$v" '%s' "$x"; }
prompt_secret(){ local v="$1" m="$2" x=""; while [[ -z "$x" ]]; do read -r -s -p "$m: " x; echo; done; printf -v "$v" '%s' "$x"; }
confirm(){ local m="$1" d="${2:-N}" a=""; if [[ "$d" == Y ]]; then read -r -p "$m [Y/n]: " a; a="${a:-Y}"; else read -r -p "$m [y/N]: " a; a="${a:-N}"; fi; [[ "$a" =~ ^[Yy]$ ]]; }
clean_domain(){ local d="$1"; d="${d#http://}"; d="${d#https://}"; d="${d%%/*}"; d="${d%%:*}"; printf '%s' "$d"; }
valid_pw(){ [[ ${#1} -ge 8 && "$1" =~ [A-Z] && "$1" =~ [a-z] && "$1" =~ [0-9] ]]; }

ask_panel(){
  clear || true
  echo "============================================================"
  echo " Pterodactyl Panel + Cloudflare Tunnel + Wings + FRP"
  echo "============================================================"
  echo
  echo "先問完 Panel 資料；Panel 安裝完成後才會開始問 Node。"
  echo
  echo "Panel 安裝完成後，腳本會執行 cloudflared tunnel login。"
  echo "終端會顯示 Cloudflare 授權連結；請用瀏覽器開啟並授權。"
  echo "授權完成後，腳本會再詢問「授權完成了嗎？」才繼續。"
  echo
  prompt_required PANEL_DOMAIN "Panel 網域，例如 p.example.com"
  PANEL_DOMAIN="$(clean_domain "$PANEL_DOMAIN")"
  PANEL_URL="https://${PANEL_DOMAIN}"
  prompt_default TIMEZONE "時區" "Asia/Taipei"
  prompt_required PANEL_EMAIL "管理員 Email"
  prompt_default ADMIN_USER "管理員 Username" "admin"
  prompt_default ADMIN_FIRST "First name" "Admin"
  prompt_default ADMIN_LAST "Last name" "User"
  while true; do prompt_secret ADMIN_PASS "管理員密碼（至少8碼，大小寫+數字）"; valid_pw "$ADMIN_PASS" && break; warn "密碼格式不符合"; done
  prompt_default DB_NAME "MariaDB Database" "panel"
  prompt_default DB_USER "MariaDB User" "pterodactyl"
  read -r -s -p "MariaDB 密碼（Enter 自動產生）: " DB_PASS; echo
  [[ -n "$DB_PASS" ]] || DB_PASS="$(printf '%s%s%s' "$RANDOM" "$(date +%s%N)" "$RANDOM" | sha256sum | cut -c1-32)"
  prompt_default CF_TUNNEL_NAME "Cloudflare Tunnel 名稱" "pterodactyl"
  echo
  echo "Panel URL : $PANEL_URL"
  echo "Database  : $DB_NAME / $DB_USER"
  echo "Tunnel    : $CF_TUNNEL_NAME"
  echo "Web       : Cloudflare Tunnel -> localhost:80"
  confirm "開始安裝 Panel？" Y || exit 0
}

install_panel_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y software-properties-common curl ca-certificates gnupg lsb-release apt-transport-https tar unzip git cron openssl jq python3
  if [[ "$VERSION_ID" == 22.04 ]]; then LC_ALL=C.UTF-8 add-apt-repository -y ppa:ondrej/php; apt-get update -y; fi
  apt-get install -y php8.3 php8.3-common php8.3-cli php8.3-gd php8.3-mysql php8.3-mbstring php8.3-bcmath php8.3-xml php8.3-fpm php8.3-curl php8.3-zip mariadb-server redis-server nginx
  systemctl enable --now mariadb redis-server php8.3-fpm nginx cron
}

install_composer(){
  if ! command -v composer >/dev/null 2>&1; then
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer.php
    php /tmp/composer.php --install-dir=/usr/local/bin --filename=composer
    rm -f /tmp/composer.php
  fi
}

setup_db(){
  local p="${DB_PASS//\'/\'\'}"
  mariadb <<SQL
CREATE DATABASE IF NOT EXISTS \`${DB_NAME}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${p}';
ALTER USER '${DB_USER}'@'127.0.0.1' IDENTIFIED BY '${p}';
GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'127.0.0.1' WITH GRANT OPTION;
FLUSH PRIVILEGES;
SQL
}

set_env(){ python3 - "$1" "$2" <<'PY'
import sys
k,v=sys.argv[1:]
p='/var/www/pterodactyl/.env'
lines=open(p,encoding='utf-8').read().splitlines()
out=[]; done=False
for line in lines:
    if line.startswith(k+'='):
        out.append(f'{k}={v}'); done=True
    else: out.append(line)
if not done: out.append(f'{k}={v}')
open(p,'w',encoding='utf-8').write('\n'.join(out)+'\n')
PY
}

install_panel_files(){
  mkdir -p /var/www/pterodactyl
  if [[ -f /var/www/pterodactyl/artisan || -f /var/www/pterodactyl/.env ]]; then
    local b="/root/pterodactyl-backup-$(date +%Y%m%d-%H%M%S).tar.gz"
    warn "發現舊 Panel，備份：$b"
    tar -czf "$b" -C /var/www pterodactyl
    find /var/www/pterodactyl -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  fi
  cd /var/www/pterodactyl
  curl -fLo panel.tar.gz https://github.com/pterodactyl/panel/releases/latest/download/panel.tar.gz
  tar -xzf panel.tar.gz && rm -f panel.tar.gz
  chmod -R 755 storage bootstrap/cache
  cp .env.example .env
  COMPOSER_ALLOW_SUPERUSER=1 composer install --no-dev --optimize-autoloader --no-interaction
  php artisan key:generate --force
  set_env APP_URL "$PANEL_URL"
  set_env APP_TIMEZONE "$TIMEZONE"
  set_env APP_SERVICE_AUTHOR "$PANEL_EMAIL"
  set_env APP_ENV production
  set_env APP_DEBUG false
  set_env DB_HOST 127.0.0.1
  set_env DB_PORT 3306
  set_env DB_DATABASE "$DB_NAME"
  set_env DB_USERNAME "$DB_USER"
  set_env DB_PASSWORD "$DB_PASS"
  set_env CACHE_STORE redis
  set_env CACHE_DRIVER redis
  set_env SESSION_DRIVER database
  set_env QUEUE_CONNECTION redis
  set_env REDIS_HOST 127.0.0.1
  set_env REDIS_PORT 6379
  set_env TRUSTED_PROXIES 127.0.0.1
  set_env MAIL_MAILER log
  php artisan migrate --seed --force
  php artisan p:user:make --email="$PANEL_EMAIL" --username="$ADMIN_USER" --name-first="$ADMIN_FIRST" --name-last="$ADMIN_LAST" --password="$ADMIN_PASS" --admin=1
}

setup_nginx(){
cat >/etc/nginx/sites-available/pterodactyl.conf <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name ${PANEL_DOMAIN};
    root /var/www/pterodactyl/public;
    index index.php;
    client_max_body_size 100m;
    client_body_timeout 120s;
    sendfile off;

    location / { try_files \$uri \$uri/ /index.php?\$query_string; }

    location ~ \.php\$ {
        fastcgi_split_path_info ^(.+\.php)(/.+)\$;
        fastcgi_pass unix:/run/php/php8.3-fpm.sock;
        fastcgi_index index.php;
        include fastcgi_params;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        fastcgi_param HTTP_PROXY "";
        fastcgi_param HTTP_X_FORWARDED_PROTO https;
        fastcgi_param HTTP_X_FORWARDED_FOR \$http_x_forwarded_for;
        fastcgi_param HTTP_X_FORWARDED_HOST \$host;
        fastcgi_param HTTP_CF_CONNECTING_IP \$http_cf_connecting_ip;
        fastcgi_intercept_errors off;
    }
    location ~ /\.ht { deny all; }
}
NGINX
  rm -f /etc/nginx/sites-enabled/default
  ln -sfn /etc/nginx/sites-available/pterodactyl.conf /etc/nginx/sites-enabled/pterodactyl.conf
  nginx -t
  systemctl restart nginx
}

setup_workers(){
cat >/etc/systemd/system/pteroq.service <<'EOFQ'
[Unit]
Description=Pterodactyl Queue Worker
After=redis-server.service mariadb.service
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
EOFQ
cat >/etc/cron.d/pterodactyl <<'EOFC'
* * * * * www-data /usr/bin/php /var/www/pterodactyl/artisan schedule:run >> /dev/null 2>&1
EOFC
  chmod 644 /etc/cron.d/pterodactyl
  chown -R www-data:www-data /var/www/pterodactyl
  chmod -R 755 /var/www/pterodactyl/storage /var/www/pterodactyl/bootstrap/cache
  systemctl daemon-reload
  systemctl enable --now pteroq nginx mariadb redis-server php8.3-fpm cron
}

setup_cloudflared(){
  info "安裝 / 更新 cloudflared..."

  # 不直接覆蓋正在執行的 binary，避免 Text file busy。
  curl -fL \
    "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH}" \
    -o /tmp/cloudflared.new
  chmod +x /tmp/cloudflared.new

  # mv 置換 pathname，不會因舊 cloudflared 正在執行而出現 ETXTBSY。
  mv -f /tmp/cloudflared.new /usr/local/bin/cloudflared

  mkdir -p /root/.cloudflared /etc/cloudflared

  echo
  echo "============================================================"
  echo " Cloudflare 授權"
  echo "============================================================"
  echo
  echo "接下來會顯示 Cloudflare 授權網址。"
  echo "請在瀏覽器開啟 -> 登入 Cloudflare -> 選擇你的 Zone -> 授權。"
  echo
  echo "cloudflared tunnel login 會等待你在瀏覽器完成授權。"
  echo

  /usr/local/bin/cloudflared tunnel login

  echo
  until confirm "你已經在 Cloudflare 頁面完成授權了嗎？" N; do
    warn "請先完成 Cloudflare 授權。"
    if confirm "要重新執行授權流程嗎？" N; then
      /usr/local/bin/cloudflared tunnel login
    fi
  done

  [[ -f /root/.cloudflared/cert.pem ]] || \
    die "找不到 /root/.cloudflared/cert.pem，Cloudflare 授權未完成。"

  ok "Cloudflare Tunnel 管理授權完成。"

  local tunnel_id creds
  tunnel_id="$(
    /usr/local/bin/cloudflared tunnel list --output json 2>/dev/null \
      | jq -r --arg n "$CF_TUNNEL_NAME" '.[] | select(.name==$n) | .id' \
      | sed -n '1p'
  )"

  if [[ -n "$tunnel_id" ]]; then
    creds="/root/.cloudflared/${tunnel_id}.json"
    if [[ -f "$creds" ]]; then
      ok "使用既有 Tunnel：${CF_TUNNEL_NAME} (${tunnel_id})"
    else
      warn "找到既有 Tunnel：${CF_TUNNEL_NAME} (${tunnel_id})，但本機沒有 credentials JSON。"
      if confirm "要刪除舊 Tunnel 並重新建立嗎？" Y; then
        /usr/local/bin/cloudflared tunnel cleanup "$CF_TUNNEL_NAME" 2>/dev/null || true
        /usr/local/bin/cloudflared tunnel delete -f "$CF_TUNNEL_NAME" 2>/dev/null || \
          /usr/local/bin/cloudflared tunnel delete "$CF_TUNNEL_NAME" 2>/dev/null || true
        tunnel_id=""
      else
        die "缺少 Tunnel credentials，無法繼續。"
      fi
    fi
  fi

  if [[ -z "$tunnel_id" ]]; then
    info "建立 Tunnel：${CF_TUNNEL_NAME}"
    /usr/local/bin/cloudflared tunnel create "$CF_TUNNEL_NAME"
    tunnel_id="$(
      /usr/local/bin/cloudflared tunnel list --output json \
        | jq -r --arg n "$CF_TUNNEL_NAME" '.[] | select(.name==$n) | .id' \
        | sed -n '1p'
    )"
  fi

  [[ -n "$tunnel_id" ]] || die "無法取得 Tunnel ID。"
  creds="/root/.cloudflared/${tunnel_id}.json"
  [[ -f "$creds" ]] || die "找不到 Tunnel credentials：$creds"

  info "綁定 Panel DNS：${PANEL_DOMAIN}"
  if ! /usr/local/bin/cloudflared tunnel route dns "$CF_TUNNEL_NAME" "$PANEL_DOMAIN"; then
    warn "${PANEL_DOMAIN} 可能已經有衝突的 A / AAAA / CNAME。"
    warn "請到 Cloudflare DNS 刪除衝突記錄。"
    read -r -p "處理完成後按 Enter 重試..."
    /usr/local/bin/cloudflared tunnel route dns "$CF_TUNNEL_NAME" "$PANEL_DOMAIN"
  fi

  cat >/etc/cloudflared/pterodactyl.yml <<EOF
tunnel: ${tunnel_id}
credentials-file: ${creds}

ingress:
  - hostname: ${PANEL_DOMAIN}
    service: http://127.0.0.1:80
  - service: http_status:404
EOF

  # 使用獨立 service，不碰其他 cloudflared tunnel/service。
  cat >/etc/systemd/system/cloudflared-pterodactyl.service <<EOF
[Unit]
Description=Cloudflare Tunnel for Pterodactyl
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/local/bin/cloudflared --no-autoupdate --config /etc/cloudflared/pterodactyl.yml tunnel run
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now cloudflared-pterodactyl
  sleep 3

  if ! systemctl is-active --quiet cloudflared-pterodactyl; then
    journalctl -u cloudflared-pterodactyl -n 100 --no-pager -l || true
    die "Pterodactyl Cloudflare Tunnel 啟動失敗。"
  fi

  ok "Cloudflare Tunnel 已建立並設為開機自啟。"
  echo "  Tunnel : ${CF_TUNNEL_NAME}"
  echo "  Domain : https://${PANEL_DOMAIN}"
  echo "  Origin : http://127.0.0.1:80"
}
install_panel(){
  ask_panel
  info "安裝 Panel dependencies..."; install_panel_deps
  install_composer
  setup_db
  install_panel_files
  setup_nginx
  setup_workers
  setup_cloudflared
  cd /var/www/pterodactyl && php artisan optimize:clear >/dev/null || true
  local code
  code="$(curl -k -sS -o /dev/null -w '%{http_code}' "$PANEL_URL/" || true)"
  ok "Panel 完成：$PANEL_URL (HTTP $code)"
  echo "Cloudflare Tunnel：${PANEL_DOMAIN} -> http://127.0.0.1:80"
}

# ---------------- Node ----------------
ask_node(){
  echo
  echo "============================================================"
  echo "                  Node / Wings"
  echo "============================================================"
  echo "Panel 已經裝完，現在才開始問 Node。"
  prompt_required NODE_FQDN "Node FQDN，例如 node1.example.com"
  NODE_FQDN="$(clean_domain "$NODE_FQDN")"
  prompt_required FRP_PUBLIC_IP "FRP 公網 IPv4"
  prompt_default WINGS_LOCAL_API "Wings 內部 API Port" "8080"
  prompt_default WINGS_LOCAL_SFTP "Wings 內部 SFTP Port" "2022"
  prompt_default FRP_API_PORT "FRP 外部 API Port（Panel 填這個）" "20020"
  prompt_default FRP_SFTP_PORT "FRP 外部 SFTP Port（Panel 填這個）" "20021"
  echo "Cloudflare API Token 權限：Zone Read + DNS Edit"
  prompt_secret CF_API_TOKEN "Cloudflare API Token"
  echo
  echo "${NODE_FQDN} -> ${FRP_PUBLIC_IP} (DNS only)"
  echo "API : ${FRP_API_PORT} -> ${WINGS_LOCAL_API}"
  echo "SFTP: ${FRP_SFTP_PORT} -> ${WINGS_LOCAL_SFTP}"
  confirm "開始部署 Node？" Y
}

install_node_deps(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl ca-certificates jq python3 python3-yaml certbot python3-certbot-dns-cloudflare
  if ! command -v docker >/dev/null 2>&1; then curl -fsSL https://get.docker.com/ | CHANNEL=stable bash; fi
  systemctl enable --now docker
  docker info >/dev/null
}

install_wings(){
  mkdir -p /etc/pterodactyl /var/lib/pterodactyl/volumes
  curl -fL -o /usr/local/bin/wings "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${WINGS_ARCH}"
  chmod +x /usr/local/bin/wings
  /usr/local/bin/wings version || true
}

find_zone(){
  local c="$NODE_FQDN" j z
  while [[ "$c" == *.* ]]; do
    j="$(curl -fsS -G https://api.cloudflare.com/client/v4/zones -H "Authorization: Bearer ${CF_API_TOKEN}" -H 'Content-Type: application/json' --data-urlencode "name=${c}")"
    z="$(jq -r '.result[0].id // empty' <<<"$j")"
    if [[ -n "$z" ]]; then CF_ZONE_ID="$z"; CF_ZONE_NAME="$c"; return 0; fi
    c="${c#*.}"
  done
  return 1
}

setup_node_dns(){
  find_zone || die "找不到 Cloudflare Zone，檢查 Token 的 Zone Read 權限"
  local old rid payload result
  old="$(curl -fsS -G "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" -H "Authorization: Bearer ${CF_API_TOKEN}" -H 'Content-Type: application/json' --data-urlencode 'type=A' --data-urlencode "name=${NODE_FQDN}")"
  rid="$(jq -r '.result[0].id // empty' <<<"$old")"
  payload="$(jq -nc --arg n "$NODE_FQDN" --arg ip "$FRP_PUBLIC_IP" '{type:"A",name:$n,content:$ip,ttl:1,proxied:false}')"
  if [[ -n "$rid" ]]; then
    result="$(curl -fsS -X PUT "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records/${rid}" -H "Authorization: Bearer ${CF_API_TOKEN}" -H 'Content-Type: application/json' --data "$payload")"
  else
    result="$(curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/${CF_ZONE_ID}/dns_records" -H "Authorization: Bearer ${CF_API_TOKEN}" -H 'Content-Type: application/json' --data "$payload")"
  fi
  [[ "$(jq -r '.success' <<<"$result")" == true ]] || { jq . <<<"$result"; die "Cloudflare DNS 建立失敗"; }
  ok "DNS：${NODE_FQDN} -> ${FRP_PUBLIC_IP} (DNS only)"
}

issue_cert(){
  mkdir -p /root/.secrets/certbot
  cat >/root/.secrets/certbot/cloudflare.ini <<EOFAPI
dns_cloudflare_api_token = ${CF_API_TOKEN}
EOFAPI
  chmod 600 /root/.secrets/certbot/cloudflare.ini
  certbot certonly --non-interactive --agree-tos --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini --dns-cloudflare-propagation-seconds 30 -m "$PANEL_EMAIL" -d "$NODE_FQDN"
  NODE_CERT="/etc/letsencrypt/live/${NODE_FQDN}/fullchain.pem"
  NODE_KEY="/etc/letsencrypt/live/${NODE_FQDN}/privkey.pem"
  [[ -f "$NODE_CERT" && -f "$NODE_KEY" ]] || die "Node 憑證不存在"
}

show_node_panel_settings(){
  echo
  echo "============================================================"
  echo "Panel 裡 Node 請這樣設定"
  echo "============================================================"
  echo "FQDN                 : $NODE_FQDN"
  echo "Communicate Over SSL : Use SSL Connection"
  echo "Behind Proxy         : Not Behind Proxy"
  echo "Daemon Port          : $FRP_API_PORT"
  echo "Daemon SFTP Port     : $FRP_SFTP_PORT"
  echo
  echo "建議資源（依你的實際 VPS 調整）："
  echo "Total Memory         : 30000 ~ 30720 MiB"
  echo "Disk Space           : 1300000 ~ 1400000 MiB"
  echo
  echo "建立 Node 後，到 Node -> Configuration。"
  echo "只要把 uuid、token_id、token 三個值複製出來即可。"
  echo
  read -r -p "準備好後按 Enter 繼續..."
}

write_wings_config(){
  prompt_required NODE_UUID "uuid"
  prompt_required NODE_TOKEN_ID "token_id"
  prompt_secret NODE_TOKEN "token"

  cat >/etc/pterodactyl/config.yml <<YAML

debug: false
uuid: ${NODE_UUID}
token_id: ${NODE_TOKEN_ID}
token: ${NODE_TOKEN}

api:
  host: 0.0.0.0
  port: ${WINGS_LOCAL_API}
  ssl:
    enabled: true
    cert: ${NODE_CERT}
    key: ${NODE_KEY}
  upload_limit: 100

system:
  data: /var/lib/pterodactyl/volumes
  sftp:
    bind_port: ${WINGS_LOCAL_SFTP}

allowed_mounts: []
remote: '${PANEL_URL}'
YAML

  chmod 600 /etc/pterodactyl/config.yml
  ok "已建立 /etc/pterodactyl/config.yml"
}

setup_wings_service(){
cat >/etc/systemd/system/wings.service <<'EOFW'
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
EOFW
  mkdir -p /etc/letsencrypt/renewal-hooks/deploy
  cat >/etc/letsencrypt/renewal-hooks/deploy/restart-wings.sh <<'EOFR'
#!/usr/bin/env bash
systemctl restart wings.service
EOFR
  chmod +x /etc/letsencrypt/renewal-hooks/deploy/restart-wings.sh
  systemctl daemon-reload
  systemctl reset-failed wings 2>/dev/null || true
  systemctl enable --now wings
  sleep 3
  systemctl is-active --quiet wings || { journalctl -u wings -n 100 --no-pager; die "Wings 啟動失敗"; }
}

install_node(){
  ask_node || return 0
  install_node_deps
  install_wings
  setup_node_dns
  issue_cert
  show_node_panel_settings
  write_wings_config
  setup_wings_service
  echo
  ok "Wings 已啟動並自啟"
  ss -lntp | grep -E ":(${WINGS_LOCAL_API}|${WINGS_LOCAL_SFTP})\b" || true
  echo
  echo "FRP Panel 建立兩條 TCP："
  echo "  API : localIP=127.0.0.1 localPort=${WINGS_LOCAL_API} remotePort=${FRP_API_PORT}"
  echo "  SFTP: localIP=127.0.0.1 localPort=${WINGS_LOCAL_SFTP} remotePort=${FRP_SFTP_PORT}"
  echo
  echo "Panel Node 填："
  echo "  FQDN=$NODE_FQDN"
  echo "  SSL=Yes"
  echo "  Behind Proxy=No"
  echo "  Daemon Port=$FRP_API_PORT"
  echo "  SFTP Port=$FRP_SFTP_PORT"
}

show_status(){
  echo
  echo "==================== 完成 ===================="
  echo "Panel: $PANEL_URL"
  for s in nginx mariadb redis-server php8.3-fpm cron pteroq cloudflared-pterodactyl docker wings; do
    if systemctl list-unit-files "${s}.service" >/dev/null 2>&1; then
      printf '  %-14s enabled=%-8s active=%s\n' "$s" "$(systemctl is-enabled "$s" 2>/dev/null || true)" "$(systemctl is-active "$s" 2>/dev/null || true)"
    fi
  done
}

main(){
  ask_panel
  info "安裝 Panel..."
  install_panel_deps
  install_composer
  setup_db
  install_panel_files
  setup_nginx
  setup_workers
  setup_cloudflared
  cd /var/www/pterodactyl && php artisan optimize:clear >/dev/null || true
  ok "Panel 完成：$PANEL_URL"
  echo "Cloudflare Tunnel Public Hostname：${PANEL_DOMAIN} -> http://localhost:80"
  echo
  if confirm "Panel 完成。現在部署 Wings Node？" Y; then install_node; fi
  show_status
}
main "$@"
