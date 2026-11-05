#!/usr/bin/env bash
# Tự tạo vhost nginx cho domain mail (nếu chưa có vhost nào khai báo domain đó).
#
#   sudo scripts/nginx-setup.sh                         # domain = MAIL_HOSTNAME trong .env (mail.hostname)
#   sudo scripts/nginx-setup.sh -d mail.example.com     # chỉ định domain
#   scripts/nginx-setup.sh --dry-run                    # chỉ in cấu hình sẽ tạo
#
# Tuỳ chọn:
#   -d, --domain DOMAIN   Domain mail (mặc định: MAIL_HOSTNAME trong .env)
#   -m, --mode MODE       webmail | api | both (mặc định: NGINX_MAIL_MODE trong .env, hoặc both)
#                           webmail: /  -> Mailu web (webmail, /admin)       MAILU_HTTP_BIND
#                           api:     /  -> Mail API                          127.0.0.1:API_PORT
#                           both:    /  -> Mailu web, /mail-api/ -> Mail API
#   -e, --email EMAIL     Email đăng ký Let's Encrypt; khi chưa có chứng chỉ phủ domain,
#                         script chạy certbot --nginx để xin (cần DNS đã trỏ về server)
#   --dry-run             In cấu hình, không ghi gì
#
# Script không bao giờ sửa vhost đã có: nếu domain đã xuất hiện trong server_name của
# cấu hình nginx đang chạy, script dừng và báo file chứa nó.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
SITES_AVAILABLE="${SITES_AVAILABLE:-/etc/nginx/sites-available}"
SITES_ENABLED="${SITES_ENABLED:-/etc/nginx/sites-enabled}"

read_kv() { # read_kv FILE KEY DEFAULT
  local val=""
  [[ -f "$1" ]] && val=$(grep -E "^$2=" "$1" | tail -n1 | cut -d= -f2-) || true
  echo "${val:-$3}"
}

DOMAIN=""; MODE=""; EMAIL="${LETSENCRYPT_EMAIL:-}"; DRY_RUN=no
while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain) DOMAIN=$2; shift 2 ;;
    -m|--mode) MODE=$2; shift 2 ;;
    -e|--email) EMAIL=$2; shift 2 ;;
    --dry-run) DRY_RUN=yes; shift ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Tham số không hợp lệ: $1" >&2; exit 1 ;;
  esac
done

[[ -f "$ENV_FILE" ]] || { echo "Lỗi: thiếu $ENV_FILE — chạy scripts/configure.py" >&2; exit 1; }
[[ -z "$DOMAIN" ]] && DOMAIN=$(read_kv "$ENV_FILE" MAIL_HOSTNAME "" | tr -d '[:space:]')
[[ -z "$MODE" ]] && MODE=$(read_kv "$ENV_FILE" NGINX_MAIL_MODE both)
[[ -z "$EMAIL" ]] && EMAIL=$(read_kv "$ENV_FILE" LETSENCRYPT_EMAIL "")
API_PORT=$(read_kv "$ENV_FILE" API_PORT "")
MAX_WAIT=$(read_kv "$ENV_FILE" MAX_WAIT_TIMEOUT 600)
READ_TIMEOUT=$((MAX_WAIT + 60))
MAILU_WEB=$(read_kv "$ENV_FILE" MAILU_HTTP_BIND "")
SITE_NAME="mailu-$DOMAIN"

die() { echo "Lỗi: $*" >&2; exit 1; }
[[ -n "$DOMAIN" ]] || die "không xác định được domain (dùng -d hoặc đặt mail.hostname trong config.yml)"
[[ -n "$API_PORT" && -n "$MAILU_WEB" ]] || die "thiếu API_PORT/MAILU_HTTP_BIND trong .env — chạy scripts/configure.py"
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || die "domain không hợp lệ: $DOMAIN"
[[ "$MODE" =~ ^(webmail|api|both)$ ]] || die "mode phải là webmail | api | both"
command -v nginx >/dev/null || die "chưa cài nginx"

# ---------------------------------------------------------------------------
# 1. Domain đã có vhost chưa?
# ---------------------------------------------------------------------------
existing_vhost() { # in file đầu tiên có server_name chứa đúng DOMAIN
  nginx -T 2>/dev/null | awk -v d="$DOMAIN" '
    /^# configuration file / { file=$4; sub(/:$/, "", file) }
    /^[[:space:]]*server_name[[:space:]]/ {
      line=$0; sub(/#.*/, "", line); gsub(/;/, " ", line)
      n=split(line, w, /[[:space:]]+/)
      for (i=1;i<=n;i++) if (w[i]==d) { print file; exit }
    }'
}

if found=$(existing_vhost) && [[ -n "$found" ]]; then
  echo "Domain $DOMAIN đã có vhost trong: $found — không tạo mới."
  echo "Nếu cần bật whitelist cho vhost đó, thêm 'include snippets/mailu-api-allow.conf;' hoặc"
  echo "'include snippets/mailu-mail-allow.conf;' vào location tương ứng (xem README)."
  exit 0
fi

# ---------------------------------------------------------------------------
# 2. Tìm chứng chỉ Let's Encrypt đã phủ domain (kể cả wildcard)
# ---------------------------------------------------------------------------
find_cert() {
  local dir san name
  for dir in /etc/letsencrypt/live/*/; do
    [[ -f "$dir/fullchain.pem" ]] || continue
    san=$(openssl x509 -in "$dir/fullchain.pem" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed -n 's/.*DNS://p')
    openssl x509 -in "$dir/fullchain.pem" -noout -checkend 0 >/dev/null 2>&1 || continue
    while read -r name; do
      # khớp chính xác, hoặc wildcard *.example.com phủ đúng 1 nhãn (mail.example.com)
      if [[ "$name" == "$DOMAIN" ]] || [[ "$name" == "*."* && "${DOMAIN#*.}" == "${name#*.}" ]]; then
        echo "${dir%/}"; return 0
      fi
    done <<< "$san"
  done
  return 1
}
CERT_DIR=$(find_cert || true)

# ---------------------------------------------------------------------------
# 3. Sinh cấu hình
# ---------------------------------------------------------------------------
proxy_headers() { # proxy_headers PROTO
  cat <<EOF
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$remote_addr;
        proxy_set_header X-Forwarded-Proto $1;
EOF
}

locations() { # locations PROTO
  local proto=$1
  if [[ $MODE == webmail || $MODE == both ]]; then
    cat <<EOF
    # Mailu web: webmail + admin (whitelist/mail.txt)
    location / {
        include snippets/mailu-mail-allow.conf;
        proxy_pass http://$MAILU_WEB;
$(proxy_headers "$proto")
    }
EOF
  fi
  if [[ $MODE == api ]]; then
    cat <<EOF
    # Mail API (whitelist/api.txt)
    location / {
        include snippets/mailu-api-allow.conf;
        proxy_pass http://127.0.0.1:$API_PORT;
$(proxy_headers "$proto")
        proxy_read_timeout ${READ_TIMEOUT}s;
        proxy_send_timeout ${READ_TIMEOUT}s;
        proxy_buffering off;
    }
EOF
  fi
  if [[ $MODE == both ]]; then
    cat <<EOF

    # Mail API dưới /mail-api/  ->  https://$DOMAIN/mail-api/wait-email (whitelist/api.txt)
    location /mail-api/ {
        include snippets/mailu-api-allow.conf;
        proxy_pass http://127.0.0.1:$API_PORT/;
$(proxy_headers "$proto")
        proxy_read_timeout ${READ_TIMEOUT}s;
        proxy_send_timeout ${READ_TIMEOUT}s;
        proxy_buffering off;
    }
EOF
  fi
}

render_config() {
  echo "# Sinh bởi $ROOT_DIR/scripts/nginx-setup.sh (mode: $MODE) — $(date -I)"
  if [[ -n "$CERT_DIR" ]]; then
    cat <<EOF
server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate     $CERT_DIR/fullchain.pem;
    ssl_certificate_key $CERT_DIR/privkey.pem;
EOF
    [[ -f /etc/letsencrypt/options-ssl-nginx.conf ]] && echo "    include /etc/letsencrypt/options-ssl-nginx.conf;"
    [[ -f /etc/letsencrypt/ssl-dhparams.pem ]] && echo "    ssl_dhparam /etc/letsencrypt/ssl-dhparams.pem;"
    cat <<EOF

    client_max_body_size 50M;

$(locations https)
}

server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF
  else
    # Chưa có chứng chỉ: tạo vhost HTTP; certbot --nginx sẽ thêm HTTPS + redirect
    cat <<EOF
server {
    listen 80;
    server_name $DOMAIN;

    client_max_body_size 50M;

$(locations \$scheme)
}
EOF
  fi
}

CONFIG=$(render_config)

if [[ $DRY_RUN == yes ]]; then
  echo "# Chứng chỉ: ${CERT_DIR:-<chưa có — sẽ xin bằng certbot nếu có --email>}"
  echo "$CONFIG"
  exit 0
fi

[[ $EUID -eq 0 ]] || die "cần chạy bằng root"

# ---------------------------------------------------------------------------
# 4. Ghi, kiểm tra, reload (rollback nếu lỗi)
# ---------------------------------------------------------------------------
# Snippet whitelist phải tồn tại trước khi nginx -t
for s in mailu-api-allow.conf mailu-mail-allow.conf; do
  if [[ ! -f /etc/nginx/snippets/$s ]]; then
    "$ROOT_DIR/scripts/nginx-whitelist.sh"
    break
  fi
done

AVAIL="$SITES_AVAILABLE/$SITE_NAME"
ENABLED="$SITES_ENABLED/$SITE_NAME"
[[ -e "$AVAIL" || -e "$ENABLED" ]] && die "$AVAIL hoặc $ENABLED đã tồn tại nhưng không được nginx nạp — kiểm tra tay"

echo "$CONFIG" > "$AVAIL"
ln -s "$AVAIL" "$ENABLED"
rollback() { rm -f "$ENABLED" "$AVAIL"; echo "Đã gỡ $SITE_NAME do lỗi" >&2; }

if ! nginx -t; then rollback; exit 1; fi
systemctl reload nginx
echo "Đã tạo vhost $AVAIL (mode: $MODE)"

if [[ -z "$CERT_DIR" ]]; then
  if [[ -n "$EMAIL" ]] && command -v certbot >/dev/null; then
    echo "Xin chứng chỉ Let's Encrypt cho $DOMAIN..."
    if certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$EMAIL" --redirect; then
      echo "Đã bật HTTPS cho $DOMAIN"
    else
      echo "Cảnh báo: certbot thất bại (DNS đã trỏ về server chưa?). Vhost vẫn chạy HTTP." >&2
    fi
  else
    echo "Cảnh báo: chưa có chứng chỉ cho $DOMAIN — vhost đang chạy HTTP."
    echo "Chạy lại với --email you@example.com (hoặc LETSENCRYPT_EMAIL trong .env), hoặc:"
    echo "  certbot --nginx -d $DOMAIN --redirect"
  fi
fi
