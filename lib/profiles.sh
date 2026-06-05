# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Profiles --------------------
# Each profile file is a bash-compatible env file under $PROFILE_DIR/<name>.env

profile_path(){ echo "${PROFILE_DIR}/$1.env"; }

# Lightweight existence check (avoids triggering ERR trap via profile_load failures)
profile_exists(){ [[ -f "$(profile_path "$1")" ]]; }

profiles_list(){
  local f name
  shopt -s nullglob
  for f in "${PROFILE_DIR}"/*.env; do
    name="${f##*/}"
    name="${name%.env}"
    echo "$name"
  done
  shopt -u nullglob
}

GLOBAL_CURRENT=""

load_global(){
  [[ -f "$GLOBAL_STATE" ]] || return 0
  # Safely source global state even if it contains unescaped $ (nounset would otherwise abort).
  local _opts; _opts="$(set +o)"
  set +e +u
  # shellcheck disable=SC1090
  source "$GLOBAL_STATE" 2>/dev/null || true
  eval "${_opts}"
  azhdar_normalize_update_base_url 2>/dev/null || true
  azhdar_normalize_asset_mirror_base 2>/dev/null || true
  GLOBAL_CURRENT="${CURRENT_PROFILE:-}"
}

save_global(){
  azhdar_normalize_update_base_url 2>/dev/null || true
  {
    printf 'CURRENT_PROFILE=%s\n' "$(q "${CURRENT_PROFILE:-}")"
    printf 'UPDATE_BASE_URL=%s\n' "$(q "${UPDATE_BASE_URL:-}")"
  } >"$GLOBAL_STATE"
  chmod 600 "$GLOBAL_STATE" 2>/dev/null || true
}

# Active profile vars (loaded from env file)
PROFILE=""
WG_IF=""
SIDE="IR"
IR_PUBLIC_IP=""
OUT_PUBLIC_IP=""
OUT_PRIVKEY=""   # only used for offline remote bundle (stored locally)
OUT_PUBKEY=""    # cached remote WG pubkey (optional)
IR_PUBKEY=""     # cached local WG pubkey (optional)
OUT_SSH_HOST=""
OUT_SSH_PORT="22"
IR_SSH_PORT="22"   # SSH port on this IR server to keep OUTSIDE tunnels/forwarding
OUT_SSH_USER="root"
OUT_SSH_IDENTITY=""
OUT_SSH_PASS=""
SSH_USE_MASTER="0"
SSH_MGMT_TRANSPORT="auto"   # auto | direct | wg (script SSH management path)
SSH_MGMT_LAST_TRANSPORT=""
SSH_MGMT_LAST_HOST=""
SSH_MGMT_LAST_PORT=""
SSH_CONTROL_PATH=""
SSH_KNOWN_HOSTS_FILE=""

REMOTE_SUDO=""   # computed when needed ("" or "sudo -n")
REMOTE_SUDO_DETECTED="0"
REMOTE_WAN_IF=""

WG_PORT="443"
TUN_SUBNET="10.66.66.0/24"
IR_WG_IP="10.66.66.1"
OUT_WG_IP="10.66.66.2"
ENABLE_TUN_IPV4="1"

ENABLE_TUN_IPV6="0"
TUN_SUBNET6="fd00:66::/64"
IR_WG_IP6="fd00:66::1"
OUT_WG_IP6="fd00:66::2"

TUN_IP_ASSIGN="auto"  # auto | manual

USE_PSK="1"
PSK_VALUE=""
MTU_MODE="manual"
MTU="1272"
KEEPALIVE="25"

FORWARD_TCP_PORTS="443"
FORWARD_UDP_PORTS=""
FORWARD_DST_IP=""   # default: OUT_WG_IP
VLESS_DST_PORT="2086"

IR_LOCAL_IP=""
OUT_LOCAL_IP=""

PROFILE_ENABLED="0"  # 1 when installed/enabled
TUNNEL_AUTO_REPAIR="0"       # 1 to let azhdar-watchdog repair this profile automatically
TUNNEL_AUTO_REPAIR_FAILS="2" # failed checks before auto repair
TUNNEL_AUTO_REPAIR_COOLDOWN="600" # seconds between automatic repairs
WG_MODE="classic"      # classic | account
WG_ACCOUNT_CONFIG=""
WG_ACCOUNT_ENDPOINT=""
WG_ACCOUNT_ALLOWEDIPS=""

SSH_FALLBACK_ENABLED="0"    # 1 to enable SSH reverse-tunnel fallback (TCP only)
SSH_FALLBACK_AUTOSTART="1"  # 1 to keep it running via systemd (autossh)
SSH_FALLBACK_AUTO_ON_WG_FAIL="1"  # 1: auto-enable fallback when WG fails in wizard
SSH_FALLBACK_AUTO_ON_WG_DROP="0"  # 1: watchdog auto-failover when WG drops later
SSH_FALLBACK_BIND="0.0.0.0" # bind address on OUT for -R forwards (0.0.0.0 requires GatewayPorts yes on OUT)
# Comma-separated mappings: OUTPORT=IRHOST:IRPORT  (e.g. "2087=127.0.0.1:2087,443=127.0.0.1:8443")
SSH_FWD_TCP_MAP=""
SSH_FALLBACK_TRANSPORT="direct"

defaults_profile(){
  SIDE="${SIDE:-IR}"
  OUT_PRIVKEY="${OUT_PRIVKEY:-}"
  OUT_PUBKEY="${OUT_PUBKEY:-}"
  IR_PUBKEY="${IR_PUBKEY:-}"
  OUT_SSH_PORT="${OUT_SSH_PORT:-22}"
  IR_SSH_PORT="${IR_SSH_PORT:-22}"
  OUT_SSH_USER="${OUT_SSH_USER:-root}"
  SSH_USE_MASTER="${SSH_USE_MASTER:-0}"
  SSH_MGMT_TRANSPORT="${SSH_MGMT_TRANSPORT:-auto}"
  SSH_MGMT_LAST_TRANSPORT="${SSH_MGMT_LAST_TRANSPORT:-}"
  SSH_MGMT_LAST_HOST="${SSH_MGMT_LAST_HOST:-}"
  SSH_MGMT_LAST_PORT="${SSH_MGMT_LAST_PORT:-}"
  SSH_KNOWN_HOSTS_FILE=""
  SSH_MIMIC_MGMT_ENABLE="${SSH_MIMIC_MGMT_ENABLE:-1}"
  WG_PORT="${WG_PORT:-443}"
  TUN_SUBNET="${TUN_SUBNET:-10.66.66.0/24}"
  IR_WG_IP="${IR_WG_IP:-10.66.66.1}"
  OUT_WG_IP="${OUT_WG_IP:-10.66.66.2}"
  ENABLE_TUN_IPV4="${ENABLE_TUN_IPV4:-1}"
  ENABLE_TUN_IPV6="${ENABLE_TUN_IPV6:-0}"
  TUN_SUBNET6="${TUN_SUBNET6:-fd00:66::/64}"
  IR_WG_IP6="${IR_WG_IP6:-fd00:66::1}"
  OUT_WG_IP6="${OUT_WG_IP6:-fd00:66::2}"
  TUN_IP_ASSIGN="${TUN_IP_ASSIGN:-auto}"
  REMOTE_WAN_IF="${REMOTE_WAN_IF:-}"
  USE_PSK="${USE_PSK:-1}"
  MTU_MODE="${MTU_MODE:-manual}"
  MTU="${MTU:-1272}"
  KEEPALIVE="${KEEPALIVE:-25}"
  FORWARD_TCP_PORTS="${FORWARD_TCP_PORTS:-443}"
  FORWARD_UDP_PORTS="${FORWARD_UDP_PORTS:-}"
  FORWARD_DST_IP="${FORWARD_DST_IP:-}"
  VLESS_DST_PORT="${VLESS_DST_PORT:-2086}"
  SSH_FALLBACK_ENABLED="${SSH_FALLBACK_ENABLED:-0}"
  SSH_FALLBACK_AUTOSTART="${SSH_FALLBACK_AUTOSTART:-1}"
  SSH_FALLBACK_AUTO_ON_WG_FAIL="${SSH_FALLBACK_AUTO_ON_WG_FAIL:-1}"
  SSH_FALLBACK_AUTO_ON_WG_DROP="${SSH_FALLBACK_AUTO_ON_WG_DROP:-0}"
  SSH_FALLBACK_MODE="${SSH_FALLBACK_MODE:-local}"
  SSH_FALLBACK_TRANSPORT="${SSH_FALLBACK_TRANSPORT:-direct}"
  # Back-compat: SSH_FALLBACK_BIND is the old "bind on OUT" for reverse mode.
  SSH_FALLBACK_BIND="${SSH_FALLBACK_BIND:-0.0.0.0}"
  SSH_FALLBACK_BIND_OUT="${SSH_FALLBACK_BIND_OUT:-${SSH_FALLBACK_BIND:-0.0.0.0}}"
  SSH_FALLBACK_BIND_IR="${SSH_FALLBACK_BIND_IR:-0.0.0.0}"
  SSH_FWD_TCP_MAP="${SSH_FWD_TCP_MAP:-}"
  PROFILE_ENABLED="${PROFILE_ENABLED:-0}"
  TUNNEL_AUTO_REPAIR="${TUNNEL_AUTO_REPAIR:-0}"
  TUNNEL_AUTO_REPAIR_FAILS="${TUNNEL_AUTO_REPAIR_FAILS:-2}"
  TUNNEL_AUTO_REPAIR_COOLDOWN="${TUNNEL_AUTO_REPAIR_COOLDOWN:-600}"
  WG_MODE="${WG_MODE:-classic}"
  WG_ACCOUNT_CONFIG="${WG_ACCOUNT_CONFIG:-}"
  WG_ACCOUNT_ENDPOINT="${WG_ACCOUNT_ENDPOINT:-}"
  WG_ACCOUNT_ALLOWEDIPS="${WG_ACCOUNT_ALLOWEDIPS:-}"
}

profile_load(){
  local name="$1"
  local f; f="$(profile_path "$name")"
  [[ -f "$f" ]] || return 1
  # reset to clean defaults first
  PROFILE="$name"
  WG_IF="$name"
  SIDE="IR"
  IR_PUBLIC_IP=""
  OUT_PUBLIC_IP=""
  OUT_PRIVKEY=""
  OUT_PUBKEY=""
  IR_PUBKEY=""
  OUT_SSH_HOST=""
  OUT_SSH_PORT="22"
  IR_SSH_PORT="22"
  OUT_SSH_USER="root"
  OUT_SSH_IDENTITY=""
  OUT_SSH_PASS=""
  SSH_USE_MASTER="0"
  SSH_MGMT_TRANSPORT="auto"
  SSH_MGMT_LAST_TRANSPORT=""
  SSH_MGMT_LAST_HOST=""
  SSH_MGMT_LAST_PORT=""
  SSH_MIMIC_MGMT_ENABLE="1"
  SSH_CONTROL_PATH=""
  SSH_KNOWN_HOSTS_FILE=""
  REMOTE_SUDO=""
  REMOTE_SUDO_DETECTED="0"
  REMOTE_WAN_IF=""
  WG_PORT="443"
  TUN_SUBNET="10.66.66.0/24"
  IR_WG_IP="10.66.66.1"
  OUT_WG_IP="10.66.66.2"
  ENABLE_TUN_IPV4="1"
  ENABLE_TUN_IPV6="0"
  TUN_SUBNET6="fd00:66::/64"
  IR_WG_IP6="fd00:66::1"
  OUT_WG_IP6="fd00:66::2"
  TUN_IP_ASSIGN="auto"
  USE_PSK="1"
  PSK_VALUE=""
  MTU_MODE="manual"
  MTU="1272"
  KEEPALIVE="25"
  FORWARD_TCP_PORTS="443"
  FORWARD_UDP_PORTS=""
  FORWARD_DST_IP=""
  VLESS_DST_PORT="2086"
  IR_LOCAL_IP=""
  OUT_LOCAL_IP=""
  PROFILE_ENABLED="0"
  TUNNEL_AUTO_REPAIR="0"
  TUNNEL_AUTO_REPAIR_FAILS="2"
  TUNNEL_AUTO_REPAIR_COOLDOWN="600"
  WG_MODE="classic"
  WG_ACCOUNT_CONFIG=""
  WG_ACCOUNT_ENDPOINT=""
  WG_ACCOUNT_ALLOWEDIPS=""
  SSH_FALLBACK_ENABLED="0"
  SSH_FALLBACK_AUTOSTART="1"
  SSH_FALLBACK_AUTO_ON_WG_FAIL="1"
  SSH_FALLBACK_AUTO_ON_WG_DROP="0"
  SSH_FALLBACK_MODE="local"
  SSH_FALLBACK_TRANSPORT="direct"
  SSH_FALLBACK_BIND="0.0.0.0"
  SSH_FALLBACK_BIND_OUT="0.0.0.0"
  SSH_FALLBACK_BIND_IR="0.0.0.0"
  SSH_FWD_TCP_MAP=""
  SSH_FALLBACK_TRANSPORT="direct"

  # Safely source profile even if fields contain $ or backticks (e.g. SSH passwords / paths).
  # We also suppress errors to keep UI usable; user can re-enter values via wizards.
  local _opts; _opts="$(set +o)"
  set +e +u
  # shellcheck disable=SC1090
  source "$f" 2>/dev/null || true
  eval "${_opts}"
  defaults_profile

  # Per-profile firewall rule marker (used by iptables -m comment).
  RULE_TAG="${TAG}:${PROFILE}"
  return 0
}

profile_save(){
  [[ -n "${PROFILE:-}" ]] || die "No active profile."
  local f; f="$(profile_path "$PROFILE")"
  mkdir -p "$(dirname "$f")" || die "Cannot create profile dir: $(dirname "$f")"
  {
    echo "# Generated by AZHDAR v${SCRIPT_VERSION} (m0000hamad)"
    echo
    printf 'PROFILE=%s\n' "$(q "${PROFILE}")"
    printf 'WG_IF=%s\n' "$(q "${WG_IF}")"
    printf 'SIDE=%s\n' "$(q "${SIDE}")"
    echo
    printf 'IR_PUBLIC_IP=%s\n' "$(q "${IR_PUBLIC_IP}")"
    printf 'OUT_PUBLIC_IP=%s\n' "$(q "${OUT_PUBLIC_IP}")"
    printf 'OUT_PRIVKEY=%s\n' "$(q "${OUT_PRIVKEY:-}")"
    printf 'OUT_PUBKEY=%s\n' "$(q "${OUT_PUBKEY:-}")"
    printf 'IR_PUBKEY=%s\n' "$(q "${IR_PUBKEY:-}")"
    echo
    printf 'OUT_SSH_HOST=%s\n' "$(q "${OUT_SSH_HOST}")"
    printf 'OUT_SSH_PORT=%s\n' "$(q "${OUT_SSH_PORT}")"
    printf 'IR_SSH_PORT=%s\n' "$(q "${IR_SSH_PORT:-22}")"
    printf 'OUT_SSH_USER=%s\n' "$(q "${OUT_SSH_USER}")"
    printf 'OUT_SSH_IDENTITY=%s\n' "$(q "${OUT_SSH_IDENTITY}")"
    printf 'OUT_SSH_PASS=%s\n' "$(q "${OUT_SSH_PASS}")"
    printf 'SSH_USE_MASTER=%s\n' "$(q "${SSH_USE_MASTER:-0}")"
    printf 'SSH_MGMT_TRANSPORT=%s\n' "$(q "${SSH_MGMT_TRANSPORT:-auto}")"
    printf 'SSH_MGMT_LAST_TRANSPORT=%s\n' "$(q "${SSH_MGMT_LAST_TRANSPORT:-}")"
    printf 'SSH_MGMT_LAST_HOST=%s\n' "$(q "${SSH_MGMT_LAST_HOST:-}")"
    printf 'SSH_MGMT_LAST_PORT=%s\n' "$(q "${SSH_MGMT_LAST_PORT:-}")"
    printf 'SSH_MIMIC_MGMT_ENABLE=%s\n' "$(q "${SSH_MIMIC_MGMT_ENABLE:-1}")"
    echo
    printf 'REMOTE_WAN_IF=%s\n' "$(q "${REMOTE_WAN_IF}")"
    echo
    printf 'WG_PORT=%s\n' "$(q "${WG_PORT}")"
    echo
    printf 'TUN_SUBNET=%s\n' "$(q "${TUN_SUBNET}")"
    printf 'IR_WG_IP=%s\n' "$(q "${IR_WG_IP}")"
    printf 'OUT_WG_IP=%s\n' "$(q "${OUT_WG_IP}")"
    echo
    printf 'ENABLE_TUN_IPV4=%s\n' "$(q "${ENABLE_TUN_IPV4}")"
    echo
    printf 'ENABLE_TUN_IPV6=%s\n' "$(q "${ENABLE_TUN_IPV6}")"
    printf 'TUN_SUBNET6=%s\n' "$(q "${TUN_SUBNET6}")"
    printf 'IR_WG_IP6=%s\n' "$(q "${IR_WG_IP6}")"
    printf 'OUT_WG_IP6=%s\n' "$(q "${OUT_WG_IP6}")"
    echo
    printf 'TUN_IP_ASSIGN=%s\n' "$(q "${TUN_IP_ASSIGN}")"
    echo
    printf 'USE_PSK=%s\n' "$(q "${USE_PSK}")"
    printf 'PSK_VALUE=%s\n' "$(q "${PSK_VALUE}")"
    echo
    printf 'MTU_MODE=%s\n' "$(q "${MTU_MODE}")"
    printf 'MTU=%s\n' "$(q "${MTU}")"
    printf 'KEEPALIVE=%s\n' "$(q "${KEEPALIVE}")"
    echo
    printf 'FORWARD_TCP_PORTS=%s
' "$(q "${FORWARD_TCP_PORTS}")"
    printf 'FORWARD_UDP_PORTS=%s
' "$(q "${FORWARD_UDP_PORTS}")"
    printf 'FORWARD_DST_IP=%s
' "$(q "${FORWARD_DST_IP:-}")"
    printf 'VLESS_DST_PORT=%s
' "$(q "${VLESS_DST_PORT}")"
    echo
    printf 'IR_LOCAL_IP=%s\n' "$(q "${IR_LOCAL_IP}")"
    printf 'OUT_LOCAL_IP=%s\n' "$(q "${OUT_LOCAL_IP}")"
    echo
    # SSH fallback (TCP-only)
    printf 'SSH_FALLBACK_ENABLED=%s\n' "$(q "${SSH_FALLBACK_ENABLED:-0}")"
    printf 'SSH_FALLBACK_AUTOSTART=%s\n' "$(q "${SSH_FALLBACK_AUTOSTART:-0}")"
    printf 'SSH_FALLBACK_AUTO_ON_WG_FAIL=%s\n' "$(q "${SSH_FALLBACK_AUTO_ON_WG_FAIL:-1}")"
    printf 'SSH_FALLBACK_MODE=%s\n' "$(q "${SSH_FALLBACK_MODE:-local}")"
    printf 'SSH_FALLBACK_BIND=%s\n' "$(q "${SSH_FALLBACK_BIND:-0.0.0.0}")"
    printf 'SSH_FALLBACK_BIND_OUT=%s\n' "$(q "${SSH_FALLBACK_BIND_OUT:-0.0.0.0}")"
    printf 'SSH_FALLBACK_BIND_IR=%s\n' "$(q "${SSH_FALLBACK_BIND_IR:-0.0.0.0}")"
    printf 'SSH_FWD_TCP_MAP=%s\n' "$(q "${SSH_FWD_TCP_MAP:-}")"
    echo
    printf 'PROFILE_ENABLED=%s\n' "$(q "${PROFILE_ENABLED}")"
    printf 'TUNNEL_AUTO_REPAIR=%s\n' "$(q "${TUNNEL_AUTO_REPAIR:-0}")"
    printf 'TUNNEL_AUTO_REPAIR_FAILS=%s\n' "$(q "${TUNNEL_AUTO_REPAIR_FAILS:-2}")"
    printf 'TUNNEL_AUTO_REPAIR_COOLDOWN=%s\n' "$(q "${TUNNEL_AUTO_REPAIR_COOLDOWN:-600}")"
    printf 'WG_MODE=%s\n' "$(q "${WG_MODE:-classic}")"
    printf 'WG_ACCOUNT_CONFIG=%s\n' "$(q "${WG_ACCOUNT_CONFIG:-}")"
    printf 'WG_ACCOUNT_ENDPOINT=%s\n' "$(q "${WG_ACCOUNT_ENDPOINT:-}")"
    printf 'WG_ACCOUNT_ALLOWEDIPS=%s\n' "$(q "${WG_ACCOUNT_ALLOWEDIPS:-}")"
  } >"$f"
  chmod 600 "$f" 2>/dev/null || true
  ok "Saved profile: ${PROFILE}"
}

# Helper: set a profile variable and persist
profile_set(){
  local k="$1" v="$2"
  [[ -n "$k" ]] || return 1
  # Assign to shell variable named by k
  printf -v "$k" "%s" "$v"
  profile_save
}

# Apply MTU persistently (best-effort). Some script variants call this helper.
mtu_apply_persistent(){
  MTU_MODE="auto"
  if profile_save; then
    ok "Profile saved: MTU_MODE=${MTU_MODE}, MTU=${MTU:-?}, Keepalive=${KEEPALIVE:-?}."
  else
    err "Profile save failed; MTU was not persisted."
    return 1
  fi
  apply_wg_configs_mtu_safe
}

# Patch WireGuard config for MTU/Keepalive without requiring peer keys and without restarting.
# Return codes: 0=patched, 1=failed, 2=config missing/skipped.
wg_patch_conf_mtu_keepalive_local(){
  local cfg="/etc/wireguard/${WG_IF}.conf"
  [[ -n "${WG_IF:-}" && -n "${MTU:-}" && -n "${KEEPALIVE:-}" ]] || return 1
  [[ -f "$cfg" ]] || return 2
  backup_file "$cfg" 2>/dev/null || true
  if grep -qi '^[[:space:]]*MTU[[:space:]]*=' "$cfg" 2>/dev/null; then
    sed -i -E "s|^[[:space:]]*MTU[[:space:]]*=.*|MTU = ${MTU}|I" "$cfg" 2>/dev/null || return 1
  else
    awk -v mtu="$MTU" 'BEGIN{done=0} /^\[Peer\]/{if(!done){print "MTU = " mtu; done=1} } {print} END{if(!done) print "MTU = " mtu}' "$cfg" >"${cfg}.tmp.$$" && mv "${cfg}.tmp.$$" "$cfg" || return 1
  fi
  if grep -qi '^[[:space:]]*PersistentKeepalive[[:space:]]*=' "$cfg" 2>/dev/null; then
    sed -i -E "s|^[[:space:]]*PersistentKeepalive[[:space:]]*=.*|PersistentKeepalive = ${KEEPALIVE}|I" "$cfg" 2>/dev/null || return 1
  else
    printf '\nPersistentKeepalive = %s\n' "$KEEPALIVE" >>"$cfg" || return 1
  fi
  chmod 600 "$cfg" 2>/dev/null || true
  return 0
}

# Runtime apply return codes: 0=applied, 1=failed/partial, 2=interface down/skipped.
wg_apply_runtime_mtu_keepalive_local(){
  local failed=0 peer=""
  if ip link show "${WG_IF}" >/dev/null 2>&1; then
    ip link set dev "${WG_IF}" mtu "${MTU}" >/dev/null 2>&1 || failed=1
  else
    return 2
  fi
  if have_cmd wg; then
    peer="$(wg show "${WG_IF}" peers 2>/dev/null | head -n1 || true)"
    if [[ -n "$peer" ]]; then
      wg set "${WG_IF}" peer "$peer" persistent-keepalive "${KEEPALIVE}" >/dev/null 2>&1 || failed=1
    else
      # MTU was set, but no peer means keepalive could not be applied live.
      failed=1
    fi
  else
    failed=1
  fi
  return "$failed"
}

wg_apply_mtu_keepalive_remote_best_effort(){
  [[ "${WG_MODE:-classic}" != "account" ]] || { info "OUT server MTU/Keepalive: skipped in account mode."; return 0; }
  if ! ssh_check_quiet >/dev/null 2>&1; then
    warn "OUT server MTU/Keepalive: SSH unavailable; remote apply skipped."
    return 1
  fi

  local out="" rc=0
  out="$(ssh_run_stdin_env_root_best_effort "WG_IF=${WG_IF}" "MTU=${MTU}" "KEEPALIVE=${KEEPALIVE}" <<'REMOTE' 2>/dev/null
set +e
failed=0
cfg_status="missing"
runtime_status="interface-down"

cfg="/etc/wireguard/${WG_IF}.conf"
if [ -f "$cfg" ]; then
  cp -a "$cfg" "$cfg.bak.$(date +%s)" 2>/dev/null || true
  cfg_ok=1
  if grep -qi '^[[:space:]]*MTU[[:space:]]*=' "$cfg" 2>/dev/null; then
    sed -i -E "s|^[[:space:]]*MTU[[:space:]]*=.*|MTU = ${MTU}|I" "$cfg" 2>/dev/null || cfg_ok=0
  else
    awk -v mtu="$MTU" 'BEGIN{done=0} /^\[Peer\]/{if(!done){print "MTU = " mtu; done=1} } {print} END{if(!done) print "MTU = " mtu}' "$cfg" >"$cfg.tmp.$$" && mv "$cfg.tmp.$$" "$cfg" || cfg_ok=0
  fi
  if grep -qi '^[[:space:]]*PersistentKeepalive[[:space:]]*=' "$cfg" 2>/dev/null; then
    sed -i -E "s|^[[:space:]]*PersistentKeepalive[[:space:]]*=.*|PersistentKeepalive = ${KEEPALIVE}|I" "$cfg" 2>/dev/null || cfg_ok=0
  else
    printf '\nPersistentKeepalive = %s\n' "$KEEPALIVE" >>"$cfg" 2>/dev/null || cfg_ok=0
  fi
  chmod 600 "$cfg" 2>/dev/null || true
  if [ "$cfg_ok" -eq 1 ]; then cfg_status="patched"; else cfg_status="failed"; failed=1; fi
else
  failed=1
fi

if ip link show "$WG_IF" >/dev/null 2>&1; then
  if ip link set dev "$WG_IF" mtu "$MTU" >/dev/null 2>&1; then
    runtime_status="mtu-applied"
  else
    runtime_status="mtu-failed"
    failed=1
  fi
  if command -v wg >/dev/null 2>&1; then
    peer="$(wg show "$WG_IF" peers 2>/dev/null | head -n1 || true)"
    if [ -n "$peer" ]; then
      if wg set "$WG_IF" peer "$peer" persistent-keepalive "$KEEPALIVE" >/dev/null 2>&1; then
        runtime_status="${runtime_status}+keepalive-applied"
      else
        runtime_status="${runtime_status}+keepalive-failed"
        failed=1
      fi
    else
      runtime_status="${runtime_status}+no-peer"
      failed=1
    fi
  else
    runtime_status="${runtime_status}+wg-missing"
    failed=1
  fi
else
  failed=1
fi

echo "config=${cfg_status};runtime=${runtime_status}"
exit "$failed"
REMOTE
)"; rc=$?

  out="$(printf '%s' "$out" | tr -d '\r' | tail -n1)"
  if (( rc == 0 )); then
    ok "OUT server MTU/Keepalive applied: ${out:-ok}."
  else
    warn "OUT server MTU/Keepalive not fully applied: ${out:-no status}."
  fi
  return "$rc"
}

# Apply WG MTU/Keepalive tweaks safely.
# Important: do NOT call the full WireGuard apply here. Full apply may rewrite keys,
# restart Mimic/WG, and cut the only management path. MTU/Keepalive can be patched
# live and persisted without restarting the tunnel.
apply_wg_configs_mtu_safe(){
  local _had_errexit=0
  case "$-" in *e*) _had_errexit=1; set +e ;; esac

  step "Apply MTU/Keepalive safely (no tunnel restart)"
  local failed=0 rc=0

  [[ "${MTU:-}" =~ ^[0-9]+$ ]] || { err "Invalid MTU: ${MTU:-}"; failed=1; }
  [[ "${KEEPALIVE:-}" =~ ^[0-9]+$ ]] || { err "Invalid Keepalive: ${KEEPALIVE:-}"; failed=1; }

  if (( failed == 0 )); then
    if profile_save >/dev/null 2>&1; then
      ok "Profile saved: MTU=${MTU}, Keepalive=${KEEPALIVE}, mode=${MTU_MODE:-manual}."
    else
      err "Profile save failed; config/runtime apply canceled."
      failed=1
    fi
  fi

  if (( failed == 0 )); then
    wg_patch_conf_mtu_keepalive_local; rc=$?
    case "$rc" in
      0) ok "IR server config patched: MTU=${MTU}, Keepalive=${KEEPALIVE}." ;;
      2) warn "IR server config file /etc/wireguard/${WG_IF}.conf not found; persistent local patch skipped."; failed=1 ;;
      *) err "IR server config patch failed."; failed=1 ;;
    esac

    wg_apply_runtime_mtu_keepalive_local; rc=$?
    case "$rc" in
      0) ok "IR server runtime applied: interface=${WG_IF}, MTU=${MTU}, Keepalive=${KEEPALIVE}." ;;
      2) warn "IR server runtime skipped: interface ${WG_IF} is not up."; failed=1 ;;
      *) warn "IR server runtime apply failed or partially applied."; failed=1 ;;
    esac

    wg_apply_mtu_keepalive_remote_best_effort || failed=1
  fi

  sleep 1
  if azhdar_ping_ok_quiet; then
    ok "Tunnel health confirmed after MTU/Keepalive apply."
  else
    warn "Tunnel health is not confirmed after MTU/Keepalive apply. Starting one safe repair pass."
    azhdar_repair_tunnel_limited 90 || true
    if azhdar_ping_ok_quiet; then
      ok "Tunnel became reachable after repair pass."
    else
      warn "Tunnel is still not confirmed. Use menu 13 -> Deep repair now if needed."
      failed=1
    fi
  fi

  status_cache_invalidate >/dev/null 2>&1 || true
  if (( failed == 0 )); then
    ok "RESULT: MTU/Keepalive successfully applied on IR and OUT: MTU=${MTU}, Keepalive=${KEEPALIVE}."
  else
    warn "RESULT: MTU/Keepalive saved, but one or more apply/health checks were NOT successful. See the IR/OUT lines above."
  fi

  local final_rc=0
  (( failed == 0 )) || final_rc=1
  (( _had_errexit == 1 )) && set -e
  return "$final_rc"
}


profile_delete(){
  local name="$1"
  local f; f="$(profile_path "$name")"
  [[ -f "$f" ]] || { warn "Profile not found: $name"; return 1; }
  rm -f "$f" 2>/dev/null || true
  ok "Deleted profile: $name"
  if [[ "${CURRENT_PROFILE:-}" == "$name" ]]; then
    CURRENT_PROFILE=""
    save_global
  fi
}


profile_read_var(){
  # Read a single variable from a profile env file in a subshell.
  # usage: profile_read_var <profile> <VAR>
  local name="$1" var="$2"
  local f; f="$(profile_path "$name")"
  [[ -f "$f" ]] || return 1
  ( set +e +u; source "$f" 2>/dev/null || true; eval "printf '%s' \"\${${var}:-}\"" ) 2>/dev/null
}

# Startup status cache (per-render) so we don't ping twice per profile.
declare -A STARTUP_AZ_OK
declare -A STARTUP_AZ_TAG

startup_status_cache_reset(){
  STARTUP_AZ_OK=()
  STARTUP_AZ_TAG=()
}

profile_az_state_quick(){
  # Determine the same "AZHDAR" connectivity state used by the profile status board,
  # but quickly (local checks only) to keep Startup fast.
  # Output: "<ok:0|1> <tag:wg|ssh|>"
  local name="$1"

  # Cache hit
  if [[ -n "${STARTUP_AZ_OK[$name]+x}" ]]; then
    printf "%s %s" "${STARTUP_AZ_OK[$name]}" "${STARTUP_AZ_TAG[$name]}"
    return 0
  fi

  local ok=0 tag=""

  # Read minimal vars from profile
  local wg_if enable4 enable6 out_wg_ip out_wg_ip6 ir_wg_ip ir_wg_ip6 wg_mode
  wg_if="$(profile_read_var "$name" WG_IF 2>/dev/null || true)"
  [[ -n "$wg_if" ]] || wg_if="$name"
  enable4="$(profile_read_var "$name" ENABLE_TUN_IPV4 2>/dev/null || true)"
  enable6="$(profile_read_var "$name" ENABLE_TUN_IPV6 2>/dev/null || true)"
  out_wg_ip="$(profile_read_var "$name" OUT_WG_IP 2>/dev/null || true)"
  out_wg_ip6="$(profile_read_var "$name" OUT_WG_IP6 2>/dev/null || true)"
  ir_wg_ip="$(profile_read_var "$name" IR_WG_IP 2>/dev/null || true)"
  ir_wg_ip6="$(profile_read_var "$name" IR_WG_IP6 2>/dev/null || true)"
  wg_mode="$(profile_read_var "$name" WG_MODE 2>/dev/null || true)"

  [[ -n "$enable4" ]] || enable4="1"
  [[ -n "$wg_mode" ]] || wg_mode="classic"
  [[ -n "$enable6" ]] || enable6="0"

  # Services
  local wgsvc="wg-quick@${wg_if}"
  local sshsvc="azhdar-ssh-fallback@${name}.service"
  local wg_active=0 ssh_active=0
  if command -v systemctl >/dev/null 2>&1; then
    systemctl is-active --quiet "$wgsvc" 2>/dev/null && wg_active=1 || true
    systemctl is-active --quiet "$sshsvc" 2>/dev/null && ssh_active=1 || true
  fi

  # Match status_board logic:
  # - If SSH fallback is active, treat as connected and tag ssh.
  # - Else if WG is active, require at least one local ping success to peer WG IP.
  if (( ssh_active == 1 )); then
    ok=1
    tag="ssh"
  elif (( wg_active == 1 )); then
    if [[ "$wg_mode" == "account" ]]; then
      local hs now_hs
      hs="$(wg show "$wg_if" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}' || echo 0)"
      now_hs="$(date +%s 2>/dev/null || echo 0)"
      if [[ -n "$hs" && "$hs" != "0" ]] && (( now_hs - hs <= 180 )); then
        ok=1
        tag="acct"
      fi
      STARTUP_AZ_OK[$name]="$ok"
      STARTUP_AZ_TAG[$name]="$tag"
      printf "%s %s" "$ok" "$tag"
      return 0
    fi
    # Inject tunnel source IPs so ping helpers can bind correctly.
    local IR_WG_IP="${ir_wg_ip}" IR_WG_IP6="${ir_wg_ip6}"
    local p4=0 p6=0
    if [[ "$enable4" == "1" && -n "$out_wg_ip" ]]; then
      ping4_local_once "$out_wg_ip" && p4=1 || true
    fi
    if [[ "$enable6" == "1" && -n "$out_wg_ip6" ]]; then
      ping6_local_once "$out_wg_ip6" && p6=1 || true
    fi
    if (( p4 == 1 || p6 == 1 )); then
      ok=1
      tag="wg"
    fi
  fi

  STARTUP_AZ_OK[$name]="$ok"
  STARTUP_AZ_TAG[$name]="$tag"
  printf "%s %s" "$ok" "$tag"
}

profile_is_running(){
  # Returns 0 if the profile is AZHDAR-connected (same meaning as the AZHDAR badge).
  local name="$1"
  local ok
  ok="$(profile_az_state_quick "$name" 2>/dev/null | awk '{print $1}' || echo 0)"
  [[ "$ok" == "1" ]]
}

profile_active_mode(){
  # Prints the AZHDAR transport tag for the profile when CONNECTED.
  # Output: "wg" | "ssh" (only when AZHDAR is green)
  local name="$1"

  local res ok tag
  res="$(profile_az_state_quick "$name" 2>/dev/null || echo '0')"
  ok="${res%% *}"
  tag="${res#* }"
  [[ "$tag" == "$res" ]] && tag=""
  if [[ "$ok" == "1" && -n "$tag" ]]; then
    echo "$tag"
    return 0
  fi
  return 1
}

profile_state_dot(){
  # Dim filled circle: green for AZHDAR-connected, red otherwise.
  local name="$1"
  if profile_is_running "$name"; then
    echo -e "${GRN}${DIM}●${RST}"
  else
    echo -e "${RED}${DIM}●${RST}"
  fi
}

profile_full_delete(){
  # FULL delete: local + remote cleanup, then remove the profile env file.
  # Best-effort remote cleanup; local cleanup always proceeds.
  local name="$1"
  local f; f="$(profile_path "$name")"
  [[ -f "$f" ]] || { warn "Profile not found: $name"; return 1; }

  # Preserve current interactive context.
  local prev_profile="${PROFILE:-}"
  local prev_current="${CURRENT_PROFILE:-}"

  # Load target profile (sets RULE_TAG as well).
  profile_load "$name" 2>/dev/null || true

  # Cleanup artifacts for this profile.
  cleanup_local 2>/dev/null || true
  cleanup_remote 2>/dev/null || true
  # v3.1.15: make sure old netfilter-persistent snapshots do not resurrect
  # deleted-profile rules after reboot.
  _recovery_clean_saved_iptables_local 2>/dev/null || true

  # Remove SSH fallback service for this profile (local).
  if command -v systemctl >/dev/null 2>&1; then
    local sshsvc="azhdar-ssh-fallback@${PROFILE}.service"
    systemctl stop "$sshsvc" >/dev/null 2>&1 || true
    systemctl disable "$sshsvc" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/${sshsvc}" "/etc/systemd/system/${sshsvc}.d"/* 2>/dev/null || true
    rmdir "/etc/systemd/system/${sshsvc}.d" 2>/dev/null || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  # Remove profile file.
  rm -f "$f" 2>/dev/null || true
  ok "Profile fully deleted: ${name}"

  # Update global selection if needed.
  if [[ "${prev_current:-}" == "$name" ]]; then
    CURRENT_PROFILE=""
    save_global 2>/dev/null || true
  else
    CURRENT_PROFILE="$prev_current"
  fi

  # Restore previously loaded profile variables (best-effort).
  if [[ -n "${prev_profile:-}" && "$prev_profile" != "$name" ]] && profile_exists "$prev_profile"; then
    profile_load "$prev_profile" 2>/dev/null || true
  fi
  return 0
}

profiles_full_delete_all(){
  local n
  while read -r n; do
    n="$(safe_name "$n")"
    [[ -n "$n" ]] || continue
    profile_full_delete "$n" || true
  done < <(profiles_list)
}

profile_select(){
  local names=()
  local n
  while read -r n; do
    n="$(safe_name "$n")"
    [[ -n "$n" ]] && names+=("$n")
  done < <(profiles_list)

  if (( ${#names[@]} == 0 )); then
    warn "No profiles found."
    pause
    return 1
  fi

  while true; do
    banner
    echo -e "${BOLD}${WHT}Select a server profile${RST}"
    hr
    local i=1
    for n in "${names[@]}"; do
      local mark=" "
      [[ "${CURRENT_PROFILE:-}" == "$n" ]] && mark="*"
      printf " %s %2d) %s\n" "$mark" "$i" "$n"
      i=$((i+1))
    done
    echo "  0) Back"
    hr
    local c
    read -rp "Select: " c || true
    c="${c:-}"
    case "$c" in
      0) return 0 ;;
      *)
        [[ "$c" =~ ^[0-9]+$ ]] || { warn "Invalid."; pause; continue; }
        local idx=$((c-1))
        (( idx >= 0 && idx < ${#names[@]} )) || { warn "Invalid."; pause; continue; }
        local sel="${names[$idx]}"
        if profile_load "$sel"; then
          CURRENT_PROFILE="$sel"
          save_global
          ok "Active profile: ${sel}"
          pause
          return 0
        else
          warn "Failed to load profile."
          pause
        fi
        ;;
    esac
  done
}

ensure_profile_selected(){
  # Ensure there is an active loaded profile. Returns 0 if selected, 1 if user cancels.
  if [[ -n "${PROFILE:-}" && -f "$(profile_path "$PROFILE")" ]]; then
    return 0
  fi

  # Try loading the last/current profile from global state.
  load_global 2>/dev/null || true
  if [[ -n "${CURRENT_PROFILE:-}" ]] && profile_exists "${CURRENT_PROFILE}"; then
    profile_load "${CURRENT_PROFILE}" 2>/dev/null || true
    return 0
  elif [[ -n "${CURRENT_PROFILE:-}" ]]; then
    warn "Stored CURRENT_PROFILE '${CURRENT_PROFILE}' not found; clearing selection."
    CURRENT_PROFILE=""
    save_global 2>/dev/null || true
  fi

  # If exactly one profile exists, auto-load it.
  local first second
  first="$(profiles_list | head -n1 2>/dev/null || true)"
  second="$(profiles_list | sed -n '2p' 2>/dev/null || true)"
  if [[ -n "$first" && -z "$second" ]]; then
    profile_load "$first" 2>/dev/null || true
    CURRENT_PROFILE="$first"
    save_global
    return 0
  fi

  while true; do
    banner
    echo -e "${BOLD}${WHT}Profile required${RST}"
    hr
    if [[ -n "$first" ]]; then
      echo " 1) Select existing profile"
      echo " 2) Add new profile"
      echo " 0) Back"
      hr
      local c
      c="$(read_choice "Select" "1" "2" "0")"
      case "$c" in
        1) profile_select || true ;;
        2) profile_add_wizard || true ;;
        0) return 1 ;;
      esac
    else
      echo " 1) Add new profile"
      echo " 0) Back"
      hr
      local c
      c="$(read_choice "Select" "1" "0")"
      case "$c" in
        1) profile_add_wizard || true ;;
        0) return 1 ;;
      esac
    fi

    if [[ -n "${CURRENT_PROFILE:-}" ]] && profile_exists "${CURRENT_PROFILE}"; then
      profile_load "${CURRENT_PROFILE}" 2>/dev/null || true
      return 0
    elif [[ -n "${CURRENT_PROFILE:-}" ]]; then
      warn "Stored CURRENT_PROFILE '${CURRENT_PROFILE}' not found; clearing selection."
      CURRENT_PROFILE=""
      save_global 2>/dev/null || true
    fi

    # Refresh first/second after user actions.
    first="$(profiles_list | head -n1 2>/dev/null || true)"
    second="$(profiles_list | sed -n '2p' 2>/dev/null || true)"
  done
}

startup_profile_prompt(){
  load_global
  CURRENT_PROFILE="${GLOBAL_CURRENT:-${CURRENT_PROFILE:-}}"

  # If global CURRENT_PROFILE points to a missing file, clear it.
  if [[ -n "${CURRENT_PROFILE:-}" ]] && ! profile_exists "${CURRENT_PROFILE}"; then
    warn "Stored CURRENT_PROFILE '${CURRENT_PROFILE}' not found; clearing selection."
    CURRENT_PROFILE=""
    save_global 2>/dev/null || true
  fi

  # Collect profiles
  local names=()
  local n
  while read -r n; do
    n="$(safe_name "$n")"
    [[ -n "$n" ]] && names+=("$n")
  done < <(profiles_list)

  # No profiles
  if (( ${#names[@]} == 0 )); then
    return 1
  fi

  # Non-interactive behavior:
  # - If a current profile exists, load it.
  # - Else if only one profile exists, auto-select it.
  if [[ ! -t 0 ]]; then
    if [[ -n "${CURRENT_PROFILE:-}" ]] && profile_exists "$CURRENT_PROFILE"; then
      profile_load "$CURRENT_PROFILE" 2>/dev/null || true
      return 0
    fi
    if (( ${#names[@]} == 1 )); then
      CURRENT_PROFILE="${names[0]}"
      save_global 2>/dev/null || true
      profile_load "$CURRENT_PROFILE" 2>/dev/null || true
      return 0
    fi
    return 1
  fi

  # If current profile isn't set, default to first profile.
  if [[ -z "${CURRENT_PROFILE:-}" ]]; then
    CURRENT_PROFILE="${names[0]}"
    save_global 2>/dev/null || true
  fi

  while true; do
    banner
    echo -e "${BOLD}${WHT}Startup${RST}"
    hr
    echo -e "${DIM}Last profile:${RST} ${BOLD}${CYN}${CURRENT_PROFILE:-<none>}${RST}"
    hr

    echo -e "${BOLD}${WHT}Profiles${RST}"

    startup_status_cache_reset

    local i=1
    for n in "${names[@]}"; do
      local mark=" "
      [[ "${CURRENT_PROFILE:-}" == "$n" ]] && mark="*"
      # status dot
      local dot mode suffix=""
      dot="$(profile_state_dot "$n")"
      mode="$(profile_active_mode "$n" 2>/dev/null || true)"
      if [[ -n "${mode:-}" ]]; then
        suffix=" ${GRN}${DIM}${mode}${RST}"
      fi
      printf " %s %2d) %b %s%b\n" "$mark" "$i" "$dot" "$n" "$suffix"
      i=$((i+1))
    done

    hr
    echo " a) Add new profile"
    echo " b) Delete profile (FULL)"
    echo " c) Delete ALL profiles"
    echo " d) Update AZHDAR"
    echo " e) Uninstall (keep AZHDAR)"
    echo " 0) Exit"
    hr

    local sel=""
    read -rp "Select (number or letter) [ENTER=last]: " sel || true
    sel="${sel//$'
'/}"
    sel="${sel//$'
'/}"
    sel="${sel//[[:space:]]/}"

    # ENTER defaults to last profile
    if [[ -z "$sel" ]]; then
      # ensure still exists
      if [[ -n "${CURRENT_PROFILE:-}" ]] && profile_exists "${CURRENT_PROFILE}"; then
        profile_load "${CURRENT_PROFILE}" 2>/dev/null || true
        return 0
      fi
      sel="1"
    fi

    # Numeric selection => profile index
    if [[ "$sel" =~ ^[0-9]+$ ]]; then
      local idx=$((sel))
      if (( idx >= 1 && idx <= ${#names[@]} )); then
        CURRENT_PROFILE="${names[idx-1]}"
        save_global 2>/dev/null || true
        profile_load "${CURRENT_PROFILE}" 2>/dev/null || true
        return 0
      fi
      if [[ "$sel" == "0" ]]; then
        exit 0
      fi
      warn "Invalid selection."
      pause
      continue
    fi

    case "$sel" in
      a|A)
        profile_add_wizard || true
        load_global
        CURRENT_PROFILE="${GLOBAL_CURRENT:-${CURRENT_PROFILE:-}}"
        # refresh profiles list
        names=()
        while read -r n; do
          n="$(safe_name "$n")"
          [[ -n "$n" ]] && names+=("$n")
        done < <(profiles_list)
        if [[ -n "${CURRENT_PROFILE:-}" ]] && profile_exists "${CURRENT_PROFILE}"; then
          profile_load "${CURRENT_PROFILE}" 2>/dev/null || true
          return 0
        fi
        ;;

      b|B)
        if (( ${#names[@]} == 0 )); then
          warn "No profiles found."
          pause
          continue
        fi

        local dsel=""
        read -rp "Delete which profile (number or name)? " dsel || true
        dsel="${dsel//$'
'/}"
        dsel="${dsel//$'
'/}"
        dsel="${dsel//[[:space:]]/}"

        local target=""
        if [[ "$dsel" =~ ^[0-9]+$ ]]; then
          local didx=$((dsel))
          if (( didx >= 1 && didx <= ${#names[@]} )); then
            target="${names[didx-1]}"
          fi
        else
          target="$(safe_name "$dsel")"
        fi

        if [[ -z "${target:-}" ]] || ! profile_exists "$target"; then
          warn "Profile not found."
          pause
          continue
        fi

        if [[ "$(prompt_yesno "Confirm FULL delete '${target}' (local+remote)?" "N")" == "Y" ]]; then
          profile_full_delete "$target" || true
        else
          warn "Cancelled."
        fi

        # refresh list
        names=()
        while read -r n; do
          n="$(safe_name "$n")"
          [[ -n "$n" ]] && names+=("$n")
        done < <(profiles_list)

        # If none left, return 1 so caller can offer add-new.
        if (( ${#names[@]} == 0 )); then
          CURRENT_PROFILE=""
          save_global 2>/dev/null || true
          return 1
        fi

        # If current missing, set to first.
        if [[ -n "${CURRENT_PROFILE:-}" ]] && ! profile_exists "${CURRENT_PROFILE}"; then
          CURRENT_PROFILE="${names[0]}"
          save_global 2>/dev/null || true
        fi

        pause
        ;;

      c|C)
        if [[ "$(prompt_yesno "Confirm FULL delete ALL profiles (local+remote)?" "N")" == "Y" ]]; then
          profiles_full_delete_all || true
          CURRENT_PROFILE=""
          save_global 2>/dev/null || true
          return 1
        else
          warn "Cancelled."
          pause
        fi
        ;;

      d|D)
        azhdar_update_menu || true
        pause
        ;;

      e|E)
        azhdar_uninstall_keep_manager || true
        # refresh profiles list
        names=()
        while read -r n; do
          n="$(safe_name "$n")"
          [[ -n "$n" ]] && names+=("$n")
        done < <(profiles_list)
        if (( ${#names[@]} == 0 )); then
          return 1
        fi
        pause
        ;;

      0)
        exit 0
        ;;

      *)
        warn "Invalid selection."
        pause
        ;;
    esac

    # refresh list at end of loop (safe)
    names=()
    while read -r n; do
      n="$(safe_name "$n")"
      [[ -n "$n" ]] && names+=("$n")
    done < <(profiles_list)
    if (( ${#names[@]} == 0 )); then
      return 1
    fi
  done
}


