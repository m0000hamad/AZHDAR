# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- SSH fallback (TCP only) --------------------

# -------------------- WG teardown helpers (for SSH fallback) --------------------
wg_teardown_local_best_effort(){
  # Stop WG service and bring interface down; remove config so it cannot interfere.
  step "WG teardown (local)"
  systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  systemctl disable "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  wg-quick down "${WG_IF}" >/dev/null 2>&1 || true
  ip link del "${WG_IF}" >/dev/null 2>&1 || true
  rm -f "/etc/wireguard/${WG_IF}.conf" "/etc/wireguard/${WG_IF}.key" "/etc/wireguard/${WG_IF}.psk" >/dev/null 2>&1 || true
  ok "Local WG stopped/cleaned (best-effort)."
}

wg_teardown_remote_best_effort(){
  step "WG teardown (remote)"
  ssh_run "${REMOTE_SUDO:-} systemctl stop wg-quick@${WG_IF} >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  ssh_run "${REMOTE_SUDO:-} systemctl disable wg-quick@${WG_IF} >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  ssh_run "${REMOTE_SUDO:-} wg-quick down ${WG_IF} >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  ssh_run "${REMOTE_SUDO:-} ip link del ${WG_IF} >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  ssh_run "${REMOTE_SUDO:-} rm -f /etc/wireguard/${WG_IF}.conf /etc/wireguard/${WG_IF}.key /etc/wireguard/${WG_IF}.psk >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  ok "Remote WG stopped/cleaned (best-effort)."
}

wg_teardown_both_best_effort(){
  # This mirrors what users were doing manually (cleanup configs), without touching Mimic.
  wg_teardown_remote_best_effort || true
  wg_teardown_local_best_effort || true
}

ssh_fallback_prepare_after_wg_fail(){
  # When WG fails, leftover WG interface/routes can break SSH port forwarding in some environments.
  # Do an automatic best-effort cleanup before enabling SSH fallback.
  warn "Preparing SSH fallback: stopping/cleaning WireGuard configs on BOTH sides (best-effort)..."
  wg_teardown_both_best_effort || true
  # Restart SSH fallback service after cleanup (if exists)
  local svc; svc="$(ssh_fallback_service_name 2>/dev/null || true)"
  if [[ -n "$svc" ]]; then
    systemctl restart "$svc" >/dev/null 2>&1 || true
  fi
}

ssh_fallback_mode_label(){
  case "${SSH_FALLBACK_MODE:-local}" in
    local) echo "local (clients connect to IR IP)" ;;
    reverse) echo "reverse (clients connect to OUT IP)" ;;
    *) echo "${SSH_FALLBACK_MODE:-local}" ;;
  esac
}

ssh_fallback_parse_map(){
  # Input: SSH_FWD_TCP_MAP "PORT=HOST:PORT,PORT=HOST:PORT"
  # Mode:
  #  - local: IR listens on PORT(s) and forwards to OUT HOST:PORT
  #  - reverse: OUT listens on PORT(s) and forwards to IR HOST:PORT
  local mode="${SSH_FALLBACK_MODE:-local}"
  local m="${1:-}"
  m="${m//[$'
''
''	']/}"
  m="${m// /}"
  [[ -n "$m" ]] || return 0

  local IFS=',' item
  for item in $m; do
    [[ -n "$item" ]] || continue
    local lport rhs
    if [[ "$item" == *"="* ]]; then
      lport="${item%%=*}"
      rhs="${item#*=}"
    else
      lport="$item"
      rhs="$item"
    fi

    local thost tport
    if [[ "$rhs" =~ ^[0-9]+$ ]]; then
      thost="127.0.0.1"
      tport="$rhs"
    else
      thost="${rhs%%:*}"
      tport="${rhs##*:}"
      [[ -n "$thost" && -n "$tport" ]] || continue
    fi

    [[ "$lport" =~ ^[0-9]+$ && "$tport" =~ ^[0-9]+$ ]] || continue
    (( lport >= 1 && lport <= 65535 )) || continue
    (( tport >= 1 && tport <= 65535 )) || continue

    if [[ "$mode" == "reverse" ]]; then
      echo "-R ${SSH_FALLBACK_BIND_OUT:-${SSH_FALLBACK_BIND:-0.0.0.0}}:${lport}:${thost}:${tport}"
    else
      echo "-L ${SSH_FALLBACK_BIND_IR:-0.0.0.0}:${lport}:${thost}:${tport}"
    fi
  done
}

ssh_fallback_ports_from_map(){
  # Outputs exposed/listen ports (left side of map)
  local m="${1:-${SSH_FWD_TCP_MAP:-}}"
  m="${m//[$'
''
''	']/}"
  m="${m// /}"
  [[ -n "$m" ]] || return 0
  local IFS=',' item
  for item in $m; do
    [[ -n "$item" ]] || continue
    local lport="${item%%=*}"
    [[ "$lport" =~ ^[0-9]+$ ]] && echo "$lport"
  done
}

ssh_fallback_validate_ports_or_warn(){
  # Validate exposed/listen ports in SSH_FWD_TCP_MAP.
  # - local mode: conflicts are checked on THIS host (global).
  # - reverse mode: conflicts are checked per remote host (grouped).
  local mode="${SSH_FALLBACK_MODE:-local}"
  local host="${OUT_SSH_HOST:-${OUT_PUBLIC_IP:-}}"
  local bad=0
  local p
  while read -r p; do
    [[ -n "$p" ]] || continue
    if [[ "$mode" == "reverse" && -n "$host" ]]; then
      local c
      if c="$(ports_conflict_remote "$host" tcp "$p" 2>/dev/null || true)"; then
        local other kind
        other="${c%% *}"; kind="${c#* }"
        warn "Reverse SSH OUT port ${p} conflicts on remote host '${host}' with profile '${other}' (${kind})."
        local sug
        sug="$(ports_suggest_free_near_remote "$host" tcp "$p" 2>/dev/null || true)"
        [[ -n "$sug" && "$sug" != "$p" ]] && warn "Suggested free OUT port near ${p}: ${sug}"
        bad=1
      fi
      if ssh_check_quiet; then
        if remote_port_in_use "$p"; then
          warn "Reverse SSH OUT port ${p} appears to be in use on remote host (ss/listen)."
          local sug2
          sug2="$(ports_suggest_free_near_remote "$host" tcp "$p" 2>/dev/null || true)"
          [[ -n "$sug2" && "$sug2" != "$p" ]] && warn "Suggested free OUT port near ${p}: ${sug2}"
          bad=1
        fi
      fi
    else
      if [[ -n "${IR_SSH_PORT:-}" && "$p" == "${IR_SSH_PORT}" ]]; then
        warn "SSH fallback IR port ${p} is the protected IR SSH management port. Choose another exposed port."
        bad=1
      fi
      local c2
      if c2="$(ports_conflict tcp "$p" 2>/dev/null || true)"; then
        local other2 kind2
        other2="${c2%% *}"; kind2="${c2#* }"
        warn "SSH fallback IR port ${p} conflicts with profile '${other2}' (${kind2})."
        local sug3
        sug3="$(ports_suggest_free_near tcp "$p" 2>/dev/null || true)"
        [[ -n "$sug3" && "$sug3" != "$p" ]] && warn "Suggested free IR port near ${p}: ${sug3}"
        bad=1
      fi
      if local_port_in_use "$p"; then
        warn "SSH fallback IR port ${p} appears to be in use on this host (ss/listen)."
        local sug4
        sug4="$(ports_suggest_free_near tcp "$p" 2>/dev/null || true)"
        [[ -n "$sug4" && "$sug4" != "$p" ]] && warn "Suggested free IR port near ${p}: ${sug4}"
        bad=1
      fi
    fi
  done < <(ssh_fallback_ports_from_map "${SSH_FWD_TCP_MAP:-}")

  (( bad == 0 )) && return 0
  return 1
}

ssh_fallback_local_allow_ports(){
  # Best-effort allow on IR (this host)
  local ports=("$@")
  [[ "${#ports[@]}" -gt 0 ]] || return 0
  azhdar_firewall_safety_local || true
  local p
  for p in "${ports[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    if [[ -n "${IR_SSH_PORT:-}" && "$p" == "${IR_SSH_PORT}" ]]; then
      warn "Skipping SSH fallback bind/allow for protected IR SSH port ${p}."
      continue
    fi
    if command -v iptables >/dev/null 2>&1; then
      iptables -C INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 || iptables -I INPUT -p tcp --dport "$p" -j ACCEPT >/dev/null 2>&1 || true
    fi
    if command -v ufw >/dev/null 2>&1; then
      ufw allow "$p"/tcp >/dev/null 2>&1 || true
    fi
  done
  persist_iptables_local >/dev/null 2>&1 || true
  ok "Local firewall allow rules applied (best-effort)."
}

ssh_fallback_autoconfigure_noninteractive(){
  # Auto-config used when WG cannot connect.
  # Goal: clients MUST connect to IR IP using the SAME public TCP ports defined in the WG/forward wizard.
  SSH_FALLBACK_ENABLED="1"
  SSH_FALLBACK_AUTOSTART="${SSH_FALLBACK_AUTOSTART:-1}"
  SSH_FALLBACK_AUTO_ON_WG_FAIL="${SSH_FALLBACK_AUTO_ON_WG_FAIL:-1}"
  SSH_FALLBACK_AUTO_ON_WG_DROP="${SSH_FALLBACK_AUTO_ON_WG_DROP:-0}"

  # Force IR-facing mode (as requested): clients connect to IR; IR forwards to OUT over SSH (-L).
  SSH_FALLBACK_MODE="local"
  SSH_FALLBACK_BIND_IR="${SSH_FALLBACK_BIND_IR:-0.0.0.0}"

  # Best-effort back-compat vars (older versions used SSH_FALLBACK_BIND/SSH_FALLBACK_BIND_OUT).
  SSH_FALLBACK_BIND_OUT="${SSH_FALLBACK_BIND_OUT:-${SSH_FALLBACK_BIND:-0.0.0.0}}"
  SSH_FALLBACK_BIND="${SSH_FALLBACK_BIND_OUT}"

  # Build the TCP map automatically from the SAME ports the user configured for clients.
  # Priority:
  #  1) FORWARD_TCP_PORTS (wizard: "Public TCP port(s) on IR to forward")
  #  2) VLESS_DST_PORT (wizard: "Destination port on OUT (service bind port)") as single exposed port
  #  3) Default 666
  #
  # In local mode, each exposed port on IR forwards to OUT:127.0.0.1:<dst>.
  # If VLESS_DST_PORT is set, it is used as <dst> for all ports (mirrors the forward-wizard behavior).
  if [[ -z "${SSH_FWD_TCP_MAP:-}" ]]; then
    local ports_src=""
    if [[ -n "${FORWARD_TCP_PORTS:-}" ]]; then
      ports_src="${FORWARD_TCP_PORTS}"
    elif [[ -n "${VLESS_DST_PORT:-}" ]]; then
      ports_src="${VLESS_DST_PORT}"
    else
      ports_src="666"
    fi

    local dst="${VLESS_DST_PORT:-}"
    local out=""
    local IFS=',' p
    for p in ${ports_src// /}; do
      [[ -n "$p" ]] || continue
      [[ "$p" =~ ^[0-9]+$ ]] || continue
      local tport="${dst:-$p}"
      out+="${out:+,}${p}=127.0.0.1:${tport}"
    done
    SSH_FWD_TCP_MAP="${out}"
  fi

  profile_save >/dev/null 2>&1 || true
  ok "SSH fallback auto-config saved (mode=$(ssh_fallback_mode_label), ports=${FORWARD_TCP_PORTS:-${VLESS_DST_PORT:-666}})."
}

ssh_fallback_autoconfigure_reverse_noninteractive(){
  # Auto-config used when WG cannot connect and user chooses SSH reverse tunnel.
  # Goal: clients connect to OUT IP; OUT exposes the SAME public TCP ports and forwards them to IR over SSH (-R).
  SSH_FALLBACK_ENABLED="1"
  SSH_FALLBACK_AUTOSTART="${SSH_FALLBACK_AUTOSTART:-1}"
  SSH_FALLBACK_AUTO_ON_WG_FAIL="${SSH_FALLBACK_AUTO_ON_WG_FAIL:-1}"
  SSH_FALLBACK_AUTO_ON_WG_DROP="${SSH_FALLBACK_AUTO_ON_WG_DROP:-0}"

  SSH_FALLBACK_MODE="reverse"
  SSH_FALLBACK_BIND_OUT="${SSH_FALLBACK_BIND_OUT:-0.0.0.0}"
  SSH_FALLBACK_BIND="${SSH_FALLBACK_BIND_OUT}"

  # Build the TCP map automatically from the SAME ports the user configured for clients.
  # Priority:
  #  1) FORWARD_TCP_PORTS
  #  2) VLESS_DST_PORT as single exposed port
  #  3) Default 666
  #
  # Reverse mode format: OUTPORT=IRHOST:IRPORT (IRHOST default 127.0.0.1)
  if [[ -z "${SSH_FWD_TCP_MAP:-}" ]]; then
    local ports_src=""
    if [[ -n "${FORWARD_TCP_PORTS:-}" ]]; then
      ports_src="${FORWARD_TCP_PORTS}"
    elif [[ -n "${VLESS_DST_PORT:-}" ]]; then
      ports_src="${VLESS_DST_PORT}"
    else
      ports_src="666"
    fi

    local dst="${VLESS_DST_PORT:-}"
    local out=""
    local IFS=',' p
    for p in ${ports_src// /}; do
      [[ -n "$p" ]] || continue
      [[ "$p" =~ ^[0-9]+$ ]] || continue
      local tport="${dst:-$p}"
      out+="${out:+,}${p}=127.0.0.1:${tport}"
    done
    SSH_FWD_TCP_MAP="${out}"
  fi

  profile_save >/dev/null 2>&1 || true
  ok "SSH fallback auto-config saved (mode=$(ssh_fallback_mode_label), ports=${FORWARD_TCP_PORTS:-${VLESS_DST_PORT:-666}})."
}

ssh_fallback_deps_local(){
  step "Install SSH fallback dependencies (local)"
  local pm; pm="$(detect_pkg_mgr)"
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update -y >/dev/null 2>&1 || true
      apt-get install -y autossh openssh-client >/dev/null 2>&1 || true
      ;;
    dnf) dnf install -y autossh openssh-clients >/dev/null 2>&1 || true ;;
    yum) yum install -y autossh openssh-clients >/dev/null 2>&1 || true ;;
    pacman) pacman -Sy --noconfirm autossh openssh >/dev/null 2>&1 || true ;;
  esac
  have_cmd autossh || warn "autossh not found; fallback can still run with ssh (less stable)."
  have_cmd ssh || die "ssh client not found."

  # If user configured a password-based SSH, ensure sshpass exists for systemd services.
  if [[ -n "${OUT_SSH_PASS:-}" ]] && ! have_cmd sshpass; then
    local pm2; pm2="$(detect_pkg_mgr)"
    case "$pm2" in
      apt) export DEBIAN_FRONTEND=noninteractive; apt-get update -y >/dev/null 2>&1 || true; apt-get install -y sshpass >/dev/null 2>&1 || true ;;
      dnf) dnf install -y sshpass >/dev/null 2>&1 || true ;;
      yum) yum install -y sshpass >/dev/null 2>&1 || true ;;
      pacman) pacman -Sy --noconfirm sshpass >/dev/null 2>&1 || true ;;
    esac
    have_cmd sshpass || warn "sshpass not found; password-based SSH fallback may fail under systemd."
  fi
  ok "Local SSH fallback deps ready."
}

ssh_fallback_ensure_key_auth(){
  step "Ensure key-based SSH auth for fallback service"

  local host="${OUT_SSH_HOST}"
  local port="${OUT_SSH_PORT:-22}"
  local transport="${SSH_FALLBACK_TRANSPORT:-direct}"
  if [[ "$transport" == "wg" && -n "${OUT_WG_IP:-}" ]]; then
    host="${OUT_WG_IP}"
  fi
  local user="${OUT_SSH_USER:-root}"
  local kh; kh="$(ssh_known_hosts_file_for "$host" "$port")"
  ssh_prepare_known_hosts_for "$host" "$port" "$kh" >/dev/null 2>&1 || true

  mkdir -p /root/.ssh >/dev/null 2>&1 || true
  chmod 700 /root/.ssh >/dev/null 2>&1 || true

  local key="/root/.ssh/id_ed25519"
  if [[ ! -f "$key" || ! -f "${key}.pub" ]]; then
    ssh-keygen -t ed25519 -N "" -f "$key" >/dev/null 2>&1 || true
  fi
  chmod 600 "$key" >/dev/null 2>&1 || true

  # Extra safety: never hang here.
  local -a base_opts=(
    -o StrictHostKeyChecking=accept-new
    -o UserKnownHostsFile="${kh:-${SSH_KNOWN_HOSTS_FILE:-$(ssh_known_hosts_file_for "$host" "$port")}}"
    -o GlobalKnownHostsFile=/dev/null
    -o CheckHostIP=no
    -o UpdateHostKeys=no
    -o ConnectTimeout=8
    -o ServerAliveInterval=10
    -o ServerAliveCountMax=1
    -o PreferredAuthentications=publickey,password,keyboard-interactive
    -o KbdInteractiveAuthentication=yes
    -o PasswordAuthentication=yes
    -o PubkeyAuthentication=yes
  )

  local -a ident_opt=()
  if [[ -n "${OUT_SSH_IDENTITY:-}" ]]; then
    ident_opt+=( -i "${OUT_SSH_IDENTITY}" )
  fi

  # 1) Fast key-only check
  if ssh -p "$port" -o BatchMode=yes "${base_opts[@]}" "${ident_opt[@]}" "${user}@${host}" "true" >/dev/null 2>&1; then
    ok "Key-based SSH auth is OK."
    return 0
  fi

  # 2) If no way to authenticate, we cannot install keys automatically.
  local have_pw=0
  if [[ -n "${OUT_SSH_PASS:-}" ]]; then
    have_pw=1
  fi

  if (( have_pw == 0 )) && [[ -z "${OUT_SSH_IDENTITY:-}" ]]; then
    # Interactive prompt (do NOT save unless user already had OUT_SSH_PASS).
    if [[ -t 0 && -t 1 ]]; then
      warn "SSH key auth is not set up yet."
      warn "To avoid hanging, AZHDAR will ask for the SSH password once (not saved)."
      local tmp_pw=""
      read -r -s -p "SSH password for ${user}@${OUT_SSH_HOST} (port ${OUT_SSH_PORT:-22}): " tmp_pw
      echo
      if [[ -n "$tmp_pw" ]]; then
        OUT_SSH_PASS="$tmp_pw"
        have_pw=1
      fi
    fi
  fi

  if (( have_pw == 0 )) && [[ -z "${OUT_SSH_IDENTITY:-}" ]]; then
    warn "No password or identity key available to install an SSH key automatically."
    warn "Fix manually: ssh-copy-id -p ${port} ${user}@${host}"
    return 1
  fi

  # 3) Install our public key on remote authorized_keys (best-effort)
  if (( have_pw == 1 )) && ! have_cmd sshpass; then
    local pm; pm="$(detect_pkg_mgr)"
    case "$pm" in
      apt) export DEBIAN_FRONTEND=noninteractive; apt-get update -y >/dev/null 2>&1 || true; apt-get install -y sshpass >/dev/null 2>&1 || true ;;
      dnf) dnf install -y sshpass >/dev/null 2>&1 || true ;;
      yum) yum install -y sshpass >/dev/null 2>&1 || true ;;
      pacman) pacman -Sy --noconfirm sshpass >/dev/null 2>&1 || true ;;
    esac
  fi

  local pub
  pub="$(cat "${key}.pub" 2>/dev/null || true)"
  [[ -n "$pub" ]] || { warn "Failed to read local public key."; return 1; }

  local rcmd
  rcmd="mkdir -p /root/.ssh && chmod 700 /root/.ssh; touch /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys; grep -qxF $(printf %q \"$pub\") /root/.ssh/authorized_keys || echo $(printf %q \"$pub\") >> /root/.ssh/authorized_keys"

  if (( have_pw == 1 )) && have_cmd sshpass; then
    SSHPASS="${OUT_SSH_PASS}" sshpass -e ssh -p "$port" -tt "${base_opts[@]}" "${ident_opt[@]}" "${user}@${host}" "bash -lc $(printf %q \"$rcmd\")" >/dev/null 2>&1 || true
  else
    ssh -p "$port" -tt "${base_opts[@]}" "${ident_opt[@]}" "${user}@${host}" "bash -lc $(printf %q \"$rcmd\")" >/dev/null 2>&1 || true
  fi

  if ssh -p "$port" -o BatchMode=yes "${base_opts[@]}" "${ident_opt[@]}" "${user}@${host}" "true" >/dev/null 2>&1; then
    ok "SSH key installed for ${user}@${host}."
    return 0
  fi

  warn "SSH key auth is still not working. The fallback service may fail until SSH auth is fixed."
  return 1
}

ssh_fallback_configure_remote_sshd()
{
  step "Configure remote sshd for reverse-tunnels safely (OUT)"
  # Do NOT rewrite /etc/ssh/sshd_config directly. Older versions edited the main
  # file and could leave sshd broken if reload/restart happened with a bad config.
  # This version writes a small drop-in, runs sshd -t, and rolls back on failure.
  local out rc
  out="$(ssh_run_stdin_root <<'REMOTE'
set +e

CFG="/etc/ssh/sshd_config"
CONFD="/etc/ssh/sshd_config.d"
DROP="${CONFD}/99-azhdar-reverse-tunnel.conf"
BACKUP="${CFG}.azhdar.bak.$(date +%s)"
MAIN_CHANGED=0
RELOADED=0

sshd_bin=""
for b in /usr/sbin/sshd /usr/local/sbin/sshd sshd; do
  command -v "$b" >/dev/null 2>&1 && { sshd_bin="$(command -v "$b")"; break; }
  [ -x "$b" ] && { sshd_bin="$b"; break; }
done

test_sshd(){
  [ -n "$sshd_bin" ] || return 0
  "$sshd_bin" -t >/tmp/azhdar-sshd-test.log 2>&1
}

rollback_sshd(){
  rm -f "$DROP" 2>/dev/null || true
  if [ "$MAIN_CHANGED" = "1" ] && [ -f "$BACKUP" ]; then
    cp -a "$BACKUP" "$CFG" 2>/dev/null || true
  fi
}

reload_sshd(){
  # Reload only. Never restart sshd from this automatic path; restart can kill the
  # only active SSH daemon if config or service naming is wrong.
  if command -v systemctl >/dev/null 2>&1; then
    systemctl reload ssh >/dev/null 2>&1 && return 0
    systemctl reload sshd >/dev/null 2>&1 && return 0
  fi
  if command -v service >/dev/null 2>&1; then
    service ssh reload >/dev/null 2>&1 && return 0
    service sshd reload >/dev/null 2>&1 && return 0
  fi
  return 1
}

mkdir -p "$CONFD" 2>/dev/null || { echo "FAILED: cannot create ${CONFD}"; exit 1; }

# If the system uses Include for sshd_config.d, use the drop-in only.
# If it does not, add a single Include line with a backup and only keep it if
# sshd -t succeeds. Never create a blank main config from scratch.
if [ -f "$CFG" ]; then
  cp -a "$CFG" "$BACKUP" 2>/dev/null || true
  if ! grep -Eiq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf([[:space:]]|$)' "$CFG" 2>/dev/null; then
    {
      printf '\n# AZHDAR: load safe drop-in configs\n'
      printf 'Include /etc/ssh/sshd_config.d/*.conf\n'
    } >>"$CFG" || { echo "FAILED: cannot add Include to ${CFG}"; rollback_sshd; exit 1; }
    MAIN_CHANGED=1
  fi
else
  echo "FAILED: ${CFG} is missing; refusing to create/replace main sshd_config"
  exit 1
fi

tmp="$(mktemp /tmp/azhdar-sshd-dropin.XXXXXX)" || { rollback_sshd; echo "FAILED: mktemp"; exit 1; }
cat >"$tmp" <<'EOF'
# Managed by AZHDAR. Safe reverse-tunnel settings only.
# Remove this file to disable AZHDAR SSH fallback sshd tweaks.
AllowTcpForwarding yes
GatewayPorts yes
ClientAliveInterval 30
ClientAliveCountMax 3
EOF

install -m 0644 "$tmp" "$DROP" >/dev/null 2>&1
rm -f "$tmp" 2>/dev/null || true

if ! test_sshd; then
  err="$(cat /tmp/azhdar-sshd-test.log 2>/dev/null | tail -n 5 | tr '\n' ' ' || true)"
  rollback_sshd
  echo "FAILED: sshd config test failed; rolled back. ${err}"
  exit 1
fi

if reload_sshd; then
  RELOADED=1
fi

echo "OK: drop-in=${DROP};configtest=passed;reload=${RELOADED}"
exit 0
REMOTE
)"; rc=$?

  out="$(printf '%s' "$out" | tr -d '\r' | tail -n1)"
  if (( rc == 0 )); then
    ok "Remote sshd fallback settings applied safely: ${out:-ok}."
    return 0
  fi

  warn "Remote sshd fallback settings were NOT applied: ${out:-no status}."
  warn "SSH was not restarted; previous sshd_config should be preserved/rolled back."
  return 1
}

ssh_fallback_remote_allow_ports(){
  # Best-effort allow on OUT (iptables/nft/ufw might vary). We try iptables first.
  local ports=("$@")
  [[ "${#ports[@]}" -gt 0 ]] || return 0
  ssh_run_stdin_root <<'REMOTE'
set -euo pipefail
REMOTE
  # Now run small per-port logic via ssh_run_root to keep quoting simple
  local p
  for p in "${ports[@]}"; do
    [[ "$p" =~ ^[0-9]+$ ]] || continue
    ssh_run_root "
      if command -v iptables >/dev/null 2>&1; then
        iptables -C INPUT -p tcp --dport ${p} -j ACCEPT -m comment --comment ${RULE_TAG} >/dev/null 2>&1 || \
        iptables -I INPUT -p tcp --dport ${p} -j ACCEPT -m comment --comment ${RULE_TAG} >/dev/null 2>&1 || \
        iptables -C INPUT -p tcp --dport ${p} -j ACCEPT >/dev/null 2>&1 || \
        iptables -I INPUT -p tcp --dport ${p} -j ACCEPT >/dev/null 2>&1 || true
      fi
      if command -v nft >/dev/null 2>&1; then
        nft list ruleset 2>/dev/null | grep -q \"dport ${p} accept\" >/dev/null 2>&1 || true
      fi
      if command -v ufw >/dev/null 2>&1; then
        ufw allow ${p}/tcp >/dev/null 2>&1 || true
      fi
    " >/dev/null 2>&1 || true
  done
  ok "Remote firewall allow rules applied (best-effort)."
}

ssh_fallback_service_name(){
  echo "azhdar-ssh-fallback@${PROFILE}.service"
}

ssh_fallback_write_service_local(){
  step "Write systemd service for SSH fallback (local)"
  local svc; svc="$(ssh_fallback_service_name)"
  local unit="/etc/systemd/system/${svc}"

  local host="${OUT_SSH_HOST}"
  local port="${OUT_SSH_PORT:-22}"
  local user="${OUT_SSH_USER:-root}"
  local mode="${SSH_FALLBACK_MODE:-local}"
  local transport="${SSH_FALLBACK_TRANSPORT:-direct}"
  if [[ "$transport" == "wg" && -n "${OUT_WG_IP:-}" ]]; then
    host="${OUT_WG_IP}"
  fi
  local kh; kh="$(ssh_known_hosts_file_for "$host" "$port")"
  ssh_prepare_known_hosts_for "$host" "$port" "$kh" >/dev/null 2>&1 || true

  local -a ident_arr=()
  local ident_opt=""
  if [[ -n "${OUT_SSH_IDENTITY:-}" ]]; then
    ident_arr=( -i "${OUT_SSH_IDENTITY}" )
    ident_opt="-i ${OUT_SSH_IDENTITY}"
  fi

  local fargs
  fargs="$(ssh_fallback_parse_map "${SSH_FWD_TCP_MAP:-}")"
  if [[ -z "${fargs:-}" ]]; then
    warn "No SSH_FWD_TCP_MAP set. Service will not be created."
    return 1
  fi
  local fargs_line
  fargs_line="$(echo "$fargs" | tr '\n' ' ' | xargs 2>/dev/null || echo "$fargs")"

  # Port validation (best-effort warnings + grouped remote checks)
  ssh_fallback_validate_ports_or_warn || true

  # Decide auth method for systemd service.
  # Prefer key-based auth. If not available but OUT_SSH_PASS exists, fall back to sshpass.
  local use_pw=0
  local key_ok=0
  {
    ssh -p "$port" -o BatchMode=yes \
      -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile="${kh:-${SSH_KNOWN_HOSTS_FILE:-$(ssh_known_hosts_file_for "$host" "$port")}}" -o GlobalKnownHostsFile=/dev/null -o CheckHostIP=no -o UpdateHostKeys=no \
      -o ConnectTimeout=8 -o ServerAliveInterval=10 -o ServerAliveCountMax=1 \
      "${ident_arr[@]}" "${user}@${host}" true >/dev/null 2>&1
  } && key_ok=1 || true

  local bin="/usr/bin/autossh"
  local envline=""
  local mopt=""
  if (( key_ok == 1 )); then
    if ! have_cmd autossh; then
      bin="/usr/bin/ssh"
    else
      envline='Environment="AUTOSSH_GATETIME=0"'
      mopt="-M 0"
    fi
  else
    if [[ -n "${OUT_SSH_PASS:-}" ]] && have_cmd sshpass; then
      use_pw=1
      bin="/usr/bin/ssh"
    else
      warn "SSH fallback service requires key-based auth. Password auth is not available (sshpass missing or password not set)."
      warn "Fix: ssh-copy-id -p ${port} ${user}@${host}  (or set OUT_SSH_PASS and install sshpass)."
      if ! have_cmd autossh; then
        bin="/usr/bin/ssh"
      else
        envline='Environment="AUTOSSH_GATETIME=0"'
        mopt="-M 0"
      fi
    fi
  fi

  local gopt=""
  if [[ "$mode" == "local" ]]; then
    gopt="-g"
  fi

  local kh_dir kh_target
  kh_dir="$(dirname "$kh")"
  kh_target="$(ssh_known_host_target_for "$host" "$port")"

  local exec
  if (( use_pw == 1 )); then
    # NOTE: SSHPASS is stored in the unit file; permissions are tightened to 0600.
    envline="Environment=\"SSHPASS=${OUT_SSH_PASS}\""
    exec="/usr/bin/sshpass -e /usr/bin/ssh -N ${gopt} -o BatchMode=no"
  else
    exec="${bin} ${mopt} -N ${gopt} -o BatchMode=yes"
  fi

  cat >"$unit" <<UNIT
[Unit]
Description=AZHDAR SSH fallback (${mode}) (%i)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
${envline}
ExecStartPre=/bin/mkdir -p ${kh_dir}
ExecStartPre=/bin/bash -lc 'tmp=\$(mktemp 2>/dev/null || echo /tmp/azhdar-kh-\$\$); if command -v ssh-keyscan >/dev/null 2>&1 && ssh-keyscan -T 5 -p ${port} ${host} >"\$tmp" 2>/dev/null && [ -s "\$tmp" ]; then touch ${kh}; chmod 600 ${kh}; if command -v ssh-keygen >/dev/null 2>&1; then ssh-keygen -R "${kh_target}" -f ${kh} >/dev/null 2>&1 || true; ssh-keygen -R "${host}" -f ${kh} >/dev/null 2>&1 || true; else : >${kh}; fi; cat "\$tmp" >>${kh}; chmod 600 ${kh}; fi; rm -f "\$tmp" >/dev/null 2>&1 || true'
ExecStart=${exec} \
  -o "ServerAliveInterval 20" -o "ServerAliveCountMax 3" \
  -o "ExitOnForwardFailure yes" \
  -o "StrictHostKeyChecking accept-new" -o "UserKnownHostsFile ${kh}" -o "GlobalKnownHostsFile /dev/null" -o "CheckHostIP no" -o "UpdateHostKeys no" \
  -o "ConnectTimeout 8" \
  -p ${port} ${ident_opt} ${fargs_line} ${user}@${host}
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
UNIT

  if (( use_pw == 1 )); then
    chmod 600 "$unit" 2>/dev/null || true
  else
    chmod 644 "$unit" 2>/dev/null || true
  fi
  systemctl daemon-reload >/dev/null 2>&1 || true
  ok "Service written: ${unit}"
}



ssh_fallback_start(){
  ensure_profile_selected || return 1
  defaults_profile
  SSH_FALLBACK_ENABLED="1"
  profile_save >/dev/null 2>&1 || true

  ssh_fallback_deps_local
  remote_preflight >/dev/null 2>&1 || true

  # If user selected Mimic SSH transport, ensure WG tunnel is reachable; otherwise offer fallback to direct.
  if [[ "${SSH_FALLBACK_TRANSPORT:-direct}" == "wg" ]]; then
    if [[ "${ENABLE_TUN_IPV4:-1}" != "1" || -z "${OUT_WG_IP:-}" ]] || ! ping4_local_once "${OUT_WG_IP:-}"; then
      warn "Mimic SSH transport requires an active WG tunnel, but the tunnel is not reachable."
      if [[ "$(prompt_yesno "Start fallback using DIRECT SSH instead?" "Y")" == "Y" ]]; then
        SSH_FALLBACK_TRANSPORT="direct"
        profile_save >/dev/null 2>&1 || true
      else
        return 1
      fi
    fi
  fi

  ssh_fallback_ensure_key_auth || true
  ssh_fallback_configure_remote_sshd || true

  local mode="${SSH_FALLBACK_MODE:-local}"

  local ports=()
  local p
  while read -r p; do
    [[ -n "$p" ]] && ports+=("$p")
  done < <(ssh_fallback_ports_from_map "${SSH_FWD_TCP_MAP:-}")

  if [[ "$mode" == "reverse" ]]; then
    ssh_fallback_remote_allow_ports "${ports[@]}" || true
  else
    ssh_fallback_local_allow_ports "${ports[@]}" || true
  fi

  ssh_fallback_write_service_local || return 1

  local svc; svc="$(ssh_fallback_service_name)"
  if [[ "${SSH_FALLBACK_AUTOSTART:-1}" == "1" ]]; then
    systemctl enable --now "$svc" >/dev/null 2>&1 || true
  else
    systemctl start "$svc" >/dev/null 2>&1 || true
  fi

  sleep 1 >/dev/null 2>&1 || true
  if ! systemctl is-active --quiet "$svc" 2>/dev/null; then
    err "SSH fallback failed to start."
    systemctl status "$svc" --no-pager -l 2>/dev/null || true
    journalctl -u "$svc" -n 120 --no-pager -l 2>/dev/null || true
    ssh_fallback_hints || true
    return 1
  fi

  ok "SSH fallback started."
}

ssh_fallback_stop(){
  ensure_profile_selected || return 1
  local svc; svc="$(ssh_fallback_service_name)"
  systemctl stop "$svc" >/dev/null 2>&1 || true
  systemctl disable "$svc" >/dev/null 2>&1 || true
  ok "SSH fallback stopped."
}

ssh_fallback_remove(){
  # Stop/disable the fallback service and clear profile settings (best-effort).
  ensure_profile_selected || return 1
  profile_load "$CURRENT_PROFILE" 2>/dev/null || true

  banner
  echo -e "${BOLD}${WHT}Remove / Reset SSH fallback (${PROFILE})${RST}"
  hr
  echo -e "${DIM}This will:${RST}
  - stop + disable the SSH fallback service
  - delete its systemd unit file
  - clear SSH fallback map/settings in this profile
Notes:
  - Firewall allow rules (if added) are NOT removed automatically.${RST}"
  hr

  if [[ "$(prompt_yesno "Proceed?" "N")" != "Y" ]]; then
    info "Cancelled."
    return 0
  fi

  local svc; svc="$(ssh_fallback_service_name)"
  systemctl stop "$svc" >/dev/null 2>&1 || true
  systemctl disable "$svc" >/dev/null 2>&1 || true

  # Disable auto-failover watchdog (if enabled)
  ssh_fallback_watchdog_disable_current_profile >/dev/null 2>&1 || true

  # Remove unit file (location varies by distro)
  rm -f "/etc/systemd/system/${svc}" "/lib/systemd/system/${svc}" "/usr/lib/systemd/system/${svc}" >/dev/null 2>&1 || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed "$svc" >/dev/null 2>&1 || true

  # Clear profile flags/settings (do not touch OUT_SSH_* used by other parts)
  SSH_FALLBACK_ENABLED="0"
  SSH_FALLBACK_AUTOSTART="0"
  SSH_FALLBACK_AUTO_ON_WG_FAIL="0"
  SSH_FALLBACK_AUTO_ON_WG_DROP="0"
  SSH_FALLBACK_MODE="local"
  SSH_FWD_TCP_MAP=""
  SSH_FALLBACK_BIND_IR="${SSH_FALLBACK_BIND_IR:-0.0.0.0}"
  SSH_FALLBACK_BIND_OUT="${SSH_FALLBACK_BIND_OUT:-${SSH_FALLBACK_BIND:-0.0.0.0}}"
  SSH_FALLBACK_BIND="${SSH_FALLBACK_BIND_OUT}"

  profile_save >/dev/null 2>&1 || true
  ok "SSH fallback removed/reset for this profile."
}

ssh_fallback_restart_sshd(){
  # Safe reload local + remote ssh/sshd. Config is tested first; no automatic
  # restart is attempted because a restart can lock the operator out.
  ensure_profile_selected || return 1
  profile_load "$CURRENT_PROFILE" 2>/dev/null || true

  banner
  echo -e "${BOLD}${WHT}Safe reload SSH service (local + remote)${RST}"
  hr
  echo -e "${DIM}This runs sshd -t first, then reloads ssh/sshd. It will NOT restart SSH automatically.${RST}"
  hr

  if [[ "$(prompt_yesno "Proceed?" "N")" != "Y" ]]; then
    info "Cancelled."
    return 0
  fi

  step "Safe reload SSH service (local)"
  local local_ok=0
  local sshd_bin=""
  for b in /usr/sbin/sshd /usr/local/sbin/sshd sshd; do
    command -v "$b" >/dev/null 2>&1 && { sshd_bin="$(command -v "$b")"; break; }
    [[ -x "$b" ]] && { sshd_bin="$b"; break; }
  done
  if [[ -n "$sshd_bin" ]] && ! "$sshd_bin" -t >/tmp/azhdar-sshd-local-test.log 2>&1; then
    warn "Local sshd config test failed; local SSH reload skipped."
    tail -n 5 /tmp/azhdar-sshd-local-test.log 2>/dev/null || true
  else
    if command -v systemctl >/dev/null 2>&1; then
      systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1
      [[ $? -eq 0 ]] && local_ok=1 || true
    elif command -v service >/dev/null 2>&1; then
      service ssh reload >/dev/null 2>&1 || service sshd reload >/dev/null 2>&1
      [[ $? -eq 0 ]] && local_ok=1 || true
    fi
    if (( local_ok == 1 )); then
      ok "Local SSH reloaded safely."
    else
      warn "Local SSH reload was not confirmed; no restart was attempted."
    fi
  fi

  step "Safe reload SSH service (remote)"
  if ensure_remote_sudo >/dev/null 2>&1; then
    local rout=""
    rout="$(ssh_run_stdin_root <<'REMOTE'
set +e
sshd_bin=""
for b in /usr/sbin/sshd /usr/local/sbin/sshd sshd; do
  command -v "$b" >/dev/null 2>&1 && { sshd_bin="$(command -v "$b")"; break; }
  [ -x "$b" ] && { sshd_bin="$b"; break; }
done
if [ -n "$sshd_bin" ] && ! "$sshd_bin" -t >/tmp/azhdar-sshd-remote-test.log 2>&1; then
  echo "FAILED: configtest $(cat /tmp/azhdar-sshd-remote-test.log 2>/dev/null | tail -n 5 | tr '\n' ' ')"
  exit 1
fi
if command -v systemctl >/dev/null 2>&1; then
  systemctl reload ssh >/dev/null 2>&1 || systemctl reload sshd >/dev/null 2>&1
  rc=$?
elif command -v service >/dev/null 2>&1; then
  service ssh reload >/dev/null 2>&1 || service sshd reload >/dev/null 2>&1
  rc=$?
else
  rc=1
fi
if [ "$rc" = "0" ]; then
  echo "OK: reloaded"
else
  echo "WARN: reload not confirmed; restart skipped"
fi
exit 0
REMOTE
)" || true
    rout="$(printf '%s' "$rout" | tr -d '\r' | tail -n1)"
    if echo "$rout" | grep -q '^OK:'; then
      ok "Remote SSH reloaded safely."
    else
      warn "Remote SSH reload not confirmed: ${rout:-no status}."
    fi
  else
    warn "Remote root access not available; skipping remote SSH reload."
  fi
}

ssh_fallback_status_quiet(){
  ensure_profile_selected || return 1
  local svc; svc="$(ssh_fallback_service_name)"
  systemctl is-active --quiet "$svc"
}

ssh_fallback_hints(){
  # Shown when SSH fallback couldn't be started/verified.
  echo
  hr
  echo -e "${BOLD}${WHT}SSH fallback hints${RST}"
  hr
  echo -e "${DIM}You requested: clients must connect to IR IP.${RST}"
  echo -e "${DIM}In this mode we listen on IR public port(s) and forward over SSH to OUT:127.0.0.1:<dst>.${RST}"
  echo
  echo -e "${DIM}1) Verify the port is reachable on IR from OUT:${RST}"
  echo -e "   nc -vz ${IR_IP_PUBLIC:-<IR_PUBLIC_IP>} <PORT>"
  echo
  echo -e "${DIM}2) Verify OUT service is listening on the destination port (usually VLESS_DST_PORT):${RST}"
  echo -e "   ss -lntp | grep ':${VLESS_DST_PORT:-<dst>}'   # on OUT"
  echo
  echo -e "${DIM}3) Verify the SSH tunnel is actually bound on IR:${RST}"
  echo -e "   ss -lntp | egrep ':(<PORT1>|<PORT2>)'         # on IR"
  echo
  echo -e "${DIM}4) If the service is flapping, check logs:${RST}"
  echo -e "   journalctl -u $(ssh_fallback_service_name) -n 100 --no-pager"
  echo
  echo -e "${DIM}If SSH auth fails under systemd, install a key manually:${RST}"
  echo -e "   ssh-copy-id -p ${OUT_SSH_PORT:-22} ${OUT_SSH_USER:-root}@${OUT_SSH_HOST:-<OUT>}"
}

ssh_fallback_status(){
  ensure_profile_selected || return 1
  banner
  echo -e "${BOLD}${WHT}SSH fallback status (${PROFILE})${RST}"
  hr
  echo -e "${DIM}Enabled:${RST} ${SSH_FALLBACK_ENABLED:-0}"
  echo -e "${DIM}Autostart:${RST} ${SSH_FALLBACK_AUTOSTART:-1}"
  echo -e "${DIM}Mode:${RST} $(ssh_fallback_mode_label)"
    echo -e "${DIM}Transport:${RST} ${SSH_FALLBACK_TRANSPORT:-direct}$( [[ "${SSH_FALLBACK_TRANSPORT:-direct}" == "wg" ]] && echo " ${DIM}(Mimic SSH)${RST}" )"
  if [[ "${SSH_FALLBACK_MODE:-local}" == "reverse" ]]; then
    echo -e "${DIM}Bind on OUT:${RST} ${SSH_FALLBACK_BIND_OUT:-${SSH_FALLBACK_BIND:-0.0.0.0}}"
  else
    echo -e "${DIM}Bind on IR:${RST} ${SSH_FALLBACK_BIND_IR:-0.0.0.0}"
  fi
  echo -e "${DIM}Map:${RST} ${SSH_FWD_TCP_MAP:-<empty>}"
  hr
  local svc; svc="$(ssh_fallback_service_name)"
  systemctl status "$svc" --no-pager -l 2>/dev/null || true
  pause
}

ssh_fallback_wizard(){
  banner
  echo -e "${BOLD}${WHT}SSH fallback (TCP only)${RST}"
  hr
  echo -e "${DIM}This is a TCP-only fallback when WireGuard/Mimic can't connect.
Modes:
  - local  : clients connect to IR IP (this server). IR forwards to OUT over SSH (-L).
  - reverse : clients connect to OUT IP. OUT forwards to IR over SSH (-R).
UDP is NOT supported in SSH fallback.${RST}"
  hr

  [[ -n "${PROFILE:-}" ]] || die "No active profile."

  OUT_SSH_HOST="$(prompt_host "OUT server host (SSH)" "${OUT_SSH_HOST:-$OUT_PUBLIC_IP}")"
  OUT_PUBLIC_IP="${OUT_SSH_HOST}"
  OUT_SSH_PORT="$(prompt_port "OUT SSH port" "${OUT_SSH_PORT:-22}")"
  OUT_SSH_USER="$(prompt_nonempty "OUT SSH user" "${OUT_SSH_USER:-root}")"
echo
echo -e "${BOLD}${WHT}SSH transport${RST}"
hr
echo -e "${DIM}direct: SSH connects to OUT public IP/port\nmimic : SSH connects to OUT via WG tunnel IP (traffic rides over Mimic). Requires WG tunnel up.${RST}"
local deftr="${SSH_FALLBACK_TRANSPORT:-direct}"
local defsel_t="1"
[[ "$deftr" == "wg" ]] && defsel_t="2"
echo " 1) direct"
echo " 2) mimic-ssh (over WG/Mimic)"
local tsel=""
read -rp "Select [${defsel_t}]: " tsel || true
tsel="${tsel:-$defsel_t}"
case "$tsel" in
  2) SSH_FALLBACK_TRANSPORT="wg" ;;
  *) SSH_FALLBACK_TRANSPORT="direct" ;;
esac

  echo
  echo -e "${BOLD}${WHT}Expose where?${RST}"
  hr
  local defm="${SSH_FALLBACK_MODE:-local}"
  echo -e "${DIM}Current:${RST} $(ssh_fallback_mode_label)"
  echo " 1) local  (IR IP)  - recommended when you want clients to use IR IP"
  echo " 2) reverse (OUT IP) - useful when IR inbound ports are blocked"
  local defsel="1"
  [[ "${defm}" == "reverse" ]] && defsel="2"
  local c=""
  read -rp "Select [${defsel}]: " c || true
  c="${c:-$defsel}"
  case "$c" in
    2) SSH_FALLBACK_MODE="reverse" ;;
    *) SSH_FALLBACK_MODE="local" ;;
  esac

  echo
  echo -e "${BOLD}${WHT}Port mappings${RST}"
  hr
  echo -e "${DIM}Tip:${RST} Leave empty to auto-use WG/forward wizard ports: TCP=${FORWARD_TCP_PORTS:-<none>}  dst=${VLESS_DST_PORT:-<auto>}"

  if [[ "${SSH_FALLBACK_MODE}" == "reverse" ]]; then
    echo -e "${DIM}Format: OUTPORT=IRHOST:IRPORT (IRHOST default: 127.0.0.1)
Example: 2087=127.0.0.1:2087${RST}"
  else
    echo -e "${DIM}Format: IRPORT=OUTHOST:OUTPORT (OUTHOST default: 127.0.0.1)
Example: 666=127.0.0.1:666 (for XMPlus on OUT)${RST}"
  fi

  local defmap="${SSH_FWD_TCP_MAP:-}"
  if [[ -z "$defmap" ]]; then
    if [[ -n "${FORWARD_TCP_PORTS:-}" ]]; then
      local out=""
      local IFS=',' p
      for p in ${FORWARD_TCP_PORTS// /}; do
        [[ -n "$p" ]] || continue
        [[ "$p" =~ ^[0-9]+$ ]] || continue
        local _dst="${VLESS_DST_PORT:-$p}"
        out+="${out:+,}${p}=127.0.0.1:${_dst}"
      done
      defmap="${out}"
    else
      defmap="666=127.0.0.1:666"
    fi
  fi

  read -rp "TCP map [${defmap}]: " SSH_FWD_TCP_MAP || true
  SSH_FWD_TCP_MAP="${SSH_FWD_TCP_MAP:-$defmap}"
  SSH_FWD_TCP_MAP="${SSH_FWD_TCP_MAP//$'
'/}"
  SSH_FWD_TCP_MAP="${SSH_FWD_TCP_MAP//$'
'/}"

  echo
  if [[ "${SSH_FALLBACK_MODE}" == "reverse" ]]; then
    SSH_FALLBACK_BIND_OUT="${SSH_FALLBACK_BIND_OUT:-${SSH_FALLBACK_BIND:-0.0.0.0}}"
    read -rp "Bind address on OUT for exposed ports [${SSH_FALLBACK_BIND_OUT}]: " _b || true
    _b="${_b:-$SSH_FALLBACK_BIND_OUT}"
    SSH_FALLBACK_BIND_OUT="${_b}"
    SSH_FALLBACK_BIND="${SSH_FALLBACK_BIND_OUT}"
  else
    SSH_FALLBACK_BIND_IR="${SSH_FALLBACK_BIND_IR:-0.0.0.0}"
    read -rp "Bind address on IR for exposed ports [${SSH_FALLBACK_BIND_IR}]: " _b || true
    _b="${_b:-$SSH_FALLBACK_BIND_IR}"
    SSH_FALLBACK_BIND_IR="${_b}"
  fi

  echo
  SSH_FALLBACK_AUTOSTART="${SSH_FALLBACK_AUTOSTART:-1}"
  if [[ "$(prompt_yesno "Keep fallback running after reboot (systemd autostart)?" "Y")" == "Y" ]]; then
    SSH_FALLBACK_AUTOSTART="1"
  else
    SSH_FALLBACK_AUTOSTART="0"
  fi

  echo
  SSH_FALLBACK_AUTO_ON_WG_FAIL="${SSH_FALLBACK_AUTO_ON_WG_FAIL:-1}"
  SSH_FALLBACK_AUTO_ON_WG_DROP="${SSH_FALLBACK_AUTO_ON_WG_DROP:-0}"
  if [[ "$(prompt_yesno "Auto-enable this fallback when WireGuard fails in the wizard?" "Y")" == "Y" ]]; then
    SSH_FALLBACK_AUTO_ON_WG_FAIL="1"
  else
    SSH_FALLBACK_AUTO_ON_WG_FAIL="0"
  fi

  SSH_FALLBACK_ENABLED="1"
  SSH_FALLBACK_BIND="${SSH_FALLBACK_BIND_OUT:-${SSH_FALLBACK_BIND:-0.0.0.0}}"
  profile_save >/dev/null 2>&1 || true

  # Enable/disable auto-failover watchdog based on user choice (best-effort).
  if [[ "${SSH_FALLBACK_AUTO_ON_WG_DROP:-0}" == "1" ]]; then
    ssh_fallback_deps_local >/dev/null 2>&1 || true
    remote_preflight >/dev/null 2>&1 || true
    ssh_fallback_ensure_key_auth >/dev/null 2>&1 || true
    ssh_fallback_configure_remote_sshd || true
    ssh_fallback_write_service_local >/dev/null 2>&1 || true
    ssh_fallback_watchdog_enable_current_profile >/dev/null 2>&1 || true
  else
    ssh_fallback_watchdog_disable_current_profile >/dev/null 2>&1 || true
  fi

  ok "SSH fallback profile settings saved."
  return 0
}


ssh_fallback_all_connections_menu(){
  # List/manage SSH fallback services across ALL profiles.
  # Does not permanently switch CURRENT_PROFILE.
  local saved_profile="${CURRENT_PROFILE:-}"
  local -a profs=()
  mapfile -t profs < <(profiles_list 2>/dev/null || true)

  banner
  echo -e "${BOLD}${WHT}Active SSH connections (all profiles)${RST}"
  hr

  if [[ "${#profs[@]}" -eq 0 ]]; then
    warn "No profiles found in ${PROFILE_DIR}."
    pause
    return 0
  fi

  while true; do
    banner
    echo -e "${BOLD}${WHT}Active SSH connections (all profiles)${RST}"
    hr
    echo -e "${DIM}Legend:${RST} svc=systemd unit state for azhdar-ssh-fallback@<profile>.service"
    echo

    local i=0 p
    for p in "${profs[@]}"; do
      ((i++))
      local f; f="$(profile_path "$p")"
      # Peek fallback vars without polluting current shell env.
      local enabled transport mode map host port user
      enabled="$( ( set +e +u; source "$f" 2>/dev/null || true; printf '%s' "${SSH_FALLBACK_ENABLED:-0}" ) )"
      transport="$( ( set +e +u; source "$f" 2>/dev/null || true; printf '%s' "${SSH_FALLBACK_TRANSPORT:-direct}" ) )"
      mode="$(    ( set +e +u; source "$f" 2>/dev/null || true; printf '%s' "${SSH_FALLBACK_MODE:-local}" ) )"
      map="$(     ( set +e +u; source "$f" 2>/dev/null || true; printf '%s' "${SSH_FWD_TCP_MAP:-}" ) )"
      host="$(    ( set +e +u; source "$f" 2>/dev/null || true; printf '%s' "${OUT_SSH_HOST:-}" ) )"
      port="$(    ( set +e +u; source "$f" 2>/dev/null || true; printf '%s' "${OUT_SSH_PORT:-22}" ) )"
      user="$(    ( set +e +u; source "$f" 2>/dev/null || true; printf '%s' "${OUT_SSH_USER:-root}" ) )"

      local svc="azhdar-ssh-fallback@${p}.service"
      local svc_state="not-installed"
      if systemctl cat "$svc" >/dev/null 2>&1; then
        svc_state="$(systemctl is-active "$svc" 2>/dev/null || echo inactive)"
      fi

      printf " %2s) %-18s  enabled=%s  transport=%-6s  mode=%-7s  svc=%-10s  map=%s\n" \
        "$i" "$p" "${enabled:-0}" "${transport:-direct}" "${mode:-local}" "${svc_state}" "${map:-<empty>}"
      if [[ -n "${host:-}" ]]; then
        printf "     %s@%s:%s\n" "${user:-root}" "${host}" "${port:-22}"
      fi
    done

    hr
    echo "Select a profile number to manage it."
    echo " 0) Back"
    hr
    local sel=""
    read -rp "Select: " sel || true
    sel="${sel:-0}"
    if [[ "$sel" == "0" ]]; then
      break
    fi
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( sel < 1 || sel > ${#profs[@]} )); then
      warn "Invalid selection."
      pause
      continue
    fi

    local target="${profs[$((sel-1))]}"
    local svc="azhdar-ssh-fallback@${target}.service"

    while true; do
      banner
      echo -e "${BOLD}${WHT}Manage SSH fallback (${target})${RST}"
      hr
      local st="not-installed"
      if systemctl cat "$svc" >/dev/null 2>&1; then
        st="$(systemctl is-active "$svc" 2>/dev/null || echo inactive)"
      fi
      echo -e "${DIM}Service:${RST} ${svc} (${st})"
      hr
      echo " 1) Start / Enable"
      echo " 2) Stop / Disable"
      echo " 3) Status"
      echo " 4) Logs (last 120 lines)"
      echo " 5) Remove / Reset (this profile)"
      echo " 0) Back"
      hr
      local a=""
      read -rp "Select: " a || true
      case "${a:-}" in
        1)
          CURRENT_PROFILE="$target"
          profile_load "$CURRENT_PROFILE" 2>/dev/null || true
          ssh_fallback_start || true
          CURRENT_PROFILE="$saved_profile"
          [[ -n "${CURRENT_PROFILE:-}" ]] && profile_load "$CURRENT_PROFILE" 2>/dev/null || true
          pause
          ;;
        2)
          CURRENT_PROFILE="$target"
          profile_load "$CURRENT_PROFILE" 2>/dev/null || true
          ssh_fallback_stop || true
          CURRENT_PROFILE="$saved_profile"
          [[ -n "${CURRENT_PROFILE:-}" ]] && profile_load "$CURRENT_PROFILE" 2>/dev/null || true
          pause
          ;;
        3)
          systemctl status "$svc" --no-pager -l 2>/dev/null || true
          pause
          ;;
        4)
          journalctl -u "$svc" -n 120 --no-pager -l 2>/dev/null || true
          pause
          ;;
        5)
          CURRENT_PROFILE="$target"
          profile_load "$CURRENT_PROFILE" 2>/dev/null || true
          ssh_fallback_remove || true
          CURRENT_PROFILE="$saved_profile"
          [[ -n "${CURRENT_PROFILE:-}" ]] && profile_load "$CURRENT_PROFILE" 2>/dev/null || true
          pause
          ;;
        0) break ;;
        *) warn "Invalid."; pause ;;
      esac
    done
  done

  # Restore current profile (best-effort).
  CURRENT_PROFILE="$saved_profile"
  [[ -n "${CURRENT_PROFILE:-}" ]] && profile_load "$CURRENT_PROFILE" 2>/dev/null || true
  return 0
}

menu_ssh_fallback(){
  ensure_profile_selected || return 0
  profile_load "$CURRENT_PROFILE" 2>/dev/null || true

  while true; do
    banner
    echo -e "${BOLD}${WHT}SSH fallback (TCP only) - ${PROFILE}${RST}"
    hr
    echo -e "${DIM}Enabled:${RST} ${SSH_FALLBACK_ENABLED:-0}"
    echo -e "${DIM}Mode:${RST} $(ssh_fallback_mode_label)"
    echo -e "${DIM}Map:${RST} ${SSH_FWD_TCP_MAP:-<empty>}"
    hr
    echo " 1) Configure (wizard)"
    echo " 2) Start / Enable"
    echo " 3) Stop / Disable"
    echo " 4) Status"
    echo " 5) Remove / Reset"
    echo " 6) Safe reload SSH (configtest first)"
    echo " 7) Active SSH connections (all profiles)"
    echo " 0) Back"
    hr
    read -rp "Select: " c || true
    case "${c:-}" in
      1) ssh_fallback_wizard || true; pause ;;
      2) ssh_fallback_start || true; pause ;;
      3) ssh_fallback_stop || true; pause ;;
      4) ssh_fallback_status || true ;;
      5) ssh_fallback_remove || true; pause ;;
      6) ssh_fallback_restart_sshd || true; pause ;;
      7) ssh_fallback_all_connections_menu || true ;;
      0) return 0 ;;
      *) warn "Invalid."; pause ;;
    esac
  done
}
menu_cleanup(){
  ensure_profile_selected || return 0

  while true; do
    banner
    echo -e "${BOLD}${WHT}Cleanup (${PROFILE})${RST}"
    hr
    echo " 1) Remove configs on THIS server (WG + Mimic rules)"
    echo " 2) Remove configs on REMOTE server (WG + Mimic rules)"
    echo " 3) Remove configs on BOTH servers"
    echo " 0) Back"
    hr
    read -rp "Select: " c || true
    case "${c:-}" in
      1) cleanup_local || true; pause ;;
      2) cleanup_remote || true; pause ;;
      3) cleanup_both || true; pause ;;
      0) return 0 ;;
      *) warn "Invalid."; pause ;;
    esac
  done
}



# v3.1.2 compatibility stubs. Older menu paths referenced watchdog helpers,
# but some builds did not ship the actual timer implementation. Keep these as
# safe no-ops so enabling/disabling fallback cannot fail with command-not-found.
ssh_fallback_watchdog_enable_current_profile(){
  warn "SSH fallback watchdog timer is not enabled in this safe build; leaving it disabled."
  return 0
}
ssh_fallback_watchdog_disable_current_profile(){
  local p="${PROFILE:-${CURRENT_PROFILE:-}}"
  if command -v systemctl >/dev/null 2>&1 && [[ -n "$p" ]]; then
    systemctl stop "azhdar-ssh-watchdog@${p}.timer" "azhdar-ssh-watchdog@${p}.service" >/dev/null 2>&1 || true
    systemctl disable "azhdar-ssh-watchdog@${p}.timer" "azhdar-ssh-watchdog@${p}.service" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/azhdar-ssh-watchdog@${p}.timer" "/etc/systemd/system/azhdar-ssh-watchdog@${p}.service" >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  return 0
}
