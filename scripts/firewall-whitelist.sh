#!/usr/bin/env bash
# Giới hạn truy cập cổng mail (Mailu trong Docker) và cổng Mail API theo whitelist IP.
#
#   sudo scripts/firewall-whitelist.sh apply    # áp dụng / cập nhật lại sau khi sửa whitelist
#   sudo scripts/firewall-whitelist.sh remove   # gỡ toàn bộ rule do script tạo
#   sudo scripts/firewall-whitelist.sh status   # xem rule hiện tại
#
# Cơ chế:
#   - Cổng do Docker publish (Mailu front) đi qua chain FORWARD nên phải lọc ở DOCKER-USER,
#     so khớp cổng gốc bằng conntrack (--ctorigdstport) vì Docker đã DNAT.
#   - Cổng API (gunicorn chạy trên host) lọc ở chain INPUT.
#   - Chỉ lọc traffic đi vào từ interface Internet (EXT_IFACE), nên traffic nội bộ giữa
#     các container (vd webmail -> imap) và từ localhost không bị ảnh hưởng.
# Cấu hình đọc từ .env (MAIL_WHITELIST_FILE, MAIL_PROTECTED_PORTS, API_*, EXT_IFACE...).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$ROOT_DIR/.env}"

read_env() { # read_env KEY DEFAULT — đọc giá trị từ .env mà không source (tránh chạy code)
  local key=$1 def=${2:-} val=""
  if [[ -n "${!key:-}" ]]; then echo "${!key}"; return; fi
  if [[ -f "$ENV_FILE" ]]; then
    val=$(grep -E "^${key}=" "$ENV_FILE" | tail -n1 | cut -d= -f2- | sed -E 's/^["'\'']//; s/["'\'']$//') || true
  fi
  echo "${val:-$def}"
}

abspath() { [[ "$1" = /* ]] && echo "$1" || echo "$ROOT_DIR/$1"; }

MAIL_WHITELIST_FILE=$(abspath "$(read_env MAIL_WHITELIST_FILE whitelist/mail.txt)")
API_WHITELIST_FILE=$(abspath "$(read_env API_WHITELIST_FILE whitelist/api.txt)")
MAIL_PROTECTED_PORTS=$(read_env MAIL_PROTECTED_PORTS "110,995,143,993,465,587")
API_PORT=$(read_env API_PORT "")
FIREWALL_PROTECT_API=$(read_env FIREWALL_PROTECT_API yes)
EXT_IFACE=$(read_env EXT_IFACE "")
[[ -z "$EXT_IFACE" ]] && EXT_IFACE=$(ip route show default | awk '/default/ {print $5; exit}')

TAG="mailu-whitelist"
MAIL_CHAIN="MAILU-WL-MAIL"
API_CHAIN="MAILU-WL-API"

die() { echo "Lỗi: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "cần chạy bằng root"
[[ -n "$API_PORT" ]] || die "thiếu API_PORT trong .env — chạy scripts/configure.py"
[[ -n "$EXT_IFACE" ]] || die "không xác định được interface Internet, đặt EXT_IFACE trong .env"

# In các mục hợp lệ của file whitelist theo họ địa chỉ (4 hoặc 6)
entries() { # entries FILE FAMILY
  local file=$1 fam=$2 line fam_of
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%%#*}; line=$(echo "$line" | tr -d '[:space:]')
    [[ -z "$line" ]] && continue
    if [[ "$line" == *:* ]]; then fam_of=6; else fam_of=4; fi
    if [[ $fam_of == "$fam" ]]; then echo "$line"; fi
  done < "$file"
}

# Xoá mọi rule có comment $TAG trong một chain cha
purge_jumps() { # purge_jumps IPT CHAIN
  local ipt=$1 chain=$2 rule
  { $ipt -S "$chain" 2>/dev/null || true; } | { grep -- "--comment $TAG" || true; } | sed -E "s/^-A /-D /" |
    while read -r rule; do eval "$ipt $rule"; done
}

reset_chain() { # reset_chain IPT CHAIN
  $1 -N "$2" 2>/dev/null || $1 -F "$2"
}

drop_chain() { # drop_chain IPT CHAIN
  $1 -F "$2" 2>/dev/null || true
  $1 -X "$2" 2>/dev/null || true
}

fill_chain() { # fill_chain IPT CHAIN FILE FAMILY
  local ipt=$1 chain=$2 file=$3 fam=$4 n=0 cidr
  while read -r cidr; do
    if $ipt -A "$chain" -s "$cidr" -m comment --comment "$TAG" -j RETURN 2>/dev/null; then
      n=$((n+1))
    else
      echo "  [$ipt] bỏ qua mục không hợp lệ: $cidr" >&2
    fi
  done < <(entries "$file" "$fam")
  $ipt -A "$chain" -m comment --comment "$TAG" -j DROP
  echo "  [$ipt] $chain: $n IP/CIDR được phép"
}

apply_family() { # apply_family IPT FAMILY
  local ipt=$1 fam=$2 port
  command -v "$ipt" >/dev/null || return 0

  purge_jumps "$ipt" DOCKER-USER
  purge_jumps "$ipt" INPUT
  reset_chain "$ipt" "$MAIL_CHAIN"
  fill_chain "$ipt" "$MAIL_CHAIN" "$MAIL_WHITELIST_FILE" "$fam"
  IFS=',' read -ra ports <<< "$MAIL_PROTECTED_PORTS"

  # --- Cổng mail của Mailu (Docker, IPv4/IPv6 qua DNAT -> FORWARD -> DOCKER-USER) ---
  if $ipt -S DOCKER-USER >/dev/null 2>&1; then
    for port in "${ports[@]}"; do
      port=$(echo "$port" | tr -d '[:space:]'); [[ -z "$port" ]] && continue
      $ipt -I DOCKER-USER 1 -i "$EXT_IFACE" -p tcp -m conntrack --ctorigdstport "$port" \
        --ctdir ORIGINAL -m comment --comment "$TAG" -j "$MAIL_CHAIN"
    done
    echo "  [$ipt] DOCKER-USER: chặn cổng $MAIL_PROTECTED_PORTS trên $EXT_IFACE trừ whitelist"
  else
    echo "  [$ipt] chưa có chain DOCKER-USER (Docker chưa chạy?) — chỉ áp dụng ở INPUT"
  fi

  # --- Cùng các cổng đó ở INPUT: bắt kết nối do docker-proxy nhận trên host
  # (IPv6 tới container chỉ có IPv4, hoặc khi DNAT không áp dụng) và dịch vụ chạy trực tiếp trên host.
  for port in "${ports[@]}"; do
    port=$(echo "$port" | tr -d '[:space:]'); [[ -z "$port" ]] && continue
    $ipt -I INPUT 1 -i "$EXT_IFACE" -p tcp --dport "$port" -m comment --comment "$TAG" -j "$MAIL_CHAIN"
  done
  echo "  [$ipt] INPUT: chặn cổng $MAIL_PROTECTED_PORTS trên $EXT_IFACE trừ whitelist"

  # --- Cổng Mail API (host) ---
  if [[ "$FIREWALL_PROTECT_API" == "yes" ]]; then
    reset_chain "$ipt" "$API_CHAIN"
    fill_chain "$ipt" "$API_CHAIN" "$API_WHITELIST_FILE" "$fam"
    $ipt -I INPUT 1 -i "$EXT_IFACE" -p tcp --dport "$API_PORT" -m comment --comment "$TAG" -j "$API_CHAIN"
    echo "  [$ipt] INPUT: chặn cổng API $API_PORT trên $EXT_IFACE trừ whitelist"
  else
    drop_chain "$ipt" "$API_CHAIN"
  fi
}

remove_family() { # remove_family IPT
  local ipt=$1
  command -v "$ipt" >/dev/null || return 0
  purge_jumps "$ipt" DOCKER-USER
  purge_jumps "$ipt" INPUT
  drop_chain "$ipt" "$MAIL_CHAIN"
  drop_chain "$ipt" "$API_CHAIN"
  echo "  [$ipt] đã gỡ rule $TAG"
}

status_family() {
  local ipt=$1
  command -v "$ipt" >/dev/null || return 0
  echo "== $ipt"
  { $ipt -S DOCKER-USER 2>/dev/null; $ipt -S INPUT 2>/dev/null; } | grep -- "$TAG" || echo "  (không có rule)"
  $ipt -S "$MAIL_CHAIN" 2>/dev/null || true
  $ipt -S "$API_CHAIN" 2>/dev/null || true
}

case "${1:-}" in
  apply)
    [[ -f "$MAIL_WHITELIST_FILE" ]] || echo "Cảnh báo: thiếu $MAIL_WHITELIST_FILE — mọi IP ngoài sẽ bị chặn ở cổng mail"
    if [[ ",${MAIL_PROTECTED_PORTS// /}," == *",25,"* ]]; then
      echo "Cảnh báo: cổng 25 nằm trong whitelist — server sẽ KHÔNG nhận được thư từ Internet"
    fi
    echo "Interface: $EXT_IFACE"
    apply_family iptables 4
    apply_family ip6tables 6
    ;;
  remove)
    remove_family iptables
    remove_family ip6tables
    ;;
  status)
    status_family iptables
    status_family ip6tables
    ;;
  *)
    echo "Cách dùng: $0 {apply|remove|status}" >&2
    exit 1
    ;;
esac
