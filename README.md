# Mailu Mail Server + Mail API

Dự án gồm hai phần chạy trên cùng một máy chủ:

1. **Mailu** (Docker Compose): mail server đầy đủ gồm SMTP (Postfix), IMAP/POP3 (Dovecot), chống spam (Rspamd), webmail Roundcube và trang quản trị.
2. **Mail API** (`app.py`, Flask + Gunicorn): một HTTP API nhỏ. API đăng nhập IMAP vào một hộp thư của Mailu, chờ thư từ một người gửi chỉ định rồi trả về tiêu đề và nội dung thư. Thường dùng để lấy OTP hoặc mã xác thực tự động.

Cả hai đều có **whitelist IP**: chỉ những IP được cấu hình mới gọi được API và kết nối được các cổng mail client. Lớp bảo vệ được áp ở ba tầng: trong app, ở nginx và ở iptables.

## Nguyên tắc cấu hình

Mọi thông tin riêng của server, gồm domain, IP, cổng, đường dẫn, chứng chỉ và secrets, **chỉ nằm trong `config.yml`**. File này không được commit. Repo chỉ chứa file mẫu và template.

```
config.yml  ──►  scripts/configure.py  ──►  .env, mailu.env, generated/   (không commit)
 (từ config.example.yml)                          ▲
                                       templates/ ┘                        (commit)
```

| Đường dẫn | Mô tả | Commit? |
|---|---|---|
| `config.example.yml` | Mẫu cấu hình, có giải thích từng khoá | ✅ |
| `config.yml` | **Cấu hình thật**: domain, IP, cổng, secrets | ❌ |
| `templates/` | Template của `.env`, `mailu.env`, unit systemd, vhost nginx, hook certbot | ✅ |
| `scripts/configure.py` | Sinh file cấu hình từ `config.yml` và `templates/` | ✅ |
| `.env`, `mailu.env`, `generated/` | File sinh ra, **không sửa tay** | ❌ |
| `docker-compose.yml` | Stack Mailu, đọc biến từ `.env` | ✅ |
| `app.py`, `requirements.txt` | Mail API | ✅ |
| `mailu-users.example.yml` | Mẫu file import domain/user vào Mailu | ✅ |
| `mailu-users.yml` | File import thật (chứa hash mật khẩu) | ❌ |
| `mail-config.example.yml` | Mẫu danh sách hộp thư | ✅ |
| `mail-config.yml` | Danh sách hộp thư thật | ❌ |
| `whitelist/*.txt.example` | Mẫu whitelist IP | ✅ |
| `whitelist/api.txt`, `whitelist/mail.txt` | Whitelist thật | ❌ |
| `scripts/firewall-whitelist.sh` | Áp whitelist cổng mail/API bằng iptables | ✅ |
| `scripts/nginx-whitelist.sh` | Sinh snippet `allow/deny` cho nginx từ whitelist | ✅ |
| `scripts/nginx-setup.sh` | Tự tạo vhost nginx cho domain mail nếu chưa có | ✅ |

Kiểm tra trước khi push: `git status` không được có `config.yml`, `.env`, `mailu.env` hay bất kỳ file nào trong `generated/`. Các file này đã có trong `.gitignore`.

## Cài đặt

### 1. Tạo cấu hình

```bash
git clone <repo> /opt/mailu && cd /opt/mailu
python3 -m venv venv && venv/bin/pip install -r requirements.txt

cp config.example.yml config.yml && chmod 600 config.yml
# Sửa config.yml: domain, hostname, IP server, đường dẫn, secrets...
#   openssl rand -hex 16   -> mailu.secret_key
#   openssl rand -hex 32   -> mailu.api_token

venv/bin/python scripts/configure.py --check   # chỉ kiểm tra
venv/bin/python scripts/configure.py           # sinh .env, mailu.env, generated/
```

`configure.py` kiểm tra định dạng domain, IP, CIDR và cổng. Nếu secrets vẫn là `change-me`, script báo lỗi và không ghi file nào. Lần đầu chạy, script tạo thêm `whitelist/api.txt` và `whitelist/mail.txt` rỗng.

**Mỗi lần sửa `config.yml` phải chạy lại `configure.py`**, sau đó khởi động lại dịch vụ liên quan.

### 2. Chứng chỉ TLS

Mailu dùng chứng chỉ Let's Encrypt của host: `/etc/letsencrypt/live/<mailu.tls.letsencrypt_name>`. Chứng chỉ này phải phủ `mail.hostname`. `docker-compose.yml` chỉ mount đúng chứng chỉ đó vào container, ở chế độ chỉ đọc.

```bash
certbot certonly --nginx -d mail.example.com            # nếu chưa có chứng chỉ
cp generated/certbot-deploy-hook-mailu.sh /etc/letsencrypt/renewal-hooks/deploy/mailu-reload.sh
```

Hook trên khởi động lại Mailu front sau mỗi lần gia hạn để nạp chứng chỉ mới. Nếu Mailu đang tắt, hook không làm gì.

### 3. Chạy Mailu

```bash
docker compose config -q && docker compose up -d
docker compose exec admin flask mailu admin admin example.com 'MatKhauManh'
# Hoặc import domain/user hàng loạt:
docker compose exec -T admin flask mailu config-import -v < mailu-users.yml
```

Cổng 25 (nhận thư), 465/587 (gửi thư), 110/995 (POP3) và 143/993 (IMAP) được publish ra ngoài. Giao diện web chỉ bind vào `mailu.http_bind`, mặc định `127.0.0.1:8080`, và được đưa ra ngoài qua nginx.

### 4. Chạy Mail API

```bash
venv/bin/python app.py                                  # chạy thử
cp generated/systemd/mailu-api.service /etc/systemd/system/
systemctl daemon-reload && systemctl enable --now mailu-api
```

## Sử dụng Mail API

### `GET /` để kiểm tra API

```bash
curl https://api.example.com/v1/
# {"result": "HELLO!"}
```

### `POST /wait-email` để chờ và đọc thư

| Trường | Bắt buộc | Mô tả |
|---|---|---|
| `receiver_email` | ✅ | Hộp thư cần đọc. API đăng nhập bằng địa chỉ này và `api.mailbox_password`. |
| `sender_email` | ✅ | Chuỗi cần có trong địa chỉ người gửi, không phân biệt hoa thường (vd `no-reply@service.com`) |
| `timeout` | | Số giây chờ, mặc định `api.wait_timeout`, tối đa `api.max_wait_timeout` |
| `only_new` | | `true` thì chỉ trả thư đến **sau** lúc gọi API, bỏ qua thư cũ trong INBOX. Mặc định `false`. |

```bash
curl -X POST https://api.example.com/v1/wait-email \
  -H 'Content-Type: application/json' \
  -d '{"receiver_email":"user1@example.com","sender_email":"no-reply@service.com","timeout":120,"only_new":true}'
```

| HTTP | Body | Ý nghĩa |
|---|---|---|
| 200 | `{"result": "<subject>\|<body>"}` | Tìm thấy thư. HTML đã được chuyển sang text. |
| 200 | `{"result": "TIMEOUT"}` | Hết thời gian mà chưa có thư phù hợp |
| 400 | `{"error": "..."}` | Thiếu tham số hoặc tham số sai |
| 403 | `{"error": "forbidden"}` | IP không nằm trong whitelist |
| 502 | `{"error": "imap ..."}` | Sai mật khẩu hoặc không kết nối được IMAP |

Khi không truyền `only_new`, API trả về thư **mới nhất** đang có trong INBOX, kể cả thư đã nhận trước khi gọi. Khi lấy OTP, nên truyền `"only_new": true` để không nhận nhầm mã cũ.

## Whitelist IP

### Định dạng file

Mỗi dòng ghi một IPv4/IPv6 hoặc một dải CIDR. Phần sau `#` là ghi chú.

```
203.0.113.10
198.51.100.0/24   # văn phòng
2001:db8::/32
```

| File | Áp dụng cho | Tầng |
|---|---|---|
| `whitelist/api.txt` | Mail API | app (tự nạp lại khi file đổi), nginx, iptables (cổng `api.port`) |
| `whitelist/mail.txt` | Webmail/admin và các cổng mail client | nginx, iptables (cổng `firewall.mail_protected_ports`) |

Localhost luôn được phép. Nếu file trống, **chỉ localhost** truy cập được.

### Áp dụng

```bash
sudo scripts/nginx-whitelist.sh             # sinh /etc/nginx/snippets/mailu-*-allow.conf + reload nginx
sudo scripts/firewall-whitelist.sh apply    # iptables + ip6tables
sudo scripts/firewall-whitelist.sh status
sudo scripts/firewall-whitelist.sh remove
```

Để whitelist tự áp dụng khi khởi động máy và mỗi khi file whitelist thay đổi:

```bash
cp generated/systemd/mailu-firewall.service generated/systemd/mailu-whitelist.* /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now mailu-firewall mailu-whitelist.path
```

### Cách firewall hoạt động

- Các cổng mail bị lọc ở hai chain: `DOCKER-USER` bắt traffic IPv4 mà Docker chuyển (DNAT) vào container. `INPUT` bắt kết nối IPv6, vốn do `docker-proxy` trên host nhận vì mạng Docker không bật IPv6. Thiếu rule ở `INPUT` thì whitelist có thể bị lách qua IPv6.
- Chỉ traffic vào từ interface Internet (`server.ext_iface`, mặc định tự dò) bị lọc. Traffic giữa các container và từ localhost không bị ảnh hưởng.
- Mọi rule mang comment `mailu-whitelist`, nên script không đụng tới rule khác.
- **Không** đưa cổng 25 vào `mail_protected_ports` nếu server cần nhận thư từ Internet.

## Cấu hình nginx

nginx trên host làm reverse proxy HTTPS cho:

| Thành phần | Backend | Whitelist |
|---|---|---|
| Mail API, vhost `nginx.api_hostname` | `127.0.0.1:<api.port>` | `whitelist/api.txt` |
| Web Mailu (webmail, `/admin`), vhost `mail.hostname` | `mailu.http_bind` | `whitelist/mail.txt` |

Các cổng IMAP/SMTP **không** đi qua nginx. Mailu tự xử lý các cổng này.

### Cách A: tự động tạo vhost cho domain mail

```bash
scripts/nginx-setup.sh --dry-run          # xem trước
sudo scripts/nginx-setup.sh               # domain = mail.hostname trong config.yml
sudo scripts/nginx-setup.sh -d mail.example.com -m both -e admin@example.com
```

| Tuỳ chọn | Mặc định | Ý nghĩa |
|---|---|---|
| `-d, --domain` | `mail.hostname` | Domain cần tạo vhost |
| `-m, --mode` | `nginx.mail_mode` | `webmail`: `/` → web Mailu. `api`: `/` → Mail API. `both`: `/` → web Mailu và `/mail-api/` → Mail API. |
| `-e, --email` | `nginx.letsencrypt_email` | Email để xin chứng chỉ Let's Encrypt khi chưa có |
| `--dry-run` | | Chỉ in cấu hình ra màn hình |

Script thực hiện các bước sau:

1. Nếu domain đã có `server_name` trong cấu hình nginx, script báo file chứa nó và **dừng lại, không sửa gì**.
2. Tìm trong `/etc/letsencrypt/live/` một chứng chỉ còn hạn phủ domain, kể cả wildcard.
   - Nếu có, tạo vhost HTTPS.
   - Nếu không có, tạo vhost HTTP. Nếu có email, script chạy thêm `certbot --nginx --redirect`.
3. Sinh snippet whitelist nếu chưa có, ghi `sites-available/mailu-<domain>`, tạo symlink, chạy `nginx -t` rồi reload. Nếu `nginx -t` lỗi, script tự gỡ vhost vừa tạo.

### Cách B: dùng file đã sinh sẵn

`configure.py` sinh sẵn hai vhost theo `config.yml`:

```bash
cp generated/nginx/mail-api.conf  /etc/nginx/sites-available/mail-api
cp generated/nginx/mailu-web.conf /etc/nginx/sites-available/mailu-web
ln -s /etc/nginx/sites-available/mail-api /etc/nginx/sites-available/mailu-web /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx
```

Một `server_name` chỉ được khai báo ở **một** vhost. Nếu domain đã có trong file cấu hình khác, hãy sửa ngay trong file đó, không tạo thêm vhost mới.

### Yêu cầu để backend nhận đúng IP client

- **Mail API**: giữ `127.0.0.1` và `::1` trong `api.trusted_proxies`. Nếu bỏ đi, mọi request đi qua nginx đều bị coi là localhost và **bỏ qua whitelist**. nginx phải gửi `proxy_set_header X-Forwarded-For $remote_addr;`, tức ghi đè header thay vì nối thêm. `proxy_read_timeout` phải lớn hơn `api.max_wait_timeout`; file sinh ra đã tự cộng thêm 60 giây.
- **Mailu**: `mailu.env` đặt `REAL_IP_HEADER=X-Real-IP` và `REAL_IP_FROM=<mailu.gateway_ip>`. Thiếu cấu hình này, Mailu thấy mọi người dùng chung một IP, và giới hạn đăng nhập theo IP sẽ khoá tất cả cùng lúc. Kiểm tra bằng `docker compose logs front`: IP trong log phải là IP thật của client.

### Kiểm tra

```bash
curl https://api.example.com/v1/          # từ IP trong whitelist  -> {"result": "HELLO!"}
curl -i https://api.example.com/v1/       # từ IP ngoài whitelist  -> 403
```

## Bảo mật

- Giữ quyền `600` cho `config.yml`, `.env`, `mailu.env`, `mailu-users.yml` và `mail-config.yml`.
- `mailu.env` có `AUTH_RATELIMIT_EXEMPTION`. `configure.py` ghép giá trị này từ `mailu.gateway_ip` và IP public của server. Mail API đăng nhập IMAP vào nhiều hộp thư từ cùng một IP; nếu không miễn trừ, chỉ vài lần đăng nhập sai là Mailu chặn luôn API. Khi IP server đổi, sửa `config.yml` rồi chạy lại `configure.py`.
- Dùng mật khẩu mạnh, sinh ngẫu nhiên, cho hộp thư và cho `api.mailbox_password`.
- Nếu secrets từng nằm trong mã nguồn hoặc từng được chia sẻ, **hãy đổi chúng**.
