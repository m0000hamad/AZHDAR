# AZHDAR (modular) v3.2.0

AZHDAR is a modular manager for WireGuard over Mimic (eBPF) with isolated profiles.

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
Updates are auto-discovered from a directory listing (`UPDATE_BASE_URL`, default: https://37.32.26.129/azhdar) by scanning for `azhdar-X.Y.Z.zip` and picking the newest semver.

> The update package must include `scripts/install.sh` (like this ZIP).

## AZHDAR v3.2.0 tunnel repair

This build adds a conservative tunnel repair path for operational servers:

- `azhdar --repair-tunnel --yes` repairs the active profile without deleting it and without touching `sshd`.
- Main menu option `13) Repair tunnel / auto watchdog` opens manual repair, deep repair, and watchdog controls.
- Auto repair is handled by `azhdar-watchdog.timer`; it only runs for profiles where `TUNNEL_AUTO_REPAIR=1`.
- The watchdog waits for repeated failures and observes a cooldown before repairing, to avoid restart loops.
- Repair cleans stale local AZHDAR firewall/NAT/RST rules, rebuilds WG/Mimic configs from the saved profile, restarts services, and only touches the OUT server when SSH is actually reachable.
