#!/usr/bin/env bash
set -u
umask 077

is_port(){ [[ "${1:-}" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }
q(){ printf '%q' "${1-}"; }
read_env_var(){
  local file="$1" var="$2"
  ( set +e +u; source "$file" 2>/dev/null || true; eval "printf '%s' \"\${${var}:-}\"" ) 2>/dev/null
}
set_env_var(){
  local file="$1" key="$2" val="$3" enc
  enc="$(q "$val")"
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${enc}|" "$file"
  else
    printf '%s=%s\n' "$key" "$enc" >> "$file"
  fi
}

safe_token(){
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1,1,16)}'
  else
    printf '%s' "$1" | cksum | awk '{print $1}'
  fi
}
known_hosts_file_for(){
  local profile="$1" host="$2" port="$3" token
  token="$(safe_token "${profile}|${host}|${port}")"
  printf '%s/ssh/known_hosts.d/%s-%s.known_hosts' "$BASE_DIR" "$profile" "$token"
}
known_host_target_for(){
  local host="$1" port="$2"
  if [[ "$port" == "22" ]]; then printf '%s' "$host"; else printf '[%s]:%s' "$host" "$port"; fi
}
refresh_known_hosts(){
  local profile="$1" host="$2" port="$3" kh tmp target
  kh="$(known_hosts_file_for "$profile" "$host" "$port")"
  mkdir -p "$(dirname "$kh")" >/dev/null 2>&1 || true
  touch "$kh" >/dev/null 2>&1 || true
  chmod 600 "$kh" >/dev/null 2>&1 || true
  command -v ssh-keyscan >/dev/null 2>&1 || { echo "$kh"; return 0; }
  tmp="$(mktemp 2>/dev/null || echo /tmp/azhdar-kh-$$)"
  if ssh-keyscan -T 5 -p "$port" "$host" >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    target="$(known_host_target_for "$host" "$port")"
    if command -v ssh-keygen >/dev/null 2>&1; then
      ssh-keygen -R "$target" -f "$kh" >/dev/null 2>&1 || true
      ssh-keygen -R "$host" -f "$kh" >/dev/null 2>&1 || true
    else
      : >"$kh" 2>/dev/null || true
    fi
    cat "$tmp" >>"$kh" 2>/dev/null || true
    chmod 600 "$kh" >/dev/null 2>&1 || true
  fi
  rm -f "$tmp" >/dev/null 2>&1 || true
  echo "$kh"
}

BASE_DIR="${AZHDAR_STATE_DIR:-/etc/azhdar}"
LEGACY_BASE="/etc/wireguard/m0000hamad-wg-mimic"
PROFILE_NAME="${1:-}"

printf 'AZHDAR SSH profile repair (no firewall/WG changes)\n'
printf '------------------------------------------------\n'
printf 'azhdar binary: %s\n' "$(command -v azhdar 2>/dev/null || echo not-found)"
printf 'state dir: %s\n' "$BASE_DIR"

mapfile -t profile_files < <(find "$BASE_DIR" "$LEGACY_BASE" /etc/wireguard -maxdepth 4 -type f -path '*/profiles/*.env' 2>/dev/null | sort -u)

if (( ${#profile_files[@]} == 0 )); then
  echo "ERROR: No AZHDAR profile env files found."
  echo "Open 'azhdar' -> Manage profiles -> add/select a profile first."
  exit 1
fi

printf '\nFound profiles:\n'
for i in "${!profile_files[@]}"; do
  f="${profile_files[$i]}"
  n="${f##*/}"; n="${n%.env}"
  printf '  %d) %s  (%s)\n' "$((i+1))" "$n" "$f"
done

if [[ -z "$PROFILE_NAME" && -f "$BASE_DIR/global.env" ]]; then
  PROFILE_NAME="$(read_env_var "$BASE_DIR/global.env" CURRENT_PROFILE)"
fi

chosen=""
if [[ -n "$PROFILE_NAME" ]]; then
  for f in "${profile_files[@]}"; do
    n="${f##*/}"; n="${n%.env}"
    if [[ "$n" == "$PROFILE_NAME" ]]; then chosen="$f"; break; fi
  done
fi

if [[ -z "$chosen" ]]; then
  printf '\nChoose profile number'
  [[ -n "$PROFILE_NAME" ]] && printf ' [%s not found by name]' "$PROFILE_NAME"
  printf ': '
  read -r idx
  if ! [[ "$idx" =~ ^[0-9]+$ ]] || (( idx < 1 || idx > ${#profile_files[@]} )); then
    echo "Invalid selection."
    exit 1
  fi
  chosen="${profile_files[$((idx-1))]}"
fi

PROFILE_NAME="${chosen##*/}"; PROFILE_NAME="${PROFILE_NAME%.env}"
backup="${chosen}.bak.$(date +%F-%H%M%S)"
cp -a "$chosen" "$backup" || { echo "ERROR: backup failed: $chosen"; exit 1; }
printf '\nSelected: %s\nFile: %s\nBackup: %s\n' "$PROFILE_NAME" "$chosen" "$backup"

cur_host="$(read_env_var "$chosen" OUT_SSH_HOST)"
cur_port="$(read_env_var "$chosen" OUT_SSH_PORT)"
cur_user="$(read_env_var "$chosen" OUT_SSH_USER)"
cur_ident="$(read_env_var "$chosen" OUT_SSH_IDENTITY)"
cur_wg_ip="$(read_env_var "$chosen" OUT_WG_IP)"
cur_transport="$(read_env_var "$chosen" SSH_MGMT_TRANSPORT)"
cur_host="${cur_host:-}"
cur_port="${cur_port:-22}"
cur_user="${cur_user:-root}"
cur_transport="${cur_transport:-auto}"

printf '\nCurrent SSH values:\n'
printf '  OUT_SSH_HOST=%s\n' "${cur_host:-<empty>}"
printf '  OUT_SSH_PORT=%s\n' "${cur_port:-<empty>}"
printf '  OUT_SSH_USER=%s\n' "${cur_user:-<empty>}"
printf '  OUT_SSH_IDENTITY=%s\n' "${cur_ident:-<empty>}"
printf '  OUT_WG_IP=%s\n' "${cur_wg_ip:-<empty>}"
printf '  SSH_MGMT_TRANSPORT=%s\n' "${cur_transport:-auto}"

printf '\nEnter the EXACT values that work manually. Example: ssh -p PORT USER@HOST\n'
while true; do
  read -rp "OUT host/IP [${cur_host:-no-default}]: " new_host
  new_host="${new_host:-$cur_host}"
  new_host="${new_host//[[:space:]]/}"
  [[ -n "$new_host" ]] && break
  echo "Host cannot be empty."
done
while true; do
  read -rp "OUT SSH port [${cur_port:-22}]: " new_port
  new_port="${new_port:-${cur_port:-22}}"
  new_port="${new_port//[[:space:]]/}"
  is_port "$new_port" && break
  echo "Port must be 1..65535."
done
while true; do
  read -rp "OUT SSH user [${cur_user:-root}]: " new_user
  new_user="${new_user:-${cur_user:-root}}"
  new_user="${new_user//[[:space:]]/}"
  [[ -n "$new_user" ]] && break
  echo "User cannot be empty."
done

printf '\nSSH management transport for AZHDAR commands:\n'
printf '  auto   = try public SSH first, then OUT_WG_IP if tunnel is up\n'
printf '  direct = only public SSH host\n'
printf '  wg     = prefer OUT_WG_IP, fallback to public SSH\n'
while true; do
  read -rp "Transport [${cur_transport:-auto}]: " new_transport
  new_transport="${new_transport:-${cur_transport:-auto}}"
  new_transport="${new_transport//[[:space:]]/}"
  case "$new_transport" in
    auto|direct|public|wg) break ;;
    *) echo "Use auto, direct, or wg." ;;
  esac
done
[[ "$new_transport" == "public" ]] && new_transport="direct"

set_env_var "$chosen" OUT_SSH_HOST "$new_host"
set_env_var "$chosen" OUT_PUBLIC_IP "$(read_env_var "$chosen" OUT_PUBLIC_IP || true)"
if [[ -z "$(read_env_var "$chosen" OUT_PUBLIC_IP)" ]]; then
  set_env_var "$chosen" OUT_PUBLIC_IP "$new_host"
fi
set_env_var "$chosen" OUT_SSH_PORT "$new_port"
set_env_var "$chosen" OUT_SSH_USER "$new_user"
set_env_var "$chosen" SSH_USE_MASTER "0"
set_env_var "$chosen" SSH_MGMT_TRANSPORT "$new_transport"
set_env_var "$chosen" SSH_MGMT_LAST_TRANSPORT ""
set_env_var "$chosen" SSH_MGMT_LAST_HOST ""
set_env_var "$chosen" SSH_MGMT_LAST_PORT ""
mkdir -p "$BASE_DIR"
printf 'CURRENT_PROFILE=%s\n' "$(q "$PROFILE_NAME")" > "$BASE_DIR/global.env"
chmod 600 "$BASE_DIR/global.env" "$chosen" 2>/dev/null || true

printf '\nTesting SSH now:\n'
printf '  ssh -p %s %s@%s "echo OK; id -u"\n\n' "$new_port" "$new_user" "$new_host"
kh="$(refresh_known_hosts "$PROFILE_NAME" "$new_host" "$new_port")"
echo "AZHDAR known_hosts: $kh"
if [[ -n "${cur_wg_ip:-}" && "$cur_wg_ip" != "peer" && "$cur_wg_ip" != "$new_host" ]]; then
  kh_wg="$(refresh_known_hosts "$PROFILE_NAME" "$cur_wg_ip" "$new_port")"
  echo "AZHDAR known_hosts (WG): $kh_wg"
fi
ssh -p "$new_port" \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile="$kh" \
  -o GlobalKnownHostsFile=/dev/null \
  -o CheckHostIP=no \
  -o UpdateHostKeys=no \
  -o ConnectTimeout=8 \
  -o ServerAliveInterval=15 \
  -o ServerAliveCountMax=2 \
  "$new_user@$new_host" "echo OK; id -u"
rc=$?
if (( rc == 0 )); then
  echo "OK: SSH profile repaired."
else
  echo "WARNING: Direct SSH test failed. Profile was updated, backup is: $backup"
  if [[ -n "${cur_wg_ip:-}" && "$cur_wg_ip" != "peer" && "$cur_wg_ip" != "$new_host" ]]; then
    echo
    echo "Trying WG management path once: ssh -p $new_port $new_user@$cur_wg_ip"
    kh_wg="$(known_hosts_file_for "$PROFILE_NAME" "$cur_wg_ip" "$new_port")"
    ssh -p "$new_port" \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$kh_wg" \
      -o GlobalKnownHostsFile=/dev/null \
      -o CheckHostIP=no \
      -o UpdateHostKeys=no \
      -o ConnectTimeout=8 \
      -o ServerAliveInterval=15 \
      -o ServerAliveCountMax=2 \
      "$new_user@$cur_wg_ip" "echo OK; id -u" && rc=0 || rc=$?
    if (( rc == 0 )); then
      set_env_var "$chosen" SSH_MGMT_LAST_TRANSPORT "wg"
      set_env_var "$chosen" SSH_MGMT_LAST_HOST "$cur_wg_ip"
      set_env_var "$chosen" SSH_MGMT_LAST_PORT "$new_port"
      echo "OK: WG management SSH works. AZHDAR auto/wg transport will use it."
    fi
  fi
fi
exit "$rc"
