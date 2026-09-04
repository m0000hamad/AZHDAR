# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Connection / diagnostics --------------------
wg_handshake_epoch(){
  if ! have_cmd wg; then echo 0; return; fi
  if ! ip link show "$WG_IF" >/dev/null 2>&1; then echo 0; return; fi
  wg show "$WG_IF" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}' || echo 0
}

human_ago(){
  local hs="$1"
  [[ -n "$hs" && "$hs" != "0" ]] || { echo "no-handshake"; return; }
  local now; now="$(date +%s)"
  echo "$(( now - hs ))s ago"
}

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

azhdar_port_filter_probe(){
  # Detect the failure mode where every configuration value is correct but the
  # tunnel port is blocked on the path between the two servers. Signature: we
  # keep transmitting, nothing ever comes back, and no handshake completes,
  # while the OUT host itself still answers on its SSH port. Repair loops
  # cannot fix that, so say so instead of retrying forever.
  local rx tx hs
  read -r rx tx <<<"$(wg_transfer_stats)"
  hs="$(wg_handshake_epoch)"
  [[ "${rx:-0}" =~ ^[0-9]+$ ]] || rx=0
  [[ "${tx:-0}" =~ ^[0-9]+$ ]] || tx=0

  (( tx > 0 )) || return 1
  (( rx == 0 )) || return 1
  [[ -z "$hs" || "$hs" == "0" ]] || return 1

  local peer_ip="${OUT_PUBLIC_IP:-${OUT_SSH_HOST:-}}"
  [[ -n "$peer_ip" ]] || return 1
  local ssh_port="${OUT_SSH_PORT:-22}"
  local host_up=0
  if timeout 6 bash -c "exec 3<>/dev/tcp/${peer_ip}/${ssh_port}" 2>/dev/null; then
    host_up=1
  fi

  echo
  warn "Tunnel port ${WG_PORT:-?} looks blocked on the path to ${peer_ip}."
  echo -e "${DIM}Evidence:${RST}"
  echo "  - WireGuard sent ${tx} bytes, received ${rx}, and never completed a handshake."
  if (( host_up != 1 )); then
    echo "  - ${peer_ip} did not answer on TCP ${ssh_port} either, so check the OUT server itself first."
    return 0
  fi
  echo "  - ${peer_ip} answers on TCP ${ssh_port}, so the OUT server is up and routable."
  echo
  echo "One-way traffic to a host that is otherwise reachable almost always means"
  echo "the port is filtered for this pair of addresses rather than misconfigured."
  echo "Moving the tunnel to another port usually restores it. Clients are not"
  echo "affected: only the port the two servers use between themselves changes."

  local c csv=",${FORWARD_TCP_PORTS:-},${FORWARD_UDP_PORTS:-},"
  local suggestions=""
  for c in "${WG_PORT_CANDIDATES[@]}"; do
    [[ "$c" == "${WG_PORT:-}" ]] && continue
    [[ "$c" == "${IR_SSH_PORT:-22}" ]] && continue
    [[ "$csv" == *",${c},"* ]] && continue
    suggestions+="${c} "
  done
  [[ -n "$suggestions" ]] && { echo; echo -e "${DIM}Candidate ports:${RST} ${suggestions}"; }
  echo "Change it from the profile settings so WireGuard, Mimic and the firewall"
  echo "are rewritten together on both sides."
  return 0
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

# OS/codename helpers (best-effort)
detect_codename_local(){
  local codename=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release 2>/dev/null || true
    codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    if [[ -z "$codename" && -n "${VERSION:-}" ]]; then
      local tmp
      tmp="${VERSION#*(}"; tmp="${tmp%%)*}"
      if [[ -n "$tmp" && "$tmp" != "$VERSION" ]]; then
        codename="${tmp%% *}"
        codename="${codename,,}"
      fi
    fi
  fi
  if [[ -z "$codename" ]] && have_cmd lsb_release; then
    codename="$(lsb_release -cs 2>/dev/null || true)"
  fi
  echo "$codename"
}

remote_os_info(){
  # Outputs KEY=VALUE lines:
  # ARCH, ID, VERSION_ID, CODENAME, SYSTEMD, APT
  ssh_run_stdin_root <<'REMOTE'
set -euo pipefail
arch="$(uname -m 2>/dev/null || echo unknown)"
id="unknown"; ver="unknown"; codename=""
if [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  id="${ID:-unknown}"
  ver="${VERSION_ID:-unknown}"
  codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  if [ -z "$codename" ] && [ -n "${VERSION:-}" ]; then
    tmp="${VERSION#*(}"; tmp="${tmp%%)*}"
    if [ -n "$tmp" ] && [ "$tmp" != "$VERSION" ]; then
      codename="${tmp%% *}"
      codename="$(printf "%s" "$codename" | tr 'A-Z' 'a-z')"
    fi
  fi
fi
if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
  codename="$(lsb_release -cs 2>/dev/null || true)"
fi
has_systemd="no"; command -v systemctl >/dev/null 2>&1 && has_systemd="yes"
has_apt="no"; command -v apt-get >/dev/null 2>&1 && has_apt="yes"
echo "ARCH=$arch"
echo "ID=$id"
echo "VERSION_ID=$ver"
echo "CODENAME=$codename"
echo "SYSTEMD=$has_systemd"
echo "APT=$has_apt"
REMOTE
}


connection_indicator(){
  step "AZHDAR indicator"

  local wgsvc; wgsvc="$(svc_wg)"
  local wan; wan="$(detect_wan_if)"
  local mimicsvc="mimic@${wan}"

  local wg_svc_active=0 wg_link_up=0 wg_active=0 mimic_active=0
  systemctl is-active --quiet "$wgsvc" 2>/dev/null && wg_svc_active=1 || true
  ip link show dev "$WG_IF" >/dev/null 2>&1 && wg_link_up=1 || true
  systemctl is-active --quiet "$mimicsvc" 2>/dev/null && mimic_active=1 || true

  # Local SSH fallback state (if enabled)
  local sshfb_active=0
  if command -v systemctl >/dev/null 2>&1; then
    local sshfb_svc
    sshfb_svc="$(ssh_fallback_service_name 2>/dev/null || true)"
    if [[ -n "$sshfb_svc" ]]; then
      systemctl is-active --quiet "$sshfb_svc" 2>/dev/null && sshfb_active=1 || true
    fi
  fi

  # Remote service state (best-effort, non-interactive)
  local ssh_ok=0 ssh_port_open=0 remote_wg_active=0 remote_mimic_active=0
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    ssh_ok=0
  fi
  if [[ -n "${OUT_SSH_HOST:-}" ]]; then
    tcp_port_open "${OUT_SSH_HOST}" "${OUT_SSH_PORT:-22}" && ssh_port_open=1 || true
    if [[ "${WG_MODE:-classic}" != "account" ]] && ssh_check_quiet; then
      ssh_ok=1
      ssh_run "systemctl is-active --quiet wg-quick@${WG_IF}" >/dev/null 2>&1 && remote_wg_active=1 || true
      local rwan="${REMOTE_WAN_IF:-}"
      [[ -z "$rwan" ]] && rwan="$(remote_detect_wan_if_quiet || true)"
      if [[ -n "$rwan" ]]; then
        ssh_run "systemctl is-active --quiet mimic@${rwan}" >/dev/null 2>&1 && remote_mimic_active=1 || true
      fi
    fi
  fi

  # Ping WG IPs (IR → OUT)
  local p4=0 p6=0 rp4=0 rp6=0
  if (( wg_svc_active == 1 || wg_link_up == 1 )); then
    if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && -n "${OUT_WG_IP:-}" && "${OUT_WG_IP}" != "peer" ]]; then
      ping4_local_once "${OUT_WG_IP}" && p4=1 || true
    fi
    if [[ "${ENABLE_TUN_IPV6:-0}" == "1" && -n "${OUT_WG_IP6:-}" && "${OUT_WG_IP6}" != "peer" ]]; then
      ping6_local_once "${OUT_WG_IP6}" && p6=1 || true
    fi
  fi

  # Ping reverse direction (OUT → IR), best-effort.
  if (( ssh_ok == 1 )); then
    if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && -n "${IR_WG_IP:-}" ]]; then
      ping4_remote_once "${IR_WG_IP}" && rp4=1 || true
    fi
    if [[ "${ENABLE_TUN_IPV6:-0}" == "1" && -n "${IR_WG_IP6:-}" ]]; then
      ping6_remote_once "${IR_WG_IP6}" && rp6=1 || true
    fi
  fi

  # Derive WG "connected" more accurately than just service state.
  local hs; hs="$(wg_handshake_epoch)"
  local wg_hs_recent=0
  if [[ -n "$hs" && "$hs" != "0" ]]; then
    local now_hs; now_hs="$(date +%s 2>/dev/null || echo 0)"
    (( now_hs - hs <= 180 )) && wg_hs_recent=1 || true
  fi
  (( (wg_svc_active == 1 || wg_link_up == 1) && ( wg_hs_recent == 1 || p4 == 1 || p6 == 1 || rp4 == 1 || rp6 == 1 ) )) && wg_active=1 || wg_active=0

  local az_ok=0
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    (( (wg_svc_active == 1 || wg_link_up == 1) && ( wg_hs_recent == 1 || p4 == 1 || p6 == 1 ) )) && az_ok=1 || true
  else
    (( p4 == 1 || p6 == 1 || rp4 == 1 || rp6 == 1 )) && az_ok=1 || true
  fi
  (( sshfb_active == 1 )) && az_ok=1 || true

  # If SSH fallback is up, show disconnected indicators as degraded (orange) instead of red.
  local degrade=0
  (( sshfb_active == 1 )) && degrade=1 || true

  echo
  echo -e "${BOLD}${WHT}Services${RST}"
  echo -e "  Local : WG $(tiny_mark "$wg_active" "$degrade")   Mimic $(tiny_mark "$mimic_active" "$degrade")"
  local ssh_tag=""
  if (( sshfb_active == 1 )) && [[ "${SSH_FALLBACK_TRANSPORT:-direct}" == "wg" ]]; then
    ssh_tag=" ${DIM}(Mimic SSH)${RST}"
  fi
  echo -e "  Local : AZHDAR SSH $(tiny_mark "$sshfb_active")${ssh_tag}"
  if (( ssh_ok == 1 )); then
    echo -e "  Remote: WG $(tiny_mark "$remote_wg_active" "$degrade")   Mimic $(tiny_mark "$remote_mimic_active" "$degrade")   ${DIM}(SSH OK)${RST}"
  else
    if (( ssh_port_open == 1 )); then
      echo -e "  Remote: ${DIM}SSH port open (auth required)${RST}"
    else
      echo -e "  Remote: ${DIM}SSH unavailable${RST}"
    fi
  fi


  echo
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    local hs_state runtime_ep txrx txb rxb
    hs_state="$(wg_handshake_state "$hs")"
    runtime_ep="$(wg_runtime_endpoint)"
    txrx="$(wg_transfer_stats)"
    txb="${txrx%% *}"
    rxb="${txrx##* }"
    echo -e "${BOLD}${WHT}WireGuard account state${RST}"
    local tunnel_summary="DISCONNECTED"
    [[ "$hs_state" == "recent" ]] && tunnel_summary="CONNECTED"
    echo -e "  Tunnel  : ${tunnel_summary}"
    echo -e "  Service : $(tiny_mark "$wg_svc_active" 0)  ${DIM}($(svc_wg))${RST}"
    echo -e "  Handshake: ${hs_state}$( [[ -n "$hs" && "$hs" != "0" ]] && echo -n " / $(human_ago "$hs")" )"
    [[ -n "${WG_ACCOUNT_ENDPOINT:-}" ]] && echo -e "  Endpoint(config): ${WG_ACCOUNT_ENDPOINT}"
    [[ -n "$runtime_ep" && "$runtime_ep" != "(none)" ]] && echo -e "  Endpoint(runtime): ${runtime_ep}"
    echo -e "  Transfer : rx=${rxb:-0}  tx=${txb:-0}"
    if [[ -n "${FORWARD_DST_IP:-}" || -n "${VLESS_DST_PORT:-}" || -n "${FORWARD_TCP_PORTS:-}${FORWARD_UDP_PORTS:-}" ]]; then
      echo -e "  Forward  : dst=${FORWARD_DST_IP:-?}:${VLESS_DST_PORT:-?}  tcp=[${FORWARD_TCP_PORTS:-}]  udp=[${FORWARD_UDP_PORTS:-}]"
    fi
    if [[ "${OUT_WG_IP:-}" == "peer" || "${OUT_WG_IP6:-}" == "peer" ]]; then
      echo -e "  Peer ping : ${DIM}skipped (peer tunnel IP not present in imported account config)${RST}"
    fi
  fi
  echo
  echo -e "${BOLD}${WHT}AZHDAR (tunnel ping)${RST}"
  echo -e "  IR→OUT:$( [[ "${ENABLE_TUN_IPV4:-1}" == "1" ]] && echo -e " v4 $(tiny_mark "$p4" "$degrade")" )$( [[ "${ENABLE_TUN_IPV6:-0}" == "1" ]] && echo -e "  v6 $(tiny_mark "$p6" "$degrade")" )"
  if (( ssh_ok == 1 )); then
    echo -e "  OUT→IR:$( [[ "${ENABLE_TUN_IPV4:-1}" == "1" ]] && echo -e " v4 $(tiny_mark "$rp4" "$degrade")" )$( [[ "${ENABLE_TUN_IPV6:-0}" == "1" ]] && echo -e "  v6 $(tiny_mark "$rp6" "$degrade")" )"
  else
    echo -e "  OUT→IR: ${DIM}skipped${RST}"
  fi

  local hs; hs="$(wg_handshake_epoch)"
  if [[ -n "$hs" && "$hs" != "0" ]]; then
    echo -e "${DIM}WG handshake (wg show):${RST} $(human_ago "$hs")"
  fi

  echo
  if (( az_ok == 1 )); then
    ok "AZHDAR: CONNECTED"
    return 0
  fi

  if (( sshfb_active == 1 )); then
    warn "AZHDAR: CONNECTED (SSH fallback)"
    return 0
  fi

  err "AZHDAR: DISCONNECTED"
if (( wg_active == 0 || mimic_active == 0 )); then
  warn "Local services are not active; start services first."
else
  warn "No tunnel ping response. Check AllowedIPs/MTU/firewall and Mimic filter IPs."
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    warn "Account mode note: peer tunnel IP is usually unknown; rely on recent handshake, runtime endpoint, and transfer counters."
  fi
  echo
  echo -e "${DIM}Details (why ping failed):${RST}"
  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" ]]; then
    if [[ -n "${OUT_WG_IP:-}" && "${OUT_WG_IP}" != "peer" && "${p4:-0}" != "1" ]]; then
      echo -e "  IR→OUT v4: $(ping4_local_diag "${OUT_WG_IP}" || true)"
    fi
    if (( ssh_ok == 1 )) && [[ -n "${IR_WG_IP:-}" && "${rp4:-0}" != "1" ]]; then
      echo -e "  OUT→IR v4: $(ping4_remote_diag "${IR_WG_IP}" || true)"
    fi
  fi
  if [[ "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then
    if [[ -n "${OUT_WG_IP6:-}" && "${OUT_WG_IP6}" != "peer" && "${p6:-0}" != "1" ]]; then
      echo -e "  IR→OUT v6: $(ping6_local_diag "${OUT_WG_IP6}" || true)"
    fi
    if (( ssh_ok == 1 )) && [[ -n "${IR_WG_IP6:-}" && "${rp6:-0}" != "1" ]]; then
      echo -e "  OUT→IR v6: $(ping6_remote_diag "${IR_WG_IP6}" || true)"
    fi
  fi
  if (( ssh_ok == 0 )); then
    echo -e "  OUT→IR: ${DIM}skipped (SSH unavailable)${RST}"
  fi
fi
return 1
}



azhdar_unit_brief_local(){
  local label="$1" unit="$2"
  local state enabled result main_status
  state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  result="$(systemctl show -p Result --value "$unit" 2>/dev/null || true)"
  main_status="$(systemctl show -p ExecMainStatus --value "$unit" 2>/dev/null || true)"
  [[ -n "$enabled" ]] || enabled="unknown"
  if [[ "$state" == "active" ]]; then
    ok "${label}: active (${unit}, enabled=${enabled})"
  elif [[ "$state" == "inactive" || "$state" == "failed" || "$state" == "activating" || "$state" == "deactivating" ]]; then
    err "${label}: ${state} (${unit}, enabled=${enabled}, result=${result:-unknown}, code=${main_status:-0})"
  else
    warn "${label}: ${state:-unknown} (${unit}, enabled=${enabled})"
  fi
}

azhdar_unit_brief_remote(){
  local label="$1" unit="$2"
  local out state enabled result main_status
  out="$(ssh_run "u='${unit}'; printf 'state='; systemctl is-active \"\$u\" 2>/dev/null || true; printf '\nenabled='; systemctl is-enabled \"\$u\" 2>/dev/null || true; printf '\nresult='; systemctl show -p Result --value \"\$u\" 2>/dev/null || true; printf '\ncode='; systemctl show -p ExecMainStatus --value \"\$u\" 2>/dev/null || true" 2>/dev/null || true)"
  state="$(printf '%s\n' "$out" | awk -F= '/^state=/{print $2; exit}')"
  enabled="$(printf '%s\n' "$out" | awk -F= '/^enabled=/{print $2; exit}')"
  result="$(printf '%s\n' "$out" | awk -F= '/^result=/{print $2; exit}')"
  main_status="$(printf '%s\n' "$out" | awk -F= '/^code=/{print $2; exit}')"
  [[ -n "$enabled" ]] || enabled="unknown"
  if [[ "$state" == "active" ]]; then
    ok "${label}: active (${unit}, enabled=${enabled})"
  elif [[ -n "$state" ]]; then
    err "${label}: ${state} (${unit}, enabled=${enabled}, result=${result:-unknown}, code=${main_status:-0})"
  else
    warn "${label}: status unavailable (${unit})"
  fi
}

diagnostics_full_verbose(){
  banner
  echo -e "${BOLD}${WHT}Diagnostics (verbose, profile: ${PROFILE})${RST}"
  hr
  echo -e "${DIM}Local:${RST}"
  echo "  WG_IF=${WG_IF}  WG_PORT=${WG_PORT}  OUT=${OUT_PUBLIC_IP}"
  echo
  echo -e "${DIM}Services:${RST}"
  local wan; wan="$(detect_wan_if)"
  systemctl status "mimic@${wan}" --no-pager -l 2>/dev/null || true
  echo
  systemctl status "$(svc_wg)" --no-pager -l 2>/dev/null || true
  echo
  echo -e "${DIM}WireGuard:${RST}"
  wg show "$WG_IF" 2>/dev/null || true
  echo
  echo -e "${DIM}Recent logs:${RST}"
  journalctl -u "mimic@${wan}" -n 60 --no-pager -l 2>/dev/null || true
  echo
  journalctl -u "$(svc_wg)" -n 60 --no-pager -l 2>/dev/null || true

  if ssh_check_quiet; then
    echo
    hr
    echo -e "${DIM}Remote:${RST}"
    ssh_run "${REMOTE_SUDO:-} uname -a" 2>/dev/null || true
    echo
    ssh_run "${REMOTE_SUDO:-} systemctl status wg-quick@${WG_IF} --no-pager -l | sed -n '1,60p'" 2>/dev/null || true
    echo
    local rw="${REMOTE_WAN_IF:-}"
    if [[ -n "$rw" ]]; then
      ssh_run "${REMOTE_SUDO:-} systemctl status mimic@${rw} --no-pager -l | sed -n '1,60p'" 2>/dev/null || true
    fi
  else
    echo
    if [[ "${WG_MODE:-classic}" == "account" ]]; then
      warn "Remote diagnostics skipped in WireGuard account mode (no remote setup / no SSH side)."
    else
      warn "Remote diagnostics skipped (SSH not available)."
    fi
  fi
  pause
}

diagnostics_full(){
  if [[ "${AZHDAR_VERBOSE_DIAG:-0}" == "1" ]]; then
    diagnostics_full_verbose
    return $?
  fi

  banner
  echo -e "${BOLD}${WHT}Diagnostics summary (profile: ${PROFILE})${RST}"
  hr
  echo -e "${DIM}Only final states are shown here. Full journal/systemctl logs are hidden by default.${RST}"
  echo

  connection_indicator || true
  echo
  hr
  echo -e "${BOLD}${WHT}Service summary${RST}"
  local wan; wan="$(detect_wan_if)"
  azhdar_unit_brief_local "Local WG" "$(svc_wg)"
  azhdar_unit_brief_local "Local Mimic" "mimic@${wan}"

  if command -v modprobe >/dev/null 2>&1; then
    if modprobe -n mimic >/dev/null 2>&1 || lsmod | grep -q '^mimic\b'; then
      ok "Mimic kernel module: available"
    else
      err "Mimic kernel module: not available/loadable"
    fi
  fi

  if ssh_check_quiet; then
    local rw="${REMOTE_WAN_IF:-}"
    [[ -z "$rw" ]] && rw="$(remote_detect_wan_if_quiet 2>/dev/null || true)"
    azhdar_unit_brief_remote "Remote WG" "wg-quick@${WG_IF}"
    [[ -n "$rw" ]] && azhdar_unit_brief_remote "Remote Mimic" "mimic@${rw}" || warn "Remote Mimic: WAN interface unknown"
  else
    warn "Remote service summary skipped (SSH unavailable)."
  fi

  echo
  echo -e "${DIM}Log files are still saved for support:${RST}"
  echo -e "  ${LOG_FILE}"
  echo -e "  $(_tunnel_repair_log 2>/dev/null || echo "${BASE_DIR}/repair-${PROFILE:-unknown}.log")"
  echo -e "${DIM}For full systemctl/journal output run:${RST} AZHDAR_VERBOSE_DIAG=1 azhdar"
  pause
}
