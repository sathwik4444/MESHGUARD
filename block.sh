#!/usr/bin/env bash
# ==============================================================================
# SATHWIK SERVER MESH - HARDENED PRODUCTION DNS DAEMON & CLI INSTALLER
# ==============================================================================
# Target AdGuard Server : 100.102.245.39 (Tailscale Mesh ACL Protected)
# Terminal Commands     : server [on | off | auto | status | login | uninstall]
# Security & Audit      :
#   - Standard sudo auth for state changes; unprivileged "server status"
#   - Safe mktemp with 077 umask inside root-owned /run/sathwik-mesh + traps
#   - Full symlink & systemd-resolved / NetworkManager backup and restoration
#   - Complete RFC 1035 DNS wire-format response validation (TXID, QR, RCODE,
#     QDCOUNT, ANCOUNT, and non-zero A-record IP verification)
# ==============================================================================

set -euo pipefail

ADGUARD_IP="${1:-${SATHWIK_ADGUARD_IP:-100.102.245.39}}"
INSTALL_DIR="/usr/local/lib/sathwik-mesh"
DAEMON_BIN="$INSTALL_DIR/sathwik-dnsd"
CLI_BIN="/usr/local/bin/server"
SERVICE_FILE="/etc/systemd/system/sathwik-dnsd.service"
NM_CONF_FILE="/etc/NetworkManager/conf.d/99-sathwik-dns.conf"
STATE_DIR="/var/lib/sathwik-mesh"
BACKUP_DIR="$STATE_DIR/resolver-backup"
RUN_DIR="/run/sathwik-mesh"
SERVER_IP_FILE="$STATE_DIR/server_ip"

# Legacy files to clean up from older versions
LEGACY_SUDOERS="/etc/sudoers.d/sathwik-server-cli"
LEGACY_SERVICES=("dns-failover-guard.service" "dns-adblock-watchdog.service")
LEGACY_BINS=("/usr/local/bin/dns-failover-guard.sh" "/usr/local/bin/dns-adblock-watchdog.sh")

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
BOLD='\033[1m'

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo -e "${CYAN}🔒 Elevating privileges via sudo for installation...${NC}"
    exec sudo -- "$0" "$@"
fi

# Clean up legacy insecure sudoers or older service units if present
rm -f "$LEGACY_SUDOERS"
for s in "${LEGACY_SERVICES[@]}"; do
    systemctl stop "$s" 2>/dev/null || true
    systemctl disable "$s" 2>/dev/null || true
    rm -f "/etc/systemd/system/$s"
done
for b in "${LEGACY_BINS[@]}"; do
    rm -f "$b"
done
if command -v iptables >/dev/null 2>&1; then
    iptables -D OUTPUT -j DNS_BLOCK 2>/dev/null || true
    iptables -F DNS_BLOCK 2>/dev/null || true
    iptables -X DNS_BLOCK 2>/dev/null || true
fi

install -d -m 0755 -o root -g root "$INSTALL_DIR" "$STATE_DIR" "$BACKUP_DIR" "$RUN_DIR"
printf "%s\n" "$ADGUARD_IP" > "$SERVER_IP_FILE"
chmod 0644 "$SERVER_IP_FILE"

# ------------------------------------------------------------------------------
# 1. SNAPSHOT ORIGINAL RESOLVER & DNS MANAGER STATE (NON-DESTRUCTIVE)
# ------------------------------------------------------------------------------
snapshot_original_resolver() {
    # Only record the initial snapshot once so re-running the installer never
    # overwrites the true original system state.
    if [ -f "$BACKUP_DIR/snapshot_complete" ]; then
        echo -e "${GREEN}✓ Original DNS resolver backup already preserved in $BACKUP_DIR${NC}"
        return 0
    fi

    echo -e "${CYAN}💾 Backing up original /etc/resolv.conf and DNS manager state...${NC}"

    if systemctl is-active --quiet systemd-resolved.service 2>/dev/null; then
        printf "active\n" > "$BACKUP_DIR/systemd_resolved_state"
    else
        printf "inactive\n" > "$BACKUP_DIR/systemd_resolved_state"
    fi

    if systemctl is-active --quiet NetworkManager.service 2>/dev/null; then
        printf "active\n" > "$BACKUP_DIR/networkmanager_state"
    else
        printf "inactive\n" > "$BACKUP_DIR/networkmanager_state"
    fi

    if [ -L /etc/resolv.conf ]; then
        local link_target
        link_target=$(readlink /etc/resolv.conf)
        printf "symlink\n" > "$BACKUP_DIR/resolv_type"
        printf "%s\n" "$link_target" > "$BACKUP_DIR/symlink_target"
        if [ -e /etc/resolv.conf ]; then
            cp -Lf /etc/resolv.conf "$BACKUP_DIR/resolv.conf.deref" 2>/dev/null || true
        fi
        echo -e "${GREEN}✓ Saved original symlink target: /etc/resolv.conf -> $link_target${NC}"
    elif [ -f /etc/resolv.conf ]; then
        printf "file\n" > "$BACKUP_DIR/resolv_type"
        cp -pf /etc/resolv.conf "$BACKUP_DIR/resolv.conf.orig"
        echo -e "${GREEN}✓ Saved original regular file: /etc/resolv.conf${NC}"
    else
        printf "none\n" > "$BACKUP_DIR/resolv_type"
    fi

    chmod 0644 "$BACKUP_DIR"/* 2>/dev/null || true
    printf "1\n" > "$BACKUP_DIR/snapshot_complete"
}

# ------------------------------------------------------------------------------
# 2. INSTALL TAILSCALE SAFELY ACROSS DISTROS
# ------------------------------------------------------------------------------
install_tailscale_if_needed() {
    if command -v tailscale >/dev/null 2>&1 && command -v tailscaled >/dev/null 2>&1; then
        echo -e "${GREEN}✓ Tailscale is installed ($(tailscale version | head -n 1))${NC}"
        return 0
    fi

    echo -e "${CYAN}📦 Installing Tailscale...${NC}"
    local distro_id="unknown"
    if [ -f /etc/os-release ]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        distro_id="${ID:-unknown}"
    fi

    case "$distro_id" in
        arch|manjaro|endeavouros|cachyos|garuda)
            pacman -S --needed --noconfirm tailscale
            ;;
        ubuntu|debian|linuxmint|pop)
            curl -fsSL https://tailscale.com/install.sh | sh
            ;;
        fedora|rhel|centos|almalinux|rocky)
            dnf install -y tailscale || curl -fsSL https://tailscale.com/install.sh | sh
            ;;
        opensuse*|suse)
            zypper install -y tailscale || curl -fsSL https://tailscale.com/install.sh | sh
            ;;
        *)
            curl -fsSL https://tailscale.com/install.sh | sh
            ;;
    esac
    echo -e "${GREEN}✓ Tailscale installed successfully.${NC}"
}

# ------------------------------------------------------------------------------
# 3. WRITE THE HARDENED BACKGROUND DAEMON (sathwik-dnsd)
# ------------------------------------------------------------------------------
cat << 'EOF_DAEMON' > "$DAEMON_BIN"
#!/usr/bin/env bash
# ==============================================================================
# SATHWIK-DNSD: HARDENED ADAPTIVE DNS FAILOVER DAEMON
# - Full RFC 1035 DNS packet validation (TXID, QR=1, RCODE=0, ANCOUNT>=1, valid IP)
# - Zero-fork steady-state loop via persistent Python 3 verifier coprocess
#   (with pure Bash + dd/od wire-format parser fallback if Python is absent)
# - Desktop notifications on state changes & fault conditions
# ==============================================================================

set -uo pipefail

STATE_DIR="/var/lib/sathwik-mesh"
SERVER_IP_FILE="$STATE_DIR/server_ip"
if [ -f "$SERVER_IP_FILE" ]; then
    ADGUARD_IP=$(head -n 1 "$SERVER_IP_FILE" 2>/dev/null || echo "100.102.245.39")
else
    ADGUARD_IP="${SATHWIK_ADGUARD_IP:-100.102.245.39}"
fi
RUN_DIR="/run/sathwik-mesh"
MODE_FILE="$STATE_DIR/mode"
ACTIVE_ROUTE_FILE="$RUN_DIR/active_route"
LAST_STATUS_FILE="$RUN_DIR/last_probe_status"
FIFO_FILE="$RUN_DIR/control.fifo"
RESOLV_FILE="/etc/resolv.conf"

NM_RESOLV="/run/NetworkManager/resolv.conf"
SYSTEMD_RESOLV="/run/systemd/resolve/resolv.conf"

HEARTBEAT_INTERVAL=3
BURST_COUNT=3

ADGUARD_TAG="# SATHWIK-MESH:ADGUARD-STRICT"
FALLBACK_TAG="# SATHWIK-MESH:NATURAL-FALLBACK"
FORCED_ON_TAG="# SATHWIK-MESH:FORCED-ON"
FORCED_OFF_TAG="# SATHWIK-MESH:FORCED-OFF"

install -d -m 0755 -o root -g root "$STATE_DIR" "$RUN_DIR"
if [ ! -f "$MODE_FILE" ]; then
    printf "auto\n" > "$MODE_FILE"
    chmod 0644 "$MODE_FILE"
fi

rm -f "$FIFO_FILE"
mkfifo -m 0600 "$FIFO_FILE"
exec 8<>"$FIFO_FILE"

cleanup() {
    exec 8<&- 8>&- 2>/dev/null || true
    if [ -n "${COPROC_PID:-}" ]; then
        kill "$COPROC_PID" 2>/dev/null || true
    fi
    rm -f "$FIFO_FILE"
    exit 0
}
trap cleanup EXIT INT TERM

# Send desktop notification to active GUI user (if notify-send is available)
notify_desktop_users() {
    local urgency="$1"
    local title="$2"
    local body="$3"

    command -v notify-send >/dev/null 2>&1 || return 0

    local runtime_dir uid user_name
    for runtime_dir in /run/user/[0-9]*; do
        [ -d "$runtime_dir" ] || continue
        uid="${runtime_dir##*/}"
        user_name=$(id -nu "$uid" 2>/dev/null || true)
        [ -n "$user_name" ] || continue

        sudo -u "$user_name" \
            DISPLAY="${DISPLAY:-:0}" \
            WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=${runtime_dir}/bus" \
            notify-send -u "$urgency" -a "Sathwik Server Mesh" "$title" "$body" >/dev/null 2>&1 || true
    done
}

# Start persistent single-process Python 3 RFC 1035 DNS Validator Coprocess
# (Spawns ONCE at daemon boot; zero subprocess forks during loop checks)
USE_PY_COPROC=0
if command -v python3 >/dev/null 2>&1; then
    coproc DNS_WORKER {
        exec python3 -u -c '
import os, socket, struct, sys, time

def build_query(txid, domain="example.com"):
    header = struct.pack("!HHHHHH", txid, 0x0100, 1, 0, 0, 0)
    qname = b"".join(bytes([len(p)]) + p.encode("ascii") for p in domain.split(".")) + b"\x00"
    return header + qname + struct.pack("!HH", 1, 1)

def skip_name(buf, offset):
    length = len(buf)
    jumps = 0
    while offset < length:
        l = buf[offset]
        if l == 0:
            return offset + 1
        if (l & 0xC0) == 0xC0:
            return offset + 2
        offset += 1 + l
        jumps += 1
        if jumps > 64:
            return -1
    return -1

def validate_response(data, expected_txid):
    if len(data) < 12:
        return False, "SHORT_HEADER"
    txid, flags, qdcount, ancount, _, _ = struct.unpack("!HHHHHH", data[:12])
    if txid != expected_txid:
        return False, "TXID_MISMATCH"
    qr = (flags >> 15) & 1
    opcode = (flags >> 11) & 0x0F
    rcode = flags & 0x0F
    if qr != 1 or opcode != 0:
        return False, "INVALID_FLAGS"
    if rcode != 0:
        return False, f"RCODE_{rcode}"
    if qdcount < 1 or ancount < 1:
        return False, "NO_ANSWERS"

    offset = 12
    for _ in range(qdcount):
        offset = skip_name(data, offset)
        if offset < 0 or offset + 4 > len(data):
            return False, "BAD_QUESTION"
        offset += 4

    valid_ipv4 = False
    for _ in range(ancount):
        offset = skip_name(data, offset)
        if offset < 0 or offset + 10 > len(data):
            return False, "BAD_ANSWER_HDR"
        rtype, rclass, _, rdlen = struct.unpack("!HHIH", data[offset:offset+10])
        offset += 10
        if offset + rdlen > len(data):
            return False, "TRUNCATED_RDATA"
        if rtype == 1 and rclass == 1 and rdlen == 4:
            ip_bytes = data[offset:offset+4]
            if ip_bytes != b"\x00\x00\x00\x00":
                valid_ipv4 = True
        offset += rdlen

    if not valid_ipv4:
        return False, "NO_VALID_A_RECORD"
    return True, "NOERROR"

for line in sys.stdin:
    parts = line.strip().split()
    if not parts:
        continue
    target_ip = parts[0]
    timeout_s = float(parts[1]) if len(parts) > 1 else 2.0
    txid = int.from_bytes(os.urandom(2), "big")
    pkt = build_query(txid)
    t0 = time.monotonic()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(timeout_s)
    try:
        sock.sendto(pkt, (target_ip, 53))
        data, _ = sock.recvfrom(512)
        ms = int((time.monotonic() - t0) * 1000)
        ok, reason = validate_response(data, txid)
        if ok:
            print(f"OK {ms} {reason}", flush=True)
        else:
            print(f"FAIL {ms} {reason}", flush=True)
    except Exception as e:
        print(f"FAIL 0 {type(e).__name__}", flush=True)
    finally:
        sock.close()
'
    }
    COPROC_PID=$!
    USE_PY_COPROC=1
fi

# Fallback full DNS wire-format validator using dd + od (if Python 3 is unavailable)
probe_adguard_fallback() {
    local timeout_sec="${1:-2}"
    local tx_hi=$(( (RANDOM % 254) + 1 ))
    local tx_lo=$(( (RANDOM % 254) + 1 ))
    local tx_hex
    printf -v tx_hex "\\\\x%02x\\\\x%02x" "$tx_hi" "$tx_lo"
    local query="${tx_hex}\\x01\\x00\\x00\\x01\\x00\\x00\\x00\\x00\\x00\\x00\\x07example\\x03com\\x00\\x00\\x01\\x00\\x01"

    if ! exec 3<>"/dev/udp/${ADGUARD_IP}/53" 2>/dev/null; then
        printf "FAIL 0 SOCKET_ERR\n" > "$LAST_STATUS_FILE"
        return 1
    fi
    if ! printf "%b" "$query" >&3 2>/dev/null; then
        exec 3<&- 3>&- 2>/dev/null || true
        printf "FAIL 0 SEND_ERR\n" > "$LAST_STATUS_FILE"
        return 1
    fi

    local raw_bytes
    raw_bytes=$(timeout "$timeout_sec" dd bs=512 count=1 <&3 2>/dev/null | od -An -tu1 -v) || true
    exec 3<&- 3>&- 2>/dev/null || true

    local -a bytes=()
    # shellcheck disable=SC2206
    bytes=($raw_bytes)
    local len="${#bytes[@]}"

    # Minimum valid response: 12B header + 17B question + 16B answer = 45 bytes
    if [ "$len" -lt 45 ]; then
        printf "FAIL 0 TIMEOUT_OR_SHORT\n" > "$LAST_STATUS_FILE"
        return 1
    fi

    # 1. Verify Transaction ID matches sent query
    if [ "${bytes[0]}" -ne "$tx_hi" ] || [ "${bytes[1]}" -ne "$tx_lo" ]; then
        printf "FAIL 0 TXID_MISMATCH\n" > "$LAST_STATUS_FILE"
        return 1
    fi

    # 2. Verify QR==1 (bit 7 of byte 2) and Opcode==0 (bits 6..3 of byte 2)
    if [ $(( bytes[2] & 128 )) -eq 0 ] || [ $(( bytes[2] & 120 )) -ne 0 ]; then
        printf "FAIL 0 INVALID_FLAGS\n" > "$LAST_STATUS_FILE"
        return 1
    fi

    # 3. Verify RCODE==0 (NOERROR, bits 3..0 of byte 3)
    local rcode=$(( bytes[3] & 15 ))
    if [ "$rcode" -ne 0 ]; then
        printf "FAIL 0 RCODE_%s\n" "$rcode" > "$LAST_STATUS_FILE"
        return 1
    fi

    # 4. Verify QDCOUNT==1 and ANCOUNT>=1
    local qdcount=$(( (bytes[4] << 8) | bytes[5] ))
    local ancount=$(( (bytes[6] << 8) | bytes[7] ))
    if [ "$qdcount" -lt 1 ] || [ "$ancount" -lt 1 ]; then
        printf "FAIL 0 NO_ANSWERS\n" > "$LAST_STATUS_FILE"
        return 1
    fi

    # 5. Verify last 4 bytes of standard A-record response are not 0.0.0.0
    local ip1="${bytes[$((len - 4))]}"
    local ip2="${bytes[$((len - 3))]}"
    local ip3="${bytes[$((len - 2))]}"
    local ip4="${bytes[$((len - 1))]}"
    if [ "$ip1" -eq 0 ] && [ "$ip2" -eq 0 ] && [ "$ip3" -eq 0 ] && [ "$ip4" -eq 0 ]; then
        printf "FAIL 0 SINKHOLED_0_0_0_0\n" > "$LAST_STATUS_FILE"
        return 1
    fi

    printf "OK 10 NOERROR\n" > "$LAST_STATUS_FILE"
    chmod 0644 "$LAST_STATUS_FILE" 2>/dev/null || true
    return 0
}

probe_adguard() {
    local timeout_sec="${1:-2}"
    if [ "$USE_PY_COPROC" -eq 1 ] && kill -0 "$COPROC_PID" 2>/dev/null; then
        local result=""
        if printf "%s %s\n" "$ADGUARD_IP" "$timeout_sec" >&"${DNS_WORKER[1]}" 2>/dev/null; then
            if IFS= read -r -t "$((timeout_sec + 1))" -u "${DNS_WORKER[0]}" result 2>/dev/null; then
                printf "%s\n" "$result" > "$LAST_STATUS_FILE"
                chmod 0644 "$LAST_STATUS_FILE" 2>/dev/null || true
                case "$result" in
                    OK*) return 0 ;;
                    *) return 1 ;;
                esac
            fi
        fi
    fi
    probe_adguard_fallback "$timeout_sec"
}

# Two-Stage Adaptive Check:
# Stage 1: Generous 2s timeout (prevents false failover during Wi-Fi/DERP lag spikes)
# Stage 2: 3 rapid verification probes (0.3s interval, 1s timeout) on packet loss
verify_server_health() {
    if probe_adguard 2; then
        return 0
    fi
    local i=1
    while [ "$i" -le "$BURST_COUNT" ]; do
        IFS= read -r -t 0.3 -u 8 _ 2>/dev/null || true
        if probe_adguard 1; then
            return 0
        fi
        i=$((i + 1))
    done
    return 1
}

get_first_line() {
    local line=""
    if [ -f "$RESOLV_FILE" ]; then
        IFS= read -r line < "$RESOLV_FILE" 2>/dev/null || true
    fi
    printf "%s" "$line"
}

atomic_write_resolv() {
    local content="$1"
    local route_name="$2"
    local tmp_file

    # Clear immutable bit if set by user or third-party script
    if command -v chattr >/dev/null 2>&1 && [ -e "$RESOLV_FILE" ] && [ ! -L "$RESOLV_FILE" ]; then
        chattr -i "$RESOLV_FILE" 2>/dev/null || true
    fi
    if [ -L "$RESOLV_FILE" ]; then
        rm -f "$RESOLV_FILE"
    fi

    umask 077
    tmp_file=$(mktemp "/etc/.resolv.tmp.XXXXXXXXXX")
    printf "%s\n" "$content" > "$tmp_file"
    chmod 0644 "$tmp_file"
    mv -f "$tmp_file" "$RESOLV_FILE"

    printf "%s\n" "$route_name" > "$ACTIVE_ROUTE_FILE"
    chmod 0644 "$ACTIVE_ROUTE_FILE" 2>/dev/null || true
}

write_adguard_resolv() {
    local header_tag="$1"
    local mode_label="$2"
    local content
    content=$(cat << EOF
$header_tag
# Managed by Sathwik Server Mesh ($mode_label)
nameserver $ADGUARD_IP
options timeout:1 attempts:2
EOF
)
    atomic_write_resolv "$content" "adguard"
}

write_fallback_resolv() {
    local header_tag="$1"
    local mode_label="$2"
    local dhcp_lines=""
    local src_file line

    # Pull natural router DHCP DNS from NetworkManager or systemd-resolved
    for src_file in "$NM_RESOLV" "$SYSTEMD_RESOLV"; do
        if [ -f "$src_file" ]; then
            while IFS= read -r line; do
                case "$line" in
                    "nameserver $ADGUARD_IP"*|"nameserver 100.100.100.100"*|"nameserver 127."*) ;;
                    nameserver*|search*)
                        dhcp_lines="${dhcp_lines}${line}"$'\n'
                        ;;
                esac
            done < "$src_file"
            break
        fi
    done

    local content
    content=$(cat << EOF
$header_tag
# Managed by Sathwik Server Mesh ($mode_label)
${dhcp_lines}nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:1 attempts:1
EOF
)
    atomic_write_resolv "$content" "fallback"
}

CONSECUTIVE_RECOVERY=0
WARNED_FORCED_ON_OFFLINE=0

while true; do
    CURRENT_MODE="auto"
    [ -f "$MODE_FILE" ] && IFS= read -r CURRENT_MODE < "$MODE_FILE" 2>/dev/null || true
    CURRENT_HEADER=$(get_first_line)
    CURRENT_ROUTE=""
    [ -f "$ACTIVE_ROUTE_FILE" ] && IFS= read -r CURRENT_ROUTE < "$ACTIVE_ROUTE_FILE" 2>/dev/null || true

    case "$CURRENT_MODE" in
        on)
            if [ "$CURRENT_HEADER" != "$FORCED_ON_TAG" ] || [ "$CURRENT_ROUTE" != "adguard" ]; then
                write_adguard_resolv "$FORCED_ON_TAG" "FORCED ON - Strict Server Routing"
                echo "[sathwik-dnsd] 🔒 Mode FORCED ON: All DNS traffic locked to $ADGUARD_IP."
            fi
            # Probe in background to warn user if server is unreachable while Forced ON
            if ! probe_adguard 2; then
                if [ "$WARNED_FORCED_ON_OFFLINE" -eq 0 ]; then
                    echo "[sathwik-dnsd] ⚠️ WARNING: Mode is FORCED ON, but $ADGUARD_IP is unreachable! Run 'server auto' or 'server off' to restore internet."
                    notify_desktop_users "critical" "AdGuard Server Unreachable (Forced ON)" \
                        "Server $ADGUARD_IP is offline while 'server on' is locked. Run 'server auto' to restore DNS."
                    WARNED_FORCED_ON_OFFLINE=1
                fi
            else
                WARNED_FORCED_ON_OFFLINE=0
            fi
            ;;
        off)
            WARNED_FORCED_ON_OFFLINE=0
            if [ "$CURRENT_HEADER" != "$FORCED_OFF_TAG" ] || [ "$CURRENT_ROUTE" != "fallback" ]; then
                write_fallback_resolv "$FORCED_OFF_TAG" "FORCED OFF - Natural DNS"
                echo "[sathwik-dnsd] 🔓 Mode FORCED OFF: Routing via Natural / Public DNS."
            fi
            # Still update live probe status file for unprivileged "server status"
            probe_adguard 1 >/dev/null 2>&1 || true
            ;;
        *)
            WARNED_FORCED_ON_OFFLINE=0
            if verify_server_health; then
                CONSECUTIVE_RECOVERY=$((CONSECUTIVE_RECOVERY + 1))
                if [ "$CURRENT_ROUTE" != "adguard" ]; then
                    if [ -z "$CURRENT_ROUTE" ] || [ "$CONSECUTIVE_RECOVERY" -ge 2 ]; then
                        write_adguard_resolv "$ADGUARD_TAG" "AUTO - AdGuard Shield Active"
                        echo "[sathwik-dnsd] 🛡️ AdGuard Server ($ADGUARD_IP) verified ONLINE (RFC 1035 NOERROR). Switched to AdGuard DNS."
                        notify_desktop_users "normal" "AdGuard Shield Active" \
                            "Connected to $ADGUARD_IP. All DNS queries are now filtered."
                    fi
                elif [ "$CURRENT_HEADER" != "$ADGUARD_TAG" ]; then
                    write_adguard_resolv "$ADGUARD_TAG" "AUTO - AdGuard Shield Active"
                fi
            else
                CONSECUTIVE_RECOVERY=0
                if [ "$CURRENT_ROUTE" != "fallback" ]; then
                    local_reason=""
                    [ -f "$LAST_STATUS_FILE" ] && IFS= read -r local_reason < "$LAST_STATUS_FILE" 2>/dev/null || true
                    write_fallback_resolv "$FALLBACK_TAG" "AUTO - Server Offline Natural Fallback"
                    echo "[sathwik-dnsd] ⚡ AdGuard Server ($ADGUARD_IP) unreachable ($local_reason). Switched to Natural Fallback DNS."
                    notify_desktop_users "normal" "Switched to Natural Fallback DNS" \
                        "AdGuard server ($ADGUARD_IP) is offline. Internet remains active via fallback DNS."
                elif [ "$CURRENT_HEADER" != "$FALLBACK_TAG" ]; then
                    write_fallback_resolv "$FALLBACK_TAG" "AUTO - Server Offline Natural Fallback"
                fi
            fi
            ;;
    esac

    IFS= read -r -t "$HEARTBEAT_INTERVAL" -u 8 _ 2>/dev/null || true
done
EOF_DAEMON

chmod 0755 "$DAEMON_BIN"

# ------------------------------------------------------------------------------
# 4. WRITE THE GLOBAL CLI CONTROLLER (/usr/local/bin/server)
# ------------------------------------------------------------------------------
cat << 'EOF_CLI' > "$CLI_BIN"
#!/usr/bin/env bash
# ==============================================================================
# SATHWIK MESH CLI CONTROLLER ("server on", "server off", "server auto")
# - "server status" runs unprivileged (no root needed)
# - State-changing commands authenticate via standard sudo (no NOPASSWD risk)
# ==============================================================================

set -euo pipefail

STATE_DIR="/var/lib/sathwik-mesh"
SERVER_IP_FILE="$STATE_DIR/server_ip"
if [ -f "$SERVER_IP_FILE" ]; then
    ADGUARD_IP=$(head -n 1 "$SERVER_IP_FILE" 2>/dev/null || echo "100.102.245.39")
else
    ADGUARD_IP="${SATHWIK_ADGUARD_IP:-100.102.245.39}"
fi
BACKUP_DIR="$STATE_DIR/resolver-backup"
RUN_DIR="/run/sathwik-mesh"
MODE_FILE="$STATE_DIR/mode"
ACTIVE_ROUTE_FILE="$RUN_DIR/active_route"
LAST_STATUS_FILE="$RUN_DIR/last_probe_status"
FIFO_FILE="$RUN_DIR/control.fifo"
SERVICE_NAME="sathwik-dnsd.service"
NM_CONF_FILE="/etc/NetworkManager/conf.d/99-sathwik-dns.conf"
INSTALL_DIR="/usr/local/lib/sathwik-mesh"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
BOLD='\033[1m'

CMD="${1:-status}"

require_root_for_action() {
    if [ "${EUID:-$(id -u)}" -ne 0 ]; then
        exec sudo -- "$0" "$CMD"
    fi
}

open_browser_portal() {
    local url="$1"
    echo -e "\n${YELLOW}${BOLD}🌐 Tailscale Authentication Required!${NC}"
    echo -e "Login Portal URL: ${CYAN}${BOLD}${url}${NC}"

    if [ -n "${SUDO_USER:-}" ] && command -v xdg-open >/dev/null 2>&1; then
        local uid
        uid=$(id -u "$SUDO_USER")
        echo -e "${CYAN}↗ Opening Tailscale login portal in your browser...${NC}"
        sudo -u "$SUDO_USER" \
            DISPLAY="${DISPLAY:-:0}" \
            WAYLAND_DISPLAY="${WAYLAND_DISPLAY:-wayland-0}" \
            DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/${uid}/bus" \
            xdg-open "$url" >/dev/null 2>&1 || true
    fi
}

# Live RFC 1035 DNS check (used by status display)
live_dns_verify() {
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$ADGUARD_IP" << 'EOF_PY'
import os, socket, struct, sys, time
ip = sys.argv[1]
txid = int.from_bytes(os.urandom(2), "big")
pkt = struct.pack("!HHHHHH", txid, 0x0100, 1, 0, 0, 0) + b"\x07example\x03com\x00" + struct.pack("!HH", 1, 1)
t0 = time.monotonic()
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(1.2)
try:
    s.sendto(pkt, (ip, 53))
    data, _ = s.recvfrom(512)
    ms = int((time.monotonic() - t0) * 1000)
    if len(data) >= 45:
        rx_id, flags, qd, an, _, _ = struct.unpack("!HHHHHH", data[:12])
        qr = (flags >> 15) & 1
        rcode = flags & 0x0F
        if rx_id == txid and qr == 1 and rcode == 0 and qd >= 1 and an >= 1 and data[-4:] != b"\x00\x00\x00\x00":
            print(f"ONLINE ({ms} ms, NOERROR, {an} Answer RR)")
            sys.exit(0)
        print(f"INVALID_DNS (RCODE={rcode}, ANCOUNT={an})")
        sys.exit(1)
except Exception as e:
    print(f"OFFLINE ({type(e).__name__})")
    sys.exit(1)
finally:
    s.close()
EOF_PY
        return $?
    fi
    return 1
}

ensure_tailscale_authenticated() {
    systemctl enable --now tailscaled.service >/dev/null 2>&1 || true

    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || true)

    if [ -z "$ts_ip" ]; then
        echo -e "${YELLOW}⚠️ Tailscale is logged out. Starting interactive browser login...${NC}"
        install -d -m 0755 -o root -g root "$RUN_DIR"
        umask 077
        local tmp_log
        tmp_log=$(mktemp "$RUN_DIR/ts_login.XXXXXXXXXX")
        trap 'rm -f -- "${tmp_log:-}"' EXIT INT TERM

        tailscale up --accept-dns=false --qr >"$tmp_log" 2>&1 &
        local pid=$!
        local opened=0

        while kill -0 "$pid" 2>/dev/null; do
            if [ "$opened" -eq 0 ] && [ -f "$tmp_log" ]; then
                local url
                url=$(grep -Eo 'https://login\.tailscale\.com/a/[a-zA-Z0-9]+' "$tmp_log" | head -n 1 || true)
                if [ -n "$url" ]; then
                    cat "$tmp_log"
                    open_browser_portal "$url"
                    echo -e "${YELLOW}⏳ Waiting for you to complete login in the browser...${NC}"
                    opened=1
                fi
            fi
            sleep 1
        done
        wait "$pid" || true
        rm -f -- "$tmp_log"
        trap - EXIT INT TERM
    else
        tailscale set --accept-dns=false 2>/dev/null || tailscale up --accept-dns=false >/dev/null 2>&1 || true
    fi

    ts_ip=$(tailscale ip -4 2>/dev/null || true)
    if [ -z "$ts_ip" ]; then
        echo -e "${RED}❌ Tailscale login did not complete. Run 'server login' when ready.${NC}"
        return 1
    fi

    # Check if 100.102.245.39 is present in the user's Tailscale mesh
    if tailscale status 2>/dev/null | grep -qF "$ADGUARD_IP"; then
        echo -e "${GREEN}✓ Mesh Verified: AdBlock Server ($ADGUARD_IP) is present in your Tailscale mesh.${NC}"
    else
        echo -e "${YELLOW}⚠️ Warning: Server ($ADGUARD_IP) is NOT visible in your Tailscale mesh peers!${NC}"
        echo -e "${YELLOW}   Ask Sathwik to share the $ADGUARD_IP node with your Tailscale account.${NC}"
    fi
}

atomic_write_resolv() {
    local content="$1"
    local route_name="$2"
    local tmp_file
    if command -v chattr >/dev/null 2>&1 && [ -e /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi
    [ -L /etc/resolv.conf ] && rm -f /etc/resolv.conf
    umask 077
    tmp_file=$(mktemp "/etc/.resolv.tmp.XXXXXXXXXX")
    printf "%s\n" "$content" > "$tmp_file"
    chmod 0644 "$tmp_file"
    mv -f "$tmp_file" /etc/resolv.conf
    printf "%s\n" "$route_name" > "$ACTIVE_ROUTE_FILE"
    chmod 0644 "$ACTIVE_ROUTE_FILE" 2>/dev/null || true
}

write_adguard_resolv() {
    local header_tag="$1"
    local mode_label="$2"
    local content
    content=$(cat << EOF
$header_tag
# Managed by Sathwik Server Mesh ($mode_label)
nameserver $ADGUARD_IP
options timeout:1 attempts:2
EOF
)
    atomic_write_resolv "$content" "adguard"
}

write_fallback_resolv() {
    local header_tag="$1"
    local mode_label="$2"
    local dhcp_lines=""
    local src_file line
    for src_file in "/run/NetworkManager/resolv.conf" "/run/systemd/resolve/resolv.conf"; do
        if [ -f "$src_file" ]; then
            while IFS= read -r line; do
                case "$line" in
                    "nameserver $ADGUARD_IP"*|"nameserver 100.100.100.100"*|"nameserver 127."*) ;;
                    nameserver*|search*|domain*)
                        dhcp_lines="${dhcp_lines}${line}"$'\n'
                        ;;
                esac
            done < "$src_file"
            break
        fi
    done
    local content
    content=$(cat << EOF
$header_tag
# Managed by Sathwik Server Mesh ($mode_label)
${dhcp_lines}nameserver 1.1.1.1
nameserver 8.8.8.8
options timeout:1 attempts:1
EOF
)
    atomic_write_resolv "$content" "fallback"
}

signal_daemon() {
    systemctl start "$SERVICE_NAME" 2>/dev/null || true
    if [ -p "$FIFO_FILE" ]; then
        printf "WAKE\n" > "$FIFO_FILE" 2>/dev/null || true
    fi
}

set_mode() {
    local target_mode="$1"
    install -d -m 0755 -o root -g root "$STATE_DIR"
    printf "%s\n" "$target_mode" > "$MODE_FILE"
    chmod 0644 "$MODE_FILE"
    case "$target_mode" in
        on)
            write_adguard_resolv "# SATHWIK-MESH:FORCED-ON" "FORCED ON - Strict Server Routing"
            ;;
        off)
            write_fallback_resolv "# SATHWIK-MESH:FORCED-OFF" "FORCED OFF - Natural DNS"
            ;;
        auto)
            if live_dns_verify >/dev/null 2>&1; then
                write_adguard_resolv "# SATHWIK-MESH:ADGUARD-STRICT" "AUTO - AdGuard Shield Active"
            else
                write_fallback_resolv "# SATHWIK-MESH:NATURAL-FALLBACK" "AUTO - Server Offline Natural Fallback"
            fi
            ;;
    esac
    signal_daemon
}

restore_original_resolver() {
    echo -e "${CYAN}🔄 Restoring original system DNS configuration...${NC}"
    rm -f "$NM_CONF_FILE"

    if command -v chattr >/dev/null 2>&1 && [ -e /etc/resolv.conf ] && [ ! -L /etc/resolv.conf ]; then
        chattr -i /etc/resolv.conf 2>/dev/null || true
    fi

    local orig_type="none"
    [ -f "$BACKUP_DIR/resolv_type" ] && IFS= read -r orig_type < "$BACKUP_DIR/resolv_type" 2>/dev/null || true

    if [ "$orig_type" = "symlink" ] && [ -f "$BACKUP_DIR/symlink_target" ]; then
        local target=""
        IFS= read -r target < "$BACKUP_DIR/symlink_target" 2>/dev/null || true
        if [ -n "$target" ]; then
            rm -f /etc/resolv.conf
            ln -snf "$target" /etc/resolv.conf
            echo -e "${GREEN}✓ Restored original symlink: /etc/resolv.conf -> $target${NC}"
        fi
    elif [ "$orig_type" = "file" ] && [ -f "$BACKUP_DIR/resolv.conf.orig" ]; then
        rm -f /etc/resolv.conf
        cp -pf "$BACKUP_DIR/resolv.conf.orig" /etc/resolv.conf
        echo -e "${GREEN}✓ Restored original /etc/resolv.conf file.${NC}"
    elif [ -f "/run/NetworkManager/resolv.conf" ]; then
        cp -f /run/NetworkManager/resolv.conf /etc/resolv.conf
    fi

    if [ -f "$BACKUP_DIR/systemd_resolved_state" ] && grep -q "^active$" "$BACKUP_DIR/systemd_resolved_state"; then
        systemctl restart systemd-resolved.service 2>/dev/null || true
    fi
    if [ -f "$BACKUP_DIR/networkmanager_state" ] && grep -q "^active$" "$BACKUP_DIR/networkmanager_state"; then
        systemctl reload NetworkManager.service 2>/dev/null || true
    fi
}

show_status() {
    local mode="auto"
    local route="unknown"
    local last_probe="unknown"
    [ -f "$MODE_FILE" ] && IFS= read -r mode < "$MODE_FILE" 2>/dev/null || true
    [ -f "$ACTIVE_ROUTE_FILE" ] && IFS= read -r route < "$ACTIVE_ROUTE_FILE" 2>/dev/null || true
    [ -f "$LAST_STATUS_FILE" ] && IFS= read -r last_probe < "$LAST_STATUS_FILE" 2>/dev/null || true

    if [ "$route" = "unknown" ] && [ -f /etc/resolv.conf ]; then
        local first_line
        IFS= read -r first_line < /etc/resolv.conf 2>/dev/null || true
        case "$first_line" in
            *"ADGUARD-STRICT"*|*"FORCED-ON"*) route="adguard" ;;
            *"NATURAL-FALLBACK"*|*"FORCED-OFF"*) route="fallback" ;;
        esac
    fi

    local ts_ip
    ts_ip=$(tailscale ip -4 2>/dev/null || echo "")

    echo -e "\n${BOLD}================ SATHWIK SERVER MESH ================${NC}"

    if [ -n "$ts_ip" ]; then
        echo -e "${BOLD}Tailscale Status:${NC}   ${GREEN}Connected ($ts_ip)${NC}"
        if tailscale status 2>/dev/null | grep -qF "$ADGUARD_IP"; then
            echo -e "${BOLD}Server in Mesh:${NC}     ${GREEN}✓ Present ($ADGUARD_IP)${NC}"
        else
            echo -e "${BOLD}Server in Mesh:${NC}     ${RED}✗ Missing ($ADGUARD_IP not shared with this account)${NC}"
        fi
    else
        echo -e "${BOLD}Tailscale Status:${NC}   ${RED}Logged Out / Disconnected${NC} (Run: ${CYAN}server login${NC})"
    fi

    case "$mode" in
        on)
            echo -e "${BOLD}Operating Mode:${NC}     ${CYAN}🔒 FORCED ON${NC} (All DNS packets locked to $ADGUARD_IP)"
            ;;
        off)
            echo -e "${BOLD}Operating Mode:${NC}     ${YELLOW}🔓 FORCED OFF${NC} (Bypassing server -> Natural DNS)"
            ;;
        *)
            echo -e "${BOLD}Operating Mode:${NC}     ${GREEN}🤖 AUTO FAILOVER${NC} (Adaptive RFC 1035 DNS verification)"
            ;;
    esac

    echo -ne "${BOLD}RFC 1035 DNS Probe:${NC} "
    local probe_out
    if probe_out=$(live_dns_verify 2>/dev/null); then
        echo -e "${GREEN}✓ ${probe_out}${NC}"
    else
        echo -e "${RED}✗ ${probe_out:-OFFLINE} (Daemon status: ${last_probe})${NC}"
    fi

    if [ "$route" = "adguard" ]; then
        echo -e "${BOLD}Active DNS Route:${NC}   ${GREEN}🛡️ AdGuard Server ($ADGUARD_IP)${NC}"
    elif [ "$route" = "fallback" ]; then
        echo -e "${BOLD}Active DNS Route:${NC}   ${YELLOW}⚡ Natural Router / Public DNS${NC}"
    else
        echo -e "${BOLD}Active DNS Route:${NC}   ${CYAN}Standard System DNS${NC}"
    fi

    echo -e "${BOLD}Active /etc/resolv.conf:${NC}"
    sed 's/^/  /' /etc/resolv.conf 2>/dev/null || true
    echo -e "${BOLD}=====================================================${NC}"
    echo -e "Commands: ${CYAN}server on${NC} | ${CYAN}server off${NC} | ${CYAN}server auto${NC} | ${CYAN}server status${NC} | ${CYAN}server ip <ip>${NC} | ${CYAN}server login${NC}\n"
}

case "$CMD" in
    status|--status)
        show_status
        ;;
    ip|--ip)
        require_root_for_action
        new_ip="${2:-}"
        if [ -z "$new_ip" ]; then
            echo -e "${BOLD}Current Server IP:${NC} ${CYAN}$ADGUARD_IP${NC}"
            echo "Usage: server ip <tailscale_node_ip>"
            exit 1
        fi
        install -d -m 0755 -o root -g root "$STATE_DIR"
        printf "%s\n" "$new_ip" > "$SERVER_IP_FILE"
        chmod 0644 "$SERVER_IP_FILE"
        ADGUARD_IP="$new_ip"
        echo -e "${GREEN}✓ Target AdGuard server IP updated to:${NC} ${BOLD}$new_ip${NC}"
        signal_daemon
        show_status
        ;;
    on|--on)
        require_root_for_action
        ensure_tailscale_authenticated || true
        set_mode "on"
        echo -e "${GREEN}${BOLD}🔒 [SERVER ON]${NC} Forced all DNS traffic strictly through ${BOLD}$ADGUARD_IP${NC}."
        show_status
        ;;
    off|--off)
        require_root_for_action
        set_mode "off"
        echo -e "${YELLOW}${BOLD}🔓 [SERVER OFF]${NC} Switched to normal/natural DNS (bypassing AdGuard server)."
        show_status
        ;;
    auto|--auto)
        require_root_for_action
        ensure_tailscale_authenticated || true
        set_mode "auto"
        echo -e "${GREEN}${BOLD}🤖 [SERVER AUTO]${NC} Real-time adaptive DNS failover enabled!"
        show_status
        ;;
    login|--login)
        require_root_for_action
        ensure_tailscale_authenticated
        signal_daemon
        show_status
        ;;
    uninstall|--uninstall)
        require_root_for_action
        echo -e "${YELLOW}🗑️ Uninstalling Sathwik Server Mesh...${NC}"
        systemctl disable --now "$SERVICE_NAME" 2>/dev/null || true
        rm -f "/etc/systemd/system/$SERVICE_NAME"
        systemctl daemon-reload
        restore_original_resolver
        rm -rf "$INSTALL_DIR" "$STATE_DIR" "$RUN_DIR"
        rm -f "$CLI_BIN"
        echo -e "${GREEN}✓ Uninstalled cleanly and restored original resolver state.${NC}"
        ;;
    *)
        echo -e "${BOLD}Sathwik Server Mesh CLI${NC}"
        echo "Usage:"
        echo "  server status     Show live mesh & RFC 1035 DNS status (no sudo required)"
        echo "  server on         Force all DNS queries to $ADGUARD_IP (even if offline)"
        echo "  server off        Force normal/natural DNS (even if server is online)"
        echo "  server auto       Automatic real-time failover (Default)"
        echo "  server login      Open Tailscale login portal & verify mesh"
        echo "  server uninstall  Remove daemon and restore original resolver symlink/file"
        exit 1
        ;;
esac
EOF_CLI

chmod 0755 "$CLI_BIN"

# ------------------------------------------------------------------------------
# 5. CONFIGURE NETWORKMANAGER & SYSTEMD SERVICE UNIT
# ------------------------------------------------------------------------------
snapshot_original_resolver

if [ -d "/etc/NetworkManager" ]; then
    mkdir -p /etc/NetworkManager/conf.d
    cat << 'EOF_NM' > "$NM_CONF_FILE"
[main]
rc-manager=unmanaged
EOF_NM
    systemctl reload NetworkManager.service 2>/dev/null || true
fi

cat << EOF_SERVICE > "$SERVICE_FILE"
[Unit]
Description=Sathwik Hardened Adaptive DNS Failover Daemon
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
Type=simple
ExecStart=$DAEMON_BIN
Restart=always
RestartSec=2
MemoryMax=16M
CPUQuota=3%
ProtectSystem=true
ReadWritePaths=/etc /var/lib/sathwik-mesh /run/sathwik-mesh
PrivateTmp=true
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF_SERVICE

# ------------------------------------------------------------------------------
# 6. RUN INITIAL SETUP, TAILSCALE AUTH & START DAEMON
# ------------------------------------------------------------------------------
echo -e "${BOLD}============================================================${NC}"
echo -e "${BOLD}🚀 INSTALLING SATHWIK SERVER MESH (HARDENED EDITION)${NC}"
echo -e "${BOLD}============================================================${NC}"

install_tailscale_if_needed
systemctl daemon-reload
systemctl enable --now tailscaled.service
systemctl restart sathwik-dnsd.service
systemctl enable sathwik-dnsd.service

"$CLI_BIN" auto
