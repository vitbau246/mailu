#!/bin/sh
# Sinh bởi scripts/configure.py
# Certbot deploy hook: nạp lại chứng chỉ cho Mailu sau khi gia hạn.
# Cài: cp generated/certbot-deploy-hook-mailu.sh /etc/letsencrypt/renewal-hooks/deploy/mailu-reload.sh
case " $RENEWED_DOMAINS " in
  *" {{mail.hostname}} "*) ;;
  *) exit 0 ;;
esac
cd {{install_dir}} || exit 0
# chỉ restart khi front đang chạy (không tự bật Mailu nếu đang tắt có chủ đích)
[ -n "$(docker compose ps -q --status running front 2>/dev/null)" ] && docker compose restart front
exit 0
