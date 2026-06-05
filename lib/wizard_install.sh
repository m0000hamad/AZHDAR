# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Install / Repair wizard --------------------
remote_prepare_deps(){
  step "Install/check remote dependencies (best-effort)"
  if ssh_run_stdin_root_best_effort <<'REMOTE' >/dev/null 2>&1
set -euo pipefail
PM=unknown
command -v apt-get >/dev/null 2>&1 && PM=apt
command -v dnf >/dev/null 2>&1 && PM=dnf
command -v yum >/dev/null 2>&1 && PM=yum
command -v pacman >/dev/null 2>&1 && PM=pacman

if [ "$PM" = apt ]; then
  export DEBIAN_FRONTEND=noninteractive
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 update -y >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 install -y wireguard-tools wireguard iptables iproute2 iputils-ping curl ca-certificates git build-essential libpcap-dev netcat-openbsd tcpdump python3 >/dev/null 2>&1 || true
elif [ "$PM" = dnf ]; then
  dnf install -y wireguard-tools iptables iproute iputils curl ca-certificates git make gcc libpcap-devel nmap-ncat tcpdump python3 >/dev/null 2>&1 || true
elif [ "$PM" = yum ]; then
  yum install -y wireguard-tools iptables iproute iputils curl ca-certificates git make gcc libpcap-devel nmap-ncat tcpdump python3 >/dev/null 2>&1 || true
elif [ "$PM" = pacman ]; then
  pacman -Sy --noconfirm wireguard-tools iptables iproute2 iputils curl ca-certificates git base-devel libpcap netcat tcpdump python >/dev/null 2>&1 || true
fi
modprobe wireguard >/dev/null 2>&1 || true
# Never leave remote SSH disabled after dependency/install operations.
if command -v systemctl >/dev/null 2>&1; then
  for svc in ssh.service sshd.service; do
    systemctl unmask "$svc" >/dev/null 2>&1 || true
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl is-active --quiet "$svc" >/dev/null 2>&1 || systemctl start "$svc" >/dev/null 2>&1 || true
  done
  for svc in ssh.socket sshd.socket; do
    systemctl unmask "$svc" >/dev/null 2>&1 || true
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl is-active --quiet "$svc" >/dev/null 2>&1 || systemctl start "$svc" >/dev/null 2>&1 || true
  done
fi
REMOTE
  then
    ok "Remote dependencies prepared (best-effort)."
    return 0
  else
    warn "Remote dependencies were NOT confirmed (SSH/root access may be unavailable). Continuing only if later steps can recover."
    return 1
  fi
}

generate_remote_pubkey(){
  # Robust remote pubkey retrieval:
  # 1) try generating/reading on remote (requires wg)
  # 2) fallback: if remote key exists, fetch it and compute pubkey locally
  # 3) fallback: generate key locally, upload to remote, return pubkey

  local key_path="/etc/wireguard/${WG_IF}.key"
  local out="" pk="" rc=0

  out="$(ssh_run_stdin_env_root "KEY_PATH=${key_path}" <<'REMOTE' 2>/dev/null
set -euo pipefail
mkdir -p /etc/wireguard
umask 077
if command -v wg >/dev/null 2>&1; then
  k="${KEY_PATH}"
  if [ ! -f "$k" ]; then
    wg genkey >"$k"
    chmod 600 "$k"
  fi
  wg pubkey <"$k"
else
  echo "NO_WG"
  exit 7
fi
REMOTE
)"; rc=$?

  pk="$(printf '%s' "${out}" | tr -d '
' | tail -n1)"
  if [[ $rc -eq 0 && -n "$pk" && "$pk" != "NO_WG" ]]; then
    echo "$pk"
    return 0
  fi

  # Fallback 1: if key exists on remote, fetch it and compute pubkey locally
  local rpriv=""
  rpriv="$(ssh_run_root "test -f ${key_path} && cat ${key_path} || true" 2>/dev/null | tr -d '
' | tail -n1 || true)"
  if [[ -n "$rpriv" ]]; then
    pk="$(printf '%s' "$rpriv" | wg pubkey 2>/dev/null | tr -d '
' | tail -n1 || true)"
    if [[ -n "$pk" ]]; then
      echo "$pk"
      return 0
    fi
  fi

  # Fallback 2: generate locally, upload to remote
  rpriv="$(wg genkey 2>/dev/null | tr -d '
' | tail -n1 || true)"
  [[ -n "$rpriv" ]] || return 1
  pk="$(printf '%s' "$rpriv" | wg pubkey 2>/dev/null | tr -d '
' | tail -n1 || true)"
  [[ -n "$pk" ]] || return 1

  ssh_run_stdin_env_root_best_effort "KEY_PATH=${key_path}" "RPRIV=${rpriv}" <<'REMOTE' 2>/dev/null || true
set -euo pipefail
mkdir -p /etc/wireguard
umask 077
printf '%s
' "${RPRIV}" >"${KEY_PATH}"
chmod 600 "${KEY_PATH}" 2>/dev/null || true
REMOTE

  echo "$pk"
  return 0
}

install_wizard(){
  banner
  echo -e "${BOLD}${WHT}Install / Update / Repair wizard${RST}"
  hr

  # Basic sanity
  [[ -n "${PROFILE:-}" ]] || die "No active profile. Create/select one first."

  IR_SSH_PORT="$(prompt_port "IR server SSH port to exempt from tunnels/forwarding" "${IR_SSH_PORT:-22}")"
  protect_ir_ssh_port || true
  azhdar_firewall_safety_local || true
  profile_save

  install_deps_local

  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    echo
    echo -e "${BOLD}${WHT}WireGuard account mode${RST}"
    hr
    wg_account_apply_runtime_vars

    local myip=""
    myip="$(public_ipv4 2>/dev/null || true)"
    [[ -n "$myip" ]] && IR_PUBLIC_IP="${IR_PUBLIC_IP:-$myip}"
    [[ -n "${FORWARD_TCP_PORTS:-}${FORWARD_UDP_PORTS:-}" ]] && info "Forward ports: TCP=${FORWARD_TCP_PORTS:-<none>} UDP=${FORWARD_UDP_PORTS:-<none>}"
    [[ -n "${FORWARD_DST_IP:-}${VLESS_DST_PORT:-}" ]] && info "Forward target: ${FORWARD_DST_IP:-<missing>}:${VLESS_DST_PORT:-<missing>}"

    echo
    echo -e "${BOLD}${WHT}Tunnel parameters${RST}"
    hr
    KEEPALIVE="$(prompt_keepalive "PersistentKeepalive" "${KEEPALIVE:-25}")"
    MTU="$(prompt_mtu "MTU" "${MTU:-1272}")"

    profile_save
    write_wg_conf_local
    start_services_local

    azhdar_firewall_safety_local || true
    allow_forward_ports_local || true
    if [[ -n "${FORWARD_TCP_PORTS}${FORWARD_UDP_PORTS}" && -n "${FORWARD_DST_IP:-}" && -n "${VLESS_DST_PORT:-}" ]]; then
      remove_forwarding_local || true
      setup_forward_ir || true
    else
      remove_forwarding_local || true
    fi
    persist_iptables_local || true

    PROFILE_ENABLED="1"
    profile_save
    echo
    hr
    echo -e "${BOLD}${WHT}Final check${RST}"
    hr
    echo -e "Waiting 6s for handshake..."
    sleep 6
    if connection_indicator; then
      ok "WireGuard account tunnel is connected."
    else
      warn "WireGuard service started, but no confirmed handshake yet."
      warn "Check endpoint reachability, DNS, MTU, and forwarding destination from Diagnostics/Status."
    fi
    pause
    return 0
  fi

  # Detect and store IR public IP (suggestion)
  local myip=""
  myip="$(public_ipv4 2>/dev/null || true)"
  [[ -n "$myip" ]] && IR_PUBLIC_IP="${IR_PUBLIC_IP:-$myip}"
  IR_PUBLIC_IP="$(prompt_ipv4 "IR public IP (this server)" "${IR_PUBLIC_IP:-}")"

  # SSH details (profile)
  OUT_SSH_HOST="$(prompt_host "OUT server host (SSH)" "${OUT_SSH_HOST:-$OUT_PUBLIC_IP}")"
  OUT_PUBLIC_IP="${OUT_PUBLIC_IP:-$OUT_SSH_HOST}"
  OUT_PUBLIC_IP="${OUT_SSH_HOST}"
  OUT_SSH_PORT="$(prompt_port "OUT SSH port" "${OUT_SSH_PORT:-22}")"
  OUT_SSH_USER="$(prompt_nonempty "OUT SSH user" "${OUT_SSH_USER:-root}")"

echo
echo -e "${BOLD}${WHT}SSH transport${RST}"
hr
echo -e "${DIM}1) direct    : SSH connects to OUT public IP/port (normal)
2) mimic-ssh : SSH connects to OUT via the WireGuard tunnel IP (traffic rides over Mimic). Requires WG tunnel to be up.${RST}"
local deftr="${SSH_FALLBACK_TRANSPORT:-direct}"
local defsel_t="1"
[[ "$deftr" == "wg" ]] && defsel_t="2"
local tsel=""
read -rp "Select [${defsel_t}]: " tsel || true
tsel="${tsel:-$defsel_t}"
case "$tsel" in
  2)
    SSH_FALLBACK_TRANSPORT="wg"
    SSH_MGMT_TRANSPORT="wg"
    ;;
  *)
    SSH_FALLBACK_TRANSPORT="direct"
    SSH_MGMT_TRANSPORT="direct"
    SSH_MGMT_LAST_TRANSPORT=""
    SSH_MGMT_LAST_HOST=""
    SSH_MGMT_LAST_PORT=""
    ;;
esac
  read -rsp "OUT SSH password (SSH key recommended): " _pw || true
  echo
  if [[ -n "${_pw:-}" ]]; then
    OUT_SSH_PASS="${_pw}"
    if ! have_cmd sshpass; then
      warn "sshpass not found; installing (for password-based non-interactive SSH)..."
      local pm; pm="$(detect_pkg_mgr)"
      case "$pm" in
        apt)
          export DEBIAN_FRONTEND=noninteractive
          DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 update -y >/dev/null 2>&1 || true
          DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 install -y sshpass >/dev/null 2>&1 || true
          ;;
        dnf) dnf install -y sshpass >/dev/null 2>&1 || true ;;
        yum) yum install -y sshpass >/dev/null 2>&1 || true ;;
        pacman) pacman -Sy --noconfirm sshpass >/dev/null 2>&1 || true ;;
      esac
      have_cmd sshpass || warn "sshpass still missing; SSH may prompt interactively."
    fi
  fi
  read -rp "OUT SSH identity file (optional) [${OUT_SSH_IDENTITY:-none}]: " ident || true
  ident="${ident:-}"
  ident="${ident//$'\r'/}"
  ident="${ident//$'\n'/}"
  [[ -n "$ident" ]] && OUT_SSH_IDENTITY="$ident"

  # Preflight (sets REMOTE_SUDO)
  remote_preflight || { pause; return 1; }

  # Port selection (auto-suggest + optional override)
  local suggested
  suggested="$(suggest_wg_port || true)"
  [[ -n "$suggested" ]] && WG_PORT="$suggested"
  while true; do
    WG_PORT="$(prompt_port "Tunnel public port (looks like TCP)" "${WG_PORT:-443}")"

    # Warn if OS sockets appear to use it.
    local _lp="no" _rp="no"
    local_port_in_use "${WG_PORT}" && _lp="yes" || true
    remote_port_in_use "${WG_PORT}" && _rp="yes" || true
    if [[ "${_lp}" == "yes" || "${_rp}" == "yes" ]]; then
      warn "Selected WG_PORT=${WG_PORT} appears to be in use (local=${_lp}, remote=${_rp})."
    fi

    # Hard conflict with other AZHDAR profiles (WG/forward/ssh-fallback).
    if ! ports_validate_current_or_warn; then
      local _sug
      _sug="$(ports_suggest_free_near tcp "${WG_PORT}" || true)"
      if [[ -n "${_sug:-}" && "${_sug}" != "${WG_PORT}" ]]; then
        warn "Suggested free port near ${WG_PORT}: ${_sug}"
        if [[ "$(prompt_yesno "Use suggested port ${_sug}?" "Y")" == "Y" ]]; then
          WG_PORT="${_sug}"
          continue
        fi
      fi
      warn "WG_PORT conflicts with another profile. Choose a different port."
      continue
    fi
    break
  done


  # Optional forwarding
  echo
  echo -e "${BOLD}${WHT}Optional reverse-forward${RST}"
  hr
  echo -e "${DIM}This can forward public IR ports to OUT over the WG tunnel.${RST}"
  local rf_default="N"
    [[ -n "${FORWARD_TCP_PORTS:-}${FORWARD_UDP_PORTS:-}" ]] && rf_default="Y"
    if [[ "$(prompt_yesno "Enable reverse-forward rules on IR?" "$rf_default")" == "Y" ]]; then
    while true; do
      read -rp "Public TCP port(s) on IR to forward (comma-separated, empty=none) [${FORWARD_TCP_PORTS}]: " FORWARD_TCP_PORTS || true
      FORWARD_TCP_PORTS="${FORWARD_TCP_PORTS:-}"
      protect_ir_ssh_port || true
      read -rp "Public UDP port(s) on IR to forward (comma-separated, empty=none) [${FORWARD_UDP_PORTS}]: " FORWARD_UDP_PORTS || true
      FORWARD_UDP_PORTS="${FORWARD_UDP_PORTS:-}"
      VLESS_DST_PORT="$(prompt_port "Destination port on OUT (service bind port)" "${VLESS_DST_PORT:-2086}")"

      if ports_validate_current_or_warn; then
        break
      fi

      warn "Forward ports conflict with another profile. Please re-enter."
    done
  else
    FORWARD_TCP_PORTS=""
    FORWARD_UDP_PORTS=""
  fi

  # Tunnel params
  echo
  echo -e "${BOLD}${WHT}Tunnel parameters${RST}"
  hr
  echo -e "${DIM}MTU mode:${RST}"
  echo " 1) Auto (discover best common MTU)"
  echo " 2) Manual"
  local _mtu_mode_def="1"
  [[ "${MTU_MODE:-manual}" == "manual" ]] && _mtu_mode_def="2" || true
  local _mtu_mode=""
  while true; do
    read -rp "Select [${_mtu_mode_def}]: " _mtu_mode || true
    _mtu_mode="${_mtu_mode:-${_mtu_mode_def}}"
    case "${_mtu_mode}" in
      1) MTU_MODE="auto"; break ;;
      2) MTU_MODE="manual"; break ;;
      *) warn "Invalid choice." ;;
    esac
  done
  if [[ "${MTU_MODE}" == "manual" ]]; then
    MTU="$(prompt_mtu "MTU" "${MTU:-1272}")"
  else
    # Start with a safe baseline; auto-discovery will refine after the tunnel comes up.
    MTU="${MTU:-1272}"
  fi
  KEEPALIVE="$(prompt_keepalive "PersistentKeepalive" "${KEEPALIVE:-25}")"


  echo -e "${DIM}Tunnel IP mode:${RST}"
  echo " 1) IPv4 only"
  echo " 2) IPv6 only"
  echo " 3) IPv4 + IPv6 (dual stack)"
  local _def_mode="1"
  if [[ "${ENABLE_TUN_IPV4:-1}" == "1" && "${ENABLE_TUN_IPV6:-0}" != "1" ]]; then _def_mode="1"; fi
  if [[ "${ENABLE_TUN_IPV4:-1}" != "1" && "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then _def_mode="2"; fi
  local _mode=""
  while true; do
    read -rp "Select [${_def_mode}]: " _mode || true
    _mode="${_mode:-${_def_mode}}"
    case "${_mode}" in
      1) ENABLE_TUN_IPV4="1"; ENABLE_TUN_IPV6="0"; break ;;
      2) ENABLE_TUN_IPV4="0"; ENABLE_TUN_IPV6="1"; break ;;
      3) ENABLE_TUN_IPV4="1"; ENABLE_TUN_IPV6="1"; break ;;
      *) warn "Invalid choice." ;;
    esac
  done

  if [[ "${ENABLE_TUN_IPV4}" != "1" && -n "${FORWARD_TCP_PORTS:-}${FORWARD_UDP_PORTS:-}" ]]; then
    warn "Reverse-forward requires an IPv4 tunnel address. Disabling forwarding settings for this profile."
    FORWARD_TCP_PORTS=""
    FORWARD_UDP_PORTS=""
  fi



  echo
  echo -e "${DIM}Tunnel IP allocation:${RST}"
  echo " 1) Auto (pick subnet + WG IPs)"
  echo " 2) Manual (set subnet + WG IPs)"
  local _def_ipassign="1"
  [[ "${TUN_IP_ASSIGN:-auto}" == "manual" ]] && _def_ipassign="2" || true
  local _ia=""
  while true; do
    read -rp "Select [${_def_ipassign}]: " _ia || true
    _ia="${_ia:-${_def_ipassign}}"
    case "${_ia}" in
      1) TUN_IP_ASSIGN="auto"; break ;;
      2) TUN_IP_ASSIGN="manual"; break ;;
      *) warn "Invalid choice." ;;
    esac
  done

  local psk_ans
  psk_ans="$(prompt_yesno "Use PSK for WireGuard?" "Y")"
  [[ "$psk_ans" == "Y" ]] && USE_PSK="1" || USE_PSK="0"
  ensure_psk

  profile_save

# If enabled, prepare and enable the auto-failover watchdog (WG → SSH) now.
if [[ "${SSH_FALLBACK_AUTO_ON_WG_DROP:-0}" == "1" ]]; then
  step "Prepare auto failover watchdog (WG → SSH)"
  # Make sure SSH fallback can run non-interactively later.
  ssh_fallback_deps_local || true
  remote_preflight >/dev/null 2>&1 || true
  ssh_fallback_ensure_key_auth || true
  ssh_fallback_configure_remote_sshd || true
  # Pre-generate the SSH fallback unit so the watchdog can start it instantly later.
  ssh_fallback_write_service_local >/dev/null 2>&1 || true
  # Enable watchdog timer
  ssh_fallback_watchdog_enable_current_profile >/dev/null 2>&1 || true
  ok "Auto failover watchdog is enabled for this profile."
fi

  # Prepare remote deps
  remote_prepare_deps || true

  # Ensure python3 is present remote (subnet check needs it). If missing, our subnet overlap check may fail.
  # We'll still try; if it fails we keep default subnet.
  if [[ "${TUN_IP_ASSIGN:-auto}" == "manual" ]]; then
    tunnel_manual_set || true
  else
    if [[ "${ENABLE_TUN_IPV4:-1}" == "1" ]]; then
      pick_subnet_pairwise || true
    fi
    if [[ "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then
      pick_subnet6_pairwise || true
    fi
  fi

  # Auto-detect mimic IPs
  auto_detect_local_ips
  profile_save

  # If still missing, ask interactively (Mimic needs correct filter IPs).
  if [[ -z "${IR_LOCAL_IP:-}" ]]; then
    IR_LOCAL_IP="$(prompt_ipv4 "IR local/source IP used to reach OUT (Mimic filter)" "")"
  fi
  if [[ -z "${OUT_LOCAL_IP:-}" ]]; then
    OUT_LOCAL_IP="$(prompt_ipv4 "OUT local/source IP used to reach IR (Mimic filter)" "")"
  fi

  # Sanity: check the IPs exist on each host (best-effort).
  if ! ip -4 addr show 2>/dev/null | grep -qw "${IR_LOCAL_IP}"; then
    warn "IR_LOCAL_IP=${IR_LOCAL_IP} not found on local interfaces (double-check)."
  fi
  if ssh_check_quiet; then
    if ! ssh_run "ip -4 addr show 2>/dev/null | grep -qw ${OUT_LOCAL_IP}" >/dev/null 2>&1; then
      warn "OUT_LOCAL_IP=${OUT_LOCAL_IP} not found on remote interfaces (double-check)."
    fi
  fi

  profile_save

  # Install Mimic both sides
  if ( install_mimic_local ); then
    ok "RESULT: IR/local Mimic install/check succeeded."
  else
    err "RESULT: IR/local Mimic install/check FAILED. Install stopped before changing services."
    pause
    return 1
  fi
  if ( install_mimic_remote ); then
    ok "RESULT: OUT/remote Mimic install/check succeeded."
  else
    err "RESULT: OUT/remote Mimic install/check FAILED. Install stopped before changing services."
    pause
    return 1
  fi

  # Generate WG keys
  if ensure_privkey_local; then
    IR_PUBKEY="$(get_pubkey_local 2>/dev/null | tr -d '\r' | tail -n1 || true)"
  else
    IR_PUBKEY=""
  fi
  if [[ -n "$IR_PUBKEY" ]]; then
    ok "RESULT: IR/local WireGuard key ready."
  else
    err "RESULT: IR/local WireGuard key FAILED. Install stopped."
    pause
    return 1
  fi

  OUT_PUBKEY="$(generate_remote_pubkey 2>/dev/null | tr -d '\r' | tail -n1 || true)"
  if [[ -n "$OUT_PUBKEY" ]]; then
    ok "RESULT: OUT/remote WireGuard key ready."
  else
    err "RESULT: OUT/remote WireGuard key FAILED. Install stopped."
    pause
    return 1
  fi

  ok "Keys ready."
  info "IR pubkey : ${IR_PUBKEY}"
  info "OUT pubkey: ${OUT_PUBKEY}"

  # Firewall
  azhdar_firewall_safety_local && ok "RESULT: IR/local SSH safety firewall check succeeded." || warn "RESULT: IR/local SSH safety firewall check was not fully confirmed."
  allow_mimic_port_local && ok "RESULT: IR/local tunnel port rule applied." || warn "RESULT: IR/local tunnel port rule NOT confirmed."
  allow_mimic_port_remote && ok "RESULT: OUT/remote tunnel port rule applied." || warn "RESULT: OUT/remote tunnel port rule NOT confirmed."
  allow_vless_on_remote_wg && ok "RESULT: OUT/remote WG ingress rule applied/skipped successfully." || warn "RESULT: OUT/remote WG ingress rule NOT confirmed."
  setup_rst_drop_remote && ok "RESULT: OUT/remote RST-drop rule applied." || warn "RESULT: OUT/remote RST-drop rule NOT confirmed."
  setup_rst_drop_local && ok "RESULT: IR/local RST-drop rule applied." || warn "RESULT: IR/local RST-drop rule NOT confirmed."

  # Write configs
  if ( write_mimic_conf_remote ); then
    REMOTE_WAN_IF="$(remote_detect_wan_if_quiet 2>/dev/null || true)"
    ok "RESULT: OUT/remote Mimic config written."
  else
    err "RESULT: OUT/remote Mimic config FAILED. Install stopped before service restart."
    pause
    return 1
  fi
  if write_wg_conf_remote; then
    ok "RESULT: OUT/remote WireGuard config written."
  else
    err "RESULT: OUT/remote WireGuard config FAILED. Install stopped before service restart."
    pause
    return 1
  fi
  if ( write_mimic_conf_local ); then
    ok "RESULT: IR/local Mimic config written."
  else
    err "RESULT: IR/local Mimic config FAILED. Install stopped before service restart."
    pause
    return 1
  fi
  if write_wg_conf_local; then
    ok "RESULT: IR/local WireGuard config written."
  else
    err "RESULT: IR/local WireGuard config FAILED. Install stopped before service restart."
    pause
    return 1
  fi

  # Start services
  start_services_remote && ok "RESULT: OUT/remote services start requested." || warn "RESULT: OUT/remote services start NOT confirmed."
  start_services_local && ok "RESULT: IR/local services start requested." || warn "RESULT: IR/local services start NOT confirmed."
  restart_services_remote && ok "RESULT: OUT/remote services restart requested." || warn "RESULT: OUT/remote services restart NOT confirmed."
  restart_services_local && ok "RESULT: IR/local services restart requested." || warn "RESULT: IR/local services restart NOT confirmed."

  # Optional forward rules
  azhdar_firewall_safety_local || true
  allow_forward_ports_local || true
  if [[ -n "${FORWARD_TCP_PORTS}${FORWARD_UDP_PORTS}" ]]; then
    setup_forward_ir || true
  fi

  # Persist firewall rules (best-effort)
  persist_iptables_local || true
  persist_iptables_remote || true

  # Mark profile enabled
  PROFILE_ENABLED="1"
  profile_save

  # Final check
  echo
  hr
  echo -e "${BOLD}${WHT}Final check${RST}"
  hr
  sleep 4
  if connection_indicator; then
    ok "Install/repair complete."

    if [[ "${MTU_MODE:-manual}" == "auto" ]]; then
      echo
      hr
      echo -e "${BOLD}${WHT}Auto MTU${RST}"
      hr
      mtu_autofind_and_apply || warn "Auto MTU failed; keeping MTU=${MTU}."
      echo
      connection_indicator || warn "After MTU apply, AZHDAR is still DISCONNECTED."
    fi
  else
    err "Install finished but AZHDAR is DISCONNECTED."

    if [[ "${TUN_IP_ASSIGN:-auto}" == "auto" ]]; then
      warn "Attempting auto-heal: switching tunnel IPs until AZHDAR is CONNECTED..."
      if azhdar_autofix_tunnel_ips; then
        ok "Auto-heal succeeded."
        # If MTU auto was selected, re-run discovery now that we have connectivity.
        if [[ "${MTU_MODE}" == "auto" ]]; then
          mtu_autofind_and_apply || true
        fi
        ok "Wizard completed."
        pause
        return 0
      fi
      warn "Auto-heal did not recover tunnel ping."
    fi

    # Final retry: restart services a few times before falling back
    # NOTE: keep output visible so user can see we really tried WG before SSH.
    local i max_try
    max_try="${WG_RETRY_BEFORE_SSH:-3}"
    for ((i=1;i<=max_try;i++)); do
      warn "Retrying WG/Mimic services (attempt ${i}/${max_try})..."
      restart_services_remote || true
      restart_services_local || true
      echo -e "Waiting 6s for handshake..."
      sleep 6
      if connection_indicator; then
        ok "Recovered after restart retry."
        pause
        return 0
      fi
    done

warn "Opening Diagnostics..."
pause
diagnostics_full || true

echo
hr
echo -e "${BOLD}${WHT}SSH fallback (last resort)${RST}"
hr

# Per request: after WG/Mimic retries fail, ASK before switching to SSH reverse tunnel.
# Default answer follows SSH_FALLBACK_AUTO_ON_WG_FAIL (Y by default).
local _def="N"
[[ "${SSH_FALLBACK_AUTO_ON_WG_FAIL:-1}" == "1" ]] && _def="Y"
local _ans="$_def"
if [[ -t 0 ]]; then
  _ans="$(prompt_yesno "WireGuard/Mimic is still DISCONNECTED. Switch to SSH reverse-tunnel fallback now? (clients connect to OUT IP)" "$_def")"
fi

if [[ "${_ans}" == "Y" ]]; then
  echo -e "${DIM}Switching to SSH reverse-tunnel fallback (TCP-only)...${RST}"
  ssh_fallback_autoconfigure_reverse_noninteractive || true
  ssh_fallback_prepare_after_wg_fail || true
  ssh_fallback_start || true
  if ssh_fallback_status_quiet; then
    ok "SSH reverse fallback is ACTIVE. Manage it later from the main menu: SSH fallback."
  else
    warn "SSH fallback attempted but service is not active. Check SSH fallback menu/status."
    ssh_fallback_hints || true
  fi
else
  echo -e "${DIM}Skipping SSH fallback. You can enable it later from: SSH fallback -> Configure.${RST}"
fi
return 1

  fi

  pause
  return 0
}

