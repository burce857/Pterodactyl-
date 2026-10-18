#!/usr/bin/env bash
set -Eeuo pipefail
trap 'code=$?; echo "[ERROR] line=$LINENO exit=$code" >&2' ERR
info(){ printf '[INFO] %s\n' "$*"; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
ask(){ local key="$1" msg="$2" default="$3" val; read -r -p "$msg [$default]: " val; printf -v "$key" '%s' "${val:-$default}"; }
required(){ local key="$1" msg="$2" val=''; until [[ -n "$val" ]]; do read -r -p "$msg: " val; done; printf -v "$key" '%s' "$val"; }
[[ $EUID -eq 0 ]] || die 'Run this script as root.'
source /etc/os-release
[[ "${ID:-}" == ubuntu && ( "${VERSION_ID:-}" == '22.04' || "${VERSION_ID:-}" == '24.04' ) ]] || die 'Supported OS: Ubuntu 22.04 or 24.04.'
case "$(uname -m)" in x86_64) ARCH=amd64;; aarch64|arm64) ARCH=arm64;; *) die 'Unsupported CPU architecture.';; esac
printf '\n=== Pterodactyl Wings Node-only installer ===\n'
info 'This script does not install or modify Pterodactyl Panel.'
required NODE_DOMAIN 'Node FQDN (e.g. node2.rb-xl.bond)'
NODE_DOMAIN="${NODE_DOMAIN#https://}"; NODE_DOMAIN="${NODE_DOMAIN#http://}"; NODE_DOMAIN="${NODE_DOMAIN%%/*}"
[[ "$NODE_DOMAIN" =~ ^[a-zA-Z0-9.-]+$ && "$NODE_DOMAIN" == *.* ]] || die 'Invalid Node FQDN.'
required PANEL_URL 'Existing Panel URL (e.g. https://p.rb-xl.bond)'
PANEL_URL="${PANEL_URL%/}"
[[ "$PANEL_URL" == https://* ]] || die 'Panel URL must start with https://.'
required FRP_IP 'FRP server public IPv4'
[[ "$FRP_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die 'Invalid IPv4 format.'
ask API_PORT 'Wings local API port' 8080
ask SFTP_PORT 'Wings local SFTP port' 2022
ask PUBLIC_API 'FRP external API port' 21080
ask PUBLIC_SFTP 'FRP external SFTP port' 21023
for p in "$API_PORT" "$SFTP_PORT" "$PUBLIC_API" "$PUBLIC_SFTP"; do
  [[ "$p" =~ ^[0-9]+$ && "$p" -ge 1 && "$p" -le 65535 ]] || die "Invalid port: $p"
done
[[ "$API_PORT" != "$SFTP_PORT" && "$PUBLIC_API" != "$PUBLIC_SFTP" ]] || die 'API and SFTP ports must differ.'
printf '\nCreate the new node in the existing Panel before continuing.\n'
printf ' FQDN=%s | SSL=Yes | Behind Proxy=No\n' "$NODE_DOMAIN"
printf ' Daemon Port=%s | Daemon SFTP Port=%s\n' "$PUBLIC_API" "$PUBLIC_SFTP"
printf ' Open Node -> Configuration and copy the COMPLETE YAML config.\n\n'
read -r -p 'Have you created the node and copied its full config? [y/N]: ' answer
[[ "$answer" =~ ^[Yy]$ ]] || die 'Cancelled.'
if [[ -e /etc/pterodactyl/config.yml ]]; then
  printf '\n[WARN] Existing Wings config detected: /etc/pterodactyl/config.yml\n'
  read -r -p 'Replace existing Wings config (backup will be saved)? [y/N]: ' answer
  [[ "$answer" =~ ^[Yy]$ ]] || die 'Cancelled to protect existing node.'
fi
printf '\nCloudflare API Token requires Zone:Zone:Read + Zone:DNS:Edit for this zone.\n'
read -r -s -p 'Cloudflare API Token: ' CF_TOKEN; echo
[[ -n "$CF_TOKEN" ]] || die 'Missing Cloudflare API Token.'
info 'Installing Wings dependencies...'
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y curl ca-certificates jq python3 python3-yaml certbot python3-certbot-dns-cloudflare
if ! command -v docker >/dev/null 2>&1; then
  curl -fsSL https://get.docker.com -o /tmp/pterodactyl-get-docker.sh
  sh /tmp/pterodactyl-get-docker.sh
fi
systemctl enable --now docker
docker info >/dev/null
info 'Installing Wings...'
mkdir -p /etc/pterodactyl /var/lib/pterodactyl/volumes
curl -fL "https://github.com/pterodactyl/wings/releases/latest/download/wings_linux_${ARCH}" -o /usr/local/bin/wings
chmod 755 /usr/local/bin/wings
info 'Checking Cloudflare zone...'
zone_name="$NODE_DOMAIN"; zone_id=''
while [[ "$zone_name" == *.* ]]; do
  response=$(curl -fsS -G 'https://api.cloudflare.com/client/v4/zones' -H "Authorization: Bearer ${CF_TOKEN}" --data-urlencode "name=${zone_name}")
  zone_id=$(jq -r '.result[0].id // empty' <<<"$response")
  [[ -z "$zone_id" ]] || break
  zone_name="${zone_name#*.}"
done
[[ -n "$zone_id" ]] || die 'Cloudflare zone not found. Check Token scope and permissions.'
records=$(curl -fsS -G "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" -H "Authorization: Bearer ${CF_TOKEN}" --data-urlencode "name=${NODE_DOMAIN}" --data-urlencode 'per_page=100')
record_count=$(jq '[.result[] | select(.type == "A" or .type == "AAAA" or .type == "CNAME")] | length' <<<"$records")
[[ "$record_count" -le 1 ]] || die 'Multiple existing DNS A/AAAA/CNAME records detected. Resolve them manually first.'
record_id=$(jq -r '.result[] | select(.type == "A") | .id' <<<"$records" | head -n1)
other_count=$(jq '[.result[] | select(.type == "AAAA" or .type == "CNAME")] | length' <<<"$records")
[[ "$other_count" -eq 0 ]] || die 'Existing AAAA/CNAME record found. Update DNS manually before rerunning.'
if [[ -n "$record_id" ]]; then
  existing_ip=$(jq -r '.result[] | select(.type == "A") | .content' <<<"$records" | head -n1)
  printf 'Existing DNS record: %s -> %s\n' "$NODE_DOMAIN" "$existing_ip"
  read -r -p "Replace it with $FRP_IP (DNS only)? [y/N]: " answer
  [[ "$answer" =~ ^[Yy]$ ]] || die 'Cancelled to protect existing DNS.'
fi
payload=$(jq -nc --arg name "$NODE_DOMAIN" --arg ip "$FRP_IP" '{type:"A",name:$name,content:$ip,ttl:1,proxied:false}')
if [[ -n "$record_id" ]]; then
  result=$(curl -fsS -X PUT "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records/${record_id}" -H "Authorization: Bearer ${CF_TOKEN}" -H 'Content-Type: application/json' --data "$payload")
else
  result=$(curl -fsS -X POST "https://api.cloudflare.com/client/v4/zones/${zone_id}/dns_records" -H "Authorization: Bearer ${CF_TOKEN}" -H 'Content-Type: application/json' --data "$payload")
fi
[[ "$(jq -r '.success' <<<"$result")" == true ]] || die 'Cloudflare DNS update failed.'
info 'Requesting Let’s Encrypt certificate via Cloudflare DNS-01 (no email needed)...'
mkdir -p /root/.secrets/certbot
umask 077
printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" > /root/.secrets/certbot/cloudflare.ini
unset CF_TOKEN
chmod 600 /root/.secrets/certbot/cloudflare.ini
certbot certonly --non-interactive --agree-tos --dns-cloudflare --dns-cloudflare-credentials /root/.secrets/certbot/cloudflare.ini --dns-cloudflare-propagation-seconds 60 --register-unsafely-without-email -d "$NODE_DOMAIN"
CERT="/etc/letsencrypt/live/${NODE_DOMAIN}/fullchain.pem"
KEY="/etc/letsencrypt/live/${NODE_DOMAIN}/privkey.pem"
[[ -f "$CERT" && -f "$KEY" ]] || die 'TLS certificate not found.'
printf '\nPaste the FULL Wings config YAML from Panel (including uuid, token_id, token).\n'
printf 'Finish by typing END_CONFIG on its own line. Keep the config private.\n'
tmp=$(mktemp); chmod 600 "$tmp"
while IFS= read -r line; do
  [[ "$line" == 'END_CONFIG' ]] && break
  printf '%s\n' "$line" >> "$tmp"
done
[[ -s "$tmp" ]] || die 'Empty configuration.'
python3 - "$tmp" "$API_PORT" "$SFTP_PORT" "$CERT" "$KEY" "$PANEL_URL" <<'PY'
import sys, yaml
path, api, sftp, cert, key, panel = sys.argv[1:]
with open(path, encoding='utf-8') as fh:
    cfg = yaml.safe_load(fh)
if not isinstance(cfg, dict) or not all(cfg.get(k) for k in ('uuid', 'token_id', 'token')):
    raise SystemExit('Invalid config: uuid, token_id and token are required.')
if cfg.get('remote', '').rstrip('/') != panel:
    raise SystemExit('Panel URL does not match config remote. Check you copied the right Node config.')
cfg.setdefault('api', {}).update({'host':'0.0.0.0','port':int(api)})
cfg['api']['ssl'] = {'enabled':True,'cert':cert,'key':key}
cfg.setdefault('system', {}).setdefault('sftp', {})['bind_port']=int(sftp)
with open(path, 'w', encoding='utf-8') as fh:
    yaml.safe_dump(cfg, fh, sort_keys=False, allow_unicode=True)
PY
if [[ -e /etc/pterodactyl/config.yml ]]; then
  cp -a /etc/pterodactyl/config.yml "/etc/pterodactyl/config.yml.backup.$(date +%Y%m%d-%H%M%S)"
fi
install -m 600 "$tmp" /etc/pterodactyl/config.yml
rm -f "$tmp"
cat >/etc/systemd/system/wings.service <<'UNIT'
[Unit]
Description=Pterodactyl Wings Daemon
After=docker.service
Requires=docker.service
[Service]
User=root
WorkingDirectory=/etc/pterodactyl
ExecStart=/usr/local/bin/wings
LimitNOFILE=4096
Restart=on-failure
RestartSec=5s
[Install]
WantedBy=multi-user.target
UNIT
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat >/etc/letsencrypt/renewal-hooks/deploy/restart-wings.sh <<'HOOK'
#!/usr/bin/env bash
systemctl try-restart wings.service
HOOK
chmod 755 /etc/letsencrypt/renewal-hooks/deploy/restart-wings.sh
systemctl daemon-reload
systemctl enable wings.service
systemctl restart wings.service
sleep 3
systemctl is-active --quiet wings || { journalctl -u wings -n 40 --no-pager; die 'Wings failed to start.'; }
printf '\n=== Node deployment complete ===\n'
printf 'Panel Node FQDN: %s\n' "$NODE_DOMAIN"
printf 'FRP API: TCP 127.0.0.1:%s -> public :%s\n' "$API_PORT" "$PUBLIC_API"
printf 'FRP SFTP: TCP 127.0.0.1:%s -> public :%s\n' "$SFTP_PORT" "$PUBLIC_SFTP"
printf 'DNS: %s -> %s (DNS only)\n' "$NODE_DOMAIN" "$FRP_IP"
printf 'FRP mappings must be configured separately on the correct FRP client.\n'
printf 'After configuring FRP, test: curl -v https://%s:%s/api/system\n' "$NODE_DOMAIN" "$PUBLIC_API"
