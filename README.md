# MESHGUARD

**Linux DNS routing and automatic failover over Tailscale.**

## ⚡ Quick install

Copy and paste this single command into your terminal:

~~~bash
curl -fsSLO https://raw.githubusercontent.com/sathwik4444/MESHGUARD/main/block.sh && chmod +x block.sh && sudo ./block.sh
~~~

> **The installer is named `block.sh`.** This repository does not contain a `sathwik-mesh-installer.sh` file.

The installer runs with administrator privileges and changes system DNS configuration. Review the script and back up any custom resolver or NetworkManager configuration before running it.

[![ShellCheck](https://github.com/sathwik4444/MESHGUARD/actions/workflows/shellcheck.yml/badge.svg)](https://github.com/sathwik4444/MESHGUARD/actions/workflows/shellcheck.yml)
[![Linux](https://img.shields.io/badge/platform-Linux-1793D1?logo=linux&logoColor=white)](https://kernel.org/)
[![Tailscale](https://img.shields.io/badge/network-Tailscale-242424?logo=tailscale&logoColor=white)](https://tailscale.com/)

---

## Contents

- [Overview](#-overview)
- [How it works](#-how-it-works)
- [Requirements](#-requirements)
- [Installation](#-installation)
- [First-time setup](#-first-time-setup)
- [Command reference](#-command-reference)
- [Tailscale sharing and access](#-tailscale-sharing-and-access)
- [Installed files](#-installed-files)
- [Monitoring and troubleshooting](#-monitoring-and-troubleshooting)
- [Security considerations](#-security-considerations)
- [Current implementation caveats](#-current-implementation-caveats)
- [Uninstallation](#-uninstallation)
- [Development and CI](#-development-and-ci)
- [License](#-license)

## 🛡️ Overview

MESHGUARD is a Linux DNS-routing and failover utility built around a Tailscale-connected AdGuard DNS endpoint.

The current installer, `block.sh`, installs and configures:

- **DNS health monitoring** — periodically probes the configured AdGuard endpoint.
- **Automatic failover** — in `auto` mode, switches to the fallback resolver route when the endpoint is unavailable and attempts to return when it recovers.
- **Manual routing modes** — `on`, `off`, and `auto` modes.
- **Tailscale integration** — installs or uses Tailscale and configures the client with `--accept-dns=false`.
- **systemd integration** — installs a background daemon and enables it at boot.
- **CLI control** — provides the `server` command for status, mode changes, login, and uninstall.
- **Resolver snapshot** — records the original resolver type/target and DNS-manager active state for restoration.

MESHGUARD manages DNS routing on the Linux client. **AdGuard performs the DNS filtering**; MESHGUARD is not itself a DNS filtering engine.

## 🧭 How it works

~~~mermaid
flowchart TD
    A[Applications] --> B[Linux system resolver]
    B --> C[/etc/resolv.conf]
    C -->|AdGuard route| D[Tailscale network]
    D --> E[AdGuard DNS endpoint]
    F[sathwik-dnsd daemon] -->|DNS health probes| E
    F -->|updates resolver route| C
    F -->|when endpoint is unreachable| G[Fallback DNS route]
    G --> B
~~~

The daemon monitors the configured endpoint and updates the resolver route according to the selected mode. The AdGuard server must be reachable over Tailscale and must accept DNS requests from the client.

## 📋 Requirements

- A Linux distribution using **systemd**.
- Bash and `curl`.
- A user account with `sudo` privileges.
- Internet connectivity during installation.
- A reachable Tailscale-connected AdGuard DNS server.
- Python 3 is recommended for the daemon's persistent DNS response-validation worker. The installer also includes a Bash fallback path.
- NetworkManager is optional; its drop-in is written only when the relevant configuration directory exists.

The installer includes package-manager handling for common Arch-based, Debian-based, Fedora/RHEL-based, and openSUSE systems. Other distributions may use Tailscale's generic installation script. Verify compatibility with your distribution before deploying.

## 🚀 Installation

### 1. Download and install

Run the following command:

~~~bash
curl -fsSLO https://raw.githubusercontent.com/sathwik4444/MESHGUARD/main/block.sh && chmod +x block.sh && sudo ./block.sh
~~~

### 2. Complete Tailscale authentication

During first-time setup, Tailscale may print a login URL. Open it in a browser and authenticate the device using an account that has access to the AdGuard server.

The installer configures Tailscale with:

~~~bash
tailscale up --accept-dns=false
~~~

This prevents the client from accepting DNS configuration from the tailnet, allowing MESHGUARD to manage the local resolver route.

### 3. Verify the installation

After installation and authentication, check the client:

~~~bash
server status
~~~

Confirm that Tailscale is connected and that the configured AdGuard endpoint is visible and reachable.

## 🎛️ Command reference

The installer creates the `server` command.

| Command | Description |
|---|---|
| `server status` | Display Tailscale state, operating mode, DNS probe result, active route, and resolver contents. |
| `sudo server on` | Force DNS routing to the configured AdGuard endpoint. |
| `sudo server off` | Force the fallback / normal DNS route. |
| `sudo server auto` | Enable automatic failover and recovery. |
| `sudo server login` | Start or complete Tailscale authentication and check mesh visibility. |
| `sudo server uninstall` | Remove the MESHGUARD daemon and CLI and attempt to restore the saved resolver configuration. |

The status command is designed to work without `sudo`. State-changing commands require administrator privileges.

<details>
<summary><strong>Which mode should I use?</strong></summary>

- **Auto** — the normal recommended mode. It monitors the AdGuard endpoint and changes to the fallback route when the health check fails.
- **On** — forces the AdGuard route. The endpoint must be online and reachable; forcing this mode while it is offline can interrupt DNS resolution.
- **Off** — bypasses the AdGuard endpoint and uses the fallback resolver route.

The installer selects `auto` during its final setup step.

</details>

## 🌐 Tailscale sharing and access

The AdGuard machine must be reachable from the client over Tailscale. To give someone outside the server owner's tailnet access, share the **server device** with that person's Tailscale account.

### Share the server device

1. Open the Tailscale admin console and go to **Machines**.
2. Find the machine running AdGuard DNS.
3. Use the machine's **Share** option to invite the recipient by email or share link.
4. The recipient accepts the invitation and signs in to Tailscale.
5. On the client, verify that the shared machine is visible:

   ~~~bash
   tailscale status
   tailscale ping 100.102.245.39
   ~~~

6. Confirm the AdGuard service listens on the Tailscale interface (or an appropriate interface) and that the host firewall allows DNS traffic on port 53.

A shared machine is visible only to the invited recipient, not automatically to every user in the recipient's tailnet. Tailscale sharing also observes the sharing tailnet's access-control policy.

### Example access rule: DNS only

Tailscale recommends **Grants** for new policy configurations; ACLs remain supported. For a tailnet that still uses the ACL section, the following is an example rule to allow shared users to reach DNS on the MESHGUARD server:

~~~json
{
  "acls": [
    {
      "action": "accept",
      "src": ["autogroup:shared"],
      "dst": ["100.102.245.39:53"]
    }
  ]
}
~~~

Merge this entry into the existing policy. Do **not** replace the entire policy file with this fragment.

The rule is intentionally limited to port 53 on the server address. Keep the host firewall and AdGuard listener restricted to the intended clients and interfaces. Do not add broad access rules or expose SSH and administrative services just to make DNS work.

> **Address note:** The current installer uses `100.102.245.39` as its default AdGuard endpoint. Update the example if the server's Tailscale address changes.

For the latest details, see the [Tailscale device-sharing guide](https://tailscale.com/docs/features/sharing), [policy syntax reference](https://tailscale.com/docs/reference/syntax/policy-file), and [access-control overview](https://tailscale.com/docs/features/access-control).

## 🗂️ Installed files

The current installer creates or uses these paths:

| Path | Purpose |
|---|---|
| `/usr/local/lib/sathwik-mesh/sathwik-dnsd` | Background DNS monitoring and failover daemon. |
| `/usr/local/bin/server` | User-facing CLI controller. |
| `/etc/systemd/system/sathwik-dnsd.service` | systemd service definition. |
| `/etc/NetworkManager/conf.d/99-sathwik-dns.conf` | NetworkManager drop-in written when the relevant directory exists. |
| `/var/lib/sathwik-mesh/` | Persistent mode and resolver-backup state. |
| `/var/lib/sathwik-mesh/resolver-backup/` | Initial resolver and DNS-manager snapshot. |
| `/run/sathwik-mesh/` | Runtime state, probe status, and daemon control FIFO. |

The default AdGuard endpoint in the current installer is `100.102.245.39`.

## 🔎 Monitoring and troubleshooting

### Check the daemon

~~~bash
systemctl status sathwik-dnsd.service
journalctl -u sathwik-dnsd.service -f
~~~

### Check Tailscale connectivity

~~~bash
tailscale status
tailscale ip -4
tailscale ping 100.102.245.39
~~~

### Check the active resolver

~~~bash
server status
cat /etc/resolv.conf
~~~

### Common symptoms

| Symptom | What to check |
|---|---|
| Server is not visible in `server status` | Check the signed-in Tailscale account, accepted device invitation, and server availability. |
| DNS probe reports offline | Check Tailscale connectivity, AdGuard service health, port 53, and host firewall rules. |
| `server on` interrupts name resolution | The forced mode requires the AdGuard endpoint to be reachable. Switch to `sudo server auto` or `sudo server off`. |
| Route does not change | Inspect the daemon journal and verify that the service can update `/etc/resolv.conf` on your system. |
| Tailscale DNS settings conflict with MESHGUARD | Verify that the client is configured with `--accept-dns=false`. |

## 🔐 Security considerations

- DNS traffic is intended to travel over Tailscale, not through a publicly exposed DNS service.
- Share only the AdGuard server device with the intended users.
- Restrict access to the DNS service. Do not expose SSH or administrative interfaces as part of DNS sharing.
- `server on` is a forced route, not a health-aware mode. Use `server auto` when automatic recovery is desired.
- Review `block.sh` before executing it with `sudo`. It installs software, writes system configuration, and enables services.
- Back up custom DNS and NetworkManager configuration before installation.

## ⚠️ Current implementation caveats

The following items are important to validate before using the current installer on a machine with a customized DNS setup:

1. **systemd write access:** the generated service sets `ProtectSystem=full`, which makes most of the filesystem hierarchy read-only inside the service sandbox, including `/etc`. The daemon also updates `/etc/resolv.conf`. Verify that those writes succeed; a carefully scoped systemd write exception may be needed. See the [systemd.exec documentation](https://www.freedesktop.org/software/systemd/man/latest/systemd.exec.html#ProtectSystem=).
2. **NetworkManager drop-in:** the installer writes `99-sathwik-dns.conf`, and the current uninstall routine removes that path. Back up any pre-existing file with that exact name before installing.
3. **Forced-mode authentication handling:** the CLI currently tolerates a failed Tailscale authentication helper when entering `on` or `auto`. Verify Tailscale connectivity before relying on the forced route.
4. **Bash DNS fallback:** the Python worker performs the more complete DNS response checks. The Bash fallback is less comprehensive and should not be treated as equivalent packet validation.

These caveats are included to make deployment expectations clear. They are not claims that every Linux resolver configuration has been integration-tested.

## 🧹 Uninstallation

Run:

~~~bash
sudo server uninstall
~~~

The uninstall routine stops and disables the MESHGUARD service, removes the installed daemon and CLI, removes the MESHGUARD NetworkManager drop-in, and attempts to restore the original resolver configuration recorded during installation.

Tailscale itself is **not** uninstalled. Review the restored DNS configuration after uninstalling.

## 🧪 Development and CI

The repository keeps the installer in one file:

~~~text
MESHGUARD/
├── .github/
│   └── workflows/
│       └── shellcheck.yml
├── README.md
└── block.sh
~~~

GitHub Actions runs ShellCheck against `block.sh` on pushes and pull requests targeting `main`. The workflow can also be started manually from the **Actions** tab.

Run the same check locally:

~~~bash
shellcheck --shell=bash --severity=error block.sh
~~~

This workflow provides static analysis. It does not replace end-to-end testing of DNS routing, Tailscale connectivity, systemd sandbox permissions, or resolver restoration.

## 📄 License

There is currently no `LICENSE` file in this repository. Until a license is added, do not assume the code is licensed for redistribution or reuse.
