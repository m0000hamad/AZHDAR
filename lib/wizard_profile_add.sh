# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Profile add wizard --------------------
wg_account_prompt_and_import(){
  WG_MODE="account"
  OUT_SSH_HOST=""
  OUT_SSH_PORT="22"
  OUT_SSH_USER="root"
  OUT_SSH_IDENTITY=""
  OUT_SSH_PASS=""
  SSH_USE_MASTER="0"
  SSH_MIMIC_MGMT_ENABLE="0"
  REMOTE_WAN_IF=""
  IR_LOCAL_IP=""
  OUT_LOCAL_IP=""
  FORWARD_TCP_PORTS=""
  FORWARD_UDP_PORTS=""
  FORWARD_DST_IP=""
  VLESS_DST_PORT="${VLESS_DST_PORT:-2086}"

  echo
  echo -e "${BOLD}${WHT}WireGuard account import${RST}"
  hr
  echo -e "${DIM}Paste the full WireGuard account config. Finish with a line containing only END.${RST}"
  local line buf=""
  while IFS= read -r line; do
    [[ "$line" == "END" ]] && break
    buf+="$line"$'\n'
  done
  buf="${buf%$'\n'}"
  [[ -n "$buf" ]] || die "No WireGuard config pasted."
  printf "%s\n" "$buf" | grep -q '^\[Interface\]' || die "Invalid config: missing [Interface]."
  printf "%s\n" "$buf" | grep -q '^\[Peer\]' || die "Invalid config: missing [Peer]."

  WG_ACCOUNT_CONFIG="$buf"
  wg_account_apply_runtime_vars
  [[ -n "${WG_ACCOUNT_ENDPOINT:-}" ]] || WG_ACCOUNT_ENDPOINT="$(printf "%s\n" "$buf" | sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//p' | head -n1)"
  [[ -n "${WG_ACCOUNT_ALLOWEDIPS:-}" ]] || WG_ACCOUNT_ALLOWEDIPS="$(printf "%s\n" "$buf" | sed -n 's/^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*//p' | head -n1)"

  echo
  echo -e "${BOLD}${WHT}Forwarding over this tunnel${RST}"
  hr
  echo -e "${DIM}Choose which public ports on this server should be forwarded into the imported WireGuard tunnel.${RST}"
  while true; do
    read -rp "Public TCP port(s) to forward (comma-separated, empty=none) [${FORWARD_TCP_PORTS}]: " FORWARD_TCP_PORTS || true
    FORWARD_TCP_PORTS="${FORWARD_TCP_PORTS:-}"
    read -rp "Public UDP port(s) to forward (comma-separated, empty=none) [${FORWARD_UDP_PORTS}]: " FORWARD_UDP_PORTS || true
    FORWARD_UDP_PORTS="${FORWARD_UDP_PORTS:-}"
    if [[ -n "${FORWARD_TCP_PORTS}${FORWARD_UDP_PORTS}" ]]; then
      FORWARD_DST_IP="$(prompt_ipv4 "Destination IPv4 inside tunnel" "${FORWARD_DST_IP:-}")"
      VLESS_DST_PORT="$(prompt_port "Destination port inside tunnel" "${VLESS_DST_PORT:-2086}")"
    else
      FORWARD_DST_IP=""
    fi
    ports_validate_current_or_warn && break
    warn "One of the forward ports conflicts with another profile. Please re-enter only the forwarding ports, or leave them empty to disable forwarding."
  done

  local meta=""
  [[ -n "${FORWARD_TCP_PORTS:-}" ]] && meta+=$'\n# AZHDAR_FORWARD_TCP_PORTS='"${FORWARD_TCP_PORTS}"
  [[ -n "${FORWARD_UDP_PORTS:-}" ]] && meta+=$'\n# AZHDAR_FORWARD_UDP_PORTS='"${FORWARD_UDP_PORTS}"
  [[ -n "${VLESS_DST_PORT:-}" && -n "${FORWARD_TCP_PORTS:-}${FORWARD_UDP_PORTS:-}" ]] && meta+=$'\n# AZHDAR_DST_PORT='"${VLESS_DST_PORT}"
  [[ -n "${FORWARD_DST_IP:-}" ]] && meta+=$'\n# AZHDAR_FORWARD_DST_IP='"${FORWARD_DST_IP}"
  WG_ACCOUNT_CONFIG="$buf$meta"
  wg_account_apply_runtime_vars
  ok "WireGuard account config imported and forwarding saved."
}


profile_add_wizard(){
  banner
  echo -e "${BOLD}${WHT}Add new server profile${RST}"
  hr

  local name
  name="$(prompt_nonempty "Profile name / WG interface (e.g. wg0, wg1)" "wg0")"
  name="$(safe_name "$name")"
  [[ -n "$name" ]] || die "Invalid profile name."

  if [[ -f "$(profile_path "$name")" ]]; then
    die "Profile already exists: $name"
  fi
  if ip link show "$name" >/dev/null 2>&1; then
    warn "An interface named '${name}' already exists on this host."
    warn "If it belongs to another setup, choose a different profile name."
  fi

  PROFILE="$name"
  WG_IF="$name"
  # set minimal defaults
  IR_PUBLIC_IP=""
  OUT_PUBLIC_IP=""
  OUT_SSH_HOST=""
  OUT_SSH_PORT="22"
  OUT_SSH_USER="root"
  OUT_SSH_IDENTITY=""
  OUT_SSH_PASS=""
  SSH_USE_MASTER="1"
  WG_PORT="443"
  TUN_SUBNET="10.66.66.0/24"
  IR_WG_IP="10.66.66.1"
  OUT_WG_IP="10.66.66.2"
  ENABLE_TUN_IPV4="1"
  ENABLE_TUN_IPV6="1"
  TUN_SUBNET6="fd00:66::/64"
  IR_WG_IP6="fd00:66::1"
  OUT_WG_IP6="fd00:66::2"
  TUN_IP_ASSIGN="auto"
  USE_PSK="1"
  PSK_VALUE=""
  MTU_MODE="manual"
  MTU="1272"
  KEEPALIVE="25"
  FORWARD_TCP_PORTS=""
  FORWARD_UDP_PORTS=""
  VLESS_DST_PORT="2086"
  IR_LOCAL_IP=""
  OUT_LOCAL_IP=""
  PROFILE_ENABLED="0"
  WG_MODE="classic"
  WG_ACCOUNT_CONFIG=""
  WG_ACCOUNT_ENDPOINT=""
  WG_ACCOUNT_ALLOWEDIPS=""

  echo
  echo -e "${BOLD}${WHT}Profile mode${RST}"
  hr
  echo " 1) Classic peer mode (SSH + remote setup)"
  echo " 2) WireGuard account mode (import config, no remote setup)"
  local mode_sel=""
  read -rp "Select [1]: " mode_sel || true
  mode_sel="${mode_sel:-1}"
  if [[ "$mode_sel" == "2" ]]; then
    wg_account_prompt_and_import
    profile_save
    CURRENT_PROFILE="$PROFILE"
    save_global
    ok "Profile created and selected: ${PROFILE} [account]"
    pause
    return 0
  fi

  # collect remote ssh and do quick preflight to suggest port
  OUT_SSH_HOST="$(prompt_host "OUT server host (SSH)" "")"
  OUT_PUBLIC_IP="$OUT_SSH_HOST"
  OUT_SSH_PORT="$(prompt_port "OUT SSH port" "22")"
  OUT_SSH_USER="$(prompt_nonempty "OUT SSH user" "root")"
  read -rsp "OUT SSH password : " _pw || true
  echo
  OUT_SSH_PASS="${_pw:-}"
  read -rp "OUT SSH identity file (optional) [none]: " ident || true
  ident="${ident:-}"
  ident="${ident//$'\r'/}"
  ident="${ident//$'\n'/}"
  OUT_SSH_IDENTITY="${ident:-}"
  # A newly-created classic profile must validate public/direct SSH first.
  # Do not try the default tunnel IP as a fallback before the tunnel exists.
  SSH_MGMT_TRANSPORT="direct"
  SSH_MGMT_LAST_TRANSPORT=""
  SSH_MGMT_LAST_HOST=""
  SSH_MGMT_LAST_PORT=""

  # if password provided but sshpass missing, try to install it robustly.
  if [[ -n "${OUT_SSH_PASS:-}" ]] && ! have_cmd sshpass; then
    warn "sshpass not found; installing (for password-based non-interactive SSH)..."
    if ssh_ensure_sshpass_for_password; then
      ok "sshpass is ready."
    else
      warn "sshpass is still missing; AZHDAR will use a real interactive SSH prompt for the preflight instead of calling the password wrong."
    fi
  fi

  # Determine REMOTE_SUDO and suggest a port
  if ssh_check; then
    # remote_preflight will also validate; but for add we keep it light and do full preflight later on install
    remote_preflight || true
    local sug
    sug="$(suggest_wg_port || true)"
    if [[ -n "$sug" ]]; then
      WG_PORT="$sug"
      info "Suggested tunnel port: ${WG_PORT}"
    fi
  else
    warn "SSH not reachable now; port suggestion may be inaccurate."
  fi

  profile_save
  CURRENT_PROFILE="$PROFILE"
  save_global
  ok "Profile created and selected: ${PROFILE}"
  pause
}

