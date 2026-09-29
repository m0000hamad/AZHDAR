# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Tunnel repair / watchdog --------------------
# This module is intentionally conservative. It repairs the active tunnel from
# saved profile state without deleting profiles, without touching ssh/sshd, and
# without requiring an IR server rebuild.

_tunnel_repair_state_dir(){ echo "${BASE_DIR}/repair"; }
_tunnel_repair_log(){ echo "${BASE_DIR}/repair-${PROFILE:-unknown}.log"; }
_tunnel_repair_lock(){ echo "/run/azhdar-repair-${PROFILE:-default}.lock"; }

_tunnel_repair_ts(){ date +%Y%m%d-%H%M%S 2>/dev/null || date +%s; }

_tunnel_repair_log_msg(){
  mkdir -p "$(dirname "$(_tunnel_repair_log)")" >/dev/null 2>&1 || true
  printf '%s %s\n' "$(date -Is 2>/dev/null || date)" "$*" >>"$(_tunnel_repair_log)" 2>/dev/null || true
  _log "REPAIR $*"
}

_tunnel_repair_load_active_profile(){
  ensure_dirs
  load_global || true
  if [[ -n "${CURRENT_PROFILE:-}" ]] && profile_exists "${CURRENT_PROFILE}"; then
    profile_load "${CURRENT_PROFILE}" || return 1
    defaults_profile
    [[ "${WG_MODE:-classic}" == "account" ]] && wg_account_apply_runtime_vars || true
    return 0
  fi

  local n first=""
  while read -r n; do
    [[ -n "$n" ]] || continue
    [[ -z "$first" ]] && first="$n"
    if [[ "$(profile_read_var "$n" PROFILE_ENABLED 2>/dev/null || echo 0)" == "1" ]]; then
      CURRENT_PROFILE="$n"
      save_global >/dev/null 2>&1 || true
      profile_load "$n" || return 1
      defaults_profile
      [[ "${WG_MODE:-classic}" == "account" ]] && wg_account_apply_runtime_vars || true
      return 0
    fi
  done < <(profiles_list 2>/dev/null || true)

  if [[ -n "$first" ]]; then
    CURRENT_PROFILE="$first"
    save_global >/dev/null 2>&1 || true
    profile_load "$first" || return 1
    defaults_profile
    [[ "${WG_MODE:-classic}" == "account" ]] && wg_account_apply_runtime_vars || true
    return 0
  fi

  return 1
}

_tunnel_repair_validate_profile(){
  [[ -n "${PROFILE:-}" ]] || { err "No active profile."; return 1; }
  [[ -n "${WG_IF:-}" ]] || WG_IF="$PROFILE"
  [[ -n "${WG_PORT:-}" && "${WG_PORT}" =~ ^[0-9]+$ ]] || { err "WG_PORT is invalid/empty."; return 1; }
  normalize_ir_ssh_port || true
  if [[ "${WG_PORT}" == "${IR_SSH_PORT:-22}" ]]; then
    err "WG_PORT (${WG_PORT}) equals protected IR SSH port (${IR_SSH_PORT:-22}). Change one of them first."
    return 1
  fi
  if [[ "${WG_MODE:-classic}" != "account" ]]; then
    [[ -n "${OUT_PUBLIC_IP:-}" ]] || warn "OUT_PUBLIC_IP is empty; Mimic filter may be incomplete."
    [[ -n "${OUT_PUBKEY:-}" ]] || warn "OUT_PUBKEY is empty; remote WG config may need wizard/key repair."
  fi
  return 0
}

_tunnel_repair_health_quiet(){
  [[ -n "${PROFILE:-}" ]] || return 1
  local wgsvc; wgsvc="$(svc_wg)"

  # A recent WG handshake only proves that some encrypted packets crossed the
  # transport. It does NOT prove the tunnel IP path is usable. In 3.2.24 the
  # repair flow could print "Tunnel repair succeeded" based only on handshake
  # while both tunnel pings were still 100% packet-loss. Treat handshake as
  # diagnostic info only; repair success requires a real tunnel ping.
  if ! systemctl is-active --quiet "$wgsvc" 2>/dev/null && ! ip link show "${WG_IF}" >/dev/null 2>&1; then
    return 1
  fi

  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && -n "${OUT_WG_IP:-}" && "${OUT_WG_IP}" != "peer" ]]; then
    ping4_local_once "${OUT_WG_IP}" && return 0 || true
  fi
  if [[ "${ENABLE_TUN_IPV6:-0}" == "1" && -n "${OUT_WG_IP6:-}" && "${OUT_WG_IP6}" != "peer" ]]; then
    ping6_local_once "${OUT_WG_IP6}" && return 0 || true
  fi
  # If SSH is available, also accept a successful reverse ping from OUT to IR.
  if [[ "${WG_MODE:-classic}" != "account" ]] && [[ -n "${OUT_SSH_HOST:-}" ]] && ssh_run "echo OK" >/dev/null 2>&1; then
    if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && -n "${IR_WG_IP:-}" && "${IR_WG_IP}" != "peer" ]]; then
      ping4_remote_once "${IR_WG_IP}" && return 0 || true
    fi
    if [[ "${ENABLE_TUN_IPV6:-0}" == "1" && -n "${IR_WG_IP6:-}" && "${IR_WG_IP6}" != "peer" ]]; then
      ping6_remote_once "${IR_WG_IP6}" && return 0 || true
    fi
  fi
  return 1
}

_tunnel_repair_snapshot(){
  local dir="${BASE_DIR}/snapshots/tunnel-repair-$(_tunnel_repair_ts)"
  mkdir -p "$dir" >/dev/null 2>&1 || true
  if have_cmd rsync; then
    rsync -a --exclude=snapshots "${BASE_DIR}/" "$dir/etc-azhdar/" 2>/dev/null || true
  else
    mkdir -p "$dir/etc-azhdar" 2>/dev/null || true
    find "${BASE_DIR}" -mindepth 1 -maxdepth 1 -not -name snapshots -exec cp -a {} "$dir/etc-azhdar/" \; 2>/dev/null || true
  fi
  cp -a /etc/wireguard "$dir/etc-wireguard" 2>/dev/null || true
  cp -a /etc/mimic "$dir/etc-mimic" 2>/dev/null || true
  if have_cmd iptables-save; then iptables-save >"$dir/iptables-save.v4" 2>/dev/null || true; fi
  if have_cmd ip6tables-save; then ip6tables-save >"$dir/iptables-save.v6" 2>/dev/null || true; fi
  # Keep the newest 10 repair snapshots; each is a few MB and a watchdog
  # repairing a filtered tunnel all day used to pile up hundreds.
  ls -1dt "${BASE_DIR}/snapshots/tunnel-repair-"* 2>/dev/null | tail -n +11 | while IFS= read -r _old; do
    rm -rf -- "$_old" 2>/dev/null || true
  done
  _tunnel_repair_log_msg "snapshot=${dir}"
  ok "Repair snapshot saved: ${dir}"
}

_tunnel_repair_stop_local_runtime(){
  # Mimic runs ONE shared systemd instance per WAN interface (mimic@<wan>),
  # not per-profile. Every other AZHDAR profile on this same WAN multiplexes
  # through that same instance. Only stop the instance for THIS profile's own
  # WAN so repairing one profile does not bounce every sibling profile that
  # happens to share a different WAN (multi-NIC boxes). On a single-NIC box
  # siblings on the same WAN still see a brief reconnect blip here; that is
  # unavoidable given Mimic's shared-per-WAN design, not fixable per-profile.
  local wan wgsvc
  wan="$(mimic_detect_local_if 2>/dev/null || detect_wan_if 2>/dev/null || true)"
  wgsvc="$(svc_wg)"
  if command -v systemctl >/dev/null 2>&1; then
    [[ -n "$wan" ]] && systemctl stop "mimic@${wan}" >/dev/null 2>&1 || true
    systemctl stop "$wgsvc" >/dev/null 2>&1 || true
    systemctl reset-failed "$wgsvc" "mimic@${wan}" >/dev/null 2>&1 || true
  fi
  wg-quick down "${WG_IF}" >/dev/null 2>&1 || true
  ip link del "${WG_IF}" >/dev/null 2>&1 || true
}

_tunnel_repair_remove_local_poison(){
  azhdar_firewall_safety_local || true
  remove_forward_rules_local || true
  remove_rst_drop_local || true
  remove_allow_rules_local || true
  remove_profile_forward_rules_by_match_local || true
  azhdar_firewall_safety_local || true

  # Clean persisted netfilter snapshots so old DNAT/raw rules do not come back.
  if declare -F _recovery_clean_saved_iptables_local >/dev/null 2>&1; then
    _recovery_clean_saved_iptables_local || true
  fi
}

_tunnel_repair_remote_available(){
  [[ "${WG_MODE:-classic}" == "account" ]] && return 1
  [[ -n "${OUT_SSH_HOST:-}" ]] || return 1
  ssh_check_quiet >/dev/null 2>&1
}

_tunnel_repair_remove_remote_poison(){
  [[ "${WG_MODE:-classic}" == "account" ]] && return 0
  remove_forward_rules_remote || true
  remove_rst_drop_remote || true
  remove_allow_rules_remote || true
}

_tunnel_repair_write_configs(){
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    write_wg_conf_local
    return 0
  fi

  if _tunnel_repair_remote_available; then
    [[ -n "${REMOTE_WAN_IF:-}" ]] || REMOTE_WAN_IF="$(remote_detect_wan_if_quiet 2>/dev/null || true)"
    write_mimic_conf_remote || true
    write_wg_conf_remote || true
  else
    warn "Remote SSH is unavailable during repair; keeping remote config as-is."
  fi

  write_mimic_conf_local || true
  write_wg_conf_local
}

_tunnel_repair_apply_firewall(){
  azhdar_firewall_safety_local || true
  allow_mimic_port_local || true
  setup_rst_drop_local || true
  allow_forward_ports_local || true
  if [[ -n "${FORWARD_TCP_PORTS:-}${FORWARD_UDP_PORTS:-}" ]]; then
    setup_forward_ir || true
  fi

  if _tunnel_repair_remote_available; then
    allow_mimic_port_remote || true
    allow_vless_on_remote_wg || true
    setup_rst_drop_remote || true
  else
    warn "Remote SSH unavailable; remote firewall repair skipped."
  fi
}

_tunnel_repair_restart_services(){
  # restart_services_* already enables and starts the units, so the previous
  # start_services_* call only doubled every service transition.
  if [[ "${WG_MODE:-classic}" != "account" ]] && _tunnel_repair_remote_available; then
    restart_services_remote || true
  fi
  restart_services_local || true
}

_tunnel_repair_pick_port(){
  # usage: _tunnel_repair_pick_port [port] [auto]
  # Sets TUNNEL_NEW_PORT to a port that is free for TCP and UDP on IR AND on
  # OUT (see ports_tunnel_port_problems). With a port argument only that port
  # is checked. Without one, a free port is suggested and the user may type
  # another; with "auto" (watchdog) or without a terminal the suggestion is
  # taken as-is.
  local want="${1:-}" ask=0 ldump rdump sug problems
  [[ -t 0 && "${2:-}" != "auto" ]] && ask=1
  TUNNEL_NEW_PORT=""
  step "Check tunnel port on IR and OUT"
  ports_build_registry
  ldump="$(ports_tunnel_dump_local)"
  rdump="$(ports_tunnel_dump_remote)"
  if ! grep -qx "SS_OK" <<<"$ldump"; then
    err "Could not list the ports in use on IR (is 'ss' installed?)."
    return 1
  fi
  if ! grep -qx "SS_OK" <<<"$rdump"; then
    err "Could not list the ports in use on OUT over SSH. The new port must be checked on both servers, so the tunnel port stays ${WG_PORT}."
    return 1
  fi

  sug="$(ports_tunnel_port_suggest "$ldump" "$rdump" || true)"
  while true; do
    if [[ -z "$want" ]]; then
      if (( ask == 0 )); then
        [[ -n "$sug" ]] || { err "No port is free on both IR and OUT near ${WG_PORT}."; return 1; }
        want="$sug"
      else
        echo -e "${DIM}Current tunnel port:${RST} ${WG_PORT}"
        [[ -n "$sug" ]] && echo -e "${DIM}Free on IR and OUT:${RST} ${sug}"
        want="$(prompt_port "New tunnel port" "${sug}")"
      fi
    fi

    if [[ "$want" == "${WG_PORT}" ]]; then
      problems="already the tunnel port of this profile"
    else
      problems="$(ports_tunnel_port_problems "$want" "$ldump" "$rdump")"
    fi
    if [[ -z "$problems" ]]; then
      ok "Port ${want} is free on IR and OUT (TCP and UDP)."
      TUNNEL_NEW_PORT="$want"
      return 0
    fi

    warn "Port ${want} cannot be the tunnel port:"
    sed 's/^/  - /' <<<"$problems"
    [[ -z "${1:-}" ]] && (( ask == 1 )) || return 1
    [[ "$(prompt_yesno "Choose another port?" "Y")" == "Y" ]] || return 1
    want=""
  done
}

_tunnel_repair_change_port(){
  # usage: _tunnel_repair_change_port [port] [auto]
  # Pick (or check) a new tunnel port and save it in the profile. The rest of
  # azhdar_repair_tunnel then rebuilds both ends on it: stale rules are removed
  # by profile tag whatever their port, and WG configs, Mimic filters and the
  # firewall are all written from the saved WG_PORT.
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    err "Account-mode profiles take the port from the provider config; it cannot be changed here."
    return 1
  fi
  if ! ensure_remote_sudo >/dev/null 2>&1; then
    err "OUT is not reachable over SSH (as root). The tunnel port must change on IR and OUT together, so it stays ${WG_PORT}."
    return 1
  fi
  _tunnel_repair_pick_port "${1:-}" "${2:-}" || return 1

  local old="${WG_PORT}"
  WG_PORT="${TUNNEL_NEW_PORT}"
  if ! profile_save >/dev/null 2>&1; then
    WG_PORT="$old"
    err "Profile save failed; the tunnel port stays ${old}."
    return 1
  fi
  _tunnel_repair_log_msg "tunnel port ${old} -> ${WG_PORT}"
  ok "Tunnel port ${old} -> ${WG_PORT} saved; both servers are rebuilt on it below."
}

_tunnel_repair_remote_listen_port(){
  # ListenPort in OUT's WG config for this profile (empty when unreadable).
  ssh_run "${REMOTE_SUDO:-} grep -E '^[[:space:]]*ListenPort[[:space:]]*=' /etc/wireguard/${WG_IF}.conf 2>/dev/null | tail -n1" 2>/dev/null \
    | tr -d '\r' | tail -n1 | tr -dc '0-9' || true
}

_tunnel_repair_wait_connected(){
  local i max="${1:-5}" delay="${2:-5}"
  for ((i=1;i<=max;i++)); do
    sleep "$delay"
    if _tunnel_repair_health_quiet || azhdar_ping_ok_quiet; then
      return 0
    fi
    _tunnel_repair_log_msg "health-check failed attempt ${i}/${max}"
  done
  return 1
}


azhdar_repair_tunnel_limited(){
  # Run one automatic repair pass with a hard wall-clock cap so UI never looks stuck.
  local limit="${1:-90}" log pid i rc=1
  [[ "$limit" =~ ^[0-9]+$ ]] || limit=90
  (( limit < 20 )) && limit=20
  log="/tmp/azhdar-repair-pass-${PROFILE:-default}-$$.log"
  ( azhdar_repair_tunnel --auto --yes >"$log" 2>&1 ) &
  pid=$!
  for ((i=0;i<limit;i++)); do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      wait "$pid" 2>/dev/null; rc=$?
      break
    fi
    sleep 1
  done
  if kill -0 "$pid" >/dev/null 2>&1; then
    warn "Safe repair pass timed out after ${limit}s; stopping it. Run menu 13 for full repair/diagnostics."
    kill "$pid" >/dev/null 2>&1 || true
    sleep 1
    kill -9 "$pid" >/dev/null 2>&1 || true
    rc=124
  fi
  if [[ -s "$log" ]]; then
    if [[ "$rc" == "0" ]]; then
      ok "Safe repair pass completed."
    else
      warn "Safe repair pass finished with issues. Full output saved: $log"
      grep -E "(✗|!|ERROR|FAILED|failed|Fatal|RESULT:)" "$log" 2>/dev/null | tail -n 12 || true
    fi
  fi
  if [[ "$rc" == "0" ]]; then
    rm -f "$log" 2>/dev/null || true
  fi
  return "$rc"
}

azhdar_repair_tunnel(){
  need_root
  ensure_dirs

  local mode="manual" assume_yes="0" deep="0" change_port="0" new_port="" arg
  for arg in "$@"; do
    case "$arg" in
      --auto|--watchdog) mode="auto"; assume_yes="1" ;;
      --yes|-y) assume_yes="1" ;;
      --deep) deep="1" ;;
      --new-port) change_port="1" ;;
      --new-port=*) change_port="1"; new_port="${arg#--new-port=}" ;;
    esac
  done

  if ! _tunnel_repair_load_active_profile; then
    err "No AZHDAR profile found for tunnel repair."
    return 1
  fi

  local lock
  lock="$(_tunnel_repair_lock)"
  mkdir -p /run >/dev/null 2>&1 || true
  exec 9>"$lock" || true
  if command -v flock >/dev/null 2>&1; then
    flock -n 9 || { warn "Another AZHDAR tunnel repair is already running."; return 0; }
  fi

  if [[ "$mode" == "manual" ]]; then
    banner
    echo -e "${BOLD}${WHT}Tunnel repair${RST}"
    hr
    echo -e "${DIM}Profile:${RST} ${PROFILE}"
    echo -e "${DIM}This repairs WG/Mimic/firewall runtime from the saved profile without deleting the profile and without touching sshd.${RST}"
    echo
    if [[ "$assume_yes" != "1" ]]; then
      [[ "$(prompt_yesno "Run repair now?" "Y")" == "Y" ]] || { warn "Canceled."; return 1; }
    fi
  fi

  _tunnel_repair_log_msg "start mode=${mode} profile=${PROFILE}${new_port:+ new_port=${new_port}}"
  _tunnel_repair_validate_profile || return 1

  if (( change_port == 0 )) && _tunnel_repair_health_quiet; then
    _tunnel_repair_log_msg "already healthy"
    [[ "$mode" == "manual" ]] && ok "Tunnel already looks healthy. Repair not needed."
    return 0
  fi

  _tunnel_repair_snapshot || true

  local old_port="${WG_PORT}"
  if (( change_port == 1 )); then
    _tunnel_repair_change_port "$new_port" "$mode" || return 1
  fi

  step "Repair preflight and SSH guard"
  azhdar_firewall_safety_local || true
  ok "SSH guard is active on IR port ${IR_SSH_PORT:-22}."

  local remote_pre_stop=0
  if _tunnel_repair_remote_available; then
    remote_pre_stop=1
    step "Remove stale remote AZHDAR firewall state"
    _tunnel_repair_remove_remote_poison || true
    ok "Remote stale state cleaned (best-effort)."
  else
    warn "Remote SSH unavailable before local cleanup; will retry after local repair steps."
  fi

  # Rebuild remote config BEFORE stopping local WG/Mimic when possible. If SSH
  # management rides over the old WG tunnel, stopping local runtime first would
  # cut the only path to OUT and make repair impossible without rebuild.
  step "Rebuild WireGuard/Mimic configs from profile"
  _tunnel_repair_write_configs || true
  if (( change_port == 1 )); then
    # Both ends must use the same port. If OUT did not take the new one (SSH
    # dropped mid-write), go back to the old port rather than leave IR alone
    # on a port OUT does not listen on.
    local out_port; out_port="$(_tunnel_repair_remote_listen_port)"
    if [[ "$out_port" == "$WG_PORT" ]]; then
      ok "OUT config confirms ListenPort=${WG_PORT}."
    else
      warn "OUT config shows ListenPort=${out_port:-unknown}, expected ${WG_PORT}; going back to port ${old_port}."
      WG_PORT="$old_port"
      profile_save >/dev/null 2>&1 || true
      _tunnel_repair_log_msg "tunnel port change reverted to ${old_port} (OUT showed ${out_port:-unknown})"
      _tunnel_repair_write_configs || true
      change_port=0
    fi
  fi
  ok "Configs rebuilt (best-effort)."

  step "Stop local WG/Mimic runtime"
  _tunnel_repair_stop_local_runtime || true
  ok "Local runtime stopped."

  step "Remove stale local firewall/NAT/RST state"
  _tunnel_repair_remove_local_poison || true
  ok "Local stale state cleaned."

  if (( remote_pre_stop == 0 )) && _tunnel_repair_remote_available; then
    step "Remove stale remote AZHDAR firewall state (retry)"
    _tunnel_repair_remove_remote_poison || true
    ok "Remote stale state cleaned after local cleanup (best-effort)."
  fi

  step "Re-apply required firewall rules"
  _tunnel_repair_apply_firewall || true
  ok "Firewall rules re-applied (best-effort)."

  step "Restart tunnel services"
  _tunnel_repair_restart_services || true
  ok "Services restarted (best-effort)."

  status_cache_invalidate || true
  if _tunnel_repair_wait_connected 5 5; then
    PROFILE_ENABLED="1"
    profile_save >/dev/null 2>&1 || true
    _tunnel_repair_log_msg "success"
    ok "Tunnel repair succeeded."
    [[ "$mode" == "manual" ]] && { echo; connection_indicator || true; }
    return 0
  fi

  warn "Basic repair did not restore tunnel. Retrying service restart once more."
  _tunnel_repair_restart_services || true
  if _tunnel_repair_wait_connected 3 6; then
    PROFILE_ENABLED="1"
    profile_save >/dev/null 2>&1 || true
    _tunnel_repair_log_msg "success-after-retry"
    ok "Tunnel repair succeeded after retry."
    [[ "$mode" == "manual" ]] && { echo; connection_indicator || true; }
    return 0
  fi

  if [[ "$deep" == "1" || "$mode" == "manual" ]]; then
    if [[ "${TUN_IP_ASSIGN:-auto}" == "auto" ]] && _tunnel_repair_remote_available; then
      warn "Trying deep repair: limited tunnel IP auto-heal."
      if azhdar_autofix_tunnel_ips; then
        if _tunnel_repair_wait_connected 3 5; then
          _tunnel_repair_log_msg "success-deep-autofix"
          ok "Tunnel repair succeeded after deep auto-heal."
          [[ "$mode" == "manual" ]] && { echo; connection_indicator || true; }
          return 0
        fi
      fi
    fi
  fi

  _tunnel_repair_log_msg "failed"
  err "Tunnel repair finished but tunnel is still disconnected."
  local port_blocked=0
  azhdar_port_filter_probe && port_blocked=1 || true
  if [[ "$mode" == "manual" && -t 0 && "${WG_MODE:-classic}" != "account" ]] && (( change_port == 0 )) && _tunnel_repair_remote_available; then
    echo
    local def="N"
    (( port_blocked == 1 )) && def="Y"
    if [[ "$(prompt_yesno "Move the tunnel to another port (checked free on IR and OUT) and repair again?" "$def")" == "Y" ]]; then
      # Release the repair lock; the nested run takes it again.
      exec 9>&-
      if [[ "$deep" == "1" ]]; then
        azhdar_repair_tunnel --yes --deep --new-port
      else
        azhdar_repair_tunnel --yes --new-port
      fi
      return $?
    fi
  fi
  echo -e "${DIM}Log:${RST} $(_tunnel_repair_log)"
  [[ "$mode" == "manual" ]] && { echo; diagnostics_full || true; }
  return 1
}

_tunnel_watchdog_state_file(){
  mkdir -p "$(_tunnel_repair_state_dir)" >/dev/null 2>&1 || true
  echo "$(_tunnel_repair_state_dir)/watchdog-${PROFILE:-default}.env"
}

_tunnel_watchdog_save_state(){
  local f; f="$(_tunnel_watchdog_state_file)"
  {
    printf 'FAIL_COUNT=%s\n' "${FAIL_COUNT:-0}"
    printf 'LAST_REPAIR_TS=%s\n' "${LAST_REPAIR_TS:-0}"
    printf 'LAST_OK_TS=%s\n' "${LAST_OK_TS:-0}"
    printf 'REPAIR_FAIL_STREAK=%s\n' "${REPAIR_FAIL_STREAK:-0}"
    printf 'PORT_HOPS=%s\n' "${PORT_HOPS:-0}"
    printf 'PORTS_TRIED=%s\n' "${PORTS_TRIED:-}"
  } >"$f" 2>/dev/null || true
  chmod 600 "$f" 2>/dev/null || true
}

_tunnel_watchdog_load_state(){
  FAIL_COUNT="0"; LAST_REPAIR_TS="0"; LAST_OK_TS="0"; REPAIR_FAIL_STREAK="0"
  PORT_HOPS="0"; PORTS_TRIED=""
  local f; f="$(_tunnel_watchdog_state_file)"
  if [[ -f "$f" ]]; then
    local _opts; _opts="$(set +o)"
    set +e +u
    # shellcheck disable=SC1090
    source "$f" 2>/dev/null || true
    eval "${_opts}"
  fi
  [[ "${FAIL_COUNT:-0}" =~ ^[0-9]+$ ]] || FAIL_COUNT="0"
  [[ "${LAST_REPAIR_TS:-0}" =~ ^[0-9]+$ ]] || LAST_REPAIR_TS="0"
  [[ "${LAST_OK_TS:-0}" =~ ^[0-9]+$ ]] || LAST_OK_TS="0"
  [[ "${REPAIR_FAIL_STREAK:-0}" =~ ^[0-9]+$ ]] || REPAIR_FAIL_STREAK="0"
  [[ "${PORT_HOPS:-0}" =~ ^[0-9]+$ ]] || PORT_HOPS="0"
  [[ "${PORTS_TRIED:-}" =~ ^[0-9,]*$ ]] || PORTS_TRIED=""
}

_tunnel_watchdog_port_hop_due(){
  # usage: _tunnel_watchdog_port_hop_due <failed repairs in a row, this one included>
  # True when the profile allows automatic port changes, enough repairs in a
  # row have failed, and this outage has not used up its port changes yet.
  local streak="$1" after="${TUNNEL_AUTO_PORT_HOP_AFTER:-2}" max="${AZHDAR_PORT_HOP_MAX:-3}"
  [[ "${TUNNEL_AUTO_PORT_HOP:-0}" == "1" ]] || return 1
  [[ "${WG_MODE:-classic}" != "account" ]] || return 1
  [[ "$after" =~ ^[0-9]+$ ]] || after=2
  [[ "$max" =~ ^[0-9]+$ ]] || max=3
  (( after < 1 )) && after=1
  (( streak >= after && PORT_HOPS < max ))
}

_tunnel_watchdog_port_hop(){
  # Move the tunnel to a port that is free on IR and OUT and has not been
  # tried in this outage, then repair on it. PORTS_TRIED keeps the watchdog
  # from bouncing between two blocked ports; it is cleared once the tunnel is
  # healthy again. A hop only counts when the port really changed (OUT must be
  # reachable over SSH to check and write the new port on both ends).
  local from="${WG_PORT}" rc=0
  ports_csv_contains "${PORTS_TRIED:-}" "$from" || PORTS_TRIED="${PORTS_TRIED:+${PORTS_TRIED},}${from}"
  _tunnel_repair_log_msg "watchdog moving tunnel off port ${from} (hop $((PORT_HOPS + 1)), tried: ${PORTS_TRIED})"
  TUNNEL_PORT_EXCLUDE="${PORTS_TRIED}"
  exec 9>&-   # release the lock of the repair that just failed
  azhdar_repair_tunnel --auto --yes --new-port || rc=$?
  unset TUNNEL_PORT_EXCLUDE
  if [[ "${WG_PORT}" != "$from" ]]; then
    PORT_HOPS=$((PORT_HOPS + 1))
    _tunnel_repair_log_msg "watchdog tunnel port ${from} -> ${WG_PORT} (rc=${rc})"
  else
    _tunnel_repair_log_msg "watchdog port change not made; tunnel stays on ${from}"
  fi
  return "$rc"
}

_tunnel_watchdog_effective_cooldown(){
  # Back off after repairs that did not bring the tunnel back. When the path to
  # OUT is filtered, no local repair can fix it, and repeating a full repair
  # every cooldown restarts the shared mimic@<wan> (dropping sibling profiles
  # on the same WAN) and leaves a config/rules backup each time. The base
  # cooldown doubles per failed repair in a row, capped at 6 hours.
  local base="$1" streak="${REPAIR_FAIL_STREAK:-0}" cap=21600 eff
  (( streak > 6 )) && streak=6
  eff=$(( base << streak ))
  (( eff > cap )) && eff=$cap
  (( eff < base )) && eff=$base
  echo "$eff"
}

azhdar_tunnel_watchdog(){
  need_root
  ensure_dirs
  if ! _tunnel_repair_load_active_profile; then
    return 0
  fi
  defaults_profile
  [[ "${TUNNEL_AUTO_REPAIR:-0}" == "1" ]] || return 0
  [[ "${PROFILE_ENABLED:-0}" == "1" ]] || return 0

  _tunnel_watchdog_load_state
  local now threshold cooldown
  now="$(date +%s 2>/dev/null || echo 0)"
  threshold="${TUNNEL_AUTO_REPAIR_FAILS:-2}"
  cooldown="${TUNNEL_AUTO_REPAIR_COOLDOWN:-600}"
  [[ "$threshold" =~ ^[0-9]+$ ]] || threshold=2
  [[ "$cooldown" =~ ^[0-9]+$ ]] || cooldown=600
  (( threshold < 1 )) && threshold=1
  (( cooldown < 120 )) && cooldown=120

  if _tunnel_repair_health_quiet; then
    FAIL_COUNT="0"
    REPAIR_FAIL_STREAK="0"
    PORT_HOPS="0"
    PORTS_TRIED=""
    LAST_OK_TS="$now"
    _tunnel_watchdog_save_state
    _tunnel_repair_log_msg "watchdog healthy profile=${PROFILE}"
    return 0
  fi

  FAIL_COUNT=$((FAIL_COUNT + 1))
  _tunnel_repair_log_msg "watchdog unhealthy profile=${PROFILE} fail_count=${FAIL_COUNT}/${threshold}"
  if (( FAIL_COUNT < threshold )); then
    _tunnel_watchdog_save_state
    return 0
  fi

  cooldown="$(_tunnel_watchdog_effective_cooldown "$cooldown")"
  if (( now - LAST_REPAIR_TS < cooldown )); then
    _tunnel_repair_log_msg "watchdog cooldown active (${cooldown}s, failed repairs in a row=${REPAIR_FAIL_STREAK}); skipping repair"
    _tunnel_watchdog_save_state
    return 0
  fi

  LAST_REPAIR_TS="$now"
  _tunnel_watchdog_save_state
  # A failed repair that completes TUNNEL_AUTO_PORT_HOP_AFTER failures in a row
  # is followed straight away by a repair on a new port (when enabled), and so
  # is every later failed repair of the same outage, up to AZHDAR_PORT_HOP_MAX.
  if azhdar_repair_tunnel --auto --yes \
     || { _tunnel_watchdog_port_hop_due $((REPAIR_FAIL_STREAK + 1)) && _tunnel_watchdog_port_hop; }; then
    FAIL_COUNT="0"
    REPAIR_FAIL_STREAK="0"
    PORT_HOPS="0"
    PORTS_TRIED=""
    LAST_OK_TS="$(date +%s 2>/dev/null || echo 0)"
  else
    # Keep a small fail count so the next run can try again after cooldown.
    FAIL_COUNT="$threshold"
    REPAIR_FAIL_STREAK=$((REPAIR_FAIL_STREAK + 1))
  fi
  _tunnel_watchdog_save_state
  return 0
}

azhdar_tunnel_watchdog_enable(){
  ensure_profile_selected || return 1
  TUNNEL_AUTO_REPAIR="1"
  TUNNEL_AUTO_REPAIR_FAILS="${TUNNEL_AUTO_REPAIR_FAILS:-2}"
  TUNNEL_AUTO_REPAIR_COOLDOWN="${TUNNEL_AUTO_REPAIR_COOLDOWN:-600}"
  PROFILE_ENABLED="1"
  profile_save
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now azhdar-watchdog.timer >/dev/null 2>&1 || true
    ok "Auto repair watchdog enabled."
  else
    warn "systemd not found; watchdog timer cannot be enabled."
  fi
}

azhdar_tunnel_watchdog_disable(){
  ensure_profile_selected || return 1
  TUNNEL_AUTO_REPAIR="0"
  profile_save
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop azhdar-watchdog.timer >/dev/null 2>&1 || true
    systemctl disable azhdar-watchdog.timer >/dev/null 2>&1 || true
    ok "Auto repair watchdog disabled."
  fi
}

_tunnel_watchdog_port_hop_label(){
  if [[ "${TUNNEL_AUTO_PORT_HOP:-0}" == "1" ]]; then
    echo "on, after ${TUNNEL_AUTO_PORT_HOP_AFTER:-2} failed repairs in a row (max ${AZHDAR_PORT_HOP_MAX:-3} per outage)"
  else
    echo "off"
  fi
}

azhdar_tunnel_watchdog_port_hop_toggle(){
  ensure_profile_selected || return 1
  if [[ "${TUNNEL_AUTO_PORT_HOP:-0}" == "1" ]]; then
    TUNNEL_AUTO_PORT_HOP="0"
    profile_save
    ok "Watchdog will no longer change the tunnel port."
    return 0
  fi
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    err "Account-mode profiles take the port from the provider config; the watchdog cannot change it."
    return 1
  fi
  echo -e "${DIM}When a watchdog repair fails this many times in a row, the next step is a repair on a new tunnel port${RST}"
  echo -e "${DIM}that is free on IR and OUT (checked over SSH first). Clients are not affected; only the port between the servers changes.${RST}"
  local n=""
  while true; do
    read -rp "Failed repairs in a row before a port change [${TUNNEL_AUTO_PORT_HOP_AFTER:-2}]: " n || true
    n="${n:-${TUNNEL_AUTO_PORT_HOP_AFTER:-2}}"
    [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 20 )) && break
    warn "Enter a number from 1 to 20."
  done
  TUNNEL_AUTO_PORT_HOP="1"
  TUNNEL_AUTO_PORT_HOP_AFTER="$n"
  profile_save
  ok "Watchdog port change: $(_tunnel_watchdog_port_hop_label)."
  [[ "${TUNNEL_AUTO_REPAIR:-0}" == "1" ]] || warn "The auto repair watchdog itself is off; enable it with option 3."
}

azhdar_tunnel_watchdog_status(){
  local f
  f="$(_tunnel_watchdog_state_file)"
  echo -e "${DIM}Auto repair:${RST} ${TUNNEL_AUTO_REPAIR:-0}"
  echo -e "${DIM}Auto port change:${RST} $(_tunnel_watchdog_port_hop_label)"
  echo -e "${DIM}Timer:${RST} $(systemctl is-enabled azhdar-watchdog.timer 2>/dev/null || echo disabled) / $(systemctl is-active azhdar-watchdog.timer 2>/dev/null || echo inactive)"
  if [[ -f "$f" ]]; then
    echo -e "${DIM}State:${RST} ${f}"
    sed 's/^/  /' "$f" 2>/dev/null || true
  else
    echo -e "${DIM}State:${RST} <none yet>"
  fi
  echo -e "${DIM}Log:${RST} $(_tunnel_repair_log)"
}

menu_tunnel_repair(){
  ensure_profile_selected || return 0
  while true; do
    banner
    echo -e "${BOLD}${WHT}Tunnel repair / auto watchdog${RST}"
    hr
    echo -e "${DIM}Profile:${RST} ${PROFILE}"
    echo -e "${DIM}Auto repair:${RST} ${TUNNEL_AUTO_REPAIR:-0}  ${DIM}fails:${RST} ${TUNNEL_AUTO_REPAIR_FAILS:-2}  ${DIM}cooldown:${RST} ${TUNNEL_AUTO_REPAIR_COOLDOWN:-600}s"
    echo -e "${DIM}Auto port change:${RST} $(_tunnel_watchdog_port_hop_label)  ${DIM}tunnel port:${RST} ${WG_PORT:-?}"
    hr
    echo " 1) Repair tunnel now (safe/manual)"
    echo " 2) Deep repair now (includes limited tunnel-IP auto-heal)"
    echo " 3) Enable auto repair watchdog"
    echo " 4) Disable auto repair watchdog"
    echo " 5) Watchdog status/log path"
    echo " 6) Repair on a new tunnel port (port checked free on IR and OUT)"
    if [[ "${TUNNEL_AUTO_PORT_HOP:-0}" == "1" ]]; then
      echo " 7) Turn off automatic port change by the watchdog"
    else
      echo " 7) Let the watchdog change the tunnel port after failed repairs"
    fi
    echo " 0) Back"
    hr
    read -rp "Select: " c || true
    case "${c:-}" in
      1) azhdar_repair_tunnel --yes || true; pause ;;
      2) azhdar_repair_tunnel --yes --deep || true; pause ;;
      6) azhdar_repair_tunnel --yes --new-port || true; pause ;;
      7) azhdar_tunnel_watchdog_port_hop_toggle || true; pause ;;
      3) azhdar_tunnel_watchdog_enable || true; pause ;;
      4) azhdar_tunnel_watchdog_disable || true; pause ;;
      5) azhdar_tunnel_watchdog_status || true; pause ;;
      0) return 0 ;;
      *) warn "Invalid."; pause ;;
    esac
  done
}
