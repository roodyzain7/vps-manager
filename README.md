# VPS Manager — SSH, VMess, VLESS, Trojan (Xray-core)

Script Bash lengkap untuk mengelola akun SSH, VMess, VLESS, dan Trojan di satu VPS
Linux, memakai **Xray-core resmi**. Semua lewat menu terminal — tidak perlu panel
web. Untuk administrasi server sendiri (legal), bukan backdoor.

## Ringkas

| Item | Keterangan |
|---|---|
| OS target | Ubuntu 22.04 / 24.04 atau Debian 12, fresh install, akses root |
| Core | Xray-core resmi (script install XTLS) |
| Config Xray | `/usr/local/etc/xray/config.json` |
| State akun | `/etc/vps-manager/state.json` (chmod 600) |
| Log | `/var/log/vps-manager.log` |
| Nginx | `/etc/nginx/conf.d/vps-manager.conf` (mode domain) |
| Sertifikat | `/etc/vps-manager/ssl/` (acme.sh, EC-256, auto-renew) |
| Cron expired | `/etc/cron.d/vps-manager` (cek harian jam 02:00) |

## Cara install (1 perintah)

Di VPS sebagai root:

```bash
curl -fsSL -o vps-manager.sh <URL-FILE-vps-manager.sh>
chmod +x vps-manager.sh
bash vps-manager.sh
```

Lalu pilih menu **1) Install/Update dependensi & Xray** dan pilih mode:

- **1) Domain + TLS** — butuh domain yang A record-nya sudah mengarah ke IP VPS,
  dan email untuk Let's Encrypt. Sertifikat diterbitkan otomatis via acme.sh
  (standalone, EC-256). Nginx melayani VMess/VLESS/Trojan/SSH di **dua port**:
  **80 non-TLS** dan **443 TLS**, dengan path tetap `/vmess`, `/vless`,
  `/trojan`, dan `/ssh-ws` (SSH WS via jembatan ws-epro ke SSH 22).
- **2) REALITY tanpa domain** — tidak butuh domain/sertifikat. Keypair REALITY
  dibuat otomatis (`xray x25519`). VLESS jalan di TCP 443 dengan REALITY,
  VMess tetap lewat WS port 10001 (tanpa TLS).

Install bersifat **idempotent**: dijalankan ulang tidak menghapus akun yang
sudah ada — config Xray selalu dibangun ulang dari `state.json`.

> Setelah install, script tersalin ke `/usr/local/bin/vps-manager`, jadi cukup
> ketik `vps-manager` untuk membuka menu.

## Link permanen (tidak expired)

Link unduhan dari chat selalu kedaluwarsa — jadi script ini **menyajikan
dirinya sendiri** dari domainmu: sesudah install (menu 1), file
`/usr/local/bin/vps-manager` bisa diunduh kapan saja dari:

```
https://<domain-kamu>/vps-manager.sh
```

Install di VPS lain / install ulang, cukup:

```bash
curl -fsSL https://<domain-kamu>/vps-manager.sh -o /usr/local/bin/vps-manager && chmod +x /usr/local/bin/vps-manager && vps-manager
```

Link ini hidup selama VPS-mu hidup. Cek dengan
`vps-manager --check` (bagian "Link permanen"). Salinan yang sudah terinstall
di `/usr/local/bin/vps-manager` juga permanen — perintah `menu` selalu bisa
dipakai di VPS itu tanpa mengunduh apa pun.

## Cara pakai menu

Sesudah install, cukup ketik `menu` di terminal — menu langsung muncul dengan
hasil instalasi yang sudah ada (mode, domain, status Xray, jumlah akun):

```bash
menu
```

(`vps-manager` juga bisa — `menu` hanya pintasan ke perintah yang sama.
Pintasan dibuat otomatis saat install; bila install dari versi lama, cukup
jalankan `vps-manager` sekali.)

```
============================================================
   VPS MANAGER — SSH / VMess / VLESS / Trojan (Xray-core)
============================================================
  OS     : Ubuntu 24.04.5 LTS
  RAM    : 512MB / 2048MB
  SWAP   : 0MB / 2047MB
  CITY   : Jakarta
  ISP    : PT Deneva
  IP     : 43.156.218.74
  DOMAIN : vpn.domainkamu.com
  UPTIME : 3 hours, 56 minutes
------------------------------------------------------------
  MONTH  : 1.17 TiB
  RX     : 610.91 GiB
  TX     : 582.84 GiB
  DAY    : 137.00 GiB
  RX     : 69.76 GiB
  TX     : 67.24 GiB
  TRAFFIC: 585.62 kbit/s
------------------------------------------------------------
  XRAY: ON | SSH-WS: ON | NGINX: ON | BOT: OFF | GOOD
------------------------------------------------------------
  Akun: 3 (aktif: 3, expired: 0) | Hampir expired (<=3 hari): 0
============================================================
  01) Install / Update         07) Hapus Akun
  02) Buat Akun SSH            08) Perpanjang Akun
  03) Buat Akun VMess          09) Link Akun
  04) Buat Akun VLESS          10) Uninstall Bersih
  05) Buat Akun Trojan         11) Bot Telegram
  06) List Semua Akun          00) Keluar
```

Tampilan di atas adalah versi baru yang rapi seperti screenshot referensi:
info server (OS/RAM/SWAP/CITY/ISP/IP/DOMAIN/UPTIME), traffic MONTH/DAY +
kecepatan saat ini, baris status XRAY/SSH-WS/NGINX/BOT, dan menu 2 kolom.

Kota/ISP diambil sekali dari ipinfo.io lalu disimpan di state (tidak
menghambat menu berikutnya). Traffic MONTH/DAY dibaca dari `vnstat` bila
terpasang (`apt install vnstat`); bila belum, tampil total sejak boot.

## Features (menu 12)

Submenu perbaikan dan utilitas, seperti menu FEATURES di screenshot
referensi — 26 item dalam 5 bagian:

```
FEATURES
  1.) Running Service          (status Xray/Nginx/ws-epro/Bot + port LISTEN)
  2.) Restart Service          (restart Xray, Nginx, ws-epro, SSH berurutan)
  3.) Auto Reboot              (atur / hapus reboot harian)
  4.) Monitoring               (uptime, load, RAM, disk, traffic, top proses)
  5.) SpeedTest                (speedtest-cli, atau unduh 10 MB Cloudflare)
  6.) Delete All Account Exp   (hapus/expire-kan semua akun yang sudah lewat)
MENU FIXX
  7.) Change Banner            (ganti banner SSH)
  8.) Change Domain            (ganti domain + terbitkan ulang sertifikat)
  9.) Change DNS Server        (ganti resolver, mis. 1.1.1.1 / 8.8.8.8)
 10.) Fixx Haproxy             (install bila belum ada + config backend ke
                                Xray 10001-10003 / ws-epro 10090 / Nginx 443,
                                lalu restart; port 8880 HTTP + 9444 TLS)
 11.) Fixx Nginx               (nginx -t, bangun ulang config bila rusak,
                                restart, cek port 80/443)
 12.) Fixx WS ePRO             (install ulang bila belum terpasang, cek modul
                                websockets, restart, cek port 10090)
 13.) Fixx Domain              (cek A record vs IP VPS, perbaiki sertifikat,
                                bangun ulang Nginx/Xray, restart berurutan)
 14.) Fixx Xray                (xray -test, restart, cek port, tampilkan
                                error.log bila gagal)
MENU CLEAR
 15.) Clear Cache              (apt clean)
 16.) Clear Logs               (kosongkan log Xray/vps-manager, journal >100M)
 17.) Clear Cache File         (hapus file lama di /tmp dan /var/tmp)
INFORMATION
 18.) Info Service Port        (semua port LISTEN + prosesnya)
 19.) Information System       (OS, kernel, CPU, RAM, disk, IP, versi Xray)
 20.) List Open Source & Sewa Script (komponen open source yang dipakai)
OTHER
 21.) Anti-DDoS Protection     (install + aktifkan fail2ban untuk SSH)
 22.) Script Other             (update script dari GitHub, verifikasi bash -n)
 23.) Limit Speed              (batas total traffic via tc HTB, 0 = hapus)
 24.) Limit-on-off XRAY        (matikan / nyalakan layanan Xray)
 25.) Boster CPU (multi-threading) (governor performance bila tersedia,
                                naikkan prioritas proses xray/nginx/ws-epro)
 26.) Back to Menu
  x . EXIT
```

Catatan jujur: item 9 di screenshot aslinya "Change Domain NS" (untuk
SlowDNS) — script ini tidak memakai SlowDNS, jadi item itu diganti Change
DNS Server (resolver). Item 10 Fixx Haproxy hanya berlaku bila HAProxy
memang terpasang dari install lama; instalasi vps-manager sendiri memakai
Nginx di port 80/443 dan tidak butuh HAProxy.

## Perintah non-interaktif (otomasi)

```bash
# Install
bash vps-manager.sh --install --mode domain --domain vpn.domainkamu.com --email admin@domainkamu.com
bash vps-manager.sh --install --mode reality

# Buat akun
bash vps-manager.sh --create ssh    --name user1 --days 30
bash vps-manager.sh --create ssh    --name user1 --days 30 --password Rahasia123
bash vps-manager.sh --create vmess  --name user1 --days 30 --limit-ip 2
bash vps-manager.sh --create vless  --name user1 --days 30 --transport ws
bash vps-manager.sh --create trojan --name user1 --days 30

# Lihat / hapus / perpanjang / tampilkan link
bash vps-manager.sh --list
bash vps-manager.sh --delete --protocol vmess --name user1 [--yes]
bash vps-manager.sh --renew  --protocol vless --name user1 --days 30
bash vps-manager.sh --show   --protocol trojan --name user1
bash vps-manager.sh --check-expired
bash vps-manager.sh --uninstall
bash vps-manager.sh --help

# Bot Telegram (tanpa menu, langsung dari terminal)
bash vps-manager.sh --setup-bot --bot-token 123456:ABC-DEF --admin-chat-id 123456789
```

## Bot Telegram (menu 11)

Kelola akun dari Telegram, tanpa buka Termius. Bot hanya menjawab admin
yang dikonfigurasi, dan semua aksi dijalankan lewat CLI `vps-manager` yang
sama dengan menu terminal.

**Siapkan dulu (2 menit):**

1. Chat **@BotFather** di Telegram → `/newbot` → ikuti langkahnya → salin
   token (format `123456:ABC-DEF...`).
2. Chat **@userinfobot** (atau @getmyid_bot) → salin angka Chat ID kamu.

**Aktifkan:**

```bash
menu
# pilih 11) Bot Telegram → 01 Instal / Update Bot → isi token + Chat ID
```

**Bot tidak ada respon?** Jalankan diagnosa — dia memeriksa service, log,
format token, lalu mengecek token ke Telegram (getMe) dan pesan masuk
terakhir (getUpdates), plus menawarkan kirim pesan tes:

```bash
menu
# pilih 11) Bot Telegram → 05 Diagnosa Bot
```

atau langsung:

```bash
vps-manager --bot-check
```

Penyebab yang paling sering: token salah/sudah diganti (getMe 401),
VPS tidak bisa mencapai api.telegram.org (DNS), chat dari akun/Chat ID
yang berbeda dari yang dikonfigurasi, atau belum `/start` ke bot yang
benar. Diagnosa menampilkan semuanya — termasuk username bot yang benar.

**Buat akun via bot tidak menampilkan hasil?** Dulu penyebabnya prompt
"Simpan QR sebagai PNG?" di `show_link` yang tidak terjaga terminal —
saat bot menjalankan pembuatan akun, `read` gagal dan script mati sebelum
hasil dikirim. QR sekarang dihapus total (tidak ditampilkan, tidak
disimpan), jadi hasil pembuatan akun selalu sampai utuh ke bot. Bot juga
menjalankan CLI dengan stdin `/dev/null` supaya tidak pernah menggantung.

atau langsung:

```bash
vps-manager --setup-bot --bot-token 123456:ABC-DEF --admin-chat-id 123456789
```

Lalu buka Telegram dan kirim `/start` ke bot kamu.

**Yang bisa dilakukan bot:**

| Tombol / perintah | Fungsi |
|---|---|
| Buat Akun (`/create`) | Buat SSH/VMess/VLESS/Trojan (tanya protokol → nama → hari) |
| List Akun (`/list`) | Daftar semua akun + status expired |
| Link Akun (`/show`) | Tampilkan link/config akun |
| Hapus Akun (`/delete`) | Hapus akun (minta konfirmasi dulu) |
| Perpanjang (`/renew`) | Tambah masa aktif akun |
| Status VPS (`/status`) | Cek Nginx, Xray, dan path WS |

Catatan:

- Password SSH/Trojan yang dibuat dari bot diacak otomatis dan ditampilkan
  sekali di chat — simpan saat itu juga (tidak disimpan di server).
- Token dan Chat ID tersimpan di `/etc/vps-manager/bot.conf` (mode 600).
- Bot jalan sebagai service `vps-bot` (`/opt/vps-bot/bot.py`, Python stdlib
  saja, long polling — tanpa dependensi tambahan). Cek dengan
  `systemctl status vps-bot`.
- Menu 11 juga bisa Restart / Stop / Hapus bot. Uninstall bersih (menu 10)
  ikut menghapus bot.

## Contoh output link

**VMess** (menu 9) — link `vmess://` (JSON base64):

```
================= LINK VMESS: user1 =================
vmess://eyJ2IjoiMiIsInBzIjoidXNlcjEiLCJhZGQiOiJ2cG4uZG9tYWlua2FtdS5jb20iLCJwb3J0IjoiNDQzIiwiaWQiOiIxMjM0NTY3OC05YWJjLTRkZWYtOTAxMi0zNDU2Nzg5YWJjZGUiLCJhaWQiOiIwIiwibmV0Ijoid3MiLCJ0eXBlIjoibm9uZSIsImhvc3QiOiJ2cG4uZG9tYWlua2FtdS5jb20iLCJwYXRoIjoiL3ZtZXNzIiwidGxzIjoidGxzIiwic25pIjoidnBuLmRvbWFpbmthbXUuY29tIn0=
```

**VLESS (mode domain, WS+TLS):**

```
vless://12345678-9abc-4def-9012-3456789abcde@vpn.domainkamu.com:443?encryption=none&security=tls&type=ws&host=vpn.domainkamu.com&path=/vless#user1
```

Setiap akun menampilkan **dua link** (menu 9): TLS port 443 dan non-TLS port 80,
misalnya VLESS non-TLS:

```
vless://12345678-9abc-4def-9012-3456789abcde@vpn.domainkamu.com:80?encryption=none&security=none&type=ws&host=vpn.domainkamu.com&path=/vless#user1-nontls
```

**VLESS (mode REALITY):**

```
vless://12345678-9abc-4def-9012-3456789abcde@1.2.3.4:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBLIK_KEY_DISINI&sid=a1b2c3d4e5f60708&type=tcp#user1
```

**Trojan (mode domain, WS+TLS):**

```
trojan://PasswordKuat20Karakter@vpn.domainkamu.com:443?security=tls&type=ws&host=vpn.domainkamu.com&path=/trojan#user1
```

Import link ke **v2rayNG**, NekoBox, Streisand, atau FoXray (salin
link-nya saja — QR code tidak ditampilkan).

> Contoh di atas memakai nilai ilustrasi (UUID/password/domain diganti) —
> link asli dibuat dari akunmu sendiri.

## Cara uji

```bash
# 1. Status service
systemctl status xray
systemctl status nginx

# 2. Validasi config
xray -test -config /usr/local/etc/xray/config.json
nginx -t

# 3. Port yang harus LISTEN (atau cukup: vps-manager --check)
ss -tlnp | grep -E ':(22|80|443|10001|10002|10003|10090)\b'
vps-manager --check   # cek rantai Nginx -> Xray -> path WS (80 & 443)

# 4. Import link di v2rayNG — harus konek, lalu cek IP berubah
# 5. Cek expiry
bash vps-manager.sh --list

# 6. Lihat log bila ada yang aneh
tail -n 50 /var/log/vps-manager.log
journalctl -u xray -n 50 --no-pager
```

## Troubleshooting

| Gejala | Penyebab umum & perbaikan |
|---|---|
| Sertifikat gagal terbit | Domain belum resolve ke IP VPS (`getent hosts domainkamu` harus = IP VPS), atau port 80 diblokir/dipakai. Perbaiki DNS, tunggu propagasi, ulangi menu 1. Log: `/tmp/acme-issue.log`. |
| Port 80/443 bentrok | Proses lain memakai port itu (`ss -tlnp \| grep :443`). Sejak versi perbaikan 27 Nov 2026, script tidak lagi langsung gagal: ia menampilkan proses yang memegang port (mis. V2Ray/Nginx/HAProxy lama) dan menanyakan izin untuk menghentikannya sementara — layanan lama itu tetap berhenti karena Nginx baru butuh 80/443. Jawab `y` untuk lanjut, `n` untuk batal dan kembali ke menu. |
| Xray tidak start | Config tidak valid — script otomatis rollback ke backup terakhir. Cek manual: `xray -test -config /usr/local/etc/xray/config.json` dan `journalctl -u xray -n 50`. Backup ada di `/etc/vps-manager/backups/`. |
| Akun dibuat tapi tidak konek | Pastikan mode & transport cocok (WS butuh domain+TLS; REALITY butuh SNI `www.microsoft.com` & `flow=xtls-rprx-vision`). Cek akun masih `active` di `--list`, bukan `expired`. |
| Lupa password SSH akun | Password SSH tidak disimpan di server (sengaja). Reset manual: `passwd <nama-user>` sebagai root, lalu perpanjang bila perlu. |
| Domain belum resolve | `curl https://api.ipify.org` untuk IP VPS, lalu samakan A record domain dengan IP itu. Installer memberi peringatan bila tidak cocok. |
| SSH terkunci | Script tidak pernah mengubah port 22 dan UFW selalu allow 22 dulu sebelum enable. Bila tetap terkunci, akses via console provider VPS. |

## Uninstall bersih

Menu **10) Uninstall bersih** (atau `bash vps-manager.sh --uninstall`) — ketik
`YA` untuk konfirmasi. Yang dihapus: service & config Xray, config Nginx,
state akun, cron, dan user SSH yang tercatat di `state.json`. Yang **tidak
pernah** dihapus: OpenSSH port 22, user root, user sistem (UID < 1000).

## Asumsi

- VPS fresh install, root, internet lancar, dan port 22/80/443 bisa dibuka.
- Satu port = satu inbound Xray: di mode REALITY, port 443 hanya untuk VLESS;
  VMess di mode itu lewat WS port 10001 tanpa TLS (port dibuka di UFW).
- `flow=xtls-rprx-vision` hanya dipakai VLESS transport TCP/REALITY; VLESS WS
  tidak memakai flow.
- Limit IP dicatat di `state.json` saja — Xray tidak punya penegakan limit IP
  bawaan, jadi angka itu bukan pembatasan aktif (ditulis jujur di script).
- SSH over WebSocket (`/ssh-ws` di Nginx): Nginx sendiri tidak menerjemahkan
  frame WebSocket menjadi TCP mentah SSH — klien SSH-WS butuh jembatan WS→TCP
  (mis. ws-epro). SSH normal port 22 selalu tersedia dan itulah jalur utama.
- Zona waktu log: Asia/Jakarta.

## Keamanan

- `set -Eeuo pipefail` + trap error yang menulis ke log.
- Validasi input ketat (username, UUID v4, domain, email, hari 1–365, port).
- `state.json` chmod 600, ditulis atomik (file tmp + `mv`).
- Backup config + state sebelum setiap perubahan; validasi `xray -test`
  sebelum reload; rollback otomatis bila gagal.
- UFW: allow 22, 80, 443 (dan 10001 di mode reality) — allow 22 selalu dulu.
- Semua aksi destruktif minta konfirmasi ketik `YA`.
- Tanpa `eval`, tanpa interpolasi shell mentah, tanpa kredensial hardcode.
- Audit: semua aksi tercatat di `/var/log/vps-manager.log`.
