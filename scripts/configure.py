#!/usr/bin/env python3
"""Sinh các file cấu hình triển khai từ config.yml.

    venv/bin/python scripts/configure.py            # sinh file
    venv/bin/python scripts/configure.py --check    # chỉ kiểm tra config.yml

Đầu vào : config.yml (không commit; mẫu: config.example.yml) + templates/
Đầu ra  : .env, mailu.env, generated/ (đều không commit)
"""

import argparse
import ipaddress
import os
import re
import stat
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.exit("Thiếu PyYAML: venv/bin/pip install -r requirements.txt")

ROOT = Path(__file__).resolve().parent.parent
TEMPLATES = ROOT / "templates"

# template -> (file đầu ra, quyền, có chứa secrets)
OUTPUTS = {
    "env.tmpl": (".env", 0o600),
    "mailu.env.tmpl": ("mailu.env", 0o600),
    "systemd/mailu-api.service": ("generated/systemd/mailu-api.service", 0o644),
    "systemd/mailu-firewall.service": ("generated/systemd/mailu-firewall.service", 0o644),
    "systemd/mailu-whitelist.path": ("generated/systemd/mailu-whitelist.path", 0o644),
    "systemd/mailu-whitelist.service": ("generated/systemd/mailu-whitelist.service", 0o644),
    "nginx/mail-api.conf": ("generated/nginx/mail-api.conf", 0o644),
    "nginx/mailu-web.conf": ("generated/nginx/mailu-web.conf", 0o644),
    "certbot-deploy-hook-mailu.sh": ("generated/certbot-deploy-hook-mailu.sh", 0o755),
}

PLACEHOLDER = re.compile(r"\{\{\s*([A-Za-z0-9_.]+)\s*\}\}")
HOSTNAME = re.compile(r"^(?=.{1,253}$)([A-Za-z0-9-]{1,63}\.)+[A-Za-z]{2,63}$")


class ConfigError(Exception):
    pass


def flatten(data, prefix=""):
    flat = {}
    for key, value in data.items():
        name = f"{prefix}{key}"
        if isinstance(value, dict):
            flat.update(flatten(value, name + "."))
        else:
            flat[name] = value
    return flat


def to_str(value):
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, (list, tuple)):
        return ",".join(str(v) for v in value)
    return "" if value is None else str(value)


def validate(c):
    errors = []

    def need(key, check=None, msg=None):
        value = c.get(key)
        if value in (None, "", []):
            errors.append(f"{key}: bắt buộc")
        elif check and not check(value):
            errors.append(f"{key}: {msg} (đang là {value!r})")

    def is_ip(v, net=False):
        try:
            (ipaddress.ip_network if net else ipaddress.ip_address)(str(v))
            return True
        except ValueError:
            return False

    def is_port(v):
        return isinstance(v, int) and 0 < v < 65536

    def is_bind(v):
        host, _, port = str(v).rpartition(":")
        return is_ip(host) and port.isdigit() and is_port(int(port))

    need("install_dir", lambda v: str(v).startswith("/"), "phải là đường dẫn tuyệt đối")
    need("mail.domain", lambda v: HOSTNAME.match(str(v)), "domain không hợp lệ")
    need("mail.hostname", lambda v: HOSTNAME.match(str(v)), "hostname không hợp lệ")
    need("mail.website")
    need("mail.postmaster")
    need("server.public_ipv4", lambda v: is_ip(v), "không phải IP")
    if c.get("server.public_ipv6"):
        need("server.public_ipv6", lambda v: is_ip(v), "không phải IP")
    need("mailu.data_dir", lambda v: str(v).startswith("/"), "phải là đường dẫn tuyệt đối")
    need("mailu.http_bind", is_bind, "dạng IP:PORT")
    need("mailu.subnet", lambda v: is_ip(v, net=True), "không phải CIDR")
    for key in ("mailu.gateway_ip", "mailu.resolver_ip"):
        need(key, lambda v: is_ip(v) and is_ip(c.get("mailu.subnet") or "", True)
             and ipaddress.ip_address(str(v)) in ipaddress.ip_network(str(c["mailu.subnet"])),
             "phải là IP nằm trong mailu.subnet")
    need("mailu.tls.letsencrypt_name")
    need("api.host", lambda v: is_ip(v), "không phải IP")
    need("api.port", is_port, "cổng không hợp lệ")
    need("api.imap_port", is_port, "cổng không hợp lệ")
    need("api.max_wait_timeout", lambda v: isinstance(v, int) and v > 0, "phải là số nguyên dương")
    need("nginx.api_hostname", lambda v: HOSTNAME.match(str(v)), "hostname không hợp lệ")
    need("nginx.mail_mode", lambda v: v in ("webmail", "api", "both"), "webmail | api | both")
    for proxy in c.get("api.trusted_proxies") or []:
        if not is_ip(proxy, net=True):
            errors.append(f"api.trusted_proxies: {proxy!r} không phải IP/CIDR")
    for port in c.get("firewall.mail_protected_ports") or []:
        if not is_port(port):
            errors.append(f"firewall.mail_protected_ports: {port!r} không phải cổng")
    for key in ("mailu.secret_key", "mailu.api_token", "api.mailbox_password"):
        value = to_str(c.get(key))
        if not value or value == "change-me":
            errors.append(f"{key}: chưa đặt giá trị thật (đang là {value!r})")
        elif "\n" in value or "'" in value:
            errors.append(f"{key}: không được chứa xuống dòng hoặc dấu nháy đơn")
    if errors:
        raise ConfigError("\n".join("  - " + e for e in errors))


def build_context(config):
    c = flatten(config)
    validate(c)
    c["api.imap_host"] = c.get("api.imap_host") or c["mail.hostname"]
    # IP Mailu không áp giới hạn đăng nhập: gateway docker + IP public (Mail API trên host)
    exempt = [c["mailu.gateway_ip"], c["server.public_ipv4"]]
    if c.get("server.public_ipv6"):
        exempt.append(c["server.public_ipv6"])
    c["auth_ratelimit_exemption"] = ",".join(str(x) for x in exempt)
    c["api_read_timeout"] = int(c["api.max_wait_timeout"]) + 60
    return {k: to_str(v) for k, v in c.items()}


def render(text, ctx, name):
    missing = sorted({m for m in PLACEHOLDER.findall(text) if m not in ctx})
    if missing:
        raise ConfigError(f"{name}: thiếu khoá trong config.yml: {', '.join(missing)}")
    return PLACEHOLDER.sub(lambda m: ctx[m.group(1)], text)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default=ROOT / "config.yml", type=Path)
    parser.add_argument("--check", action="store_true", help="chỉ kiểm tra config, không ghi file")
    args = parser.parse_args()

    if not args.config.is_file():
        sys.exit(f"Không thấy {args.config}. Tạo từ mẫu: cp config.example.yml config.yml")
    if args.config.stat().st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        print(f"Cảnh báo: {args.config} chứa secrets, nên chmod 600", file=sys.stderr)

    try:
        config = yaml.safe_load(args.config.read_text(encoding="utf-8")) or {}
        ctx = build_context(config)
        rendered = {
            out: (render((TEMPLATES / tpl).read_text(encoding="utf-8"), ctx, tpl), mode)
            for tpl, (out, mode) in OUTPUTS.items()
        }
    except (ConfigError, yaml.YAMLError) as exc:
        sys.exit(f"config.yml không hợp lệ:\n{exc}")

    if args.check:
        print("config.yml hợp lệ")
        return

    for out, (content, mode) in rendered.items():
        path = ROOT / out
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_name(path.name + ".tmp")
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(content)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
        print(f"  đã ghi {out}")

    for name in ("api.txt", "mail.txt"):
        wl = ROOT / "whitelist" / name
        if not wl.exists():
            wl.write_text((ROOT / "whitelist" / f"{name}.example").read_text(encoding="utf-8"))
            print(f"  đã tạo whitelist/{name} (trống — chỉ localhost được phép)")

    print("\nTiếp theo: docker compose config -q && docker compose up -d   (xem README)")


if __name__ == "__main__":
    main()
