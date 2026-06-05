# AZHDAR (modular) v3.2.7

## AZHDAR v3.2.7 Smart Wizard

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

## AZHDAR v3.2.7 profile port fixes

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
Updates are auto-discovered from a directory listing (`UPDATE_BASE_URL`, default: https://dl.digitsell.shop/share/gZ1XGygF) by scanning for `azhdar-X.Y.Z.zip` and picking the newest semver.

> The update package must include `scripts/install.sh` (like this ZIP).

## AZHDAR v3.2.7 tunnel repair

This build adds a conservative tunnel repair path for operational servers:

- `azhdar --repair-tunnel --yes` repairs the active profile without deleting it and without touching `sshd`.
- Main menu option `14) Repair tunnel / auto watchdog` opens manual repair, deep repair, and watchdog controls.
- Auto repair is handled by `azhdar-watchdog.timer`; it only runs for profiles where `TUNNEL_AUTO_REPAIR=1`.
- The watchdog waits for repeated failures and observes a cooldown before repairing, to avoid restart loops.
- Repair cleans stale local AZHDAR firewall/NAT/RST rules, rebuilds WG/Mimic configs from the saved profile, restarts services, and only touches the OUT server when SSH is actually reachable.


Mimic fallback mirror name: m0000hamad (`https://dl.digitsell.shop/share/Wf-XKNL9`).

## AZHDAR v3.2.7 service detection fixes

- Forces Mimic `xdp_mode = skb` in generated configs for better VPS/virtual NIC compatibility.
- Starts and restarts the correct per-interface service `mimic@<wan>` automatically.
- Detects local Mimic interface from route, existing `mimic@*.service`, or `/etc/mimic/*.conf`.
- Shows the real `mimic@<wan>` systemd status/journal when Mimic fails.
- Caps automatic safe repair passes so the UI does not appear stuck.
