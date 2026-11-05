#!/usr/bin/env bash
# Sinh snippet allow/deny cho nginx từ các file whitelist của dự án, rồi kiểm tra và reload nginx.
#
#   sudo scripts/nginx-whitelist.sh            # sinh snippet + nginx -t + reload
#   scripts/nginx-whitelist.sh --dry-run       # chỉ in nội dung snippet
#
#   whitelist/api.txt   -> $NGINX_SNIPPET_DIR/mailu-api-allow.conf
#   whitelist/mail.txt  -> $NGINX_SNIPPET_DIR/mailu-mail-allow.conf
#
# Trong vhost dùng:  include snippets/mailu-api-allow.conf;
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"
NGINX_SNIPPET_DIR="${NGINX_SNIPPET_DIR:-/etc/nginx/snippets}"
DRY_RUN=no; [[ "${1:-}" == "--dry-run" ]] && DRY_RUN=yes

read_env() {
  local key=$1 def=${2:-} val=""
  if [[ -n "${!key:-}" ]]; then echo "${!key}"; return; fi
  [[ -f "$ENV_FILE" ]] && val=$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2-) || true
  echo "${val:-$def}"
}
abspath() { [[ "$1" = /* ]] && echo "$1" || echo "$ROOT_DIR/$1"; }

# render FILE -> in ra nội dung snippet; mục không hợp lệ bị bỏ qua (báo ra stderr)
render() {
  python3 -I - "$1" <<'PY'
import ipaddress, sys
path = sys.argv[1]
print(f"# Sinh tự động từ {path} bởi scripts/nginx-whitelist.sh — KHÔNG sửa tay")
print("allow 127.0.0.1;")
print("allow ::1;")
try:
    lines = open(path, encoding="utf-8").read().splitlines()
except FileNotFoundError:
    print(f"Cảnh báo: thiếu {path} — chỉ localhost được phép", file=sys.stderr)
    lines = []
for raw in lines:
    entry = raw.split("#", 1)[0].strip()
    if not entry:
        continue
    try:
        print(f"allow {ipaddress.ip_network(entry, strict=False)};")
    except ValueError:
        print(f"Bỏ qua mục không hợp lệ trong {path}: {entry!r}", file=sys.stderr)
print("deny all;")
PY
}

declare -A MAP=(
  [mailu-api-allow.conf]="$(abspath "$(read_env API_WHITELIST_FILE whitelist/api.txt)")"
  [mailu-mail-allow.conf]="$(abspath "$(read_env MAIL_WHITELIST_FILE whitelist/mail.txt)")"
)

if [[ $DRY_RUN == yes ]]; then
  for name in "${!MAP[@]}"; do echo "=== $name"; render "${MAP[$name]}"; done
  exit 0
fi

[[ $EUID -eq 0 ]] || { echo "Lỗi: cần chạy bằng root" >&2; exit 1; }
mkdir -p "$NGINX_SNIPPET_DIR"
declare -A BACKUP=()
for name in "${!MAP[@]}"; do
  target="$NGINX_SNIPPET_DIR/$name"
  [[ -f "$target" ]] && { BACKUP[$name]=$(mktemp); cp "$target" "${BACKUP[$name]}"; }
  render "${MAP[$name]}" > "$target.tmp" && mv "$target.tmp" "$target"
  echo "Đã ghi $target"
done

if nginx -t; then
  systemctl reload nginx
  echo "Đã reload nginx"
else
  echo "nginx -t lỗi — khôi phục snippet cũ" >&2
  for name in "${!MAP[@]}"; do
    if [[ -n "${BACKUP[$name]:-}" ]]; then cp "${BACKUP[$name]}" "$NGINX_SNIPPET_DIR/$name"; fi
  done
  exit 1
fi
for f in "${BACKUP[@]}"; do rm -f "$f"; done
