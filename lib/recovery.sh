# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Operational recovery / anti-poison --------------------
# Purpose: recover the IR host from stale AZHDAR runtime state without rebuilding.
# It avoids touching ssh/sshd and keeps profile files by default.

_recovery_ts(){ date +%F-%H%M%S 2>/dev/null || date +%s; }

_recovery_snapshot_local(){
  local dir="/root/azhdar-recovery-$(_recovery_ts)"
  mkdir -p "$dir" 2>/dev/null || return 0
  echo "$dir" >"${BASE_DIR:-/etc/azhdar}/last_recovery_snapshot" 2>/dev/null || true
  iptables-save >"$dir/iptables-save.v4" 2>/dev/null || true
  ip6tables-save >"$dir/ip6tables-save.v6" 2>/dev/null || true
  nft list ruleset >"$dir/nft-ruleset.txt" 2>/dev/null || true
  ss -lntup >"$dir/ss-lntup.txt" 2>/dev/null || true
  ip addr show >"$dir/ip-addr.txt" 2>/dev/null || true
  ip route show table all >"$dir/ip-route-all.txt" 2>/dev/null || true
  systemctl list-units --type=service --all >"$dir/systemd-services.txt" 2>/dev/null || true
  systemctl list-unit-files >"$dir/systemd-unit-files.txt" 2>/dev/null || true
  cp -a "${BASE_DIR:-/etc/azhdar}" "$dir/etc-azhdar" 2>/dev/null || true
  cp -a /etc/wireguard "$dir/etc-wireguard" 2>/dev/null || true
  cp -a /etc/mimic "$dir/etc-mimic" 2>/dev/null || true
  cp -a /etc/iptables "$dir/etc-iptables" 2>/dev/null || true
  ok "Recovery snapshot saved: ${dir}"
}

_recovery_delete_rule_lines(){
  local table="$1"; shift
  local line cmd
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    cmd="${line/-A /-D }"
    if [[ "$table" == "filter" ]]; then
      iptables $cmd >/dev/null 2>&1 || true
    else
      iptables -t "$table" $cmd >/dev/null 2>&1 || true
    fi
  done
}

_recovery_delete_ip6_rule_lines(){
  local table="$1"; shift
  local line cmd
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    cmd="${line/-A /-D }"
    if [[ "$table" == "filter" ]]; then
      ip6tables $cmd >/dev/null 2>&1 || true
    else
      ip6tables -t "$table" $cmd >/dev/null 2>&1 || true
    fi
  done
}

_recovery_stop_units_matching_local(){
  local pattern="$1" unit
  command -v systemctl >/dev/null 2>&1 || return 0
  while read -r unit; do
    [[ -n "$unit" ]] || continue
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl disable "$unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  done < <(systemctl list-unit-files "$pattern" --no-legend 2>/dev/null | awk '{print $1}' || true)
  while read -r unit; do
    [[ -n "$unit" ]] || continue
    systemctl stop "$unit" >/dev/null 2>&1 || true
    systemctl reset-failed "$unit" >/dev/null 2>&1 || true
  done < <(systemctl list-units "$pattern" --all --no-legend 2>/dev/null | awk '{print $1}' || true)
}

_recovery_profile_ports_csv(){
  local p v
  while read -r p; do
    [[ -n "$p" ]] || continue
    v="$(profile_read_var "$p" WG_PORT 2>/dev/null || true)"; [[ -n "$v" ]] && echo "$v"
    v="$(profile_read_var "$p" IR_SSH_PORT 2>/dev/null || true)"; [[ -n "$v" ]] && echo "$v"
    v="$(profile_read_var "$p" VLESS_DST_PORT 2>/dev/null || true)"; [[ -n "$v" ]] && echo "$v"
    v="$(profile_read_var "$p" FORWARD_TCP_PORTS 2>/dev/null || true)"; ports_split_csv "$v" 2>/dev/null || true
    v="$(profile_read_var "$p" FORWARD_UDP_PORTS 2>/dev/null || true)"; ports_split_csv "$v" 2>/dev/null || true
    v="$(profile_read_var "$p" SSH_FWD_TCP_MAP 2>/dev/null || true)"
    printf '%s' "$v" | tr ',' '\n' | sed -n 's/^\([0-9][0-9]*\)=.*/\1/p' || true
  done < <(profiles_list 2>/dev/null || true)
}

_recovery_remove_azhdar_rules_local(){
  local tag="${TAG:-AZHDAR}"
  # Tagged rules (safe and precise)
  iptables -S INPUT 2>/dev/null | grep -F "$tag" | _recovery_delete_rule_lines filter || true
  iptables -S FORWARD 2>/dev/null | grep -F "$tag" | _recovery_delete_rule_lines filter || true
  iptables -t nat -S PREROUTING 2>/dev/null | grep -F "$tag" | _recovery_delete_rule_lines nat || true
  iptables -t nat -S POSTROUTING 2>/dev/null | grep -F "$tag" | _recovery_delete_rule_lines nat || true
  iptables -t raw -S OUTPUT 2>/dev/null | grep -F "$tag" | _recovery_delete_rule_lines raw || true

  if command -v ip6tables >/dev/null 2>&1; then
    ip6tables -S INPUT 2>/dev/null | grep -F "$tag" | _recovery_delete_ip6_rule_lines filter || true
    ip6tables -S FORWARD 2>/dev/null | grep -F "$tag" | _recovery_delete_ip6_rule_lines filter || true
    ip6tables -t raw -S OUTPUT 2>/dev/null | grep -F "$tag" | _recovery_delete_ip6_rule_lines raw || true
  fi

  # Untagged legacy fallback rules created by older/broken builds: remove only
  # rules that match ports/interfaces from saved AZHDAR profiles.
  local port
  while read -r port; do
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || continue
    (( port >= 1 && port <= 65535 )) || continue
    iptables -t nat -S PREROUTING 2>/dev/null | grep -F -- "--dport ${port}" | grep -E -- ' -j (DNAT|REDIRECT)( |$)' | _recovery_delete_rule_lines nat || true
    iptables -t raw -S OUTPUT 2>/dev/null | grep -F -- "--sport ${port}" | grep -F -- '--tcp-flags RST RST' | grep -F -- '-j DROP' | _recovery_delete_rule_lines raw || true
  done < <(_recovery_profile_ports_csv | sort -n | uniq)

  # Remove MASQUERADE/FORWARD rules for generated WG interfaces.
  local iface
  while read -r iface; do
    [[ -n "$iface" ]] || continue
    iptables -t nat -S POSTROUTING 2>/dev/null | grep -F -- "-o ${iface}" | grep -F -- '-j MASQUERADE' | _recovery_delete_rule_lines nat || true
    iptables -S FORWARD 2>/dev/null | grep -E -- "(-i ${iface}|-o ${iface})" | grep -F -- '-j ACCEPT' | _recovery_delete_rule_lines filter || true
  done < <(find /etc/wireguard -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null | while read -r f; do
    if grep -Eq 'Generated by .*AZHDAR|Generated by m0000hamad|WireGuard .*Mimic' "$f" 2>/dev/null; then basename "$f" .conf; fi
  done
  while read -r p; do
    p="$(safe_name "$p")"; [[ -n "$p" ]] || continue
    iface="$(profile_read_var "$p" WG_IF 2>/dev/null || true)"; [[ -n "$iface" ]] || iface="$p"
    echo "$iface"
  done < <(profiles_list 2>/dev/null || true))
}

_recovery_clean_saved_iptables_local(){
  local f bak
  mkdir -p /etc/iptables >/dev/null 2>&1 || true
  for f in /etc/iptables/rules.v4 /etc/iptables/rules.v6; do
    [[ -f "$f" ]] || continue
    bak="${f}.azhdar-bak.$(_recovery_ts)"
    cp -a "$f" "$bak" 2>/dev/null || true
    # Drop tagged AZHDAR lines from saved persistent rules. Untagged runtime
    # poison is removed before save below, so saving current tables cleans it too.
    grep -v -F "${TAG:-AZHDAR}" "$bak" >"$f" 2>/dev/null || cp -a "$bak" "$f" 2>/dev/null || true
  done

  # Save the cleaned current runtime if a persistence tool exists. This prevents
  # stale rules from returning on the next reboot while preserving non-AZHDAR rules.
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
  elif command -v iptables-save >/dev/null 2>&1 && [[ -d /etc/iptables ]]; then
    iptables-save >/etc/iptables/rules.v4 2>/dev/null || true
    command -v ip6tables-save >/dev/null 2>&1 && ip6tables-save >/etc/iptables/rules.v6 2>/dev/null || true
  fi
}

_recovery_stop_generated_services_local(){
  local p iface svc wan f
  command -v systemctl >/dev/null 2>&1 || return 0

  _recovery_stop_units_matching_local 'azhdar-ssh-fallback@*.service'

  while read -r p; do
    p="$(safe_name "$p")"; [[ -n "$p" ]] || continue
    iface="$(profile_read_var "$p" WG_IF 2>/dev/null || true)"; [[ -n "$iface" ]] || iface="$p"
    systemctl stop "wg-quick@${iface}" >/dev/null 2>&1 || true
    systemctl disable "wg-quick@${iface}" >/dev/null 2>&1 || true
    wg-quick down "$iface" >/dev/null 2>&1 || true
    ip link del "$iface" >/dev/null 2>&1 || true
  done < <(profiles_list 2>/dev/null || true)

  find /etc/wireguard -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null | while read -r f; do
    if grep -Eq 'Generated by .*AZHDAR|Generated by m0000hamad|WireGuard .*Mimic' "$f" 2>/dev/null; then
      iface="$(basename "$f" .conf)"
      systemctl stop "wg-quick@${iface}" >/dev/null 2>&1 || true
      systemctl disable "wg-quick@${iface}" >/dev/null 2>&1 || true
      wg-quick down "$iface" >/dev/null 2>&1 || true
      ip link del "$iface" >/dev/null 2>&1 || true
    fi
  done

  find /etc/mimic -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null | while read -r f; do
    if grep -Eq 'Generated by .*AZHDAR|Generated by m0000hamad' "$f" 2>/dev/null; then
      wan="$(basename "$f" .conf)"
      systemctl stop "mimic@${wan}" >/dev/null 2>&1 || true
      systemctl disable "mimic@${wan}" >/dev/null 2>&1 || true
    fi
  done

  systemctl reset-failed >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
}

_recovery_remove_generated_configs_local(){
  local f iface
  find /etc/wireguard -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null | while read -r f; do
    if grep -Eq 'Generated by .*AZHDAR|Generated by m0000hamad|WireGuard .*Mimic' "$f" 2>/dev/null; then
      iface="$(basename "$f" .conf)"
      rm -f "/etc/wireguard/${iface}.conf" "/etc/wireguard/${iface}.key" "/etc/wireguard/${iface}.psk" >/dev/null 2>&1 || true
    fi
  done
  find /etc/mimic -maxdepth 1 -type f -name '*.conf' -print 2>/dev/null | while read -r f; do
    if grep -Eq 'Generated by .*AZHDAR|Generated by m0000hamad' "$f" 2>/dev/null; then
      rm -f "$f" >/dev/null 2>&1 || true
    fi
  done
}

azhdar_recover_ir_runtime(){
  need_root
  ensure_dirs
  load_global || true

  local assume_yes="0"
  [[ "${1:-}" == "--yes" || "${AZHDAR_RECOVERY_YES:-0}" == "1" ]] && assume_yes="1"

  banner
  warn "IR runtime recovery: removes stale AZHDAR services, WG/Mimic generated configs, and firewall/NAT/RST rules on THIS server only."
  warn "It does NOT restart or modify ssh/sshd, and it does NOT touch the OUT server."
  echo
  if [[ "$assume_yes" != "1" ]]; then
    read -rp "Type RECOVER to continue: " ans || true
    [[ "${ans:-}" == "RECOVER" ]] || { warn "Canceled."; return 1; }
  fi

  _recovery_snapshot_local || true

  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop azhdar-watchdog.timer azhdar-watchdog.service >/dev/null 2>&1 || true
  fi

  step "Stop generated local services"
  _recovery_stop_generated_services_local || true
  ok "Generated local services stopped/disabled."

  step "Remove AZHDAR firewall/NAT/RST runtime rules"
  _recovery_remove_azhdar_rules_local || true
  ok "Runtime firewall rules cleaned."

  step "Clean saved iptables persistence state"
  _recovery_clean_saved_iptables_local || true
  ok "Saved iptables persistence cleaned (best-effort)."

  step "Remove generated WG/Mimic configs"
  _recovery_remove_generated_configs_local || true
  ok "Generated local configs removed."

  rm -f /etc/sysctl.d/99-wg-mimic.conf >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true

  # Keep manager/profile state, but clear selected boot profile to avoid an
  # automatic re-apply loop until the user explicitly runs the wizard again.
  CURRENT_PROFILE=""
  save_global >/dev/null 2>&1 || true

  ok "IR runtime recovery finished. Re-open azhdar, select/add profile, then run Install/Update/Repair."
  return 0
}
