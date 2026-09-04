# AZHDAR (modular) v3.2.8

## AZHDAR v3.2.30 fewer service restarts

Install and repair restarted WireGuard and Mimic twice on both servers.

`start_services_*` and `restart_services_*` were called back to back. For Mimic
the two are literally the same code path: `enable_mimic_local` is just
`mimic_restart_local_checked`, which is what the restart function calls too. For
WireGuard the only thing the start call added was `systemctl enable`, so the
unit was started and then immediately restarted.

The restart functions now enable the unit themselves, and the redundant start
calls are gone from the install wizard and from tunnel repair. Boot enablement
is unchanged; both wizard modes and every repair pass now cycle each service
once instead of twice, and the remote side does it in half the SSH round trips.

## AZHDAR v3.2.29 forwarding and filtered-port fixes

- Fixes stale DNAT rules surviving a destination change. `setup_forward_ir` only
  checked for a rule matching the *current* destination, so changing the tunnel
  IP or the node port left the previous rule in place. Because `PREROUTING` is
  first-match-wins, an obsolete rule could keep winning while the profile
  reported the new destination, sending client traffic to a dead port. Each
  apply now clears existing DNAT rules for the port first, for TCP and UDP.
- Adds `azhdar_port_filter_probe`, reported when a repair pass ends with the
  tunnel still down. When WireGuard keeps transmitting, never receives a byte,
  never completes a handshake, and the OUT host still answers on its SSH port,
  the tunnel port is blocked on the path rather than misconfigured. Repair
  cannot fix that, so the tool now says so and suggests unused candidate ports
  instead of looping.

## AZHDAR v3.2.8 Smart Wizard

Changes in this build:

- Fixes Smart/normal wizard port suggestions so `WG_PORT` is reserved first and never suggested again as the user-facing TCP forward port.
- Prints an explicit hint such as: tunnel uses `WG_PORT=443`, suggested public TCP forward port is `8443` when free.
- Makes Mimic package downloads retry with a relaxed curl path before falling back or failing, fixing false Smart Wizard download errors when manual curl works.

- Added **Smart Wizard / one-step install** in the main menu.
- Smart Wizard uses the selected profile's existing OUT SSH settings and only asks:
  - Public TCP port users connect to on IR
  - Target/service port on OUT
- Reverse-forward is now enabled by default (`Y`) in the normal wizard.
- If a selected public TCP forward port conflicts with another profile, the IR SSH protected port, the tunnel port, or a local listener, Smart Wizard automatically replaces it with a usable port and prints the replacement in the final summary.
- The final install screen now prints the important connection/forwarding details directly below the status indicators.

Smart Wizard keeps the classic wizard path intact. Use the classic wizard when you want to manually tune MTU, IP families, tunnel IP allocation, PSK behavior, or SSH transport.

AZHDAR is a modular manager for WireGuard over Mimic (eBPF) with isolated profiles.

## AZHDAR v3.2.8 profile port fixes

- Fixes adding a second profile when the first profile uses `WG_PORT=443` and the new profile uses a different tunnel port such as `8443`.
- Preserves an explicitly empty `FORWARD_TCP_PORTS` value instead of silently restoring it to `443` on profile load.
- Makes tunnel-port suggestions check both TCP and UDP reservations, and improves conflict messages so forwarding conflicts are not mislabeled as WG port conflicts.

## Project layout
- `azhdar` : main executable (interactive menu + CLI entry)
- `lib/` : modules (each feature in a separate file)
- `scripts/install.sh` : system install (creates `azhdar` command + systemd unit)
- `scripts/uninstall.sh` : uninstall (optional: `--purge` removes `/etc/azhdar` state)
- `systemd/azhdar.service` : best-effort apply on boot

## Install
```bash
sudo bash scripts/install.sh
sudo azhdar
```

## systemd
```bash
systemctl status azhdar.service
systemctl restart azhdar.service
```

## In-menu update
The startup screen includes `Update AZHDAR`.
Updates are auto-discovered from the repository's `dist/` listing (`UPDATE_BASE_URL`, default: https://github.com/m0000hamad/AZHDAR) by scanning for `azhdar-X.Y.Z.zip` and picking the newest semver.

> The update package must include `scripts/install.sh` (like this ZIP).

## AZHDAR v3.2.8 tunnel repair

This build adds a conservative tunnel repair path for operational servers:

- `azhdar --repair-tunnel --yes` repairs the active profile without deleting it and without touching `sshd`.
- Main menu option `14) Repair tunnel / auto watchdog` opens manual repair, deep repair, and watchdog controls.
- Auto repair is handled by `azhdar-watchdog.timer`; it only runs for profiles where `TUNNEL_AUTO_REPAIR=1`.
- The watchdog waits for repeated failures and observes a cooldown before repairing, to avoid restart loops.
- Repair cleans stale local AZHDAR firewall/NAT/RST rules, rebuilds WG/Mimic configs from the saved profile, restarts services, and only touches the OUT server when SSH is actually reachable.


Mimic fallback mirror name: m0000hamad (`https://api.github.com/repos/m0000hamad/AZHDAR/contents/assets`).

## AZHDAR v3.2.8 service detection fixes

- Forces Mimic `xdp_mode = skb` in generated configs for better VPS/virtual NIC compatibility.
- Starts and restarts the correct per-interface service `mimic@<wan>` automatically.
- Detects local Mimic interface from route, existing `mimic@*.service`, or `/etc/mimic/*.conf`.
- Shows the real `mimic@<wan>` systemd status/journal when Mimic fails.
- Caps automatic safe repair passes so the UI does not appear stuck.

## v3.2.28 hotfix
- Pin Mimic package selection to stable 0.7.0 mirror by default.
- Avoid unattended/full-upgrade side effects during Mimic install.
- Suppress maintainer service restarts during apt/dpkg repair.
- Reinstall broken/half-configured Mimic packages cleanly before DKMS build.

## v3.2.19 hotfix
- Adds aggressive Mimic DKMS/BTF repair for service failures with `mimic_change_csum_offset` / `failed to load BPF program`.
- Installs `pahole/dwarves/bpftool`, rebuilds/reinstalls the Mimic DKMS module for the running kernel, reloads it, clears stale runtime locks, and retries the service.
