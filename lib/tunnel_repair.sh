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
  cp -a "${BASE_DIR}" "$dir/etc-azhdar" 2>/dev/null || true
  cp -a /etc/wireguard "$dir/etc-wireguard" 2>/dev/null || true
  cp -a /etc/mimic "$dir/etc-mimic" 2>/dev/null || true
  if have_cmd iptables-save; then iptables-save >"$dir/iptables-save.v4" 2>/dev/null || true; fi
  if have_cmd ip6tables-save; then ip6tables-save >"$dir/iptables-save.v6" 2>/dev/null || true; fi
  _tunnel_repair_log_msg "snapshot=${dir}"
  ok "Repair snapshot saved: ${dir}"
}

_tunnel_repair_stop_local_runtime(){
  local wan wgsvc
  wan="$(mimic_detect_local_if 2>/dev/null || detect_wan_if 2>/dev/null || true)"
  wgsvc="$(svc_wg)"
  if command -v systemctl >/dev/null 2>&1; then
    local svc
    while read -r svc; do
      [[ -n "$svc" ]] && systemctl stop "$svc" >/dev/null 2>&1 || true
    done < <(systemctl list-units --all 'mimic@*.service' --no-legend --plain 2>/dev/null | awk '{print $1}')
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
  if [[ "${WG_MODE:-classic}" != "account" ]] && _tunnel_repair_remote_available; then
    start_services_remote || true
    restart_services_remote || true
  fi
  start_services_local || true
  restart_services_local || true
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

  local mode="manual" assume_yes="0" deep="0" arg
  for arg in "$@"; do
    case "$arg" in
      --auto|--watchdog) mode="auto"; assume_yes="1" ;;
      --yes|-y) assume_yes="1" ;;
      --deep) deep="1" ;;
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

  _tunnel_repair_log_msg "start mode=${mode} profile=${PROFILE}"
  _tunnel_repair_validate_profile || return 1

  if _tunnel_repair_health_quiet; then
    _tunnel_repair_log_msg "already healthy"
    [[ "$mode" == "manual" ]] && ok "Tunnel already looks healthy. Repair not needed."
    return 0
  fi

  _tunnel_repair_snapshot || true

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
  azhdar_port_filter_probe || true
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
  } >"$f" 2>/dev/null || true
  chmod 600 "$f" 2>/dev/null || true
}

_tunnel_watchdog_load_state(){
  FAIL_COUNT="0"; LAST_REPAIR_TS="0"; LAST_OK_TS="0"
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

  if (( now - LAST_REPAIR_TS < cooldown )); then
    _tunnel_repair_log_msg "watchdog cooldown active; skipping repair"
    _tunnel_watchdog_save_state
    return 0
  fi

  LAST_REPAIR_TS="$now"
  _tunnel_watchdog_save_state
  if azhdar_repair_tunnel --auto --yes; then
    FAIL_COUNT="0"
    LAST_OK_TS="$(date +%s 2>/dev/null || echo 0)"
  else
    # Keep a small fail count so the next run can try again after cooldown.
    FAIL_COUNT="$threshold"
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

azhdar_tunnel_watchdog_status(){
  local f
  f="$(_tunnel_watchdog_state_file)"
  echo -e "${DIM}Auto repair:${RST} ${TUNNEL_AUTO_REPAIR:-0}"
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
    hr
    echo " 1) Repair tunnel now (safe/manual)"
    echo " 2) Deep repair now (includes limited tunnel-IP auto-heal)"
    echo " 3) Enable auto repair watchdog"
    echo " 4) Disable auto repair watchdog"
    echo " 5) Watchdog status/log path"
    echo " 0) Back"
    hr
    read -rp "Select: " c || true
    case "${c:-}" in
      1) azhdar_repair_tunnel --yes || true; pause ;;
      2) azhdar_repair_tunnel --yes --deep || true; pause ;;
      3) azhdar_tunnel_watchdog_enable || true; pause ;;
      4) azhdar_tunnel_watchdog_disable || true; pause ;;
      5) azhdar_tunnel_watchdog_status || true; pause ;;
      0) return 0 ;;
      *) warn "Invalid."; pause ;;
    esac
  done
}
