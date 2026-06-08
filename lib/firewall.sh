# shellcheck shell=bash
# Part of AZHDAR (modular)


# -------------------- Safety guardrails --------------------
_is_valid_port(){
  local p="${1:-}"
  [[ "$p" =~ ^[0-9]{1,5}$ ]] && (( p >= 1 && p <= 65535 ))
}

normalize_ir_ssh_port(){
  IR_SSH_PORT="${IR_SSH_PORT:-22}"
  if ! _is_valid_port "$IR_SSH_PORT"; then
    warn "Invalid IR_SSH_PORT='${IR_SSH_PORT}', falling back to 22."
    IR_SSH_PORT="22"
  fi
}

allow_ir_ssh_port_local(){
  # Keep the management SSH port reachable on this IR server. This does not
  # override DNAT in PREROUTING, so setup/remove functions also explicitly
  # remove DNAT/REDIRECT rules for this port.
  normalize_ir_ssh_port
  local p="${IR_SSH_PORT}"
  iptables -C INPUT -p tcp --dport "$p" -j ACCEPT -m comment --comment "${RULE_TAG:-$TAG}-SSH-GUARD" 2>/dev/null || \
  iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT -m comment --comment "${RULE_TAG:-$TAG}-SSH-GUARD" 2>/dev/null || \
  iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
  iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${p}/tcp" >/dev/null 2>&1 || true
  fi
}

_iptables_delete_lines(){
  # usage: _iptables_delete_lines <table> <chain> <filter-command...>
  # Reads iptables-save style lines from stdin and deletes matching rules.
  local table="$1"; shift
  local line cmd
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    cmd="${line/-A /-D }"
    if [[ "$table" == "filter" ]]; then
      iptables $cmd 2>/dev/null || true
    else
      iptables -t "$table" $cmd 2>/dev/null || true
    fi
  done
}

remove_dnat_for_port_local(){
  # Remove any local NAT PREROUTING rule that would steal a protected TCP port
  # before sshd can receive it. Intentionally matches tagged and untagged rules
  # because older AZHDAR fallbacks could create untagged rules when the comment
  # match was unavailable.
  local port="${1:-}"
  _is_valid_port "$port" || return 0
  iptables -t nat -S PREROUTING 2>/dev/null |     grep -F -- "--dport ${port}" |     grep -E -- ' -p tcp |^-A [^ ]+ -p tcp ' |     grep -E -- ' -j (DNAT|REDIRECT)( |$)' |     _iptables_delete_lines nat || true
}

remove_rst_drop_for_port_local(){
  # If a previous/bad profile used the SSH port as WG_PORT, its raw OUTPUT
  # RST-drop rule can remain. Remove it for the protected SSH port.
  local port="${1:-}"
  _is_valid_port "$port" || return 0
  iptables -t raw -S OUTPUT 2>/dev/null |     grep -F -- "--sport ${port}" |     grep -F -- "--tcp-flags RST RST" |     grep -F -- "-j DROP" |     _iptables_delete_lines raw || true
}

remove_profile_forward_rules_by_match_local(){
  # Clean up profile forwarding rules even if they were inserted without a
  # comment tag. This prevents stale DNAT from surviving reboot/persistence.
  local p
  while read -r p; do
    [[ -n "$p" ]] || continue
    iptables -t nat -S PREROUTING 2>/dev/null | grep -F -- "--dport ${p}" | grep -E -- ' -p tcp |^-A [^ ]+ -p tcp ' | grep -E -- ' -j (DNAT|REDIRECT)( |$)' | _iptables_delete_lines nat || true
  done < <(ports_split_csv "${FORWARD_TCP_PORTS:-}")
  while read -r p; do
    [[ -n "$p" ]] || continue
    iptables -t nat -S PREROUTING 2>/dev/null | grep -F -- "--dport ${p}" | grep -E -- ' -p udp |^-A [^ ]+ -p udp ' | grep -E -- ' -j (DNAT|REDIRECT)( |$)' | _iptables_delete_lines nat || true
  done < <(ports_split_csv "${FORWARD_UDP_PORTS:-}")

  if [[ -n "${WG_IF:-}" ]]; then
    iptables -t nat -S POSTROUTING 2>/dev/null | grep -F -- "-o ${WG_IF}" | grep -F -- "-j MASQUERADE" | _iptables_delete_lines nat || true
    iptables -S FORWARD 2>/dev/null | grep -E -- "(-i ${WG_IF}|-o ${WG_IF})" | grep -F -- "-j ACCEPT" | _iptables_delete_lines filter || true
  fi
}

azhdar_firewall_safety_local(){
  # Safe to run repeatedly. Run before applying/saving firewall rules and at boot.
  normalize_ir_ssh_port
  azhdar_ensure_system_ssh_local || true
  protect_ir_ssh_port || true
  allow_ir_ssh_port_local || true
  remove_dnat_for_port_local "${IR_SSH_PORT}" || true
  remove_rst_drop_for_port_local "${IR_SSH_PORT}" || true
}


normalize_out_ssh_port(){
  OUT_SSH_PORT="${OUT_SSH_PORT:-22}"
  if ! _is_valid_port "$OUT_SSH_PORT"; then
    warn "Invalid OUT_SSH_PORT='${OUT_SSH_PORT}', falling back to 22."
    OUT_SSH_PORT="22"
  fi
}

azhdar_ssh_guard_local(){
  # Emergency management guard for the IR host. It is intentionally safe and
  # idempotent: do not restart an active SSH daemon; only unmask/enable/start
  # when inactive, open the management port, and remove NAT/raw rules that can
  # steal or break SSH after tunnel/firewall changes.
  normalize_ir_ssh_port || true
  azhdar_ensure_system_ssh_local || true
  allow_ir_ssh_port_local || true
  local p="${IR_SSH_PORT:-22}"
  _is_valid_port "$p" || return 0
  iptables -C OUTPUT -p tcp --sport "$p" -j ACCEPT -m comment --comment "${RULE_TAG:-$TAG}-SSH-GUARD" 2>/dev/null || \
  iptables -I OUTPUT 1 -p tcp --sport "$p" -j ACCEPT -m comment --comment "${RULE_TAG:-$TAG}-SSH-GUARD" 2>/dev/null || \
  iptables -C OUTPUT -p tcp --sport "$p" -j ACCEPT 2>/dev/null || \
  iptables -I OUTPUT 1 -p tcp --sport "$p" -j ACCEPT 2>/dev/null || true
  remove_dnat_for_port_local "$p" || true
  remove_rst_drop_for_port_local "$p" || true
  if command -v firewall-cmd >/dev/null 2>&1; then
    firewall-cmd --add-port="${p}/tcp" >/dev/null 2>&1 || true
    firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
  fi
}

azhdar_ssh_guard_remote(){
  # Keep the OUT management SSH reachable before/after remote firewall/service
  # changes. Never restarts active sshd; only starts/enables it if inactive.
  [[ "${WG_MODE:-classic}" == "account" ]] && return 0
  normalize_out_ssh_port || true
  local p="${OUT_SSH_PORT:-22}"
  _is_valid_port "$p" || return 0
  ssh_run_stdin_env_root_best_effort "OUT_SSH_PORT=${p}" "RULE_TAG=${RULE_TAG:-$TAG}" <<'REMOTE' >/dev/null 2>&1 || true
set +e
p="${OUT_SSH_PORT:-22}"
case "$p" in ''|*[!0-9]* ) p=22;; esac
if [ "$p" -lt 1 ] || [ "$p" -gt 65535 ]; then p=22; fi
comment="${RULE_TAG:-AZHDAR}-SSH-GUARD"

# Firewall first: keep current SSH replies and new SSH connections accepted.
iptables -C INPUT -p tcp --dport "$p" -j ACCEPT -m comment --comment "$comment" 2>/dev/null || \
iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT -m comment --comment "$comment" 2>/dev/null || \
iptables -C INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || \
iptables -I INPUT 1 -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
iptables -C OUTPUT -p tcp --sport "$p" -j ACCEPT -m comment --comment "$comment" 2>/dev/null || \
iptables -I OUTPUT 1 -p tcp --sport "$p" -j ACCEPT -m comment --comment "$comment" 2>/dev/null || \
iptables -C OUTPUT -p tcp --sport "$p" -j ACCEPT 2>/dev/null || \
iptables -I OUTPUT 1 -p tcp --sport "$p" -j ACCEPT 2>/dev/null || true

# Remove rules that would steal SSH before sshd sees it or drop SSH RST replies.
iptables -t nat -S PREROUTING 2>/dev/null | grep -F -- "--dport ${p}" | grep -E -- ' -p tcp |^-A [^ ]+ -p tcp ' | grep -E -- ' -j (DNAT|REDIRECT)( |$)' | while read -r line; do
  cmd="${line/-A /-D }"; iptables -t nat $cmd 2>/dev/null || true
done
iptables -t raw -S OUTPUT 2>/dev/null | grep -F -- "--sport ${p}" | grep -F -- "--tcp-flags RST RST" | grep -F -- "-j DROP" | while read -r line; do
  cmd="${line/-A /-D }"; iptables -t raw $cmd 2>/dev/null || true
done

if command -v ufw >/dev/null 2>&1; then ufw allow "${p}/tcp" >/dev/null 2>&1 || true; fi
if command -v firewall-cmd >/dev/null 2>&1; then
  firewall-cmd --add-port="${p}/tcp" >/dev/null 2>&1 || true
  firewall-cmd --permanent --add-port="${p}/tcp" >/dev/null 2>&1 || true
fi

# Service guard. Do not restart an already-active sshd. Test config before
# starting/reloading anything, and tolerate images using ssh vs sshd naming.
sshd_bin=""
for b in /usr/sbin/sshd /usr/local/sbin/sshd sshd; do
  if command -v "$b" >/dev/null 2>&1; then sshd_bin="$(command -v "$b")"; break; fi
  [ -x "$b" ] && { sshd_bin="$b"; break; }
done
if [ -n "$sshd_bin" ]; then "$sshd_bin" -t >/tmp/azhdar-sshd-guard-test.log 2>&1 || exit 0; fi
if command -v systemctl >/dev/null 2>&1; then
  for svc in ssh.service sshd.service; do
    systemctl list-unit-files "$svc" >/dev/null 2>&1 || systemctl status "$svc" >/dev/null 2>&1 || continue
    systemctl unmask "$svc" >/dev/null 2>&1 || true
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl is-active --quiet "$svc" || systemctl start "$svc" >/dev/null 2>&1 || true
  done
  for svc in ssh.socket sshd.socket; do
    systemctl list-unit-files "$svc" >/dev/null 2>&1 || systemctl status "$svc" >/dev/null 2>&1 || continue
    systemctl unmask "$svc" >/dev/null 2>&1 || true
    systemctl enable "$svc" >/dev/null 2>&1 || true
    systemctl is-active --quiet "$svc" || systemctl start "$svc" >/dev/null 2>&1 || true
  done
fi
REMOTE
}

azhdar_ssh_guard_all(){
  azhdar_ssh_guard_local || true
  azhdar_ssh_guard_remote || true
}

ssh_guard_remote_conflict(){
  [[ "${WG_MODE:-classic}" == "account" ]] && return 0
  normalize_out_ssh_port || true
  if [[ -n "${WG_PORT:-}" && -n "${OUT_SSH_PORT:-}" && "${WG_PORT}" == "${OUT_SSH_PORT}" ]]; then
    err "WG_PORT ${WG_PORT} equals OUT SSH port ${OUT_SSH_PORT}; refusing because it can lock you out of the OUT server. Choose another tunnel public port."
    return 1
  fi
  return 0
}

# -------------------- Firewall / forwarding --------------------
allow_mimic_port_local(){
  azhdar_firewall_safety_local || true
  if [[ -n "${IR_SSH_PORT:-}" && "${WG_PORT:-}" == "${IR_SSH_PORT}" ]]; then
    err "WG_PORT ${WG_PORT} equals the IR SSH protected port; refusing to open/use it as tunnel port."
    return 1
  fi
  step "Open local port (best-effort)"
  local proto
  for proto in tcp udp; do
    iptables -C INPUT -p "$proto" --dport "${WG_PORT}" -j ACCEPT -m comment --comment "${RULE_TAG}" 2>/dev/null ||     iptables -I INPUT -p "$proto" --dport "${WG_PORT}" -j ACCEPT -m comment --comment "${RULE_TAG}" 2>/dev/null ||     iptables -I INPUT -p "$proto" --dport "${WG_PORT}" -j ACCEPT 2>/dev/null || true
  done
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${WG_PORT}/tcp" >/dev/null 2>&1 || true
    ufw allow "${WG_PORT}/udp" >/dev/null 2>&1 || true
  fi
  ok "Local firewall rule applied (best-effort)."
}


# Backwards-compat aliases used by some modules
add_rst_drop_local(){ setup_rst_drop_local; }
add_rst_drop_remote(){ setup_rst_drop_remote; }

allow_mimic_port_remote(){
  ssh_guard_remote_conflict || return 1
  azhdar_ssh_guard_remote || true
  step "Open remote port (best-effort)"
  ssh_run_stdin_env_root_best_effort "WG_PORT=${WG_PORT}" "RULE_TAG=${RULE_TAG}" <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail
for proto in tcp udp; do
  iptables -C INPUT -p "$proto" --dport "${WG_PORT}" -j ACCEPT -m comment --comment "${RULE_TAG}" 2>/dev/null ||   iptables -I INPUT -p "$proto" --dport "${WG_PORT}" -j ACCEPT -m comment --comment "${RULE_TAG}" 2>/dev/null ||   iptables -I INPUT -p "$proto" --dport "${WG_PORT}" -j ACCEPT 2>/dev/null || true
done
if command -v ufw >/dev/null 2>&1; then
  ufw allow "${WG_PORT}/tcp" >/dev/null 2>&1 || true
  ufw allow "${WG_PORT}/udp" >/dev/null 2>&1 || true
fi
REMOTE
  ok "Remote firewall rule applied (best-effort)."
}

allow_forward_ports_local(){
  azhdar_firewall_safety_local || true
  local p
  for p in ${FORWARD_TCP_PORTS//,/ }; do
    [[ -z "$p" ]] && continue
    if [[ -n "${IR_SSH_PORT:-}" && "$p" == "${IR_SSH_PORT}" ]]; then
      warn "Skipping TCP allow for IR SSH protected port ${p}."
      continue
    fi
    iptables -C INPUT -p tcp --dport "$p" -j ACCEPT -m comment --comment "$RULE_TAG" 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "$p" -j ACCEPT -m comment --comment "$RULE_TAG" 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
  done
  for p in ${FORWARD_UDP_PORTS//,/ }; do
    [[ -z "$p" ]] && continue
    iptables -C INPUT -p udp --dport "$p" -j ACCEPT -m comment --comment "$RULE_TAG" 2>/dev/null || \
    iptables -I INPUT -p udp --dport "$p" -j ACCEPT -m comment --comment "$RULE_TAG" 2>/dev/null || \
    iptables -I INPUT -p udp --dport "$p" -j ACCEPT 2>/dev/null || true
  done
  if command -v ufw >/dev/null 2>&1; then
    for p in ${FORWARD_TCP_PORTS//,/ }; do [[ -n "$p" ]] && ufw allow "$p"/tcp >/dev/null 2>&1 || true; done
    for p in ${FORWARD_UDP_PORTS//,/ }; do [[ -n "$p" ]] && ufw allow "$p"/udp >/dev/null 2>&1 || true; done
  fi
}

remove_allow_rules_local(){
  step "Remove local allow rules (best-effort)"
  local line cmd
  while read -r line; do
    cmd="${line/-A /-D }"
    iptables $cmd 2>/dev/null || true
  done < <(iptables -S INPUT 2>/dev/null | grep -F "${RULE_TAG:-$TAG}" || true)

  # Legacy cleanup (v2.0.0): rules were tagged with AZHDAR (global). Remove only ports from this profile.
  _remove_legacy_allow_rules_local || true
  ok "Local allow rules removed (best-effort)."
}

remove_allow_rules_remote(){
  step "Remove remote allow rules (best-effort)"
  ssh_run_stdin_env_root_best_effort "TAG_MARK=${RULE_TAG:-$TAG}" "TAG_LEGACY=${TAG}" "WG_PORT=${WG_PORT}" "VLESS_DST_PORT=${VLESS_DST_PORT:-}" "WG_IF=${WG_IF}" <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail
iptables -S INPUT 2>/dev/null | grep -F "${TAG_MARK}" | while read -r line; do
  cmd="${line/-A /-D }"; iptables $cmd 2>/dev/null || true
done

# Legacy cleanup (v2.0.0): rules were tagged with AZHDAR (global).
iptables -S INPUT 2>/dev/null | grep -F "${TAG_LEGACY}" | while read -r line; do
  # mimic allow
  if echo "$line" | grep -Fq -- "--dport ${WG_PORT}"; then
    cmd="${line/-A /-D }"; iptables $cmd 2>/dev/null || true
    continue
  fi
  # vless allow on WG iface
  if [[ -n "${VLESS_DST_PORT}" ]] && echo "$line" | grep -Fq -- "-i ${WG_IF}" && echo "$line" | grep -Fq -- "--dport ${VLESS_DST_PORT}"; then
    cmd="${line/-A /-D }"; iptables $cmd 2>/dev/null || true
    continue
  fi
done
REMOTE
  ok "Remote allow rules removed (best-effort)."
}



allow_vless_on_remote_wg(){
  [[ -z "${VLESS_DST_PORT:-}" ]] && return 0
  step "Allow destination port on remote WG interface (best-effort)"
  ssh_run_stdin_env_root_best_effort "WG_IF=${WG_IF}" "VLESS_DST_PORT=${VLESS_DST_PORT}" "RULE_TAG=${RULE_TAG}" <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail
for proto in tcp udp; do
  iptables -C INPUT -i "${WG_IF}" -p "$proto" --dport "${VLESS_DST_PORT}" -j ACCEPT -m comment --comment "${RULE_TAG}" 2>/dev/null ||   iptables -I INPUT -i "${WG_IF}" -p "$proto" --dport "${VLESS_DST_PORT}" -j ACCEPT -m comment --comment "${RULE_TAG}" 2>/dev/null ||   iptables -I INPUT -i "${WG_IF}" -p "$proto" --dport "${VLESS_DST_PORT}" -j ACCEPT 2>/dev/null || true
done
if command -v ufw >/dev/null 2>&1; then
  ufw allow in on "${WG_IF}" to any port "${VLESS_DST_PORT}" proto tcp >/dev/null 2>&1 || true
  ufw allow in on "${WG_IF}" to any port "${VLESS_DST_PORT}" proto udp >/dev/null 2>&1 || true
fi
REMOTE
  ok "Remote WG ingress rule applied (best-effort)."
}

enable_ip_forward(){
  sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || true
  mkdir -p /etc/sysctl.d
  echo "net.ipv4.ip_forward=1" >/etc/sysctl.d/99-wg-mimic.conf
}

setup_forward_ir(){
  azhdar_firewall_safety_local || true
  step "Configure reverse-forward (IR public -> OUT over WG)"
  if [[ "${ENABLE_TUN_IPV4:-1}" != "1" ]]; then
    err "Reverse-forward requires IPv4 tunnel addresses (iptables DNAT)."
    warn "Enable IPv4 tunnel mode (Advanced) or disable forwarding ports."
    return 1
  fi

  enable_ip_forward
  local wan; wan="$(detect_wan_if)"
  [[ -n "$wan" ]] || warn "WAN interface not detected; continuing."

  local _dst_ip="${FORWARD_DST_IP:-${OUT_WG_IP}}"
  if [[ -z "${FORWARD_TCP_PORTS:-}${FORWARD_UDP_PORTS:-}" ]]; then
    info "No forwarding ports configured; nothing to apply."
    return 0
  fi
  if [[ -z "${VLESS_DST_PORT:-}" || -z "${_dst_ip:-}" || "${_dst_ip}" == "peer" ]]; then
    warn "Forwarding target is incomplete (dst=${_dst_ip:-<empty>}, port=${VLESS_DST_PORT:-<empty>}); skipping DNAT to avoid broken firewall rules."
    return 1
  fi
  info "DNAT destination: ${_dst_ip}:${VLESS_DST_PORT}"
  local p

  IFS=',' read -r -a tcp_ports <<<"${FORWARD_TCP_PORTS}"
  for p in "${tcp_ports[@]}"; do
    p="$(echo "$p" | xargs)"
    [[ -z "$p" ]] && continue
    if [[ -n "${IR_SSH_PORT:-}" && "$p" == "${IR_SSH_PORT}" ]]; then
      warn "Skipping DNAT for IR SSH protected port ${p}."
      remove_dnat_for_port_local "$p" || true
      continue
    fi
    iptables -t nat -C PREROUTING -p tcp --dport "$p" -j DNAT --to-destination "${_dst_ip}:${VLESS_DST_PORT}" -m comment --comment "${RULE_TAG:-$TAG}" 2>/dev/null || \
    iptables -t nat -I PREROUTING -p tcp --dport "$p" -j DNAT --to-destination "${_dst_ip}:${VLESS_DST_PORT}" -m comment --comment "${RULE_TAG:-$TAG}" 2>/dev/null || \
    iptables -t nat -I PREROUTING -p tcp --dport "$p" -j DNAT --to-destination "${_dst_ip}:${VLESS_DST_PORT}" 2>/dev/null || true
    ok "DNAT TCP :$p -> ${_dst_ip}:${VLESS_DST_PORT}"
  done

  IFS=',' read -r -a udp_ports <<<"${FORWARD_UDP_PORTS}"
  for p in "${udp_ports[@]}"; do
    p="$(echo "$p" | xargs)"
    [[ -z "$p" ]] && continue
    iptables -t nat -C PREROUTING -p udp --dport "$p" -j DNAT --to-destination "${_dst_ip}:${VLESS_DST_PORT}" -m comment --comment "${RULE_TAG:-$TAG}" 2>/dev/null || \
    iptables -t nat -I PREROUTING -p udp --dport "$p" -j DNAT --to-destination "${_dst_ip}:${VLESS_DST_PORT}" -m comment --comment "${RULE_TAG:-$TAG}" 2>/dev/null || \
    iptables -t nat -I PREROUTING -p udp --dport "$p" -j DNAT --to-destination "${_dst_ip}:${VLESS_DST_PORT}" 2>/dev/null || true
    ok "DNAT UDP :$p -> ${_dst_ip}:${VLESS_DST_PORT}"
  done

  iptables -t nat -C POSTROUTING -o "${WG_IF}" -j MASQUERADE -m comment --comment "${RULE_TAG:-$TAG}" 2>/dev/null || \
  iptables -t nat -I POSTROUTING -o "${WG_IF}" -j MASQUERADE -m comment --comment "${RULE_TAG:-$TAG}" 2>/dev/null || \
  iptables -t nat -I POSTROUTING -o "${WG_IF}" -j MASQUERADE 2>/dev/null || true
  ok "MASQUERADE on ${WG_IF}"

  # allow forwarding
  if [[ -n "$wan" ]]; then
    iptables -C FORWARD -i "$wan" -o "${WG_IF}" -j ACCEPT -m comment --comment "${RULE_TAG:-$TAG}" 2>/dev/null || \
    iptables -I FORWARD -i "$wan" -o "${WG_IF}" -j ACCEPT -m comment --comment "${RULE_TAG:-$TAG}" 2>/dev/null || true
    iptables -C FORWARD -i "${WG_IF}" -o "$wan" -j ACCEPT -m comment --comment "${RULE_TAG:-$TAG}" 2>/dev/null || \
    iptables -I FORWARD -i "${WG_IF}" -o "$wan" -j ACCEPT -m comment --comment "${RULE_TAG:-$TAG}" 2>/dev/null || true
  fi

  ok "Forwarding rules applied (best-effort)."
}

remove_forward_rules_local(){
  step "Remove forwarding rules (best-effort)"
  local line cmd
  while read -r line; do
    cmd="${line/-A /-D }"
    iptables -t nat $cmd 2>/dev/null || true
  done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep -F "${RULE_TAG:-$TAG}" || true)

  while read -r line; do
    cmd="${line/-A /-D }"
    iptables -t nat $cmd 2>/dev/null || true
  done < <(iptables -t nat -S POSTROUTING 2>/dev/null | grep -F "${RULE_TAG:-$TAG}" || true)

  while read -r line; do
    cmd="${line/-A /-D }"
    iptables $cmd 2>/dev/null || true
  done < <(iptables -S FORWARD 2>/dev/null | grep -F "${RULE_TAG:-$TAG}" || true)

  # Legacy cleanup (v2.0.0): rules were tagged with AZHDAR (global). Remove only artifacts from this profile.
  _remove_legacy_forward_rules_local || true

  # Extra safety: older fallback insertions could be untagged. Remove exact
  # profile forwarding matches and always remove DNAT/RST-drop for protected SSH.
  remove_profile_forward_rules_by_match_local || true
  normalize_ir_ssh_port || true
  remove_dnat_for_port_local "${IR_SSH_PORT}" || true
  remove_rst_drop_for_port_local "${IR_SSH_PORT}" || true

  ok "Forwarding rules removed (best-effort)."
}


remove_forwarding_local(){ remove_forward_rules_local; }

remove_forward_rules_remote(){
  step "Remove remote forwarding rules (best-effort)"
  ssh_run_stdin_env_root_best_effort "TAG_MARK=${RULE_TAG:-$TAG}" "TAG_LEGACY=${TAG}" "WG_IF=${WG_IF}" "FORWARD_TCP_PORTS=${FORWARD_TCP_PORTS:-}" "FORWARD_UDP_PORTS=${FORWARD_UDP_PORTS:-}" <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail
iptables -t nat -S PREROUTING 2>/dev/null | grep -F "${TAG_MARK}" | while read -r line; do
  cmd="${line/-A /-D }"; iptables -t nat $cmd 2>/dev/null || true
done
iptables -t nat -S POSTROUTING 2>/dev/null | grep -F "${TAG_MARK}" | while read -r line; do
  cmd="${line/-A /-D }"; iptables -t nat $cmd 2>/dev/null || true
done
iptables -S FORWARD 2>/dev/null | grep -F "${TAG_MARK}" | while read -r line; do
  cmd="${line/-A /-D }"; iptables $cmd 2>/dev/null || true
done

# Legacy cleanup (v2.0.0): tagged with AZHDAR (global) - remove only rules related to this profile.
parse_ports() {
  echo "$1" | tr ',' ' ' | tr -s ' '
}

for p in $(parse_ports "${FORWARD_TCP_PORTS:-}"); do
  [[ -n "$p" ]] || continue
  iptables -t nat -S PREROUTING 2>/dev/null | grep -F "${TAG_LEGACY}" | grep -Fq -- "--dport ${p}" && \
    iptables -t nat -S PREROUTING 2>/dev/null | grep -F "${TAG_LEGACY}" | grep -F -- "--dport ${p}" | while read -r line; do
      cmd="${line/-A /-D }"; iptables -t nat $cmd 2>/dev/null || true
    done || true
done
for p in $(parse_ports "${FORWARD_UDP_PORTS:-}"); do
  [[ -n "$p" ]] || continue
  iptables -t nat -S PREROUTING 2>/dev/null | grep -F "${TAG_LEGACY}" | grep -Fq -- "--dport ${p}" && \
    iptables -t nat -S PREROUTING 2>/dev/null | grep -F "${TAG_LEGACY}" | grep -F -- "--dport ${p}" | while read -r line; do
      cmd="${line/-A /-D }"; iptables -t nat $cmd 2>/dev/null || true
    done || true
done

iptables -t nat -S POSTROUTING 2>/dev/null | grep -F "${TAG_LEGACY}" | grep -F -- "-o ${WG_IF}" | while read -r line; do
  cmd="${line/-A /-D }"; iptables -t nat $cmd 2>/dev/null || true
done
iptables -S FORWARD 2>/dev/null | grep -F "${TAG_LEGACY}" | grep "${WG_IF}" | while read -r line; do
  cmd="${line/-A /-D }"; iptables $cmd 2>/dev/null || true
done
REMOTE
  ok "Remote forwarding rules removed (best-effort)."
}

remove_forwarding_remote(){ remove_forward_rules_remote; }


setup_rst_drop_local(){
  normalize_ir_ssh_port || true
  if [[ -n "${IR_SSH_PORT:-}" && "${WG_PORT:-}" == "${IR_SSH_PORT}" ]]; then
    err "Refusing to add RST-drop on IR SSH protected port ${IR_SSH_PORT}."
    return 1
  fi
  step "Drop TCP RST (local) for fake TCP port (best-effort)"
  # Prevent the kernel from interfering with Mimic's fake TCP flow.
  iptables -t raw -C OUTPUT -p tcp --sport "${WG_PORT}" --tcp-flags RST RST -j DROP -m comment --comment "${RULE_TAG:-$TAG}" 2>/dev/null || \
  iptables -t raw -I OUTPUT -p tcp --sport "${WG_PORT}" --tcp-flags RST RST -j DROP -m comment --comment "${RULE_TAG:-$TAG}" 2>/dev/null || true
  ok "Local RST-drop rule applied (best-effort)."
}

setup_rst_drop_remote(){
  ssh_guard_remote_conflict || return 1
  azhdar_ssh_guard_remote || true
  step "Drop TCP RST (remote) for fake TCP port (best-effort)"
  ssh_run_stdin_env_root_best_effort "WG_PORT=${WG_PORT}" "RULE_TAG=${RULE_TAG}" <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail
iptables -t raw -C OUTPUT -p tcp --sport "${WG_PORT}" --tcp-flags RST RST -j DROP -m comment --comment "${RULE_TAG}" 2>/dev/null || iptables -t raw -I OUTPUT -p tcp --sport "${WG_PORT}" --tcp-flags RST RST -j DROP -m comment --comment "${RULE_TAG}" 2>/dev/null || true
REMOTE
  ok "Remote RST-drop rule applied (best-effort)."
}

remove_rst_drop_local(){
  step "Remove TCP RST-drop rules (local, best-effort)"
  local line cmd
  while read -r line; do
    cmd="${line/-A /-D }"
    iptables -t raw $cmd 2>/dev/null || true
  done < <(iptables -t raw -S OUTPUT 2>/dev/null | grep -F "${RULE_TAG:-$TAG}" || true)

  # Legacy cleanup (v2.0.0)
  _remove_legacy_rst_drop_local || true
  ok "Local RST-drop rules removed (best-effort)."
}

remove_rst_drop_remote(){
  step "Remove TCP RST-drop rules (remote, best-effort)"
  ssh_run_stdin_env_root_best_effort "TAG_MARK=${RULE_TAG:-$TAG}" "TAG_LEGACY=${TAG}" "WG_PORT=${WG_PORT}" <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail
iptables -t raw -S OUTPUT 2>/dev/null | grep -F "${TAG_MARK}" | while read -r line; do
  cmd="${line/-A /-D }"
  iptables -t raw $cmd 2>/dev/null || true
done

# Legacy cleanup (v2.0.0): tagged with AZHDAR (global)
iptables -t raw -S OUTPUT 2>/dev/null | grep -F "${TAG_LEGACY}" | grep -F -- "--sport ${WG_PORT}" | while read -r line; do
  cmd="${line/-A /-D }"; iptables -t raw $cmd 2>/dev/null || true
done
REMOTE
  ok "Remote RST-drop rules removed (best-effort)."
}


# -------------------- Legacy cleanup helpers (v2.0.0) --------------------
# In v2.0.0 iptables rules were tagged only with "AZHDAR" (global).
# These helpers remove only the rules that match the current profile's ports/iface.

_remove_legacy_allow_rules_local(){
  local legacy="${TAG}" p line cmd
  for p in ${FORWARD_TCP_PORTS//,/ }; do
    [[ -n "$p" ]] || continue
    while read -r line; do
      cmd="${line/-A /-D }"; iptables $cmd 2>/dev/null || true
    done < <(iptables -S INPUT 2>/dev/null | grep -F "$legacy" | grep -F -- "--dport ${p}" || true)
  done
  for p in ${FORWARD_UDP_PORTS//,/ }; do
    [[ -n "$p" ]] || continue
    while read -r line; do
      cmd="${line/-A /-D }"; iptables $cmd 2>/dev/null || true
    done < <(iptables -S INPUT 2>/dev/null | grep -F "$legacy" | grep -F -- "--dport ${p}" || true)
  done
}

_remove_legacy_forward_rules_local(){
  local legacy="${TAG}" p line cmd
  for p in ${FORWARD_TCP_PORTS//,/ }; do
    [[ -n "$p" ]] || continue
    while read -r line; do
      cmd="${line/-A /-D }"; iptables -t nat $cmd 2>/dev/null || true
    done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep -F "$legacy" | grep -F -- "--dport ${p}" || true)
  done
  for p in ${FORWARD_UDP_PORTS//,/ }; do
    [[ -n "$p" ]] || continue
    while read -r line; do
      cmd="${line/-A /-D }"; iptables -t nat $cmd 2>/dev/null || true
    done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep -F "$legacy" | grep -F -- "--dport ${p}" || true)
  done

  while read -r line; do
    cmd="${line/-A /-D }"; iptables -t nat $cmd 2>/dev/null || true
  done < <(iptables -t nat -S POSTROUTING 2>/dev/null | grep -F "$legacy" | grep -F -- "-o ${WG_IF}" || true)

  while read -r line; do
    cmd="${line/-A /-D }"; iptables $cmd 2>/dev/null || true
  done < <(iptables -S FORWARD 2>/dev/null | grep -F "$legacy" | grep "${WG_IF}" || true)
}

_remove_legacy_rst_drop_local(){
  local legacy="${TAG}" line cmd
  while read -r line; do
    cmd="${line/-A /-D }"; iptables -t raw $cmd 2>/dev/null || true
  done < <(iptables -t raw -S OUTPUT 2>/dev/null | grep -F "$legacy" | grep -F -- "--sport ${WG_PORT}" || true)
}

persist_iptables_local(){
  # v3.1.2: Do NOT install/use iptables-persistent by default.
  # Reason: saving transient/bad NAT/raw rules was the main way AZHDAR could
  # poison the IR server after reboot and force a rebuild. The boot service now
  # reconstructs required runtime rules from the profile instead.
  azhdar_firewall_safety_local || true
  azhdar_ssh_guard_local || true
  if [[ "${AZHDAR_PERSIST_IPTABLES:-0}" != "1" && "${FIREWALL_PERSIST:-0}" != "1" ]]; then
    info "Skipping iptables persistence (safe default). Runtime rules will be rebuilt by azhdar.service at boot."
    return 0
  fi

  step "Persist iptables rules (local, explicit opt-in)"
  if command -v netfilter-persistent >/dev/null 2>&1; then
    netfilter-persistent save >/dev/null 2>&1 || true
    ok "Saved via netfilter-persistent."
    return 0
  fi
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get install -y iptables-persistent >/dev/null 2>&1 || true
    if command -v netfilter-persistent >/dev/null 2>&1; then
      netfilter-persistent save >/dev/null 2>&1 || true
      ok "Saved via iptables-persistent."
      return 0
    fi
  fi
  warn "Could not persist iptables automatically on local host."
  return 0
}
persist_iptables_remote(){
  # v3.1.2: safe default is no remote firewall persistence. Remote services
  # remain enabled with their own systemd units; saving remote firewall state is
  # only done when explicitly requested.
  if [[ "${AZHDAR_PERSIST_IPTABLES_REMOTE:-${AZHDAR_PERSIST_IPTABLES:-0}}" != "1" && "${FIREWALL_PERSIST_REMOTE:-${FIREWALL_PERSIST:-0}}" != "1" ]]; then
    info "Skipping remote iptables persistence (safe default)."
    return 0
  fi

  step "Persist iptables rules (remote, explicit opt-in)"
  ssh_run_stdin_root_best_effort <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail
if command -v netfilter-persistent >/dev/null 2>&1; then
  netfilter-persistent save >/dev/null 2>&1 || true
  exit 0
fi
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get install -y iptables-persistent >/dev/null 2>&1 || true
  command -v netfilter-persistent >/dev/null 2>&1 && netfilter-persistent save >/dev/null 2>&1 || true
fi
REMOTE
  ok "Remote iptables persistence attempted (best-effort)."
}


