# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Port checks --------------------
_ports_trim(){ echo "${1:-}" | xargs 2>/dev/null || echo "${1:-}"; }

ports_split_csv(){
  # Prints one port per line from a comma-separated list.
  local s="${1:-}"
  s="${s//,/ }"
  local p
  for p in $s; do
    p="$(_ports_trim "$p")"
    [[ -n "$p" ]] && echo "$p"
  done
}

parse_port_range(){
  # usage: parse_port_range "20000-30000" -> "20000 30000"
  # accepts: A-B, A:B, A..B
  local s="${1:-}"
  s="${s//[[:space:]]/}"
  [[ -n "$s" ]] || return 1
  s="${s//../-}"
  s="${s//:/-}"
  if [[ "$s" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
    local a="${BASH_REMATCH[1]}" b="${BASH_REMATCH[2]}"
    (( a >= 1 && a <= 65535 )) || return 1
    (( b >= 1 && b <= 65535 )) || return 1
    if (( a > b )); then
      local t="$a"; a="$b"; b="$t"
    fi
    echo "$a $b"
    return 0
  fi
  return 1
}

local_port_in_use(){
  local port="$1"
  ss -lntu 2>/dev/null | awk '{print $5}' | grep -qE '(:|\])'"${port}"'$'
}

remote_port_in_use(){
  local port="$1"
  ssh_run "${REMOTE_SUDO:-} ss -lntu 2>/dev/null | awk '{print \$5}' | grep -qE '(:|\\])${port}\$'" >/dev/null 2>&1
}


profile_port_reserved(){
  # Legacy helper: returns 0 if WG_PORT is already assigned to another saved profile.
  local port="$1"
  local f name pval
  shopt -s nullglob
  for f in "${PROFILE_DIR}"/*.env; do
    name="${f##*/}"; name="${name%.env}"
    [[ -n "${PROFILE:-}" && "$name" == "${PROFILE}" ]] && continue
    pval="$(grep -E '^WG_PORT=' "$f" 2>/dev/null | head -n1 | sed -E 's/^WG_PORT="?([^"]*)"?$/\1/' || true)"
    [[ "$pval" == "$port" ]] && { shopt -u nullglob; return 0; }
  done
  shopt -u nullglob
  return 1
}

ports_build_registry(){
  # Builds a registry of PUBLIC ports reserved by other profiles.
  # Globals set:
  #   PORT_REG_PROFILE["tcp:443"]="profileA"
  #   PORT_REG_KIND["tcp:443"]="wg"|"fwd-tcp"|"fwd-udp"|"ssh"
  declare -gA PORT_REG_PROFILE=()
  declare -gA PORT_REG_KIND=()
  declare -gA PORT_REG_PROFILE_REMOTE=()
  declare -gA PORT_REG_KIND_REMOTE=()

  local n
  while read -r n; do
    n="$(safe_name "$n")"
    [[ -n "$n" ]] || continue
    [[ -n "${PROFILE:-}" && "$n" == "${PROFILE}" ]] && continue

    local wg_port fwd_tcp fwd_udp sshmap sshmode sshhost
    wg_port="$(profile_read_var "$n" WG_PORT 2>/dev/null || true)"
    fwd_tcp="$(profile_read_var "$n" FORWARD_TCP_PORTS 2>/dev/null || true)"
    fwd_udp="$(profile_read_var "$n" FORWARD_UDP_PORTS 2>/dev/null || true)"
    sshmap="$(profile_read_var "$n" SSH_FWD_TCP_MAP 2>/dev/null || true)"
    sshmode="$(profile_read_var "$n" SSH_FALLBACK_MODE 2>/dev/null || true)"
    sshhost="$(profile_read_var "$n" OUT_SSH_HOST 2>/dev/null || true)"
    [[ -z "$sshhost" ]] && sshhost="$(profile_read_var "$n" OUT_PUBLIC_IP 2>/dev/null || true)"

    if [[ -n "$wg_port" ]]; then
      PORT_REG_PROFILE["tcp:${wg_port}"]="$n"; PORT_REG_KIND["tcp:${wg_port}"]="wg"
      PORT_REG_PROFILE["udp:${wg_port}"]="$n"; PORT_REG_KIND["udp:${wg_port}"]="wg"
    fi

    local p
    while read -r p; do
      [[ -n "$p" ]] || continue
      PORT_REG_PROFILE["tcp:${p}"]="$n"; PORT_REG_KIND["tcp:${p}"]="fwd-tcp"
    done < <(ports_split_csv "$fwd_tcp")

    while read -r p; do
      [[ -n "$p" ]] || continue
      PORT_REG_PROFILE["udp:${p}"]="$n"; PORT_REG_KIND["udp:${p}"]="fwd-udp"
    done < <(ports_split_csv "$fwd_udp")

    # SSH fallback:
    # - local mode: IR listens on OUTPORT(s) (actually local ports) => must be unique on THIS server.
    # - reverse mode: OUT listens on OUTPORT(s) => conflicts matter per-remote-host.
    # Format: OUTPORT=IRHOST:IRPORT,OUTPORT2=...
    if [[ -n "$sshmap" ]]; then
      local item outport
      IFS=',' read -r -a _items <<<"$sshmap"
      for item in "${_items[@]}"; do
        item="$(_ports_trim "$item")"
        outport="${item%%=*}"
        outport="$(_ports_trim "$outport")"
        [[ "$outport" =~ ^[0-9]+$ ]] || continue
        if [[ "${sshmode:-local}" == "reverse" && -n "${sshhost:-}" ]]; then
          PORT_REG_PROFILE_REMOTE["${sshhost}|tcp:${outport}"]="$n"; PORT_REG_KIND_REMOTE["${sshhost}|tcp:${outport}"]="ssh-reverse"
        else
          PORT_REG_PROFILE["tcp:${outport}"]="$n"; PORT_REG_KIND["tcp:${outport}"]="ssh"
        fi
      done
    fi

  done < <(profiles_list)
}

ports_conflict_remote(){
  # usage: ports_conflict_remote <host> <proto> <port> -> prints "profile kind" if reserved
  local host="$1" proto="$2" port="$3"
  ports_build_registry
  local key="${host}|${proto}:${port}"
  if [[ -n "${PORT_REG_PROFILE_REMOTE[$key]:-}" ]]; then
    echo "${PORT_REG_PROFILE_REMOTE[$key]} ${PORT_REG_KIND_REMOTE[$key]}"
    return 0
  fi
  return 1
}

ports_conflict(){
  # usage: ports_conflict <proto> <port>  -> prints "profile kind" if reserved
  local proto="$1" port="$2"
  ports_build_registry
  local key="${proto}:${port}"
  if [[ -n "${PORT_REG_PROFILE[$key]:-}" ]]; then
    echo "${PORT_REG_PROFILE[$key]} ${PORT_REG_KIND[$key]}"
    return 0
  fi
  return 1
}

ports_suggest_free(){
  # usage: ports_suggest_free <proto> <start_port>
  local proto="$1" start="${2:-1024}"
  local p
  ports_build_registry
  for ((p=start; p<=65000; p++)); do
    [[ -n "${PORT_REG_PROFILE[${proto}:${p}]:-}" ]] && continue
    local_port_in_use "$p" && continue
    echo "$p"
    return 0
  done
  echo ""
  return 1
}

ports_suggest_free_near(){
  # usage: ports_suggest_free_near <proto> <desired_port> [range]
  # range optional: "20000-30000" (also accepts A:B or A..B)
  local proto="$1" desired="$2" range="${3:-${AZHDAR_PORT_RANGE:-}}"
  local lo=1024 hi=65000
  if [[ -n "$range" ]]; then
    local rr
    rr="$(parse_port_range "$range" 2>/dev/null || true)"
    if [[ -n "$rr" ]]; then
      lo="${rr%% *}"; hi="${rr##* }"
    fi
  fi

  ports_build_registry

  local max_delta="${AZHDAR_PORT_SUGGEST_DELTA:-250}"
  local d p
  for ((d=0; d<=max_delta; d++)); do
    p=$((desired + d))
    if (( p >= lo && p <= hi )); then
      [[ -n "${PORT_REG_PROFILE[${proto}:${p}]:-}" ]] || {
        if ! local_port_in_use "$p"; then
          echo "$p"; return 0
        fi
      }
    fi
    if (( d == 0 )); then
      continue
    fi
    p=$((desired - d))
    if (( p >= lo && p <= hi )); then
      [[ -n "${PORT_REG_PROFILE[${proto}:${p}]:-}" ]] || {
        if ! local_port_in_use "$p"; then
          echo "$p"; return 0
        fi
      }
    fi
  done

  # Fallback: scan forward within range.
  local start="$desired"
  (( start < lo )) && start="$lo"
  (( start > hi )) && start="$lo"
  local q
  for ((q=start; q<=hi; q++)); do
    [[ -n "${PORT_REG_PROFILE[${proto}:${q}]:-}" ]] && continue
    local_port_in_use "$q" && continue
    echo "$q"; return 0
  done
  echo ""
  return 1
}

ports_suggest_free_near_remote(){
  # usage: ports_suggest_free_near_remote <host> <proto> <desired_port> [range]
  # NOTE: remote_port_in_use() relies on CURRENT profile SSH settings.
  local host="$1" proto="$2" desired="$3" range="${4:-${AZHDAR_PORT_RANGE_REMOTE:-}}"
  local lo=1024 hi=65000
  if [[ -n "$range" ]]; then
    local rr
    rr="$(parse_port_range "$range" 2>/dev/null || true)"
    if [[ -n "$rr" ]]; then
      lo="${rr%% *}"; hi="${rr##* }"
    fi
  fi

  ports_build_registry
  local max_delta="${AZHDAR_PORT_SUGGEST_DELTA_REMOTE:-400}"
  local d p
  for ((d=0; d<=max_delta; d++)); do
    p=$((desired + d))
    if (( p >= lo && p <= hi )); then
      [[ -n "${PORT_REG_PROFILE_REMOTE[${host}|${proto}:${p}]:-}" ]] || {
        if ssh_check_quiet; then
          remote_port_in_use "$p" || { echo "$p"; return 0; }
        else
          echo "$p"; return 0
        fi
      }
    fi
    if (( d == 0 )); then
      continue
    fi
    p=$((desired - d))
    if (( p >= lo && p <= hi )); then
      [[ -n "${PORT_REG_PROFILE_REMOTE[${host}|${proto}:${p}]:-}" ]] || {
        if ssh_check_quiet; then
          remote_port_in_use "$p" || { echo "$p"; return 0; }
        else
          echo "$p"; return 0
        fi
      }
    fi
  done

  # Fallback: scan forward within range.
  local start="$desired"
  (( start < lo )) && start="$lo"
  (( start > hi )) && start="$lo"
  local q
  for ((q=start; q<=hi; q++)); do
    [[ -n "${PORT_REG_PROFILE_REMOTE[${host}|${proto}:${q}]:-}" ]] && continue
    if ssh_check_quiet; then
      remote_port_in_use "$q" && continue
    fi
    echo "$q"; return 0
  done
  echo ""
  return 1
}


ports_csv_remove_port(){
  # usage: ports_csv_remove_port "443,22,8443" "22" -> "443,8443"
  local list="${1:-}" remove="${2:-}"
  local out="" p
  [[ "$remove" =~ ^[0-9]{1,5}$ ]] || { echo "$list"; return 0; }
  while read -r p; do
    [[ -n "$p" ]] || continue
    [[ "$p" =~ ^[0-9]{1,5}$ ]] || continue
    (( p >= 1 && p <= 65535 )) || continue
    if [[ "$p" == "$remove" ]]; then
      continue
    fi
    case ",$out," in
      *,"$p",*) continue ;;
    esac
    if [[ -n "$out" ]]; then out+=",$p"; else out="$p"; fi
  done < <(ports_split_csv "$list")
  echo "$out"
}

protect_ir_ssh_port(){
  # Keeps the IR management SSH port out of public tunnel / DNAT TCP ports.
  # This is intentionally manual: user sets IR_SSH_PORT from the first main-menu item.
  IR_SSH_PORT="${IR_SSH_PORT:-22}"
  if ! [[ "$IR_SSH_PORT" =~ ^[0-9]{1,5}$ ]] || (( IR_SSH_PORT < 1 || IR_SSH_PORT > 65535 )); then
    warn "Invalid IR_SSH_PORT='${IR_SSH_PORT}', falling back to 22."
    IR_SSH_PORT="22"
  fi

  if [[ -n "${FORWARD_TCP_PORTS:-}" ]]; then
    local old_tcp="${FORWARD_TCP_PORTS}"
    FORWARD_TCP_PORTS="$(ports_csv_remove_port "${FORWARD_TCP_PORTS}" "${IR_SSH_PORT}")"
    if [[ "${old_tcp}" != "${FORWARD_TCP_PORTS}" ]]; then
      warn "IR SSH port ${IR_SSH_PORT} removed from TCP forwarding ports."
      if [[ -n "${PROFILE:-}" ]]; then
        profile_save >/dev/null 2>&1 || true
      fi
    fi
  fi
}

ports_csv_contains(){
  # usage: ports_csv_contains "443,8443" "443"
  local list="${1:-}" needle="${2:-}" p
  [[ -n "$needle" ]] || return 1
  while read -r p; do
    [[ -n "$p" ]] || continue
    [[ "$p" == "$needle" ]] && return 0
  done < <(ports_split_csv "$list")
  return 1
}

ports_wg_port_candidate_ok(){
  # WG public port reserves both TCP and UDP in AZHDAR's registry.
  # Return 0 only when neither protocol is reserved and it is not the IR SSH
  # guard port or a public forward port in the CURRENT profile.
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  [[ -n "${IR_SSH_PORT:-}" && "$p" == "${IR_SSH_PORT}" ]] && return 1
  [[ -n "${PORT_REG_PROFILE[tcp:${p}]:-}" ]] && return 1
  [[ -n "${PORT_REG_PROFILE[udp:${p}]:-}" ]] && return 1
  ports_csv_contains "${FORWARD_TCP_PORTS:-}" "$p" && return 1
  ports_csv_contains "${FORWARD_UDP_PORTS:-}" "$p" && return 1
  return 0
}

ports_suggest_wg_free_near(){
  # usage: ports_suggest_wg_free_near <desired_port> [range]
  # Unlike ports_suggest_free_near tcp, this checks BOTH tcp:<port> and udp:<port>
  # because WG_PORT is reserved as a public tunnel port for both protocols.
  local desired="${1:-443}" range="${2:-${AZHDAR_PORT_RANGE:-}}"
  [[ "$desired" =~ ^[0-9]{1,5}$ ]] || desired="443"
  local lo=1024 hi=65000
  if [[ -n "$range" ]]; then
    local rr
    rr="$(parse_port_range "$range" 2>/dev/null || true)"
    if [[ -n "$rr" ]]; then
      lo="${rr%% *}"; hi="${rr##* }"
    fi
  fi

  ports_build_registry

  local max_delta="${AZHDAR_PORT_SUGGEST_DELTA:-250}"
  local d p
  for ((d=0; d<=max_delta; d++)); do
    p=$((desired + d))
    if (( p >= lo && p <= hi )) && ports_wg_port_candidate_ok "$p"; then
      if ! local_port_in_use "$p"; then
        if ssh_check_quiet; then
          remote_port_in_use "$p" || { echo "$p"; return 0; }
        else
          echo "$p"; return 0
        fi
      fi
    fi
    (( d == 0 )) && continue
    p=$((desired - d))
    if (( p >= lo && p <= hi )) && ports_wg_port_candidate_ok "$p"; then
      if ! local_port_in_use "$p"; then
        if ssh_check_quiet; then
          remote_port_in_use "$p" || { echo "$p"; return 0; }
        else
          echo "$p"; return 0
        fi
      fi
    fi
  done

  local start="$desired" q
  (( start < lo )) && start="$lo"
  (( start > hi )) && start="$lo"
  for ((q=start; q<=hi; q++)); do
    ports_wg_port_candidate_ok "$q" || continue
    local_port_in_use "$q" && continue
    if ssh_check_quiet; then
      remote_port_in_use "$q" && continue
    fi
    echo "$q"; return 0
  done
  echo ""
  return 1
}

ports_forward_tcp_candidate_ok(){
  # Return 0 if a public TCP forward port can be used on IR.
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]{1,5}$ ]] || return 1
  (( p >= 1 && p <= 65535 )) || return 1
  [[ -n "${IR_SSH_PORT:-}" && "$p" == "${IR_SSH_PORT}" ]] && return 1
  [[ -n "${WG_PORT:-}" && "$p" == "${WG_PORT}" ]] && return 1
  [[ -n "${PORT_REG_PROFILE[tcp:${p}]:-}" ]] && return 1
  local_port_in_use "$p" && return 1
  return 0
}

ports_suggest_forward_tcp_free_near(){
  # usage: ports_suggest_forward_tcp_free_near <desired_port> [range]
  local desired="${1:-443}" range="${2:-${AZHDAR_PORT_RANGE:-}}"
  [[ "$desired" =~ ^[0-9]{1,5}$ ]] || desired="443"
  local lo=1024 hi=65000
  if [[ -n "$range" ]]; then
    local rr
    rr="$(parse_port_range "$range" 2>/dev/null || true)"
    if [[ -n "$rr" ]]; then
      lo="${rr%% *}"; hi="${rr##* }"
    fi
  fi

  ports_build_registry
  local max_delta="${AZHDAR_PORT_SUGGEST_DELTA:-250}"
  local d p
  for ((d=0; d<=max_delta; d++)); do
    p=$((desired + d))
    if (( p >= lo && p <= hi )) && ports_forward_tcp_candidate_ok "$p"; then
      echo "$p"; return 0
    fi
    (( d == 0 )) && continue
    p=$((desired - d))
    if (( p >= lo && p <= hi )) && ports_forward_tcp_candidate_ok "$p"; then
      echo "$p"; return 0
    fi
  done

  local start="$desired" q
  (( start < lo )) && start="$lo"
  (( start > hi )) && start="$lo"
  for ((q=start; q<=hi; q++)); do
    ports_forward_tcp_candidate_ok "$q" || continue
    echo "$q"; return 0
  done
  echo ""
  return 1
}

ports_suggest_forward_tcp_free_preferred(){
  # usage: ports_suggest_forward_tcp_free_preferred <desired_port> [range]
  # First try a user-facing friendly list (8443, Cloudflare-style HTTPS
  # alternates, etc.) while respecting the CURRENT profile's WG_PORT. This
  # prevents the tunnel port (for example 443) from being offered again as a
  # public TCP forward port.
  local desired="${1:-443}" range="${2:-${AZHDAR_PORT_RANGE:-}}" p
  [[ "$desired" =~ ^[0-9]{1,5}$ ]] || desired="443"

  ports_build_registry

  if ports_forward_tcp_candidate_ok "$desired"; then
    echo "$desired"
    return 0
  fi

  local -a preferred=(8443 443 2053 2083 2087 2096 8080 80 4443 9443 10443 11443)
  for p in "${preferred[@]}"; do
    [[ "$p" == "$desired" ]] && continue
    if ports_forward_tcp_candidate_ok "$p"; then
      echo "$p"
      return 0
    fi
  done

  ports_suggest_forward_tcp_free_near "$desired" "$range"
}

ports_auto_fix_forward_tcp_ports(){
  # Mutates FORWARD_TCP_PORTS. In Smart Wizard this prevents a conflict from
  # blocking install: invalid/conflicting public TCP ports are replaced by the
  # nearest usable IR port and the replacement is recorded in
  # AZHDAR_PORT_REPLACEMENTS for the final summary.
  local src="${FORWARD_TCP_PORTS:-}" out="" p sug reason
  AZHDAR_PORT_REPLACEMENTS="${AZHDAR_PORT_REPLACEMENTS:-}"
  ports_build_registry

  while read -r p; do
    [[ -n "$p" ]] || continue
    reason=""
    if ! [[ "$p" =~ ^[0-9]{1,5}$ ]] || (( p < 1 || p > 65535 )); then
      reason="invalid"
    elif [[ -n "${IR_SSH_PORT:-}" && "$p" == "${IR_SSH_PORT}" ]]; then
      reason="IR SSH protected port"
    elif [[ -n "${WG_PORT:-}" && "$p" == "${WG_PORT}" ]]; then
      reason="tunnel port"
    elif [[ -n "${PORT_REG_PROFILE[tcp:${p}]:-}" ]]; then
      reason="reserved by profile ${PORT_REG_PROFILE[tcp:${p}]} (${PORT_REG_KIND[tcp:${p}]:-unknown})"
    elif local_port_in_use "$p"; then
      reason="already listening on IR"
    elif ports_csv_contains "$out" "$p"; then
      reason="duplicate in this profile"
    fi

    if [[ -z "$reason" ]]; then
      if [[ -n "$out" ]]; then out+=",$p"; else out="$p"; fi
      continue
    fi

    sug="$(ports_suggest_forward_tcp_free_preferred "$p" || true)"
    if [[ -n "$sug" ]] && ports_csv_contains "$out" "$sug"; then
      # Avoid duplicates that may have been introduced earlier in this same list.
      local q
      for ((q=sug+1; q<=65000; q++)); do
        ports_csv_contains "$out" "$q" && continue
        ports_forward_tcp_candidate_ok "$q" || continue
        sug="$q"
        break
      done
      ports_csv_contains "$out" "$sug" && sug=""
    fi
    if [[ -n "$sug" ]]; then
      warn "TCP forward port ${p} conflicts (${reason}); Smart Wizard replaced it with ${sug}."
      if [[ -n "${AZHDAR_PORT_REPLACEMENTS:-}" ]]; then
        AZHDAR_PORT_REPLACEMENTS+=", ${p}->${sug} (${reason})"
      else
        AZHDAR_PORT_REPLACEMENTS="${p}->${sug} (${reason})"
      fi
      if [[ -n "$out" ]]; then out+=",$sug"; else out="$sug"; fi
    else
      warn "TCP forward port ${p} conflicts (${reason}) and no free replacement was found; skipping it."
      if [[ -n "${AZHDAR_PORT_REPLACEMENTS:-}" ]]; then
        AZHDAR_PORT_REPLACEMENTS+=", ${p}->skipped (${reason})"
      else
        AZHDAR_PORT_REPLACEMENTS="${p}->skipped (${reason})"
      fi
    fi
  done < <(ports_split_csv "$src")

  FORWARD_TCP_PORTS="$out"
  export AZHDAR_PORT_REPLACEMENTS
}

ports_validate_current_or_warn(){
  # Validate that current profile's PUBLIC ports do not overlap with other profiles.
  # Prints warnings and suggestions. Returns 0 if OK, 1 if conflicts.
  local bad=0
  IR_SSH_PORT="${IR_SSH_PORT:-22}"
  ports_build_registry

  # WG_PORT (reserve both tcp+udp). Empty is valid for imported account profiles.
  local c="" other="" kind=""
  if [[ -n "${WG_PORT:-}" ]]; then
    if ! [[ "${WG_PORT}" =~ ^[0-9]{1,5}$ ]] || (( WG_PORT < 1 || WG_PORT > 65535 )); then
      warn "Invalid WG_PORT '${WG_PORT}'. Choose a port between 1 and 65535."
      bad=1
    else
      if c="$(ports_conflict tcp "${WG_PORT}")"; then
        other="${c%% *}"; kind="${c#* }"
        warn "WG_PORT ${WG_PORT} conflicts with profile '${other}' (${kind})."
        local sug; sug="$(suggest_wg_port || true)"
        [[ -z "$sug" || "$sug" == "$WG_PORT" ]] && sug="$(ports_suggest_wg_free_near "${WG_PORT}" || true)"
        [[ -n "$sug" && "$sug" != "$WG_PORT" ]] && warn "Suggested free tunnel port: ${sug}"
        bad=1
      elif c="$(ports_conflict udp "${WG_PORT}")"; then
        other="${c%% *}"; kind="${c#* }"
        warn "WG_PORT ${WG_PORT} conflicts with profile '${other}' (${kind}, udp side)."
        local sug_udp; sug_udp="$(suggest_wg_port || true)"
        [[ -z "$sug_udp" || "$sug_udp" == "$WG_PORT" ]] && sug_udp="$(ports_suggest_wg_free_near "${WG_PORT}" || true)"
        [[ -n "$sug_udp" && "$sug_udp" != "$WG_PORT" ]] && warn "Suggested free tunnel port: ${sug_udp}"
        bad=1
      fi
    fi
  fi

  # Never allow the tunnel public port to take over the IR SSH management port.
  if [[ -n "${WG_PORT:-}" && -n "${IR_SSH_PORT:-}" && "${WG_PORT:-}" == "${IR_SSH_PORT}" ]]; then
    warn "WG_PORT ${WG_PORT} is the IR SSH exempt port. Choose another tunnel port."
    local sug_ir; sug_ir="$(suggest_wg_port || true)"
    [[ -z "$sug_ir" || "$sug_ir" == "$WG_PORT" ]] && sug_ir="$(ports_suggest_wg_free_near "${WG_PORT}" || true)"
    [[ -n "$sug_ir" && "$sug_ir" != "$WG_PORT" ]] && warn "Suggested free tunnel port: ${sug_ir}"
    bad=1
  fi

  # Current-profile overlaps: the tunnel port and public forward ports cannot share the same TCP/UDP port.
  local curp
  while read -r curp; do
    [[ -n "$curp" ]] || continue
    if [[ -n "${WG_PORT:-}" && "$curp" == "${WG_PORT}" ]]; then
      warn "Forward TCP port ${curp} conflicts with WG_PORT in this profile."
      local sug_cur; sug_cur="$(ports_suggest_forward_tcp_free_near "$curp" || true)"
      [[ -n "$sug_cur" && "$sug_cur" != "$curp" ]] && warn "Suggested free TCP forward port near ${curp}: ${sug_cur}"
      bad=1
    fi
  done < <(ports_split_csv "${FORWARD_TCP_PORTS:-}")
  while read -r curp; do
    [[ -n "$curp" ]] || continue
    if [[ -n "${WG_PORT:-}" && "$curp" == "${WG_PORT}" ]]; then
      warn "Forward UDP port ${curp} conflicts with WG_PORT in this profile."
      bad=1
    fi
  done < <(ports_split_csv "${FORWARD_UDP_PORTS:-}")

  # Forward ports
  local p
  while read -r p; do
    [[ -n "$p" ]] || continue
    if ! [[ "$p" =~ ^[0-9]{1,5}$ ]] || (( p < 1 || p > 65535 )); then
      warn "Invalid forward TCP port '${p}'."
      bad=1
      continue
    fi
    if [[ -n "${IR_SSH_PORT:-}" && "$p" == "${IR_SSH_PORT}" ]]; then
      warn "Forward TCP port ${p} is the IR SSH exempt port and will be skipped."
      bad=1
    fi
    if c="$(ports_conflict tcp "$p")"; then
      other="${c%% *}"; kind="${c#* }"
      warn "Forward TCP port ${p} conflicts with profile '${other}' (${kind})."
      local sug2; sug2="$(ports_suggest_forward_tcp_free_near "$p" || true)"
      [[ -n "$sug2" && "$sug2" != "$p" ]] && warn "Suggested free TCP port near ${p}: ${sug2}"
      bad=1
    fi
  done < <(ports_split_csv "${FORWARD_TCP_PORTS:-}")

  while read -r p; do
    [[ -n "$p" ]] || continue
    if ! [[ "$p" =~ ^[0-9]{1,5}$ ]] || (( p < 1 || p > 65535 )); then
      warn "Invalid forward UDP port '${p}'."
      bad=1
      continue
    fi
    if c="$(ports_conflict udp "$p")"; then
      other="${c%% *}"; kind="${c#* }"
      warn "Forward UDP port ${p} conflicts with profile '${other}' (${kind})."
      local sug3; sug3="$(ports_suggest_free_near udp "$p" || true)"
      [[ -n "$sug3" && "$sug3" != "$p" ]] && warn "Suggested free UDP port near ${p}: ${sug3}"
      bad=1
    fi
  done < <(ports_split_csv "${FORWARD_UDP_PORTS:-}")

  if (( bad == 1 )); then
    return 1
  fi
  return 0
}

suggest_wg_port(){
  ports_build_registry
  local p
  for p in "${WG_PORT_CANDIDATES[@]}"; do
    ports_wg_port_candidate_ok "$p" || continue
    if local_port_in_use "$p"; then
      continue
    fi
    if ssh_check_quiet; then
      if remote_port_in_use "$p"; then
        continue
      fi
    fi
    echo "$p"
    return 0
  done

  local near
  near="$(ports_suggest_wg_free_near "${WG_PORT:-443}" || true)"
  [[ -n "$near" ]] && { echo "$near"; return 0; }
  echo ""
  return 1
}

