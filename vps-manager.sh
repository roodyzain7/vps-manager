#!/usr/bin/env bash
# =============================================================================
# vps-manager.sh — Pengelola akun SSH, VMess, VLESS, dan Trojan di VPS Linux
# Menggunakan Xray-core resmi. Untuk administrasi server sendiri (legal).
#
# Cara pakai:
#   Menu interaktif : bash vps-manager.sh
#   Non-interaktif  : bash vps-manager.sh --install --mode domain \
#                       --domain contoh.com --email admin@contoh.com
#                     bash vps-manager.sh --create vmess --name user1 --days 30
#
# File penting:
#   State akun      : /etc/vps-manager/state.json (chmod 600)
#   Config Xray     : /usr/local/etc/xray/config.json
#   Config Nginx    : /etc/nginx/conf.d/vps-manager.conf
#   Sertifikat      : /etc/vps-manager/ssl/
#   Log             : /var/log/vps-manager.log
#   Cron expired    : /etc/cron.d/vps-manager
#
# Keamanan:
#   - Port SSH default (22) TIDAK diubah. UFW selalu allow 22 dulu sebelum enable.
#   - Password SSH TIDAK disimpan di state.json (hanya hash di sistem Linux).
#   - Password Trojan & UUID disimpan di state.json (chmod 600) karena Xray
#     butuh nilai itu untuk berjalan — itu sudah sewajarnya, bukan kebocoran.
#   - Semua command sistem dijalankan tanpa shell dan tanpa eval; argumen
#     dilewatkan sebagai array, dan input user divalidasi dulu dengan regex.
#   - TIDAK ADA fitur payload / bug-host / pengelabuan operator di sini.
# =============================================================================

set -Eeuo pipefail

# -----------------------------------------------------------------------------
# Konstanta & global
# -----------------------------------------------------------------------------
readonly SCRIPT_NAME="vps-manager"
readonly STATE_DIR="/etc/vps-manager"
readonly STATE_FILE="${STATE_DIR}/state.json"
readonly BACKUP_DIR="${STATE_DIR}/backups"
readonly SSL_DIR="${STATE_DIR}/ssl"
readonly LOG_FILE="/var/log/vps-manager.log"
readonly XRAY_CONFIG="/usr/local/etc/xray/config.json"
readonly XRAY_BIN="/usr/local/bin/xray"
readonly NGINX_CONF="/etc/nginx/conf.d/vps-manager.conf"
readonly CRON_FILE="/etc/cron.d/vps-manager"
readonly INSTALL_BIN="/usr/local/bin/vps-manager"
readonly BOT_DIR="/opt/vps-bot"
readonly BOT_CONF="/etc/vps-manager/bot.conf"
readonly BOT_UNIT="/etc/systemd/system/vps-bot.service"
# FORCE=1 bila dipanggil dengan --yes: lewati konfirmasi destruktif (dipakai bot
# Telegram untuk hapus akun; tanpa ini `vps-manager --delete` menggantung
# menunggu ketikan YA di terminal yang tidak ada).
FORCE=0

# Port Xray (localhost, di belakang Nginx pada mode domain)
readonly PORT_VMESS_WS=10001
readonly PORT_VLESS_WS=10002
readonly PORT_TROJAN_WS=10003
readonly PORT_VLESS_GRPC=10004
readonly PORT_VMESS_GRPC=10005
readonly PORT_TROJAN_GRPC=10006
readonly PORT_SS_WS=10007
readonly PORT_SS_GRPC=10008
readonly PORT_XRAY_API=10085

# Warna terminal
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_CYAN='\033[0;36m'
readonly C_MAGENTA='\033[1;35m'
readonly C_BLUE='\033[0;34m'
readonly C_BOLD='\033[1m'
readonly C_BG_BLUE='\033[44m'

# -----------------------------------------------------------------------------
# Log — selalu ke stdout DAN file log (timestamp Asia/Jakarta)
# -----------------------------------------------------------------------------
log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts=$(TZ=Asia/Jakarta date '+%Y-%m-%d %H:%M:%S %Z')
    printf '%s [%s] %s\n' "$ts" "$level" "$msg" | tee -a "$LOG_FILE"
}

info()  { log "INFO" "$@" >&2; printf '%b\n' "${C_GREEN}[OK]${C_RESET} $*"; }
warn()  { log "WARN" "$@" >&2; printf '%b\n' "${C_YELLOW}[!]${C_RESET} $*"; }
error() { log "ERROR" "$@" >&2; printf '%b\n' "${C_RED}[X]${C_RESET} $*" >&2; }

# Trap error: catat baris & perintah yang gagal, lalu keluar dengan pesan jelas.
trap 'error "Script gagal di baris ${LINENO} (perintah: ${BASH_COMMAND}). Lihat ${LOG_FILE}."' ERR

# -----------------------------------------------------------------------------
# Cek dasar
# -----------------------------------------------------------------------------
require_root() {
    if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
        error "Script ini harus dijalankan sebagai root (sudo / root via SSH)."
        exit 1
    fi
}

check_os() {
    # Target: Ubuntu 22.04/24.04 atau Debian 12. Distro lain: peringatan, lanjut.
    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        case "${ID:-}-${VERSION_ID:-}" in
            ubuntu-22.04|ubuntu-24.04|debian-12) info "OS terdeteksi: ${PRETTY_NAME:-$ID $VERSION_ID}" ;;
            *) warn "OS ${PRETTY_NAME:-tidak dikenal} belum teruji — lanjut dengan risiko sendiri." ;;
        esac
    else
        warn "File /etc/os-release tidak ditemukan — tidak bisa memastikan OS."
    fi
}

# Perbaiki DNS VPS sebelum apt (VPS cloud seperti Tencent sering gagal resolve
# mirror bawaannya, mis. mirrors.tencentyun.com — persis penyebab install gagal
# di v1.1.1 dulu). Tidak merusak apa pun bila DNS sudah sehat.
fix_dns() {
    if getent hosts archive.ubuntu.com >/dev/null 2>&1 || getent hosts deb.debian.org >/dev/null 2>&1; then
        return 0
    fi
    warn "DNS VPS bermasalah — memperbaiki /etc/resolv.conf (1.1.1.1, 8.8.8.8)."
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf || true
    # Mirror Ubuntu Tencent yang mati -> archive.ubuntu.com
    if [[ -f /etc/apt/sources.list ]] && grep -q "mirrors.tencentyun.com" /etc/apt/sources.list 2>/dev/null; then
        sed -i 's|mirrors.tencentyun.com|archive.ubuntu.com|g' /etc/apt/sources.list || true
    fi
    if [[ -d /etc/apt/sources.list.d ]]; then
        grep -rl "mirrors.tencentyun.com" /etc/apt/sources.list.d/ 2>/dev/null | while read -r f; do
            sed -i 's|mirrors.tencentyun.com|archive.ubuntu.com|g' "$f" || true
        done
    fi
}

# Pastikan jq ADA sebelum apa pun yang membaca state.json dipanggil.
# BUG yang dilaporkan user: menu langsung memanggil state_get (pakai jq) padahal
# jq baru di-install di menu 1 — script mati di baris 219 sebelum menu tampil.
# Fungsi ini dipanggil di awal main(), jadi menu tidak pernah lagi mati karena jq.
ensure_jq() {
    if command -v jq >/dev/null 2>&1; then
        return 0
    fi
    warn "jq belum terinstall — menginstall jq dulu (dibutuhkan untuk membaca state.json)."
    fix_dns
    export DEBIAN_FRONTEND=noninteractive
    if timeout 120 apt-get update -qq 2>/dev/null && timeout 300 apt-get install -y -qq jq 2>/dev/null && command -v jq >/dev/null 2>&1; then
        info "jq berhasil diinstall via apt."
        return 0
    fi
    # Fallback terakhir bila apt gagal/mirror mati: binary statis jq dari GitHub.
    warn "apt gagal install jq — mencoba binary statis dari GitHub."
    if command -v curl >/dev/null 2>&1 && curl -fsSL --max-time 60 \
        https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-linux64 \
        -o /usr/local/bin/jq 2>/dev/null; then
        chmod +x /usr/local/bin/jq
        if command -v jq >/dev/null 2>&1; then
            info "jq berhasil diinstall via binary GitHub."
            return 0
        fi
    fi
    error "jq TIDAK bisa diinstall otomatis. Jalankan manual: apt-get update && apt-get install -y jq"
    error "Lalu jalankan lagi: vps-manager"
    return 1
}

check_deps() {
    # Daftar dependensi wajib. Yang kurang di-install via apt (non-interaktif).
    local deps=(curl jq uuid-runtime openssl nginx socat ufw python3 procps iproute2)
    local missing=()
    local dep
    for dep in "${deps[@]}"; do
        if ! dpkg -s "$dep" >/dev/null 2>&1; then
            missing+=("$dep")
        fi
    done
    # Perintah yang tidak terikat paket dpkg (ss, xray dicek terpisah)
    command -v ss >/dev/null 2>&1 || missing+=(iproute2)
    if ((${#missing[@]} > 0)); then
        info "Menginstall dependensi yang kurang: ${missing[*]}"
        fix_dns
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq || { warn "apt-get update gagal — coba lagi setelah fix DNS."; apt-get update -qq || true; }
        apt-get install -y -qq "${missing[@]}"
    fi
    info "Semua dependensi tersedia."
}

# -----------------------------------------------------------------------------
# Validasi input (ketat — semua input user lewat sini)
# -----------------------------------------------------------------------------
valid_username() { [[ "$1" =~ ^[a-z_][a-z0-9_-]{2,31}$ ]]; }
valid_domain()   { [[ "$1" =~ ^[a-zA-Z0-9]([a-zA-Z0-9.-]{0,61}[a-zA-Z0-9])?\.[a-zA-Z]{2,}$ ]]; }
valid_email()    { [[ "$1" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; }
valid_days()     { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 365 )); }
valid_port()     { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
valid_uuid()     { [[ "$1" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$ ]]; }

# Baca input dengan validasi. $1=prompt, $2=fungsi validasi, $3=pesan error, $4=boleh kosong?
read_validated() {
    local prompt="$1" validator="$2" errmsg="$3" allow_empty="${4:-0}" value=""
    while true; do
        read -r -p "$prompt" value
        value="$(printf '%s' "$value" | tr -d '[:space:]')"
        if [[ -z "$value" && "$allow_empty" == "1" ]]; then
            printf '%s' ""
            return 0
        fi
        if "$validator" "$value"; then
            printf '%s' "$value"
            return 0
        fi
        error "$errmsg"
    done
}

# Konfirmasi aksi destruktif: user harus mengetik YA (huruf besar).
confirm_destructive() {
    local pesan="$1" jawab=""
    if (( FORCE == 1 )); then
        log "INFO" "Konfirmasi dilewati (--yes): ${pesan}"
        return 0
    fi
    printf '%b\n' "${C_RED}${pesan}${C_RESET}"
    read -r -p "Ketik YA untuk lanjut, selain itu batal: " jawab
    [[ "$jawab" == "YA" ]]
}

# -----------------------------------------------------------------------------
# State JSON (/etc/vps-manager/state.json, chmod 600, tulis atomik)
# Struktur:
#   {
#     "install": {
#       "mode": "domain" | "reality" | "",
#       "domain": "", "email": "",
#       "ws_paths": {"vmess": "/vmess-xxxx", "vless": "/vless-xxxx", "trojan": "/trojan-xxxx"},
#       "reality": {"private_key": "", "public_key": "", "short_id": "", "dest": "www.microsoft.com", "sni": "www.microsoft.com"},
#       "installed_at": "2026-11-27T02:00:00+07:00"
#     },
#     "accounts": [
#       {"protocol": "ssh|vmess|vless|trojan|ss", "name": "", "uuid": "", "password": "",
#        "expiry": "2026-12-27", "limit_ip": null, "flow": "", "transport": "ws|tcp",
#        "status": "active|expired|locked", "created_at": "2026-11-27"}
#     ]
#   }
# Catatan: password akun SSH TIDAK disimpan di sini (hanya di sistem Linux).
# Password Trojan & UUID memang harus disimpan agar Xray bisa membacanya.
# -----------------------------------------------------------------------------
state_init() {
    mkdir -p "$STATE_DIR" "$BACKUP_DIR" "$SSL_DIR"
    chmod 700 "$STATE_DIR"
    if [[ ! -f "$STATE_FILE" ]]; then
        cat > "$STATE_FILE" <<'EOF'
{
  "install": {
    "mode": "",
    "domain": "",
    "email": "",
    "ws_paths": {"vmess": "", "vless": "", "trojan": ""},
    "reality": {"private_key": "", "public_key": "", "short_id": "", "dest": "www.microsoft.com", "sni": "www.microsoft.com"},
    "installed_at": ""
  },
  "accounts": []
}
EOF
        chmod 600 "$STATE_FILE"
        info "State baru dibuat: $STATE_FILE (chmod 600)"
    fi
    # Pastikan permission tetap 600 walau file sudah ada.
    chmod 600 "$STATE_FILE"
}

# Jalankan jq pada state.json dan tulis hasilnya secara atomik (tmp + mv).
# Pemakaian: jq_state <argumen-jq...>
jq_state() {
    local tmp="${STATE_FILE}.tmp"
    if ! jq "$@" "$STATE_FILE" > "$tmp"; then
        rm -f "$tmp"
        error "Gagal mengubah state.json (jq gagal)."
        return 1
    fi
    chmod 600 "$tmp"
    mv "$tmp" "$STATE_FILE"
}

state_get() { # $1 = ekspresi jq (mis. .install.mode)
    # Pengaman terakhir: bila jq entah kenapa hilang, install dulu, jangan mati.
    if ! command -v jq >/dev/null 2>&1; then
        ensure_jq || { echo ""; return 0; }
    fi
    jq -r "$1" "$STATE_FILE"
}

state_account_exists() { # $1=protocol $2=name -> 0 bila ada
    [[ "$(jq -r --arg p "$1" --arg n "$2" \
        '[.accounts[] | select(.protocol==$p and .name==$n)] | length' "$STATE_FILE")" -gt 0 ]]
}

state_add_account() { # $1 = objek JSON akun (sudah divalidasi jq)
    jq_state --argjson acc "$1" '.accounts += [$acc]'
}

state_del_account() { # $1=protocol $2=name
    jq_state --arg p "$1" --arg n "$2" \
        '.accounts |= map(select(.protocol!=$p or .name!=$n))'
}

state_set_field() { # $1=protocol $2=name $3=field $4=nilai (string)
    jq_state --arg p "$1" --arg n "$2" --arg f "$3" --arg v "$4" \
        '.accounts |= map(if .protocol==$p and .name==$n then .[$f]=$v else . end)'
}

# -----------------------------------------------------------------------------
# Backup & rollback config
# -----------------------------------------------------------------------------
backup_config() {
    local ts
    ts=$(date '+%Y%m%d-%H%M%S')
    mkdir -p "$BACKUP_DIR"
    [[ -f "$XRAY_CONFIG" ]] && cp -a "$XRAY_CONFIG" "${BACKUP_DIR}/config.json.${ts}"
    [[ -f "$STATE_FILE" ]] && cp -a "$STATE_FILE" "${BACKUP_DIR}/state.json.${ts}"
    [[ -f "$NGINX_CONF" ]] && cp -a "$NGINX_CONF" "${BACKUP_DIR}/vps-manager.conf.${ts}"
    # Simpan maksimal 10 backup terakhir per jenis, hapus yang lama.
    ls -t "${BACKUP_DIR}"/config.json.* 2>/dev/null | tail -n +11 | xargs -r rm -f
    ls -t "${BACKUP_DIR}"/state.json.* 2>/dev/null | tail -n +11 | xargs -r rm -f
    info "Backup tersimpan di ${BACKUP_DIR} (timestamp ${ts})"
}

rollback_config() {
    local last
    last=$(ls -t "${BACKUP_DIR}"/config.json.* 2>/dev/null | head -n 1 || true)
    if [[ -n "$last" && -f "$last" ]]; then
        cp -a "$last" "$XRAY_CONFIG"
        warn "Config Xray dikembalikan dari backup: $last"
        systemctl reload-or-restart xray || systemctl restart xray || true
    else
        error "Tidak ada backup config untuk rollback!"
    fi
}

# -----------------------------------------------------------------------------
# Cek port bentrok sebelum bind
# -----------------------------------------------------------------------------
check_port_free() { # $1=port $2=protokol(tcp/udp) — 0 bila bebas
    local port="$1" proto="${2:-tcp}" ss_out
    ss_out=$(ss -tlnp 2>/dev/null)
    if grep -qE ":${port}[[:space:]]" <<< "$ss_out"; then
        return 1
    fi
    return 0
}

check_port_or_die() { # $1=port $2=keterangan
    if ! check_port_free "$1"; then
        error "Port $1 ($2) sudah dipakai proses lain. Cek dengan: ss -tlnp | grep :$1"
        return 1
    fi
    return 0
}

# Siapa yang memegang port? Output: "nama-program/pid" atau kosong bila bebas.
port_holder() { # $1=port
    local line prog pid
    line=$(ss -tlnp 2>/dev/null | grep -E ":$1[[:space:]]" | head -n 1 || true)
    [[ -z "$line" ]] && return 0
    prog=$(printf '%s' "$line" | sed -nE 's/.*users:\(\("([^"]+)".*/\1/p')
    pid=$(printf '%s' "$line" | sed -nE 's/.*pid=([0-9]+).*/\1/p')
    printf '%s' "${prog:-tidak-dikenal}/${pid:-?}"
}

# Bebaskan port untuk ACME/Nginx dengan IZIN user (jangan hard-fail).
# Penyebab umum di VPS yang sudah pernah di-install VPN lain: V2Ray lama di
# port 80, Nginx lama, HAProxy, atau Xray lama di 443. Layanan lama itu HARUS
# berhenti — Nginx baru butuh 80/443 — jadi yang dihentikan TIDAK di-restart
# lagi setelah install (dijelaskan ke user). SSH (22) tidak pernah disentuh.
# $1=port $2=keterangan -> 0 bila port bebas (atau berhasil dibebaskan).
declare -a STOPPED_SERVICES=()
free_port_or_ask() {
    local port="$1" desc="$2" holder="" prog="" pid="" svc=""
    if check_port_free "$port"; then
        return 0
    fi
    holder=$(port_holder "$port")
    prog="${holder%%/*}"; pid="${holder##*/}"
    warn "Port ${port} (${desc}) sedang dipakai oleh: ${holder}."
    warn "Nginx baru butuh port ini. Layanan lama itu akan DIHENTIKAN (bukan dihapus)."
    local ans=""
    read -r -p "Hentikan ${prog} (pid ${pid}) sementara & lanjut install? [y/N]: " ans
    [[ "${ans:-}" =~ ^[Yy]$ ]] || { error "Instalasi dibatalkan oleh user (port ${port} masih dipakai)."; return 1; }
    case "$prog" in
        nginx|v2ray|xray|haproxy|apache2) svc="$prog" ;;
        *) svc="" ;;
    esac
    if [[ -n "$svc" ]] && systemctl is-active --quiet "$svc" 2>/dev/null; then
        systemctl stop "$svc" 2>/dev/null || true
        systemctl disable "$svc" 2>/dev/null || true
        STOPPED_SERVICES+=("$svc")
    elif [[ "$pid" =~ ^[0-9]+$ ]]; then
        kill "$pid" 2>/dev/null || true
        sleep 1
    fi
    sleep 1
    if check_port_free "$port"; then
        info "Port ${port} sudah bebas (yang memegang tadi: ${holder})."
        return 0
    fi
    error "Port ${port} masih dipakai setelah mencoba menghentikan ${holder}. Cek manual: ss -tlnp | grep :${port}"
    return 1
}

# -----------------------------------------------------------------------------
# Bangun config Xray dari state.json (dengan jq — tanpa interpolasi string mentah)
# Aturan:
#   - Hanya akun status "active" yang masuk ke config (expired/locked tidak bisa login).
#   - VMess WS 127.0.0.1:10001, VLESS WS 127.0.0.1:10002, Trojan WS 127.0.0.1:10003,
#     VLESS gRPC 127.0.0.1:10004, Stats API 127.0.0.1:10085.
#   - Mode reality: tambah inbound VLESS TCP 443 + REALITY (satu port = satu inbound,
#     jadi 443 hanya untuk VLESS; VMess di mode reality tetap lewat WS 10001 tanpa TLS).
#   - Mode domain: port 443 dipegang Nginx (TLS), Xray hanya listen di localhost.
#   - flow xtls-rprx-vision HANYA untuk klien VLESS transport TCP/REALITY; klien WS
#     tidak diberi flow (Xray akan error bila flow dipakai di WS).
# -----------------------------------------------------------------------------
build_xray_config() {
    local tmp_cfg="${XRAY_CONFIG}.tmp"
    local mode vmess_clients vless_clients trojan_clients
    local vmess_path vless_path trojan_path
    local reality_priv reality_sid reality_dest reality_sni

    mode=$(state_get '.install.mode // ""')
    vmess_path=$(state_get '.install.ws_paths.vmess // "/vmess"')
    vless_path=$(state_get '.install.ws_paths.vless // "/vless"')
    trojan_path=$(state_get '.install.ws_paths.trojan // "/trojan"')
    reality_priv=$(state_get '.install.reality.private_key // ""')
    reality_sid=$(state_get '.install.reality.short_id // ""')
    reality_dest=$(state_get '.install.reality.dest // "www.microsoft.com"')
    reality_sni=$(state_get '.install.reality.sni // "www.microsoft.com"')
    # Akun trial yang sudah habis (trial_until lewat) tidak ikut ke config
    # Xray — pertahanan kedua selain cron 5-menit yang menghapusnya.
    local now_epoch
    now_epoch=$(date +%s)

    vmess_clients=$(jq -c --argjson now "$now_epoch" '[.accounts[] | select(.protocol=="vmess" and .status=="active" and ((.trial_until // 9999999999) > $now))
        | {id: .uuid, alterId: 0, email: .name}]' "$STATE_FILE")
    vless_clients=$(jq -c --argjson now "$now_epoch" '[.accounts[] | select(.protocol=="vless" and .status=="active" and ((.trial_until // 9999999999) > $now))
        | {id: .uuid, email: .name}
          + (if (.transport // "ws") == "tcp" then {flow: "xtls-rprx-vision"} else {} end)]' "$STATE_FILE")
    trojan_clients=$(jq -c --argjson now "$now_epoch" '[.accounts[] | select(.protocol=="trojan" and .status=="active" and ((.trial_until // 9999999999) > $now))
        | {password: .password, email: .name}]' "$STATE_FILE")

    ss_clients=$(jq -c --argjson now "$now_epoch" '[.accounts[] | select(.protocol=="ss" and .status=="active" and ((.trial_until // 9999999999) > $now))
        | {password: .password, method: (.method // "aes-256-gcm"), email: .name}]' "$STATE_FILE")

    mkdir -p "$(dirname "$XRAY_CONFIG")"
    jq -n \
        --argjson vmess "$vmess_clients" \
        --argjson vless "$vless_clients" \
        --argjson trojan "$trojan_clients" \
        --argjson ss "$ss_clients" \
        --arg mode "$mode" \
        --arg vmess_path "$vmess_path" \
        --arg vless_path "$vless_path" \
        --arg trojan_path "$trojan_path" \
        --arg reality_priv "$reality_priv" \
        --arg reality_sid "$reality_sid" \
        --arg reality_dest "$reality_dest" \
        --arg reality_sni "$reality_sni" \
        '{
          log: {loglevel: "warning", access: "/var/log/xray/access.log", error: "/var/log/xray/error.log"},
          stats: {},
          api: {tag: "api", services: ["StatsService"]},
          policy: {
            levels: {"0": {statsUserUplink: true, statsUserDownlink: true}},
            system: {statsInboundUplink: true, statsInboundDownlink: true}
          },
          inbounds: (
            [
              {port: 10001, listen: "127.0.0.1", protocol: "vmess",
               settings: {clients: $vmess},
               streamSettings: {network: "ws", wsSettings: {path: $vmess_path}},
               tag: "vmess-ws"},
              {port: 10002, listen: "127.0.0.1", protocol: "vless",
               settings: {clients: $vless, decryption: "none"},
               streamSettings: {network: "ws", wsSettings: {path: $vless_path}},
               tag: "vless-ws"},
              {port: 10003, listen: "127.0.0.1", protocol: "trojan",
               settings: {clients: $trojan},
               streamSettings: {network: "ws", wsSettings: {path: $trojan_path}},
               tag: "trojan-ws"},
              {port: 10004, listen: "127.0.0.1", protocol: "vless",
               settings: {clients: $vless, decryption: "none"},
               streamSettings: {network: "grpc", grpcSettings: {serviceName: "vless-grpc"}},
               tag: "vless-grpc"},
              {port: 10005, listen: "127.0.0.1", protocol: "vmess",
               settings: {clients: $vmess},
               streamSettings: {network: "grpc", grpcSettings: {serviceName: "vmess-grpc"}},
               tag: "vmess-grpc"},
              {port: 10006, listen: "127.0.0.1", protocol: "trojan",
               settings: {clients: $trojan},
               streamSettings: {network: "grpc", grpcSettings: {serviceName: "trojan-grpc"}},
               tag: "trojan-grpc"},
              {port: 10007, listen: "127.0.0.1", protocol: "shadowsocks",
               settings: {clients: $ss},
               streamSettings: {network: "ws", wsSettings: {path: "/ss"}},
               tag: "ss-ws"},
              {port: 10008, listen: "127.0.0.1", protocol: "shadowsocks",
               settings: {clients: $ss},
               streamSettings: {network: "grpc", grpcSettings: {serviceName: "ss-grpc"}},
               tag: "ss-grpc"},
              {port: 10085, listen: "127.0.0.1", protocol: "dokodemo-door",
               settings: {address: "127.0.0.1"},
               tag: "api"}
            ]
            + (if $mode == "reality" then [
              {port: 443, protocol: "vless",
               settings: {clients: $vless, decryption: "none"},
               streamSettings: {
                 network: "tcp", security: "reality",
                 realitySettings: {
                   dest: ($reality_dest + ":443"),
                   serverNames: [$reality_sni],
                   privateKey: $reality_priv,
                   shortIds: [$reality_sid]
                 }
               },
               sniffing: {enabled: true, destOverride: ["http", "tls"]},
               tag: "vless-reality"}
            ] else [] end)
          ),
          outbounds: [
            {protocol: "freedom", tag: "direct"},
            {protocol: "blackhole", tag: "blocked"}
          ],
          routing: {
            rules: [{type: "field", inboundTag: ["api"], outboundTag: "api"}]
          }
        }' > "$tmp_cfg" || { error "Gagal membangun config Xray (jq)."; return 1; }

    # Validasi struktur JSON sebelum dipakai.
    jq empty "$tmp_cfg" || { error "Config Xray hasil build bukan JSON valid."; rm -f "$tmp_cfg"; return 1; }
    mv "$tmp_cfg" "$XRAY_CONFIG"
    chmod 644 "$XRAY_CONFIG"
    info "Config Xray dibangun dari state.json (${XRAY_CONFIG})"
}

# Terapkan config: backup dulu, validasi xray -test, baru reload/restart.
# Bila validasi gagal -> rollback otomatis, JANGAN restart service yang jalan.
# Tampilkan penyebab sebenarnya saat Xray gagal start — sebelumnya script hanya
# bilang "cek journalctl" dan user harus menjalankan sendiri. Penyebab paling
# umum (xray -test lolos tapi start gagal): reload (HUP) gagal di unit lama,
# atau port 10001-10004/10085 masih dipegang proses lama.
show_xray_failure() {
    error "--- Penyebab gagal (diagnosa otomatis) ---"
    echo "--- systemctl status xray ---" >&2
    systemctl status xray --no-pager 2>/dev/null | head -n 15 >&2 || true
    echo "--- /var/log/xray/error.log (20 baris terakhir) ---" >&2
    tail -n 20 /var/log/xray/error.log 2>/dev/null >&2 || echo "(tidak ada /var/log/xray/error.log)" >&2
    echo "--- journalctl -u xray (20 baris terakhir) ---" >&2
    journalctl -u xray -n 20 --no-pager 2>/dev/null >&2 || true
    echo "--- port Xray (10001-10004, 10085) ---" >&2
    ss -tlnp 2>/dev/null | grep -E ':(10001|10002|10003|10004|10085)[[:space:]]' >&2 || echo "(tidak ada yang mendengarkan di port Xray)" >&2
    error "--- akhir diagnosa ---"
}

# Direktori log Xray HARUS bisa ditulis oleh user yang menjalankan service Xray.
# Unit resmi Xray berjalan sebagai User=nobody, sementara config kita menulis
# log ke /var/log/xray/access.log & error.log. Bila direktori itu milik root
# (dibuat oleh `mkdir -p` saat install), nobody tidak bisa membuat file log
# sehingga Xray gagal start dengan exit code 23 — padahal `xray -test`
# (dijalankan sebagai root) lolos. Itu penyebab pasti kegagalan di VPS user
# (status=23, "open /var/log/xray/access.log: permission denied").
# Direproduksi & diverifikasi dengan Xray 26.11.9 asli: sebagai nobody +
# /var/log/xray milik root -> exit 23; setelah chown ke nobody -> jalan.
ensure_xray_logdir() {
    local xray_user
    xray_user=$(systemctl show -p User --value xray 2>/dev/null || true)
    [[ -z "$xray_user" ]] && xray_user="nobody"
    mkdir -p /var/log/xray
    if [[ "$xray_user" != "root" ]]; then
        chown "$xray_user" /var/log/xray 2>/dev/null || chmod 777 /var/log/xray 2>/dev/null || true
        chown "$xray_user" /var/log/xray/*.log 2>/dev/null || true
    fi
}

apply_xray() {
    build_xray_config || return 1
    backup_config
    if [[ ! -x "$XRAY_BIN" ]]; then
        error "Binary Xray tidak ditemukan di ${XRAY_BIN}. Jalankan menu 1 (Install) dulu."
        return 1
    fi
    ensure_xray_logdir
    if ! "$XRAY_BIN" -test -config "$XRAY_CONFIG" >/tmp/xray-test.log 2>&1; then
        error "Validasi config Xray GAGAL — rollback ke config sebelumnya:"
        cat /tmp/xray-test.log >&2 || true
        rollback_config
        return 1
    fi
    info "Validasi xray -test OK."
    if systemctl is-active --quiet xray; then
        # Coba reload dulu (cepat, tanpa putus koneksi lama)...
        if ! systemctl reload-or-restart xray 2>/dev/null; then
            warn "Reload Xray gagal — coba restart penuh (stop + start)."
        fi
    else
        systemctl start xray 2>/dev/null || true
    fi
    sleep 3
    if systemctl is-active --quiet xray; then
        info "Xray berjalan (active)."
        return 0
    fi
    # Percobaan kedua: restart penuh. Reload (HUP) sering gagal di unit Xray
    # lama / proses yang macet, sementara stop + start bersih berhasil.
    warn "Xray belum aktif setelah reload — coba restart penuh."
    systemctl stop xray 2>/dev/null || true
    sleep 1
    systemctl start xray 2>/dev/null || true
    sleep 3
    if systemctl is-active --quiet xray; then
        info "Xray berjalan setelah restart penuh."
        return 0
    fi
    error "Xray gagal start setelah config baru."
    show_xray_failure
    rollback_config
    # Setelah rollback, pastikan Xray hidup lagi dengan config lama.
    sleep 1
    systemctl is-active --quiet xray || systemctl start xray 2>/dev/null || true
    return 1
}

# -----------------------------------------------------------------------------
# UFW — selalu allow 22 DULU sebelum enable (anti lockout)
# -----------------------------------------------------------------------------
setup_ufw() {
    local mode="$1"
    command -v ufw >/dev/null 2>&1 || { warn "UFW tidak ditemukan, lewati setup firewall."; return 0; }
    ufw allow 22/tcp  comment 'SSH'  >/dev/null 2>&1 || true
    ufw allow 80/tcp  comment 'HTTP'  >/dev/null 2>&1 || true
    ufw allow 443/tcp comment 'HTTPS' >/dev/null 2>&1 || true
    if [[ "$mode" == "reality" ]]; then
        # VMess WS tanpa TLS di mode reality listen di 10001 (publik).
        ufw allow 10001/tcp comment 'VMess WS (reality)' >/dev/null 2>&1 || true
    fi
    local ufw_out
    ufw_out=$(ufw status 2>/dev/null)
    if ! grep -q "Status: active" <<< "$ufw_out"; then
        # Port 22 sudah di-allow di atas, jadi enable aman.
        ufw --force enable >/dev/null 2>&1 || warn "Gagal mengaktifkan UFW — cek manual: ufw status"
    fi
    info "UFW: 22, 80, 443 di-allow (anti lockout SSH)."
}

# -----------------------------------------------------------------------------
# Install Xray-core resmi
# -----------------------------------------------------------------------------
install_xray() {
    if [[ -x "$XRAY_BIN" ]]; then
        info "Xray sudah terpasang: $("$XRAY_BIN" version 2>/dev/null | head -n 1)"
    else
        info "Menginstall Xray-core resmi (script XTLS)..."
        # Script resmi: https://github.com/XTLS/Xray-install
        bash -c "$(curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
        info "Xray terpasang: $("$XRAY_BIN" version 2>/dev/null | head -n 1)"
    fi
    mkdir -p /var/log/xray
    systemctl enable xray >/dev/null 2>&1 || true
}

# -----------------------------------------------------------------------------
# Sertifikat Let's Encrypt via acme.sh (default) — standalone EC-256
# Port 80 harus bebas sesaat; Nginx dihentikan sementara bila jalan.
# Fallback: certbot --nginx bila acme.sh gagal dan certbot tersedia.
# -----------------------------------------------------------------------------
# Pasang sertifikat acme.sh yang sudah ada (bila masih valid) ke SSL_DIR.
# Mengembalikan 0 bila berhasil. Dipakai saat --issue "skip" karena sertifikat
# sudah ada — kasus nyata user: sertifikat sg1.roodyzain.web.id sudah terbit
# (valid sampai 2027-01-26) tapi acme.sh --issue mengembalikan non-zero saat
# "Domains not changed. Skipping", sehingga script lama menganggapnya gagal.
reuse_acme_cert() {
    local domain="$1"
    local acme_home="${HOME}/.acme.sh"
    local cert_dir="${acme_home}/${domain}_ecc"
    local fullchain="${cert_dir}/fullchain.cer"
    local keyfile="${cert_dir}/${domain}.key"
    [[ -f "$fullchain" ]] || return 1
    # Masih valid minimal 1 hari ke depan?
    openssl x509 -in "$fullchain" -noout -checkend 86400 >/dev/null 2>&1 || return 1
    mkdir -p "$SSL_DIR"
    # Coba via --install-cert dulu (supaya auto-renew tetap jalan), fallback cp langsung.
    if ! "${acme_home}/acme.sh" --install-cert -d "$domain" \
            --key-file "${SSL_DIR}/private.key" \
            --fullchain-file "${SSL_DIR}/fullchain.cer" \
            --reloadcmd "systemctl reload nginx" >/dev/null 2>&1; then
        [[ -f "$keyfile" ]] || return 1
        cp -a "$fullchain" "${SSL_DIR}/fullchain.cer"
        cp -a "$keyfile" "${SSL_DIR}/private.key"
    fi
    chmod 600 "${SSL_DIR}/private.key"
    local exp
    exp=$(openssl x509 -in "${SSL_DIR}/fullchain.cer" -noout -enddate 2>/dev/null | cut -d= -f2 || echo "?")
    info "Sertifikat dipakai ulang: ${SSL_DIR}/fullchain.cer (berlaku sampai ${exp})"
    return 0
}

issue_cert_acme() {
    local domain="$1" email="$2"
    local acme_home="${HOME}/.acme.sh"
    # Sertifikat sudah ada & masih valid -> pakai ulang, jangan terbitkan baru.
    if reuse_acme_cert "$domain"; then
        info "Sertifikat untuk ${domain} sudah ada dan masih valid — tidak perlu terbit baru."
        return 0
    fi
    if [[ ! -x "${acme_home}/acme.sh" ]]; then
        info "Menginstall acme.sh..."
        # Email BOLEH kosong: acme.sh tetap bisa terbitkan sertifikat tanpa email,
        # hanya saja tidak ada pengingat expiry dari Let's Encrypt.
        if [[ -n "$email" ]]; then
            curl -fsSL https://get.acme.sh | sh -s email="$email" >/tmp/acme-install.log 2>&1 \
                || { error "Install acme.sh gagal. Lihat /tmp/acme-install.log"; return 1; }
        else
            curl -fsSL https://get.acme.sh | sh >/tmp/acme-install.log 2>&1 \
                || { error "Install acme.sh gagal. Lihat /tmp/acme-install.log"; return 1; }
        fi
    fi
    "${acme_home}/acme.sh" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
    # Port 80 harus bebas untuk validasi standalone.
    if systemctl is-active --quiet nginx; then
        systemctl stop nginx
    fi
    if ! "${acme_home}/acme.sh" --issue -d "$domain" --standalone --keylength ec-256 >/tmp/acme-issue.log 2>&1; then
        # acme.sh mengembalikan non-zero saat "Domains not changed. Skipping"
        # (sertifikat sudah ada & belum waktunya renew) — itu BUKAN kegagalan.
        if reuse_acme_cert "$domain"; then
            info "acme.sh melewatkan penerbitan karena sertifikat sudah ada — dipakai ulang."
            return 0
        fi
        error "acme.sh gagal menerbitkan sertifikat untuk ${domain}."
        error "--- isi /tmp/acme-issue.log (15 baris terakhir — penyebab pastinya) ---"
        tail -n 15 /tmp/acme-issue.log >&2 || true
        error "--- akhir log acme ---"
        error "Penyebab umum: domain belum resolve ke IP VPS ini, atau port 80 diblokir (firewall cloud/security group)."
        return 1
    fi
    mkdir -p "$SSL_DIR"
    "${acme_home}/acme.sh" --install-cert -d "$domain" \
        --key-file "${SSL_DIR}/private.key" \
        --fullchain-file "${SSL_DIR}/fullchain.cer" \
        --reloadcmd "systemctl reload nginx" >/dev/null 2>&1
    chmod 600 "${SSL_DIR}/private.key"
    info "Sertifikat terbit: ${SSL_DIR}/fullchain.cer (EC-256, auto-renew via acme.sh)"
}

issue_cert() {
    local domain="$1" email="$2"
    if issue_cert_acme "$domain" "$email"; then
        return 0
    fi
    warn "acme.sh gagal — coba fallback certbot --nginx..."
    if ! command -v certbot >/dev/null 2>&1; then
        warn "certbot tidak terinstall — fallback dilewati (install: apt-get install -y certbot python3-certbot-nginx)."
    fi
    if command -v certbot >/dev/null 2>&1; then
        systemctl start nginx 2>/dev/null || true
        local certbot_email_args=(--email "$email")
        [[ -z "$email" ]] && certbot_email_args=(--register-unsafely-without-email)
        if certbot --nginx -d "$domain" "${certbot_email_args[@]}" --agree-tos --non-interactive --redirect; then
            # Certbot menyimpan cert di /etc/letsencrypt; salin path-nya ke state via symlink.
            mkdir -p "$SSL_DIR"
            ln -sf "/etc/letsencrypt/live/${domain}/fullchain.pem" "${SSL_DIR}/fullchain.cer"
            ln -sf "/etc/letsencrypt/live/${domain}/privkey.pem" "${SSL_DIR}/private.key"
            info "Sertifikat terbit via certbot."
            return 0
        fi
    fi
    error "Semua cara penerbitan sertifikat gagal. Perbaiki DNS/port 80 lalu ulangi menu 1."
    return 1
}

# -----------------------------------------------------------------------------
# Nginx (mode domain): reverse proxy WS + SSH WS, TLS dari /etc/vps-manager/ssl/
# Catatan jujur: location /ssh-ws di bawah ini meneruskan upgrade WebSocket ke
# 127.0.0.1:22. Nginx sendiri TIDAK menerjemahkan frame WebSocket menjadi TCP
# mentah SSH — klien SSH-WS (mis. HTTP Custom) butuh jembatan WS->TCP seperti
# ws-epro di depan port 22. Bila tidak ada jembatan, SSH tetap bisa dipakai
# normal lewat port 22. Blok ini tetap ditulis sesuai permintaan, dan README
# menjelaskan batasannya.
# -----------------------------------------------------------------------------
write_nginx_conf() {
    local domain="$1"
    local vmess_path vless_path trojan_path
    vmess_path=$(state_get '.install.ws_paths.vmess')
    vless_path=$(state_get '.install.ws_paths.vless')
    trojan_path=$(state_get '.install.ws_paths.trojan')

    cat > "$NGINX_CONF" <<EOF
# vps-manager — Nginx reverse proxy (dibuat otomatis, jangan edit manual).
# Domain: ${domain}

server {
    listen 80;
    server_name ${domain};
    # Port 80 = non-TLS: VMess/VLESS/Trojan WS + SSH WS tanpa TLS.
    # (ACME challenge tetap bisa diakses; selain path di bawah, redirect ke HTTPS.)
    location /.well-known/acme-challenge/ { root /var/www/html; }
    location ${vmess_path} {
        proxy_pass http://127.0.0.1:${PORT_VMESS_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location ${vless_path} {
        proxy_pass http://127.0.0.1:${PORT_VLESS_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location ${trojan_path} {
        proxy_pass http://127.0.0.1:${PORT_TROJAN_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    # Shadowsocks WS
    location /ss {
        proxy_pass http://127.0.0.1:${PORT_SS_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location /ssh-ws {
        proxy_pass http://127.0.0.1:10090;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    # "http2 on;" hanya ada di Nginx >= 1.25.1 — di Ubuntu 22.04 (Nginx 1.18)
    # direktif itu tidak dikenal dan "nginx -t" gagal. Bentuk "listen ... http2"
    # ini jalan di semua versi Nginx sejak 1.9.5.
    # (Jangan pakai backtick di komentar dalam heredoc ini: heredoc tidak
    # dikutip sehingga backtick akan dieksekusi sebagai perintah.)
    listen 443 ssl http2;
    server_name ${domain};

    ssl_certificate ${SSL_DIR}/fullchain.cer;
    ssl_certificate_key ${SSL_DIR}/private.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;

    # VMess WS
    location ${vmess_path} {
        proxy_pass http://127.0.0.1:${PORT_VMESS_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    # VLESS WS
    location ${vless_path} {
        proxy_pass http://127.0.0.1:${PORT_VLESS_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    # Trojan WS
    location ${trojan_path} {
        proxy_pass http://127.0.0.1:${PORT_TROJAN_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    # Shadowsocks WS
    location /ss {
        proxy_pass http://127.0.0.1:${PORT_SS_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }
    # SSH over WebSocket via jembatan ws-epro (127.0.0.1:10090 -> SSH 22).
    # JANGAN proxy langsung ke 127.0.0.1:22: Nginx tidak menerjemahkan frame
    # WebSocket menjadi TCP mentah, jadi klien SSH/HTTP Custom tidak akan connect.
    location /ssh-ws {
        proxy_pass http://127.0.0.1:10090;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
    }

    # gRPC (VLESS/VMess/Trojan/Shadowsocks) — serviceName = path; butuh HTTP/2 (sudah aktif di 443).
    location /vless-grpc {
        grpc_pass grpc://127.0.0.1:${PORT_VLESS_GRPC};
    }
    location /vmess-grpc {
        grpc_pass grpc://127.0.0.1:${PORT_VMESS_GRPC};
    }
    location /trojan-grpc {
        grpc_pass grpc://127.0.0.1:${PORT_TROJAN_GRPC};
    }
    location /ss-grpc {
        grpc_pass grpc://127.0.0.1:${PORT_SS_GRPC};
    }

    # Link PERMANEN script ini (permintaan user — tidak ada expired):
    # https://<domain>/vps-manager.sh menyajikan file /usr/local/bin/vps-manager
    # yang sedang terinstall. Selama VPS ini hidup, link itu selalu bisa dipakai
    # untuk install di VPS lain / install ulang. Script tidak berisi kredensial
    # apa pun (UUID/password hanya ada di /etc/vps-manager/state.json, 600),
    # jadi aman disajikan publik.
    location = /vps-manager.sh {
        alias /usr/local/bin/vps-manager;
        default_type text/plain;
    }

    location / {
        return 200 'vps-manager OK\n';
        add_header Content-Type text/plain;
    }
}
EOF
    if ! nginx -t >/tmp/nginx-test.log 2>&1; then
        error "Validasi Nginx GAGAL — rollback ke config sebelumnya:"
        cat /tmp/nginx-test.log >&2 || true
        local last
        last=$(ls -t "${BACKUP_DIR}"/vps-manager.conf.* 2>/dev/null | head -n 1 || true)
        if [[ -n "$last" ]]; then cp -a "$last" "$NGINX_CONF"; fi
        return 1
    fi
    info "Config Nginx valid (nginx -t OK)."
    systemctl reload-or-restart nginx
}

# -----------------------------------------------------------------------------
# Instalasi / update
# Idempotent: install ulang TIDAK menghapus akun di state.json — config selalu
# dibangun ulang dari state yang sudah ada.
# -----------------------------------------------------------------------------
setup_cron_expired() {
    cat > "$CRON_FILE" <<EOF
# vps-manager: cek akun expired setiap hari jam 02:00 WIB
0 2 * * * root ${INSTALL_BIN} --check-expired >> ${LOG_FILE} 2>&1
# vps-manager: hapus akun trial yang habis (tiap 5 menit)
*/5 * * * * root ${INSTALL_BIN} --check-trials >> ${LOG_FILE} 2>&1
EOF
    chmod 644 "$CRON_FILE"
    info "Cron harian dipasang: ${CRON_FILE}"
}

install_self() {
    # Salin script ini ke /usr/local/bin agar bisa dipanggil sebagai `vps-manager`.
    # Bila sudah dijalankan dari sana, jangan salin ke dirinya sendiri
    # (dulu memunculkan pesan "cp: ... are the same file").
    if [[ "$(readlink -f "$0" 2>/dev/null || echo "$0")" != "$(readlink -f "$INSTALL_BIN" 2>/dev/null || echo "$INSTALL_BIN")" ]]; then
        cp -a "$0" "$INSTALL_BIN" 2>/dev/null || cp -a "$(readlink -f "$0")" "$INSTALL_BIN"
    fi
    chmod +x "$INSTALL_BIN"
    # Pintasan `menu`: sekali terinstall, cukup ketik `menu` di terminal untuk
    # membuka menu dengan hasil instalasi yang sudah ada (permintaan user).
    # Hanya dibuat bila belum ada, atau bila sudah menunjuk ke script ini —
    # jangan timpa perintah `menu` lain bila ada.
    if [[ ! -e /usr/local/bin/menu ]] || [[ "$(readlink /usr/local/bin/menu 2>/dev/null)" == "$INSTALL_BIN" ]]; then
        ln -sf "$INSTALL_BIN" /usr/local/bin/menu 2>/dev/null || true
    fi
}

# Deteksi IP publik VPS dari beberapa sumber (satu saja cukup).
detect_public_ip() {
    local ip=""
    for url in https://api.ipify.org https://ifconfig.me https://icanhazip.com; do
        ip=$(curl -fsSL --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            printf '%s' "$ip"
            return 0
        fi
    done
    return 1
}

# Setup mode REALITY (dipakai menu 1 pilihan 2, dan sebagai fallback bila
# sertifikat domain gagal — user tetap bisa memakai VLESS tanpa domain).
install_reality() {
    free_port_or_ask 443 "VLESS REALITY" || return 1
    local priv pub sid
    local key_out
    key_out=$("$XRAY_BIN" x25519 2>/tmp/x25519.err)
    priv=$(printf '%s' "$key_out" | awk -F': ' '/Private key/{print $2}')
    pub=$(printf '%s' "$key_out" | awk -F': ' '/Public key/{print $2}')
    if [[ -z "$priv" || -z "$pub" ]]; then
        warn "xray x25519 gagal — coba generate keypair dengan openssl sebagai gantinya."
        warn "Error xray x25519: $(cat /tmp/x25519.err 2>/dev/null | head -n 3 | tr '\n' ' ')"
        # Fallback openssl: private key = 32 byte terakhir DER PKCS8,
        # public key = 32 byte terakhir DER SPKI; keduanya base64url tanpa padding
        # (format yang sama dengan yang dihasilkan `xray x25519`).
        local k_priv k_pub
        k_priv=$(mktemp); k_pub=$(mktemp)
        if openssl genpkey -algorithm X25519 -out "$k_priv" 2>/dev/null \
            && openssl pkey -in "$k_priv" -pubout -outform DER -out "$k_pub" 2>/dev/null; then
            priv=$(tail -c 32 "$k_priv" | base64 -w0 | tr '+/' '-_' | tr -d '=')
            pub=$(tail -c 32 "$k_pub" | base64 -w0 | tr '+/' '-_' | tr -d '=')
        fi
        rm -f "$k_priv" "$k_pub"
    fi
    if [[ -z "$priv" || -z "$pub" ]]; then
        error "Gagal generate keypair REALITY (xray x25519 dan openssl sama-sama gagal)."
        error "Coba manual di VPS: $XRAY_BIN x25519  — lalu kirim outputnya."
        return 1
    fi
    sid=$(openssl rand -hex 8)
    jq_state --arg priv "$priv" --arg pub "$pub" --arg sid "$sid" \
        '.install.mode="reality"
         | .install.reality.private_key=$priv | .install.reality.public_key=$pub
         | .install.reality.short_id=$sid
         | .install.installed_at=(now | strftime("%Y-%m-%dT%H:%M:%S%z"))'
    jq_state '.install.ws_paths.vmess="/vmess" | .install.ws_paths.vless="/vless" | .install.ws_paths.trojan="/trojan"'
    info "Keypair REALITY dibuat. Public key (untuk link klien): ${pub}"
    info "ShortId: ${sid} | SNI tujuan: www.microsoft.com"
}

# Dropbear SSH di 109/143 (dipakai HTTP Custom + Running Service).
# OpenSSH tetap di 22 — Dropbear TIDAK menggantikannya, hanya tambahan.
setup_dropbear() {
    local dpkg_out
    dpkg_out=$(dpkg -l dropbear 2>/dev/null)
    if ! grep -q '^ii' <<< "$dpkg_out"; then
        fix_dns
        DEBIAN_FRONTEND=noninteractive apt-get install -y dropbear 2>/dev/null \
            || { warn "Install dropbear gagal (apt) — coba manual: apt install dropbear."; return 1; }
    fi
    if [[ -f /etc/default/dropbear ]]; then
        sed -i 's/^NO_START=.*/NO_START=0/' /etc/default/dropbear 2>/dev/null || true
        if grep -q '^DROPBEAR_PORT=' /etc/default/dropbear; then
            sed -i 's/^DROPBEAR_PORT=.*/DROPBEAR_PORT=109/' /etc/default/dropbear
        else
            echo "DROPBEAR_PORT=109" >> /etc/default/dropbear
        fi
        if grep -q '^DROPBEAR_EXTRA_ARGS=' /etc/default/dropbear; then
            sed -i 's/^DROPBEAR_EXTRA_ARGS=.*/DROPBEAR_EXTRA_ARGS="-p 143"/' /etc/default/dropbear
        else
            echo 'DROPBEAR_EXTRA_ARGS="-p 143"' >> /etc/default/dropbear
        fi
        # Jangan sampai ada "-p 22" (bentrok OpenSSH).
        sed -i 's/-p 22//g' /etc/default/dropbear
    fi
    systemctl enable dropbear 2>/dev/null || true
    systemctl restart dropbear 2>/dev/null || systemctl start dropbear 2>/dev/null \
        || { warn "Dropbear gagal start — cek: systemctl status dropbear"; return 1; }
    sleep 1
    if port_tcp 109 || port_tcp 143; then
        info "Dropbear jalan (109/143)."
        ufw allow 109/tcp 2>/dev/null || true
        ufw allow 143/tcp 2>/dev/null || true
    else
        warn "Dropbear tidak mendengarkan di 109/143 — cek: systemctl status dropbear"
        return 1
    fi
}

# SSH UDP-HC: 3 instance udp-custom (UDP 7100/7200/7300 -> SSH 22).
# Desain ini dari script menu lama (milik sendiri): binary
# /usr/local/bin/udp-custom, config /etc/udp-custom/config-<port>.json,
# unit udp-custom-<port>.service. Bila binary sudah ada di VPS, cukup tulis
# ulang config + unit lalu restart. Bila belum ada, coba unduh dari rilis
# http-custom/udp-custom (pengganti aztecrabbit yang sudah tidak ada);
# bila unduhan gagal, laporkan jujur — jangan pura-pura berhasil.
setup_udp_forward() {
    # Forwarder UDP -> SSH (pengganti udp-custom / BadVPN udpgw), dibuat sendiri.
    # Binary udp-custom TIDAK bisa diunduh (repo http-custom/udp-custom tidak
    # punya rilis — 404), jadi fungsinya ditulis ulang di sini (Python stdlib):
    # listen UDP 7100/7200/7300, teruskan ke SSH 127.0.0.1:22.
    mkdir -p /opt/vps-tunnel
    cat > /opt/vps-tunnel/udp-custom.py <<'PYEOF'
#!/usr/bin/env python3
"""UDP -> SSH forwarder (pengganti udp-custom / BadVPN udpgw).

Listen UDP 7100/7200/7300, teruskan ke SSH 127.0.0.1:22 (TCP).
Satu proses melayani ketiga port; tiap klien UDP (IP:port + port listen)
dipetakan ke satu koneksi TCP SSH. Dibuat sendiri (stdlib saja) karena
binary udp-custom tidak lagi bisa diunduh (repo http-custom/udp-custom
tidak punya rilis — 404).
"""
import socket
import threading
import time
import logging

SSH_HOST = "127.0.0.1"
SSH_PORT = 22
UDP_PORTS = (7100, 7200, 7300)
IDLE_TIMEOUT = 180
BUF = 65535

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")


class Client:
    def __init__(self, addr, sock):
        self.addr = addr
        self.sock = sock
        self.tcp = socket.create_connection((SSH_HOST, SSH_PORT), timeout=10)
        self.tcp.settimeout(60)
        self.last = time.time()
        self.lock = threading.Lock()
        self.closed = False

    def send_to_tcp(self, data):
        with self.lock:
            if self.closed:
                return
            try:
                self.tcp.sendall(data)
                self.last = time.time()
            except OSError:
                self.close()

    def close(self):
        with self.lock:
            if self.closed:
                return
            self.closed = True
            try:
                self.tcp.close()
            except OSError:
                pass


clients = {}
clients_lock = threading.Lock()


def tcp_reader(client, key):
    try:
        while True:
            data = client.tcp.recv(16384)
            if not data:
                break
            client.last = time.time()
            try:
                client.sock.sendto(data, client.addr)
            except OSError:
                break
    except OSError:
        pass
    finally:
        with clients_lock:
            if clients.get(key) is client:
                del clients[key]
        client.close()


def udp_loop(port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.bind(("0.0.0.0", port))
    logging.info("UDP forwarder listen 0.0.0.0:%d -> %s:%d",
                 port, SSH_HOST, SSH_PORT)
    while True:
        try:
            data, addr = sock.recvfrom(BUF)
        except OSError:
            continue
        if not data:
            continue
        key = (addr, port)
        with clients_lock:
            client = clients.get(key)
            if client is None or client.closed:
                try:
                    client = Client(addr, sock)
                except OSError:
                    continue
                clients[key] = client
                threading.Thread(target=tcp_reader, args=(client, key),
                                 daemon=True).start()
        client.send_to_tcp(data)


def reaper():
    while True:
        time.sleep(30)
        now = time.time()
        with clients_lock:
            for key, client in list(clients.items()):
                if now - client.last > IDLE_TIMEOUT:
                    del clients[key]
                    client.close()


def main():
    threading.Thread(target=reaper, daemon=True).start()
    threads = []
    for port in UDP_PORTS:
        t = threading.Thread(target=udp_loop, args=(port,), daemon=True)
        t.start()
        threads.append(t)
    for t in threads:
        t.join()


if __name__ == "__main__":
    main()
PYEOF
    if ! python3 -m py_compile /opt/vps-tunnel/udp-custom.py 2>/dev/null; then
        error "udp-custom.py gagal dikompilasi — SSH UDP-HC / BadVPN tetap OFF."
        return 1
    fi
    # Bersihkan unit udp-custom lama (bila pernah dibuat) supaya tidak rebutan port.
    local p
    for p in 7100 7200 7300; do
        if systemctl is-enabled "udp-custom-${p}" >/dev/null 2>&1 || [[ -f "/etc/systemd/system/udp-custom-${p}.service" ]]; then
            systemctl stop "udp-custom-${p}" 2>/dev/null || true
            systemctl disable "udp-custom-${p}" 2>/dev/null || true
            rm -f "/etc/systemd/system/udp-custom-${p}.service"
        fi
    done
    rm -f /etc/udp-custom/config-7100.json /etc/udp-custom/config-7200.json /etc/udp-custom/config-7300.json
    cat > /etc/systemd/system/vps-udp.service <<EOF
[Unit]
Description=SSH UDP-HC / BadVPN (UDP 7100/7200/7300 -> SSH 22)
After=network.target ssh.service
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/vps-tunnel/udp-custom.py
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable vps-udp 2>/dev/null || true
    systemctl restart vps-udp 2>/dev/null || warn "vps-udp gagal start"
    ufw allow 7100/udp 2>/dev/null || true
    ufw allow 7200/udp 2>/dev/null || true
    ufw allow 7300/udp 2>/dev/null || true
    sleep 1
    local ok=0
    for p in 7100 7200 7300; do port_udp "$p" && ok=$((ok+1)); done
    if (( ok == 3 )); then
        info "SSH UDP-HC jalan (UDP 7100/7200/7300 -> SSH 22)."
    else
        warn "UDP forwarder hanya ${ok}/3 port yang LISTEN — cek: journalctl -u vps-udp -n 20"
        return 1
    fi
}


setup_ohp() {
    # HTTP tunnel (pengganti OHP / Open HTTP Puncher), dibuat sendiri (Python stdlib).
    # Binary OHP tidak tersedia publik (repo 404, docs 403), jadi fungsinya
    # ditulis ulang di sini: baca header HTTP, balas respons HTTP, lalu teruskan
    # (TCP murni) ke SSH 22 (mode ssh, listen 8181) atau Dropbear 109 (mode
    # dropbear, listen 8282). Dipakai HTTP Custom.
    mkdir -p /opt/vps-tunnel
    cat > /opt/vps-tunnel/ohp.py <<'PYEOF'
#!/usr/bin/env python3
"""HTTP tunnel (pengganti OHP / Open HTTP Puncher) — stdlib saja.

Terima koneksi HTTP, baca header request, balas respons HTTP, lalu teruskan
(murni TCP) ke backend: SSH 127.0.0.1:22 (mode ssh, listen 8181) atau
Dropbear 127.0.0.1:109 (mode dropbear, listen 8282). Dipakai HTTP Custom.
Dibuat sendiri karena binary OHP tidak tersedia publik (repo 404, docs 403).
"""
import argparse
import logging
import socket
import threading

logging.basicConfig(level=logging.INFO,
                    format="%(asctime)s %(levelname)s %(message)s")


def pump(src, dst, done, pair):
    try:
        while not done.is_set():
            data = src.recv(16384)
            if not data:
                break
            dst.sendall(data)
    except OSError:
        pass
    finally:
        done.set()
        for s in pair:
            try:
                s.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass


def handle(client, backend_host, backend_port):
    try:
        client.settimeout(15)
        buf = b""
        while b"\r\n\r\n" not in buf and len(buf) < 16384:
            chunk = client.recv(4096)
            if not chunk:
                return
            buf += chunk
        if b"\r\n\r\n" not in buf:
            return
        head, rest = buf.split(b"\r\n\r\n", 1)
        first = head.split(b"\r\n", 1)[0].decode("iso-8859-1", "replace")
        method = first.split(" ", 1)[0].upper() if first else ""
        if method == "CONNECT":
            resp = b"HTTP/1.1 200 Connection Established\r\n\r\n"
        elif (b"upgrade: websocket" in head.lower()
                or b"connection: upgrade" in head.lower()):
            resp = (b"HTTP/1.1 101 Switching Protocols\r\n"
                    b"Upgrade: websocket\r\n"
                    b"Connection: Upgrade\r\n\r\n")
        else:
            resp = b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        backend = socket.create_connection((backend_host, backend_port),
                                           timeout=10)
        client.sendall(resp)
        if rest:
            backend.sendall(rest)
        client.settimeout(None)
        backend.settimeout(None)
        done = threading.Event()
        pair = (client, backend)
        t1 = threading.Thread(target=pump, args=(client, backend, done, pair),
                              daemon=True)
        t2 = threading.Thread(target=pump, args=(backend, client, done, pair),
                              daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
    except OSError:
        pass
    finally:
        for s in (client,):
            try:
                s.close()
            except OSError:
                pass


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["ssh", "dropbear"], required=True)
    ap.add_argument("--port", type=int, default=0)
    args = ap.parse_args()
    if args.mode == "ssh":
        backend = ("127.0.0.1", 22)
        port = args.port or 8181
    else:
        backend = ("127.0.0.1", 109)
        port = args.port or 8282
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(128)
    logging.info("OHP %s listen 0.0.0.0:%d -> %s:%d",
                 args.mode, port, backend[0], backend[1])
    while True:
        try:
            client, _ = srv.accept()
        except OSError:
            continue
        threading.Thread(target=handle, args=(client, backend[0], backend[1]),
                         daemon=True).start()


if __name__ == "__main__":
    main()
PYEOF
    if ! python3 -m py_compile /opt/vps-tunnel/ohp.py 2>/dev/null; then
        error "ohp.py gagal dikompilasi — OHP tetap OFF."
        return 1
    fi
    cat > /etc/systemd/system/ohp-ssh.service <<EOF
[Unit]
Description=OHP SSH (HTTP tunnel 8181 -> SSH 22)
After=network.target ssh.service
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/vps-tunnel/ohp.py --mode ssh
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    cat > /etc/systemd/system/ohp-dropbear.service <<EOF
[Unit]
Description=OHP Dropbear (HTTP tunnel 8282 -> Dropbear 109)
After=network.target ssh.service dropbear.service
[Service]
Type=simple
User=root
ExecStart=/usr/bin/python3 /opt/vps-tunnel/ohp.py --mode dropbear
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable ohp-ssh 2>/dev/null || true
    systemctl enable ohp-dropbear 2>/dev/null || true
    systemctl restart ohp-ssh 2>/dev/null || warn "ohp-ssh gagal start"
    systemctl restart ohp-dropbear 2>/dev/null || warn "ohp-dropbear gagal start"
    ufw allow 8181/tcp 2>/dev/null || true
    ufw allow 8282/tcp 2>/dev/null || true
    sleep 1
    local ok=0
    port_tcp 8181 && ok=$((ok+1))
    port_tcp 8282 && ok=$((ok+1))
    if (( ok == 2 )); then
        info "OHP jalan (SSH 8181 -> SSH 22, Dropbear 8282 -> Dropbear 109)."
    else
        warn "OHP hanya ${ok}/2 port yang LISTEN — cek: journalctl -u ohp-ssh -n 20 / journalctl -u ohp-dropbear -n 20"
        return 1
    fi
    if ! port_tcp 109; then
        warn "Dropbear (port 109) belum LISTEN — OHP Dropbear (8282) sudah jalan tapi belum bisa dipakai sampai Dropbear aktif (menu 12 > 27 memperbaikinya)."
    fi
}


setup_ws_epro() {
    if python3 -c "import websockets" 2>/dev/null; then
        info "Modul websockets sudah ada."
    else
        info "Menginstall modul websockets (untuk jembatan SSH WS)..."
        if ! (timeout 120 apt-get install -y python3-websockets 2>/dev/null || timeout 120 pip3 install --break-system-packages websockets 2>/dev/null || timeout 120 pip3 install websockets 2>/dev/null); then
            warn "Gagal install websockets — SSH WS (/ssh-ws) tidak akan jalan; VMess/VLESS/Trojan tetap jalan."
            return 1
        fi
    fi
    mkdir -p /opt/ws-epro
    cat > /opt/ws-epro/ws-epro.py <<'PYEOF'
#!/usr/bin/env python3
"""WS-ePRO: jembatan WebSocket -> TCP untuk SSH.
Mendengarkan 127.0.0.1:10090, meneruskan setiap koneksi WS ke SSH 127.0.0.1:22.
Dipakai Nginx location /ssh-ws (port 80 non-TLS dan 443 TLS).
"""
import asyncio
import logging

import websockets

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = 10090
SSH_HOST = "127.0.0.1"
SSH_PORT = 22

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")


async def handle(ws):
    try:
        reader, writer = await asyncio.open_connection(SSH_HOST, SSH_PORT)
    except Exception as e:
        logging.error("gagal connect SSH: %s", e)
        try:
            await ws.close()
        except Exception:
            pass
        return

    async def ws_to_tcp():
        try:
            async for msg in ws:
                if isinstance(msg, bytes):
                    writer.write(msg)
                    await writer.drain()
        except Exception:
            pass
        finally:
            writer.close()

    async def tcp_to_ws():
        try:
            while True:
                data = await reader.read(65536)
                if not data:
                    break
                await ws.send(data)
        except Exception:
            pass
        finally:
            try:
                await ws.close()
            except Exception:
                pass

    await asyncio.gather(ws_to_tcp(), tcp_to_ws())


async def main():
    async with websockets.serve(handle, LISTEN_HOST, LISTEN_PORT, max_size=10 * 1024 * 1024):
        logging.info("ws-epro jalan di %s:%d -> SSH %s:%d", LISTEN_HOST, LISTEN_PORT, SSH_HOST, SSH_PORT)
        await asyncio.Future()


asyncio.run(main())
PYEOF
    chmod +x /opt/ws-epro/ws-epro.py
    cat > /etc/systemd/system/ws-epro.service <<'EOF'
[Unit]
Description=WS-ePRO bridge (WebSocket to SSH 22)
After=network.target sshd.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/ws-epro/ws-epro.py
Restart=on-failure
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable ws-epro >/dev/null 2>&1 || true
    systemctl restart ws-epro 2>/dev/null || systemctl start ws-epro 2>/dev/null || true
    sleep 1
    if systemctl is-active --quiet ws-epro 2>/dev/null; then
        info "ws-epro berjalan (127.0.0.1:10090 -> SSH 22)."
    else
        warn "ws-epro gagal start — SSH WS (/ssh-ws) tidak jalan; VMess/VLESS/Trojan tetap jalan."
    fi
    return 0
}

do_install() {
    # Argumen opsional (mode non-interaktif): $1=mode $2=domain $3=email
    local mode="${1:-}" domain="${2:-}" email="${3:-}"
    local cur_mode
    cur_mode=$(state_get '.install.mode // ""')

    check_deps
    install_xray
    ensure_xray_logdir

    # Pilih mode bila belum diberikan.
    if [[ -z "$mode" ]]; then
        echo "Pilih mode instalasi:"
        echo "  1) Domain + TLS (butuh domain yang sudah mengarah ke IP VPS ini)"
        echo "  2) REALITY tanpa domain (VLESS TCP 443, tanpa sertifikat)"
        local pilih=""
        read -r -p "Pilih [1/2]: " pilih
        case "$pilih" in
            1) mode="domain" ;;
            2) mode="reality" ;;
            *) error "Pilihan tidak valid."; return 1 ;;
        esac
    fi

    if [[ "$mode" == "domain" ]]; then
        if [[ -z "$domain" ]]; then
            domain=$(read_validated "Domain (contoh: vpn.domainkamu.com): " valid_domain "Domain tidak valid.")
        elif ! valid_domain "$domain"; then
            error "Domain tidak valid: $domain"; return 1
        fi
        if [[ -z "$email" ]]; then
            # Email OPSIONAL: tekan Enter saja bila tidak mau pakai email.
            # Konsekuensi: tidak ada pengingat expiry sertifikat dari Let's Encrypt.
            # Alternatif tanpa email & tanpa domain sama sekali: pilih mode REALITY.
            email=$(read_validated "Email untuk Let's Encrypt (boleh kosong, tekan Enter): " valid_email "Email tidak valid." 1)
        elif ! valid_email "$email"; then
            error "Email tidak valid: $email"; return 1
        fi
        # Cek DNS — SELALU tampilkan kedua nilai supaya mismatch terlihat jelas.
        # Kasus nyata yang dialami user: sg1.roodyzain.web.id resolve ke
        # 198.18.122.101 (bukan IP VPS) sehingga Let's Encrypt gagal — tapi cek
        # lama diam saja karena IP VPS gagal terdeteksi dari 1 sumber (ipify).
        local vps_ip resolved
        vps_ip=$(detect_public_ip || true)
        [[ -n "$vps_ip" ]] && jq_state --arg v "$vps_ip" '.install.ip = $v' 2>/dev/null || true
        resolved=$(getent hosts "$domain" | awk '{print $1}' | head -n 1 || true)
        info "Domain ${domain} resolve ke: ${resolved:-TIDAK RESOLVE ke mana pun}"
        info "IP publik VPS ini: ${vps_ip:-TIDAK TERDETEKSI (cek manual: curl -s https://api.ipify.org)}"
        if [[ -z "$resolved" ]]; then
            error "Domain ${domain} TIDAK resolve ke IP mana pun. Perbaiki A record domain ke IP VPS (${vps_ip:-<cek dengan: curl -s https://api.ipify.org>}), tunggu propagasi, lalu ulangi menu 1."
            read -r -p "Tetap coba terbitkan sertifikat (kemungkinan besar gagal)? [y/N]: " -n 1 -r
            echo
            [[ ${REPLY:-} =~ ^[Yy]$ ]] || { info "Instalasi dibatalkan."; return 1; }
        elif [[ -n "$vps_ip" && "$resolved" != "$vps_ip" ]]; then
            error "Domain ${domain} resolve ke ${resolved}, sedangkan IP VPS ini ${vps_ip}. Let's Encrypt akan GAGAL — ubah A record domain ke ${vps_ip} dulu."
            error "Periksa juga firewall cloud (security group Tencent/dll): port 80 & 443 harus terbuka dari internet, bukan hanya UFW."
            read -r -p "Tetap lanjut? [y/N]: " -n 1 -r
            echo
            [[ ${REPLY:-} =~ ^[Yy]$ ]] || { info "Instalasi dibatalkan."; return 1; }
        elif [[ -z "$vps_ip" ]]; then
            warn "IP publik VPS tidak terdeteksi — tidak bisa memastikan domain sudah benar. Lanjut, tapi bila sertifikat gagal, cek A record manual."
        fi
        free_port_or_ask 80 "HTTP (validasi ACME)" || return 1
        free_port_or_ask 443 "HTTPS" || return 1
        # Path WS TETAP (permintaan user): /vmess, /vless, /trojan.
        # Dulu acak (/vmess-xxxx) supaya tidak mudah ditebak; user minta yang
        # sederhana saja, dan install ulang akan menyeragamkan path lama ke ini.
        local vp vl tp
        vp="/vmess"
        vl="/vless"
        tp="/trojan"
        jq_state --arg d "$domain" --arg e "$email" --arg vp "$vp" --arg vl "$vl" --arg tp "$tp" \
            '.install.mode="domain" | .install.domain=$d | .install.email=$e
             | .install.ws_paths.vmess=$vp | .install.ws_paths.vless=$vl | .install.ws_paths.trojan=$tp
             | .install.installed_at=(now | strftime("%Y-%m-%dT%H:%M:%S%z"))'
        if ! issue_cert "$domain" "$email"; then
            error "Instalasi berhenti: sertifikat gagal. Mode domain butuh sertifikat valid."
            local ans=""
            read -r -p "Lanjut install dengan mode REALITY saja (VLESS TCP 443, tanpa domain/sertifikat — bisa langsung dipakai)? [y/N]: " ans
            if [[ "${ans:-}" =~ ^[Yy]$ ]]; then
                mode="reality"
                install_reality || return 1
            else
                return 1
            fi
        fi
        if [[ "$mode" == "domain" ]]; then
            backup_config
            write_nginx_conf "$domain" || return 1
            systemctl enable nginx >/dev/null 2>&1 || true
            systemctl start nginx 2>/dev/null || systemctl reload nginx
            # Jembatan SSH WS (wajib supaya /ssh-ws di port 80 & 443 benar-benar jalan).
            setup_ws_epro || true
            if ((${#STOPPED_SERVICES[@]} > 0)); then
                warn "Layanan lama berikut TETAP berhenti (portnya kini dipakai Nginx baru): ${STOPPED_SERVICES[*]}."
                warn "Itu sengaja — instalasi VPN lama tidak dihapus, hanya dimatikan supaya tidak bentrok."
            fi
        fi
    else
        install_reality || return 1
    fi

    setup_ufw "$mode"
    setup_cron_expired
    install_self
    # SSH UDP-HC (BadVPN 7100/7200/7300) + OHP (SSH 8181, Dropbear 8282) —
    # wajib supaya akun jalan di HTTP Custom; non-blocking bila gagal.
    setup_udp_forward || true
    setup_ohp || true
    apply_xray || return 1
    echo
    info "Instalasi selesai — mode: ${mode}"
    if [[ "$mode" == "domain" ]]; then
        info "Domain: ${domain} | WS: VMess $(state_get '.install.ws_paths.vmess'), VLESS $(state_get '.install.ws_paths.vless'), Trojan $(state_get '.install.ws_paths.trojan')"
    else
        info "REALITY: VLESS TCP 443 (SNI www.microsoft.com), VMess WS port 10001"
    fi
    info "Perintah: menu  (buka menu ini lagi kapan saja)  |  vps-manager --help  (non-interaktif)"
    if [[ "$mode" == "domain" ]]; then
        info "Link permanen script (tidak expired): https://${domain}/vps-manager.sh"
        info "Install di VPS lain: curl -fsSL https://${domain}/vps-manager.sh -o /usr/local/bin/vps-manager && chmod +x /usr/local/bin/vps-manager && vps-manager"
    fi
    echo
    do_check
}

# -----------------------------------------------------------------------------
# Helper akun
# -----------------------------------------------------------------------------
today_iso() { date '+%F'; }
expiry_iso() { # $1=jumlah hari (dari hari ini)
    date -d "+$1 days" '+%F'
}
expiry_plus() { # $1=tanggal dasar (YYYY-MM-DD) $2=hari tambahan
    date -d "$1 +$2 days" '+%F'
}
is_expired() { # $1=tanggal expiry — 0 bila sudah lewat
    [[ "$(date -d "$1" '+%s')" -lt "$(date -d "$(today_iso)" '+%s')" ]]
}

random_password() { # $1=panjang (default 12) — huruf+angka, tanpa karakter aneh
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c "${1:-12}"
}

gen_uuid() { # UUID v4 — uuidgen bila ada, fallback /proc (selalu ada di Linux)
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen
    elif [[ -r /proc/sys/kernel/random/uuid ]]; then
        cat /proc/sys/kernel/random/uuid
    else
        python3 -c "import uuid; print(uuid.uuid4())"
    fi
}

ask_days() {
    local d=""
    d=$(read_validated "Masa aktif (hari, 1-365): " valid_days "Hari harus angka 1-365.")
    printf '%s' "$d"
}

ask_name() { # $1=protokol — nama akun unik per protokol
    local proto="$1" name=""
    while true; do
        name=$(read_validated "Nama akun (huruf kecil, angka, _ , - ; min 3 karakter): " valid_username "Nama tidak valid.")
        if state_account_exists "$proto" "$name"; then
            error "Akun ${proto}/${name} sudah ada. Pilih nama lain."
        else
            printf '%s' "$name"
            return 0
        fi
    done
}

# -----------------------------------------------------------------------------
# Buat akun
# -----------------------------------------------------------------------------
create_ssh() {
    # $1=name (opsional) $2=days (opsional) $3=password (opsional)
    local name="${1:-}" days="${2:-}" password="${3:-}"
    [[ -z "$name" ]] && name=$(ask_name "ssh")
    if ! valid_username "$name"; then error "Nama SSH tidak valid: $name"; return 1; fi
    if state_account_exists "ssh" "$name"; then error "Akun SSH ${name} sudah ada."; return 1; fi
    if id "$name" >/dev/null 2>&1; then
        error "User Linux ${name} sudah ada di sistem. Pilih nama lain."
        return 1
    fi
    [[ -z "$days" ]] && days=$(ask_days)
    valid_days "$days" || { error "Hari tidak valid: $days"; return 1; }
    if [[ -z "$password" ]]; then
        if [[ -t 0 ]]; then
        read -r -s -p "Password (kosongkan = acak 12 karakter): " password; echo
        fi
        [[ -z "$password" ]] && password=$(random_password 12)
    fi
    if ((${#password} < 8)); then error "Password minimal 8 karakter."; return 1; fi
    local expiry
    expiry=$(expiry_iso "$days")
    # Buat user Linux: shell nologin (tidak bisa login shell interaktif),
    # tapi tetap bisa dipakai untuk tunnel/SSH. Password di-set via chpasswd.
    useradd -m -s /usr/sbin/nologin "$name"
    printf '%s:%s\n' "$name" "$password" | chpasswd
    chage -E "$expiry" "$name"
    local acc
    acc=$(jq -n --arg name "$name" --arg exp "$expiry" --arg now "$(today_iso)" \
        '{protocol:"ssh", name:$name, uuid:"", password:"", expiry:$exp,
          limit_ip:null, flow:"", transport:"", status:"active", created_at:$now}')
    state_add_account "$acc" || { userdel -r "$name" 2>/dev/null || true; error "Gagal menyimpan state — user Linux dihapus kembali."; return 1; }
    echo
    info "Akun SSH dibuat: ${name} (expired: ${expiry})"
    echo "  Username : ${name}"
    echo "  Password : ${password}   <-- simpan sekarang, password TIDAK disimpan di server"
    echo "  Expired  : ${expiry}"
    echo "  Login    : ssh ${name}@<IP-VPS>  (port 22)"
}

create_vmess() {
    # $1=name $2=days $3=limit_ip(opsional)
    local name="${1:-}" days="${2:-}" limit_ip="${3:-}"
    [[ -z "$name" ]] && name=$(ask_name "vmess")
    if ! valid_username "$name"; then error "Nama tidak valid: $name"; return 1; fi
    if state_account_exists "vmess" "$name"; then error "Akun VMess ${name} sudah ada."; return 1; fi
    [[ -z "$days" ]] && days=$(ask_days)
    valid_days "$days" || { error "Hari tidak valid: $days"; return 1; }
    if [[ -z "$limit_ip" ]] && [[ -t 0 ]]; then
        read -r -p "Limit IP (kosongkan = tanpa batas; dicatat saja, tidak ditegakkan Xray): " limit_ip
        [[ -n "$limit_ip" ]] && ! [[ "$limit_ip" =~ ^[0-9]+$ ]] && { error "Limit IP harus angka."; return 1; }
    fi
    local uuid expiry acc
    uuid=$(gen_uuid)
    expiry=$(expiry_iso "$days")
    acc=$(jq -n --arg name "$name" --arg uuid "$uuid" --arg exp "$expiry" --arg now "$(today_iso)" \
        --argjson lip "${limit_ip:-null}" \
        '{protocol:"vmess", name:$name, uuid:$uuid, password:"", expiry:$exp,
          limit_ip:$lip, flow:"", transport:"ws", status:"active", created_at:$now}')
    state_add_account "$acc"
    apply_xray || { state_del_account "vmess" "$name"; error "Gagal menerapkan config — akun dibatalkan."; return 1; }
    info "Akun VMess dibuat: ${name} (UUID: ${uuid}, expired: ${expiry})"
    show_link "vmess" "$name"
}

create_vless() {
    # $1=name $2=days $3=transport(ws|tcp, default ikut mode) $4=limit_ip
    local name="${1:-}" days="${2:-}" transport="${3:-}" limit_ip="${4:-}"
    local mode
    mode=$(state_get '.install.mode // ""')
    [[ -z "$name" ]] && name=$(ask_name "vless")
    if ! valid_username "$name"; then error "Nama tidak valid: $name"; return 1; fi
    if state_account_exists "vless" "$name"; then error "Akun VLESS ${name} sudah ada."; return 1; fi
    [[ -z "$days" ]] && days=$(ask_days)
    valid_days "$days" || { error "Hari tidak valid: $days"; return 1; }
    if [[ -z "$transport" ]]; then
        if [[ "$mode" == "reality" ]]; then transport="tcp"; else transport="ws"; fi
        if [[ -t 0 ]]; then
        read -r -p "Transport [ws/tcp] (default: ${transport}): " -r ans || true
        fi
        [[ -n "${ans:-}" ]] && transport="$ans"
    fi
    [[ "$transport" != "ws" && "$transport" != "tcp" ]] && { error "Transport harus ws atau tcp."; return 1; }
    if [[ -z "$limit_ip" ]] && [[ -t 0 ]]; then
        read -r -p "Limit IP (kosongkan = tanpa batas; dicatat saja): " limit_ip
        [[ -n "$limit_ip" ]] && ! [[ "$limit_ip" =~ ^[0-9]+$ ]] && { error "Limit IP harus angka."; return 1; }
    fi
    local uuid expiry acc flow
    uuid=$(gen_uuid)
    expiry=$(expiry_iso "$days")
    flow=""; [[ "$transport" == "tcp" ]] && flow="xtls-rprx-vision"
    acc=$(jq -n --arg name "$name" --arg uuid "$uuid" --arg exp "$expiry" --arg now "$(today_iso)" \
        --arg flow "$flow" --arg tr "$transport" --argjson lip "${limit_ip:-null}" \
        '{protocol:"vless", name:$name, uuid:$uuid, password:"", expiry:$exp,
          limit_ip:$lip, flow:$flow, transport:$tr, status:"active", created_at:$now}')
    state_add_account "$acc"
    apply_xray || { state_del_account "vless" "$name"; error "Gagal menerapkan config — akun dibatalkan."; return 1; }
    info "Akun VLESS dibuat: ${name} (UUID: ${uuid}, transport: ${transport}, expired: ${expiry})"
    show_link "vless" "$name"
}

create_trojan() {
    # $1=name $2=days $3=password(opsional)
    local name="${1:-}" days="${2:-}" password="${3:-}"
    [[ -z "$name" ]] && name=$(ask_name "trojan")
    if ! valid_username "$name"; then error "Nama tidak valid: $name"; return 1; fi
    if state_account_exists "trojan" "$name"; then error "Akun Trojan ${name} sudah ada."; return 1; fi
    [[ -z "$days" ]] && days=$(ask_days)
    valid_days "$days" || { error "Hari tidak valid: $days"; return 1; }
    if [[ -z "$password" ]]; then
        if [[ -t 0 ]]; then
        read -r -s -p "Password Trojan (kosongkan = acak kuat): " password; echo
        fi
        [[ -z "$password" ]] && password=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
    fi
    if ((${#password} < 8)); then error "Password minimal 8 karakter."; return 1; fi
    local expiry acc
    expiry=$(expiry_iso "$days")
    acc=$(jq -n --arg name "$name" --arg pw "$password" --arg exp "$expiry" --arg now "$(today_iso)" \
        '{protocol:"trojan", name:$name, uuid:"", password:$pw, expiry:$exp,
          limit_ip:null, flow:"", transport:"ws", status:"active", created_at:$now}')
    state_add_account "$acc"
    apply_xray || { state_del_account "trojan" "$name"; error "Gagal menerapkan config — akun dibatalkan."; return 1; }
    info "Akun Trojan dibuat: ${name} (expired: ${expiry})"
    show_link "trojan" "$name"
}

create_ss() {
    # $1=name $2=days $3=password(opsional) — Shadowsocks via Xray (WS /ss + gRPC).
    local name="${1:-}" days="${2:-}" password="${3:-}"
    [[ -z "$name" ]] && name=$(ask_name "ss")
    if ! valid_username "$name"; then error "Nama tidak valid: $name"; return 1; fi
    if state_account_exists "ss" "$name"; then error "Akun Shadowsocks ${name} sudah ada."; return 1; fi
    [[ -z "$days" ]] && days=$(ask_days)
    valid_days "$days" || { error "Hari tidak valid: $days"; return 1; }
    if [[ -z "$password" ]]; then
        if [[ -t 0 ]]; then
        read -r -s -p "Password Shadowsocks (kosongkan = acak kuat): " password; echo
        fi
        [[ -z "$password" ]] && password=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20)
    fi
    if ((${#password} < 8)); then error "Password minimal 8 karakter."; return 1; fi
    local expiry acc
    expiry=$(expiry_iso "$days")
    acc=$(jq -n --arg name "$name" --arg pw "$password" --arg exp "$expiry" --arg now "$(today_iso)" \
        '{protocol:"ss", name:$name, uuid:"", password:$pw, method:"aes-256-gcm", expiry:$exp,
          limit_ip:null, flow:"", transport:"ws", status:"active", created_at:$now}')
    state_add_account "$acc"
    apply_xray || { state_del_account "ss" "$name"; error "Gagal menerapkan config — akun dibatalkan."; return 1; }
    info "Akun Shadowsocks dibuat: ${name} (expired: ${expiry})"
    show_link "ss" "$name"
}

# -----------------------------------------------------------------------------
# Akun trial: akun sekali pakai untuk tes, 30 menit atau 1 jam, lalu dihapus
# otomatis (cron tiap 5 menit + saat list). Nama acak trial-xxxxxx, tanpa
# perlu isi nama/hari/password manual — sekali pilih langsung jadi + link.
# -----------------------------------------------------------------------------
create_account() { # $1=proto — panggil create_* interaktif (menu Buat Akun)
    case "$1" in
        ssh) create_ssh ;;
        vmess) create_vmess ;;
        vless) create_vless ;;
        trojan) create_trojan ;;
        ss) create_ss ;;
        *) error "Protokol tidak valid: $1"; return 1 ;;
    esac
}

create_trial() {
    # $1=proto $2=menit (30|60)
    local proto="${1:-}" minutes="${2:-}"
    case "$proto" in ssh|vmess|vless|trojan|ss) ;; *) error "Protokol trial tidak valid: $proto"; return 1 ;; esac
    case "$minutes" in 30|60) ;; *) error "Trial hanya 30 atau 60 menit."; return 1 ;; esac
    # Pastikan cron penghapus trial ada, tanpa harus install ulang (menu 1).
    setup_cron_expired
    # Nama trial acak (trial-xxxxxx), unik per protokol.
    local name="" tries=0
    while true; do
        name="trial-$(openssl rand -hex 3)"
        if ! state_account_exists "$proto" "$name"; then
            if [[ "$proto" != "ssh" ]] || ! id "$name" >/dev/null 2>&1; then
                break
            fi
        fi
        tries=$((tries+1))
        (( tries > 20 )) && { error "Gagal membuat nama trial unik."; return 1; }
    done
    local password=""
    case "$proto" in
        ssh) password=$(random_password 12) ;;
        trojan|ss) password=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | head -c 20) ;;
    esac
    # Buat akun 1 hari via create_* (stdin /dev/null agar prompt opsional
    # seperti Limit IP tidak muncul — trial harus sekali jadi).
    local created=0
    case "$proto" in
        ssh)    if create_ssh "$name" 1 "$password" </dev/null; then created=1; fi ;;
        vmess)  if create_vmess "$name" 1 "" </dev/null; then created=1; fi ;;
        vless)  if create_vless "$name" 1 "" "" </dev/null; then created=1; fi ;;
        trojan) if create_trojan "$name" 1 "$password" </dev/null; then created=1; fi ;;
        ss)     if create_ss "$name" 1 "$password" </dev/null; then created=1; fi ;;
    esac
    (( created == 1 )) || { error "Gagal membuat akun trial ${proto}."; return 1; }
    # Tandai sebagai trial: habis dalam X menit (epoch), expiry tanggal
    # dipangkas ke hari ini sebagai pengaman (cron harian akan menandainya
    # expired besok bila cron trial gagal).
    local until_epoch
    until_epoch=$(( $(date +%s) + minutes * 60 ))
    jq_state --arg p "$proto" --arg n "$name" --argjson until "$until_epoch" \
        --arg today "$(today_iso)" \
        '.accounts |= map(if .protocol==$p and .name==$n then .trial=true | .trial_until=$until | .expiry=$today else . end)' \
        || { error "Gagal menandai trial — akun ${name} jadi akun biasa 1 hari."; return 1; }
    echo
    info "TRIAL ${proto} dibuat: ${name} — aktif ${minutes} menit (sampai $(date -d "@${until_epoch}" '+%H:%M')), lalu dihapus otomatis."
}

check_trials_quiet() {
    # Hapus akun trial yang trial_until-nya sudah lewat. Untuk SSH, user
    # Linux-nya juga dihapus. Config Xray dibangun ulang bila ada yang dihapus.
    local now_epoch
    now_epoch=$(date +%s)
    local removed=0 need_xray=0
    local proto name
    while IFS=$'\t' read -r proto name; do
        if [[ "$proto" == "ssh" ]]; then
            if id "$name" >/dev/null 2>&1; then
                userdel -r "$name" 2>/dev/null || userdel "$name" 2>/dev/null || true
            fi
        else
            need_xray=1
        fi
        state_del_account "$proto" "$name"
        log "INFO" "Akun trial ${proto}/${name} habis — dihapus."
        removed=1
    done < <(jq -r --argjson now "$now_epoch" \
        '.accounts[] | select((.trial // false) == true and (.trial_until // 9999999999) < $now) | [.protocol, .name] | @tsv' "$STATE_FILE")
    if (( removed == 1 )) && (( need_xray == 1 )); then
        apply_xray || warn "Gagal menerapkan config setelah hapus trial."
    fi
}

check_trials() {
    info "Mengecek akun trial yang habis..."
    check_trials_quiet
    info "Selesai."
}

submenu_create() {
    # $1=proto $2=label — submenu Buat Akun: akun biasa atau Trial 30 mnt / 1 jam.
    local proto="$1" label="$2"
    while true; do
        echo "================= BUAT AKUN ${label} ================="
        echo "  1) Buat Akun (masa aktif hari)"
        echo "  2) Trial 30 menit"
        echo "  3) Trial 1 jam"
        echo "  0) Kembali"
        echo "----------------------------------------------------------"
        local pilih=""
        read -r -p "Pilih [0-3]: " pilih || return 0
        case "$pilih" in
            1) create_account "$proto"; return 0 ;;
            2) create_trial "$proto" 30; return 0 ;;
            3) create_trial "$proto" 60; return 0 ;;
            0) return 0 ;;
            *) error "Pilihan tidak valid: ${pilih}" ;;
        esac
    done
}


# -----------------------------------------------------------------------------
# List, hapus, perpanjang
# -----------------------------------------------------------------------------
list_accounts() {
    check_expired_quiet
    local total now_epoch
    now_epoch=$(date +%s)
    total=$(jq -r '.accounts | length' "$STATE_FILE")
    echo "================= DAFTAR AKUN (${total}) ================="
    printf '%-8s %-18s %-12s %-10s %-8s\n' "PROTOKOL" "NAMA" "EXPIRED" "STATUS" "LIMIT-IP"
    echo "----------------------------------------------------------"
    jq -r '.accounts | sort_by(.expiry)[] | [.protocol, .name, .expiry, .status, (.limit_ip // "-" | tostring), (.trial_until // 0)] | @tsv' "$STATE_FILE" \
        | while IFS=$'\t' read -r proto name exp status lip trial_until; do
            local mark=""
            if is_expired "$exp" && [[ "$status" == "active" ]]; then mark=" (LEWAT!)"; fi
            if [[ "$trial_until" != "0" && -n "$trial_until" ]]; then
                local remain=$(( (trial_until - now_epoch) / 60 ))
                (( remain < 0 )) && remain=0
                mark="${mark} (TRIAL, sisa ${remain} mnt)"
            fi
            printf '%-8s %-18s %-12s %-10s %-8s%s\n' "$proto" "$name" "$exp" "$status" "$lip" "$mark"
        done
    echo "----------------------------------------------------------"
    local expiring
    expiring=$(jq -r --arg today "$(today_iso)" --arg soon "$(date -d '+3 days' '+%F')" \
        '[.accounts[] | select(.status=="active" and .expiry >= $today and .expiry <= $soon)] | length' "$STATE_FILE")
    echo "Akun hampir expired (<=3 hari): ${expiring}"
}

select_account() {
    # Pilih akun dari daftar bernomor. Daftar dicetak ke STDERR, hasilnya
    # ("proto<TAB>name") ke STDOUT, agar pemanggil bisa menangkap hasilnya
    # via $(...) tanpa ikut menangkap daftarnya. Return 1 bila tidak ada
    # akun / batal (0) / nomor tidak valid.
    check_expired_quiet
    local total
    total=$(jq -r '.accounts | length' "$STATE_FILE" 2>/dev/null || echo 0)
    total=${total:-0}
    if [[ "$total" -eq 0 ]]; then
        info "Belum ada akun."
        return 1
    fi
    local -a protos names exps stats
    mapfile -t protos < <(jq -r '.accounts | sort_by(.expiry)[].protocol' "$STATE_FILE")
    mapfile -t names  < <(jq -r '.accounts | sort_by(.expiry)[].name' "$STATE_FILE")
    mapfile -t exps   < <(jq -r '.accounts | sort_by(.expiry)[].expiry' "$STATE_FILE")
    mapfile -t stats  < <(jq -r '.accounts | sort_by(.expiry)[].status' "$STATE_FILE")
    echo "================= PILIH AKUN (${total}) =================" >&2
    local i mark
    for i in "${!names[@]}"; do
        mark=""
        if is_expired "${exps[$i]}" && [[ "${stats[$i]}" == "active" ]]; then mark=" (LEWAT!)"; fi
        printf '%2d) %-8s %-18s %-12s %-10s%s\n' "$((i+1))" "${protos[$i]}" "${names[$i]}" "${exps[$i]}" "${stats[$i]}" "$mark" >&2
    done
    echo "----------------------------------------------------------" >&2
    local pilih
    read -r -p "Pilih nomor akun [1-${total}, 0 batal]: " pilih || return 1
    if [[ "$pilih" == "0" || -z "$pilih" ]]; then
        info "Dibatalkan."
        return 1
    fi
    if ! [[ "$pilih" =~ ^[0-9]+$ ]] || (( pilih < 1 || pilih > total )); then
        error "Nomor tidak valid: $pilih"
        return 1
    fi
    local idx=$((pilih-1))
    printf '%s\t%s\n' "${protos[$idx]}" "${names[$idx]}"
    return 0
}

delete_account() {
    # $1=protocol $2=name
    # Bila dipanggil dari menu (tanpa argumen): tampilkan daftar akun
    # bernomor, user tinggal tekan nomornya — tidak perlu ketik protokol +
    # nama manual. Jalur CLI (--delete --protocol X --name Y, dipakai bot)
    # tidak berubah.
    local proto="${1:-}" name="${2:-}"
    if [[ -z "$proto" || -z "$name" ]]; then
        if [[ ! -t 0 ]]; then
            error "Hapus akun butuh --protocol dan --name bila dijalankan non-interaktif."
            return 1
        fi
        local chosen
        chosen=$(select_account) || return 0
        proto=$(printf '%s' "$chosen" | cut -f1)
        name=$(printf '%s' "$chosen" | cut -f2)
    fi
    case "$proto" in ssh|vmess|vless|trojan|ss) ;; *) error "Protokol tidak valid: $proto"; return 1 ;; esac
    if ! state_account_exists "$proto" "$name"; then
        error "Akun ${proto}/${name} tidak ditemukan."
        return 1
    fi
    confirm_destructive "HAPUS akun ${proto}/${name} secara permanen?" || { info "Dibatalkan."; return 0; }
    if [[ "$proto" == "ssh" ]]; then
        if id "$name" >/dev/null 2>&1; then
            userdel -r "$name" 2>/dev/null || userdel "$name" 2>/dev/null || warn "userdel gagal — user ${name} mungkin masih login."
            info "User Linux ${name} dihapus."
        fi
    fi
    state_del_account "$proto" "$name"
    if [[ "$proto" != "ssh" ]]; then
        apply_xray || warn "Config Xray gagal diterapkan setelah hapus — cek manual."
    fi
    info "Akun ${proto}/${name} dihapus."
}

renew_account() {
    # $1=protocol $2=name $3=days
    local proto="${1:-}" name="${2:-}" days="${3:-}"
    if [[ -z "$proto" ]]; then read -r -p "Protokol (ssh/vmess/vless/trojan/ss): " proto; fi
    if [[ -z "$name" ]]; then read -r -p "Nama akun: " name; fi
    if [[ -z "$days" ]]; then days=$(ask_days); fi
    valid_days "$days" || { error "Hari tidak valid: $days"; return 1; }
    if ! state_account_exists "$proto" "$name"; then
        error "Akun ${proto}/${name} tidak ditemukan."
        return 1
    fi
    local cur_exp base new_exp
    cur_exp=$(jq -r --arg p "$proto" --arg n "$name" \
        '.accounts[] | select(.protocol==$p and .name==$n) | .expiry' "$STATE_FILE")
    # Basis: tanggal expiry lama bila masih di masa depan, bila tidak hari ini.
    if is_expired "$cur_exp"; then base=$(today_iso); else base="$cur_exp"; fi
    new_exp=$(expiry_plus "$base" "$days")
    state_set_field "$proto" "$name" "expiry" "$new_exp"
    state_set_field "$proto" "$name" "status" "active"
    # Bila yang diperpanjang adalah akun trial, jadikan akun biasa
    # (hapus penanda trial agar tidak ikut terhapus oleh cron trial).
    jq_state --arg p "$proto" --arg n "$name" \
        '.accounts |= map(if .protocol==$p and .name==$n then del(.trial, .trial_until) else . end)' || true
    if [[ "$proto" == "ssh" ]]; then
        chage -E "$new_exp" "$name" 2>/dev/null || warn "chage gagal untuk ${name} — cek user masih ada."
        # Buka kunci bila sebelumnya terkunci karena expired.
        usermod -U "$name" 2>/dev/null || true
    else
        apply_xray || warn "Config Xray gagal diterapkan setelah perpanjang — cek manual."
    fi
    info "Akun ${proto}/${name} diperpanjang: ${cur_exp} -> ${new_exp}"
}

# -----------------------------------------------------------------------------
# Cek expired: tandai akun lewat masa aktif sebagai expired (+ kunci user SSH).
# Dipanggil saat list & via cron harian. Versi quiet dipakai internal.
# -----------------------------------------------------------------------------
check_expired_quiet() {
    # Hapus dulu akun trial yang sudah habis (per-menit), baru cek expiry harian.
    check_trials_quiet
    local today
    today=$(today_iso)
    local changed=0
    local proto name exp
    while IFS=$'\t' read -r proto name exp; do
        if is_expired "$exp"; then
            jq_state --arg p "$proto" --arg n "$name" \
                '.accounts |= map(if .protocol==$p and .name==$n and .status=="active" then .status="expired" else . end)'
            if [[ "$proto" == "ssh" ]]; then
                usermod -L "$name" 2>/dev/null || true
            fi
            changed=1
        fi
    done < <(jq -r --arg t "$today" '.accounts[] | select(.status=="active" and .expiry < $t) | [.protocol, .name, .expiry] | @tsv' "$STATE_FILE")
    if (( changed == 1 )); then
        log "INFO" "Ada akun expired — config Xray dibangun ulang."
        apply_xray || warn "Gagal menerapkan config setelah cek expired."
    fi
}

check_expired() {
    info "Mengecek akun expired (hari ini: $(today_iso))..."
    check_expired_quiet
    info "Selesai. Lihat daftar dengan: vps-manager --list"
}

# -----------------------------------------------------------------------------
# Salin ke clipboard terminal via OSC 52 (Termius mendukung; di iPad perlu
# diaktifkan dulu: Settings -> Terminal -> Sequences -> OSC 52).
# -----------------------------------------------------------------------------
osc52_copy() { # $1=teks — salin ke clipboard terminal via OSC 52.
    # Hanya bila stdout adalah terminal interaktif: bila output ditangkap
    # (mis. bot Telegram), JANGAN kirim escape sequence agar teks tidak rusak.
    # Return 0 bila sequence dikirim, 1 bila tidak.
    [[ -n "${1:-}" ]] || return 1
    [[ -t 1 ]] || return 1
    local b64
    b64=$(printf '%s' "$1" | base64 -w0 2>/dev/null) || return 1
    [[ -n "$b64" ]] || return 1
    printf '\033]52;c;%s\a' "$b64"
    return 0
}

trial_expiry_display() { # $1=proto $2=name $3=expiry-tanggal — datetime trial bila trial, else tanggal.
    local proto="$1" name="$2" exp="$3"
    local until_epoch
    until_epoch=$(jq -r --arg p "$proto" --arg n "$name" '.accounts[] | select(.protocol==$p and .name==$n) | (.trial_until // 0)' "$STATE_FILE")
    if [[ "$until_epoch" != "0" && -n "$until_epoch" ]]; then
        date -d "@${until_epoch}" '+%F %T'
    else
        printf '%s' "$exp"
    fi
}

# -----------------------------------------------------------------------------
# Tampilkan link/config
# -----------------------------------------------------------------------------
show_link() {
    # $1=protocol $2=name
    local proto="${1:-}" name="${2:-}"
    if [[ -z "$proto" ]]; then
        if [[ -t 0 ]]; then read -r -p "Protokol (vmess/vless/trojan/ss/ssh): " proto;
        else error "Protokol wajib diisi (--protocol)."; return 1; fi
    fi
    if [[ -z "$name" ]]; then
        if [[ -t 0 ]]; then read -r -p "Nama akun: " name;
        else error "Nama akun wajib diisi (--name)."; return 1; fi
    fi
    if ! state_account_exists "$proto" "$name"; then
        error "Akun ${proto}/${name} tidak ditemukan."
        return 1
    fi
    local mode domain
    mode=$(state_get '.install.mode // ""')
    domain=$(state_get '.install.domain // ""')
    if [[ -z "$mode" ]]; then
        error "Belum terinstall (mode kosong). Jalankan menu 1 dulu."
        return 1
    fi
    # Alamat yang dipakai klien: domain bila mode domain, bila tidak IP publik VPS.
    local addr="$domain"
    if [[ "$mode" == "reality" ]]; then
        addr=$(curl -fsSL --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
    fi

    local link="" link_nontls="" link_grpc=""
    case "$proto" in
        ssh)
            local exp geo city isp exp_disp
            exp=$(jq -r --arg n "$name" '.accounts[] | select(.protocol=="ssh" and .name==$n) | .expiry' "$STATE_FILE")
            exp_disp=$(trial_expiry_display "ssh" "$name" "$exp")
            geo=$(server_geo); city="${geo%%|*}"; isp="${geo##*|}"
            echo "SSH - CEK AKUN"
            echo "----------------------------------------"
            echo "Remarks    : ${name}"
            echo "Domain     : ${addr}"
            echo "ISP        : ${isp}"
            echo "City       : ${city}"
            echo "Expired On : ${exp_disp}"
            echo "----------------------------------------"
            echo "CONFIG DETAILS"
            echo "Host       : ${addr}"
            echo "Port       : 22"
            echo "Username   : ${name}"
            echo "Password   : (sudah ditampilkan sekali saat dibuat — bila lupa, reset manual: passwd ${name})"
            echo "SSH WS     : ${addr}:80 dan ${addr}:443 (path /ssh-ws, via ws-epro)"
            echo "Perintah   : ssh ${name}@${addr}"
            echo "----------------------------------------"
            return 0
            ;;
        vmess)
            local uuid vmess_path
            uuid=$(jq -r --arg n "$name" '.accounts[] | select(.protocol=="vmess" and .name==$n) | .uuid' "$STATE_FILE")
            vmess_path=$(state_get '.install.ws_paths.vmess // "/vmess"')
            if [[ "$mode" == "domain" ]]; then
                local vmess_json vmess_json_nontls
                vmess_json=$(jq -n -c --arg ps "$name" --arg add "$addr" --arg id "$uuid" --arg path "$vmess_path" --arg host "$addr" \
                    '{v:"2", ps:$ps, add:$add, port:"443", id:$id, aid:"0", net:"ws", type:"none", host:$host, path:$path, tls:"tls", sni:$host}')
                link="vmess://$(printf '%s' "$vmess_json" | base64 -w0)"
                vmess_json_nontls=$(jq -n -c --arg ps "${name} (non-TLS 80)" --arg add "$addr" --arg id "$uuid" --arg path "$vmess_path" --arg host "$addr" \
                    '{v:"2", ps:$ps, add:$add, port:"80", id:$id, aid:"0", net:"ws", type:"none", host:$host, path:$path, tls:""}')
                link_nontls="vmess://$(printf '%s' "$vmess_json_nontls" | base64 -w0)"
                local vmess_json_grpc
                vmess_json_grpc=$(jq -n -c --arg ps "${name} (gRPC)" --arg add "$addr" --arg id "$uuid" --arg host "$addr" \
                    '{v:"2", ps:$ps, add:$add, port:"443", id:$id, aid:"0", net:"grpc", type:"none", host:$host, path:"vmess-grpc", tls:"tls", sni:$host}')
                link_grpc="vmess://$(printf '%s' "$vmess_json_grpc" | base64 -w0)"
            else
                local vmess_json
                vmess_json=$(jq -n -c --arg ps "$name" --arg add "$addr" --arg id "$uuid" --arg path "$vmess_path" \
                    '{v:"2", ps:$ps, add:$add, port:"10001", id:$id, aid:"0", net:"ws", type:"none", host:$add, path:$path, tls:""}')
                link="vmess://$(printf '%s' "$vmess_json" | base64 -w0)"
            fi
            ;;
        vless)
            local uuid transport flow pbk sid sni vless_path
            uuid=$(jq -r --arg n "$name" '.accounts[] | select(.protocol=="vless" and .name==$n) | .uuid' "$STATE_FILE")
            transport=$(jq -r --arg n "$name" '.accounts[] | select(.protocol=="vless" and .name==$n) | (.transport // "ws")' "$STATE_FILE")
            vless_path=$(state_get '.install.ws_paths.vless // "/vless"')
            if [[ "$transport" == "tcp" || "$mode" == "reality" ]]; then
                pbk=$(state_get '.install.reality.public_key // ""')
                sid=$(state_get '.install.reality.short_id // ""')
                sni=$(state_get '.install.reality.sni // "www.microsoft.com"')
                link="vless://${uuid}@${addr}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${sni}&fp=chrome&pbk=${pbk}&sid=${sid}&type=tcp#${name}"
            else
                link="vless://${uuid}@${addr}:443?encryption=none&security=tls&type=ws&host=${addr}&path=${vless_path}#${name}"
                link_nontls="vless://${uuid}@${addr}:80?encryption=none&security=none&type=ws&host=${addr}&path=${vless_path}#${name}-nontls"
                link_grpc="vless://${uuid}@${addr}:443?encryption=none&security=tls&type=grpc&serviceName=vless-grpc&sni=${addr}#${name}-grpc"
            fi
            ;;
        trojan)
            local pw trojan_path
            pw=$(jq -r --arg n "$name" '.accounts[] | select(.protocol=="trojan" and .name==$n) | .password' "$STATE_FILE")
            trojan_path=$(state_get '.install.ws_paths.trojan // "/trojan"')
            if [[ "$mode" == "domain" ]]; then
                link="trojan://${pw}@${addr}:443?security=tls&type=ws&host=${addr}&path=${trojan_path}#${name}"
                link_nontls="trojan://${pw}@${addr}:80?security=none&type=ws&host=${addr}&path=${trojan_path}#${name}-nontls"
                link_grpc="trojan://${pw}@${addr}:443?security=tls&type=grpc&serviceName=trojan-grpc&sni=${addr}#${name}-grpc"
            else
                # Mode reality: Trojan lewat WS 10003 tanpa TLS (port dibuka UFW bila perlu).
                link="trojan://${pw}@${addr}:10003?security=none&type=ws&path=${trojan_path}#${name}"
            fi
            ;;
        ss)
            local pw method ss_b64
            pw=$(jq -r --arg n "$name" '.accounts[] | select(.protocol=="ss" and .name==$n) | .password' "$STATE_FILE")
            method=$(jq -r --arg n "$name" '.accounts[] | select(.protocol=="ss" and .name==$n) | (.method // "aes-256-gcm")' "$STATE_FILE")
            if [[ "$mode" == "domain" ]]; then
                ss_b64=$(printf '%s' "${method}:${pw}@${addr}:443" | base64 -w0 | tr '+/' '-_' | tr -d '=')
                link="ss://${ss_b64}/?plugin=v2ray-plugin%3Btls%3Bhost%3D${addr}%3Bpath%3D%2Fss#${name}"
                ss_b64=$(printf '%s' "${method}:${pw}@${addr}:80" | base64 -w0 | tr '+/' '-_' | tr -d '=')
                link_nontls="ss://${ss_b64}/?plugin=v2ray-plugin%3Bhost%3D${addr}%3Bpath%3D%2Fss#${name}-nontls"
                ss_b64=$(printf '%s' "${method}:${pw}@${addr}:443" | base64 -w0 | tr '+/' '-_' | tr -d '=')
                link_grpc="ss://${ss_b64}/?plugin=v2ray-plugin%3Btls%3Bmode%3Dgrpc%3BserviceName%3Dss-grpc%3Bhost%3D${addr}#${name}-grpc"
            else
                # Mode reality: SS lewat WS 10007 tanpa TLS (port dibuka UFW bila perlu).
                ss_b64=$(printf '%s' "${method}:${pw}@${addr}:10007" | base64 -w0 | tr '+/' '-_' | tr -d '=')
                link="ss://${ss_b64}/?plugin=v2ray-plugin%3Bhost%3D${addr}%3Bpath%3D%2Fss#${name}"
            fi
            ;;

        *)
            error "Protokol tidak dikenal: $proto"
            return 1
            ;;
    esac

    # ---- Tampilan CEK AKUN (format simpel, seperti referensi) ----
    local exp geo city isp exp_disp proto_label link_label_main
    exp=$(jq -r --arg p "$proto" --arg n "$name" '.accounts[] | select(.protocol==$p and .name==$n) | .expiry' "$STATE_FILE")
    exp_disp=$(trial_expiry_display "$proto" "$name" "$exp")
    geo=$(server_geo); city="${geo%%|*}"; isp="${geo##*|}"
    proto_label="${proto^^}"
    [[ "$proto" == "ss" ]] && proto_label="SHADOWSOCKS"
    echo "${proto_label} - CEK AKUN"
    echo "----------------------------------------"
    echo "Remarks    : ${name}"
    echo "Domain     : ${addr}"
    echo "ISP        : ${isp}"
    echo "City       : ${city}"
    echo "Expired On : ${exp_disp}"
    echo "----------------------------------------"
    echo "CONFIG DETAILS"
    case "$proto" in
        vmess)
            echo "Port TLS   : 443"
            echo "Port NTLS  : 80"
            echo "UUID       : ${uuid}"
            echo "AlterId    : 0"
            echo "Security   : auto"
            echo "Network    : ws, grpc"
            echo "Path WS    : ${vmess_path}"
            echo "Serv.Name  : vmess-grpc"
            ;;
        vless)
            if [[ "$transport" == "tcp" || "$mode" == "reality" ]]; then
                echo "Port       : 443"
                echo "UUID       : ${uuid}"
                echo "Flow       : xtls-rprx-vision"
                echo "Security   : reality"
                echo "Network    : tcp"
                echo "SNI        : ${sni}"
            else
                echo "Port TLS   : 443"
                echo "Port NTLS  : 80"
                echo "UUID       : ${uuid}"
                echo "Security   : tls"
                echo "Network    : ws, grpc"
                echo "Path WS    : ${vless_path}"
                echo "Serv.Name  : vless-grpc"
            fi
            ;;
        trojan)
            echo "Port TLS   : 443"
            echo "Port NTLS  : 80"
            echo "Password   : ${pw}"
            echo "Security   : tls"
            echo "Network    : ws, grpc"
            echo "Path WS    : ${trojan_path}"
            echo "Serv.Name  : trojan-grpc"
            ;;
        ss)
            echo "Port TLS   : 443"
            echo "Port NTLS  : 80"
            echo "Password   : ${pw}"
            echo "Method     : ${method}"
            echo "Network    : ws, grpc"
            echo "Path WS    : /ss"
            echo "Serv.Name  : ss-grpc"
            ;;
    esac
    echo "----------------------------------------"
    link_label_main="LINK ${proto_label} WS TLS"
    if [[ "$proto" == "vless" ]] && { [[ "$transport" == "tcp" ]] || [[ "$mode" == "reality" ]]; }; then
        link_label_main="LINK VLESS REALITY"
    elif [[ "$mode" != "domain" ]]; then
        link_label_main="LINK ${proto_label} WS"
    fi
    echo "${link_label_main}"
    echo "$link"
    if osc52_copy "$link"; then
        echo "(Link di atas sudah disalin ke clipboard — tinggal paste di aplikasi VPN.)"
    fi
    if [[ -n "$link_nontls" ]]; then
        echo
        echo "LINK ${proto_label} WS NO TLS"
        echo "$link_nontls"
    fi
    if [[ -n "$link_grpc" ]]; then
        echo
        echo "LINK ${proto_label} GRPC"
        echo "$link_grpc"
    fi
    echo "----------------------------------------"
}

# -----------------------------------------------------------------------------
# Uninstall bersih
# -----------------------------------------------------------------------------
do_uninstall() {
    echo "================= UNINSTALL BERSIH ================="
    echo "Yang akan dihapus:"
    echo "  - Service & config Xray (${XRAY_CONFIG})"
    echo "  - Config Nginx vps-manager (${NGINX_CONF})"
    echo "  - State akun (${STATE_DIR}) dan cron (${CRON_FILE})"
    echo "  - User SSH yang tercatat di state.json (HANYA itu)"
    echo "  - Bot Telegram (service vps-bot, ${BOT_DIR}, ${BOT_CONF})"
    echo "Yang TIDAK dihapus: OpenSSH port 22, user root, user sistem (UID<1000)."
    confirm_destructive "Yakin uninstall SEMUA di atas?" || { info "Dibatalkan."; return 0; }

    local keep_log="N"
    read -r -p "Pertahankan file log ${LOG_FILE}? [Y/n]: " keep_log
    [[ -z "$keep_log" ]] && keep_log="Y"

    # Hapus user SSH yang dibuat panel (hanya yang tercatat di state + UID>=1000).
    local ssh_users
    ssh_users=$(jq -r '.accounts[] | select(.protocol=="ssh") | .name' "$STATE_FILE" 2>/dev/null || true)
    local u uid
    for u in $ssh_users; do
        if id "$u" >/dev/null 2>&1; then
            uid=$(id -u "$u")
            if (( uid >= 1000 )) && [[ "$u" != "root" ]]; then
                userdel -r "$u" 2>/dev/null || userdel "$u" 2>/dev/null || warn "Gagal menghapus user ${u}."
                info "User SSH dihapus: ${u}"
            fi
        fi
    done

    systemctl stop xray 2>/dev/null || true
    systemctl disable xray 2>/dev/null || true
    systemctl stop ws-epro 2>/dev/null || true
    systemctl disable ws-epro 2>/dev/null || true
    rm -f /etc/systemd/system/ws-epro.service
    rm -rf /opt/ws-epro
    systemctl stop vps-udp ohp-ssh ohp-dropbear 2>/dev/null || true
    systemctl disable vps-udp ohp-ssh ohp-dropbear 2>/dev/null || true
    rm -f /etc/systemd/system/vps-udp.service /etc/systemd/system/ohp-ssh.service /etc/systemd/system/ohp-dropbear.service
    rm -rf /opt/vps-tunnel
    systemctl stop vps-bot 2>/dev/null || true
    systemctl disable vps-bot 2>/dev/null || true
    rm -f "$BOT_UNIT" "$BOT_CONF"
    rm -rf "$BOT_DIR"
    systemctl daemon-reload 2>/dev/null || true
    rm -f "$XRAY_CONFIG" "$NGINX_CONF" "$CRON_FILE" "$INSTALL_BIN" /usr/local/bin/menu
    rm -rf "$STATE_DIR" /var/log/xray
    if systemctl is-active --quiet nginx; then
        nginx -t && systemctl reload nginx || warn "Nginx gagal reload setelah hapus conf."
    fi
    if [[ "${keep_log^^}" == "Y" ]]; then
        log "INFO" "Uninstall selesai (log dipertahankan)."
    else
        rm -f "$LOG_FILE"
    fi
    info "Uninstall selesai. Hapus file script ini secara manual bila sudah tidak perlu."
}


# -----------------------------------------------------------------------------
# Bot Telegram — kelola akun dari Telegram (menu 11).
# Bot (Python stdlib saja, long polling) hanya menjawab ADMIN_CHAT_ID dan
# menjalankan CLI `vps-manager` yang sama dengan menu terminal, jadi akun
# yang dibuat dari Telegram sama persis dengan dari menu.
# Token didapat dari @BotFather, Chat ID dari @userinfobot / @getmyid_bot.
# -----------------------------------------------------------------------------
setup_bot() {
    # $1=token (opsional) $2=admin chat id (opsional) — bila kosong ditanya.
    local token="${1:-}" admin_id="${2:-}"
    if [[ -z "$token" ]]; then
        echo "Buat bot dulu di Telegram: chat @BotFather -> /newbot -> salin tokennya."
        echo "Chat ID kamu: chat @userinfobot atau @getmyid_bot di Telegram."
        read -r -s -p "Token bot Telegram: " token; echo
    fi
    if [[ -z "$admin_id" ]]; then
        read -r -p "Admin Chat ID (angka): " admin_id
    fi
    if ! [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]]; then
        error "Token tidak valid (format: angka:huruf, contoh 123456:ABC-DEF...)."
        return 1
    fi
    if ! [[ "$admin_id" =~ ^[0-9]+$ ]]; then
        error "Admin Chat ID harus angka."
        return 1
    fi
    mkdir -p "$BOT_DIR" "$STATE_DIR"
    cat > "${BOT_DIR}/bot.py" <<'PYEOF'
#!/usr/bin/env python3
"""Bot Telegram untuk vps-manager.

Kelola akun SSH / VMess / VLESS / Trojan dari Telegram. Bot ini TIDAK
mendua logika: semua aksi dijalankan lewat CLI `vps-manager` (yang sama
dengan menu terminal), jadi akun yang dibuat dari Telegram sama persis
dengan yang dibuat dari menu.

Hanya menjawab ADMIN_CHAT_ID yang dikonfigurasi di bot.conf. Jalankan
sebagai root (butuh useradd / tulis state / restart Xray).

Perintah:
  /start, /menu  - tampilkan menu tombol
  /list          - daftar semua akun + status expired
  /status        - cek rantai Nginx -> Xray -> path WS
  /create        - buat akun (tanya protokol, nama, hari)
  /show          - tampilkan link/config akun
  /delete        - hapus akun (dengan konfirmasi)
  /renew         - perpanjang masa aktif akun
  /cancel        - batalkan percakapan yang sedang berjalan
"""

import json
import logging
import os
import random
import re
import string
import subprocess
import sys
import time
import urllib.error
import urllib.request

BOT_CONF = os.environ.get("VPS_BOT_CONF", "/etc/vps-manager/bot.conf")
VPS_MANAGER = os.environ.get("VPS_MANAGER_BIN", "/usr/local/bin/vps-manager")

PROTOCOLS = ("ssh", "vmess", "vless", "trojan", "ss")
USERNAME_RE = re.compile(r"^[a-z_][a-z0-9_-]{2,31}$")
ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")

MAIN_KEYBOARD = {
    "keyboard": [
        ["Buat Akun", "List Akun"],
        ["Link Akun", "Hapus Akun"],
        ["Perpanjang", "Status VPS"],
        ["Batal"],
    ],
    "resize_keyboard": True,
}
PROTO_KEYBOARD = {
    "keyboard": [["SSH", "VMess"], ["VLESS", "Trojan"], ["Shadowsocks", "Batal"]],
    "resize_keyboard": True,
}
CONFIRM_KEYBOARD = {
    "keyboard": [["Ya, Hapus", "Batal"]],
    "resize_keyboard": True,
}

logging.basicConfig(
    level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s"
)


def load_conf(path=BOT_CONF):
    """Baca bot.conf (format KEY=VALUE)."""
    conf = {}
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            conf[key.strip()] = val.strip().strip('"').strip("'")
    token = conf.get("BOT_TOKEN", "")
    admin = conf.get("ADMIN_CHAT_ID", "")
    if not token or not admin.isdigit():
        raise SystemExit(
            "bot.conf tidak valid: isi BOT_TOKEN dan ADMIN_CHAT_ID "
            "(angka). Jalankan menu 11 > Instal Bot di vps-manager."
        )
    return token, int(admin)


def api(token, method, params=None, timeout=30):
    """Panggil Bot API Telegram, kembalikan dict hasil (atau None)."""
    url = "https://api.telegram.org/bot%s/%s" % (token, method)
    data = json.dumps(params or {}).encode("utf-8")
    req = urllib.request.Request(
        url, data=data, headers={"Content-Type": "application/json"}
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        try:
            body = json.loads(e.read().decode("utf-8"))
        except Exception:
            body = {}
        logging.error("Telegram %s gagal HTTP %s: %s", method, e.code, body)
        return None
    except Exception as e:
        logging.error("Telegram %s gagal: %s", method, e)
        return None
    if not body.get("ok"):
        logging.error("Telegram %s: %s", method, body)
        return None
    return body.get("result")


def html_escape(text):
    return (text.replace("&", "&amp;")
                .replace("<", "&lt;")
                .replace(">", "&gt;"))


def send(token, chat_id, text, keyboard=None, code=False):
    """Kirim pesan (potong per 4000 karakter, Telegram maks 4096).
    code=True: tampilkan sebagai blok monospace (<pre>) supaya format
    CEK AKUN yang rata kolomnya tetap rapi di Telegram (font Telegram
    biasa proporsional, kolomnya jadi tidak sejajar)."""
    text = text or "(tidak ada output)"
    step = 3900 if code else 4000
    for i in range(0, len(text), step):
        chunk = text[i : i + step]
        params = {"chat_id": chat_id, "text": chunk}
        if code:
            params["text"] = "<pre>%s</pre>" % html_escape(chunk)
            params["parse_mode"] = "HTML"
        if keyboard is not None and i == 0:
            params["reply_markup"] = keyboard
        api(token, "sendMessage", params, timeout=15)


def strip_ansi(text):
    return ANSI_RE.sub("", text or "")


def run_cli(args, timeout=180):
    """Jalankan `vps-manager ...`, kembalikan output bersih (tanpa ANSI)."""
    try:
        proc = subprocess.run(
            [VPS_MANAGER] + args,
            # stdin selalu /dev/null: CLI tidak boleh menggantung menunggu
            # input (prompt apa pun langsung EOF), dan prompt yang tidak
            # terjaga TTY tidak akan memblokir bot sampai timeout 180 detik.
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return "Perintah timeout (>%s detik)." % timeout
    except Exception as e:
        return "Gagal menjalankan vps-manager: %s" % e
    out = strip_ansi((proc.stdout or "") + (proc.stderr or "")).strip()
    return out or "(perintah selesai tanpa output)"


def random_password(n=12):
    alphabet = string.ascii_letters + string.digits
    return "".join(random.choice(alphabet) for _ in range(n))


def cmd_create(session):
    """Jalankan pembuatan akun dari data percakapan."""
    proto = session["data"]["proto"]
    name = session["data"]["name"]
    days = session["data"]["days"]
    # Catatan: CLI memakai bentuk `--create <protokol>` (posisi), BUKAN
    # `--create --protocol <protokol>` — bentuk kedua membuat proto terisi
    # "--protocol" dan CLI menolaknya.
    args = ["--create", proto, "--name", name, "--days", days]
    if proto == "ssh":
        # CLI meminta password bila kosong — beri acak supaya tidak menggantung.
        args += ["--password", random_password(12)]
    return run_cli(args)


def cmd_show(session):
    return run_cli(
        ["--show", "--protocol", session["data"]["proto"],
         "--name", session["data"]["name"]]
    )


def cmd_delete(session):
    return run_cli(
        ["--delete", "--protocol", session["data"]["proto"],
         "--name", session["data"]["name"], "--yes"]
    )


def cmd_renew(session):
    return run_cli(
        ["--renew", "--protocol", session["data"]["proto"],
         "--name", session["data"]["name"], "--days", session["data"]["days"]]
    )


# Peta langkah percakapan: (prompt berikutnya, keyboard berikutnya)
# Tiap langkah menyimpan jawaban ke session["data"][field].
STEPS = {
    "create": [
        ("proto", "Pilih protokol akun yang dibuat:", PROTO_KEYBOARD),
        ("name", "Nama akun? (huruf kecil, 3-32 karakter, contoh: aku)", None),
        ("days", "Masa aktif berapa hari? (1-365, ketik 0 untuk 30 hari)", None),
    ],
    "show": [
        ("proto", "Link akun protokol apa?", PROTO_KEYBOARD),
        ("name", "Nama akunnya?", None),
    ],
    "delete": [
        ("proto", "Hapus akun protokol apa?", PROTO_KEYBOARD),
        ("name", "Nama akunnya?", None),
        ("confirm", "Yakin hapus akun ini secara permanen?", CONFIRM_KEYBOARD),
    ],
    "renew": [
        ("proto", "Perpanjang akun protokol apa?", PROTO_KEYBOARD),
        ("name", "Nama akunnya?", None),
        ("days", "Tambah berapa hari? (1-365)", None),
    ],
}

FINISH = {"create": cmd_create, "show": cmd_show,
          "delete": cmd_delete, "renew": cmd_renew}

MENU_TEXT = (
    "VPS MANAGER — Bot Telegram\n"
    "Kelola akun SSH / VMess / VLESS / Trojan.\n\n"
    "Buat Akun — buat akun baru\n"
    "List Akun — daftar semua akun + expired\n"
    "Link Akun — tampilkan link/config akun\n"
    "Hapus Akun — hapus akun (konfirmasi dulu)\n"
    "Perpanjang — tambah masa aktif akun\n"
    "Status VPS — cek Nginx, Xray, dan path WS"
)


def valid_name(name):
    return bool(USERNAME_RE.match(name or ""))


def valid_days(days):
    return days.isdigit() and 1 <= int(days) <= 365


def handle_message(token, admin_id, sessions, msg):
    """Tangani satu pesan masuk. Kembalikan None (balasan dikirim langsung)."""
    chat = msg.get("chat", {})
    chat_id = chat.get("id")
    text = (msg.get("text") or "").strip()
    if chat_id is None or not text:
        return
    if chat_id != admin_id:
        send(token, chat_id, "Bot ini hanya untuk admin VPS.")
        logging.warning("pesan ditolak dari chat %s", chat_id)
        return

    session = sessions.get(chat_id)

    # Batal kapan saja.
    if text in ("/cancel", "Batal"):
        sessions.pop(chat_id, None)
        send(token, chat_id, "Dibatalkan.", MAIN_KEYBOARD)
        return

    # Perintah langsung (tanpa percakapan).
    if text in ("/start", "/menu"):
        sessions.pop(chat_id, None)
        send(token, chat_id, MENU_TEXT, MAIN_KEYBOARD)
        return
    if text == "/list":
        sessions.pop(chat_id, None)
        send(token, chat_id, run_cli(["--list"]), MAIN_KEYBOARD, code=True)
        return
    if text == "/status":
        sessions.pop(chat_id, None)
        send(token, chat_id, run_cli(["--check"]), MAIN_KEYBOARD, code=True)
        return

    # Tombol menu utama -> mulai percakapan.
    start = {
        "Buat Akun": "create", "/create": "create",
        "Link Akun": "show", "/show": "show",
        "Hapus Akun": "delete", "/delete": "delete",
        "Perpanjang": "renew", "/renew": "renew",
        "List Akun": None, "Status VPS": None,
    }
    if text in start and session is None:
        if text == "List Akun":
            send(token, chat_id, run_cli(["--list"]), MAIN_KEYBOARD, code=True)
            return
        if text == "Status VPS":
            send(token, chat_id, run_cli(["--check"]), MAIN_KEYBOARD, code=True)
            return
        kind = start[text]
        sessions[chat_id] = {"kind": kind, "step": 0, "data": {}}
        field, prompt, kb = STEPS[kind][0]
        send(token, chat_id, prompt, kb)
        return

    # Lanjutkan percakapan yang sedang berjalan.
    if session is not None:
        kind = session["kind"]
        steps = STEPS[kind]
        idx = session["step"]
        field, _, _ = steps[idx]
        value = text

        if field == "proto":
            value = value.lower()
            if value == "shadowsocks": value = "ss"
            if value not in PROTOCOLS:
                send(token, chat_id,
                     "Protokol tidak dikenal. Pilih: SSH, VMess, VLESS, Trojan, Shadowsocks.",
                     PROTO_KEYBOARD)
                return
        elif field == "name":
            if not valid_name(value):
                send(token, chat_id,
                     "Nama tidak valid (huruf kecil, 3-32 karakter, "
                     "diawali huruf/underscore). Coba lagi.")
                return
        elif field == "days":
            # Telegram tidak bisa kirim pesan kosong — 0 berarti default 30 hari.
            if value in ("0", "-", "default") and kind == "create":
                value = "30"
            if not valid_days(value):
                send(token, chat_id,
                     "Hari harus angka 1-365. Coba lagi.")
                return
        elif field == "confirm":
            if value not in ("Ya, Hapus",):
                sessions.pop(chat_id, None)
                send(token, chat_id, "Penghapusan dibatalkan.",
                     MAIN_KEYBOARD)
                return
            value = "ya"

        session["data"][field] = value
        session["step"] = idx + 1
        if session["step"] < len(steps):
            _, prompt, kb = steps[session["step"]]
            send(token, chat_id, prompt, kb)
            return
        # Selesai: jalankan aksi.
        sessions.pop(chat_id, None)
        result = FINISH[kind](session)
        send(token, chat_id, result, MAIN_KEYBOARD, code=True)
        return

    # Tidak dikenal -> tampilkan menu.
    send(token, chat_id, MENU_TEXT, MAIN_KEYBOARD)


def main():
    token, admin_id = load_conf()
    # Validasi token di awal supaya penyebab "bot diam" langsung ketahuan
    # di log: username bot (cek kamu chat ke bot yang benar) atau 401.
    me = api(token, "getMe", timeout=15)
    if me:
        logging.info("bot jalan sebagai @%s (id %s), admin chat %s",
                     me.get("username"), me.get("id"), admin_id)
    else:
        logging.warning("getMe gagal — token mungkin salah atau jaringan "
                        "bermasalah; tetap mencoba polling.")
    logging.info("bot jalan (admin chat %s)", admin_id)
    sessions = {}
    offset = None
    while True:
        params = {"timeout": 30}
        if offset is not None:
            params["offset"] = offset
        updates = api(token, "getUpdates", params, timeout=35)
        if updates is None:
            time.sleep(5)
            continue
        for upd in updates:
            offset = upd["update_id"] + 1
            msg = upd.get("message")
            if msg:
                try:
                    handle_message(token, admin_id, sessions, msg)
                except Exception:
                    logging.exception("gagal menangani pesan")


if __name__ == "__main__":
    main()
PYEOF
    chmod +x "${BOT_DIR}/bot.py"
    python3 -m py_compile "${BOT_DIR}/bot.py" || { error "bot.py gagal dicek sintaks."; return 1; }
    printf 'BOT_TOKEN=%s\nADMIN_CHAT_ID=%s\n' "$token" "$admin_id" > "$BOT_CONF"
    chmod 600 "$BOT_CONF"
    cat > "$BOT_UNIT" <<'EOF'
[Unit]
Description=Bot Telegram vps-manager
After=network.target xray.service
[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/vps-bot/bot.py
Restart=on-failure
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload 2>/dev/null || true
    systemctl enable vps-bot 2>/dev/null || true
    systemctl restart vps-bot 2>/dev/null || systemctl start vps-bot 2>/dev/null || warn "Bot gagal start — cek: systemctl status vps-bot"
    sleep 2
    if systemctl is-active --quiet vps-bot 2>/dev/null; then
        info "Bot Telegram BERJALAN. Buka Telegram dan kirim /start ke bot kamu."
    else
        warn "Bot belum aktif — cek token/Chat ID lalu: systemctl status vps-bot"
        warn "Pastikan token dari @BotFather benar dan Chat ID angka (cek di @userinfobot)."
    fi
    echo "Perintah bot: /start /list /status /create /show /delete /renew /cancel"
}

bot_status() {
    if systemctl is-active --quiet vps-bot 2>/dev/null; then echo "ON"; else echo "OFF"; fi
}


# -----------------------------------------------------------------------------
# Diagnosa Bot Telegram (menu 11 > 05, atau: vps-manager --bot-check).
# Penyebab "bot tidak ada respon" yang paling sering, berurutan:
#   1. token salah / sudah diganti (getMe -> 401),
#   2. VPS tidak bisa mencapai api.telegram.org (DNS/internet),
#   3. chat dari akun/chat ID yang berbeda dari ADMIN_CHAT_ID,
#   4. belum /start ke bot yang benar, atau bot diblokir (sendMessage -> 403),
#   5. service crash-loop (config tidak valid).
# Token TIDAK pernah ditampilkan utuh (hanya 6 karakter awal + 4 akhir).
# -----------------------------------------------------------------------------
bot_check() {
    echo "=== Diagnosa Bot Telegram ==="
    echo "--- 0. Versi bot & CLI + proses ganda ---"
    if [[ -f "$BOT_DIR/bot.py" ]]; then
        if grep -q "stdin=subprocess.DEVNULL" "$BOT_DIR/bot.py" 2>/dev/null; then
            info "File bot (/opt/vps-bot/bot.py) VERSI TERBARU."
        else
            error "File bot MASIH VERSI LAMA — install ulang bot: menu 11 > 01 (isi token + Chat ID yang sama)."
            echo "  (File bot hanya diperbarui saat instal ulang; update script saja tidak cukup.)"
        fi
    else
        error "File bot tidak ada — install dulu (menu 11 > 01)."
    fi
    local qr_cmd="qrencode -t ANSI""UTF8"
    if grep -qF "$qr_cmd" "$INSTALL_BIN" 2>/dev/null; then
        error "Script vps-manager MASIH VERSI LAMA (masih ada QR) — unduh versi terbaru dari GitHub dulu."
    else
        info "Script vps-manager sudah versi terbaru (tanpa QR)."
    fi
    local nproc
    nproc=$(pgrep -fc "/opt/vps-bot/bot.py" 2>/dev/null || true)
    nproc=${nproc:-0}
    if (( nproc > 1 )); then
        error "Ada $nproc proses bot.py berjalan — dua bot berebut pesan Telegram!"
        echo "  Matikan yang zombie: pkill -f bot.py ; lalu menu 11 > 02 (restart bot)."
    elif (( nproc == 1 )); then
        info "Proses bot.py: 1 (normal)."
    else
        warn "Tidak ada proses bot.py berjalan."
    fi
    echo "--- 1. Service vps-bot ---"
    local st
    st=$(systemctl is-active vps-bot 2>/dev/null || true)
    if systemctl is-active --quiet vps-bot 2>/dev/null; then
        info "Service vps-bot AKTIF."
    else
        warn "Service vps-bot TIDAK aktif (status: $st)."
    fi
    echo "  Log 15 baris terakhir (journalctl -u vps-bot):"
    journalctl -u vps-bot -n 15 --no-pager 2>/dev/null | sed 's/^/  /' || echo "  (tidak ada log)"
    echo "--- 2. Config ${BOT_CONF} ---"
    if [[ ! -f "$BOT_CONF" ]]; then
        error "bot.conf tidak ada — install dulu (menu 11 > 01)."
        return 0
    fi
    local token admin
    token=$(grep '^BOT_TOKEN=' "$BOT_CONF" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
    admin=$(grep '^ADMIN_CHAT_ID=' "$BOT_CONF" 2>/dev/null | cut -d= -f2- | tr -d '[:space:]')
    if [[ -z "$token" ]]; then
        error "BOT_TOKEN kosong di bot.conf — install ulang (menu 11 > 01)."
        return 0
    fi
    if [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]]; then
        info "Format token OK: ${token:0:6}...${token: -4}"
    else
        error "Format token ANEH: ${token:0:6}... (harusnya angka:huruf-panjang) — ambil token baru dari @BotFather."
    fi
    if [[ "$admin" =~ ^[0-9]+$ ]]; then
        info "ADMIN_CHAT_ID: $admin"
    else
        error "ADMIN_CHAT_ID tidak valid ('$admin') — harus angka dari @userinfobot. Install ulang (menu 11 > 01)."
        return 0
    fi
    echo "--- 3. Token dicek ke Telegram (getMe) ---"
    local resp code body username botid
    resp=$(curl -s --max-time 15 -w "\n%{http_code}" "https://api.telegram.org/bot${token}/getMe" 2>/dev/null || printf '\n000')
    code=$(printf '%s' "$resp" | tail -n 1)
    body=$(printf '%s' "$resp" | sed '$d')
    if [[ "$code" == "200" ]]; then
        username=$(printf '%s' "$body" | jq -r '.result.username // ""' 2>/dev/null)
        botid=$(printf '%s' "$body" | jq -r '.result.id // ""' 2>/dev/null)
        info "Token VALID — bot: @${username:-?} (id ${botid:-?})."
        echo "  Pastikan kamu chat ke bot @$username ini (bukan bot lain), lalu kirim /start."
    elif [[ "$code" == "401" ]]; then
        error "TOKEN SALAH (401 Unauthorized) — token ini ditolak Telegram."
        echo "  Ambil token baru: chat @BotFather > /mybots > pilih bot > API Token."
        echo "  Lalu install ulang: menu 11 > 01 (isi token baru + chat ID yang sama)."
        return 0
    elif [[ "$code" == "000" ]]; then
        error "VPS TIDAK BISA mencapai api.telegram.org (koneksi gagal/timeout)."
        echo "  Cek internet/DNS VPS: Features 9 (ganti DNS ke 1.1.1.1) lalu ulangi diagnosa."
        return 0
    else
        error "getMe gagal (HTTP $code): $body"
        return 0
    fi
    echo "--- 4. Pesan masuk terakhir (getUpdates) ---"
    local upd n last_chat last_text
    upd=$(curl -s --max-time 15 "https://api.telegram.org/bot${token}/getUpdates?timeout=5" 2>/dev/null || true)
    n=$(printf '%s' "$upd" | jq -r '.result | length' 2>/dev/null || echo "?")
    last_chat=$(printf '%s' "$upd" | jq -r '.result[-1].message.chat.id // empty' 2>/dev/null || true)
    last_text=$(printf '%s' "$upd" | jq -r '.result[-1].message.text // empty' 2>/dev/null || true)
    if [[ "$n" == "0" ]]; then
        warn "Belum ada pesan masuk ke bot sama sekali."
        echo "  Buka Telegram, cari @${username}, kirim /start, lalu ulangi diagnosa."
    elif [[ -n "$last_chat" && "$last_chat" != "$admin" ]]; then
        error "Pesan terakhir datang dari chat ID $last_chat, tapi bot hanya menjawab $admin."
        echo "  Penyebabnya: kamu chat dari akun/chat yang berbeda, atau ADMIN_CHAT_ID salah ketik."
        echo "  Pesan terakhir: '${last_text:-?}'"
        echo "  Ambil ID yang benar: chat @userinfobot dari akun yang sama, lalu install ulang (menu 11 > 01)."
    elif [[ -n "$last_chat" ]]; then
        info "Pesanmu sudah sampai ke bot (chat ID $admin cocok, terakhir: '${last_text:-?}')."
        echo "  Kalau bot tetap diam, restart bot (menu 11 > 02) lalu ulangi diagnosa."
    else
        warn "getUpdates tidak mengembalikan pesan (n=$n)."
    fi
    echo "--- 5. Kirim pesan tes ---"
    local ans sent
    read -r -p "Kirim pesan tes ke chat admin ($admin)? [y/N]: " ans
    if [[ ${ans:-} =~ ^[Yy]$ ]]; then
        sent=$(curl -s --max-time 15 -X POST "https://api.telegram.org/bot${token}/sendMessage" -d "chat_id=${admin}" --data-urlencode "text=Bot vps-manager aktif - ini pesan tes." 2>/dev/null || true)
        if grep -q '"ok":true' <<< "$sent"; then
            info "Pesan tes TERKIRIM — cek Telegram kamu sekarang."
        elif grep -q '403' <<< "$sent"; then
            error "Pesan tes DITOLAK (403): bot diblokir, atau kamu belum pernah /start ke bot ini."
            echo "  Buka @${username}, tekan START, lalu ulangi diagnosa."
        elif grep -q '400' <<< "$sent"; then
            error "Pesan tes gagal (400): chat ID $admin tidak ditemukan Telegram."
            echo "  Ambil ID yang benar dari @userinfobot lalu install ulang (menu 11 > 01)."
        else
            error "Pesan tes gagal: $sent"
        fi
    else
        info "Pesan tes dilewati."
    fi
    echo "--- 6. Tes buat akun (jalur yang sama seperti bot) ---"
    local ans2 out code
    read -r -p "Jalankan tes buat akun VMess 'bottest' (1 hari, lalu dihapus)? [y/N]: " ans2
    if [[ ${ans2:-} =~ ^[Yy]$ ]]; then
        echo "  Menjalankan: vps-manager --create vmess --name bottest --days 1"
        code=0
        out=$("$INSTALL_BIN" --create vmess --name bottest --days 1 </dev/null 2>&1) || code=$?
        if (( code == 0 )); then
            info "Tes buat akun BERHASIL (exit 0) — CLI bisa membuat akun."
            echo "  Kalau bot tetap tidak menampilkan hasil, masalahnya ada di bot (lihat langkah 0-5 di atas)."
            printf '%s\n' "$out" | grep -a "vmess://" | head -n 2 | sed 's/^/  /'
        else
            error "Tes buat akun GAGAL (exit $code) — inilah penyebab bot tidak menampilkan hasil:"
            printf '%s\n' "$out" | tail -n 15 | sed 's/^/  /'
            echo "  Periksa Xray: journalctl -u xray -n 20 ; atau menu 12 > 14 (Fixx Xray)."
        fi
        # Bersihkan akun tes (bila sempat dibuat).
        "$INSTALL_BIN" --delete --protocol vmess --name bottest --yes </dev/null >/dev/null 2>&1 || true
        info "Akun tes 'bottest' dibersihkan."
    else
        info "Tes buat akun dilewati."
    fi
}

submenu_bot() {
    while true; do
        echo "================= BOT TELEGRAM =================="
        echo "  Status Bot : [$(bot_status)]"
        echo "  Config     : ${BOT_CONF}  (token + admin chat id)"
        echo "  Service    : vps-bot.service  |  File: ${BOT_DIR}/bot.py"
        echo
        echo "  [01] Instal / Update Bot (isi token + admin chat id)"
        echo "  [02] Restart Bot"
        echo "  [03] Stop Bot"
        echo "  [04] Hapus Bot"
        echo "  [05] Diagnosa Bot (kenapa tidak respon)"
        echo "  [b]  Back"
        echo "  [x]  EXIT"
        echo
        local pil=""
        read -r -p "Pilih [1-5/b/x]: " pil
        case "$pil" in
            1) setup_bot || warn "Instal bot tidak selesai." ;;
            2) systemctl restart vps-bot 2>/dev/null && info "Bot di-restart: $(bot_status)" || warn "Restart gagal." ;;
            3) systemctl stop vps-bot 2>/dev/null && info "Bot di-stop." || warn "Stop gagal." ;;
            4)
                if confirm_destructive "HAPUS bot Telegram (service + file + config)?"; then
                    systemctl stop vps-bot 2>/dev/null || true
                    systemctl disable vps-bot 2>/dev/null || true
                    rm -f "$BOT_UNIT" "$BOT_CONF"
                    rm -rf "$BOT_DIR"
                    systemctl daemon-reload 2>/dev/null || true
                    info "Bot dihapus."
                else
                    info "Dibatalkan."
                fi
                ;;
            5) bot_check || warn "Diagnosa bot gagal." ;;
            b|B) return 0 ;;
            x|X) echo "Sampai jumpa!"; exit 0 ;;
            *) error "Pilihan tidak valid: ${pil}" ;;
        esac
        echo
        read -r -p "Tekan Enter untuk lanjut..." -r _
    done
}

# -----------------------------------------------------------------------------
# Menu interaktif
# -----------------------------------------------------------------------------
# -----------------------------------------------------------------------------
# Tampilan menu — gaya kotak info seperti screenshot referensi (banner, info
# server, traffic, status, menu 2 kolom). Semua nilai best-effort: bila
# vnstat / ipinfo tidak ada, tampilkan "-" supaya menu tetap jalan.
# -----------------------------------------------------------------------------
fmt_bytes() { # $1=byte -> "1.17 TiB" / "610.91 GiB" / "585 B"
    local b=${1:-0}
    if (( b >= 1099511627776 )); then awk -v v="$b" 'BEGIN{printf "%.2f TiB", v/1099511627776}';
    elif (( b >= 1073741824 )); then awk -v v="$b" 'BEGIN{printf "%.2f GiB", v/1073741824}';
    elif (( b >= 1048576 )); then awk -v v="$b" 'BEGIN{printf "%.2f MiB", v/1048576}';
    elif (( b >= 1024 )); then awk -v v="$b" 'BEGIN{printf "%.2f KiB", v/1024}';
    else printf '%s B' "$b"; fi
}

uptime_str() { # "3 hours, 56 minutes" / "2 days, 1 hours, 5 minutes"
    local s d h m
    s=$(awk '{print int($1)}' /proc/uptime 2>/dev/null || echo 0)
    d=$((s/86400)); h=$((s%86400/3600)); m=$((s%3600/60))
    if (( d > 0 )); then printf '%d days, %d hours, %d minutes' "$d" "$h" "$m";
    elif (( h > 0 )); then printf '%d hours, %d minutes' "$h" "$m";
    else printf '%d minutes' "$m"; fi
}

main_iface() {
    local i
    i=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for(n=1;n<=NF;n++) if ($n=="dev") print $(n+1)}' | head -n 1)
    [[ -z "$i" ]] && i=$(ls /sys/class/net 2>/dev/null | grep -v '^lo$' | head -n 1)
    printf '%s' "${i:-eth0}"
}

cached_public_ip() { # IP publik (cache di state, deteksi sekali bila kosong)
    local ip
    ip=$(state_get '.install.ip // ""')
    if [[ -z "$ip" ]]; then
        ip=$(detect_public_ip 2>/dev/null || true)
        [[ -n "$ip" ]] && jq_state --arg v "$ip" '.install.ip = $v' 2>/dev/null || true
    fi
    printf '%s' "${ip:-—}"
}

server_geo() { # cetak "CITY|ISP" (cache di state .server, fetch sekali via ipinfo.io)
    local city isp js
    city=$(state_get '.server.city // ""')
    isp=$(state_get '.server.isp // ""')
    if [[ -z "$city" || -z "$isp" ]]; then
        js=$(curl -fsSL --max-time 3 https://ipinfo.io/json 2>/dev/null || true)
        if [[ -n "$js" ]]; then
            city=$(printf '%s' "$js" | jq -r '.city // ""' 2>/dev/null)
            isp=$(printf '%s' "$js" | jq -r '.org // ""' 2>/dev/null)
            [[ -n "$city" ]] && jq_state --arg c "$city" '.server.city = $c' 2>/dev/null || true
            [[ -n "$isp" ]] && jq_state --arg i "$isp" '.server.isp = $i' 2>/dev/null || true
        fi
    fi
    printf '%s|%s' "${city:-—}" "${isp:-—}"
}

traffic_speed() { # kecepatan gabungan down+up selama 1 detik, "585.62 kbit/s"
    local iface r1 t1 r2 t2
    iface=$(main_iface)
    r1=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)
    t1=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)
    sleep 1
    r2=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)
    t2=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)
    awk -v r="$((r2-r1))" -v t="$((t2-t1))" 'BEGIN{printf "%.2f kbit/s", (r+t)*8/1000}'
}

traffic_lines() { # cetak MONTH/RX/TX/DAY/RX/TX/TRAFFIC (vnstat bila ada, else total boot)
    local iface mrx mtx drx dtx rx tx
    iface=$(main_iface)
    if command -v vnstat >/dev/null 2>&1; then
        mrx=$(vnstat --json m 2>/dev/null | jq -r --arg i "$iface" '.interfaces[] | select(.id==$i) | .traffic.months[-1].rx // 0')
        mtx=$(vnstat --json m 2>/dev/null | jq -r --arg i "$iface" '.interfaces[] | select(.id==$i) | .traffic.months[-1].tx // 0')
        drx=$(vnstat --json d 2>/dev/null | jq -r --arg i "$iface" '.interfaces[] | select(.id==$i) | .traffic.days[-1].rx // 0')
        dtx=$(vnstat --json d 2>/dev/null | jq -r --arg i "$iface" '.interfaces[] | select(.id==$i) | .traffic.days[-1].tx // 0')
        [[ "$mrx" =~ ^[0-9]+$ ]] || mrx=0
        [[ "$mtx" =~ ^[0-9]+$ ]] || mtx=0
        [[ "$drx" =~ ^[0-9]+$ ]] || drx=0
        [[ "$dtx" =~ ^[0-9]+$ ]] || dtx=0
        printf '  MONTH  : %s\n' "$(fmt_bytes "$((mrx+mtx))")"
        printf '  RX     : %s\n' "$(fmt_bytes "$mrx")"
        printf '  TX     : %s\n' "$(fmt_bytes "$mtx")"
        printf '  DAY    : %s\n' "$(fmt_bytes "$((drx+dtx))")"
        printf '  RX     : %s\n' "$(fmt_bytes "$drx")"
        printf '  TX     : %s\n' "$(fmt_bytes "$dtx")"
    else
        rx=$(cat "/sys/class/net/$iface/statistics/rx_bytes" 2>/dev/null || echo 0)
        tx=$(cat "/sys/class/net/$iface/statistics/tx_bytes" 2>/dev/null || echo 0)
        printf '  TOTAL  : %s (sejak boot)\n' "$(fmt_bytes "$((rx+tx))")"
        printf '  RX     : %s\n' "$(fmt_bytes "$rx")"
        printf '  TX     : %s\n' "$(fmt_bytes "$tx")"
        printf '  DAY    : — (pasang vnstat: apt install vnstat)\n'
        printf '  RX     : —\n'
        printf '  TX     : —\n'
    fi
    printf '  TRAFFIC: %s\n' "$(traffic_speed)"
}

# -----------------------------------------------------------------------------
# FEATURES (menu 12) — submenu seperti screenshot referensi: Running Service,
# Restart, Auto Reboot, Monitoring, SpeedTest, Delete Expired, MENU FIXX
# (Banner/Domain/DNS/Haproxy/Nginx/WS ePRO/Domain/Xray), MENU CLEAR,
# INFORMATION, OTHER (Anti-DDoS, Script Lain, Limit Speed, XRAY On/Off,
# Boster CPU). Semua aksi best-effort dan jujur: layanan yang memang tidak
# terpasang di script ini (mis. HAProxy) dilaporkan, bukan dipalsukan.
# -----------------------------------------------------------------------------
feat_pause() { read -r -p "Tekan Enter untuk kembali ke menu Features..." -r _; }

# --- helper pengecekan untuk Running Service (systemctl + ss + pgrep) ---
# PENTING: tangkap output ss dulu baru grep. `ss | grep -q` di bawah
# `set -o pipefail` rawan SIGPIPE: grep -q keluar begitu ketemu, ss mati
# dengan 141, pipeline ikut gagal — port yang sebenarnya LISTEN jadi
# dilaporkan OFF secara acak (terbukti 12/200 kali di uji). Itu penyebab
# "banyak yang off" di Running Service padahal layanan jalan.
port_tcp() { local out; out=$(ss -tln 2>/dev/null); grep -q ":$1 " <<< "$out"; }
port_udp() { local out; out=$(ss -uln 2>/dev/null); grep -q ":$1 " <<< "$out"; }
svc_active() { local u; for u in "$@"; do systemctl is-active --quiet "$u" 2>/dev/null && return 0; done; return 1; }
proc_on() { pgrep -qf "$1" 2>/dev/null; }
# xray_inbound <protokol> <network>: true bila config Xray punya inbound itu
xray_inbound() {
    [[ -f "$XRAY_CONFIG" ]] || return 1
    python3 -c 'import json,sys
try:
    c=json.load(open(sys.argv[3]))
except Exception:
    sys.exit(1)
ok=any(i.get("protocol")==sys.argv[1] and i.get("streamSettings",{}).get("network")==sys.argv[2] for i in c.get("inbounds",[]))
sys.exit(0 if ok else 1)' "$1" "$2" "$XRAY_CONFIG" 2>/dev/null
}
chk_ssh_tun() { svc_active ssh sshd && port_tcp 22; }
chk_ssh_udp() { proc_on udp-custom || port_udp 7100 || port_udp 7200 || port_udp 7300; }
chk_ovpn_ssl() { svc_active openvpn-server@ssl openvpn@ssl || proc_on 'openvpn.*ssl'; }
chk_ovpn_wsssl() { svc_active openvpn-server@ws-ssl openvpn@ws-ssl || proc_on 'openvpn.*ws'; }
chk_ovpn_udp() { port_udp 1194; }
chk_ovpn_tcp() { port_tcp 1194; }
chk_ohp_ssh() { proc_on 'ohp.*ssh' || port_tcp 8181; }
chk_ohp_dropbear() { proc_on 'ohp.*dropbear' || port_tcp 8282; }
chk_ohp_ovpn() { proc_on 'ohp.*openvpn'; }
chk_wsepro() { svc_active ws-epro && port_tcp 10090; }
chk_badvpn7100() { port_udp 7100; }
chk_badvpn7200() { port_udp 7200; }
chk_badvpn7300() { port_udp 7300; }
chk_dropbear() { svc_active dropbear && { port_tcp 109 || port_tcp 143; }; }
chk_haproxy() { port_tcp 8880; }
chk_crons() { svc_active cron crond; }
chk_nginx() { svc_active nginx && port_tcp 443; }
chk_xray_vmess_tls() { svc_active xray && xray_inbound vmess ws && port_tcp 443; }
chk_xray_vmess_nontls() { svc_active xray && xray_inbound vmess ws && port_tcp 80; }
chk_xray_vmess_grpc() { svc_active xray && xray_inbound vmess grpc; }
chk_xray_vless_tls() { svc_active xray && xray_inbound vless ws && port_tcp 443; }
chk_xray_vless_nontls() { svc_active xray && xray_inbound vless ws && port_tcp 80; }
chk_xray_vless_grpc() { svc_active xray && xray_inbound vless grpc; }
chk_xray_trojan_ws() { svc_active xray && xray_inbound trojan ws && port_tcp 443; }
chk_xray_trojan_nonws() { svc_active xray && xray_inbound trojan ws && port_tcp 80; }
chk_xray_trojan_grpc() { svc_active xray && xray_inbound trojan grpc; }
chk_xray_ss_ws() { svc_active xray && xray_inbound shadowsocks ws && port_tcp 443; }
chk_xray_ss_nonws() { svc_active xray && xray_inbound shadowsocks ws && port_tcp 80; }
chk_xray_ss_grpc() { svc_active xray && xray_inbound shadowsocks grpc; }
# svc_line <label> <fungsi-cek>: satu baris "| Service <nama> = [ON]/[OFF]"
svc_line() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        printf ' | Service %-25s = %b[ON]%b\n' "$label" "$C_GREEN" "$C_RESET"
    else
        RS_OFF_COUNT=$(( ${RS_OFF_COUNT:-0} + 1 ))
        printf ' | Service %-25s = %b[OFF]%b\n' "$label" "$C_RED" "$C_RESET"
    fi
}
feat_running_service() {
    local noprompt=0
    [[ "${1:-}" == "noprompt" ]] && noprompt=1
    RS_OFF_COUNT=0
    echo "=== Running Service ==="
    svc_line "SSH / TUN" chk_ssh_tun
    svc_line "SSH UDP-HC" chk_ssh_udp
    svc_line "OpenVPN SSL" chk_ovpn_ssl
    svc_line "OpenVPN WS-SSL" chk_ovpn_wsssl
    svc_line "OpenVPN UDP" chk_ovpn_udp
    svc_line "OpenVPN TCP" chk_ovpn_tcp
    svc_line "OHP SSH" chk_ohp_ssh
    svc_line "OHP Dropbear" chk_ohp_dropbear
    svc_line "OHP OpenVPN" chk_ohp_ovpn
    svc_line "WS ePRO" chk_wsepro
    svc_line "BadVPN 7100" chk_badvpn7100
    svc_line "BadVPN 7200" chk_badvpn7200
    svc_line "BadVPN 7300" chk_badvpn7300
    svc_line "Dropbear" chk_dropbear
    svc_line "Haproxy" chk_haproxy
    svc_line "Crons" chk_crons
    svc_line "Nginx Webserver" chk_nginx
    svc_line "Xray Vmess WS TLS" chk_xray_vmess_tls
    svc_line "Xray Vmess WS Non TLS" chk_xray_vmess_nontls
    svc_line "Xray Vmess gRPC" chk_xray_vmess_grpc
    svc_line "Xray Vless WS TLS" chk_xray_vless_tls
    svc_line "Xray Vless WS Non TLS" chk_xray_vless_nontls
    svc_line "Xray Vless gRPC" chk_xray_vless_grpc
    svc_line "Xray Trojan WS" chk_xray_trojan_ws
    svc_line "Xray Trojan Non WS" chk_xray_trojan_nonws
    svc_line "Xray Trojan gRPC" chk_xray_trojan_grpc
    svc_line "Xray Shadowsocks WS" chk_xray_ss_ws
    svc_line "Xray Shadowsocks Non WS" chk_xray_ss_nonws
    svc_line "Xray Shadowsocks gRPC" chk_xray_ss_grpc
    echo
    if svc_active xray && svc_active nginx; then
        info "SIAP DIGUNAKAN — Xray + Nginx jalan."
    else
        warn "Ada layanan mati — pakai 2.) Restart Service atau 13.)/14.) Fixx."
    fi
    if (( RS_OFF_COUNT > 0 )) && (( noprompt == 0 )) && [[ -t 0 ]]; then
        echo
        echo "Ada ${RS_OFF_COUNT} layanan OFF di atas."
        local ans=""
        read -r -p "Perbaiki semua yang OFF sekarang? [y/N]: " ans || true
        if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
            feat_fix_all_services
        fi
    fi
}

feat_restart_service() {
    echo "=== Restart Service ==="
    systemctl restart xray 2>/dev/null || warn "restart xray gagal"
    systemctl restart nginx 2>/dev/null || warn "restart nginx gagal"
    systemctl restart ws-epro 2>/dev/null || warn "restart ws-epro gagal"
    systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
    sleep 2
    feat_running_service
}

feat_auto_reboot() {
    echo "=== Auto Reboot ==="
    local cur
    cur=$(crontab -l 2>/dev/null | grep -F "/sbin/reboot" | head -n 1 || true)
    echo "Cron reboot saat ini: ${cur:-tidak ada}"
    echo "  1) Atur reboot harian (pilih jam)"
    echo "  2) Hapus auto reboot"
    echo "  0) Batal"
    local p jam menit
    read -r -p "Pilih [0-2]: " p
    case "$p" in
        1)
            read -r -p "Jam reboot (0-23): " jam
            read -r -p "Menit (0-59, kosong=0): " menit
            [[ -z "$menit" ]] && menit=0
            if [[ "$jam" =~ ^[0-9]+$ ]] && (( jam >= 0 && jam <= 23 )) && [[ "$menit" =~ ^[0-9]+$ ]] && (( menit >= 0 && menit <= 59 )); then
                (crontab -l 2>/dev/null | grep -vF "/sbin/reboot"; echo "$menit $jam * * * /sbin/reboot # auto-reboot-vps-manager") | crontab -
                info "Auto reboot diatur tiap hari jam $jam:$menit."
            else
                error "Jam/menit tidak valid."
            fi
            ;;
        2)
            (crontab -l 2>/dev/null | grep -vF "/sbin/reboot") | crontab -
            info "Auto reboot dihapus."
            ;;
        *) info "Dibatalkan." ;;
    esac
}

feat_monitoring() {
    echo "=== Monitoring ==="
    echo "--- Uptime & Load ---"
    uptime
    echo "--- RAM ---"
    free -h
    echo "--- Disk ---"
    df -h / /root 2>/dev/null
    echo "--- Traffic ---"
    traffic_lines
    echo "--- 10 proses CPU teratas ---"
    ps -eo pid,ppid,%cpu,%mem,comm --sort=-%cpu 2>/dev/null | head -n 12
}

feat_speedtest() {
    echo "=== SpeedTest ==="
    if command -v speedtest-cli >/dev/null 2>&1; then
        speedtest-cli --simple 2>&1 || warn "speedtest-cli gagal."
    else
        info "speedtest-cli belum ada — tes unduh 10 MB dari Cloudflare:"
        local t0 t1 dt
        t0=$(date +%s%N)
        if curl -fsSL -o /dev/null --max-time 30 https://speed.cloudflare.com/__down?bytes=10000000 2>/dev/null; then
            t1=$(date +%s%N)
            dt=$(( (t1 - t0) / 1000000 ))
            awk -v ms="$dt" 'BEGIN{printf "  10 MB dalam %.2f detik = %.2f Mbit/s\n", ms/1000, 80/(ms/1000)}'
        else
            error "Tes unduh gagal (cek internet VPS)."
        fi
    fi
}

feat_delete_expired() {
    echo "=== Delete All Account Exp ==="
    check_expired
    list_accounts
}

feat_change_banner() {
    echo "=== Change Banner ==="
    echo "Banner sekarang (bila ada):"
    cat /etc/ssh/banner.txt 2>/dev/null || echo "  (belum ada)"
    echo "Ketik teks banner baru (kosongkan = hapus banner), lalu Enter:"
    local teks
    read -r -p "Banner: " teks
    if [[ -z "$teks" ]]; then
        rm -f /etc/ssh/banner.txt
        sed -i '/^Banner /d' /etc/ssh/sshd_config 2>/dev/null || true
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        info "Banner dihapus."
        return 0
    fi
    printf '%s\n' "$teks" > /etc/ssh/banner.txt
    if grep -q '^Banner ' /etc/ssh/sshd_config 2>/dev/null; then
        sed -i 's|^Banner .*|Banner /etc/ssh/banner.txt|' /etc/ssh/sshd_config
    elif grep -q '^#Banner ' /etc/ssh/sshd_config 2>/dev/null; then
        sed -i 's|^#Banner .*|Banner /etc/ssh/banner.txt|' /etc/ssh/sshd_config
    else
        echo "Banner /etc/ssh/banner.txt" >> /etc/ssh/sshd_config
    fi
    if sshd -t 2>/dev/null; then
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        info "Banner diganti."
    else
        error "sshd -t gagal — banner tidak diterapkan."
    fi
}

feat_change_domain() {
    echo "=== Change Domain ==="
    local cur_domain email new_domain resolved vps_ip
    cur_domain=$(state_get '.install.domain // ""')
    email=$(state_get '.install.email // ""')
    echo "Domain sekarang: ${cur_domain:-—}"
    read -r -p "Domain baru: " new_domain
    [[ -z "$new_domain" ]] && { error "Domain kosong."; return 1; }
    [[ "$new_domain" =~ ^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || { error "Format domain tidak valid."; return 1; }
    vps_ip=$(detect_public_ip || true)
    resolved=$(getent hosts "$new_domain" | awk '{print $1}' | head -n 1 || true)
    info "Domain $new_domain resolve ke: ${resolved:-TIDAK RESOLVE}"
    info "IP publik VPS: ${vps_ip:-tidak terdeteksi}"
    if [[ -n "$resolved" && -n "$vps_ip" && "$resolved" != "$vps_ip" ]]; then
        warn "A record belum mengarah ke VPS ini — sertifikat kemungkinan gagal. Lanjutkan tetap?"
        read -r -p "Lanjut? [y/N]: " REPLY
        [[ ${REPLY:-} =~ ^[Yy]$ ]] || { info "Dibatalkan."; return 1; }
    fi
    jq_state --arg d "$new_domain" '.install.domain = $d' || return 1
    [[ -n "$vps_ip" ]] && jq_state --arg v "$vps_ip" '.install.ip = $v' 2>/dev/null || true
    if ! issue_cert "$new_domain" "$email"; then
        error "Sertifikat gagal — domain di state sudah diganti, tapi Nginx/Xray masih pakai sertifikat lama."
        return 1
    fi
    backup_config
    write_nginx_conf "$new_domain"
    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx
    else
        error "nginx -t gagal — cek /etc/nginx/conf.d/vps-manager.conf"
        return 1
    fi
    apply_xray || { error "Xray gagal start dengan domain baru."; show_xray_failure; return 1; }
    systemctl restart ws-epro 2>/dev/null || true
    info "Domain diganti ke $new_domain."
}

feat_change_dns() {
    echo "=== Change DNS Server ==="
    echo "DNS di /etc/resolv.conf sekarang:"
    grep -E '^nameserver' /etc/resolv.conf 2>/dev/null || echo "  (tidak ada)"
    echo "  1) 1.1.1.1 + 8.8.8.8 (Cloudflare + Google)"
    echo "  2) 8.8.8.8 + 8.8.4.4 (Google)"
    echo "  3) Custom (ketik sendiri)"
    echo "  0) Batal"
    local p ns1 ns2
    read -r -p "Pilih [0-3]: " p
    case "$p" in
        1) ns1=1.1.1.1; ns2=8.8.8.8 ;;
        2) ns1=8.8.8.8; ns2=8.8.4.4 ;;
        3) read -r -p "DNS utama: " ns1; read -r -p "DNS kedua (boleh kosong): " ns2 ;;
        *) info "Dibatalkan."; return 0 ;;
    esac
    [[ "$ns1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { error "DNS tidak valid."; return 1; }
    printf 'nameserver %s\n' "$ns1" > /etc/resolv.conf
    [[ -n "$ns2" ]] && printf 'nameserver %s\n' "$ns2" >> /etc/resolv.conf
    info "DNS diganti. Tes resolve: $(getent hosts archive.ubuntu.com | head -n 1 || echo GAGAL)"
}

write_haproxy_conf() {
    # Config HAProxy multiport untuk stack vps-manager saat ini:
    # frontend http-in listen di port yang sama seperti HAProxy ARISCTUNNEL
    # (55, 8080, 8880, 2082, 2086, 2095 + rentang 222-1000), kecuali 80/443
    # yang tetap dipegang Nginx (link lama tetap jalan).
    # PENTING: rentang ditulis 222-442 + 444-1000 (BUKAN 222-1000), karena
    # 443 ada di dalam 222-1000 dan dipegang Nginx — HAProxy yang mencoba
    # bind 443 akan gagal total ("cannot bind socket", exit 1) dan tetap OFF
    # meski Fixx Haproxy diulang berkali-kali (terbukti di uji 27 Nov 2026).
    # backend langsung ke inbound Xray (VMess 10001, VLESS 10002, Trojan 10003)
    # dan ws-epro (SSH-WS 10090); https-in 9444 diteruskan ke Nginx :443.
    # Pola yang sama seperti menu lama v1.9.0 (terbukti jalan di VPS ini),
    # hanya port backend yang disesuaikan dengan vps-manager.
    mkdir -p /etc/haproxy
    [[ -f /etc/haproxy/haproxy.cfg ]] && cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.bak.$(date '+%Y%m%d-%H%M') 2>/dev/null || true
    cat > /etc/haproxy/haproxy.cfg <<'HAPROXYEOF'
global
    log /dev/log local0
    maxconn 1024
    # maxconn 1024 (bukan 4096): HAProxy butuh ~2*maxconn + jumlah listener
    # (~790, karena rentang 222-442 + 444-1000) FD. Dengan 4096 butuh ~9005 FD
    # dan service gagal start bila batas FD sistem hanya 4096 ("Cannot raise
    # FD limit", tanpa error bind — persis laporan 27 Nov 2026). Dengan 1024
    # butuh ~2900 FD, muat bahkan di batas 4096; untuk VPN pribadi (beberapa
    # akun) 1024 koneksi bersamaan sudah sangat longgar.

defaults
    log global
    mode http
    timeout connect 5s
    timeout client 30s
    timeout server 30s

frontend http-in
    bind *:8880
    bind *:8080
    bind *:2082
    bind *:2086
    bind *:2095
    bind *:55
    bind *:222-442
    bind *:444-1000
    mode http
    acl is_vmess path_beg /vmess
    acl is_vless path_beg /vless
    acl is_trojan path_beg /trojan
    acl is_sshws path_beg /ssh-ws
    use_backend v2ray-vmess if is_vmess
    use_backend v2ray-vless if is_vless
    use_backend v2ray-trojan if is_trojan
    use_backend ws-epro if is_sshws
    default_backend v2ray-vmess

backend v2ray-vmess
    mode http
    server vmess 127.0.0.1:10001 check inter 5s fall 3 rise 2

backend v2ray-vless
    mode http
    server vless 127.0.0.1:10002 check inter 5s fall 3 rise 2

backend v2ray-trojan
    mode http
    server trojan 127.0.0.1:10003 check inter 5s fall 3 rise 2

backend ws-epro
    mode http
    server wsepro 127.0.0.1:10090 check inter 5s fall 3 rise 2

frontend https-in
    bind *:9444
    mode tcp
    default_backend xray-tls

backend xray-tls
    mode tcp
    server xray 127.0.0.1:443 check inter 5s fall 3 rise 2
HAPROXYEOF
}

haproxy_is_up() {
    # HAProxy dianggap jalan bila port 8880 LISTEN (bukti ia melayani).
    # systemctl is-active kadang masih "activating" sesaat sesudah restart
    # (unit Type=notify), dan worker butuh sejenak untuk bind ~790 port —
    # jadi cek port diulang 3x (jeda 2 detik), bukan sekali. Port yang jadi
    # patokan; status unit semata tidak cukup untuk menyatakan OFF.
    local i
    for i in 1 2 3; do
        port_tcp 8880 && return 0
        sleep 2
    done
    return 1
}

haproxy_status_diag() {
    # Tampilkan separuh mana yang gagal, agar screenshot berikutnya langsung
    # menjawabnya (tanpa perlu perintah manual dari user).
    local st
    st=$(systemctl is-active haproxy 2>/dev/null || echo "?")
    info "Status unit haproxy: ${st} | Port 8880: $(port_tcp 8880 && echo LISTEN || echo TIDAK-LISTEN) | Port 9444: $(port_tcp 9444 && echo LISTEN || echo TIDAK-LISTEN)"
}

haproxy_config_diag() {
    # Bila service aktif tapi tidak ada port yang LISTEN, penyebabnya hampir
    # pasti di file config yang dibaca service (bukan di prosesnya): tampilkan
    # (a) berapa baris bind di config yang ditulis script, (b) CONFIG +
    # ExecStart dari unit (bila unit memakai file lain, di sinilah ketahuan),
    # (c) semua listener yang benar-benar dipegang proses haproxy.
    local nbind nlisten
    nbind=$(grep -c "^[[:space:]]*bind" /etc/haproxy/haproxy.cfg 2>/dev/null || true); nbind=${nbind:-0}
    nlisten=$(ss -tlnp 2>/dev/null | grep -c "haproxy" || true); nlisten=${nlisten:-0}
    info "Config /etc/haproxy/haproxy.cfg: ${nbind} baris bind | Listener haproxy (ss): ${nlisten}"
    systemctl cat haproxy 2>/dev/null | grep -E "CONFIG=|ExecStart" | head -n 4 | while IFS= read -r l; do info "Unit: ${l}"; done
    ss -tlnp 2>/dev/null | grep "haproxy" | head -n 5 | while IFS= read -r l; do info "ss: ${l}"; done
}

haproxy_apply_limits() {
    # Naikkan batas file descriptor service HAProxy via drop-in systemd, agar
    # maxconn + ~790 listener tidak mentok di batas default. Aman bila systemd
    # tidak ada (daemon-reload gagal -> diabaikan).
    mkdir -p /etc/systemd/system/haproxy.service.d 2>/dev/null || return 0
    cat > /etc/systemd/system/haproxy.service.d/limits.conf <<'LIMITSEOF'
[Service]
LimitNOFILE=65535
LIMITSEOF
    systemctl daemon-reload 2>/dev/null || true
}

haproxy_fix_bind() {
    # HAProxy gagal start karena ada port yang bentrok: baca port itu dari
    # journal, tampilkan pemegangnya, bebaskan (tanya dulu bila interaktif),
    # lalu coba restart lagi (maks. 3 percobaan — satu port per percobaan).
    # Port 80/443 TIDAK PERNAH dibebaskan: itu milik Nginx, bila yang bentrok
    # 443 berarti confignya yang salah (update script lalu ulangi Fixx Haproxy).
    local attempt jlog port holder
    for attempt in 1 2 3; do
        if haproxy_is_up; then
            info "HAProxy jalan."
            return 0
        fi
        jlog=$(journalctl -u haproxy -n 30 --no-pager 2>/dev/null)
        printf '%s\n' "$jlog" | grep -i "cannot bind" | head -n 3 >&2 || true
        # FD limit: HAProxy butuh ~2*maxconn + ~790 listener FD. Bila journal
        # menunjukkan "Cannot raise FD limit", tulis ulang config (maxconn
        # sudah diturunkan ke 1024) + naikkan LimitNOFILE service, lalu coba lagi.
        if printf '%s\n' "$jlog" | grep -qi "fd limit"; then
            warn "HAProxy gagal start karena batas file descriptor (FD limit) terlalu kecil — memperbaiki (maxconn 1024 + LimitNOFILE 65535)..."
            write_haproxy_conf
            haproxy_apply_limits
            systemctl restart haproxy 2>/dev/null || true
            sleep 2
            continue
        fi
        port=$(printf '%s\n' "$jlog" | grep -i "cannot bind" | head -n 1 | sed -nE 's/.*:([0-9]+)\].*/\1/p')
        if [[ -z "$port" ]]; then
            error "HAProxy gagal jalan. Isi journal terakhir (penyebab aslinya ada di sini):"
            printf '%s\n' "$jlog" | tail -n 12 >&2 || true
            haproxy_config_diag
            error "Bila masih belum jelas, cek manual: journalctl -u haproxy -n 30"
            return 1
        fi
        if [[ "$port" == "443" || "$port" == "80" ]]; then
            error "Port ${port} bentrok dengan Nginx (port itu milik Nginx, bukan HAProxy). Config HAProxy salah — update script ke versi terbaru lalu ulangi Fixx Haproxy."
            return 1
        fi
        if [[ -t 0 ]]; then
            free_port_or_ask "$port" "HAProxy" || return 1
        else
            holder=$(port_holder "$port" 2>/dev/null || echo "?")
            error "Port ${port} dipakai oleh ${holder} — bebaskan dulu, lalu jalankan Fixx Haproxy dari menu (bukan dari bot)."
            return 1
        fi
        systemctl restart haproxy 2>/dev/null || true
        sleep 2
    done
    if haproxy_is_up; then
        info "HAProxy jalan."
        return 0
    fi
    haproxy_status_diag
    error "HAProxy masih gagal jalan sesudah 3 percobaan. Cek: journalctl -u haproxy -n 30"
    return 1
}

setup_haproxy() {
    # Install HAProxy + config + nyalakan. Dipanggil dari Features 10.
    # (Menu 1 sengaja tidak memasangnya: port 80/443 sudah dipegang Nginx.)
    if ! command -v haproxy >/dev/null 2>&1; then
        info "Menginstall HAProxy..."
        fix_dns
        if ! timeout 180 apt-get update 2>/dev/null; then warn "apt-get update lambat/gagal — lanjut install."; fi
        if ! timeout 180 apt-get install -y haproxy 2>/dev/null; then
            error "Gagal install HAProxy — cek internet/DNS VPS (coba Features 9 ganti DNS)."
            return 1
        fi
    fi
    write_haproxy_conf
    haproxy_apply_limits
    if ! haproxy -c -f /etc/haproxy/haproxy.cfg 2>&1 | tail -n 5; then
        error "Config HAProxy TIDAK valid."
        return 1
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 8880/tcp 2>/dev/null || true
        ufw allow 9444/tcp 2>/dev/null || true
        ufw allow 8080/tcp 2>/dev/null || true
        ufw allow 2082/tcp 2>/dev/null || true
        ufw allow 2086/tcp 2>/dev/null || true
        ufw allow 2095/tcp 2>/dev/null || true
        ufw allow 55/tcp 2>/dev/null || true
        ufw allow 222:1000/tcp 2>/dev/null || true
    fi
    systemctl enable haproxy 2>/dev/null || true
    systemctl restart haproxy
    sleep 2
    if haproxy_is_up; then
        info "HAProxy jalan (multiport: 55, 8080, 8880, 2082, 2086, 2095, 222-442 + 444-1000 HTTP + 9444 TLS)."
    else
        haproxy_status_diag
        haproxy_fix_bind
        return $?
    fi
    ss -tlnp 2>/dev/null | grep -E ':8880|:9444|:8080|:2082|:55' || warn "Port HAProxy belum LISTEN."
}

feat_fix_haproxy() {
    echo "=== Fixx Haproxy ==="
    if ! command -v haproxy >/dev/null 2>&1; then
        warn "HAProxy belum terpasang — menginstall sekarang."
        setup_haproxy
        return $?
    fi
    if ! haproxy -c -f /etc/haproxy/haproxy.cfg 2>&1 | tail -n 5; then
        warn "Config HAProxy rusak — menulis ulang dari template vps-manager..."
        write_haproxy_conf
        haproxy -c -f /etc/haproxy/haproxy.cfg 2>&1 | tail -n 5 || { error "Config baru tetap tidak valid."; return 1; }
    fi
    # Config valid tapi tanpa baris bind = service jalan tanpa mendengarkan
    # apa-apa (persis gejala 27 Nov 2026: active, worker forked, 0 listener).
    # Ini terjadi bila file config tertimpa/berbeda — tulis ulang dari template.
    if [[ $(grep -c "^[[:space:]]*bind" /etc/haproxy/haproxy.cfg 2>/dev/null || true) -eq 0 ]]; then
        warn "Config HAProxy tidak punya baris bind sama sekali — menulis ulang dari template vps-manager..."
        write_haproxy_conf
        haproxy -c -f /etc/haproxy/haproxy.cfg 2>&1 | tail -n 5 || { error "Config baru tetap tidak valid."; return 1; }
    fi
    haproxy_apply_limits
    systemctl restart haproxy
    sleep 2
    if haproxy_is_up; then
        info "HAProxy jalan."
        echo "--- Backend (harus UP bila Xray/ws-epro/Nginx jalan) ---"
        echo "  55, 8080, 8880, 2082, 2086, 2095, 222-442 + 444-1000 -> VMess 10001 / VLESS 10002 / Trojan 10003 / SSH-WS 10090"
        echo "  9444 -> Nginx :443 (TLS)"
    else
        haproxy_status_diag
        haproxy_config_diag
        haproxy_fix_bind
        return $?
    fi
    ss -tlnp 2>/dev/null | grep -E ':8880|:9444|:8080|:2082|:55' || warn "Port HAProxy belum LISTEN."
}
feat_fix_nginx() {
    echo "=== Fixx Nginx ==="
    if nginx -t 2>&1; then
        info "Config Nginx valid."
    else
        error "Config Nginx TIDAK valid:"
        nginx -t 2>&1 | tail -n 10
        local domain
        domain=$(state_get '.install.domain // ""')
        if [[ -n "$domain" ]]; then
            warn "Membangun ulang config Nginx dari state..."
            backup_config
            write_nginx_conf "$domain"
            nginx -t 2>&1 | tail -n 5
        fi
    fi
    systemctl restart nginx
    sleep 1
    if systemctl is-active --quiet nginx; then info "Nginx jalan."; else error "Nginx gagal jalan — cek: journalctl -u nginx -n 30"; fi
    ss -tlnp 2>/dev/null | grep -E ':80 |:443 ' || warn "Port 80/443 belum LISTEN."
}

feat_fix_ws_epro() {
    echo "=== Fixx WS ePRO ==="
    # SSH-WS OFF di menu biasanya karena ws-epro belum pernah terpasang
    # (menu 1 belum dijalankan ulang sesudah versi ws-epro) atau servicenya
    # gagal start (modul websockets hilang / file rusak). Perbaiki semua itu.
    if [[ ! -f /opt/ws-epro/ws-epro.py || ! -f /etc/systemd/system/ws-epro.service ]]; then
        warn "ws-epro belum terpasang — menginstall sekarang."
        setup_ws_epro
    else
        if ! python3 -c "import websockets" 2>/dev/null; then
            warn "Modul Python 'websockets' tidak ada — menginstall..."
            if ! (timeout 120 apt-get install -y python3-websockets 2>/dev/null || timeout 120 pip3 install --break-system-packages websockets 2>/dev/null || timeout 120 pip3 install websockets 2>/dev/null); then
                error "Gagal install websockets — SSH WS tetap tidak bisa jalan."
                return 1
            fi
        fi
        if ! python3 -m py_compile /opt/ws-epro/ws-epro.py 2>/dev/null; then
            warn "File ws-epro.py rusak — menulis ulang."
            setup_ws_epro
        else
            systemctl restart ws-epro
        fi
    fi
    sleep 2
    if systemctl is-active --quiet ws-epro; then
        info "ws-epro jalan."
    else
        error "ws-epro gagal jalan — log 20 baris terakhir:"
        journalctl -u ws-epro -n 20 --no-pager 2>/dev/null || true
        local holder
        holder=$(ss -tlnp 2>/dev/null | grep ':10090' || true)
        [[ -n "$holder" ]] && warn "Port 10090 sudah dipakai: $holder"
        return 1
    fi
    ss -tlnp 2>/dev/null | grep -E ':10090' || warn "Port 10090 belum LISTEN."
}
feat_fix_domain() {
    echo "=== Fixx Domain ==="
    local domain vps_ip resolved email
    domain=$(state_get '.install.domain // ""')
    email=$(state_get '.install.email // ""')
    [[ -z "$domain" ]] && { error "Belum ada domain di state — jalankan menu 1 dulu."; return 1; }
    vps_ip=$(detect_public_ip || true)
    resolved=$(getent hosts "$domain" | awk '{print $1}' | head -n 1 || true)
    info "Domain $domain resolve ke: ${resolved:-TIDAK RESOLVE}"
    info "IP publik VPS: ${vps_ip:-tidak terdeteksi}"
    [[ -n "$vps_ip" ]] && jq_state --arg v "$vps_ip" '.install.ip = $v' 2>/dev/null || true
    if [[ -n "$resolved" && -n "$vps_ip" && "$resolved" != "$vps_ip" ]]; then
        error "A record SALAH — ubah A record $domain ke $vps_ip di DNS registrar kamu, tunggu propagasi, lalu ulangi Fixx Domain."
        return 1
    fi
    if [[ -z "$resolved" ]]; then
        error "Domain tidak resolve — buat A record $domain ke ${vps_ip:-IP VPS} dulu."
        return 1
    fi
    if ! issue_cert "$domain" "$email"; then
        error "Sertifikat gagal diterbitkan — cek /tmp/acme-issue.log (15 baris terakhir):"
        tail -n 15 /tmp/acme-issue.log 2>/dev/null || true
        return 1
    fi
    backup_config
    write_nginx_conf "$domain"
    if nginx -t 2>/dev/null; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx
    else
        error "nginx -t gagal."
        return 1
    fi
    apply_xray || { error "Xray gagal start."; show_xray_failure; return 1; }
    sleep 2
    systemctl restart ws-epro 2>/dev/null || true
    systemctl restart nginx 2>/dev/null || true
    info "Domain diperbaiki: $domain (IP $vps_ip)."
    feat_running_service
}

feat_fix_xray() {
    echo "=== Fixx Xray ==="
    if ! command -v xray >/dev/null 2>&1 && [[ ! -x /usr/local/bin/xray ]]; then
        error "Xray belum terpasang — jalankan menu 1 dulu."
        return 1
    fi
    build_xray_config
    if xray -test -config /usr/local/etc/xray/config.json 2>&1 | tail -n 5; then
        info "Config Xray valid (xray -test OK)."
    else
        error "Config Xray TIDAK valid — cek /usr/local/etc/xray/config.json"
        return 1
    fi
    ensure_xray_logdir
    systemctl restart xray
    sleep 3
    if systemctl is-active --quiet xray; then info "Xray jalan."; else error "Xray gagal jalan:"; show_xray_failure; fi
    ss -tlnp 2>/dev/null | grep -E ':1000[1-5]|:10085' || warn "Port Xray 10001-10004/10085 belum LISTEN."
}

feat_clear_cache() {
    echo "=== Clear Cache ==="
    apt-get clean 2>/dev/null || true
    rm -rf /var/cache/apt/archives/*.deb 2>/dev/null || true
    sync
    info "Cache apt dibersihkan."
}

feat_clear_logs() {
    echo "=== Clear Logs ==="
    : > /var/log/xray/access.log 2>/dev/null || true
    : > /var/log/xray/error.log 2>/dev/null || true
    : > /var/log/vps-manager.log 2>/dev/null || true
    journalctl --vacuum-size=100M 2>/dev/null || true
    info "Log dibersihkan (Xray + vps-manager + journal di atas 100M)."
}

feat_clear_cache_file() {
    echo "=== Clear Cache File ==="
    find /tmp -type f -mtime +7 -delete 2>/dev/null || true
    rm -rf /root/.cache/* 2>/dev/null || true
    find /var/tmp -type f -mtime +30 -delete 2>/dev/null || true
    info "File cache lama di /tmp dan /var/tmp dibersihkan."
}

feat_info_ports() {
    echo "=== Info Service Port ==="
    echo "Port layanan vps-manager (yang seharusnya LISTEN):"
    echo "  SSH 22 | Nginx 80, 443 | Xray 10001-10004, 10085 | ws-epro 10090"
    echo
    ss -tlnp 2>/dev/null
}

feat_info_system() {
    echo "=== Information System ==="
    echo "OS      : $(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
    echo "Kernel  : $(uname -r)"
    echo "CPU     : $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //') ($(nproc) core)"
    echo "RAM     : $(free -h 2>/dev/null | awk '/^Mem:/ {print $3" / "$2}')"
    echo "Disk    : $(df -h / 2>/dev/null | awk 'NR==2 {print $3" / "$2" ("$5")"}')"
    echo "Uptime  : $(uptime_str)"
    echo "IP      : $(cached_public_ip)"
    echo "Domain  : $(state_get '.install.domain // "—"')"
    echo "Xray    : $(xray version 2>/dev/null | head -n 1 || echo 'belum terpasang')"
    echo "Nginx   : $(nginx -v 2>&1 | head -n 1 || echo 'belum terpasang')"
}

feat_list_opensource() {
    echo "=== List Open Source & Sewa Script ==="
    echo "Komponen open source yang dipakai script ini:"
    echo "  - Xray-core ......... $(xray version 2>/dev/null | head -n 1 || echo 'belum terpasang')"
    echo "  - Nginx ............. $(nginx -v 2>&1 | head -n 1 || echo 'belum terpasang')"
    echo "  - acme.sh ........... $(ls ~/.acme.sh/acme.sh 2>/dev/null && echo 'terpasang' || echo 'belum terpasang')"
    echo "  - Python websockets . $(python3 -c 'import websockets; print(websockets.__version__)' 2>/dev/null || echo 'belum terpasang')"
    echo "  - vnstat ............ $(vnstat --version 2>/dev/null | head -n 1 || echo 'belum terpasang')"
    echo "  - fail2ban .......... $(fail2ban-client --version 2>/dev/null || echo 'belum terpasang')"
    echo
    echo "Script ini (vps-manager) adalah karya sendiri untuk VPS kamu —"
    echo "bukan script sewa, tidak ada masa aktif / lisensi."
}

feat_antiddos() {
    echo "=== Anti-DDoS Protection ==="
    if ! command -v fail2ban-client >/dev/null 2>&1; then
        echo "fail2ban belum terpasang. Pasang sekarang? (proteksi brute-force SSH)"
        read -r -p "Install fail2ban? [y/N]: " REPLY
        if [[ ${REPLY:-} =~ ^[Yy]$ ]]; then
            fix_dns
            apt-get update && apt-get install -y fail2ban
            systemctl enable --now fail2ban
        else
            info "Dibatalkan — tanpa fail2ban, SSH hanya dilindungi password/SSH key."
            return 0
        fi
    fi
    if [[ ! -f /etc/fail2ban/jail.local ]]; then
        printf '[sshd]\nenabled = true\nmaxretry = 5\nbantime = 3600\n' > /etc/fail2ban/jail.local
        systemctl restart fail2ban
    fi
    sleep 1
    fail2ban-client status 2>/dev/null || warn "fail2ban tidak jalan."
    fail2ban-client status sshd 2>/dev/null || true
}

feat_script_other() {
    echo "=== Script Other ==="
    echo "Perintah yang terpasang di VPS ini:"
    echo "  menu ......... buka menu vps-manager"
    echo "  vps-manager .. perintah utama (menu + non-interaktif)"
    echo
    echo "Update script ke versi terbaru dari GitHub (roodyzain7/vps-manager)?"
    read -r -p "Update sekarang? [y/N]: " REPLY
    [[ ${REPLY:-} =~ ^[Yy]$ ]] || { info "Dibatalkan."; return 0; }
    local tmp
    tmp=$(mktemp /tmp/vps-manager-update.XXXXXX)
    if curl -fsSL --max-time 30 https://raw.githubusercontent.com/roodyzain7/vps-manager/main/vps-manager.sh -o "$tmp"; then
        if bash -n "$tmp"; then
            cp /usr/local/bin/vps-manager "/usr/local/bin/vps-manager.bak.$(date '+%Y%m%d-%H%M')" 2>/dev/null || true
            cp "$tmp" /usr/local/bin/vps-manager
            chmod +x /usr/local/bin/vps-manager
            info "Script diperbarui. Ketik 'menu' lagi untuk memakai versi baru."
        else
            error "File baru gagal verifikasi (bash -n) — tidak diganti."
        fi
    else
        error "Gagal unduh dari GitHub — cek internet VPS."
    fi
    rm -f "$tmp"
}

feat_limit_speed() {
    echo "=== Limit Speed ==="
    local iface
    iface=$(main_iface)
    if ! command -v tc >/dev/null 2>&1; then
        error "Perintah 'tc' tidak ada (paket iproute2). Install: apt-get install -y iproute2."
        return 1
    fi
    echo "Interface: $iface"
    echo "Qdisc saat ini:"
    tc qdisc show dev "$iface" 2>/dev/null || true
    echo
    echo "Batas ini berlaku untuk SEMUA traffic VPS (termasuk SSH kamu)."
    local lim
    read -r -p "Batas download+upload (Mbit, 1-1000; 0 = hapus limit): " lim
    if [[ "$lim" == "0" ]]; then
        tc qdisc del dev "$iface" root 2>/dev/null || true
        info "Limit dihapus."
        return 0
    fi
    [[ "$lim" =~ ^[0-9]+$ ]] && (( lim >= 1 && lim <= 1000 )) || { error "Batas harus angka 1-1000."; return 1; }
    tc qdisc replace dev "$iface" root handle 1: htb default 30
    tc class add dev "$iface" parent 1: classid 1:1 htb rate "${lim}Mbit" ceil "${lim}Mbit"
    tc class add dev "$iface" parent 1:1 classid 1:30 htb rate "${lim}Mbit" ceil "${lim}Mbit"
    info "Limit total ${lim} Mbit diterapkan di $iface."
}

feat_xray_onoff() {
    echo "=== Limit-on-off XRAY ==="
    if systemctl is-active --quiet xray 2>/dev/null; then
        echo "Xray sedang ON. Matikan Xray (semua akun VPN berhenti)?"
        read -r -p "Matikan Xray? [y/N]: " REPLY
        if [[ ${REPLY:-} =~ ^[Yy]$ ]]; then
            systemctl stop xray
            systemctl disable xray 2>/dev/null || true
            info "Xray dimatikan."
        else
            info "Dibatalkan — Xray tetap ON."
        fi
    else
        echo "Xray sedang OFF. Nyalakan lagi?"
        read -r -p "Nyalakan Xray? [y/N]: " REPLY
        if [[ ${REPLY:-} =~ ^[Yy]$ ]]; then
            systemctl enable xray 2>/dev/null || true
            systemctl start xray
            sleep 2
            systemctl is-active --quiet xray && info "Xray jalan." || error "Xray gagal jalan — pakai 14.) Fixx Xray."
        else
            info "Dibatalkan — Xray tetap OFF."
        fi
    fi
}

feat_booster_cpu() {
    echo "=== Boster CPU (multi-threading) ==="
    echo "CPU: $(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | sed 's/^ //') ($(nproc) core)"
    echo "Load: $(uptime | awk -F'load average:' '{print $2}')"
    local gov
    gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo "")
    if [[ -n "$gov" ]]; then
        echo "Governor sekarang: $gov"
        echo "performance" | tee /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor 2>/dev/null >/dev/null && info "Governor diubah ke performance." || warn "Governor tidak bisa diubah (VPS cloud biasanya dikunci hypervisor)."
    else
        info "CPU governor tidak tersedia — di VPS cloud, CPU dikelola hypervisor, bukan dari dalam VPS."
    fi
    local pr pid
    for pr in xray nginx ws-epro; do
        pid=$(pgrep -x "$pr" 2>/dev/null | head -n 1 || true)
        [[ -n "$pid" ]] && renice -n -5 -p "$pid" 2>/dev/null || true
    done
    info "Prioritas proses xray/nginx/ws-epro dinaikkan (nice -5)."
}

# Perbaiki SEMUA layanan yang OFF di Running Service (dipanggil dari
# Running Service bila user jawab y, atau langsung dari Features 27).
# Setiap kelompok hanya diperbaiki bila ada entrinya yang OFF; yang sudah ON
# dilewati. OpenVPN + OHP TIDAK dipasang di sini — keduanya butuh server
# sendiri (OpenVPN butuh PKI + NAT, OHP butuh server OpenVPN) dan bukan
# sekadar "restart"; dilaporkan jujur sebagai belum terpasang.
feat_fix_all_services() {
    echo "=== Fixx Semua Service OFF ==="
    echo "Memeriksa 29 layanan, memperbaiki yang OFF (yang sudah ON dilewati)."
    echo
    if ! chk_ssh_tun; then
        info "[SSH / TUN] OFF — restart OpenSSH..."
        systemctl restart ssh 2>/dev/null || systemctl restart sshd 2>/dev/null || true
        sleep 1
        chk_ssh_tun && info "[SSH / TUN] sekarang ON." || warn "[SSH / TUN] masih OFF."
    fi
    if ! chk_ssh_udp || ! chk_badvpn7100 || ! chk_badvpn7200 || ! chk_badvpn7300; then
        info "[SSH UDP-HC / BadVPN] ada yang OFF — setup udp-custom..."
        setup_udp_forward || warn "[SSH UDP-HC / BadVPN] setup gagal (lihat pesan di atas)."
    fi
    if ! chk_wsepro; then
        info "[WS ePRO] OFF — jalankan Fixx WS ePRO..."
        feat_fix_ws_epro || warn "[WS ePRO] perbaikan gagal."
    fi
    if ! chk_dropbear; then
        info "[Dropbear] OFF — setup dropbear (109/143)..."
        setup_dropbear || warn "[Dropbear] setup gagal."
    fi
    if ! chk_haproxy; then
        info "[Haproxy] OFF — jalankan Fixx Haproxy..."
        feat_fix_haproxy || warn "[Haproxy] perbaikan gagal."
    fi
    if ! chk_crons; then
        info "[Crons] OFF — enable + start cron..."
        systemctl enable cron 2>/dev/null || systemctl enable crond 2>/dev/null || true
        systemctl start cron 2>/dev/null || systemctl start crond 2>/dev/null || true
        sleep 1
        chk_crons && info "[Crons] sekarang ON." || warn "[Crons] masih OFF."
    fi
    if ! chk_nginx; then
        info "[Nginx] OFF — jalankan Fixx Nginx..."
        feat_fix_nginx || warn "[Nginx] perbaikan gagal."
    fi
    if ! chk_xray_vmess_tls || ! chk_xray_vmess_nontls || ! chk_xray_vmess_grpc \
        || ! chk_xray_vless_tls || ! chk_xray_vless_nontls || ! chk_xray_vless_grpc \
        || ! chk_xray_trojan_ws || ! chk_xray_trojan_nonws || ! chk_xray_trojan_grpc \
        || ! chk_xray_ss_ws || ! chk_xray_ss_nonws || ! chk_xray_ss_grpc; then
        info "[Xray] ada yang OFF — bangun ulang config (inbound gRPC + Shadowsocks baru ikut) + restart Xray..."
        apply_xray || warn "[Xray] apply gagal — lihat diagnosa di atas."
        sleep 1
    fi
    if ! chk_ovpn_ssl || ! chk_ovpn_wsssl || ! chk_ovpn_udp || ! chk_ovpn_tcp; then
        warn "[OpenVPN] belum terpasang — vps-manager belum menginstall server OpenVPN (SSL/WS-SSL/UDP/TCP). Bila mau dipasang, minta 'tambah OpenVPN'."
    fi
    if ! chk_ohp_ssh || ! chk_ohp_dropbear; then
        info "[OHP SSH / Dropbear] ada yang OFF — setup OHP (SSH 8181 + Dropbear 8282)..."
        setup_ohp || warn "[OHP] setup gagal (lihat pesan di atas)."
    fi
    if ! chk_ohp_ovpn; then
        warn "[OHP OpenVPN] tetap OFF — butuh server OpenVPN (belum dipasang). Minta 'tambah OpenVPN' bila mau."
    fi
    echo
    echo "=== Hasil sesudah perbaikan ==="
    feat_running_service noprompt
    return 0
}


show_features_menu() {
    printf '%b\n' "${C_BLUE}------------------------------------------------------------${C_RESET}"
    printf '  %bFEATURES%b\n' "$C_MAGENTA" "$C_RESET"
    printf '%b\n' "${C_BLUE}------------------------------------------------------------${C_RESET}"
    echo "  1.) Running Service"
    echo "  2.) Restart Service"
    echo "  3.) Auto Reboot"
    echo "  4.) Monitoring"
    echo "  5.) SpeedTest"
    echo "  6.) Delete All Account Exp"
    printf '%b%b%-60s%b\n' "$C_BG_BLUE" "$C_GREEN" "  MENU FIXX" "$C_RESET"
    echo "  7.) Change Banner"
    echo "  8.) Change Domain"
    echo "  9.) Change DNS Server"
    echo " 10.) Fixx Haproxy"
    echo " 11.) Fixx Nginx"
    echo " 12.) Fixx WS ePRO"
    echo " 13.) Fixx Domain"
    echo " 14.) Fixx Xray"
    printf '%b%b%-60s%b\n' "$C_BG_BLUE" "$C_GREEN" "  MENU CLEAR" "$C_RESET"
    echo " 15.) Clear Cache"
    echo " 16.) Clear Logs"
    echo " 17.) Clear Cache File"
    printf '%b%b%-60s%b\n' "$C_BG_BLUE" "$C_GREEN" "  INFORMATION" "$C_RESET"
    echo " 18.) Info Service Port"
    echo " 19.) Information System"
    echo " 20.) List Open Source & Sewa Script"
    printf '%b%b%-60s%b\n' "$C_BG_BLUE" "$C_GREEN" "  OTHER" "$C_RESET"
    echo " 21.) Anti-DDoS Protection"
    echo " 22.) Script Other"
    echo " 23.) Limit Speed"
    echo " 24.) Limit-on-off XRAY"
    echo " 25.) Boster CPU (multi-threading)"
    echo " 26.) Back to Menu"
    echo " 27.) Fixx Semua Service OFF"
    echo "  x . EXIT"
    printf '%b\n' "${C_BLUE}------------------------------------------------------------${C_RESET}"
}

submenu_features() {
    while true; do
        clear 2>/dev/null || true
        show_features_menu
        local pilih=""
        read -r -p "Pilih dari opsi [1-27 atau x]: " pilih || return 0
        # Setiap aksi dibungkus "|| warn" supaya kegagalan kembali ke menu
        # Features, bukan keluar script (pola yang sama seperti menu_loop).
        case "$pilih" in
            1)  feat_running_service || warn "Running Service gagal." ;;
            2)  feat_restart_service || warn "Restart Service gagal." ;;
            3)  feat_auto_reboot || warn "Auto Reboot gagal." ;;
            4)  feat_monitoring || warn "Monitoring gagal." ;;
            5)  feat_speedtest || warn "SpeedTest gagal." ;;
            6)  feat_delete_expired || warn "Delete Expired gagal." ;;
            7)  feat_change_banner || warn "Change Banner gagal." ;;
            8)  feat_change_domain || warn "Change Domain gagal." ;;
            9)  feat_change_dns || warn "Change DNS Server gagal." ;;
            10) feat_fix_haproxy || warn "Fixx Haproxy gagal." ;;
            11) feat_fix_nginx || warn "Fixx Nginx gagal." ;;
            12) feat_fix_ws_epro || warn "Fixx WS ePRO gagal." ;;
            13) feat_fix_domain || warn "Fixx Domain gagal." ;;
            14) feat_fix_xray || warn "Fixx Xray gagal." ;;
            15) feat_clear_cache || warn "Clear Cache gagal." ;;
            16) feat_clear_logs || warn "Clear Logs gagal." ;;
            17) feat_clear_cache_file || warn "Clear Cache File gagal." ;;
            18) feat_info_ports || warn "Info Service Port gagal." ;;
            19) feat_info_system || warn "Information System gagal." ;;
            20) feat_list_opensource || warn "List Open Source gagal." ;;
            21) feat_antiddos || warn "Anti-DDoS gagal." ;;
            22) feat_script_other || warn "Script Other gagal." ;;
            23) feat_limit_speed || warn "Limit Speed gagal." ;;
            24) feat_xray_onoff || warn "Limit-on-off XRAY gagal." ;;
            25) feat_booster_cpu || warn "Boster CPU gagal." ;;
            26) return 0 ;;
            27) feat_fix_all_services || warn "Fixx Semua Service gagal." ;;
            x|X) exit 0 ;;
            *)  error "Pilihan tidak valid: ${pilih}" ;;
        esac
        echo
        feat_pause
    done
}

show_header() {
    local mode domain xray_status total active expired expiring
    mode=$(state_get '.install.mode // ""')
    domain=$(state_get '.install.domain // ""')
    total=$(jq -r '.accounts | length' "$STATE_FILE" 2>/dev/null || echo 0)
    active=$(jq -r '[.accounts[] | select(.status=="active")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
    expired=$(jq -r '[.accounts[] | select(.status=="expired")] | length' "$STATE_FILE" 2>/dev/null || echo 0)
    expiring=$(jq -r --arg today "$(today_iso)" --arg soon "$(date -d '+3 days' '+%F')" '[.accounts[] | select(.status=="active" and .expiry >= $today and .expiry <= $soon)] | length' "$STATE_FILE" 2>/dev/null || echo 0)
    if systemctl is-active --quiet xray 2>/dev/null; then xray_status="${C_GREEN}ON${C_RESET}"; else xray_status="${C_RED}OFF${C_RESET}"; fi
    local nginx_status ws_status bot_stat health
    if systemctl is-active --quiet nginx 2>/dev/null; then nginx_status="${C_GREEN}ON${C_RESET}"; else nginx_status="${C_RED}OFF${C_RESET}"; fi
    if systemctl is-active --quiet ws-epro 2>/dev/null; then ws_status="${C_GREEN}ON${C_RESET}"; else ws_status="${C_RED}OFF${C_RESET}"; fi
    if [[ "$(bot_status)" == "ON" ]]; then bot_stat="${C_GREEN}ON${C_RESET}"; else bot_stat="${C_RED}OFF${C_RESET}"; fi
    if [[ -z "$mode" ]]; then health="${C_YELLOW}BELUM INSTALL${C_RESET}";
    elif systemctl is-active --quiet xray 2>/dev/null && systemctl is-active --quiet nginx 2>/dev/null && systemctl is-active --quiet ws-epro 2>/dev/null; then health="${C_GREEN}GOOD${C_RESET}";
    else health="${C_YELLOW}PERIKSA${C_RESET}"; fi
    local os_name ram_str swap_str up_str ip_pub city isp
    os_name=$(grep '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')
    ram_str=$(free -m 2>/dev/null | awk '/^Mem:/ {printf "%dMB / %dMB", $3, $2}')
    swap_str=$(free -m 2>/dev/null | awk '/^Swap:/ {printf "%dMB / %dMB", $3, $2}')
    up_str=$(uptime_str)
    ip_pub=$(cached_public_ip)
    IFS='|' read -r city isp <<< "$(server_geo)"
    clear 2>/dev/null || true
    printf '%b\n' "${C_BLUE}============================================================${C_RESET}"
    printf '%b\n' "${C_MAGENTA}   VPS MANAGER — SSH / VMess / VLESS / Trojan (Xray-core)   ${C_RESET}"
    printf '%b\n' "${C_BLUE}============================================================${C_RESET}"
    printf '  OS     : %s\n' "${os_name:-—}"
    printf '  RAM    : %s\n' "${ram_str:-—}"
    printf '  SWAP   : %s\n' "${swap_str:-—}"
    printf '  CITY   : %s\n' "$city"
    printf '  ISP    : %s\n' "$isp"
    printf '  IP     : %b%s%b\n' "$C_RED" "$ip_pub" "$C_RESET"
    printf '  DOMAIN : %s\n' "${domain:-—}"
    printf '  UPTIME : %s\n' "$up_str"
    printf '%b\n' "${C_BLUE}------------------------------------------------------------${C_RESET}"
    traffic_lines
    printf '%b\n' "${C_BLUE}------------------------------------------------------------${C_RESET}"
    printf '  XRAY: %b | SSH-WS: %b | NGINX: %b | BOT: %b | %b\n' "$xray_status" "$ws_status" "$nginx_status" "$bot_stat" "$health"
    printf '%b\n' "${C_BLUE}------------------------------------------------------------${C_RESET}"
    printf '  Akun: %s (aktif: %s, expired: %s) | Hampir expired (<=3 hari): %s\n' "$total" "$active" "$expired" "$expiring"
    printf '%b\n' "${C_BLUE}============================================================${C_RESET}"
}
show_menu() {
    printf '  %b01%b) %-24s %b08%b) %s\n' "$C_CYAN" "$C_RESET" "Install / Update" "$C_CYAN" "$C_RESET" "Perpanjang Akun"
    printf '  %b02%b) %-24s %b09%b) %s\n' "$C_CYAN" "$C_RESET" "Buat Akun SSH" "$C_CYAN" "$C_RESET" "Link Akun"
    printf '  %b03%b) %-24s %b10%b) %s\n' "$C_CYAN" "$C_RESET" "Buat Akun VMess" "$C_CYAN" "$C_RESET" "Uninstall Bersih"
    printf '  %b04%b) %-24s %b11%b) %s\n' "$C_CYAN" "$C_RESET" "Buat Akun VLESS" "$C_CYAN" "$C_RESET" "Bot Telegram"
    printf '  %b05%b) %-24s %b12%b) %s\n' "$C_CYAN" "$C_RESET" "Buat Akun Trojan" "$C_CYAN" "$C_RESET" "Features"
    printf '  %b06%b) %-24s %b13%b) %s\n' "$C_CYAN" "$C_RESET" "List Semua Akun" "$C_CYAN" "$C_RESET" "Buat Akun Shadowsocks"
    printf '  %b07%b) %-24s %b00%b) %s\n' "$C_CYAN" "$C_RESET" "Hapus Akun" "$C_CYAN" "$C_RESET" "Keluar"
    echo
}
menu_loop() {
    while true; do
        show_header
        show_menu
        local pilih=""
        read -r -p "Pilih menu [0-13]: " pilih || exit 0
        # PENTING: setiap aksi dibungkus "|| warn" supaya kegagalan (mis. install
        # batal karena port dipakai) kembali ke menu, BUKAN keluar script.
        # Sebelum perbaikan ini, "return 1" dari do_install + set -e membuat
        # script langsung lompat ke prompt shell seperti yang dilaporkan user.
        case "$pilih" in
            1)  do_install || warn "Menu 1 tidak selesai — kembali ke menu." ;;
            2)  submenu_create ssh "SSH" || warn "Buat akun SSH tidak selesai — kembali ke menu." ;;
            3)  submenu_create vmess "VMess" || warn "Buat akun VMess tidak selesai — kembali ke menu." ;;
            4)  submenu_create vless "VLESS" || warn "Buat akun VLESS tidak selesai — kembali ke menu." ;;
            5)  submenu_create trojan "Trojan" || warn "Buat akun Trojan tidak selesai — kembali ke menu." ;;
            6)  list_accounts || warn "List akun gagal — kembali ke menu." ;;
            7)  delete_account || warn "Hapus akun tidak selesai — kembali ke menu." ;;
            8)  renew_account || warn "Perpanjang tidak selesai — kembali ke menu." ;;
            9)  show_link || warn "Tampilkan link gagal — kembali ke menu." ;;
            10) do_uninstall || warn "Uninstall tidak selesai — kembali ke menu." ;;
            11) submenu_bot || warn "Menu bot tidak selesai — kembali ke menu." ;;
            12) submenu_features || warn "Menu features tidak selesai — kembali ke menu." ;;
            13) submenu_create ss "Shadowsocks" || warn "Buat akun Shadowsocks tidak selesai — kembali ke menu." ;;
            0)  echo "Sampai jumpa!"; exit 0 ;;
            *)  error "Pilihan tidak valid: ${pilih}" ;;
        esac
        echo
        read -r -p "Tekan Enter untuk kembali ke menu..." -r _
    done
}

# -----------------------------------------------------------------------------
# Cek rantai koneksi: Nginx -> Xray -> path WS.
# Dibuat setelah kasus user: install sukses tapi VPN "tidak jalan" dan dugaan
# "webserver mati" ternyata salah (Nginx hidup, HTTPS 200 dari luar).
# Arti hasil uji WS path:
#   101 = NORMAL (paling bagus: handshake WebSocket berhasil penuh, Nginx ->
#         Xray jalan; curl lalu menunggu dan timeout karena tidak ada payload
#         VMess — itu wajar, bukan error)
#   400 = NORMAL (Nginx meneruskan ke Xray; Xray menolak karena bukan handshake
#         VMess — itu yang diharapkan dari curl polos)
#   200 = path TIDAK dikenali Nginx (jatuh ke location /) -> link klien pakai
#         path WS lama, ambil link baru dari menu 9
#   502 = Nginx hidup tapi Xray tidak menjawab
#   000 = Nginx/TLS mati atau port 443 tidak bisa dijangkau
# Selalu return 0 (hanya laporan, tidak menggagalkan install).
# -----------------------------------------------------------------------------
do_check() {
    echo "=== Cek rantai koneksi (vps-manager --check) ==="
    local mode domain ok=1
    mode=$(state_get '.install.mode // ""')
    domain=$(state_get '.install.domain // ""')
    if systemctl is-active --quiet nginx 2>/dev/null; then
        info "Nginx: berjalan"
    else
        error "Nginx: TIDAK berjalan — coba: systemctl start nginx"
        ok=0
    fi
    if port_tcp 443; then
        info "Port 443: LISTEN"
    else
        error "Port 443: tidak ada yang mendengarkan"
        ok=0
    fi
    if systemctl is-active --quiet xray 2>/dev/null; then
        info "Xray: berjalan"
    else
        error "Xray: TIDAK berjalan — coba: systemctl status xray"
        ok=0
    fi
    if systemctl is-active --quiet ws-epro 2>/dev/null; then
        info "ws-epro (SSH WS): berjalan"
    else
        warn "ws-epro (SSH WS): TIDAK berjalan — /ssh-ws di port 80/443 tidak jalan"
    fi
    if port_tcp 10090; then
        info "Port 10090 (ws-epro): LISTEN"
    else
        warn "Port 10090 (ws-epro): tidak LISTEN"
    fi
    local pp
    for pp in 10001 10002 10003 10004 10005 10006 10007 10008 10085; do
        if port_tcp "$pp"; then
            info "Port ${pp} (Xray): LISTEN"
        else
            warn "Port ${pp} (Xray): tidak LISTEN"
        fi
    done
    if [[ "$mode" == "domain" && -n "$domain" ]]; then
        local vp code
        vp=$(state_get '.install.ws_paths.vmess // "/vmess"')
        code=$(curl -sk --max-time 8 --resolve "${domain}:443:127.0.0.1" "https://${domain}/" -o /dev/null -w "%{http_code}" 2>/dev/null || true)
        code=${code:-000}
        if [[ "$code" == "200" ]]; then
            info "HTTPS ${domain}/ : 200 (Nginx + TLS OK)"
        else
            error "HTTPS ${domain}/ : ${code} (Nginx/TLS bermasalah)"
            ok=0
        fi
        code=$(curl -sk --http1.1 --max-time 5 --resolve "${domain}:443:127.0.0.1" "https://${domain}${vp}" \
            -H "Connection: Upgrade" -H "Upgrade: websocket" \
            -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
            -o /dev/null -w "%{http_code}" 2>/dev/null || true)
        code=${code:-000}
        case "$code" in
            101) info "WS ${vp} : 101 (NORMAL — WebSocket handshake berhasil, Nginx -> Xray jalan)" ;;
            400) info "WS ${vp} : 400 (NORMAL — Nginx terus ke Xray, tinggal handshake VMess klien)" ;;
            200) error "WS ${vp} : 200 — path TIDAK dikenali Nginx, link klien pakai path lama! Ambil link baru dari menu 9."; ok=0 ;;
            502) error "WS ${vp} : 502 — Nginx hidup tapi Xray tidak menjawab (cek: systemctl status xray)"; ok=0 ;;
            *)   error "WS ${vp} : ${code} — rantai putus di Nginx/Xray"; ok=0 ;;
        esac
        # Link permanen script harus bisa diunduh (200).
        code=$(curl -sk --max-time 8 --resolve "${domain}:443:127.0.0.1" "https://${domain}/vps-manager.sh" -o /dev/null -w "%{http_code}" 2>/dev/null || true)
        code=${code:-000}
        if [[ "$code" == "200" ]]; then
            info "Link permanen https://${domain}/vps-manager.sh : 200 (bisa diunduh, tidak expired)"
        else
            warn "Link permanen https://${domain}/vps-manager.sh : ${code} (cek Nginx location /vps-manager.sh)"
        fi
        # Uji yang sama di port 80 non-TLS.
        code=$(curl -s --max-time 5 --resolve "${domain}:80:127.0.0.1" "http://${domain}${vp}" \
            -H "Connection: Upgrade" -H "Upgrade: websocket" \
            -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
            -o /dev/null -w "%{http_code}" 2>/dev/null || true)
        code=${code:-000}
        case "$code" in
            101) info "WS non-TLS ${vp} (port 80) : 101 (NORMAL — WebSocket handshake berhasil)" ;;
            400) info "WS non-TLS ${vp} (port 80) : 400 (NORMAL)" ;;
            200) error "WS non-TLS ${vp} (port 80) : 200 — path tidak dikenali di port 80"; ok=0 ;;
            502) error "WS non-TLS ${vp} (port 80) : 502 — Nginx hidup tapi Xray tidak menjawab"; ok=0 ;;
            *)   error "WS non-TLS ${vp} (port 80) : ${code} — cek Nginx port 80"; ok=0 ;;
        esac
    elif [[ "$mode" == "reality" ]]; then
        if port_tcp 443; then
            info "Port 443 (REALITY): LISTEN"
        else
            error "Port 443 (REALITY): tidak LISTEN"
            ok=0
        fi
    else
        warn "Belum install (mode kosong) — jalankan menu 1 dulu."
    fi
    if (( ok )); then
        info "Rantai koneksi OK — bila klien tetap tidak connect, periksa link (menu 9) & setting klien."
    else
        warn "Ada yang FAIL di atas — perbaiki itu dulu."
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Bantuan & parsing argumen non-interaktif
# -----------------------------------------------------------------------------
print_help() {
    cat <<'EOF'
vps-manager — pengelola akun SSH / VMess / VLESS / Trojan / Shadowsocks (Xray-core)

PENGGUNAAN:
  bash vps-manager.sh                        Menu interaktif
  menu                                       Sama dengan di atas (pintasan,
                                             dibuat otomatis saat install)
  bash vps-manager.sh --help                 Tampilkan bantuan ini

  bash vps-manager.sh --install --mode domain --domain contoh.com --email admin@contoh.com
  bash vps-manager.sh --install --mode reality
  bash vps-manager.sh --setup-bot --bot-token 123456:ABC-DEF --admin-chat-id 123456789
  bash vps-manager.sh --bot-check          Diagnosa bot Telegram (token, chat ID, pesan tes)

  bash vps-manager.sh --create ssh    --name user1 --days 30 [--password rahasia]
  bash vps-manager.sh --create vmess  --name user1 --days 30 [--limit-ip 2]
  bash vps-manager.sh --create vless  --name user1 --days 30 [--transport ws|tcp]
  bash vps-manager.sh --create trojan --name user1 --days 30 [--password rahasia]
  bash vps-manager.sh --create ss     --name user1 --days 30 [--password rahasia]

  bash vps-manager.sh --list
  bash vps-manager.sh --delete --protocol vmess --name user1 [--yes]
  bash vps-manager.sh --renew  --protocol vmess --name user1 --days 30
  bash vps-manager.sh --show   --protocol vless --name user1
  bash vps-manager.sh --check          Cek rantai koneksi Nginx -> Xray -> path WS
  bash vps-manager.sh --check-expired
  bash vps-manager.sh --check-trials         Hapus akun trial yang habis
  bash vps-manager.sh --trial vmess --minutes 30   Buat akun trial (30/60 menit)
  bash vps-manager.sh --uninstall
EOF
}

main() {
    require_root
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
    # PENTING: jq harus ada SEBELUM state_init/menu — menu membaca state.json
    # lewat jq di header. Tanpa ini script mati dengan "jq: command not found"
    # sebelum menu sempat tampil (bug yang dilaporkan user).
    ensure_jq
    state_init
    check_os
    # Pastikan pintasan `menu` ada (untuk yang install dari versi lama, cukup
    # jalankan `vps-manager` sekali — pintasan langsung dibuat bila belum ada).
    if [[ -x "$INSTALL_BIN" && ! -e /usr/local/bin/menu ]]; then
        ln -sf "$INSTALL_BIN" /usr/local/bin/menu 2>/dev/null || true
    fi

    # Tanpa argumen -> menu interaktif.
    if (( $# == 0 )); then
        menu_loop
        return 0
    fi

    local cmd="" mode="" domain="" email="" proto="" name="" days="" password="" transport="" limit_ip="" bot_token="" admin_chat_id="" minutes=""
    while (( $# > 0 )); do
        case "$1" in
            --help|-h) print_help; exit 0 ;;
            --install) cmd="install"; shift ;;
            --create) cmd="create"; proto="${2:-}"; shift 2 ;;
            --delete) cmd="delete"; shift ;;
            --list) cmd="list"; shift ;;
            --renew) cmd="renew"; shift ;;
            --show) cmd="show"; shift ;;
            --check-expired) cmd="check-expired"; shift ;;
            --check-trials) cmd="check-trials"; shift ;;
            --trial) cmd="trial"; proto="${2:-}"; shift 2 ;;
            --minutes) minutes="${2:-}"; shift 2 ;;
            --check) cmd="check"; shift ;;
            --setup-bot) cmd="setup-bot"; shift ;;
            --bot-check) cmd="bot-check"; shift ;;
            --bot-token) bot_token="${2:-}"; shift 2 ;;
            --admin-chat-id) admin_chat_id="${2:-}"; shift 2 ;;
            --yes) FORCE=1; shift ;;
            --uninstall) cmd="uninstall"; shift ;;
            --mode) mode="${2:-}"; shift 2 ;;
            --domain) domain="${2:-}"; shift 2 ;;
            --email) email="${2:-}"; shift 2 ;;
            --protocol) proto="${2:-}"; shift 2 ;;
            --name) name="${2:-}"; shift 2 ;;
            --days) days="${2:-}"; shift 2 ;;
            --password) password="${2:-}"; shift 2 ;;
            --transport) transport="${2:-}"; shift 2 ;;
            --limit-ip) limit_ip="${2:-}"; shift 2 ;;
            *) error "Argumen tidak dikenal: $1 (lihat --help)"; exit 1 ;;
        esac
    done

    case "$cmd" in
        install)
            if [[ -n "$mode" && "$mode" != "domain" && "$mode" != "reality" ]]; then
                error "--mode harus domain atau reality."; exit 1
            fi
            do_install "$mode" "$domain" "$email"
            ;;
        create)
            case "$proto" in
                ssh)    create_ssh "$name" "$days" "$password" ;;
                vmess)  create_vmess "$name" "$days" "$limit_ip" ;;
                vless)  create_vless "$name" "$days" "$transport" "$limit_ip" ;;
                trojan) create_trojan "$name" "$days" "$password" ;;
                ss)     create_ss "$name" "$days" "$password" ;;
                *) error "--create butuh protokol: ssh|vmess|vless|trojan|ss"; exit 1 ;;
            esac
            ;;
        delete) delete_account "$proto" "$name" ;;
        list) list_accounts ;;
        renew) renew_account "$proto" "$name" "$days" ;;
        show) show_link "$proto" "$name" ;;
        check-expired) check_expired ;;
        check-trials) check_trials ;;
        trial) create_trial "$proto" "$minutes" ;;
        check) do_check ;;
        setup-bot) setup_bot "$bot_token" "$admin_chat_id" ;;
        bot-check) bot_check ;;
        uninstall) do_uninstall ;;
        *) error "Tidak ada perintah. Jalankan: bash vps-manager.sh --help"; exit 1 ;;
    esac
}

main "$@"
