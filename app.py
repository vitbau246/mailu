"""Mail API: chờ và đọc email mới nhất từ một người gửi trong hộp thư Mailu (IMAP).

Cấu hình đọc từ biến môi trường / file .env (xem .env.example).
Truy cập API bị giới hạn theo whitelist IP (xem whitelist/api.txt).
"""

import ipaddress
import logging
import os
import ssl
import threading
import time
from functools import wraps
from pathlib import Path

import pyzmail
from bs4 import BeautifulSoup
from flask import Flask, jsonify, request
from imapclient import IMAPClient

BASE_DIR = Path(__file__).resolve().parent


# --------------------------------------------------------------------------
# Cấu hình
# --------------------------------------------------------------------------

def load_dotenv(path):
    """Nạp file .env đơn giản (KEY=VALUE). Biến môi trường đã có sẵn được ưu tiên."""
    if not path.is_file():
        return
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        os.environ.setdefault(key.strip(), value)


load_dotenv(Path(os.environ.get("ENV_FILE", BASE_DIR / ".env")))


def env_int(name, default):
    return int(os.environ.get(name, default))


IMAP_HOST = os.environ.get("IMAP_HOST", "")
IMAP_PORT = env_int("IMAP_PORT", 993)
MAILBOX_PASSWORD = os.environ.get("MAILBOX_PASSWORD", "")

WAIT_TIMEOUT = env_int("WAIT_TIMEOUT", 300)          # giây, mặc định cho mỗi request
MAX_WAIT_TIMEOUT = env_int("MAX_WAIT_TIMEOUT", 600)  # giới hạn trên client được phép yêu cầu
POLL_INTERVAL = env_int("POLL_INTERVAL", 5)

API_WHITELIST_FILE = Path(os.environ.get("API_WHITELIST_FILE", BASE_DIR / "whitelist" / "api.txt"))
# Danh sách IP/CIDR của reverse proxy tin cậy (vd nginx). Chỉ khi request đến từ
# các IP này thì X-Forwarded-For / X-Real-IP mới được dùng để lấy IP thật của client.
# Mặc định tin nginx chạy cùng máy; nếu không, request qua nginx sẽ mang IP 127.0.0.1
# và luôn lọt qua whitelist.
TRUSTED_PROXIES_RAW = os.environ.get("TRUSTED_PROXIES", "127.0.0.1,::1")

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"),
                    format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("mail-api")

if not IMAP_HOST or not MAILBOX_PASSWORD:
    log.warning("IMAP_HOST hoặc MAILBOX_PASSWORD chưa được cấu hình (.env)")


# --------------------------------------------------------------------------
# Whitelist IP
# --------------------------------------------------------------------------

LOOPBACK = [ipaddress.ip_network("127.0.0.0/8"), ipaddress.ip_network("::1/128")]


def parse_networks(entries, source):
    nets = []
    for raw in entries:
        entry = raw.split("#", 1)[0].strip()
        if not entry:
            continue
        try:
            nets.append(ipaddress.ip_network(entry, strict=False))
        except ValueError:
            log.error("Bỏ qua mục whitelist không hợp lệ trong %s: %r", source, entry)
    return nets


TRUSTED_PROXIES = parse_networks(TRUSTED_PROXIES_RAW.replace(",", "\n").splitlines(), "TRUSTED_PROXIES")


class Whitelist:
    """Đọc whitelist từ file, tự nạp lại khi file thay đổi (không cần restart)."""

    def __init__(self, path):
        self.path = path
        self._mtime = None
        self._nets = list(LOOPBACK)
        self._lock = threading.Lock()

    def networks(self):
        try:
            mtime = self.path.stat().st_mtime
        except FileNotFoundError:
            mtime = None
        with self._lock:
            if mtime != self._mtime:
                self._mtime = mtime
                if mtime is None:
                    log.warning("Không thấy %s — chỉ cho phép localhost", self.path)
                    self._nets = list(LOOPBACK)
                else:
                    lines = self.path.read_text(encoding="utf-8").splitlines()
                    self._nets = LOOPBACK + parse_networks(lines, self.path)
                    log.info("Đã nạp whitelist API: %d mục", len(self._nets) - len(LOOPBACK))
            return self._nets

    def allows(self, ip):
        try:
            addr = ipaddress.ip_address(ip)
        except ValueError:
            return False
        if getattr(addr, "ipv4_mapped", None):
            addr = addr.ipv4_mapped
        return any(addr.version == net.version and addr in net for net in self.networks())


api_whitelist = Whitelist(API_WHITELIST_FILE)


def _in(ip, nets):
    try:
        addr = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return any(addr.version == n.version and addr in n for n in nets)


def client_ip():
    """IP thật của client. Chỉ tin X-Forwarded-For khi request đi qua proxy tin cậy."""
    remote = request.remote_addr or ""
    if not _in(remote, TRUSTED_PROXIES):
        return remote
    forwarded = [p.strip() for p in request.headers.get("X-Forwarded-For", "").split(",") if p.strip()]
    # Duyệt từ phải sang trái, bỏ qua các proxy tin cậy; IP đầu tiên không phải proxy là client.
    for ip in reversed(forwarded):
        if not _in(ip, TRUSTED_PROXIES):
            return ip
    real_ip = request.headers.get("X-Real-IP", "").strip()
    if real_ip:
        return real_ip
    return remote


def require_whitelisted_ip(view):
    @wraps(view)
    def wrapper(*args, **kwargs):
        ip = client_ip()
        if not api_whitelist.allows(ip):
            log.warning("Từ chối request từ IP %s tới %s", ip, request.path)
            return jsonify({"error": "forbidden"}), 403
        return view(*args, **kwargs)
    return wrapper


# --------------------------------------------------------------------------
# Đọc email
# --------------------------------------------------------------------------

def html_to_text(html):
    soup = BeautifulSoup(html, "html.parser")
    text = soup.get_text("\n")
    return "\n".join(line.strip() for line in text.splitlines() if line.strip())


def extract_body(msg):
    if msg.text_part:
        return msg.text_part.get_payload().decode(
            msg.text_part.charset or "utf-8", errors="ignore"
        ).strip()
    if msg.html_part:
        html = msg.html_part.get_payload().decode(
            msg.html_part.charset or "utf-8", errors="ignore"
        )
        return html_to_text(html)
    return ""


def wait_email(receiver_email, sender_email, timeout, only_new=False):
    """Poll INBOX của receiver_email tới khi thấy thư từ sender_email.

    Trả về "subject|body" của thư mới nhất khớp, hoặc "TIMEOUT".
    only_new=True: bỏ qua mọi thư đã có trong INBOX trước lúc gọi (tránh trả OTP cũ).
    """
    context = ssl.create_default_context()

    with IMAPClient(IMAP_HOST, port=IMAP_PORT, ssl=True, ssl_context=context) as server:
        server.login(receiver_email, MAILBOX_PASSWORD)
        server.select_folder("INBOX")

        start_time = time.time()
        checked_uids = set()
        if only_new:
            # UID trong IMAP tăng dần: đánh dấu mọi thư hiện có là "đã xem"
            checked_uids.update(server.search(["ALL"]))

        while time.time() - start_time < timeout:
            messages = server.search(["ALL"])

            for uid in reversed(messages):
                if uid in checked_uids:
                    continue
                checked_uids.add(uid)

                raw_message = server.fetch([uid], ["BODY[]"])[uid][b"BODY[]"]
                msg = pyzmail.PyzMessage.factory(raw_message)

                from_email = msg.get_addresses("from")
                if not from_email:
                    continue
                if sender_email.lower() not in from_email[0][1].lower():
                    continue

                return f"{msg.get_subject()}|{extract_body(msg)}"

            time.sleep(POLL_INTERVAL)

    return "TIMEOUT"


# --------------------------------------------------------------------------
# API
# --------------------------------------------------------------------------

app = Flask(__name__)


@app.route("/", methods=["GET"])
@require_whitelisted_ip
def api_hello():
    return jsonify({"result": "HELLO!"})


@app.route("/wait-email", methods=["POST"])
@require_whitelisted_ip
def api_wait_email():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        data = {}

    receiver_email = data.get("receiver_email")
    sender_email = data.get("sender_email")

    if not isinstance(receiver_email, str) or not isinstance(sender_email, str) \
            or not receiver_email.strip() or not sender_email.strip():
        return jsonify({"error": "receiver_email and sender_email required"}), 400

    try:
        timeout = int(data.get("timeout", WAIT_TIMEOUT))
    except (TypeError, ValueError):
        return jsonify({"error": "timeout must be an integer"}), 400
    timeout = max(1, min(timeout, MAX_WAIT_TIMEOUT))
    only_new = data.get("only_new", False) is True

    try:
        result = wait_email(receiver_email, sender_email, timeout, only_new)
    except IMAPClient.Error as exc:
        log.warning("Lỗi IMAP cho %s: %s", receiver_email, exc)
        return jsonify({"error": "imap login/read failed"}), 502
    except (OSError, ssl.SSLError) as exc:
        log.error("Không kết nối được IMAP %s:%s: %s", IMAP_HOST, IMAP_PORT, exc)
        return jsonify({"error": "imap connection failed"}), 502

    return jsonify({"result": result})


if __name__ == "__main__":
    app.run(
        host=os.environ.get("API_HOST", "0.0.0.0"),
        port=env_int("API_PORT", 8000),
    )
