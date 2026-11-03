# Changelog

All notable changes to **MeshGuard** are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [1.2.1] - 2026-11-03

### 🐛 Fixed
- **Reboot Runtime Directory Persistence (`/run` tmpfs)**:
  - *Root Cause:* In Linux, `/run` is mounted as a volatile `tmpfs` RAM disk cleared on every system restart. When the system rebooted, `/run/sathwik-mesh` vanished, causing `server on`, `server off`, and status probes to fail with `/run/sathwik-mesh/active_route: No such file or directory`.
  - *Fix:* Integrated `RuntimeDirectory=sathwik-mesh` and `RuntimeDirectoryMode=0755` into the systemd service definition. systemd (PID 1) now guarantees the runtime directory is provisioned before service execution. Additionally added defensive directory creation (`mkdir -p "$RUN_DIR"`) across all CLI and daemon file write entry points.
- **Fatal Bash Floating-Point Arithmetic Crash**:
  - *Root Cause:* Bash's `$(( ... ))` arithmetic expansion engine exclusively accepts integer operands. When stage timeouts passed decimal values (such as `2.5`s or `1.5`s), Bash aborted with `arithmetic syntax error: invalid arithmetic operator (error token is ".5")`, placing the daemon into an unrecoverable restart loop.
  - *Fix:* Added string-prefix decimal truncation (`${timeout_sec%.*}`) to sanitize timeout parameters before evaluation, preventing arithmetic errors while preserving sub-second socket timeouts.
- **Route Flapping & Desktop Notification Storms**:
  - *Root Cause:* Battery-operated server nodes (e.g. mobile/Android devices in Termux) intermittently enter 802.11 power-saving DTIM sleep, introducing transient 30-50% UDP packet loss and 100-330ms latency spikes. The previous failover threshold triggered on a single failed cycle, causing rapid bouncing between AdGuard Shield and Fallback routes.
  - *Fix:* 
    - Debounced failover: Requires **2 consecutive failed verification cycles** (~10–12 seconds of sustained outage) before demoting to fallback DNS.
    - Debounced recovery: Requires **3 consecutive healthy cycles** (~12–15 seconds of sustained stability) before restoring AdGuard DNS.
    - Added a **45-second notification cooldown** (`LAST_NOTIF_TIME`) to suppress repetitive desktop popup alerts.

---

## [1.2.0] - 2026-11-02

### ⚡ Added
- **Instant Synchronous CLI Route Switching**:
  - `server on`, `server off`, and `server auto` now execute atomic resolver file writes directly when invoked with `sudo`, rather than asynchronously awaiting the background daemon's FIFO wake cycle. Eliminates route-switch race conditions.
- **Dynamic & Multi-Device Target IP Support**:
  - Added persistent configuration storage in `/var/lib/sathwik-mesh/server_ip`.
  - Added `server ip <new_ip>` CLI subcommand to update target server endpoints dynamically without modifying script sources.
  - Enabled installer command-line arguments: `sudo ./block.sh <target_tailscale_ip>`.
- **Search Domain Preservation**:
  - Fallback resolver generation now extracts and preserves `search` and `domain` entries from NetworkManager and systemd-resolved to maintain local LAN hostname resolution.

---

## [1.1.0] - 2026-11-02

### 🔒 Security & Hardening
- **Systemd Sandbox /etc Mount Restrictions**:
  - *Root Cause:* `ProtectSystem=full` mounts `/etc` as read-only (`EROFS`). This prevented the background daemon from updating `/etc/resolv.conf`.
  - *Fix:* Replaced with `ProtectSystem=true` and explicit write grants via `ReadWritePaths=/etc /var/lib/sathwik-mesh /run/sathwik-mesh`.
- **POSIX-Compliant Atomic Inode Replacement**:
  - *Root Cause:* Creating temporary files in `/run` (`tmpfs`) and moving them to `/etc` (root filesystem) violates `EXDEV` boundaries, forcing `mv` to fall back to non-atomic copy-and-unlink.
  - *Fix:* Relocated temporary staging files to `/etc/.resolv.tmp.XXXXXXXXXX`, ensuring `mv` triggers an atomic single-inode swap via the Linux `rename(2)` syscall.
- **Legacy Service & Firewall Cleanup**:
  - Automated detection and removal of obsolete units (`dns-adblock-watchdog.service`, `dns-failover-guard.service`), residual binaries, and flushed orphaned `DNS_BLOCK` iptables chains.
- **Bash Fallback `printf` Escape Syntax**:
  - Corrected raw byte query construction from `"\\x%02x"` to `"\\\\x%02x"`, silencing hex escape syntax warnings on newer Bash releases.

---

## [1.0.0] - 2026-11-02

### 🚀 Initial Core Release
- **Zero-Fork DNS Probing**: Persistent Python 3 RFC 1035 wire-format validator coprocess worker.
- **Two-Stage Adaptive Verification**: Initial generous timeout followed by 3 rapid burst probes on packet loss.
- **Global `server` CLI**:
  - `server status`: Unprivileged inspection of mesh presence, socket latency, and active resolver.
  - `server on`: Strict server routing.
  - `server off`: Router DHCP and public DNS bypass.
  - `server auto`: Real-time adaptive failover.
  - `server login`: Interactive Tailscale browser authentication.
  - `server uninstall`: Full restoration of initial resolver symlinks/files and configuration cleanup.
- **Cross-Distribution Installer**: Dynamic package manager integration for Arch, Debian/Ubuntu, Fedora/RHEL, and openSUSE.
