#!/usr/bin/env bash
set -euo pipefail

echo "===== 停止 Pterodactyl / Wings / 專用 Tunnel ====="
systemctl disable --now wings 2>/dev/null || true
systemctl disable --now pteroq 2>/dev/null || true
systemctl disable --now cloudflared-pterodactyl 2>/dev/null || true

echo "===== 刪除 Pterodactyl systemd / cron ====="
rm -f /etc/systemd/system/wings.service
rm -f /etc/systemd/system/pteroq.service
rm -f /etc/systemd/system/cloudflared-pterodactyl.service
rm -f /etc/cron.d/pterodactyl
systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true

echo "===== 刪除 Nginx Pterodactyl 設定 ====="
rm -f /etc/nginx/sites-enabled/pterodactyl.conf
rm -f /etc/nginx/sites-available/pterodactyl.conf

echo "===== 刪除 Panel / Wings / 遊戲資料 ====="
rm -rf /var/www/pterodactyl
rm -rf /etc/pterodactyl
rm -rf /var/lib/pterodactyl
rm -f /usr/local/bin/wings

echo "===== 刪除 Pterodactyl 專用 Cloudflare config ====="
rm -f /etc/cloudflared/pterodactyl.yml

echo "===== 刪除資料庫 ====="
if command -v mariadb >/dev/null 2>&1; then
mariadb <<'SQL'
DROP DATABASE IF EXISTS panel;
DROP USER IF EXISTS 'pterodactyl'@'localhost';
DROP USER IF EXISTS 'pterodactyl'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
fi

echo "===== 清除 Wings 憑證續期 hook / 暫存 ====="
rm -f /etc/letsencrypt/renewal-hooks/deploy/restart-wings.sh
rm -f /tmp/wings-config.yml /tmp/panel.tar.gz /tmp/cloudflared.new
rm -f /root/install.sh

echo
echo "注意："
echo "- 不會刪除 Docker"
echo "- 不會刪除 FRP"
echo "- 不會刪除其他 cloudflared Tunnel"
echo "- 不會刪除 /root/.cloudflared/cert.pem"
echo
echo "Pterodactyl 已清除。"
