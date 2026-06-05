# AZHDAR (modular) v3.2.3

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
Updates are auto-discovered from a directory listing (`UPDATE_BASE_URL`, default: https://dl.digitsell.shop/share/gZ1XGygF) by scanning for `azhdar-X.Y.Z.zip` and picking the newest semver.

> The update package must include `scripts/install.sh` (like this ZIP).

## AZHDAR v3.2.3 tunnel repair

This build adds a conservative tunnel repair path for operational servers:

- `azhdar --repair-tunnel --yes` repairs the active profile without deleting it and without touching `sshd`.
- Main menu option `13) Repair tunnel / auto watchdog` opens manual repair, deep repair, and watchdog controls.
- Auto repair is handled by `azhdar-watchdog.timer`; it only runs for profiles where `TUNNEL_AUTO_REPAIR=1`.
- The watchdog waits for repeated failures and observes a cooldown before repairing, to avoid restart loops.
- Repair cleans stale local AZHDAR firewall/NAT/RST rules, rebuilds WG/Mimic configs from the saved profile, restarts services, and only touches the OUT server when SSH is actually reachable.


Mimic fallback mirror name: m0000hamad (`https://dl.digitsell.shop/share/Wf-XKNL9`).

## AZHDAR v3.2.3 service detection fixes

- Forces Mimic `xdp_mode = skb` in generated configs for better VPS/virtual NIC compatibility.
- Starts and restarts the correct per-interface service `mimic@<wan>` automatically.
- Detects local Mimic interface from route, existing `mimic@*.service`, or `/etc/mimic/*.conf`.
- Shows the real `mimic@<wan>` systemd status/journal when Mimic fails.
- Caps automatic safe repair passes so the UI does not appear stuck.

## AZHDAR v3.2.3 install/service fixes

- Controlled install probes no longer print a false `Fatal: step failed` when the same step later succeeds.
- Mimic install check now validates both the CLI and the kernel module (`modprobe mimic`) on IR and OUT.
- If Mimic CLI is present but DKMS/module is broken, AZHDAR attempts a DKMS/package repair instead of reporting success too early.
- Mimic service detection uses `mimic@<detected-interface>` and accepts any active `mimic@*.service`.
- Automatic safe repair is time-limited so the UI does not stay stuck indefinitely.
