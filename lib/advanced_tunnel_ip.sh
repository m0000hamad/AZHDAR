# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Advanced: tunnel IP management --------------------
tunnel_mode_label(){
  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then
    echo "dual (v4+v6)"
  elif [[ "${ENABLE_TUN_IPV4:-1}" == "1" ]]; then
    echo "v4 only"
  elif [[ "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then
    echo "v6 only"
  else
    echo "none"
  fi
}

valid_cidr4(){
  local cidr="$1"
  if have_cmd python3; then
    python3 - "$cidr" <<'PY' >/dev/null 2>&1
import ipaddress, sys
cidr=sys.argv[1]
try:
  n = ipaddress.ip_network(cidr, strict=False)
  sys.exit(0 if n.version == 4 else 1)
except Exception:
  sys.exit(1)
PY
    return $?
  fi
  [[ "$cidr" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[1-2][0-9]|3[0-2])$ ]] || return 1
  local ip="${cidr%/*}"
  local a b c d
  IFS='.' read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

valid_cidr6(){
  local cidr="$1"
  have_cmd python3 || return 1
  python3 - "$cidr" <<'PY' >/dev/null 2>&1
import ipaddress, sys
cidr=sys.argv[1]
try:
  n = ipaddress.ip_network(cidr, strict=False)
  sys.exit(0 if n.version == 6 else 1)
except Exception:
  sys.exit(1)
PY
}

ip_in_cidr(){
  # ip_in_cidr <ip> <cidr>
  local ip="$1" cidr="$2"
  have_cmd python3 || return 1
  python3 - "$ip" "$cidr" <<'PY' >/dev/null 2>&1
import ipaddress, sys
ip_s=sys.argv[1]
cidr=sys.argv[2]
try:
  ip = ipaddress.ip_address(ip_s)
  net = ipaddress.ip_network(cidr, strict=False)
  sys.exit(0 if ip in net else 1)
except Exception:
  sys.exit(1)
PY
}

prompt_tunnel_mode(){
  echo -e "${DIM}Tunnel IP mode:${RST} $(tunnel_mode_label)"
  echo " 1) IPv4 only"
  echo " 2) IPv6 only"
  echo " 3) IPv4 + IPv6 (dual stack)"
  local def="1"
  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && "${ENABLE_TUN_IPV6:-0}" != "1" ]]; then def="1"; fi
  if [[ "${ENABLE_TUN_IPV4:-1}" != "1" && "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then def="2"; fi
  local c=""
  while true; do
    read -rp "Select [${def}]: " c || true
    c="${c:-$def}"
    case "$c" in
      1) ENABLE_TUN_IPV4="1"; ENABLE_TUN_IPV6="0"; break ;;
      2) ENABLE_TUN_IPV4="0"; ENABLE_TUN_IPV6="1"; break ;;
      3) ENABLE_TUN_IPV4="1"; ENABLE_TUN_IPV6="1"; break ;;
      *) warn "Invalid choice." ;;
    esac
  done

  if [[ "${ENABLE_TUN_IPV4}" != "1" && -n "${FORWARD_TCP_PORTS:-}${FORWARD_UDP_PORTS:-}" ]]; then
    warn "Forwarding requires IPv4 tunnel addresses. Disabling forwarding ports in this profile."
    FORWARD_TCP_PORTS=""
    FORWARD_UDP_PORTS=""
  fi
}

prepare_ssh_mgmt_for_tunnel_change(){
  # If management SSH currently works through the existing WG tunnel, changing
  # OUT_WG_IP would otherwise make ssh_target_candidates use only the NEW WG IP
  # before the remote host has received the new config. Preserve the old WG IP
  # in-memory as last-good management target for this apply cycle.
  if [[ -n "${OUT_WG_IP:-}" && "${OUT_WG_IP}" != "peer" ]]; then
    SSH_MGMT_LAST_TRANSPORT="wg"
    SSH_MGMT_LAST_HOST="${OUT_WG_IP}"
    SSH_MGMT_LAST_PORT="${OUT_SSH_PORT:-22}"
  fi
}

apply_wg_configs_best_effort(){
  step "Apply WireGuard config changes (safe/full apply)"
  if [[ "${ENABLE_TUN_IPV4:-1}" != "1" && "${ENABLE_TUN_IPV6:-0}" != "1" ]]; then
    err "No tunnel IP family enabled."
    return 1
  fi

  local remote_ok=0 remote_written=0 local_written=0 apply_failed=0
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    remote_ok=0
  elif ssh_check_quiet >/dev/null 2>&1; then
    remote_ok=1
  else
    warn "SSH unavailable; cannot rewrite remote WG config now. Keeping remote as-is."
  fi

  if ! ensure_privkey_local; then
    err "Local WireGuard key preparation failed; leaving current runtime untouched."
    return 1
  fi

  if (( remote_ok == 1 )); then
    remote_prepare_deps >/dev/null 2>&1 || true
  fi

  IR_PUBKEY="$(get_pubkey_local 2>/dev/null | tr -d '\r' | tail -n1 || true)"
  if [[ -z "${IR_PUBKEY:-}" ]]; then
    err "Local WG public key not found; leaving current runtime untouched."
    return 1
  fi

  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    :
  elif (( remote_ok == 1 )); then
    OUT_PUBKEY="$(generate_remote_pubkey 2>/dev/null | tr -d '\r' | tail -n1 || true)"
    if [[ -z "${OUT_PUBKEY:-}" ]]; then
      warn "Remote WG public key not found; remote/local WG rewrite skipped. Run Repair tunnel if needed."
      remote_ok=0
    fi
  fi

  # Remote config must be written first. Run write helpers in subshells so any
  # legacy 'exit/die' inside them cannot throw the operator back to shell.
  if (( remote_ok == 1 )); then
    if ( write_wg_conf_remote ); then
      remote_written=1
    else
      warn "Remote WG config write failed; remote restart skipped. Local runtime will not be stopped unless local config writes cleanly."
      remote_ok=0
      apply_failed=1
    fi
  fi

  if ( write_wg_conf_local ); then
    local_written=1
  else
    err "Local WG config write failed; keeping current local WG runtime untouched."
    return 1
  fi

  if (( remote_written == 1 )); then
    ssh_run_root_best_effort "systemctl daemon-reload >/dev/null 2>&1 || true; systemctl enable wg-quick@${WG_IF} >/dev/null 2>&1 || true; systemctl restart wg-quick@${WG_IF} >/dev/null 2>&1 || systemctl start wg-quick@${WG_IF} >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi

  if (( local_written == 1 )); then
    systemctl stop "$(svc_wg)" >/dev/null 2>&1 || true
    wg-quick down "${WG_IF}" >/dev/null 2>&1 || true
    ip link del "${WG_IF}" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable "$(svc_wg)" >/dev/null 2>&1 || true
    if ! systemctl restart "$(svc_wg)" >/dev/null 2>&1; then
      systemctl start "$(svc_wg)" >/dev/null 2>&1 || apply_failed=1
    fi
  fi

  # Re-apply local firewall/NAT after tunnel IP/port changes so DNAT destination
  # and MASQUERADE/FORWARD rules follow the active profile.
  azhdar_firewall_safety_local || true
  allow_mimic_port_local || true
  setup_rst_drop_local || true
  if [[ -n "${FORWARD_TCP_PORTS:-}${FORWARD_UDP_PORTS:-}" && "${ENABLE_TUN_IPV4:-1}" == "1" ]]; then
    remove_forward_rules_local || true
    setup_forward_ir || true
  else
    remove_forward_rules_local || true
  fi

  if (( remote_written == 1 )); then
    if [[ -n "${OUT_WG_IP:-}" && "${OUT_WG_IP}" != "peer" ]]; then
      SSH_MGMT_LAST_TRANSPORT="wg"
      SSH_MGMT_LAST_HOST="${OUT_WG_IP}"
      SSH_MGMT_LAST_PORT="${OUT_SSH_PORT:-22}"
    fi
    allow_mimic_port_remote || true
    allow_vless_on_remote_wg || true
    setup_rst_drop_remote || true
  fi

  sleep 3
  if azhdar_ping_ok_quiet; then
    SSH_MGMT_LAST_TRANSPORT="wg"
    SSH_MGMT_LAST_HOST="${OUT_WG_IP:-}"
    SSH_MGMT_LAST_PORT="${OUT_SSH_PORT:-22}"
    profile_save >/dev/null 2>&1 || true
    ok "WireGuard configs applied and tunnel is reachable."
  else
    warn "WireGuard configs applied, but tunnel health is not confirmed yet. Running one safe repair pass."
    azhdar_repair_tunnel_limited 90 || true
    if azhdar_ping_ok_quiet; then
      ok "Tunnel became reachable after repair pass."
    else
      warn "Tunnel is still not confirmed. Use menu 13 -> Deep repair now if it remains down."
      apply_failed=1
    fi
  fi

  status_cache_invalidate || true
  if (( apply_failed == 1 )); then
    warn "WireGuard apply completed with warnings; see Diagnostics/Repair log."
    return 1
  fi
  ok "WireGuard config apply completed."
  return 0
}

apply_mimic_confs_best_effort(){
  step "Applying Mimic config to both servers (remote-first, best-effort)"

  # Remote-first is important when script SSH uses the existing WG tunnel. If we
  # restart local Mimic first during a port/filter change, the only management
  # path to OUT can be cut before OUT receives its new config.
  if [[ "${WG_MODE:-classic}" != "account" ]]; then
    if [[ -n "${OUT_SSH_HOST:-}" ]] && ssh_run "echo OK" >/dev/null 2>&1; then
      [[ -n "${REMOTE_WAN_IF:-}" ]] || REMOTE_WAN_IF="$(remote_detect_wan_if_quiet || true)"

      if [[ -n "${REMOTE_WAN_IF:-}" ]]; then
        ssh_run_root_best_effort "rm -f /etc/mimic/$(printf '%q' "${REMOTE_WAN_IF}").conf" >/dev/null 2>&1 || true
      fi

      if ( write_mimic_conf_remote ); then
        REMOTE_WAN_IF="$(remote_detect_wan_if_quiet || true)"
        if [[ -n "${REMOTE_WAN_IF:-}" ]]; then
          restart_svc_remote "mimic@${REMOTE_WAN_IF}" || true
        else
          warn "Remote WAN interface not detected after config write; remote Mimic restart skipped."
        fi
      else
        warn "Remote Mimic config was not written; remote Mimic restart skipped."
      fi
    else
      warn "SSH unavailable; remote Mimic config not applied."
    fi
  fi

  local wan=""
  wan="$(detect_wan_if || true)"
  if [[ -n "${wan}" ]]; then
    if write_mimic_conf_local; then
      restart_svc_local "mimic@${wan}" || true
    else
      warn "Local Mimic config was not written; local Mimic restart skipped."
    fi
  else
    warn "Local WAN interface not detected; local Mimic config/restart skipped."
  fi

  ok "Mimic config applied (best-effort)."
  return 0
}
wg_port_patch_conf_local(){
  local cfg="/etc/wireguard/${WG_IF}.conf"
  local endpoint=""
  [[ -n "${WG_IF:-}" ]] || { err "WG_IF is empty; local WG port patch skipped."; return 1; }
  [[ -n "${WG_PORT:-}" && "${WG_PORT}" =~ ^[0-9]+$ ]] || { err "Invalid WG_PORT='${WG_PORT:-}'."; return 1; }
  [[ -f "$cfg" ]] || { warn "Local WG config not found: ${cfg}; runtime/config patch skipped."; return 1; }

  backup_file "$cfg" 2>/dev/null || true

  if grep -qE '^[[:space:]]*ListenPort[[:space:]]*=' "$cfg" 2>/dev/null; then
    sed -i -E "s|^[[:space:]]*ListenPort[[:space:]]*=.*|ListenPort = ${WG_PORT}|" "$cfg" || return 1
  else
    local tmp
    tmp="$(mktemp -t azhdar-wg-port.local.XXXXXX)"
    awk -v port="$WG_PORT" '
      BEGIN{done=0}
      /^[[:space:]]*\[Peer\][[:space:]]*$/ && !done { print "ListenPort = " port; done=1 }
      { print }
      END{ if(!done) print "ListenPort = " port }
    ' "$cfg" >"$tmp" && mv -f "$tmp" "$cfg" || { rm -f "${tmp:-}" 2>/dev/null || true; return 1; }
  fi

  if [[ -n "${OUT_PUBLIC_IP:-}" ]]; then
    endpoint="$(format_ipport "${OUT_PUBLIC_IP}" "${WG_PORT}" 2>/dev/null || echo "${OUT_PUBLIC_IP}:${WG_PORT}")"
    if grep -qE '^[[:space:]]*Endpoint[[:space:]]*=' "$cfg" 2>/dev/null; then
      sed -i -E "s|^[[:space:]]*Endpoint[[:space:]]*=.*|Endpoint = ${endpoint}|" "$cfg" || return 1
    fi
  fi

  chmod 600 "$cfg" 2>/dev/null || true
  ok "IR/local WG config patched: ListenPort=${WG_PORT}${endpoint:+, Endpoint=${endpoint}}."
  return 0
}

wg_port_patch_runtime_local(){
  local endpoint="" runtime=""
  if ! command -v wg >/dev/null 2>&1 || ! ip link show "${WG_IF}" >/dev/null 2>&1; then
    warn "IR/local WG interface is not up; config is patched and runtime will use new port after service restart."
    return 0
  fi

  if ! wg set "${WG_IF}" listen-port "${WG_PORT}" >/dev/null 2>&1; then
    warn "IR/local runtime ListenPort could not be changed with wg set."
    return 1
  fi

  if [[ -n "${OUT_PUBLIC_IP:-}" && -n "${OUT_PUBKEY:-}" ]]; then
    endpoint="$(format_ipport "${OUT_PUBLIC_IP}" "${WG_PORT}" 2>/dev/null || echo "${OUT_PUBLIC_IP}:${WG_PORT}")"
    wg set "${WG_IF}" peer "${OUT_PUBKEY}" endpoint "${endpoint}" >/dev/null 2>&1 || true
  fi

  runtime="$(wg show "${WG_IF}" listen-port 2>/dev/null | tr -d '\r' | tail -n1 || true)"
  if [[ "$runtime" == "$WG_PORT" ]]; then
    ok "IR/local WG runtime patched: ListenPort=${runtime}."
    return 0
  fi

  warn "IR/local WG runtime did not confirm new port (runtime=${runtime:-unknown}, expected=${WG_PORT})."
  return 1
}

wg_port_patch_remote_and_restart_mimic(){
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    ok "OUT/remote WG port patch skipped (account mode)."
    return 0
  fi
  if ! ssh_check_quiet >/dev/null 2>&1; then
    warn "SSH unavailable; OUT/remote WG port and Mimic runtime not applied."
    return 1
  fi

  local out="" rc=0
  out="$(ssh_run_stdin_env_root \
    "WG_IF=${WG_IF}" \
    "WG_PORT=${WG_PORT}" \
    "REMOTE_WAN_IF=${REMOTE_WAN_IF:-}" <<'REMOTE'
set +e
failed=0
config_status="missing"
runtime_status="not-up"
mimic_status="skipped"

patch_listen_port_file(){
  cfg="$1"
  port="$2"
  [ -f "$cfg" ] || return 2
  cp -a "$cfg" "$cfg.bak.$(date +%s)" 2>/dev/null || true
  if grep -qE '^[[:space:]]*ListenPort[[:space:]]*=' "$cfg" 2>/dev/null; then
    sed -i -E "s|^[[:space:]]*ListenPort[[:space:]]*=.*|ListenPort = ${port}|" "$cfg" || return 1
  else
    tmp="$(mktemp -t azhdar-wg-port.remote.XXXXXX)" || return 1
    awk -v port="$port" '
      BEGIN{done=0}
      /^[[:space:]]*\[Peer\][[:space:]]*$/ && !done { print "ListenPort = " port; done=1 }
      { print }
      END{ if(!done) print "ListenPort = " port }
    ' "$cfg" >"$tmp" && mv -f "$tmp" "$cfg" || { rm -f "$tmp" 2>/dev/null || true; return 1; }
  fi
  chmod 600 "$cfg" 2>/dev/null || true
  return 0
}

cfg="/etc/wireguard/${WG_IF}.conf"
patch_listen_port_file "$cfg" "$WG_PORT"
case "$?" in
  0) config_status="updated" ;;
  2) config_status="missing"; failed=1 ;;
  *) config_status="failed"; failed=1 ;;
esac

if command -v wg >/dev/null 2>&1 && ip link show "$WG_IF" >/dev/null 2>&1; then
  if wg set "$WG_IF" listen-port "$WG_PORT" >/dev/null 2>&1; then
    runtime_status="$(wg show "$WG_IF" listen-port 2>/dev/null | tr -d '\r' | tail -n1 || true)"
    [ "$runtime_status" = "$WG_PORT" ] || failed=1
  else
    runtime_status="failed"
    failed=1
  fi
fi

if [ -n "${REMOTE_WAN_IF:-}" ]; then
  if systemctl restart "mimic@${REMOTE_WAN_IF}" >/dev/null 2>&1; then
    mimic_status="restarted"
  else
    mimic_status="failed"
    failed=1
  fi
fi

systemctl daemon-reload >/dev/null 2>&1 || true
echo "config=${config_status};runtime=${runtime_status};mimic=${mimic_status}"
exit "$failed"
REMOTE
)"; rc=$?

  out="$(printf '%s' "$out" | tr -d '\r' | tail -n1)"
  if (( rc == 0 )); then
    ok "OUT/remote WG port applied: ${out:-ok}."
  else
    warn "OUT/remote WG port not fully confirmed: ${out:-no status}."
  fi
  return "$rc"
}

wg_port_verify_after_change(){
  local failed=0 runtime="" cfg="/etc/wireguard/${WG_IF}.conf" saved=""
  saved="$(profile_read_var "$PROFILE" WG_PORT 2>/dev/null || true)"
  if [[ "$saved" == "$WG_PORT" ]]; then
    ok "Profile confirms WG_PORT=${WG_PORT}."
  else
    warn "Profile WG_PORT check failed: saved=${saved:-empty}, expected=${WG_PORT}."
    failed=1
  fi

  if [[ -f "$cfg" ]] && grep -Eq "^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*${WG_PORT}[[:space:]]*$" "$cfg" 2>/dev/null; then
    ok "IR/local WG config confirms ListenPort=${WG_PORT}."
  else
    warn "IR/local WG config does not confirm ListenPort=${WG_PORT}."
    failed=1
  fi

  if command -v wg >/dev/null 2>&1 && ip link show "${WG_IF}" >/dev/null 2>&1; then
    runtime="$(wg show "${WG_IF}" listen-port 2>/dev/null | tr -d '\r' | tail -n1 || true)"
    if [[ "$runtime" == "$WG_PORT" ]]; then
      ok "IR/local WG runtime confirms ListenPort=${WG_PORT}."
    else
      warn "IR/local WG runtime is ${runtime:-unknown}, expected ${WG_PORT}."
      failed=1
    fi
  fi

  if [[ "${WG_MODE:-classic}" != "account" ]] && ssh_check_quiet >/dev/null 2>&1; then
    local rout=""
    rout="$(ssh_run "printf 'cfg='; grep -Eq '^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*${WG_PORT}[[:space:]]*$' /etc/wireguard/${WG_IF}.conf 2>/dev/null && printf ok || printf fail; printf ';runtime='; if command -v wg >/dev/null 2>&1 && ip link show ${WG_IF} >/dev/null 2>&1; then wg show ${WG_IF} listen-port 2>/dev/null | tr -d '\r' | tail -n1; else printf not-up; fi" 2>/dev/null | tr -d '\r' | tail -n1 || true)"
    if echo "$rout" | grep -q "cfg=ok"; then
      ok "OUT/remote WG config confirms ListenPort=${WG_PORT}."
    else
      warn "OUT/remote WG config check did not confirm new port: ${rout:-no status}."
      failed=1
    fi
    if echo "$rout" | grep -q "runtime=${WG_PORT}"; then
      ok "OUT/remote WG runtime confirms ListenPort=${WG_PORT}."
    elif echo "$rout" | grep -q "runtime=not-up"; then
      warn "OUT/remote WG interface is not up; config is patched but runtime not checked."
    else
      warn "OUT/remote WG runtime did not confirm new port: ${rout:-no status}."
      failed=1
    fi
  fi

  return "$failed"
}

apply_port_change_best_effort(){
  local _had_errexit=0
  case "$-" in *e*) _had_errexit=1; set +e ;; esac

  local new_port="${WG_PORT}" old_port="${OLD_WG_PORT:-}" failed=0 rc=0 wan=""
  step "Applying WG_PORT=${new_port} on BOTH servers (safe live patch)"

  if [[ -z "$new_port" || ! "$new_port" =~ ^[0-9]+$ || "$new_port" -lt 1 || "$new_port" -gt 65535 ]]; then
    err "Invalid WG_PORT: ${new_port:-empty}"
    (( _had_errexit == 1 )) && set -e
    return 1
  fi

  if profile_save >/dev/null 2>&1; then
    ok "Profile saved with WG_PORT=${new_port}."
  else
    err "Profile save failed; port apply canceled."
    (( _had_errexit == 1 )) && set -e
    return 1
  fi

  # Open the NEW port before touching runtime. Do not remove the old port until
  # the new one is applied, otherwise management/tunnel traffic can be cut mid-apply.
  WG_PORT="$new_port"
  allow_mimic_port_local || { warn "IR/local firewall allow for new port was not confirmed."; failed=1; }
  allow_mimic_port_remote || { warn "OUT/remote firewall allow for new port was not confirmed."; failed=1; }
  add_rst_drop_local || true
  add_rst_drop_remote || true

  # Write Mimic configs first, but restart Mimic only after WG runtime is patched.
  if [[ "${WG_MODE:-classic}" != "account" ]]; then
    if write_mimic_conf_remote; then
      ok "OUT/remote Mimic config patched for WG_PORT=${new_port}."
    else
      warn "OUT/remote Mimic config was not patched; remote port apply may be incomplete."
      failed=1
    fi
  fi

  if write_mimic_conf_local; then
    ok "IR/local Mimic config patched for WG_PORT=${new_port}."
  else
    warn "IR/local Mimic config was not patched."
    failed=1
  fi

  wg_port_patch_remote_and_restart_mimic; rc=$?
  (( rc == 0 )) || failed=1

  wg_port_patch_conf_local; rc=$?
  (( rc == 0 )) || failed=1
  wg_port_patch_runtime_local; rc=$?
  (( rc == 0 )) || failed=1

  wan="$(detect_wan_if 2>/dev/null || true)"
  if [[ -n "$wan" ]]; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    if systemctl restart "mimic@${wan}" >/dev/null 2>&1; then
      ok "IR/local Mimic restarted on port ${new_port}."
    else
      warn "IR/local Mimic restart was not confirmed."
      failed=1
    fi
  else
    warn "IR/local WAN interface not detected; Mimic restart skipped."
    failed=1
  fi

  # After new port is in place, remove stale firewall/raw rules for the old port.
  if [[ -n "$old_port" && "$old_port" =~ ^[0-9]+$ && "$old_port" != "$new_port" ]]; then
    WG_PORT="$old_port"
    remove_allow_rules_local || true
    remove_allow_rules_remote || true
    remove_rst_drop_local || true
    remove_rst_drop_remote || true
    WG_PORT="$new_port"
    allow_mimic_port_local || true
    allow_mimic_port_remote || true
    add_rst_drop_local || true
    add_rst_drop_remote || true
    ok "Old WG_PORT=${old_port} firewall/raw rules cleaned up best-effort."
  fi

  wg_port_verify_after_change; rc=$?
  (( rc == 0 )) || failed=1

  sleep 2
  if azhdar_ping_ok_quiet; then
    ok "Tunnel health confirmed after WG_PORT change."
  else
    warn "Tunnel health is not confirmed yet after WG_PORT change. Check STATUS or run Repair if handshake does not return."
    failed=1
  fi

  status_cache_invalidate || true
  if (( failed == 0 )); then
    ok "WG_PORT change applied successfully on IR and OUT: ${old_port:-?} -> ${new_port}."
    (( _had_errexit == 1 )) && set -e
    return 0
  fi

  warn "WG_PORT change finished with warnings. Profile is saved with WG_PORT=${WG_PORT}; see messages above for the side that did not confirm."
  (( _had_errexit == 1 )) && set -e
  return 1
}

tunnel_auto_pick(){
  step "Auto-pick tunnel IP range + WG IPs"
  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" ]]; then
    if ssh_run "echo OK" >/dev/null 2>&1; then
      pick_subnet_pairwise || set_subnet_vars "${TUN_SUBNET}"
    else
      set_subnet_vars "${TUN_SUBNET}"
    fi
  fi
  if [[ "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then
    if ssh_run "echo OK" >/dev/null 2>&1; then
      pick_subnet6_pairwise || set_subnet6_vars "${TUN_SUBNET6}"
    else
      set_subnet6_vars "${TUN_SUBNET6}"
    fi
  fi
  ok "Tunnel IPs updated in memory."
}

tunnel_manual_set(){
  step "Manual tunnel IP range + WG IPs"

  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" ]]; then
    local cidr=""
    while true; do
      read -rp "IPv4 tunnel subnet CIDR [${TUN_SUBNET}]: " cidr || true
      cidr="${cidr:-$TUN_SUBNET}"
      valid_cidr4 "$cidr" && break
      warn "Invalid IPv4 CIDR."
    done
    TUN_SUBNET="$cidr"

    if subnet_overlaps_local "$TUN_SUBNET"; then
      warn "IPv4 tunnel subnet overlaps local routes."
      [[ "$(prompt_yesno "Continue anyway?" "N")" == "Y" ]] || return 1
    fi
    if ssh_run "echo OK" >/dev/null 2>&1 && subnet_overlaps_remote "$TUN_SUBNET"; then
      warn "IPv4 tunnel subnet overlaps remote routes."
      [[ "$(prompt_yesno "Continue anyway?" "N")" == "Y" ]] || return 1
    fi

    set_subnet_vars "$TUN_SUBNET"
    while true; do
      IR_WG_IP="$(prompt_ipv4 "IR WG IPv4" "${IR_WG_IP}")"
      ip_in_cidr "$IR_WG_IP" "$TUN_SUBNET" && break
      warn "IR WG IPv4 is not inside ${TUN_SUBNET}."
    done
    while true; do
      OUT_WG_IP="$(prompt_ipv4 "OUT WG IPv4" "${OUT_WG_IP}")"
      ip_in_cidr "$OUT_WG_IP" "$TUN_SUBNET" && [[ "$OUT_WG_IP" != "$IR_WG_IP" ]] && break
      warn "OUT WG IPv4 must be inside ${TUN_SUBNET} and different from IR."
    done
  fi

  if [[ "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then
    local cidr6=""
    while true; do
      read -rp "IPv6 tunnel subnet CIDR [${TUN_SUBNET6}]: " cidr6 || true
      cidr6="${cidr6:-$TUN_SUBNET6}"
      valid_cidr6 "$cidr6" && break
      warn "Invalid IPv6 CIDR (python3 required for validation)."
    done
    TUN_SUBNET6="$(normalize_cidr6 "$cidr6")"
    set_subnet6_vars "$TUN_SUBNET6"
    while true; do
      IR_WG_IP6="$(normalize_ipv6 "$(prompt_ipv6 "IR WG IPv6" "${IR_WG_IP6}")")"
      ip_in_cidr "$IR_WG_IP6" "$TUN_SUBNET6" && break
      warn "IR WG IPv6 is not inside ${TUN_SUBNET6}."
    done
    while true; do
      OUT_WG_IP6="$(normalize_ipv6 "$(prompt_ipv6 "OUT WG IPv6" "${OUT_WG_IP6}")")"
      ip_in_cidr "$OUT_WG_IP6" "$TUN_SUBNET6" && [[ "$OUT_WG_IP6" != "$IR_WG_IP6" ]] && break
      warn "OUT WG IPv6 must be inside ${TUN_SUBNET6} and different from IR."
    done
  fi

  ok "Tunnel IPs updated in memory."
}
menu_advanced(){
  ensure_profile_selected || return 0

  while true; do
    banner
    echo -e "${BOLD}${WHT}Advanced Settings (${PROFILE})${RST}"
    hr
    echo -e "${DIM}WG:${RST} IF=${WG_IF}  PORT=${WG_PORT}  MTU=${MTU} (${MTU_MODE:-manual})  KEEPALIVE=${KEEPALIVE}"
    echo -e "${DIM}Tunnel mode:${RST} ${TUN_MODE:-dual}   Subnets: v4=${TUN_SUBNET}  v6=${TUN_SUBNET6}"
    echo -e "${DIM}Mimic filter IPs:${RST} local=${IR_LOCAL_IP:-?}   remote=${OUT_LOCAL_IP:-?}   out_public=${OUT_PUBLIC_IP:-?}"
    local _fwd_dst="${FORWARD_DST_IP:-${OUT_WG_IP}}"
    echo -e "${DIM}Forwarding:${RST} TCP=${FORWARD_TCP_PORTS:-<none>}  UDP=${FORWARD_UDP_PORTS:-<none>}  dst=${_fwd_dst}:${VLESS_DST_PORT:-<none>}"
    echo -e "${DIM}IR SSH exempt port:${RST} ${IR_SSH_PORT:-22}"
    echo -e "${DIM}SSH management:${RST} transport=${SSH_MGMT_TRANSPORT:-auto} last=${SSH_MGMT_LAST_TRANSPORT:-none}:${SSH_MGMT_LAST_HOST:-}"
    hr
    echo " 1) Re-run Remote Preflight"
    echo " 2) Auto-detect Mimic filter IPs (save + apply on BOTH)"
    echo " 3) Change WG_PORT (save + live apply + verify on BOTH)"
    echo " 4) MTU / Keepalive (manual or auto, apply on BOTH)"
    echo " 5) Auto-pick tunnel IP range + WG IPs (save + apply)"
    echo " 6) Manual set tunnel IP range + WG IPs (save + apply)"
    echo " 7) Set tunnel IP mode (IPv4 / IPv6 / dual) (save + apply)"
    echo " 8) Manage port forwarding (TCP/UDP/dst) (save + apply)"
    echo " 9) Change IR SSH exempt port"
    echo "10) Change SSH management transport (auto/direct/wg)"
    echo " 0) Back"
    hr

    local c
    c="$(read_choice "Select" "1" "2" "3" "4" "5" "6" "7" "8" "9" "10" "0")"
    case "$c" in
      1)
        banner
        remote_preflight || true
        pause
        ;;
      2)
        banner
        auto_detect_local_ips || true
        profile_save 2>/dev/null || true
        apply_mimic_confs_best_effort || true
        pause
        ;;
      3)
        banner
        local old_port new_port sug
        old_port="${WG_PORT}"
        sug="$(suggest_wg_port || true)"
        [[ -n "$sug" ]] && echo -e "${DIM}Suggested free port:${RST} ${sug}"
        while true; do
          new_port="$(prompt_port "New WG_PORT" "${WG_PORT}")"
          WG_PORT="$new_port"
          if ports_validate_current_or_warn; then
            break
          fi
          local _sug
          _sug="$(suggest_wg_port || true)"
          if [[ -n "${_sug:-}" && "${_sug}" != "${WG_PORT}" ]]; then
            warn "Suggested free port: ${_sug}"
            if [[ "$(prompt_yesno "Use suggested port ${_sug}?" "Y")" == "Y" ]]; then
              WG_PORT="${_sug}"
              new_port="${_sug}"
              continue
            fi
          fi
          warn "Selected tunnel/forward port conflicts with another profile. Check the warning above and choose a different port."
        done
        OLD_WG_PORT="$old_port"
        profile_save
        if ! apply_port_change_best_effort; then
          warn "Change WG_PORT did not fully confirm health, but AZHDAR stayed open. Check menu 13 Repair if needed."
        fi
        unset OLD_WG_PORT
        pause
        ;;
      4)
        while true; do
          banner
          echo -e "${BOLD}${WHT}MTU / Keepalive (${PROFILE})${RST}"
          hr
          echo -e "${DIM}Current:${RST} MTU=${MTU}  MTU_MODE=${MTU_MODE:-manual}  KEEPALIVE=${KEEPALIVE}"
          hr
          echo " 1) Auto-find best common MTU now (apply on BOTH)"
          echo " 2) Manual set MTU (apply on BOTH)"
          echo " 3) Set Keepalive (apply on BOTH)"
          echo " 0) Back"
          hr
          local m
          m="$(read_choice "Select" "1" "2" "3" "0")"
          case "$m" in
            1)
              mtu_autofind_and_apply || true
              pause
              ;;
            2)
              MTU_MODE="manual"
              MTU="$(prompt_mtu "MTU" "${MTU:-1272}")"
              profile_save 2>/dev/null || true
              apply_wg_configs_mtu_safe || warn "MTU was saved, but live apply/health was not fully confirmed."
              pause
              ;;
            3)
              KEEPALIVE="$(prompt_keepalive "PersistentKeepalive" "${KEEPALIVE:-25}")"
              profile_save 2>/dev/null || true
              apply_wg_configs_mtu_safe || warn "MTU was saved, but live apply/health was not fully confirmed."
              pause
              ;;
            0)
              break
              ;;
          esac
        done
        ;;
      5)
        banner
        prepare_ssh_mgmt_for_tunnel_change || true
        tunnel_auto_pick || { warn "Tunnel auto-pick failed; keeping previous settings."; pause; continue; }
        profile_save 2>/dev/null || true
        apply_wg_configs_best_effort || true
        pause
        ;;
      6)
        banner
        prepare_ssh_mgmt_for_tunnel_change || true
        tunnel_manual_set || { warn "No changes applied."; pause; continue; }
        profile_save 2>/dev/null || true
        apply_wg_configs_best_effort || true
        pause
        ;;
      7)
        banner
        prepare_ssh_mgmt_for_tunnel_change || true
        prompt_tunnel_mode || true
        # Ensure defaults exist for enabled families
        if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && -z "${TUN_SUBNET:-}" ]]; then
          TUN_SUBNET="10.66.66.0/24"
          set_subnet_vars "$TUN_SUBNET"
        fi
        if [[ "${ENABLE_TUN_IPV6:-0}" == "1" && -z "${TUN_SUBNET6:-}" ]]; then
          TUN_SUBNET6="fd00:66::/64"
          set_subnet6_vars "$TUN_SUBNET6"
        fi
        profile_save 2>/dev/null || true
        apply_wg_configs_best_effort || true
        pause
        ;;
      8)
        while true; do
          banner
          echo -e "${BOLD}${WHT}Manage Port Forwarding (${PROFILE})${RST}"
          hr
          local _dst_ip="${FORWARD_DST_IP:-${OUT_WG_IP}}"
          echo -e "Forwarding: TCP=${FORWARD_TCP_PORTS:-<none>}  UDP=${FORWARD_UDP_PORTS:-<none>}  dst=${_dst_ip}:${VLESS_DST_PORT:-<none>}"
          hr
          echo " 1) Change TCP ports"
          echo " 2) Change UDP ports"
          echo " 3) Change destination IP (DNAT dst)"
          echo " 4) Change destination port"
          echo " 5) Apply now (no WG/Mimic/SSH restart)"
          echo " 6) Reset forwarding (disable)"
          echo " 0) Back"
          hr
          local f
          f="$(read_choice "Select" "1" "2" "3" "4" "5" "6" "0")"
          case "$f" in
            1)
              read -rp "TCP ports (comma-separated, empty=none) [${FORWARD_TCP_PORTS:-}]: " FORWARD_TCP_PORTS || true
              FORWARD_TCP_PORTS="${FORWARD_TCP_PORTS:-}"
              protect_ir_ssh_port || true
              profile_save 2>/dev/null || true
              ;;
            2)
              read -rp "UDP ports (comma-separated, empty=none) [${FORWARD_UDP_PORTS:-}]: " FORWARD_UDP_PORTS || true
              FORWARD_UDP_PORTS="${FORWARD_UDP_PORTS:-}"
              profile_save 2>/dev/null || true
              ;;
            3)
              local _ip
              _ip="$(prompt_ipv4 "Destination IP (default: OUT_WG_IP)" "${FORWARD_DST_IP:-${OUT_WG_IP}}")"
              # store override only if different from OUT_WG_IP
              if [[ -n "${_ip:-}" && "${_ip}" != "${OUT_WG_IP}" ]]; then
                FORWARD_DST_IP="${_ip}"
              else
                FORWARD_DST_IP=""
              fi
              profile_save 2>/dev/null || true
              ;;
            4)
              VLESS_DST_PORT="$(prompt_port "Destination port" "${VLESS_DST_PORT:-2086}")"
              profile_save 2>/dev/null || true
              ;;
            5)
              banner
              if [[ "${ENABLE_TUN_IPV4:-1}" != "1" ]]; then
                err "Forwarding requires IPv4 tunnel mode. Enable IPv4 in Advanced first."
                pause
                continue
              fi
              local ports_all="${FORWARD_TCP_PORTS},${FORWARD_UDP_PORTS}"
              protect_ir_ssh_port || true
              if [[ -n "${IR_SSH_PORT:-}" ]] && echo ",${ports_all}," | grep -q ",${IR_SSH_PORT},"; then
                warn "Forwarding includes IR_SSH_PORT=${IR_SSH_PORT}; it will be skipped."
              fi
              azhdar_firewall_safety_local || true
              remove_forwarding_local || true
              setup_forward_ir || warn "Forwarding apply failed; check Diagnostics."
              persist_iptables_local || true
              allow_vless_on_remote_wg || true
              ok "Forwarding applied (best-effort)."
              pause
              ;;
            6)
              banner
              FORWARD_TCP_PORTS=""
              FORWARD_UDP_PORTS=""
              FORWARD_DST_IP=""
              VLESS_DST_PORT=""
              profile_save
              remove_forwarding_local || true
              persist_iptables_local || true
              ok "Forwarding reset/disabled (best-effort)."
              pause
              ;;
            0)
              break
              ;;
          esac
        done
        ;;
      9)
        banner
        IR_SSH_PORT="$(prompt_port "IR server SSH port to exempt" "${IR_SSH_PORT:-22}")"
        protect_ir_ssh_port || true
        profile_save
        ok "IR SSH exempt port saved: ${IR_SSH_PORT}"
        pause
        ;;
      10)
        banner
        echo -e "${BOLD}${WHT}SSH management transport (${PROFILE})${RST}"
        hr
        echo " 1) auto   - try public SSH, then WG IP if tunnel is up"
        echo " 2) direct - only OUT_SSH_HOST / public IP"
        echo " 3) wg     - prefer OUT_WG_IP, fallback to public IP"
        hr
        local sm
        sm="$(read_choice "Select" "1" "2" "3")"
        case "$sm" in
          1) SSH_MGMT_TRANSPORT="auto" ;;
          2) SSH_MGMT_TRANSPORT="direct" ;;
          3) SSH_MGMT_TRANSPORT="wg" ;;
        esac
        SSH_USE_MASTER="0"
        SSH_MGMT_LAST_TRANSPORT=""
        SSH_MGMT_LAST_HOST=""
        SSH_MGMT_LAST_PORT=""
        profile_save
        ok "SSH management transport saved: ${SSH_MGMT_TRANSPORT}"
        ssh_check || true
        pause
        ;;
      0)
        return 0
        ;;
    esac
  done
}


