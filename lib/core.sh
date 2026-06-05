# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Globals --------------------
SCRIPT_VERSION="3.2.9"

# TAG is used for logs and as the base marker for firewall comments.
TAG="AZHDAR"

# Firewall comment marker. For new rules, we scope it per-profile as: AZHDAR:<profile>.
# When no profile is loaded, it falls back to AZHDAR.
RULE_TAG="${TAG}"

# State directory
# - Default: /etc/azhdar
# - Legacy compatibility: if old dir exists, we transparently symlink /etc/azhdar -> legacy
DEFAULT_BASE_DIR="/etc/azhdar"
LEGACY_BASE_DIR="/etc/wireguard/m0000hamad-wg-mimic"
BASE_DIR="${AZHDAR_STATE_DIR:-$DEFAULT_BASE_DIR}"
PROFILE_DIR="${BASE_DIR}/profiles"
GLOBAL_STATE="${BASE_DIR}/global.env"
LOG_FILE="${BASE_DIR}/manager.log"

# Self-update (auto-discover latest zip from directory listing).
UPDATE_BASE_URL_DEFAULT="https://dl.digitsell.shop/share/gZ1XGygF"
UPDATE_BASE_URL="${UPDATE_BASE_URL:-$UPDATE_BASE_URL_DEFAULT}"

azhdar_normalize_update_base_url(){
  # Keep the updater independent from the Mimic asset mirror. Older installs may
  # have saved Wf-XKNL9 / legacy-IP URLs in global.env; reset only those known-bad
  # values while still allowing deliberate custom update mirrors.
  local u="${UPDATE_BASE_URL:-}"
  u="${u%/}"
  case "$u" in
    ""|*Wf-XKNL9*|*62.60.184.163*|*37.32.26.129*)
      UPDATE_BASE_URL="$UPDATE_BASE_URL_DEFAULT"
      ;;
    */api/public/dl/gZ1XGygF)
      UPDATE_BASE_URL="https://dl.digitsell.shop/share/gZ1XGygF"
      ;;
    */api/public/share/gZ1XGygF)
      UPDATE_BASE_URL="https://dl.digitsell.shop/share/gZ1XGygF"
      ;;
  esac
}
azhdar_normalize_update_base_url

# Asset mirrors (useful when GitHub is filtered).
# Public name shown in messages: m0000hamad
ASSET_MIRROR_NAME_DEFAULT="m0000hamad"
ASSET_MIRROR_NAME="${ASSET_MIRROR_NAME:-$ASSET_MIRROR_NAME_DEFAULT}"
ASSET_MIRROR_BASE_DEFAULT="https://dl.digitsell.shop/api/public/dl/Wf-XKNL9"
ASSET_MIRROR_BASE="${ASSET_MIRROR_BASE:-$ASSET_MIRROR_BASE_DEFAULT}"

azhdar_normalize_asset_mirror_base(){
  # Older builds and profiles may still point to legacy mirror hosts or the old direct IP.
  # Reset only known-bad legacy values, then normalize File Browser share URLs
  # to the stable public download API.
  local u="${ASSET_MIRROR_BASE:-}"
  u="${u%/}"
  case "$u" in
    ""|*atil.ir*|*62.60.184.163*)
      ASSET_MIRROR_BASE="$ASSET_MIRROR_BASE_DEFAULT"
      ;;
    *)
      ASSET_MIRROR_BASE="$u"
      ;;
  esac

  case "${ASSET_MIRROR_BASE%/}" in
    */share/*)
      _az_mirror_tmp="${ASSET_MIRROR_BASE%/}"
      _az_mirror_share="${_az_mirror_tmp##*/share/}"
      _az_mirror_root="${_az_mirror_tmp%%/share/*}"
      ASSET_MIRROR_BASE="${_az_mirror_root}/api/public/dl/${_az_mirror_share}"
      ;;
    */api/public/share/*)
      _az_mirror_tmp="${ASSET_MIRROR_BASE%/}"
      _az_mirror_share="${_az_mirror_tmp##*/api/public/share/}"
      _az_mirror_root="${_az_mirror_tmp%%/api/public/share/*}"
      ASSET_MIRROR_BASE="${_az_mirror_root}/api/public/dl/${_az_mirror_share}"
      ;;
  esac
  unset _az_mirror_tmp _az_mirror_share _az_mirror_root 2>/dev/null || true
}
azhdar_normalize_asset_mirror_base

# Default candidates (ports that typically blend in)
WG_PORT_CANDIDATES=(443 8443 2053 2083 2087 2096 8080 80 4443 9443)

state_dir_init(){
  # Best-effort migration path
  if [[ "$BASE_DIR" == "$DEFAULT_BASE_DIR" ]]; then
    if [[ ! -e "$DEFAULT_BASE_DIR" && -d "$LEGACY_BASE_DIR" ]]; then
      ln -s "$LEGACY_BASE_DIR" "$DEFAULT_BASE_DIR" 2>/dev/null || true
    fi
  fi
  mkdir -p "$BASE_DIR" 2>/dev/null || true
}

# -------------------- Colors/UI --------------------
RST=$'\e[0m'
BOLD=$'\e[1m'
DIM=$'\e[2m'
RED=$'\e[31m'
GRN=$'\e[32m'
YLW=$'\e[33m'
BLU=$'\e[34m'
MAG=$'\e[35m'  # purple/magenta
CYN=$'\e[36m'
WHT=$'\e[97m'

hr(){ echo -e "${DIM}──────────────────────────────────────────────────────────────${RST}"; }
_log(){ mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true; { printf "%s [%s] %s\n" "$(date -Is 2>/dev/null || date)" "${TAG}" "$*" >>"$LOG_FILE"; } 2>/dev/null || true; }

ok(){ echo -e "${GRN}✓${RST} $*"; _log "OK   $*"; }
warn(){ echo -e "${YLW}!${RST} $*"; _log "WARN $*"; }
err(){ echo -e "${RED}✗${RST} $*"; _log "ERR  $*"; }
info(){ echo -e "${CYN}i${RST} $*"; _log "INFO $*"; }

die(){ err "$*"; exit 1; }

pause(){ read -rp $'\nPress ENTER to continue...' _ || true; }

banner(){
  clear || true
  echo -e "${MAG}${BOLD}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${RST}"
  echo -e "${MAG}${BOLD}┃                             AZHDAR                           ┃${RST}"
  echo -e "${MAG}${BOLD}┃                       Creator: m0000hamad                    ┃${RST}"
  echo -e "${MAG}${BOLD}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${RST}"
  echo -e "${DIM}AZHDAR v${SCRIPT_VERSION}${RST}"
  echo
}

# -------------------- Error trap (nice reports) --------------------
LAST_STEP=""
on_err(){
  local ec=$?
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  echo -e "
${RED}${BOLD}Fatal:${RST} step failed: ${BOLD}${LAST_STEP:-unknown}${RST} (exit=${ec})" | tee -a "$LOG_FILE" >&2
  echo -e "${DIM}Log:${RST} ${LOG_FILE}" | tee -a "$LOG_FILE" >&2
  echo
  echo -e "${YLW}Tip:${RST} Open the Diagnostics menu to view full status/logs." | tee -a "$LOG_FILE" >&2
  exit "$ec"
}
trap on_err ERR


# In interactive menus we must not let a recoverable command failure (for example
# an unavailable SSH/WireGuard check) close the whole manager. CLI/boot paths keep
# strict error handling; azhdar_main enables this relaxed mode before showing menus.
azhdar_interactive_mode(){
  set +e
  return 0
}

step(){
  LAST_STEP="$*"
  local _msg
  _msg="${DIM}→${RST} ${BOLD}${LAST_STEP}${RST}"
  mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
  if ! echo -e "${_msg}" | tee -a "$LOG_FILE" >/dev/null 2>&1; then
    echo -e "${_msg}"
  else
    echo -e "${_msg}"
  fi
}

# -------------------- Helpers --------------------
need_root(){
  if [[ ${EUID:-999} -ne 0 ]]; then
    die "Run as root (sudo)."
  fi
}

have_cmd(){ command -v "$1" >/dev/null 2>&1; }

# Quote a value so it can be safely re-loaded by bash without expansion/injection.
# Uses bash's %q formatter (produces shell-escaped output).
q(){ printf '%q' "${1-}"; }

ensure_dirs(){
  state_dir_init
  mkdir -p "$PROFILE_DIR"
  touch "$LOG_FILE"
  chmod 600 "$LOG_FILE" 2>/dev/null || true
}



# Keep the system SSH server enabled/running. AZHDAR must never leave the
# operator without SSH after install/boot/repair. This helper is intentionally
# conservative: it does not rewrite sshd_config and it uses start/enable only
# when needed; no reload/restart of an already-active SSH daemon.
azhdar_ensure_system_ssh_local(){
  command -v systemctl >/dev/null 2>&1 || return 0
  local svc found=""
  for svc in ssh.service sshd.service; do
    if systemctl list-unit-files "$svc" >/dev/null 2>&1 || systemctl status "$svc" >/dev/null 2>&1; then
      found="$svc"
      systemctl unmask "$svc" >/dev/null 2>&1 || true
      systemctl enable "$svc" >/dev/null 2>&1 || true
      systemctl is-active --quiet "$svc" >/dev/null 2>&1 || systemctl start "$svc" >/dev/null 2>&1 || true
    fi
  done
  # Some Ubuntu/Debian images are socket-activated.
  for svc in ssh.socket sshd.socket; do
    if systemctl list-unit-files "$svc" >/dev/null 2>&1 || systemctl status "$svc" >/dev/null 2>&1; then
      systemctl unmask "$svc" >/dev/null 2>&1 || true
      systemctl enable "$svc" >/dev/null 2>&1 || true
      systemctl is-active --quiet "$svc" >/dev/null 2>&1 || systemctl start "$svc" >/dev/null 2>&1 || true
    fi
  done
  return 0
}

safe_name(){
  # allow: letters, numbers, _, -, .
  local s="$1"
  s="${s//[^a-zA-Z0-9_.-]/}"
  echo "$s"
}

is_ipv4(){
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS='.' read -r a b c d <<<"$ip"
  for o in "$a" "$b" "$c" "$d"; do
    [[ "$o" =~ ^[0-9]+$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

is_ipv6(){
  local ip="$1"
  [[ -n "$ip" ]] || return 1

  # Prefer python3's ipaddress for correctness when available.
  if have_cmd python3; then
    python3 - <<PY >/dev/null 2>&1
import ipaddress, sys
try:
  ipaddress.IPv6Address("$ip")
  sys.exit(0)
except Exception:
  sys.exit(1)
PY
    return $?
  fi

  # Fallback heuristic (not fully strict).
  [[ "$ip" =~ : ]] || return 1
  [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  return 0
}

is_host_like(){
  local h="$1"
  [[ -n "$h" ]] || return 1
  [[ "$h" =~ ^[a-zA-Z0-9.-]+$ ]] || return 1
  [[ "$h" != -* ]] || return 1
  [[ "$h" != *..* ]] || return 1
  return 0
}

prompt_host(){
  # Accept IPv4, IPv6, or DNS name.
  local prompt="$1" default="${2:-}"
  local v=""
  while true; do
    if [[ -n "$default" ]]; then
      read -rp "${prompt} [${default}]: " v || true
      v="${v:-$default}"
    else
      read -rp "${prompt}: " v || true
    fi
    v="${v//$'\r'/}"
    v="${v//$'\n'/}"
    v="${v//[[:space:]]/}"
    if is_ipv4 "$v" || is_ipv6 "$v" || is_host_like "$v"; then
      echo "$v"; return 0
    fi
    warn "Invalid host. Use an IPv4, IPv6, or DNS name."
  done
}

prompt_ipv6(){
  local prompt="$1" default="${2:-}"
  local v=""
  while true; do
    if [[ -n "$default" ]]; then
      read -rp "${prompt} [${default}]: " v || true
      v="${v:-$default}"
    else
      read -rp "${prompt}: " v || true
    fi
    v="${v//[[:space:]]/}"
    if is_ipv6 "$v"; then
      echo "$v"; return 0
    fi
    warn "Invalid IPv6. Example: 2001:db8::1"
  done
}

normalize_ipv6(){
  local ip="$1"
  have_cmd python3 || { echo "$ip"; return 0; }
  python3 -c 'import ipaddress,sys;

try:
 print(ipaddress.IPv6Address(sys.argv[1]).compressed)
except Exception:
 print(sys.argv[1])' "$ip" 2>/dev/null || echo "$ip"
}

normalize_cidr6(){
  local cidr="$1"
  have_cmd python3 || { echo "$cidr"; return 0; }
  python3 -c 'import ipaddress,sys;

try:
 print(ipaddress.ip_network(sys.argv[1], strict=False).compressed)
except Exception:
 print(sys.argv[1])' "$cidr" 2>/dev/null || echo "$cidr"
}


is_port(){
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  return 0
}

prompt_nonempty(){
  local prompt="$1" default="${2:-}"
  local v=""
  while true; do
    if [[ -n "$default" ]]; then
      read -rp "${prompt} [${default}]: " v || true
      v="${v:-$default}"
    else
      read -rp "${prompt}: " v || true
    fi
    v="${v//$'\r'/}"
    v="${v//$'\n'/}"
    if [[ -n "$v" ]]; then
      echo "$v"; return 0
    fi
    warn "Value cannot be empty."
  done
}

prompt_ipv4(){
  local prompt="$1" default="${2:-}"
  local v=""
  while true; do
    if [[ -n "$default" ]]; then
      read -rp "${prompt} [${default}]: " v || true
      v="${v:-$default}"
    else
      read -rp "${prompt}: " v || true
    fi
    v="${v//[[:space:]]/}"
    if is_ipv4 "$v"; then
      echo "$v"; return 0
    fi
    warn "Invalid IPv4. Example: 31.25.235.197"
  done
}

prompt_port(){
  local prompt="$1" default="${2:-}"
  local v=""
  while true; do
    if [[ -n "$default" ]]; then
      read -rp "${prompt} [${default}]: " v || true
      v="${v:-$default}"
    else
      read -rp "${prompt}: " v || true
    fi
    v="${v//[[:space:]]/}"
    if is_port "$v"; then
      echo "$v"; return 0
    fi
    warn "Port must be 1..65535"
  done
}

prompt_mtu(){
  local prompt="$1" default="${2:-1272}"
  local v=""
  while true; do
    read -rp "${prompt} (576..1500) [${default}]: " v || true
    v="${v:-$default}"
    v="${v//[[:space:]]/}"
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 576 && v <= 1500 )); then
      echo "$v"; return 0
    fi
    warn "MTU must be between 576 and 1500."
  done
}

prompt_keepalive(){
  local prompt="$1" default="${2:-25}"
  local v=""
  while true; do
    read -rp "${prompt} (0..60) [${default}]: " v || true
    v="${v:-$default}"
    v="${v//[[:space:]]/}"
    if [[ "$v" =~ ^[0-9]+$ ]] && (( v >= 0 && v <= 60 )); then
      echo "$v"; return 0
    fi
    warn "Keepalive must be between 0 and 60."
  done
}

prompt_yesno(){
  local prompt="$1" default="${2:-Y}"
  local ans=""
  while true; do
    read -rp "${prompt} [${default}]: " ans || true
    ans="${ans:-$default}"
    case "$ans" in
      Y|y|YES|yes) echo "Y"; return 0 ;;
      N|n|NO|no)   echo "N"; return 0 ;;
      *) warn "Please answer Y or N." ;;
    esac
  done
}


read_choice(){
  # usage: read_choice "Prompt" "1" "2" "0"
  local prompt="$1"; shift
  local opts=("$@")
  local in=""
  while true; do
    read -rp "${prompt}: " in || true
    in="${in//$'\r'/}"
    in="${in//$'\n'/}"
    in="${in//[[:space:]]/}"
    if [[ -z "$in" ]]; then
    # Empty input: default to the FIRST option (safer than accidentally backing out).
    echo "${opts[0]}"
    return 0
  fi
    local o
    for o in "${opts[@]}"; do
      if [[ "$in" == "$o" ]]; then
        echo "$in"
        return 0
      fi
    done
    warn "Invalid."
  done
}

detect_wan_if(){
  local ifc=""
  ifc="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  [[ -n "$ifc" && "$ifc" != "lo" ]] && { echo "$ifc"; return 0; }
  ifc="$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $5; exit}' || true)"
  [[ -n "$ifc" && "$ifc" != "lo" ]] && { echo "$ifc"; return 0; }
  ifc="$(ip -br link 2>/dev/null | awk '$1!="lo" && $2 ~ /UP/ {print $1; exit}' || true)"
  echo "$ifc"
}

public_ipv4(){
  have_cmd curl || return 1
  local ip
  for url in "https://api.ipify.org" "https://ipv4.icanhazip.com" "https://ifconfig.me/ip"; do
    ip="$(curl -4 -fsS --max-time 4 "$url" 2>/dev/null | tr -d '\n\r ' || true)"
    if is_ipv4 "$ip"; then
      echo "$ip"; return 0
    fi
  done
  return 1
}

