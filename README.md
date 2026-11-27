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
  (standalone, EC-256). **HAProxy memegang port 80 dan 443** (pola
  WibuTunnel): ia mendeteksi protokol dari payload pertama koneksi —
  `SSH-` diteruskan ke OpenSSH 22 (SSH mentah jalan di 80 & 443!),
  path Xray diteruskan ke hub internal, sisanya ke Nginx. Nginx kini
  hanya melayani dari localhost:18080 (tanpa TLS). VMess/VLESS/Trojan/SSH
  tetap di **dua port**: **80 non-TLS** dan **443 TLS**, dengan path tetap
  `/vmess`, `/vless`, `/trojan`, dan `/ssh-ws` (SSH WS via jembatan
  ws-epro ke SSH 22).
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
curl -fsSL https://<domain-kamu>/vps-manager.sh -o /tmp/vps-manager.sh && bash -n /tmp/vps-manager.sh && cp /tmp/vps-manager.sh /usr/local/bin/vps-manager && chmod +x /usr/local/bin/vps-manager && vps-manager
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
  01) Install / Update         08) Perpanjang Akun
  02) Buat Akun SSH            09) Link Akun
  03) Buat Akun VMess          10) Uninstall Bersih
  04) Buat Akun VLESS          11) Bot Telegram
  05) Buat Akun Trojan         12) Features
  06) List Semua Akun          13) Buat Akun Shadowsocks
  07) Hapus Akun               00) Keluar
```

Tampilan di atas adalah versi baru yang rapi seperti screenshot referensi:
info server (OS/RAM/SWAP/CITY/ISP/IP/DOMAIN/UPTIME), traffic MONTH/DAY +
kecepatan saat ini, baris status XRAY/SSH-WS/NGINX/BOT, dan menu 2 kolom.

Kota/ISP diambil sekali dari ipinfo.io lalu disimpan di state (tidak
menghambat menu berikutnya). Traffic MONTH/DAY dibaca dari `vnstat` bila
terpasang (`apt install vnstat`); bila belum, tampil total sejak boot.

## Akun Trial (30 menit / 1 jam)

Menu **Buat Akun SSH / VMess / VLESS / Trojan / Shadowsocks** (2, 3, 4, 5, 13)
kini membuka submenu:

```
================= BUAT AKUN VMess =================
  1) Buat Akun (masa aktif hari)
  2) Trial 30 menit
  3) Trial 1 jam
  0) Kembali
```

Trial membuat akun sekali pakai bernama `trial-xxxxxx` (acak, tanpa perlu
isi nama/hari/password) dan langsung menampilkan link-nya, sama seperti
akun biasa. Akun trial **dihapus otomatis** begitu waktunya habis — cron
tiap 5 menit (`--check-trials`) menghapusnya dari state + config Xray, dan
untuk SSH user Linux-nya ikut dihapus. Di menu 6 (List) akun trial ditandai
`(TRIAL, sisa 25 mnt)`. Bila trial diperpanjang di menu 8, ia berubah jadi
akun biasa (penanda trial hilang).

## Link akun: format CEK AKUN, salin otomatis

Menu 9 (Link Akun) dan hasil buat akun menampilkan akun dalam format
CEK AKUN yang simpel (VMess / VLESS / Trojan / Shadowsocks / SSH):

```
VMESS - CEK AKUN
----------------------------------------
Remarks    : lut
Domain     : sg1.roodyzain.web.id
ISP        : Tencent Cloud
City       : Singapore
Expired On : 2026-12-27
----------------------------------------
CONFIG DETAILS
Port TLS   : 443
Port NTLS  : 80
UUID       : a3d57954-969b-4e62-b7e3-fcf5018f537a
AlterId    : 0
Security   : auto
Network    : ws, grpc
Path WS    : /vmess
Serv.Name  : vmess-grpc
----------------------------------------
LINK VMESS WS TLS
vmess://...

(Link di atas sudah disalin ke clipboard — tinggal paste di aplikasi VPN.)

LINK VMESS WS NO TLS
vmess://...

LINK VMESS GRPC
vmess://...
----------------------------------------
```

Hasil buat/lihat akun **hanya menampilkan blok CEK AKUN** — tanpa baris
`[OK]`, tanpa baris log ber-timestamp, tanpa "OS terdeteksi". Semua
kemajuan proses tetap dicatat ke file log `/var/log/vps-manager.log`
(saja, tidak ikut tampil di terminal), dan bila ada yang gagal, pesan
error tetap tampil. Perintah lain (menu, list, check, install) tetap
menampilkan baris `[OK]` seperti biasa.

Link **WS TLS otomatis disalin ke clipboard** lewat OSC 52 begitu
ditampilkan — di Termius tinggal paste di v2rayNG / NekoBox / Streisand /
FoXray, tanpa perlu menandai teks panjangnya. (Bila belum tersalin,
aktifkan OSC 52 di Termius: Settings → Terminal → Sequences → OSC 52.)
Link NO TLS dan GRPC tetap bisa disalin manual dengan tekan lama. Saat
output ditangkap program lain (mis. bot Telegram), tidak ada escape
sequence yang ikut terkirim — pesan bot tetap bersih. Untuk akun trial,
"Expired On" menampilkan tanggal + jam habisnya.

**Akun SSH hanya menampilkan config SSH WebSocket untuk HTTP Custom
— SSH mentah (port 22) tidak ditampilkan.** Hasil akun SSH (buat +
lihat) hanya berisi:

```
SSH - CEK AKUN
----------------------------------------
Remarks    : saya
Domain     : sg1.roodyzain.web.id
ISP        : ...
City       : ...
Expired On : ...
----------------------------------------
CONFIG HTTP CUSTOM
SSH WEBSOCKET : sg1.roodyzain.web.id:80@saya:saya
SSH SSL       : sg1.roodyzain.web.id:443@saya:saya
----------------------------------------
```

Format setting-nya `host:port@name:password`, **tanpa path**. Di HTTP
Custom: **SSH WEBSOCKET pakai port 80** (non-TLS), **SSH SSL pakai
port 443** (TLS/SNI). Saat buat akun maupun lihat akun (menu 9),
password tampil di setting itu sebagai `host:port@name:password`
(password SSH disimpan di `/etc/vps-manager/state.json`, mode 600,
hanya root yang bisa baca). Akun SSH lama (dibuat sebelum password
disimpan) tetap tampil sebagai `host:port@name` saja. Jalurnya sudah
disiapkan script: Nginx meneruskan handshake WebSocket di root `/`
(tanpa path) **dan** di `/ssh-ws` — di port 80 maupun 443 — ke
jembatan ws-epro (`127.0.0.1:10090`) → SSH port 22. HTTP biasa di
root tetap 200 OK di kedua port. **SSH mentah kini juga jalan di
port 80 dan 443** (HAProxy mendeteksi `SSH-` dan meneruskan ke
OpenSSH 22), jadi `ssh -p 80 user@domain` dan `ssh -p 443 user@domain`
bisa dipakai dari terminal — tidak hanya port 22. Cek dengan
`vps-manager --check` (ada baris "SSH mentah port 80/443").

**Bot Telegram menampilkan format yang sama.** Karena bot menjalankan
CLI yang sama, hasil buat akun / link akun di bot juga format CEK AKUN.
Bedanya, bot membungkus hasil CLI dalam blok monospace (`<pre>`) supaya
kolomnya tetap sejajar — font Telegram biasa proporsional, jadi tanpa
blok itu kolom Remarks / Port / UUID jadi tidak rapi. Prompt dan pesan
konfirmasi bot tetap teks biasa.

## Features (menu 12)

Submenu perbaikan dan utilitas, seperti menu FEATURES di screenshot
referensi — 28 item dalam 5 bagian:

```
FEATURES
  1.) Running Service          (29 layanan seperti layar ARISCTUNNEL: SSH/TUN,
                                SSH UDP-HC, OpenVPN, OHP, WS ePRO, BadVPN,
                                Dropbear, Haproxy, Crons, Nginx, Xray
                                Vmess/Vless/Trojan/Shadowsocks WS TLS/Non
                                TLS/gRPC; dicek via systemctl + ss + config
                                Xray, tanpa error ps; bila ada yang OFF,
                                ditawari langsung "Perbaiki semua yang OFF
                                sekarang? [y/N]" — sama dengan item 27)
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
                                lalu restart; multiport seperti ARISCTUNNEL:
                                55, 8080, 8880, 2082, 2086, 2095, 222-442 +
                                444-1000 HTTP + 9444 TLS; 80/443 tetap milik
                                Nginx — rentang dibelah karena 443 ada di
                                dalam 222-1000 dan dipegang Nginx, HAProxy
                                yang coba bind 443 gagal total dan tetap OFF)
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
 27.) Fixx Semua Service OFF   (perbaiki semua yang OFF di Running Service
                                sekaligus, kelompok per kelompok: SSH UDP-HC
                                + BadVPN (forwarder UDP 7100/7200/7300 ->
                                SSH 22, dibuat sendiri di script ini),
                                OHP (HTTP tunnel SSH 8181 -> SSH 22,
                                Dropbear 8282 -> Dropbear 109, dan OpenVPN
                                8383 -> OpenVPN SSL 1195, dibuat sendiri),
                                WS ePRO, Dropbear (109/143),
                                Haproxy (multiport), Crons, Nginx, Xray
                                (bangun ulang config termasuk inbound gRPC +
                                Shadowsocks baru, lalu restart), OpenVPN
                                WS-SSL + SSL + UDP (install server +
                                jembatan WS bila OFF, lihat item 28).
                                Yang sudah ON dilewati.
 28.) Install OpenVPN WS-SSL   (install server OpenVPN + PKI openssl +
                                jembatan WebSocket ws-ovpn 127.0.0.1:10091
                                + Nginx location /ovpn (80 + 443) + NAT;
                                tiga instance: WS-SSL (TCP 1194, tun
                                10.9.0.0/24), SSL langsung (TCP 1195,
                                tun 10.10.0.0/24 — service "OpenVPN SSL"),
                                dan UDP (UDP 1194, tun 10.11.0.0/24 —
                                service "OpenVPN UDP"; TCP dan UDP 1194
                                tidak bentrok). Lalu buat akun klien contoh
                                "ovpn" 30 hari. Service "OpenVPN WS-SSL",
                                "OpenVPN SSL", "OpenVPN UDP", dan "OHP
                                OpenVPN" (8383 -> OpenVPN SSL 1195) di
                                Running Service jadi ON. Buat akun lain:
                                `vps-manager --create ovpn --name <nama>
                                --days 30` — file .ovpn di
                                /root/ovpn-<nama>.ovpn, remote 443 (WS-SSL,
                                butuh klien WebSocket) + 1194 TCP
                                (WS-SSL, klien standar) + 1195 TCP (SSL
                                langsung) + 1194 UDP (klien standar).
                                Hapus: menu 7 — sertifikat di-revoke +
                                CRL diperbarui.)
  x . EXIT
```

Catatan jujur: item 9 di screenshot aslinya "Change Domain NS" (untuk
SlowDNS) — script ini tidak memakai SlowDNS, jadi item itu diganti Change
DNS Server (resolver). Item 10 Fixx Haproxy memasang HAProxy multiport
(port 55, 8080, 8880, 2082, 2086, 2095 + rentang 222-1000, sama seperti
HAProxy ARISCTUNNEL) dengan backend ke Xray/ws-epro/Nginx; **sejak
27 Nov 2026 HAProxy juga memegang port 80/443** (SSH mentah + WS,
pola WibuTunnel) dan Nginx pindah ke localhost:18080, jadi link lama
tidak berubah. Rentang ditulis 222-442 + 444-1000 (bukan 222-1000),
karena 443 ada di dalam rentang itu dan kini dipegang frontend 443
HAProxy sendiri — frontend multiport yang mencoba bind 443 akan gagal
start total ("cannot bind socket", exit 1). Bila HAProxy gagal start
karena port lain bentrok (mis. 8080 dipegang V2Ray lama), Fixx Haproxy
menampilkan port + pemegangnya, menanyakan izin membebaskannya, lalu
mencoba lagi (maks. 3x).

## Perintah non-interaktif (otomasi)

```bash
# Install
bash vps-manager.sh --install --mode domain --domain vpn.domainkamu.com --email admin@domainkamu.com
bash vps-manager.sh --install --mode reality

# Buat akun
# Password SSH WAJIB diisi manual (tidak dibuat otomatis): di menu akan
# ditanya sampai diisi (minimal 1 karakter); di bot ditanyakan juga;
# non-interaktif tanpa --password akan ditolak.
bash vps-manager.sh --create ssh    --name user1 --days 30 --password Rahasia123
bash vps-manager.sh --create vmess  --name user1 --days 30 --limit-ip 2
bash vps-manager.sh --create vless  --name user1 --days 30 --transport ws
bash vps-manager.sh --create trojan --name user1 --days 30
bash vps-manager.sh --create ss     --name user1 --days 30 --password Rahasia123
bash vps-manager.sh --create ovpn   --name user1 --days 30
# (ovpn: file .ovpn di /root/ovpn-user1.ovpn; remote 443 WS-SSL + 1194 TCP)

# Akun trial (30/60 menit, nama acak trial-xxxxxx, dihapus otomatis bila habis)
bash vps-manager.sh --trial vmess --minutes 30
bash vps-manager.sh --trial ssh --minutes 60
bash vps-manager.sh --check-trials

# Lihat / hapus / perpanjang / tampilkan link
bash vps-manager.sh --list
bash vps-manager.sh --delete --protocol vmess --name user1 [--yes]
# Menu 7 (interaktif): tampilkan daftar akun bernomor — tinggal tekan nomornya, lalu ketik YA. Akun diurutkan berdasarkan tanggal expired (paling cepat habis di atas).
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

Diagnosa (menu 11 > 05) sekarang juga memeriksa **versi file bot & script**
(langkah 0 — file bot hanya diperbarui saat instal ulang, jadi kalau kamu
hanya update script, botnya masih versi lama), **proses bot ganda**
(dua bot berebut pesan Telegram), dan bisa menjalankan **tes buat akun**
(langkah 6 — membuat akun VMess `bottest` 1 hari lewat jalur yang sama
persis seperti bot, lalu menghapusnya lagi). Kalau tes itu berhasil tapi
bot tetap diam, masalahnya ada di bot; kalau tes itu gagal, penyebabnya
tampil di situ (biasanya Xray gagal start).

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
ss -tlnp | grep -E ':(22|80|443|10001|10002|10003|10004|10005|10006|10007|10008|10090|8181|8282)\b'
ss -uln | grep -E ':(7100|7200|7300)\b'   # UDP forwarder (BadVPN)
vps-manager --check   # cek rantai Nginx -> Xray -> path WS (80 & 443)

# Inbound Xray (localhost, di belakang Nginx):
#   10001 VMess WS /vmess | 10002 VLESS WS /vless | 10003 Trojan WS /trojan
#   10004 VLESS gRPC (vless-grpc) | 10005 VMess gRPC (vmess-grpc)
#   10006 Trojan gRPC (trojan-grpc) | 10007 Shadowsocks WS /ss
#   10008 Shadowsocks gRPC (ss-grpc) | 10085 Stats API
#   10090 ws-epro (SSH WS /ssh-ws) | 8181 OHP SSH -> SSH 22
#   8282 OHP Dropbear -> Dropbear 109 | 8383 OHP OpenVPN -> OpenVPN SSL 1195
#   UDP 7100/7200/7300 -> SSH 22
# Shadowsocks: menu 13 atau --create ss; link TLS (443) + Non-TLS (80) +
# gRPC (443), plugin v2ray-plugin, method aes-256-gcm. Bot Telegram juga
# punya tombol Shadowsocks (install ulang bot via menu 11 > 01 dulu).

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
| Port 80/443 bentrok | Proses lain memakai port itu (`ss -tlnp \| grep :443`). Sejak 27 Nov 2026 port 80/443 dipegang **HAProxy** (bukan Nginx). Saat install/update, script memindahkan Nginx lama ke port internal dulu sebelum HAProxy bind 80/443. Bila masih bentrok (mis. V2Ray lama), script menampilkan proses pemegangnya dan menanyakan izin menghentikannya sementara. Jawab `y` untuk lanjut, `n` untuk batal dan kembali ke menu. |
| Xray tidak start | Config tidak valid — script otomatis rollback ke backup terakhir. Cek manual: `xray -test -config /usr/local/etc/xray/config.json` dan `journalctl -u xray -n 50`. Backup ada di `/etc/vps-manager/backups/`. |
| Akun dibuat tapi tidak konek | Pastikan mode & transport cocok (WS butuh domain+TLS; REALITY butuh SNI `www.microsoft.com` & `flow=xtls-rprx-vision`). Cek akun masih `active` di `--list`, bukan `expired`. |
| Lupa password SSH akun | Password SSH tidak disimpan di server (sengaja). Reset manual: `passwd <nama-user>` sebagai root, lalu perpanjang bila perlu. |
| Domain belum resolve | `curl https://api.ipify.org` untuk IP VPS, lalu samakan A record domain dengan IP itu. Installer memberi peringatan bila tidak cocok. |
| SSH terkunci | Script tidak pernah mengubah port 22 dan UFW selalu allow 22 dulu sebelum enable. Bila tetap terkunci, akses via console provider VPS. |
| Running Service banyak OFF padahal layanan jalan | Dua penyebab: (1) layanan memang belum terpasang — perbaiki via menu 12 → 27 (Fixx Semua Service OFF); (2) bug cek port di versi lama: `ss \| grep -q` di bawah `set -o pipefail` bisa mati kena SIGPIPE (grep keluar duluan, ss exit 141) sehingga port yang LISTEN dilaporkan OFF secara acak. Sejak 27 Nov 2026, semua cek menangkap output `ss` dulu baru grep — hasil Running Service kini stabil. Bila masih ada yang OFF, itu memang belum terpasang (OHP dan UDP-HC/BadVPN sudah dipasang sejak 27 Nov 2026 — OHP SSH 8181, OHP Dropbear 8282, OHP OpenVPN 8383, UDP 7100/7200/7300 — dan diperbaiki via menu 12 → 27). |

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
