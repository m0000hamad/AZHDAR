# Changelog

Release notes carried over from the README. Newest first.
Each release is also a git tag, so `git show v3.2.14` gives that exact build.

## AZHDAR v3.2.36: the watchdog can move the tunnel to a new port

v3.2.35 added repair on a new tunnel port, but only by hand. The watchdog
could still only retry the same port with a growing cooldown, so a port
filtered on the path stayed down until someone logged in.

- New option `14) Repair tunnel` → `7`: let the watchdog change the tunnel
  port by itself. It is off by default and asks how many failed repairs in a
  row come first (`TUNNEL_AUTO_PORT_HOP_AFTER`, default 2). Saved per profile
  as `TUNNEL_AUTO_PORT_HOP` / `TUNNEL_AUTO_PORT_HOP_AFTER`.
- When a watchdog repair fails and that makes N failures in a row, the same
  run goes straight on to a repair on a new port, with the same checks as the
  manual one: free for TCP and UDP on IR and OUT, OUT reachable over SSH, and
  a revert if OUT does not confirm the new `ListenPort`. Every later failed
  repair in the same outage moves the port again, up to 3 changes
  (`AZHDAR_PORT_HOP_MAX`).
- Ports already tried in the outage are skipped (`PORTS_TRIED` in the
  watchdog state), so it never bounces between two blocked ports. The list
  and the change count reset once the tunnel is healthy again. A change only
  counts when the port really changed; if OUT cannot be reached over SSH the
  tunnel stays where it is.
- In automatic mode the port picker never prompts, even when
  `azhdar --watchdog` is run from a terminal.
- The repair menu header and `Watchdog status` show the setting.

## AZHDAR v3.2.35: repair on a new tunnel port, no more ssh-keyscan bans

### Repair can move the tunnel to a new port

When the tunnel port is filtered on the path between the two servers, the
repair loop could only report it (`azhdar_port_filter_probe`) and the port had
to be changed separately under Advanced settings. That change only checked
other AZHDAR profiles, not whether the port was actually free on either server.

- Menu `14) Repair tunnel` has a new entry `6) Repair on a new tunnel port`,
  also available as `azhdar --repair-tunnel --new-port[=N]`. A failed manual
  repair now offers the same thing at the end, defaulting to yes when the
  port-filter probe saw one-way traffic.
- Before anything changes, the port is checked on IR and on OUT for TCP and
  UDP: listening sockets (`ss -lntup`, with the owning process in the
  message) and `nat PREROUTING` rules whose `--dport`/`--dports` match,
  including multiport lists and ranges. It also refuses the IR and OUT SSH
  ports, this profile's forward ports, ports other profiles reserve, and
  reverse SSH fallback ports on the same OUT host. Each server is listed once
  and every candidate is checked against that list, instead of one SSH call
  per candidate port. The suggested port is the first free one from the
  usual tunnel candidates, then outward from the current port.
- If OUT cannot be listed over SSH as root, nothing changes: the port has to
  move on both ends together.
- The new port is saved and both ends are rebuilt by the normal repair steps
  (stale rules are removed by profile tag, so the old port's rules go too).
  After the configs are written, OUT's WireGuard config must show the new
  `ListenPort`; if it does not (for example SSH dropped mid-write), the
  profile goes back to the old port so IR and OUT never disagree.
- Without a terminal, `--new-port` takes the suggested port as-is.

### ssh-keyscan no longer gets IR banned by newer OUT servers

`ssh_prepare_known_hosts_for` ran `ssh-keyscan` before every SSH call to OUT
(`ssh_exec_cmd_on`, `ssh_exec_stdin_on`, `ssh_autodetect_port`, the SSH
fallback setup, and again in the rc==255 retry). A scan opens one connection
per host key type, about five, and each closes without authenticating.
OpenSSH 9.8 and newer (Debian 13, Ubuntu 24.10+) enable `PerSourcePenalties`
by default and count every such connection as a `noauth` penalty, so after
about three AZHDAR calls OUT refused IR's address outright. Measured against
a stock OpenSSH 10.2 sshd with `PerSourcePenalties yes`: calls 1-3 of
`ssh_run "echo ok"` succeeded and calls 4-8 failed with "Connection reset".
OUT servers on OpenSSH 9.6 (Ubuntu 24.04) were not affected.

- Each endpoint is now scanned at most once per 10 minutes. A marker file
  next to its known_hosts file (`<file>.scanned`) records the last scan; a
  file rather than a variable because most callers run inside `$(...)`
  subshells. The same run now gives 8 of 8. `AZHDAR_KEYSCAN_TTL` (seconds,
  default 600, 0 = scan every time) overrides the window.
- The marker is written even when the scan fails: the endpoint was already
  cleared from known_hosts, so ssh's `accept-new` records the key on first
  connect, and rescanning a server that is penalising us only extends the
  block.
- A host key that changes inside the window is still picked up.
  `ssh_forget_known_host_for` deletes the marker, so the rc==255 retry
  forgets, rescans and reconnects. Tested by regenerating the test sshd's
  host key while the marker was fresh: the next `ssh_run` succeeded and
  known_hosts held the new key.
- The SSH fallback unit's `ExecStartPre` keyscan uses the same marker.
  With `Restart=always` and `RestartSec=3`, a failing tunnel re-ran the scan
  every 3 seconds, which can keep OUT's penalty running so the tunnel never
  gets back in. Existing units keep the old line until the fallback service
  is written again (SSH fallback menu or install wizard).

## AZHDAR v3.2.34: one shared SSH key for every exit server

Until now each profile could point at its own identity file, and everything
else meant a saved password pushed through sshpass. With many exit servers
that is one password per box.

- New main menu entry `17) SSH key`. It generates an ed25519 pair or imports
  an existing private key (pasted or by path; CRLF from Windows is stripped,
  PuTTY `.ppk` goes through `puttygen` when installed, a pasted public key is
  refused with an explanation). The key is stored as
  `/etc/azhdar/ssh/id_azhdar`, mode 600, without a passphrase: sshpass would
  otherwise answer the local passphrase prompt with the server password. An
  encrypted key is unlocked once and only AZHDAR's copy loses the passphrase.
- Every profile without its own `OUT_SSH_IDENTITY` now offers this key first
  (`-i ... -o IdentitiesOnly=yes`) and falls back to the saved password in
  the same connection. Before, a saved password disabled public-key auth
  entirely. `IdentitiesOnly` also stops agent/default keys from using up the
  server's `MaxAuthTries` before the password gets its turn.
- The menu can install the public key on the current profile's exit server or
  on all profiles at once, logging in with whatever works today and checking
  a key-only login afterwards. The add-profile and classic install wizards
  offer this once when the key is not trusted yet (Smart Wizard still asks
  only ports). Pressing ENTER at the password prompt now means "key only".
- The SSH fallback systemd unit and its key setup use the same key instead of
  generating a separate `/root/.ssh/id_ed25519` when a shared key exists.
- Non-interactive runs (watchdog, boot) without a password now always use
  `BatchMode`, so a server that rejects the key fails fast instead of waiting
  on a prompt nobody can answer.

## AZHDAR v3.2.33: rule deletion that actually matches, watchdog backoff, bounded backups

Found while chasing a profile whose OUT address had become filtered from the
IR side (ICMP passes, but any non-TLS TCP flow is cut after about 8.6 KB, so
the Mimic flow and SSH to OUT both stall). Nothing on the servers can repair
that, and it exposed three problems in how AZHDAR behaves around it.

- Every place that deletes rules by replaying `iptables -S` output (about 45
  sites in `firewall.sh`, `cleanup.sh`, `recovery.sh`, local and remote) ran
  `iptables $cmd`. `iptables -S` prints `--comment "AZHDAR:s6"` with quotes
  because of the colon, and word splitting kept those quotes, so `-D` never
  matched a profile-tagged rule. Stale DNAT/INPUT/raw rules from every old
  tunnel subnet and port were never removed; one server carried eight DNAT
  rules for the same public port. The v3.2.32 DNAT dedup was affected too.
  The line is now passed through `xargs`, which strips the quoting without
  shell expansion.
- The watchdog retried a failed repair every cooldown forever. Each repair
  restarts the shared `mimic@<wan>`, so a sibling profile on the same WAN was
  dropped about 40 times a day. The cooldown now doubles per failed repair in
  a row (600s, 1200s, 2400s, ...) up to 6 hours, and resets on the first
  healthy check or successful repair.
- Each repair left a WireGuard config backup (local and on OUT), an
  `/etc/iptables/rules.v4` backup and a repair snapshot, with no limit: 300+
  config backups on OUT and 152 snapshots (570 MB) on IR. Only the newest 10
  of each are kept now.

## AZHDAR v3.2.32: scope repair to one profile's WAN, self-heal duplicate DNAT

Two live incidents from repairing one profile bouncing/breaking another
profile, and a forwarded client port silently routing to a stale destination.

- `_tunnel_repair_stop_local_runtime()` and `stop_services_local()` used to
  stop every `mimic@*` systemd instance on the box. Mimic is one shared
  instance per WAN interface (`mimic@<wan>`), so repairing/stopping one
  profile bounced every sibling profile on a different WAN too (multi-NIC
  boxes). Both now stop only the WAN instance the active profile actually
  uses.
- PREROUTING is first-match-wins. A stale DNAT rule for a forward port (left
  over from a crashed apply, a destination-IP/port change, or historical
  state) sitting ahead of the current correct rule silently sent client
  traffic to the wrong/dead destination while the profile still reported the
  right one. `azhdar_firewall_safety_local()` — already run before every
  apply/repair/boot — now also calls `dedup_forward_dnat_local()`, which
  removes any DNAT rule for a forward port that doesn't match the profile's
  current destination, so duplicates can no longer accumulate or survive a
  crashed run.

## AZHDAR v3.2.31 live monitor

Adds `16) Live monitor` to the main menu and `azhdar --monitor` on the command
line: a refreshing terminal dashboard for the active profile. It only reads
state, and never writes configuration or firewall rules.

- Clients: established connections on the forwarding ports and how many distinct
  client addresses they come from, read from conntrack, with a sparkline of the
  recent trend. Distinct addresses is the honest proxy for "people online"; one
  client usually holds several connections.
- Uptime: system, WireGuard and Mimic, each with its restart count, so a service
  that has been bouncing is visible.
- Traffic: in, out, per-second rates with sparklines, the session total, and a
  lifetime total. WireGuard's counters reset whenever the interface is
  recreated, so the lifetime figure is carried forward in a small state file per
  profile.
- Framing: payload bytes, packet count, and an estimate of what Mimic's framing
  adds.

The framing figure is an estimate on purpose. Mimic rewrites packets in XDP,
which runs before netfilter and before any capture hook, so on this host the
traffic only ever appears in its UDP form: iptables counters and tcpdump both
miss the TCP frames entirely. Wire bytes cannot be measured locally, so the
panel multiplies the packet count by the 12 bytes a 20-byte TCP header adds over
an 8-byte UDP header, and says that it is an estimate.

Nothing in this stack compresses. WireGuard does not, and Mimic wraps UDP in TCP
framing, which adds bytes rather than removing them, so the monitor reports
added overhead and never claims a compression ratio.

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
