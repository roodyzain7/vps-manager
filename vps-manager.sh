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

# Port Xray (localhost, di belakang Nginx pada mode domain)
readonly PORT_VMESS_WS=10001
readonly PORT_VLESS_WS=10002
readonly PORT_TROJAN_WS=10003
readonly PORT_VLESS_GRPC=10004
readonly PORT_XRAY_API=10085

# Warna terminal
readonly C_RESET='\033[0m'
readonly C_RED='\033[0;31m'
readonly C_GREEN='\033[0;32m'
readonly C_YELLOW='\033[1;33m'
readonly C_CYAN='\033[0;36m'
readonly C_MAGENTA='\033[1;35m'

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
    local deps=(curl jq qrencode uuid-runtime openssl nginx socat ufw python3 procps iproute2)
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
#       {"protocol": "ssh|vmess|vless|trojan", "name": "", "uuid": "", "password": "",
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
    local port="$1" proto="${2:-tcp}"
    if ss -tlnp 2>/dev/null | grep -qE ":${port}[[:space:]]"; then
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

    vmess_clients=$(jq -c '[.accounts[] | select(.protocol=="vmess" and .status=="active")
        | {id: .uuid, alterId: 0, email: .name}]' "$STATE_FILE")
    vless_clients=$(jq -c '[.accounts[] | select(.protocol=="vless" and .status=="active")
        | {id: .uuid, email: .name}
          + (if (.transport // "ws") == "tcp" then {flow: "xtls-rprx-vision"} else {} end)]' "$STATE_FILE")
    trojan_clients=$(jq -c '[.accounts[] | select(.protocol=="trojan" and .status=="active")
        | {password: .password, email: .name}]' "$STATE_FILE")

    mkdir -p "$(dirname "$XRAY_CONFIG")"
    jq -n \
        --argjson vmess "$vmess_clients" \
        --argjson vless "$vless_clients" \
        --argjson trojan "$trojan_clients" \
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
    if ! ufw status 2>/dev/null | grep -q "Status: active"; then
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

# Jembatan WebSocket -> TCP untuk SSH (dipakai HTTP Custom dkk via /ssh-ws).
# Nginx hanya meneruskan upgrade WebSocket; yang mengubah frame WS menjadi TCP
# mentah ke SSH 22 adalah proses ini (127.0.0.1:10090).
setup_ws_epro() {
    if python3 -c "import websockets" 2>/dev/null; then
        info "Modul websockets sudah ada."
    else
        info "Menginstall modul websockets (untuk jembatan SSH WS)..."
        if ! (apt-get install -y python3-websockets 2>/dev/null || pip3 install --break-system-packages websockets 2>/dev/null || pip3 install websockets 2>/dev/null); then
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
        read -r -s -p "Password (kosongkan = acak 12 karakter): " password; echo
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
    if [[ -z "$limit_ip" ]]; then
        read -r -p "Limit IP (kosongkan = tanpa batas; dicatat saja, tidak ditegakkan Xray): " limit_ip
        [[ -n "$limit_ip" ]] && ! [[ "$limit_ip" =~ ^[0-9]+$ ]] && { error "Limit IP harus angka."; return 1; }
    fi
    local uuid expiry acc
    uuid=$(uuidgen)
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
        read -r -p "Transport [ws/tcp] (default: ${transport}): " -r ans || true
        [[ -n "${ans:-}" ]] && transport="$ans"
    fi
    [[ "$transport" != "ws" && "$transport" != "tcp" ]] && { error "Transport harus ws atau tcp."; return 1; }
    if [[ -z "$limit_ip" ]]; then
        read -r -p "Limit IP (kosongkan = tanpa batas; dicatat saja): " limit_ip
        [[ -n "$limit_ip" ]] && ! [[ "$limit_ip" =~ ^[0-9]+$ ]] && { error "Limit IP harus angka."; return 1; }
    fi
    local uuid expiry acc flow
    uuid=$(uuidgen)
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
        read -r -s -p "Password Trojan (kosongkan = acak kuat): " password; echo
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

# -----------------------------------------------------------------------------
# List, hapus, perpanjang
# -----------------------------------------------------------------------------
list_accounts() {
    check_expired_quiet
    local total
    total=$(jq -r '.accounts | length' "$STATE_FILE")
    echo "================= DAFTAR AKUN (${total}) ================="
    printf '%-8s %-18s %-12s %-10s %-8s\n' "PROTOKOL" "NAMA" "EXPIRED" "STATUS" "LIMIT-IP"
    echo "----------------------------------------------------------"
    jq -r '.accounts | sort_by(.expiry)[] | [.protocol, .name, .expiry, .status, (.limit_ip // "-" | tostring)] | @tsv' "$STATE_FILE" \
        | while IFS=$'\t' read -r proto name exp status lip; do
            local mark=""
            if is_expired "$exp" && [[ "$status" == "active" ]]; then mark=" (LEWAT!)"; fi
            printf '%-8s %-18s %-12s %-10s %-8s%s\n' "$proto" "$name" "$exp" "$status" "$lip" "$mark"
        done
    echo "----------------------------------------------------------"
    local expiring
    expiring=$(jq -r --arg today "$(today_iso)" --arg soon "$(date -d '+3 days' '+%F')" \
        '[.accounts[] | select(.status=="active" and .expiry >= $today and .expiry <= $soon)] | length' "$STATE_FILE")
    echo "Akun hampir expired (<=3 hari): ${expiring}"
}

delete_account() {
    # $1=protocol $2=name
    local proto="${1:-}" name="${2:-}"
    if [[ -z "$proto" ]]; then
        read -r -p "Protokol (ssh/vmess/vless/trojan): " proto
    fi
    if [[ -z "$name" ]]; then
        read -r -p "Nama akun: " name
    fi
    case "$proto" in ssh|vmess|vless|trojan) ;; *) error "Protokol tidak valid: $proto"; return 1 ;; esac
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
    if [[ -z "$proto" ]]; then read -r -p "Protokol (ssh/vmess/vless/trojan): " proto; fi
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
# Tampilkan link/config + QR code
# -----------------------------------------------------------------------------
show_link() {
    # $1=protocol $2=name
    local proto="${1:-}" name="${2:-}"
    if [[ -z "$proto" ]]; then read -r -p "Protokol (vmess/vless/trojan/ssh): " proto; fi
    if [[ -z "$name" ]]; then read -r -p "Nama akun: " name; fi
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

    local link="" link_nontls=""
    case "$proto" in
        ssh)
            local exp
            exp=$(jq -r --arg n "$name" '.accounts[] | select(.protocol=="ssh" and .name==$n) | .expiry' "$STATE_FILE")
            echo "================= AKUN SSH: ${name} ================="
            echo "  Host     : ${addr}"
            echo "  Port     : 22"
            echo "  Username : ${name}"
            echo "  Password : (sudah ditampilkan sekali saat dibuat — bila lupa, reset manual: passwd ${name})"
            echo "  Expired  : ${exp}"
            echo "  SSH WS   : ${addr}:80 dan ${addr}:443 (path /ssh-ws, via ws-epro)"
            echo "  Perintah : ssh ${name}@${addr}"
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
            fi
            ;;
        trojan)
            local pw trojan_path
            pw=$(jq -r --arg n "$name" '.accounts[] | select(.protocol=="trojan" and .name==$n) | .password' "$STATE_FILE")
            trojan_path=$(state_get '.install.ws_paths.trojan // "/trojan"')
            if [[ "$mode" == "domain" ]]; then
                link="trojan://${pw}@${addr}:443?security=tls&type=ws&host=${addr}&path=${trojan_path}#${name}"
                link_nontls="trojan://${pw}@${addr}:80?security=none&type=ws&host=${addr}&path=${trojan_path}#${name}-nontls"
            else
                # Mode reality: Trojan lewat WS 10003 tanpa TLS (port dibuka UFW bila perlu).
                link="trojan://${pw}@${addr}:10003?security=none&type=ws&path=${trojan_path}#${name}"
            fi
            ;;
        *)
            error "Protokol tidak dikenal: $proto"
            return 1
            ;;
    esac

    echo "================= LINK ${proto^^}: ${name} ================="
    echo "-- TLS (port 443) --"
    echo "$link"
    if [[ -n "$link_nontls" ]]; then
        echo
        echo "-- Non-TLS (port 80) --"
        echo "$link_nontls"
    fi
    echo
    # QR code di terminal (butuh qrencode) + opsi simpan PNG.
    if command -v qrencode >/dev/null 2>&1; then
        qrencode -t ANSIUTF8 "$link"
        local save=""
        read -r -p "Simpan QR sebagai PNG di /root/${name}-qr.png? [y/N]: " save
        if [[ "${save:-}" =~ ^[Yy]$ ]]; then
            qrencode -o "/root/${name}-qr.png" "$link"
            info "QR disimpan: /root/${name}-qr.png"
        fi
    else
        warn "qrencode tidak tersedia — install dengan: apt install qrencode"
    fi
    echo "Import link di atas ke v2rayNG / NekoBox / Streisand / FoXray."
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
# Menu interaktif
# -----------------------------------------------------------------------------
show_header() {
    local mode domain xray_status total
    mode=$(state_get '.install.mode // ""')
    domain=$(state_get '.install.domain // ""')
    total=$(jq -r '.accounts | length' "$STATE_FILE" 2>/dev/null || echo 0)
    if systemctl is-active --quiet xray 2>/dev/null; then xray_status="ON"; else xray_status="OFF"; fi
    clear 2>/dev/null || true
    printf '%b\n' "${C_MAGENTA}============================================================${C_RESET}"
    printf '%b\n' "${C_MAGENTA}   VPS MANAGER — SSH / VMess / VLESS / Trojan (Xray-core)   ${C_RESET}"
    printf '%b\n' "${C_MAGENTA}============================================================${C_RESET}"
    printf '  Mode   : %s\n' "${mode:-belum install}"
    printf '  Domain : %s\n' "${domain:-—}"
    printf '  Xray   : %s   |   Akun: %s\n' "$xray_status" "$total"
    printf '%b\n' "${C_MAGENTA}------------------------------------------------------------${C_RESET}"
}

show_menu() {
    echo "  1) Install/Update dependensi & Xray"
    echo "  2) Buat akun SSH"
    echo "  3) Buat akun VMess"
    echo "  4) Buat akun VLESS"
    echo "  5) Buat akun Trojan"
    echo "  6) List semua akun + status expired"
    echo "  7) Hapus akun"
    echo "  8) Perpanjang masa aktif akun"
    echo "  9) Tampilkan link/config + QR code"
    echo "  10) Uninstall bersih"
    echo "  0) Keluar"
    echo
}

menu_loop() {
    while true; do
        show_header
        show_menu
        local pilih=""
        read -r -p "Pilih menu [0-10]: " pilih
        # PENTING: setiap aksi dibungkus "|| warn" supaya kegagalan (mis. install
        # batal karena port dipakai) kembali ke menu, BUKAN keluar script.
        # Sebelum perbaikan ini, "return 1" dari do_install + set -e membuat
        # script langsung lompat ke prompt shell seperti yang dilaporkan user.
        case "$pilih" in
            1)  do_install || warn "Menu 1 tidak selesai — kembali ke menu." ;;
            2)  create_ssh || warn "Buat akun SSH tidak selesai — kembali ke menu." ;;
            3)  create_vmess || warn "Buat akun VMess tidak selesai — kembali ke menu." ;;
            4)  create_vless || warn "Buat akun VLESS tidak selesai — kembali ke menu." ;;
            5)  create_trojan || warn "Buat akun Trojan tidak selesai — kembali ke menu." ;;
            6)  list_accounts || warn "List akun gagal — kembali ke menu." ;;
            7)  delete_account || warn "Hapus akun tidak selesai — kembali ke menu." ;;
            8)  renew_account || warn "Perpanjang tidak selesai — kembali ke menu." ;;
            9)  show_link || warn "Tampilkan link gagal — kembali ke menu." ;;
            10) do_uninstall || warn "Uninstall tidak selesai — kembali ke menu." ;;
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
    if ss -tln 2>/dev/null | grep -q ':443 '; then
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
    if ss -tln 2>/dev/null | grep -q ':10090 '; then
        info "Port 10090 (ws-epro): LISTEN"
    else
        warn "Port 10090 (ws-epro): tidak LISTEN"
    fi
    local pp
    for pp in 10001 10002 10003 10004 10085; do
        if ss -tln 2>/dev/null | grep -q ":${pp} "; then
            info "Port ${pp} (Xray): LISTEN"
        else
            warn "Port ${pp} (Xray): tidak LISTEN"
        fi
    done
    if [[ "$mode" == "domain" && -n "$domain" ]]; then
        local vp code
        vp=$(state_get '.install.ws_paths.vmess // "/vmess"')
        code=$(curl -sk --max-time 8 --resolve "${domain}:443:127.0.0.1" "https://${domain}/" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
        if [[ "$code" == "200" ]]; then
            info "HTTPS ${domain}/ : 200 (Nginx + TLS OK)"
        else
            error "HTTPS ${domain}/ : ${code} (Nginx/TLS bermasalah)"
            ok=0
        fi
        code=$(curl -sk --max-time 8 --resolve "${domain}:443:127.0.0.1" "https://${domain}${vp}" \
            -H "Connection: Upgrade" -H "Upgrade: websocket" \
            -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
            -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
        case "$code" in
            400) info "WS ${vp} : 400 (NORMAL — Nginx terus ke Xray, tinggal handshake VMess klien)" ;;
            200) error "WS ${vp} : 200 — path TIDAK dikenali Nginx, link klien pakai path lama! Ambil link baru dari menu 9."; ok=0 ;;
            502) error "WS ${vp} : 502 — Nginx hidup tapi Xray tidak menjawab (cek: systemctl status xray)"; ok=0 ;;
            *)   error "WS ${vp} : ${code} — rantai putus di Nginx/Xray"; ok=0 ;;
        esac
        # Link permanen script harus bisa diunduh (200).
        code=$(curl -sk --max-time 8 --resolve "${domain}:443:127.0.0.1" "https://${domain}/vps-manager.sh" -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
        if [[ "$code" == "200" ]]; then
            info "Link permanen https://${domain}/vps-manager.sh : 200 (bisa diunduh, tidak expired)"
        else
            warn "Link permanen https://${domain}/vps-manager.sh : ${code} (cek Nginx location /vps-manager.sh)"
        fi
        # Uji yang sama di port 80 non-TLS.
        code=$(curl -s --max-time 8 "http://${domain}${vp}" \
            -H "Connection: Upgrade" -H "Upgrade: websocket" \
            -H "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==" -H "Sec-WebSocket-Version: 13" \
            -o /dev/null -w "%{http_code}" 2>/dev/null || echo "000")
        case "$code" in
            400) info "WS non-TLS ${vp} (port 80) : 400 (NORMAL)" ;;
            200) error "WS non-TLS ${vp} (port 80) : 200 — path tidak dikenali di port 80"; ok=0 ;;
            502) error "WS non-TLS ${vp} (port 80) : 502 — Nginx hidup tapi Xray tidak menjawab"; ok=0 ;;
            *)   error "WS non-TLS ${vp} (port 80) : ${code} — cek Nginx port 80"; ok=0 ;;
        esac
    elif [[ "$mode" == "reality" ]]; then
        if ss -tln 2>/dev/null | grep -q ':443 '; then
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
vps-manager — pengelola akun SSH / VMess / VLESS / Trojan (Xray-core)

PENGGUNAAN:
  bash vps-manager.sh                        Menu interaktif
  menu                                       Sama dengan di atas (pintasan,
                                             dibuat otomatis saat install)
  bash vps-manager.sh --help                 Tampilkan bantuan ini

  bash vps-manager.sh --install --mode domain --domain contoh.com --email admin@contoh.com
  bash vps-manager.sh --install --mode reality

  bash vps-manager.sh --create ssh    --name user1 --days 30 [--password rahasia]
  bash vps-manager.sh --create vmess  --name user1 --days 30 [--limit-ip 2]
  bash vps-manager.sh --create vless  --name user1 --days 30 [--transport ws|tcp]
  bash vps-manager.sh --create trojan --name user1 --days 30 [--password rahasia]

  bash vps-manager.sh --list
  bash vps-manager.sh --delete --protocol vmess --name user1
  bash vps-manager.sh --renew  --protocol vmess --name user1 --days 30
  bash vps-manager.sh --show   --protocol vless --name user1
  bash vps-manager.sh --check          Cek rantai koneksi Nginx -> Xray -> path WS
  bash vps-manager.sh --check-expired
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

    local cmd="" mode="" domain="" email="" proto="" name="" days="" password="" transport="" limit_ip=""
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
            --check) cmd="check"; shift ;;
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
                *) error "--create butuh protokol: ssh|vmess|vless|trojan"; exit 1 ;;
            esac
            ;;
        delete) delete_account "$proto" "$name" ;;
        list) list_accounts ;;
        renew) renew_account "$proto" "$name" "$days" ;;
        show) show_link "$proto" "$name" ;;
        check-expired) check_expired ;;
        check) do_check ;;
        uninstall) do_uninstall ;;
        *) error "Tidak ada perintah. Jalankan: bash vps-manager.sh --help"; exit 1 ;;
    esac
}

main "$@"
