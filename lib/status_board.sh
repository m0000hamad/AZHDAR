# shellcheck shell=bash
wg_runtime_endpoint(){
  if ! have_cmd wg; then echo ""; return; fi
  if ! ip link show "$WG_IF" >/dev/null 2>&1; then echo ""; return; fi
  wg show "$WG_IF" endpoints 2>/dev/null | awk 'NR==1{print $2}' || true
}

wg_transfer_stats(){
  if ! have_cmd wg; then echo "0 0"; return; fi
  if ! ip link show "$WG_IF" >/dev/null 2>&1; then echo "0 0"; return; fi
  wg show "$WG_IF" transfer 2>/dev/null | awk 'NR==1{print $2" "$3}' || echo "0 0"
}

wg_handshake_state(){
  local hs="$1"
  [[ -n "$hs" && "$hs" != "0" ]] || { echo "no-handshake"; return; }
  local now; now="$(date +%s 2>/dev/null || echo 0)"
  local age=$(( now - hs ))
  if (( age <= 180 )); then
    echo "recent"
  else
    echo "stale"
  fi
}

# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Status board (menus) --------------------
STATUS_CACHE_TS=0
STATUS_CACHE_TEXT=""
STATUS_CACHE_TTL=6

status_cache_invalidate(){
  STATUS_CACHE_TS=0
  STATUS_CACHE_TEXT=""
}

ui_box_top(){
  local title="$1"
  echo -e "${DIM}┌─ ${BOLD}${title}${RST} ${DIM}────────────────────────────────────────────────${RST}"
}

ui_box_row(){
  local label="$1"; shift
  local value="$*"
  echo -e "${DIM}│${RST} ${BOLD}${label}:${RST} ${value}"
}

ui_box_bottom(){
  echo -e "${DIM}└────────────────────────────────────────────────────────────${RST}"
}

tiny_mark(){
  local okflag="${1:-0}"
  local degrade="${2:-0}"
  if [[ "$okflag" == "1" ]]; then
    printf "%b" "${GRN}✓${RST}"
    return 0
  fi
  if [[ "$degrade" == "1" ]]; then
    # Degraded: something else is providing connectivity, so show orange instead of red.
    printf "%b" "${YLW}~${RST}"
    return 0
  fi
  printf "%b" "${RED}✗${RST}"
}

iface_addrs_local(){
  local ifc="$1"
  ip -br address show dev "$ifc" 2>/dev/null | sed -E 's/^[^ ]+ +[^ ]+ +//' | tr -d '\r' || true
}

iface_addrs_remote(){
  local ifc="$1"
  ssh_run "ip -br address show dev ${ifc} 2>/dev/null | sed -E 's/^[^ ]+ +[^ ]+ +//'" 2>/dev/null | tr -d '\r' | tail -n1 || true
}

remote_detect_wan_if_quiet(){
  # Determine remote WAN interface name (best-effort) without awk quoting issues.
  ssh_run "ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p' | head -n1 || true; \
ip -4 route show default 2>/dev/null | sed -n 's/^default.* dev \\([^ ]*\\).*/\\1/p' | head -n1 || true; \
ip -br link 2>/dev/null | grep -v '^lo ' | sed -n 's/^\\([^ ]*\\) .*UP.*/\\1/p' | head -n1 || true" \
    2>/dev/null | tr -d '\r' | awk 'NF{print $1; exit}' || true
}

ping_summarize_err(){
  # Extract a short, useful error line from ping output.
  # Usage: ping_summarize_err "<output>"
  local out="${1:-}"
  out="$(printf "%s" "$out" | tr -d '
')"
  local line=""
  line="$(printf "%s
" "$out" | grep -E '(^ping:|bind:|connect:|unreachable|unknown host|Name or service not known|Network is unreachable|Packet filtered|Operation not permitted|Permission denied|100% packet loss|Destination Host Unreachable|No route to host|Invalid argument)' | head -n1 || true)"
  [[ -z "$line" ]] && line="$(printf "%s
" "$out" | tail -n1)"
  printf "%s" "$line"
}

ping4_local_cmd(){
  local dst="$1"
  local src="${IR_WG_IP:-}"
  # IMPORTANT:
  # - Some kernels/routes reject ping -I <source-ip> while a normal routed ping works.
  # - Health must reflect real connectivity, not just the source-bound probe.
  # Try source-bound first, then fall back to the exact manual test users run: ping <peer>.
  if [[ -n "$src" ]] && is_ipv4 "$src"; then
    ping -c1 -W1 -I "$src" "$dst" || ping -c1 -W1 "$dst"
  else
    ping -c1 -W1 "$dst"
  fi
}

ping6_local_cmd(){
  local dst="$1"
  local src="${IR_WG_IP6:-}"
  if [[ -n "$src" ]] && is_ipv6 "$src"; then
    ping -6 -c1 -W1 -I "$src" "$dst" 2>/dev/null || ping6 -c1 -W1 -I "$src" "$dst" 2>/dev/null || ping -6 -c1 -W1 "$dst" 2>/dev/null || ping6 -c1 -W1 "$dst"
  else
    ping -6 -c1 -W1 "$dst" 2>/dev/null || ping6 -c1 -W1 "$dst"
  fi
}

ping4_local_once(){
  local dst="$1"
  ping4_local_cmd "$dst" >/dev/null 2>&1
}

ping6_local_once(){
  local dst="$1"
  ping6_local_cmd "$dst" >/dev/null 2>&1
}

ping4_remote_cmd(){
  local dst="$1"
  local src="${OUT_WG_IP:-}"
  if [[ -n "$src" ]] && is_ipv4 "$src"; then
    ssh_run "ping -c1 -W1 -I '${src}' '${dst}' || ping -c1 -W1 '${dst}'"
  else
    ssh_run "ping -c1 -W1 '${dst}'"
  fi
}

ping6_remote_cmd(){
  local dst="$1"
  local src="${OUT_WG_IP6:-}"
  if [[ -n "$src" ]] && is_ipv6 "$src"; then
    ssh_run "(ping -6 -c1 -W1 -I '${src}' '${dst}' 2>/dev/null) || (ping6 -c1 -W1 -I '${src}' '${dst}' 2>/dev/null) || (ping -6 -c1 -W1 '${dst}' 2>/dev/null) || (ping6 -c1 -W1 '${dst}')"
  else
    ssh_run "(ping -6 -c1 -W1 '${dst}' 2>/dev/null) || (ping6 -c1 -W1 '${dst}')"
  fi
}

ping4_remote_once(){
  local dst="$1"
  ping4_remote_cmd "$dst" >/dev/null 2>&1
}

ping6_remote_once(){
  local dst="$1"
  ping6_remote_cmd "$dst" >/dev/null 2>&1
}

ping4_local_diag(){
  local dst="$1"
  local out=""
  if out="$(ping4_local_cmd "$dst" 2>&1)"; then
    echo "ok"
    return 0
  fi
  ping_summarize_err "$out"
  return 1
}

ping6_local_diag(){
  local dst="$1"
  local out=""
  if out="$(ping6_local_cmd "$dst" 2>&1)"; then
    echo "ok"
    return 0
  fi
  ping_summarize_err "$out"
  return 1
}

ping4_remote_diag(){
  local dst="$1"
  local out=""
  if out="$(ping4_remote_cmd "$dst" 2>&1)"; then
    echo "ok"
    return 0
  fi
  ping_summarize_err "$out"
  return 1
}

ping6_remote_diag(){
  local dst="$1"
  local out=""
  if out="$(ping6_remote_cmd "$dst" 2>&1)"; then
    echo "ok"
    return 0
  fi
  ping_summarize_err "$out"
  return 1
}

# MTU auto-discovery helpers (best-effort)
# We search for the highest MTU that works in BOTH directions and (if enabled) BOTH IP families.
MTU_AUTODETECT_BEST=""

azhdar_ping_ok_quiet(){
  # Returns 0 if ANY tunnel ping works (either direction, IPv4 or IPv6).
  local ssh_ok=0
  if [[ -n "${OUT_SSH_HOST:-}" ]] && ssh_run "echo OK" >/dev/null 2>&1; then
    ssh_ok=1
  fi

  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" ]]; then
    [[ -n "${OUT_WG_IP:-}" ]] && ping4_local_once "${OUT_WG_IP}" && return 0 || true
    if (( ssh_ok == 1 )); then
      [[ -n "${IR_WG_IP:-}" ]] && ping4_remote_once "${IR_WG_IP}" && return 0 || true
    fi
  fi

  if [[ "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then
    [[ -n "${OUT_WG_IP6:-}" ]] && ping6_local_once "${OUT_WG_IP6}" && return 0 || true
    if (( ssh_ok == 1 )); then
      [[ -n "${IR_WG_IP6:-}" ]] && ping6_remote_once "${IR_WG_IP6}" && return 0 || true
    fi
  fi

  return 1
}

azhdar_autofix_tunnel_ips(){
  step "Auto-heal: limited tunnel IP retries (fast)"

  if ! ssh_check_quiet; then
    warn "SSH unavailable; cannot auto-heal remote tunnel config."
    return 1
  fi

  # Save original tunnel settings (so we can roll back cleanly).
  local orig_v4="${ENABLE_TUN_IPV4:-1}"
  local orig_v6="${ENABLE_TUN_IPV6:-0}"
  local orig_subnet="${TUN_SUBNET:-10.66.66.0/24}"
  local orig_ir="${IR_WG_IP:-10.66.66.1}"
  local orig_out="${OUT_WG_IP:-10.66.66.2}"
  local orig_subnet6="${TUN_SUBNET6:-fd00:66::/64}"
  local orig_ir6="${IR_WG_IP6:-fd00:66::1}"
  local orig_out6="${OUT_WG_IP6:-fd00:66::2}"

  # Per request: only try 2 IPv4 ranges, then 1 short IPv6 range.
  local -a v4_subnets=("10.66.66.0/24" "10.77.77.0/24")
  local s

  for s in "${v4_subnets[@]}"; do
    if subnet_overlaps_local "$s" || subnet_overlaps_remote "$s"; then
      warn "Candidate IPv4 subnet ${s} overlaps existing routes (local/remote); skipping."
      continue
    fi
    info "Trying IPv4 tunnel subnet: ${s} ..."
    ENABLE_TUN_IPV4="1"
    ENABLE_TUN_IPV6="0"
    set_subnet_vars "${s}"
    profile_save
    apply_wg_configs_best_effort || true
    echo -e "Waiting 6s for handshake..."
    sleep 6
    if azhdar_ping_ok_quiet; then
      ok "Auto-heal succeeded with IPv4 subnet ${s}."
      return 0
    fi
  done

  # IPv6 try (short ULA), only if IPv6 isn't disabled on both hosts.
  local ipv6_local_disable ipv6_remote_disable
  ipv6_local_disable="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)"
  ipv6_remote_disable="$(ssh_run "cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0" 2>/dev/null | tr -d '\r' | tail -n1 || true)"
  ipv6_remote_disable="${ipv6_remote_disable:-0}"

  if [[ "${ipv6_local_disable}" != "1" && "${ipv6_remote_disable}" != "1" ]]; then
    local s6="fd00:66::/64"
    if subnet6_overlaps_local "$s6" || subnet6_overlaps_remote "$s6"; then
      warn "Candidate IPv6 subnet ${s6} overlaps existing IPv6 routes (local/remote); skipping."
    else
      info "Trying IPv6-only short tunnel subnet: ${s6} ..."
      ENABLE_TUN_IPV4="0"
      ENABLE_TUN_IPV6="1"
      set_subnet6_vars "${s6}"
      profile_save
      apply_wg_configs_best_effort || true
      echo -e "Waiting 6s for handshake..."
      sleep 6
      if azhdar_ping_ok_quiet; then
        ok "Auto-heal succeeded with IPv6-only tunnel."
        return 0
      fi
    fi
  else
    warn "IPv6 appears disabled on local or remote; skipping IPv6 auto-heal try."
  fi

  warn "Auto-heal failed after limited retries. Restoring original tunnel settings (best-effort)..."
  ENABLE_TUN_IPV4="$orig_v4"
  ENABLE_TUN_IPV6="$orig_v6"
  TUN_SUBNET="$orig_subnet"
  IR_WG_IP="$orig_ir"
  OUT_WG_IP="$orig_out"
  TUN_SUBNET6="$orig_subnet6"
  IR_WG_IP6="$orig_ir6"
  OUT_WG_IP6="$orig_out6"
  profile_save
  apply_wg_configs_best_effort || true
  return 1
}




mtu_auto_min(){
  local v="${MTU_AUTO_MIN:-1272}"
  [[ "$v" =~ ^[0-9]+$ ]] || v="1272"
  (( v < 1272 )) && v=1272
  (( v > 1500 )) && v=1272
  echo "$v"
}

mtu_auto_max(){
  local v="${MTU_AUTO_MAX:-1500}"
  [[ "$v" =~ ^[0-9]+$ ]] || v="1500"
  (( v < 1272 )) && v=1500
  (( v > 1500 )) && v=1500
  echo "$v"
}

mtu_auto_margin(){
  # Safety margin below the highest passing probe. It avoids applying the exact
  # cliff-edge value that often passes ICMP once but breaks real traffic.
  local v="${MTU_AUTO_MARGIN:-16}"
  [[ "$v" =~ ^[0-9]+$ ]] || v="16"
  (( v > 80 )) && v=80
  echo "$v"
}

ping4_df_local_payload(){
  local dst="$1" payload="$2" src="${IR_WG_IP:-}" ok=0 i
  for i in 1 2 3; do
    if [[ -n "$src" ]] && is_ipv4 "$src"; then
      ping -4 -I "$src" -c1 -W1 -M do -s "$payload" "$dst" >/dev/null 2>&1 && ok=$((ok+1)) || true
    else
      ping -4 -I "${WG_IF}" -c1 -W1 -M do -s "$payload" "$dst" >/dev/null 2>&1 && ok=$((ok+1)) || true
    fi
  done
  (( ok >= 2 ))
}

ping6_df_local_payload(){
  local dst="$1" payload="$2" src="${IR_WG_IP6:-}" ok=0 i
  for i in 1 2 3; do
    if [[ -n "$src" ]] && is_ipv6 "$src"; then
      (ping -6 -I "$src" -c1 -W1 -M do -s "$payload" "$dst" >/dev/null 2>&1 || ping6 -I "$src" -c1 -W1 -M do -s "$payload" "$dst" >/dev/null 2>&1) && ok=$((ok+1)) || true
    else
      (ping -6 -I "${WG_IF}" -c1 -W1 -M do -s "$payload" "$dst" >/dev/null 2>&1 || ping6 -I "${WG_IF}" -c1 -W1 -M do -s "$payload" "$dst" >/dev/null 2>&1) && ok=$((ok+1)) || true
    fi
  done
  (( ok >= 2 ))
}

ping4_df_remote_payload(){
  local dst="$1" payload="$2" src="${OUT_WG_IP:-}" ok=0 i qsrc qdst
  qdst="$(printf '%q' "$dst")"
  qsrc="$(printf '%q' "$src")"
  for i in 1 2 3; do
    if [[ -n "$src" && "$src" != "peer" ]]; then
      ssh_run "ping -4 -I ${qsrc} -c1 -W1 -M do -s ${payload} ${qdst} >/dev/null 2>&1" >/dev/null 2>&1 && ok=$((ok+1)) || true
    else
      ssh_run "ping -4 -I ${WG_IF} -c1 -W1 -M do -s ${payload} ${qdst} >/dev/null 2>&1" >/dev/null 2>&1 && ok=$((ok+1)) || true
    fi
  done
  (( ok >= 2 ))
}

ping6_df_remote_payload(){
  local dst="$1" payload="$2" src="${OUT_WG_IP6:-}" ok=0 i qsrc qdst
  qdst="$(printf '%q' "$dst")"
  qsrc="$(printf '%q' "$src")"
  for i in 1 2 3; do
    if [[ -n "$src" && "$src" != "peer" ]]; then
      ssh_run "(ping -6 -I ${qsrc} -c1 -W1 -M do -s ${payload} ${qdst} >/dev/null 2>&1) || (ping6 -I ${qsrc} -c1 -W1 -M do -s ${payload} ${qdst} >/dev/null 2>&1)" >/dev/null 2>&1 && ok=$((ok+1)) || true
    else
      ssh_run "(ping -6 -I ${WG_IF} -c1 -W1 -M do -s ${payload} ${qdst} >/dev/null 2>&1) || (ping6 -I ${WG_IF} -c1 -W1 -M do -s ${payload} ${qdst} >/dev/null 2>&1)" >/dev/null 2>&1 && ok=$((ok+1)) || true
    fi
  done
  (( ok >= 2 ))
}

mtu_set_runtime_local(){
  local mtu="$1"
  ip link set dev "${WG_IF}" mtu "${mtu}" >/dev/null 2>&1 || true
}

mtu_set_runtime_remote(){
  local mtu="$1"
  [[ -n "${OUT_SSH_HOST:-}" ]] || return 1
  ssh_run "${REMOTE_SUDO:-} ip link set dev ${WG_IF} mtu ${mtu} >/dev/null 2>&1" >/dev/null 2>&1 || return 1
  return 0
}

mtu_probe_candidate(){
  # Apply a candidate MTU live, then test real tunnel traffic with DF set.
  # Returns 0 only when every checked direction/family is stable (2/3 probes pass).
  local mtu="$1" ssh_ok="${2:-0}" checked=0 failed=0 payload=0
  [[ "$mtu" =~ ^[0-9]+$ ]] || return 1

  mtu_set_runtime_local "$mtu"
  if (( ssh_ok == 1 )); then
    mtu_set_runtime_remote "$mtu" || true
  fi
  sleep 0.25 2>/dev/null || true

  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && -n "${OUT_WG_IP:-}" && "${OUT_WG_IP}" != "peer" ]]; then
    payload=$((mtu - 28))
    if (( payload > 0 )); then
      checked=$((checked+1))
      ping4_df_local_payload "${OUT_WG_IP}" "$payload" || failed=1
      if (( ssh_ok == 1 )) && [[ -n "${IR_WG_IP:-}" ]]; then
        checked=$((checked+1))
        ping4_df_remote_payload "${IR_WG_IP}" "$payload" || failed=1
      fi
    fi
  fi

  if [[ "${ENABLE_TUN_IPV6:-0}" == "1" && -n "${OUT_WG_IP6:-}" && "${OUT_WG_IP6}" != "peer" ]]; then
    payload=$((mtu - 48))
    if (( payload > 0 )); then
      checked=$((checked+1))
      ping6_df_local_payload "${OUT_WG_IP6}" "$payload" || failed=1
      if (( ssh_ok == 1 )) && [[ -n "${IR_WG_IP6:-}" ]]; then
        checked=$((checked+1))
        ping6_df_remote_payload "${IR_WG_IP6}" "$payload" || failed=1
      fi
    fi
  fi

  (( checked > 0 && failed == 0 ))
}

mtu_autodetect_common(){
  MTU_AUTODETECT_BEST=""

  local min max margin ssh_ok=0 low high mid best=0 stable=0
  min="$(mtu_auto_min)"
  max="$(mtu_auto_max)"
  margin="$(mtu_auto_margin)"
  (( max < min )) && max=1500

  [[ -n "${OUT_SSH_HOST:-}" ]] && ssh_check_quiet >/dev/null 2>&1 && ssh_ok=1 || true

  echo
  echo -e "${BOLD}${WHT}MTU auto-discovery${RST}"
  echo -e "${DIM}Real tunnel probe: applies candidate MTU live, tests DF ping 3 times, and chooses a stable value.${RST}"
  echo -e "${DIM}Range:${RST} ${min}..${max}   ${DIM}margin:${RST} ${margin}   ${DIM}OUT→IR check:${RST} $([[ $ssh_ok == 1 ]] && echo yes || echo skipped-no-ssh)"

  if ! mtu_probe_candidate "$min" "$ssh_ok"; then
    warn "Minimum MTU=${min} did not fully pass tunnel probes. Will use minimum anyway; not going lower by policy."
    MTU_AUTODETECT_BEST="$min"
    return 0
  fi

  low="$min"
  high="$max"
  best="$min"
  while (( low <= high )); do
    mid=$(((low + high) / 2))
    printf "  probe MTU=%s ... " "$mid"
    if mtu_probe_candidate "$mid" "$ssh_ok"; then
      echo "OK"
      best="$mid"
      low=$((mid + 1))
    else
      echo "fail"
      high=$((mid - 1))
    fi
  done

  stable=$((best - margin))
  (( stable < min )) && stable="$min"
  (( stable > max )) && stable="$max"

  echo -e "${DIM}Highest passing MTU:${RST} ${best}"
  echo -e "${DIM}Stable MTU after margin:${RST} ${stable}"

  if ! mtu_probe_candidate "$stable" "$ssh_ok"; then
    warn "Stable MTU=${stable} did not confirm on final probe; falling back to minimum MTU=${min}."
    stable="$min"
    mtu_probe_candidate "$stable" "$ssh_ok" || true
  fi

  MTU_AUTODETECT_BEST="$stable"
  ok "Best stable common MTU: ${MTU_AUTODETECT_BEST}"
  return 0
}

mtu_autofind_and_apply(){
  step "Auto-find MTU (real tunnel probe)"

  local old_mtu="${MTU:-1272}"
  local old_mode="${MTU_MODE:-manual}"
  local min="$(mtu_auto_min)"

  _mtu_apply_minimum(){
    local reason="$1"
    warn "${reason} Applying safe minimum MTU=${min}; AZHDAR will not go below ${min}."
    MTU_MODE="auto"
    MTU="$min"
    profile_save 2>/dev/null || true
    apply_wg_configs_mtu_safe || warn "Minimum MTU was saved, but live apply/health was not fully confirmed."
    return 0
  }

  # Auto MTU must be based on the actual tunnel. Do not derive a fake constant
  # from public-path PMTU; that was the source of repeated wrong values such as 1383.
  if ! azhdar_ping_ok_quiet; then
    _mtu_apply_minimum "AZHDAR tunnel is disconnected; real MTU probing is unavailable."
    return 0
  fi

  if ! mtu_autodetect_common; then
    warn "MTU auto-discovery failed; restoring previous MTU=${old_mtu}."
    MTU_MODE="$old_mode"
    MTU="$old_mtu"
    profile_save 2>/dev/null || true
    mtu_set_runtime_local "$old_mtu"
    mtu_set_runtime_remote "$old_mtu" || true
    return 0
  fi

  MTU_MODE="auto"
  MTU="${MTU_AUTODETECT_BEST}"
  (( MTU < min )) && MTU="$min"
  profile_save 2>/dev/null || true

  echo
  step "Applying MTU=${MTU} on BOTH servers"
  if apply_wg_configs_mtu_safe; then
    ok "MTU applied: ${MTU} (auto, real probe)"
  else
    warn "MTU=${MTU} was not fully healthy after apply. Falling back to minimum MTU=${min}."
    if [[ "$MTU" != "$min" ]]; then
      MTU="$min"
      MTU_MODE="auto"
      profile_save 2>/dev/null || true
      apply_wg_configs_mtu_safe || warn "Fallback MTU=${min} also was not fully confirmed."
    fi
  fi
  return 0
}

profile_status_board(){
  [[ -n "${PROFILE:-}" ]] || return 0

  local now; now="$(date +%s 2>/dev/null || echo 0)"
  if [[ "${STATUS_CACHE_TS:-0}" =~ ^[0-9]+$ ]] && (( now - STATUS_CACHE_TS < STATUS_CACHE_TTL )) && [[ -n "${STATUS_CACHE_TEXT:-}" ]]; then
    printf "%b" "${STATUS_CACHE_TEXT}"
    return 0
  fi

  local wan; wan="$(detect_wan_if)"
  local wgsvc; wgsvc="$(svc_wg)"
  local mimicsvc="mimic@${wan}"

  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    local wg_svc_active=0 wg_link_up=0 wg_ok=0 az_ok=0
    systemctl is-active --quiet "${wgsvc}" 2>/dev/null && wg_svc_active=1 || true
    ip link show "${WG_IF}" >/dev/null 2>&1 && wg_link_up=1 || true
    local hs; hs="$(wg_handshake_epoch)"
    local wg_hs_recent=0
    if [[ -n "$hs" && "$hs" != "0" ]]; then
      local now_hs; now_hs="$(date +%s 2>/dev/null || echo 0)"
      (( now_hs - hs <= 180 )) && wg_hs_recent=1 || true
    fi
    local runtime_ep txrx txb rxb hs_state
    runtime_ep="$(wg_runtime_endpoint)"
    txrx="$(wg_transfer_stats)"; txb="${txrx%% *}"; rxb="${txrx##* }"
    hs_state="$(wg_handshake_state "$hs")"
    local has_runtime=0
    [[ -n "$runtime_ep" && "$runtime_ep" != "(none)" ]] && has_runtime=1 || true
    [[ "${rxb:-0}" != "0" || "${txb:-0}" != "0" ]] && has_runtime=1 || true
    local p4=0 p6=0
    if (( wg_link_up == 1 )); then
      if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && -n "${OUT_WG_IP:-}" && "${OUT_WG_IP}" != "peer" ]]; then ping4_local_once "${OUT_WG_IP}" && p4=1 || true; fi
      if [[ "${ENABLE_TUN_IPV6:-0}" == "1" && -n "${OUT_WG_IP6:-}" && "${OUT_WG_IP6}" != "peer" ]]; then ping6_local_once "${OUT_WG_IP6}" && p6=1 || true; fi
    fi
    (( (wg_link_up == 1 || wg_svc_active == 1 || has_runtime == 1) && (wg_hs_recent == 1 || p4 == 1 || p6 == 1) )) && wg_ok=1 || wg_ok=0
    (( wg_ok == 1 )) && az_ok=1 || true
    local endpoint="${WG_ACCOUNT_ENDPOINT:-${OUT_PUBLIC_IP}:${WG_PORT}}"
    local local_addrs; local_addrs="$(iface_addrs_local "${WG_IF}")"; [[ -n "$local_addrs" ]] || local_addrs="<none>"
    local svc_state="down"
    if (( wg_svc_active == 1 )); then
      svc_state="up"
    elif (( wg_link_up == 1 || has_runtime == 1 )); then
      svc_state="runtime-up"
    fi
    local tunnel_state="DISCONNECTED"
    (( wg_ok == 1 )) && tunnel_state="CONNECTED" || true
    local out=""
    out+="$(status_badge "$wg_ok" "WG(local)")   $(status_badge "$az_ok" "AZHDAR" 0 "acct")\n"
    out+="${BOLD}${WHT}Tunnel:${RST} ${tunnel_state}\n"
    out+="${DIM}Mode:${RST} WireGuard account import (no remote setup)\n"
    out+="${DIM}WG state:${RST} service=${svc_state}  handshake=${hs_state}\n"
    [[ -n "$hs" && "$hs" != "0" ]] && out+="${DIM}WG handshake (wg show):${RST} $(human_ago "$hs")\n"
    out+="${DIM}WG config:${RST} Endpoint=${endpoint}\n"
    [[ -n "$runtime_ep" && "$runtime_ep" != "(none)" ]] && out+="${DIM}WG runtime endpoint:${RST} ${runtime_ep}\n"
    out+="${DIM}WG transfer:${RST} rx=${rxb:-0}  tx=${txb:-0}\n"
    if [[ "$hs_state" == "no-handshake" && "$svc_state" != "down" ]]; then
      out+="${DIM}Note:${RST} interface/runtime detected, but no successful handshake yet.\n"
    fi
    [[ -n "${WG_ACCOUNT_ALLOWEDIPS:-}" ]] && out+="${DIM}AllowedIPs:${RST} ${WG_ACCOUNT_ALLOWEDIPS}\n"
    out+="${DIM}WG iface (local):${RST} ${local_addrs}\n"
    if [[ "${OUT_WG_IP:-}" == "peer" || "${OUT_WG_IP6:-}" == "peer" ]]; then
      out+="${DIM}Peer ping:${RST} skipped (peer tunnel IP not present in imported account config)\n"
    fi
    STATUS_CACHE_TEXT="$out"
    STATUS_CACHE_TS="$now"
    printf "%b" "$out"
    return 0
  fi

  local ssh_ok=0 wg_svc_active=0 wg_link_up=0 wg_ok=0 mimic_ok=0
  if [[ -n "${OUT_SSH_HOST:-}" ]] && ssh_run "echo OK" >/dev/null 2>&1; then ssh_ok=1; fi
  systemctl is-active --quiet "${wgsvc}" 2>/dev/null && wg_svc_active=1 || true
  ip link show dev "${WG_IF}" >/dev/null 2>&1 && wg_link_up=1 || true
  if systemctl is-active --quiet "${mimicsvc}" 2>/dev/null; then
    mimic_profile_present_local "${PROFILE}" && mimic_ok=1 || mimic_ok=0
  fi

  # WG handshake age (used for connectivity, not just info)
  local hs; hs="$(wg_handshake_epoch)"
  local wg_hs_recent=0
  if [[ -n "$hs" && "$hs" != "0" ]]; then
    local now_hs; now_hs="$(date +%s 2>/dev/null || echo 0)"
    # Consider WG "connected" if last handshake is within 180s
    (( now_hs - hs <= 180 )) && wg_hs_recent=1 || true
  fi

  local remote_wg_svc_active=0 remote_wg_ok=0 remote_mimic_ok=0
  local remote_wan="${REMOTE_WAN_IF:-}"
  local remote_addrs="<ssh unavailable>"
  if (( ssh_ok == 1 )); then
    remote_addrs="$(iface_addrs_remote "${WG_IF}")"
    [[ -n "$remote_addrs" ]] || remote_addrs="<none>"
    ssh_run "systemctl is-active --quiet wg-quick@${WG_IF}" >/dev/null 2>&1 && remote_wg_svc_active=1 || true

    if [[ -z "$remote_wan" ]]; then
      remote_wan="$(remote_detect_wan_if_quiet)"
    fi
    if [[ -n "$remote_wan" ]]; then
      if ssh_run "systemctl is-active --quiet mimic@${remote_wan}" >/dev/null 2>&1; then
        REMOTE_WAN_IF="$remote_wan"
        mimic_profile_present_remote "${PROFILE}" && remote_mimic_ok=1 || remote_mimic_ok=0
      fi
    fi
  fi

  # Local iface runtime details
  local local_addrs; local_addrs="$(iface_addrs_local "${WG_IF}")"
  [[ -n "$local_addrs" ]] || local_addrs="<none>"

  local endpoint; endpoint="$(format_ipport "${OUT_PUBLIC_IP}" "${WG_PORT}")"
  local prefix4="${TUN_SUBNET##*/}"
  local prefix6="${TUN_SUBNET6##*/}"
  local listen_rt=""; listen_rt="$(wg show "${WG_IF}" listen-port 2>/dev/null | tr -d '
' | tail -n1 || true)"
  [[ "${listen_rt}" == "0" ]] && listen_rt=""

  # Ping indicators (WG IPs)
  local p4=0 p6=0 rp4=0 rp6=0
  if (( wg_svc_active == 1 || wg_link_up == 1 )); then
    if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && -n "${OUT_WG_IP:-}" ]]; then
      ping4_local_once "${OUT_WG_IP}" && p4=1 || true
    fi
    if [[ "${ENABLE_TUN_IPV6:-0}" == "1" && -n "${OUT_WG_IP6:-}" ]]; then
      ping6_local_once "${OUT_WG_IP6}" && p6=1 || true
    fi
  fi
  if (( ssh_ok == 1 )); then
    if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && -n "${IR_WG_IP:-}" ]]; then
      ping4_remote_once "${IR_WG_IP}" && rp4=1 || true
    fi
    if [[ "${ENABLE_TUN_IPV6:-0}" == "1" && -n "${IR_WG_IP6:-}" ]]; then
      ping6_remote_once "${IR_WG_IP6}" && rp6=1 || true
    fi
  fi

  local az_ok=0
  (( p4 == 1 || p6 == 1 || rp4 == 1 || rp6 == 1 )) && az_ok=1 || true

  # Determine WG connectivity more accurately than just systemd status.
  # If service is active but there is no recent handshake and no ping success, WG is treated as "down".
  (( (wg_svc_active == 1 || wg_link_up == 1) && ( wg_hs_recent == 1 || p4 == 1 || p6 == 1 || rp4 == 1 || rp6 == 1 ) )) && wg_ok=1 || wg_ok=0

  # Remote WG connectivity (best-effort): require service active and recent handshake.
  if (( ssh_ok == 1 && remote_wg_svc_active == 1 )); then
    local rhs rnow
    rhs="$(ssh_run "wg show ${WG_IF} latest-handshakes 2>/dev/null | awk 'NR==1{print \$2}'" 2>/dev/null || echo 0)"
    rnow="$(date +%s 2>/dev/null || echo 0)"
    if [[ -n "$rhs" && "$rhs" != "0" ]]; then
      (( rnow - rhs <= 180 )) && remote_wg_ok=1 || remote_wg_ok=0
    else
      remote_wg_ok=0
    fi
  fi

  # Local SSH fallback state (if enabled)
  local sshfb_active=0
  if command -v systemctl >/dev/null 2>&1; then
    local sshfb_svc
    sshfb_svc="$(ssh_fallback_service_name 2>/dev/null || true)"
    if [[ -n "$sshfb_svc" ]]; then
      systemctl is-active --quiet "$sshfb_svc" 2>/dev/null && sshfb_active=1 || true
    fi
  fi

  # If SSH fallback is up, show disconnected indicators as degraded (orange) instead of red.
  local degrade=0
  (( sshfb_active == 1 )) && degrade=1 || true

  # Treat SSH fallback as AZHDAR-connected for the main badge.
  (( sshfb_active == 1 )) && az_ok=1 || true

  # AZHDAR tag (wg/ssh) when connected
  local az_tag=""
  if (( az_ok == 1 )); then
    if (( sshfb_active == 1 && wg_ok == 0 )); then
      az_tag="ssh"
    elif (( wg_ok == 1 )); then
      az_tag="wg"
    elif (( sshfb_active == 1 )); then
      az_tag="ssh"
    fi
  fi

  local out=""
  out+="$(status_badge "$ssh_ok" "SSH")   $(status_badge "$mimic_ok" "Mimic(local)" "$degrade")   $(status_badge "$wg_ok" "WG(local)" "$degrade")   $(status_badge "$az_ok" "AZHDAR" "$degrade" "$az_tag")"
  if (( ssh_ok == 1 )); then
    out+="   $(status_badge "$remote_mimic_ok" "Mimic(remote)" "$degrade")   $(status_badge "$remote_wg_ok" "WG(remote)" "$degrade")"
  fi
  out+="
"

  if [[ -n "$hs" && "$hs" != "0" ]]; then
    out+="${DIM}WG handshake (wg show):${RST} $(human_ago "$hs")
"
  fi

  out+="${DIM}AZHDAR ping:${RST} IR→OUT"
  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" ]]; then
    out+=" v4 $(tiny_mark "$p4")"
  fi
  if [[ "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then
    out+="  v6 $(tiny_mark "$p6")"
  fi
  out+="   ${DIM}|${RST}   OUT→IR"
  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" ]]; then
    out+=" v4 $(tiny_mark "$rp4")"
  fi
  if [[ "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then
    out+="  v6 $(tiny_mark "$rp6")"
  fi
  out+="
"

  out+="${DIM}WG config:${RST} Port=${WG_PORT}  Endpoint=${endpoint}
"
  [[ -n "${listen_rt}" ]] && out+="${DIM}WG runtime:${RST} listen-port=${listen_rt}
"
  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" ]]; then
    out+="${DIM}WG IPv4:${RST} IR=${IR_WG_IP}/${prefix4}  OUT=${OUT_WG_IP}/${prefix4}
"
  else
    out+="${DIM}WG IPv4:${RST} disabled
"
  fi
  if [[ "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then
    out+="${DIM}WG IPv6:${RST} IR=${IR_WG_IP6}/${prefix6}  OUT=${OUT_WG_IP6}/${prefix6}
"
  else
    out+="${DIM}WG IPv6:${RST} disabled
"
  fi

  out+="${DIM}WG iface (local):${RST} ${local_addrs}
"
  out+="${DIM}WG iface (remote):${RST} ${remote_addrs}
"

  out+="${DIM}Mimic filter:${RST} local=${IR_LOCAL_IP:-?}:${WG_PORT}  remote=${OUT_PUBLIC_IP}:${WG_PORT}
"
  local _dst="<ipv4 disabled>"
  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && -n "${OUT_WG_IP:-}" ]]; then
    _dst="${OUT_WG_IP}:${VLESS_DST_PORT}"
  elif [[ "${ENABLE_TUN_IPV6:-0}" == "1" && -n "${OUT_WG_IP6:-}" ]]; then
    _dst="[${OUT_WG_IP6}]:${VLESS_DST_PORT}"
  fi
  out+="${DIM}Forwarding:${RST} TCP=${FORWARD_TCP_PORTS:-<none>}  UDP=${FORWARD_UDP_PORTS:-<none>}  dst=${_dst}
"

  STATUS_CACHE_TEXT="$out"
  STATUS_CACHE_TS="$now"
  printf "%b" "$out"
}


profile_quick_info_panel(){
  # Compact, readable dashboard for the main menu. Keep it mostly local-only so
  # the menu stays responsive; exact remote validation remains in menu 5.
  [[ -n "${PROFILE:-}" ]] || return 0

  local wan="" listen_rt="" endpoint="" local_addrs="" dst="" mgmt="" outpub=""
  local wgsvc="" hs_epoch="0" hs_txt="none" wgsvc_ok=0 wg_link_ok=0 ssh_local_ok=0 mimic_local_ok=0 wg_local_ok=0 az_local_ok=0
  local az_transport="" sshfb_active=0
  local local_line="" remote_line=""

  wan="$(detect_wan_if 2>/dev/null || true)"
  wgsvc="$(svc_wg 2>/dev/null || echo "wg-quick@${WG_IF}")"
  command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet "$wgsvc" 2>/dev/null && wgsvc_ok=1 || true
  [[ -d "/sys/class/net/${WG_IF}" ]] && wg_link_ok=1 || true

  # SSH is the management/recovery path. It is separate from the AZHDAR/WG
  # tunnel state, but the dashboard should still reflect whether it is usable.
  # Keep it best-effort and non-fatal so menu rendering never exits on SSH
  # failures or missing profile fields.
  if declare -F ssh_check_quiet >/dev/null 2>&1 && ssh_check_quiet >/dev/null 2>&1; then
    ssh_local_ok=1
  fi

  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    mimic_local_ok=1
  elif declare -F mimic_local_active_quiet >/dev/null 2>&1; then
    mimic_local_active_quiet "$wan" && mimic_local_ok=1 || true
  elif [[ -n "$wan" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet "mimic@${wan}" 2>/dev/null && mimic_local_ok=1 || true
  fi
  hs_epoch="$(wg_handshake_epoch 2>/dev/null || echo 0)"
  local hs_state="no-handshake" az_connected=0 connect_line=""
  if [[ -n "$hs_epoch" && "$hs_epoch" != "0" ]]; then
    hs_txt="$(human_ago "$hs_epoch" 2>/dev/null || echo seen)"
    hs_state="$(wg_handshake_state "$hs_epoch" 2>/dev/null || echo stale)"
    # The big connection indicator must represent the AZHDAR/WireGuard tunnel,
    # not merely the presence of a profile, service, interface, or SSH fallback.
    # Only a recent WireGuard handshake is treated as connected.
    if [[ "$hs_state" == "recent" ]]; then
      wg_local_ok=1
      az_local_ok=1
      az_connected=1
      az_transport="wg"
    fi
  fi

  # Optional emergency SSH fallback is a management/recovery path, not the
  # WireGuard tunnel itself.  It may make the profile repairable, but it must
  # never be shown as "direct" under AZHDAR; "direct" belongs only to SSH
  # management transport and previously made the dashboard look like the tunnel
  # was bypassing WireGuard even when the WG handshake was fresh.
  if command -v systemctl >/dev/null 2>&1 && declare -F ssh_fallback_service_name >/dev/null 2>&1; then
    local sshfb_svc=""
    sshfb_svc="$(ssh_fallback_service_name 2>/dev/null || true)"
    if [[ -n "$sshfb_svc" ]] && systemctl is-active --quiet "$sshfb_svc" 2>/dev/null; then
      sshfb_active=1
    fi
  fi
  if (( az_local_ok == 0 && sshfb_active == 1 )); then
    # SSH fallback is useful for recovery, but it is not an AZHDAR tunnel
    # connection. Keep the main CONNECTED state tied to the WG handshake.
    az_transport="ssh-fallback"
  fi

  listen_rt="$(wg show "${WG_IF}" listen-port 2>/dev/null | tr -d '
' | tail -n1 || true)"
  [[ "${listen_rt}" == "0" ]] && listen_rt=""
  outpub="${OUT_PUBLIC_IP:-${OUT_SSH_HOST:-?}}"
  endpoint="$(format_ipport "${outpub}" "${WG_PORT:-?}" 2>/dev/null || echo "${outpub}:${WG_PORT:-?}")"
  local_addrs="$(iface_addrs_local "${WG_IF}" 2>/dev/null || true)"
  [[ -n "$local_addrs" ]] || local_addrs="<none>"
  mgmt="${SSH_MGMT_TRANSPORT:-auto}"
  if [[ -n "${SSH_MGMT_LAST_TRANSPORT:-}" && -n "${SSH_MGMT_LAST_HOST:-}" ]]; then
    mgmt+=" / last=${SSH_MGMT_LAST_TRANSPORT}@${SSH_MGMT_LAST_HOST}:${SSH_MGMT_LAST_PORT:-${OUT_SSH_PORT:-22}}"
  fi

  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && -n "${OUT_WG_IP:-}" && "${OUT_WG_IP}" != "peer" ]]; then
    dst="${OUT_WG_IP}:${VLESS_DST_PORT:-?}"
  elif [[ "${ENABLE_TUN_IPV6:-0}" == "1" && -n "${OUT_WG_IP6:-}" && "${OUT_WG_IP6}" != "peer" ]]; then
    dst="[${OUT_WG_IP6}]:${VLESS_DST_PORT:-?}"
  else
    dst="<none>"
  fi

  local_line="$(status_badge "$ssh_local_ok" "SSH")   $(status_badge "$mimic_local_ok" "Mimic")   $(status_badge "$wg_local_ok" "WG")   $(status_badge "$az_local_ok" "AZHDAR" 0 "$az_transport")"

  if (( az_connected == 1 )); then
    connect_line="🟢 connected"
  elif [[ "$hs_state" == "stale" ]]; then
    connect_line="🟠 stale handshake"
  else
    connect_line="🔴 disconnected"
  fi

  ui_box_top "STATUS"
  echo -e "${DIM}│${RST} ${connect_line}"
  ui_box_row "Local" "$local_line"
  ui_box_row "Quick" "WG service=$(tiny_mark "$wgsvc_ok")   link=$(tiny_mark "$wg_link_ok")   handshake=${hs_txt}"
  ui_box_bottom

  ui_box_top "IR / OUT SERVERS"
  ui_box_row "IR" "public=${IR_PUBLIC_IP:-?}   local=${IR_LOCAL_IP:-?}   WAN=${wan:-?}"
  ui_box_row "SSH" "IR-exempt=${IR_SSH_PORT:-22}   OUT=${OUT_SSH_USER:-root}@${OUT_SSH_HOST:-?}:${OUT_SSH_PORT:-22}"
  ui_box_row "Mgmt" "${mgmt}"
  ui_box_bottom

  ui_box_top "WIREGUARD / TUNNEL"
  ui_box_row "WG" "iface=${WG_IF:-?}   port=${WG_PORT:-?}   runtime=${listen_rt:-?}   mtu=${MTU:-?}"
  ui_box_row "Peer" "endpoint=${endpoint}"
  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" ]]; then
    ui_box_row "IPv4" "IR=${IR_WG_IP:-?}   OUT=${OUT_WG_IP:-?}   subnet=${TUN_SUBNET:-?}"
  else
    ui_box_row "IPv4" "disabled"
  fi
  if [[ "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then
    ui_box_row "IPv6" "IR=${IR_WG_IP6:-?}   OUT=${OUT_WG_IP6:-?}   subnet=${TUN_SUBNET6:-?}"
  fi
  ui_box_row "Iface" "${local_addrs}"
  ui_box_bottom

  ui_box_top "MIMIC / FORWARDING"
  ui_box_row "Mimic" "local=${IR_LOCAL_IP:-?}:${WG_PORT:-?}   remote=${outpub}:${WG_PORT:-?}"
  ui_box_row "Forward" "TCP=${FORWARD_TCP_PORTS:-<none>}   UDP=${FORWARD_UDP_PORTS:-<none>}"
  ui_box_row "Target" "${dst}"
  ui_box_bottom
}

profile_status_line_fast(){
  # Kept for compatibility; the detailed quick dashboard is rendered below.
  return 0
}


profile_status_line(){
  # Compatibility alias for older menu paths/plugins.
  profile_status_line_fast "$@"
}
