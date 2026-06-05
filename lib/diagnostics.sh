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
  local wan; wan="$(mimic_detect_local_if 2>/dev/null || detect_wan_if 2>/dev/null || true)"
  local mimicsvc="mimic@${wan}"

  local wg_svc_active=0 wg_active=0 mimic_active=0
  systemctl is-active --quiet "$wgsvc" 2>/dev/null && wg_svc_active=1 || true
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    mimic_active=1
  elif declare -F mimic_local_active_quiet >/dev/null 2>&1; then
    mimic_local_active_quiet "$wan" && mimic_active=1 || true
  elif [[ -n "$wan" ]]; then
    systemctl is-active --quiet "$mimicsvc" 2>/dev/null && mimic_active=1 || true
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
  if (( wg_svc_active == 1 )); then
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
  (( wg_svc_active == 1 && ( wg_hs_recent == 1 || p4 == 1 || p6 == 1 || rp4 == 1 || rp6 == 1 ) )) && wg_active=1 || wg_active=0

  local az_ok=0
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    (( wg_svc_active == 1 && ( wg_hs_recent == 1 || p4 == 1 || p6 == 1 ) )) && az_ok=1 || true
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


diagnostics_full(){
  banner
  echo -e "${BOLD}${WHT}Diagnostics (profile: ${PROFILE})${RST}"
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

