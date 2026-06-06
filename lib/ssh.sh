# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- SSH helpers --------------------

ssh_interactive(){
  # True when a human can answer prompts.  Do not require stdout to be a TTY:
  # many AZHDAR checks capture stdout (command substitution) or hide stderr,
  # while manual SSH still works from the same terminal.
  [[ -t 0 || -t 2 || -r /dev/tty ]]
}

ssh_can_prompt(){
  # OpenSSH can read passphrases/passwords from the controlling tty even when
  # stdin is a heredoc/script and stdout is captured.  Use this for deciding
  # whether BatchMode should be disabled.
  [[ -t 0 || -t 2 || -r /dev/tty ]]
}

ssh_tty_flag_ok(){
  # Only force a remote pseudo-tty when stdin is a real tty.  For heredoc/stdin
  # script uploads, -tt can consume the script input incorrectly.
  [[ -t 0 ]]
}

ssh_safe_token(){
  # Return a filesystem-safe short token for host/port/profile-specific files.
  local raw="$1"
  if have_cmd sha256sum; then
    printf '%s' "$raw" | sha256sum | awk '{print substr($1,1,16)}'
  elif have_cmd shasum; then
    printf '%s' "$raw" | shasum -a 256 | awk '{print substr($1,1,16)}'
  else
    printf '%s' "$raw" | cksum | awk '{print $1}'
  fi
}

ssh_known_hosts_dir(){
  echo "${BASE_DIR:-/etc/azhdar}/ssh/known_hosts.d"
}

ssh_known_hosts_file_for(){
  # usage: ssh_known_hosts_file_for <host> <port>
  local host="${1:-unknown}" port="${2:-22}" prof="${PROFILE:-default}"
  local token; token="$(ssh_safe_token "${prof}|${host}|${port}")"
  echo "$(ssh_known_hosts_dir)/${prof}-${token}.known_hosts"
}

ssh_known_hosts_file(){
  ssh_known_hosts_file_for "${OUT_SSH_HOST:-unknown}" "${OUT_SSH_PORT:-22}"
}

ssh_known_host_target_for(){
  # OpenSSH stores non-22 ports as [host]:port.
  local host="$1" port="${2:-22}"
  if [[ "$port" == "22" ]]; then
    printf '%s' "$host"
  else
    printf '[%s]:%s' "$host" "$port"
  fi
}

ssh_forget_known_host_for(){
  # Remove stale host keys for this endpoint. AZHDAR uses an isolated
  # known_hosts file, but after a VPS rebuild users often also have the old
  # signature in ~/.ssh/known_hosts; prune that exact host/port too so the next
  # interactive SSH attempt is not blocked by REMOTE HOST IDENTIFICATION errors.
  local host="$1" port="${2:-22}" kh="${3:-}" target f
  [[ -n "$host" ]] || return 0
  [[ -n "$kh" ]] || kh="$(ssh_known_hosts_file_for "$host" "$port")"
  mkdir -p "$(dirname "$kh")" >/dev/null 2>&1 || true
  touch "$kh" >/dev/null 2>&1 || true
  chmod 600 "$kh" >/dev/null 2>&1 || true
  target="$(ssh_known_host_target_for "$host" "$port")"
  if have_cmd ssh-keygen; then
    ssh-keygen -R "$target" -f "$kh" >/dev/null 2>&1 || true
    # Also remove plain host form for compatibility with older AZHDAR builds.
    ssh-keygen -R "$host" -f "$kh" >/dev/null 2>&1 || true

    if [[ "${AZHDAR_PRUNE_USER_KNOWN_HOSTS:-1}" == "1" ]]; then
      local -a kh_files=()
      [[ -n "${HOME:-}" ]] && kh_files+=("${HOME}/.ssh/known_hosts" "${HOME}/.ssh/known_hosts2")
      kh_files+=("/root/.ssh/known_hosts" "/root/.ssh/known_hosts2")
      for f in "${kh_files[@]}"; do
        [[ -f "$f" && "$f" != "$kh" ]] || continue
        ssh-keygen -R "$target" -f "$f" >/dev/null 2>&1 || true
        ssh-keygen -R "$host" -f "$f" >/dev/null 2>&1 || true
      done
    fi
  else
    # Conservative fallback: keep the file but empty it for this profile endpoint.
    : >"$kh" 2>/dev/null || true
  fi
}

ssh_prepare_known_hosts_for(){
  # Refresh and save the current SSH host key before connecting.
  # This prevents 'REMOTE HOST IDENTIFICATION HAS CHANGED' after VPS rebuilds,
  # provider host-key rotation, or IP reuse. It also clears the exact endpoint
  # from the user's known_hosts by default, because rebuilt OUT servers commonly
  # keep the same IP with a new SSH signature.
  local host="$1" port="${2:-22}" kh="${3:-}" tmp=""
  [[ -n "$host" ]] || return 0
  is_port "$port" || port="22"
  [[ -n "$kh" ]] || kh="$(ssh_known_hosts_file_for "$host" "$port")"
  mkdir -p "$(dirname "$kh")" >/dev/null 2>&1 || true
  touch "$kh" >/dev/null 2>&1 || true
  chmod 600 "$kh" >/dev/null 2>&1 || true

  # Clear stale signatures first. If ssh-keyscan fails, ssh(1) can still accept
  # the new key into AZHDAR's isolated file on the next connection attempt.
  ssh_forget_known_host_for "$host" "$port" "$kh" >/dev/null 2>&1 || true

  have_cmd ssh-keyscan || return 0
  tmp="$(mktemp 2>/dev/null || printf '/tmp/azhdar-kh-%s' "$$")"
  : >"$tmp" 2>/dev/null || true
  if ssh-keyscan -T 5 -p "$port" "$host" >"$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    cat "$tmp" >>"$kh" 2>/dev/null || true
    chmod 600 "$kh" >/dev/null 2>&1 || true
  fi
  rm -f "$tmp" >/dev/null 2>&1 || true
}

ssh_prepare_known_hosts(){
  ssh_prepare_known_hosts_for "${OUT_SSH_HOST:-}" "${OUT_SSH_PORT:-22}" "${SSH_KNOWN_HOSTS_FILE:-}"
}

ssh_refresh_remote_known_hosts_best_effort(){
  # Best-effort: store IR's host key on OUT too, so both sides have AZHDAR
  # known_hosts state. This does not change sshd, firewall, WG, or tunnels.
  [[ -n "${IR_PUBLIC_IP:-}" ]] || return 0
  local ir_port="${IR_SSH_PORT:-22}" ir_host="${IR_PUBLIC_IP:-}" ir_target
  is_port "$ir_port" || ir_port="22"
  ir_target="$(ssh_known_host_target_for "$ir_host" "$ir_port")"

  local q_profile q_host q_port q_target
  q_profile="$(q "${PROFILE:-default}")"
  q_host="$(q "$ir_host")"
  q_port="$(q "$ir_port")"
  q_target="$(q "$ir_target")"

  ssh_run_root_best_effort "
    set +e
    mkdir -p /etc/azhdar/ssh/known_hosts.d >/dev/null 2>&1 || true
    kh=/etc/azhdar/ssh/known_hosts.d/${q_profile}-ir.known_hosts
    touch \"\$kh\" >/dev/null 2>&1 || true
    chmod 600 \"\$kh\" >/dev/null 2>&1 || true
    if command -v ssh-keyscan >/dev/null 2>&1; then
      tmp=\$(mktemp 2>/dev/null || echo /tmp/azhdar-ir-kh-\$\$)
      if ssh-keyscan -T 5 -p ${q_port} ${q_host} >\"\$tmp\" 2>/dev/null && [ -s \"\$tmp\" ]; then
        if command -v ssh-keygen >/dev/null 2>&1; then
          ssh-keygen -R ${q_target} -f \"\$kh\" >/dev/null 2>&1 || true
          ssh-keygen -R ${q_host} -f \"\$kh\" >/dev/null 2>&1 || true
        else
          : >\"\$kh\" 2>/dev/null || true
        fi
        cat \"\$tmp\" >>\"\$kh\" 2>/dev/null || true
        chmod 600 \"\$kh\" >/dev/null 2>&1 || true
      fi
      rm -f \"\$tmp\" >/dev/null 2>&1 || true
    fi
  " >/dev/null 2>&1 || true
}
ssh_clean_captured_line(){
  # prompt_* diagnostics used to be printed to stdout in older builds; when a
  # user first typed an invalid value, command substitution could save the
  # warning text together with the real host. Keep only the last non-empty line
  # and strip ANSI color sequences.
  local raw="$1" line last=""
  raw="${raw//$'\r'/}"
  raw="$(printf '%s
' "$raw" | sed -E $'s/\x1B\[[0-9;]*[A-Za-z]//g' 2>/dev/null || printf '%s
' "$raw")"
  while IFS= read -r line; do
    line="${line#${line%%[![:space:]]*}}"
    line="${line%${line##*[![:space:]]}}"
    [[ -n "$line" ]] && last="$line"
  done <<<"$raw"
  printf '%s' "$last"
}

ssh_normalize_endpoint_vars(){
  # Normalize OUT_SSH_HOST and optionally extract user/port from pasted values:
  # root@1.2.3.4:22, 1.2.3.4:22, [2001:db8::1]:22.
  local raw="${OUT_SSH_HOST:-}" user="" port="" host=""
  raw="$(ssh_clean_captured_line "$raw")"
  raw="${raw//[[:space:]]/}"
  if [[ "$raw" == *@* ]]; then
    user="${raw%@*}"
    raw="${raw##*@}"
    [[ -n "$user" && "$user" != *:* ]] && OUT_SSH_USER="$user"
  fi
  if [[ "$raw" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  elif [[ "$raw" =~ ^([A-Za-z0-9.-]+):([0-9]+)$ ]]; then
    host="${BASH_REMATCH[1]}"
    port="${BASH_REMATCH[2]}"
  else
    host="$raw"
  fi
  OUT_SSH_HOST="$host"
  if is_port "${port:-}"; then
    OUT_SSH_PORT="$port"
  fi
}

ssh_normalize_vars(){
  OUT_SSH_USER="${OUT_SSH_USER:-root}"
  ssh_normalize_endpoint_vars
  if ! is_port "${OUT_SSH_PORT:-}"; then
    OUT_SSH_PORT="22"
  fi
  SSH_MGMT_TRANSPORT="${SSH_MGMT_TRANSPORT:-auto}"
  case "${SSH_MGMT_TRANSPORT}" in
    auto|direct|public|wg) ;;
    *) SSH_MGMT_TRANSPORT="auto" ;;
  esac
  # Operational safety: ControlMaster sockets can go stale after reboot/network changes.
  # Keep it disabled unless explicitly requested from the environment.
  if [[ "${AZHDAR_ALLOW_SSH_MASTER:-0}" != "1" ]]; then
    SSH_USE_MASTER="0"
  else
    SSH_USE_MASTER="${SSH_USE_MASTER:-0}"
  fi
}

ssh_ensure_sshpass_for_password(){
  # Password auth through AZHDAR needs sshpass for non-interactive remote steps.
  # Manual `ssh user@host` can work without it, so silently try to install it
  # when a password is saved or just re-entered.
  [[ -n "${OUT_SSH_PASS:-}" ]] || return 0
  have_cmd sshpass && return 0
  local pm; pm="$(detect_pkg_mgr 2>/dev/null || echo unknown)"
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y sshpass >/dev/null 2>&1 || true
      ;;
    dnf) dnf install -y sshpass >/dev/null 2>&1 || true ;;
    yum) yum install -y sshpass >/dev/null 2>&1 || true ;;
    pacman) pacman -Sy --noconfirm sshpass >/dev/null 2>&1 || true ;;
  esac
}

ssh_profile_set_var_silent(){
  # Update one profile variable without printing "Saved profile" and without
  # touching firewall/WG state. Used for last-good SSH management path.
  local key="$1" val="$2" f enc
  [[ -n "${PROFILE:-}" && -n "${key:-}" ]] || return 0
  f="$(profile_path "$PROFILE" 2>/dev/null || true)"
  [[ -n "$f" && -f "$f" ]] || return 0
  enc="$(q "$val")"
  if grep -qE "^${key}=" "$f" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${enc}|" "$f" 2>/dev/null || true
  else
    printf '%s=%s\n' "$key" "$enc" >>"$f" 2>/dev/null || true
  fi
  chmod 600 "$f" 2>/dev/null || true
}

ssh_require_vars(){
  # Normalize and validate SSH connection variables before any ssh(1) call.
  # This prevents cryptic errors like: Bad port ''
  ssh_normalize_vars

  if [[ -z "${OUT_SSH_HOST:-}" ]]; then
    if ssh_interactive && [[ -n "${PROFILE:-}" ]]; then
      warn "OUT SSH host is empty for profile '${PROFILE}'."
      OUT_SSH_HOST="$(prompt_host "OUT server host (SSH)" "${OUT_PUBLIC_IP:-}")"
      OUT_PUBLIC_IP="${OUT_PUBLIC_IP:-$OUT_SSH_HOST}"
      OUT_SSH_USER="$(prompt_nonempty "OUT SSH user" "${OUT_SSH_USER:-root}")"
      OUT_SSH_PORT="$(prompt_port "OUT SSH port" "${OUT_SSH_PORT:-22}")"
      profile_save >/dev/null 2>&1 || true
    else
      err "OUT SSH host is empty. Select/create a profile and set OUT server SSH settings first."
      return 2
    fi
  fi

  if [[ -n "${OUT_SSH_HOST:-}" ]] && ! is_ipv4 "${OUT_SSH_HOST}" && ! is_ipv6 "${OUT_SSH_HOST}" && ! is_host_like "${OUT_SSH_HOST}"; then
    if ssh_interactive && [[ -n "${PROFILE:-}" ]]; then
      warn "OUT SSH host in profile '${PROFILE}' looked invalid/corrupted; please re-enter it."
      OUT_SSH_HOST="$(prompt_host "OUT server host (SSH)" "${OUT_PUBLIC_IP:-}")"
      OUT_PUBLIC_IP="${OUT_PUBLIC_IP:-$OUT_SSH_HOST}"
      profile_save >/dev/null 2>&1 || true
    else
      err "OUT SSH host is invalid: ${OUT_SSH_HOST}"
      return 2
    fi
  fi

  if ! is_port "${OUT_SSH_PORT:-}"; then
    if ssh_interactive && [[ -n "${PROFILE:-}" ]]; then
      warn "OUT SSH port is invalid/empty for profile '${PROFILE}'."
      OUT_SSH_PORT="$(prompt_port "OUT SSH port" "22")"
      profile_save >/dev/null 2>&1 || true
    else
      OUT_SSH_PORT="22"
    fi
  fi

  OUT_SSH_USER="${OUT_SSH_USER:-root}"
  return 0
}

ssh_control_path_for(){
  local host="${1:-unknown}" port="${2:-22}" user="${3:-${OUT_SSH_USER:-root}}"
  local token; token="$(ssh_safe_token "${PROFILE:-default}|${user}|${host}|${port}")"
  echo "/tmp/azhdar-ssh-${token}.sock"
}

ssh_control_path(){
  ssh_control_path_for "${OUT_SSH_HOST:-unknown}" "${OUT_SSH_PORT:-22}" "${OUT_SSH_USER:-root}"
}

ssh_prune_stale_control_socket_for(){
  # Remove dead/stale ControlMaster sockets before a new SSH attempt.
  local host="${1:-${OUT_SSH_HOST:-127.0.0.1}}" port="${2:-${OUT_SSH_PORT:-22}}" kh="${3:-}" cp
  [[ "${SSH_USE_MASTER:-0}" == "1" ]] || return 0
  [[ -n "$kh" ]] || kh="$(ssh_known_hosts_file_for "$host" "$port")"
  cp="$(ssh_control_path_for "$host" "$port" "${OUT_SSH_USER:-root}")"
  if [[ -e "$cp" && ! -S "$cp" ]]; then
    rm -f "$cp" >/dev/null 2>&1 || true
    return 0
  fi
  if [[ -S "$cp" ]]; then
    ssh -S "$cp" -O check \
      -o BatchMode=yes \
      -o ControlMaster=no \
      -o StrictHostKeyChecking=accept-new \
      -o UserKnownHostsFile="$kh" \
      -o GlobalKnownHostsFile=/dev/null \
      -o CheckHostIP=no \
      -o UpdateHostKeys=no \
      -p "$port" "${OUT_SSH_USER:-root}@${host}" >/dev/null 2>&1 || rm -f "$cp" >/dev/null 2>&1 || true
  fi
}

ssh_prune_stale_control_socket(){
  ssh_prune_stale_control_socket_for "${OUT_SSH_HOST:-127.0.0.1}" "${OUT_SSH_PORT:-22}" "${SSH_KNOWN_HOSTS_FILE:-$(ssh_known_hosts_file)}"
}

tcp_port_open(){
  # usage: tcp_port_open host port
  local host="$1" port="$2"
  if have_cmd nc; then
    nc -z -w2 "$host" "$port" >/dev/null 2>&1
    return $?
  fi
  # Bound the /dev/tcp fallback too; otherwise a filtered host can hang cleanup.
  if have_cmd timeout; then
    timeout 2 bash -c 'echo >/dev/tcp/"$1"/"$2"' _ "$host" "$port" >/dev/null 2>&1
    return $?
  fi
  (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1 && return 0 || return 1
}

tcp_port_is_ssh(){
  # usage: tcp_port_is_ssh host port
  local host="$1" port="$2" line=""
  if have_cmd timeout; then
    if have_cmd nc; then
      line="$(timeout 3 nc -w2 "$host" "$port" </dev/null 2>/dev/null | head -n1 || true)"
    else
      line="$(timeout 3 bash -lc "exec 3<>/dev/tcp/${host}/${port}; head -n1 <&3" 2>/dev/null || true)"
    fi
  else
    if have_cmd nc; then
      line="$(nc -w2 "$host" "$port" </dev/null 2>/dev/null | head -n1 || true)"
    else
      line="$((exec 3<>/dev/tcp/${host}/${port}; head -n1 <&3) 2>/dev/null || true)"
    fi
  fi
  line="${line//$'\r'/}"
  line="${line//$'\n'/}"
  [[ "$line" == SSH-* ]]
}

ssh_wg_mgmt_host(){
  # Return OUT's tunnel IP if it is a valid management fallback target.
  # During a new install the default OUT_WG_IP may be populated even though no
  # WG interface/handshake exists yet. Do not try that stale 10.x fallback unless
  # the user explicitly selected WG management, or it was the last working path,
  # or the local WG interface is actually present.
  local h="${OUT_WG_IP:-}" mode="${SSH_MGMT_TRANSPORT:-auto}" last="${SSH_MGMT_LAST_TRANSPORT:-}"
  [[ "${ENABLE_TUN_IPV4:-1}" == "1" ]] || return 1
  [[ -n "$h" && "$h" != "peer" ]] || return 1
  [[ "$h" != "${OUT_SSH_HOST:-}" ]] || return 1

  if [[ "$mode" != "wg" && "$last" != "wg" ]]; then
    if command -v ip >/dev/null 2>&1 && [[ -n "${WG_IF:-}" ]]; then
      ip link show "${WG_IF}" >/dev/null 2>&1 || return 1
    else
      return 1
    fi
  fi

  if is_ipv4 "$h" || is_host_like "$h"; then
    printf '%s' "$h"
    return 0
  fi
  return 1
}

ssh_target_candidates(){
  # Print candidate management paths as: host<TAB>port<TAB>label
  # label: direct | wg
  ssh_require_vars >/dev/null 2>&1 || return 1
  local port="${OUT_SSH_PORT:-22}" mode="${SSH_MGMT_TRANSPORT:-auto}" last="${SSH_MGMT_LAST_TRANSPORT:-}"
  local direct="${OUT_SSH_HOST:-}" wg="" last_host="${SSH_MGMT_LAST_HOST:-}" last_port="${SSH_MGMT_LAST_PORT:-}"
  is_port "$port" || port="22"
  is_port "$last_port" || last_port="$port"
  wg="$(ssh_wg_mgmt_host 2>/dev/null || true)"

  local -A seen=()
  _emit(){
    local h="$1" p="$2" label="$3" k
    [[ -n "$h" && -n "$p" ]] || return 0
    k="${h}|${p}"
    [[ -n "${seen[$k]:-}" ]] && return 0
    seen[$k]=1
    printf '%s\t%s\t%s\n' "$h" "$p" "$label"
  }

  case "$mode" in
    wg)
      # During tunnel-IP changes the saved current OUT_WG_IP may already be the
      # NEW address, while the only reachable management path is still the OLD
      # WG address. Try last-good WG host first, then the current WG IP, then direct.
      [[ "$last" == "wg" && -n "$last_host" ]] && _emit "$last_host" "$last_port" "wg"
      _emit "$wg" "$port" "wg"
      _emit "$direct" "$port" "direct"
      ;;
    direct|public)
      _emit "$direct" "$port" "direct"
      _emit "$wg" "$port" "wg"
      [[ "$last" == "wg" && -n "$last_host" ]] && _emit "$last_host" "$last_port" "wg"
      ;;
    auto|*)
      if [[ "$last" == "wg" ]]; then
        [[ -n "$last_host" ]] && _emit "$last_host" "$last_port" "wg"
        _emit "$wg" "$port" "wg"
        _emit "$direct" "$port" "direct"
      else
        _emit "$direct" "$port" "direct"
        _emit "$wg" "$port" "wg"
        [[ -n "$last_host" ]] && _emit "$last_host" "$last_port" "wg"
      fi
      ;;
  esac
}

ssh_mark_target_success(){
  local host="$1" port="$2" label="$3"
  SSH_ACTIVE_HOST="$host"
  SSH_ACTIVE_PORT="$port"
  SSH_ACTIVE_TRANSPORT="$label"
  SSH_MGMT_LAST_TRANSPORT="$label"
  SSH_MGMT_LAST_HOST="$host"
  SSH_MGMT_LAST_PORT="$port"
  ssh_profile_set_var_silent SSH_MGMT_LAST_TRANSPORT "$label"
  ssh_profile_set_var_silent SSH_MGMT_LAST_HOST "$host"
  ssh_profile_set_var_silent SSH_MGMT_LAST_PORT "$port"
  # Keep transport in auto, but if the user explicitly selected wg/direct keep that preference.
  if [[ "${SSH_MGMT_TRANSPORT:-auto}" != "direct" && "${SSH_MGMT_TRANSPORT:-auto}" != "public" && "${SSH_MGMT_TRANSPORT:-auto}" != "wg" ]]; then
    ssh_profile_set_var_silent SSH_MGMT_TRANSPORT "auto"
  fi
}

ssh_base_opts_for(){
  # Echo a NUL-separated list would be overkill; this helper is documented only.
  :
}

ssh_exec_cmd_on(){
  # usage: ssh_exec_cmd_on <host> <port> <label> <command>
  local host="$1" port="$2" label="$3" cmd="$4"
  local have_pw=0 interactive=0 kh cp rc
  if [[ -n "${OUT_SSH_PASS:-}" ]] && ! have_cmd sshpass; then
    ssh_ensure_sshpass_for_password >/dev/null 2>&1 || true
  fi
  [[ -n "${OUT_SSH_PASS:-}" ]] && have_cmd sshpass && have_pw=1 || true
  ssh_can_prompt && interactive=1 || true

  kh="$(ssh_known_hosts_file_for "$host" "$port")"
  ssh_prepare_known_hosts_for "$host" "$port" "$kh" >/dev/null 2>&1 || true

  local -a flags=()
  local -a opts=(
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="$kh"
    -o GlobalKnownHostsFile=/dev/null
    -o CheckHostIP=no
    -o UpdateHostKeys=no
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=2
    -o ConnectTimeout="${AZHDAR_SSH_CONNECT_TIMEOUT:-8}"
    -o PreferredAuthentications=publickey,password,keyboard-interactive
    -o KbdInteractiveAuthentication=yes
    -o PasswordAuthentication=yes
    -o PubkeyAuthentication=yes
    -o NumberOfPasswordPrompts=1
  )

  if (( interactive == 1 )) && (( have_pw == 0 )) && [[ -z "${OUT_SSH_IDENTITY:-}" ]] && ssh_tty_flag_ok; then
    flags+=(-tt)
  fi
  if (( interactive == 0 )) && (( have_pw == 0 )) && [[ -z "${OUT_SSH_IDENTITY:-}" ]]; then
    opts+=(-o BatchMode=yes -o NumberOfPasswordPrompts=0)
  fi
  if [[ -n "${OUT_SSH_IDENTITY:-}" ]]; then
    opts+=(-i "${OUT_SSH_IDENTITY}")
  fi
  if [[ "${SSH_USE_MASTER:-0}" == "1" ]]; then
    cp="$(ssh_control_path_for "$host" "$port" "${OUT_SSH_USER:-root}")"
    ssh_prune_stale_control_socket_for "$host" "$port" "$kh" >/dev/null 2>&1 || true
    opts+=(-o ControlMaster=auto -o ControlPersist=600 -o ControlPath="$cp")
  else
    opts+=(-o ControlMaster=no)
  fi

  if (( have_pw == 1 )); then
    SSHPASS="${OUT_SSH_PASS}" sshpass -e ssh -p "$port" "${flags[@]}" "${opts[@]}" "${OUT_SSH_USER}@${host}" "$cmd"
    rc=$?
  else
    ssh -p "$port" "${flags[@]}" "${opts[@]}" "${OUT_SSH_USER}@${host}" "$cmd"
    rc=$?
  fi

  # If host-key changed and keyscan did not refresh it, forget once and retry.
  if (( rc == 255 )); then
    ssh_forget_known_host_for "$host" "$port" "$kh" >/dev/null 2>&1 || true
    ssh_prepare_known_hosts_for "$host" "$port" "$kh" >/dev/null 2>&1 || true
    if (( have_pw == 1 )); then
      SSHPASS="${OUT_SSH_PASS}" sshpass -e ssh -p "$port" "${flags[@]}" "${opts[@]}" "${OUT_SSH_USER}@${host}" "$cmd"
      rc=$?
    else
      ssh -p "$port" "${flags[@]}" "${opts[@]}" "${OUT_SSH_USER}@${host}" "$cmd"
      rc=$?
    fi
  fi

  return "$rc"
}

ssh_run(){
  # usage: ssh_run "command"
  local cmd="$1" host port label rc=255 last_rc=255 tried=0
  ssh_require_vars || return $?

  while IFS=$'\t' read -r host port label; do
    [[ -n "$host" && -n "$port" ]] || continue
    tried=1
    ssh_exec_cmd_on "$host" "$port" "$label" "$cmd"
    rc=$?; last_rc=$rc
    if (( rc == 0 )); then
      ssh_mark_target_success "$host" "$port" "$label"
      return 0
    fi
    # 255 means SSH transport/auth/host-key failure. Try next candidate.
    # Other exit codes belong to the remote command; do not re-run side effects.
    (( rc == 255 )) || return "$rc"
  done < <(ssh_target_candidates)

  (( tried == 1 )) || return 1
  return "$last_rc"
}

ssh_pick_working_target(){
  # Print first target that can run 'true' as: host<TAB>port<TAB>label
  local host port label rc
  ssh_require_vars || return $?
  while IFS=$'\t' read -r host port label; do
    [[ -n "$host" && -n "$port" ]] || continue
    ssh_exec_cmd_on "$host" "$port" "$label" "true" >/dev/null 2>&1
    rc=$?
    if (( rc == 0 )); then
      ssh_mark_target_success "$host" "$port" "$label"
      printf '%s\t%s\t%s\n' "$host" "$port" "$label"
      return 0
    fi
    (( rc == 255 )) || return "$rc"
  done < <(ssh_target_candidates)
  return 1
}

ssh_exec_stdin_on(){
  # usage: ssh_exec_stdin_on <host> <port> <label> [remote command...]
  local host="$1" port="$2" label="$3"; shift 3
  local have_pw=0 interactive=0 kh cp rc
  if [[ -n "${OUT_SSH_PASS:-}" ]] && ! have_cmd sshpass; then
    ssh_ensure_sshpass_for_password >/dev/null 2>&1 || true
  fi
  [[ -n "${OUT_SSH_PASS:-}" ]] && have_cmd sshpass && have_pw=1 || true
  ssh_can_prompt && interactive=1 || true
  kh="$(ssh_known_hosts_file_for "$host" "$port")"
  ssh_prepare_known_hosts_for "$host" "$port" "$kh" >/dev/null 2>&1 || true

  local -a flags=()
  local -a opts=(
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="$kh"
    -o GlobalKnownHostsFile=/dev/null
    -o CheckHostIP=no
    -o UpdateHostKeys=no
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=2
    -o ConnectTimeout="${AZHDAR_SSH_CONNECT_TIMEOUT:-8}"
    -o PreferredAuthentications=publickey,password,keyboard-interactive
    -o KbdInteractiveAuthentication=yes
    -o PasswordAuthentication=yes
    -o PubkeyAuthentication=yes
    -o NumberOfPasswordPrompts=1
  )
  if (( interactive == 1 )) && (( have_pw == 0 )) && [[ -z "${OUT_SSH_IDENTITY:-}" ]] && ssh_tty_flag_ok; then
    flags+=(-tt)
  fi
  if (( interactive == 0 )) && (( have_pw == 0 )) && [[ -z "${OUT_SSH_IDENTITY:-}" ]]; then
    opts+=(-o BatchMode=yes -o NumberOfPasswordPrompts=0)
  fi
  if [[ -n "${OUT_SSH_IDENTITY:-}" ]]; then
    opts+=(-i "${OUT_SSH_IDENTITY}")
  fi
  if [[ "${SSH_USE_MASTER:-0}" == "1" ]]; then
    cp="$(ssh_control_path_for "$host" "$port" "${OUT_SSH_USER:-root}")"
    ssh_prune_stale_control_socket_for "$host" "$port" "$kh" >/dev/null 2>&1 || true
    opts+=(-o ControlMaster=auto -o ControlPersist=600 -o ControlPath="$cp")
  else
    opts+=(-o ControlMaster=no)
  fi

  if (( have_pw == 1 )); then
    SSHPASS="${OUT_SSH_PASS}" sshpass -e ssh -p "$port" "${flags[@]}" "${opts[@]}" "${OUT_SSH_USER}@${host}" "$@"
    rc=$?
  else
    ssh -p "$port" "${flags[@]}" "${opts[@]}" "${OUT_SSH_USER}@${host}" "$@"
    rc=$?
  fi

  # Same host-key rotation/rebuild handling as ssh_exec_cmd_on().  This path is
  # used by installer steps that pipe scripts over SSH, so it must not be the
  # one place where a stale OUT signature can still break the install.
  if (( rc == 255 )); then
    ssh_forget_known_host_for "$host" "$port" "$kh" >/dev/null 2>&1 || true
    ssh_prepare_known_hosts_for "$host" "$port" "$kh" >/dev/null 2>&1 || true
    if (( have_pw == 1 )); then
      SSHPASS="${OUT_SSH_PASS}" sshpass -e ssh -p "$port" "${flags[@]}" "${opts[@]}" "${OUT_SSH_USER}@${host}" "$@"
      rc=$?
    else
      ssh -p "$port" "${flags[@]}" "${opts[@]}" "${OUT_SSH_USER}@${host}" "$@"
      rc=$?
    fi
  fi
  return "$rc"
}

ssh_run_stdin(){
  # Run a stdin script on the remote host (non-root).
  local target host port label
  target="$(ssh_pick_working_target 2>/dev/null || true)"
  if [[ -z "$target" ]]; then
    cat >/dev/null 2>&1 || true
    return 1
  fi
  IFS=$'\t' read -r host port label <<<"$target"
  ssh_exec_stdin_on "$host" "$port" "$label" bash -s
}

ensure_remote_sudo(){
  # Determine whether we need sudo on the remote side, once per session.
  # Sets REMOTE_SUDO to "" (root) or "sudo -n" (passwordless sudo).
  [[ "${REMOTE_SUDO_DETECTED:-0}" == "1" ]] && return 0

  ssh_check_quiet || return 1

  local uid
  uid="$(ssh_run "id -u" 2>/dev/null | tr -d '\r' | tail -n1 || true)"
  if [[ "$uid" == "0" ]]; then
    REMOTE_SUDO=""
    REMOTE_SUDO_DETECTED="1"
    return 0
  fi

  if ssh_run "sudo -n true >/dev/null 2>&1 && echo OK || echo NO" 2>/dev/null | tr -d '\r' | tail -n1 | grep -qx OK; then
    REMOTE_SUDO="sudo -n"
    REMOTE_SUDO_DETECTED="1"
    return 0
  fi

  return 1
}

ssh_run_root(){
  # Run a command as root on the remote host (auto-uses sudo -n if available).
  local cmd="$1"
  ensure_remote_sudo || die "Remote root access is not available (use root SSH or enable passwordless sudo)."
  if [[ -n "${REMOTE_SUDO:-}" ]]; then
    ssh_run "${REMOTE_SUDO} bash -lc $(printf %q "$cmd")"
  else
    ssh_run "$cmd"
  fi
}

# -------------------- Best-effort root helpers --------------------
# These are used by cleanup/delete paths. They MUST NOT abort the whole program
# if remote root access is unavailable.

ssh_run_root_best_effort(){
  local cmd="$1"
  if ! ensure_remote_sudo; then
    warn "Remote root access is not available; skipping remote step."
    return 1
  fi
  if [[ -n "${REMOTE_SUDO:-}" ]]; then
    ssh_run "${REMOTE_SUDO} bash -lc $(printf %q "$cmd")" 2>/dev/null
  else
    ssh_run "$cmd" 2>/dev/null
  fi
}

ssh_run_stdin_root_best_effort(){
  if ! ensure_remote_sudo; then
    warn "Remote root access is not available; skipping remote step."
    cat >/dev/null 2>&1 || true
    return 1
  fi
  local target host port label
  target="$(ssh_pick_working_target 2>/dev/null || true)"
  if [[ -z "$target" ]]; then
    cat >/dev/null 2>&1 || true
    return 1
  fi
  IFS=$'\t' read -r host port label <<<"$target"
  local -a rcmd=(bash -s)
  if [[ -n "${REMOTE_SUDO:-}" ]]; then
    rcmd=(sudo -n bash -s)
  fi
  ssh_exec_stdin_on "$host" "$port" "$label" "${rcmd[@]}"
}

ssh_run_stdin_env_root_best_effort(){
  if ! ensure_remote_sudo; then
    warn "Remote root access is not available; skipping remote step."
    cat >/dev/null 2>&1 || true
    return 1
  fi
  local -a envs=("$@")
  local target host port label
  target="$(ssh_pick_working_target 2>/dev/null || true)"
  if [[ -z "$target" ]]; then
    cat >/dev/null 2>&1 || true
    return 1
  fi
  IFS=$'\t' read -r host port label <<<"$target"
  local -a rcmd=()
  if [[ -n "${REMOTE_SUDO:-}" ]]; then
    rcmd+=(sudo -n)
  fi
  rcmd+=(env)
  rcmd+=("${envs[@]}")
  rcmd+=(bash -s)
  ssh_exec_stdin_on "$host" "$port" "$label" "${rcmd[@]}"
}

ssh_run_stdin_root(){
  # Run a stdin script as root on the remote host (auto-uses sudo -n if available).
  ensure_remote_sudo || die "Remote root access is not available (use root SSH or enable passwordless sudo)."
  local target host port label
  target="$(ssh_pick_working_target 2>/dev/null || true)"
  if [[ -z "$target" ]]; then
    cat >/dev/null 2>&1 || true
    return 1
  fi
  IFS=$'\t' read -r host port label <<<"$target"
  local -a rcmd=(bash -s)
  if [[ -n "${REMOTE_SUDO:-}" ]]; then
    rcmd=(sudo -n bash -s)
  fi
  ssh_exec_stdin_on "$host" "$port" "$label" "${rcmd[@]}"
}

ssh_run_stdin_env_root(){
  # Run a stdin script as root, with environment variables set (KEY=VALUE pairs).
  ensure_remote_sudo || die "Remote root access is not available (use root SSH or enable passwordless sudo)."
  local -a envs=("$@")
  local target host port label
  target="$(ssh_pick_working_target 2>/dev/null || true)"
  if [[ -z "$target" ]]; then
    cat >/dev/null 2>&1 || true
    return 1
  fi
  IFS=$'\t' read -r host port label <<<"$target"
  local -a rcmd=()
  if [[ -n "${REMOTE_SUDO:-}" ]]; then
    rcmd+=(sudo -n)
  fi
  rcmd+=(env)
  rcmd+=("${envs[@]}")
  rcmd+=(bash -s)
  ssh_exec_stdin_on "$host" "$port" "$label" "${rcmd[@]}"
}

ssh_check_quiet(){
  # Non-interactive SSH check (no prompting). Good for background checks.
  ssh_require_vars >/dev/null 2>&1 || return 1
  local target
  target="$(ssh_pick_working_target 2>/dev/null || true)"
  [[ -n "$target" ]]
}

ssh_autodetect_port(){
  # Try to find the correct SSH port when OUT_SSH_PORT is wrong.
  ssh_require_vars || return 1
  local host="${OUT_SSH_HOST}" user="${OUT_SSH_USER:-root}"
  local ident_opt=()
  [[ -n "${OUT_SSH_IDENTITY:-}" ]] && ident_opt=(-i "${OUT_SSH_IDENTITY}")

  local -a cand=( "${OUT_SSH_PORT:-22}" 22 2222 2233 2200 2022 222 22222 9922 10022 443 8443 8080 80 10443 992 50022 60022 65522 )
  local -A seen=()
  local -a uniq=()
  local p
  for p in "${cand[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    [[ -n "${seen[$p]:-}" ]] && continue
    seen["$p"]=1
    uniq+=("$p")
  done

  local first_open=""
  for p in "${uniq[@]}"; do
    tcp_port_open "$host" "$p" || continue
    [[ -z "$first_open" ]] && first_open="$p"
    tcp_port_is_ssh "$host" "$p" || continue

    local kh_p; kh_p="$(ssh_known_hosts_file_for "$host" "$p")"
    ssh_prepare_known_hosts_for "$host" "$p" "$kh_p" >/dev/null 2>&1 || true

    if [[ -n "${OUT_SSH_PASS:-}" ]] && have_cmd sshpass; then
      if SSHPASS="${OUT_SSH_PASS}" sshpass -e ssh -p "$p" \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh_p" -o GlobalKnownHostsFile=/dev/null -o CheckHostIP=no -o UpdateHostKeys=no \
        -o ConnectTimeout="${AZHDAR_SSH_CONNECT_TIMEOUT:-8}" -o ServerAliveInterval=10 -o ServerAliveCountMax=1 \
        -o NumberOfPasswordPrompts=1 \
        "${ident_opt[@]}" "${user}@${host}" "true" >/dev/null 2>&1; then
        echo "$p"; return 0
      fi
    else
      if [[ -z "${OUT_SSH_PASS:-}" && -z "${OUT_SSH_IDENTITY:-}" ]]; then
        echo "$p"; return 0
      fi
      if ssh -p "$p" \
        -o BatchMode=yes \
        -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="$kh_p" -o GlobalKnownHostsFile=/dev/null -o CheckHostIP=no -o UpdateHostKeys=no \
        -o ConnectTimeout="${AZHDAR_SSH_CONNECT_TIMEOUT:-8}" -o ServerAliveInterval=10 -o ServerAliveCountMax=1 \
        "${ident_opt[@]}" "${user}@${host}" "true" >/dev/null 2>&1; then
        echo "$p"; return 0
      fi
    fi
  done
  [[ -n "$first_open" ]] && { echo "$first_open"; return 0; }
  return 1
}

ssh_check_success_msg(){
  if [[ "${SSH_ACTIVE_TRANSPORT:-direct}" == "wg" ]]; then
    ok "SSH OK via WG management path (${SSH_ACTIVE_HOST}:${SSH_ACTIVE_PORT})."
  else
    ok "SSH OK."
  fi
  ssh_refresh_remote_known_hosts_best_effort >/dev/null 2>&1 || true
}

ssh_check_run_once(){
  local quiet="${1:-1}"
  if [[ "$quiet" == "1" ]]; then
    ssh_run "echo OK" >/dev/null 2>&1
  else
    ssh_run "echo OK"
  fi
}

ssh_check(){
  # SSH checks are allowed to fail during interactive setup. Never let a failed
  # probe trip the global ERR trap and throw the user back to the shell.
  local _had_errexit=0
  case "$-" in *e*) _had_errexit=1; set +e ;; esac

  ssh_require_vars
  local req_rc=$?
  if (( req_rc != 0 )); then
    (( _had_errexit == 1 )) && set -e
    return "$req_rc"
  fi

  local mode="${SSH_MGMT_TRANSPORT:-auto}" wg=""
  wg="$(ssh_wg_mgmt_host 2>/dev/null || true)"
  if [[ -n "$wg" && "$mode" != "direct" && "$mode" != "public" ]]; then
    info "Checking SSH to ${OUT_SSH_USER}@${OUT_SSH_HOST}:${OUT_SSH_PORT} (auto; WG fallback ${wg}:${OUT_SSH_PORT}) ..."
  else
    info "Checking SSH to ${OUT_SSH_USER}@${OUT_SSH_HOST}:${OUT_SSH_PORT} ..."
  fi

  local interactive=0 have_pw=0 quiet=1
  ssh_can_prompt && interactive=1 || true
  [[ -n "${OUT_SSH_PASS:-}" && "$(command -v sshpass 2>/dev/null || true)" != "" ]] && have_pw=1 || true
  if (( interactive == 1 )) && (( have_pw == 0 )) && [[ -z "${OUT_SSH_IDENTITY:-}" ]]; then
    quiet=0
  fi

  ssh_check_run_once "$quiet"
  local rc=$?
  if (( rc == 0 )); then
    ssh_check_success_msg
    (( _had_errexit == 1 )) && set -e
    return 0
  fi

  # If password-based non-interactive auth failed, do not pretend the port is
  # wrong. Ask once for a corrected password, or let the user fall back to a real
  # interactive ssh prompt. This fixes the common case where manual ssh works but
  # AZHDAR had a wrong/empty password cached.
  if (( interactive == 1 )) && (( have_pw == 1 )); then
    warn "SSH password/non-interactive auth did not succeed. The port may still be correct."
    local _retry_pw=""
    read -rsp "Re-enter OUT SSH password, or press ENTER to try interactive SSH prompt: " _retry_pw || true
    echo
    if [[ -n "${_retry_pw:-}" ]]; then
      OUT_SSH_PASS="${_retry_pw}"
      if command -v sshpass >/dev/null 2>&1; then
        ssh_check_run_once 1
        rc=$?
        if (( rc == 0 )); then
          profile_save >/dev/null 2>&1 || true
          ssh_check_success_msg
          (( _had_errexit == 1 )) && set -e
          return 0
        fi
      fi
      warn "SSH password retry failed."
    else
      OUT_SSH_PASS=""
      info "Trying interactive SSH. Accept the host key and enter the server password if prompted."
      ssh_check_run_once 0
      rc=$?
      if (( rc == 0 )); then
        warn "Manual interactive SSH worked, but no password/key is saved for non-interactive install steps."
        local _save_pw=""
        read -rsp "Enter OUT SSH password to save for the rest of this install, or press ENTER to continue with interactive prompts: " _save_pw || true
        echo
        if [[ -n "${_save_pw:-}" ]]; then
          OUT_SSH_PASS="${_save_pw}"
          ssh_ensure_sshpass_for_password >/dev/null 2>&1 || true
          profile_save >/dev/null 2>&1 || true
        fi
        ssh_check_success_msg
        (( _had_errexit == 1 )) && set -e
        return 0
      fi
    fi
  fi

  local direct_is_ssh=0
  if tcp_port_open "${OUT_SSH_HOST}" "${OUT_SSH_PORT}" && tcp_port_is_ssh "${OUT_SSH_HOST}" "${OUT_SSH_PORT}"; then
    direct_is_ssh=1
  fi

  err "SSH failed on port ${OUT_SSH_PORT}."
  if (( direct_is_ssh == 1 )); then
    warn "Port ${OUT_SSH_PORT} is open and speaks SSH. This looks like authentication/host-key handling, not a closed port."
    echo -e "${DIM}Manual test:${RST} ssh -o StrictHostKeyChecking=accept-new -p ${OUT_SSH_PORT} ${OUT_SSH_USER}@${OUT_SSH_HOST}"
    echo -e "${DIM}Fix:${RST} Use the correct root password, or add/set an SSH identity file, then retry."
    (( _had_errexit == 1 )) && set -e
    return 1
  fi

  # If OUT public SSH port changed, try to auto-detect it on the public SSH host.
  local detected=""
  detected="$(ssh_autodetect_port 2>/dev/null || true)"
  if [[ -n "${detected:-}" && "${detected}" != "${OUT_SSH_PORT}" ]]; then
    warn "Detected open SSH port ${detected}. Updating profile (OUT_SSH_PORT ${OUT_SSH_PORT} → ${detected})."
    OUT_SSH_PORT="${detected}"
    SSH_MGMT_LAST_TRANSPORT=""
    SSH_MGMT_LAST_HOST=""
    SSH_MGMT_LAST_PORT=""
    profile_save >/dev/null 2>&1 || true

    info "Re-checking SSH on port ${OUT_SSH_PORT} ..."
    ssh_check_run_once "$quiet"
    rc=$?
    if (( rc == 0 )); then
      ssh_check_success_msg
      (( _had_errexit == 1 )) && set -e
      return 0
    fi
  fi

  # Interactive fallback: ask user for the correct port, then retry once.
  if ssh_interactive; then
    local pnew=""
    pnew="$(prompt_port "OUT SSH port" "${OUT_SSH_PORT:-22}")"
    if [[ -n "${pnew:-}" && "${pnew}" != "${OUT_SSH_PORT}" ]]; then
      OUT_SSH_PORT="${pnew}"
      SSH_MGMT_LAST_TRANSPORT=""
      SSH_MGMT_LAST_HOST=""
      SSH_MGMT_LAST_PORT=""
      profile_save >/dev/null 2>&1 || true
    fi

    ssh_check_run_once 0
    rc=$?
    if (( rc == 0 )); then
      ssh_check_success_msg
      (( _had_errexit == 1 )) && set -e
      return 0
    fi
  fi

  err "SSH failed."
  echo -e "${DIM}Quick direct test:${RST} ssh -p ${OUT_SSH_PORT} ${OUT_SSH_USER}@${OUT_SSH_HOST}"
  if [[ -n "$wg" ]]; then
    echo -e "${DIM}Quick WG test:${RST} ssh -p ${OUT_SSH_PORT} ${OUT_SSH_USER}@${wg}"
    echo -e "${DIM}Tip:${RST} If the WG test works while direct public SSH times out, set SSH_MGMT_TRANSPORT=wg or leave it auto."
  fi
  (( _had_errexit == 1 )) && set -e
  return 1
}

