# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Cleanup / Uninstall --------------------
cleanup_remote_ssh_quick_check(){
  # Return quickly when remote SSH is unavailable. Used by profile deletion so
  # a dead OUT server cannot hold the UI for multiple SSH fallback attempts.
  local timeout_total="${1:-6}" ssh_timeout="4"
  [[ "$timeout_total" =~ ^[0-9]+$ ]] || timeout_total="6"
  (( timeout_total < 2 )) && timeout_total="2"
  (( timeout_total <= 3 )) && ssh_timeout="2"

  [[ -n "${OUT_SSH_HOST:-}" ]] || return 1
  [[ -n "${OUT_SSH_PORT:-}" ]] || OUT_SSH_PORT="22"

  # Fast TCP gate first (about 2s). If TCP/SSH is not open, skip immediately.
  tcp_port_open "${OUT_SSH_HOST}" "${OUT_SSH_PORT}" || return 1

  local old_timeout="${AZHDAR_SSH_CONNECT_TIMEOUT:-}"
  local old_mode="${SSH_MGMT_TRANSPORT:-}"
  local old_last="${SSH_MGMT_LAST_TRANSPORT:-}"
  local rc=1

  # For deletion cleanup, do not try stale WG fallback targets. The goal is only
  # best-effort cleanup; if public SSH is not reachable quickly, continue.
  AZHDAR_SSH_CONNECT_TIMEOUT="$ssh_timeout"
  SSH_MGMT_TRANSPORT="direct"
  SSH_MGMT_LAST_TRANSPORT=""

  ssh_run "true" >/dev/null 2>&1
  rc=$?

  if [[ -n "$old_timeout" ]]; then AZHDAR_SSH_CONNECT_TIMEOUT="$old_timeout"; else unset AZHDAR_SSH_CONNECT_TIMEOUT; fi
  SSH_MGMT_TRANSPORT="$old_mode"
  SSH_MGMT_LAST_TRANSPORT="$old_last"

  return "$rc"
}

cleanup_local(){
  step "Cleanup local (profile)"
  # Stop WG for this profile.
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop "wg-quick@${WG_IF}" >/dev/null 2>&1 || true
  fi

  # Stop SSH fallback service for this profile (if present).
  if command -v systemctl >/dev/null 2>&1; then
    local sshsvc="azhdar-ssh-fallback@${PROFILE}.service"
    systemctl stop "$sshsvc" >/dev/null 2>&1 || true
  fi

  local wan; wan="$(detect_wan_if)"

  remove_forward_rules_local || true
  remove_rst_drop_local || true
  remove_allow_rules_local || true
  rm -f "/etc/wireguard/${WG_IF}.conf" "/etc/wireguard/${WG_IF}.key" 2>/dev/null || true

  # Rebuild Mimic config for remaining enabled profiles (exclude this profile).
  mimic_rebuild_local_excluding "${PROFILE}" || true
  ok "Local WG config removed."
}

cleanup_remote(){
  step "Cleanup remote (profile)"

  if ! cleanup_remote_ssh_quick_check 6; then
    warn "Remote cleanup skipped: SSH did not respond within ~6s. Continuing profile deletion."
    CLEANUP_REMOTE_SKIPPED="1"
    return 0
  fi

  local old_timeout="${AZHDAR_SSH_CONNECT_TIMEOUT:-}"
  local old_mode="${SSH_MGMT_TRANSPORT:-}"
  local old_last="${SSH_MGMT_LAST_TRANSPORT:-}"
  AZHDAR_SSH_CONNECT_TIMEOUT="4"
  SSH_MGMT_TRANSPORT="direct"
  SSH_MGMT_LAST_TRANSPORT=""

  # Stop remote WG for this profile.
  ssh_run_root_best_effort "systemctl stop wg-quick@${WG_IF} >/dev/null 2>&1 || true" >/dev/null 2>&1 || true

  [[ -n "${REMOTE_WAN_IF:-}" ]] || REMOTE_WAN_IF="$(remote_detect_wan_if_quiet || true)"
  remove_rst_drop_remote || true
  remove_allow_rules_remote || true
  ssh_run_stdin_env_root_best_effort "WG_IF=${WG_IF}" <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail
rm -f "/etc/wireguard/${WG_IF}.conf" "/etc/wireguard/${WG_IF}.key" 2>/dev/null || true
REMOTE

  # Rebuild remote Mimic config for remaining enabled profiles on this same OUT host.
  mimic_rebuild_remote_excluding "${PROFILE}" || true

  if [[ -n "$old_timeout" ]]; then AZHDAR_SSH_CONNECT_TIMEOUT="$old_timeout"; else unset AZHDAR_SSH_CONNECT_TIMEOUT; fi
  SSH_MGMT_TRANSPORT="$old_mode"
  SSH_MGMT_LAST_TRANSPORT="$old_last"

  ok "Remote WG config removed (best-effort)."
}

cleanup_both(){
  cleanup_local || true
  cleanup_remote || true
  PROFILE_ENABLED="0"
  profile_save
}

purge_mimic_local(){
  if have_cmd apt-get; then
    step "Purging Mimic packages (local)"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y mimic mimic-dkms >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
  fi
}

purge_mimic_remote(){
  if [[ -n "${OUT_SSH_HOST:-}" ]] && ssh_run "echo OK" >/dev/null 2>&1; then
    step "Purging Mimic packages (remote)"
    ssh_run "${REMOTE_SUDO:-} DEBIAN_FRONTEND=noninteractive apt-get purge -y mimic mimic-dkms >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    ssh_run "${REMOTE_SUDO:-} DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi
}

complete_uninstall_local(){
  banner
  warn "COMPLETE UNINSTALL (LOCAL): removes Mimic/WG configs, firewall rules, and ALL manager state on THIS server."
  read -rp "Type DELETE to confirm: " ans || true
  [[ "${ans:-}" == "DELETE" ]] || { warn "Canceled."; return 1; }

  cleanup_local || true

  # Remove Mimic config
  local wan; wan="$(detect_wan_if)"
  rm -f "/etc/mimic/${wan}.conf" 2>/dev/null || true

  # Remove forwarding/sysctl artifacts
  remove_forwarding_local || true
  remove_allow_rules_local || true
  remove_rst_drop_local || true
  rm -f "/etc/sysctl.d/99-wg-mimic.conf" 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || true

  purge_mimic_local || true

  # Remove manager state
  rm -rf "${BASE_DIR}" 2>/dev/null || true

  ok "Local complete uninstall finished."
  return 0
}

complete_uninstall_remote(){
  banner
  warn "COMPLETE UNINSTALL (REMOTE): removes Mimic/WG configs and firewall rules on the REMOTE server."
  read -rp "Type DELETE to confirm: " ans || true
  [[ "${ans:-}" == "DELETE" ]] || { warn "Canceled."; return 1; }

  cleanup_remote || true

  [[ -n "${REMOTE_WAN_IF:-}" ]] || REMOTE_WAN_IF="$(remote_detect_wan_if_quiet || true)"

  # Remove remote Mimic config
  if [[ -n "${REMOTE_WAN_IF:-}" ]]; then
    ssh_run "${REMOTE_SUDO:-} rm -f /etc/mimic/${REMOTE_WAN_IF}.conf" >/dev/null 2>&1 || true
  fi

  remove_forwarding_remote || true
  remove_allow_rules_remote || true
  remove_rst_drop_remote || true

  purge_mimic_remote || true

  ok "Remote complete uninstall finished."
  return 0
}

complete_uninstall_both(){
  banner
  warn "COMPLETE UNINSTALL (BOTH): removes configs/rules on BOTH servers, purges Mimic, and removes ALL local manager state."
  read -rp "Type DELETE to confirm: " ans || true
  [[ "${ans:-}" == "DELETE" ]] || { warn "Canceled."; return 1; }

  cleanup_local || true
  cleanup_remote || true

  # Local
  local wan; wan="$(detect_wan_if)"
  rm -f "/etc/mimic/${wan}.conf" 2>/dev/null || true
  remove_forwarding_local || true
  remove_allow_rules_local || true
  remove_rst_drop_local || true
  rm -f "/etc/sysctl.d/99-wg-mimic.conf" 2>/dev/null || true
  sysctl --system >/dev/null 2>&1 || true
  purge_mimic_local || true
  rm -rf "${BASE_DIR}" 2>/dev/null || true

  # Remote
  [[ -n "${REMOTE_WAN_IF:-}" ]] || REMOTE_WAN_IF="$(remote_detect_wan_if_quiet || true)"
  if [[ -n "${REMOTE_WAN_IF:-}" ]]; then
    ssh_run "${REMOTE_SUDO:-} rm -f /etc/mimic/${REMOTE_WAN_IF}.conf" >/dev/null 2>&1 || true
  fi
  remove_forwarding_remote || true
  remove_allow_rules_remote || true
  remove_rst_drop_remote || true
  purge_mimic_remote || true

  ok "Complete uninstall on BOTH servers finished."
  return 0
}


# -------------------- Project uninstall (keep AZHDAR) --------------------
_purge_wireguard_local(){
  if have_cmd apt-get; then
    step "Purging WireGuard packages (local)"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y \
      wireguard wireguard-tools wireguard-dkms wireguard-linux-compat \
      >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
  fi
}

_purge_wireguard_remote(){
  if [[ -n "${OUT_SSH_HOST:-}" ]] && ssh_run "echo OK" >/dev/null 2>&1; then
    step "Purging WireGuard packages (remote)"
    ssh_run "${REMOTE_SUDO:-} DEBIAN_FRONTEND=noninteractive apt-get purge -y wireguard wireguard-tools wireguard-dkms wireguard-linux-compat >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    ssh_run "${REMOTE_SUDO:-} DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi
}

_purge_iptables_persistent_local(){
  if have_cmd apt-get; then
    step "Purging iptables persistence packages (local)"
    DEBIAN_FRONTEND=noninteractive apt-get purge -y iptables-persistent netfilter-persistent >/dev/null 2>&1 || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
  fi
}

_purge_iptables_persistent_remote(){
  if [[ -n "${OUT_SSH_HOST:-}" ]] && ssh_run "echo OK" >/dev/null 2>&1; then
    step "Purging iptables persistence packages (remote)"
    ssh_run "${REMOTE_SUDO:-} DEBIAN_FRONTEND=noninteractive apt-get purge -y iptables-persistent netfilter-persistent >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    ssh_run "${REMOTE_SUDO:-} DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  fi
}

_remove_all_tagged_rules_local(){
  # Removes any iptables rules containing the AZHDAR tag (profile-tagged and legacy).
  local tag="${TAG:-AZHDAR}"
  local line cmd

  # filter table
  while read -r line; do
    cmd="${line/-A /-D }"; iptables $cmd >/dev/null 2>&1 || true
  done < <(iptables -S INPUT 2>/dev/null | grep -F "$tag" || true)
  while read -r line; do
    cmd="${line/-A /-D }"; iptables $cmd >/dev/null 2>&1 || true
  done < <(iptables -S FORWARD 2>/dev/null | grep -F "$tag" || true)

  # nat table
  while read -r line; do
    cmd="${line/-A /-D }"; iptables -t nat $cmd >/dev/null 2>&1 || true
  done < <(iptables -t nat -S PREROUTING 2>/dev/null | grep -F "$tag" || true)
  while read -r line; do
    cmd="${line/-A /-D }"; iptables -t nat $cmd >/dev/null 2>&1 || true
  done < <(iptables -t nat -S POSTROUTING 2>/dev/null | grep -F "$tag" || true)

  # raw table
  while read -r line; do
    cmd="${line/-A /-D }"; iptables -t raw $cmd >/dev/null 2>&1 || true
  done < <(iptables -t raw -S OUTPUT 2>/dev/null | grep -F "$tag" || true)

  # IPv6 (best-effort)
  if have_cmd ip6tables; then
    while read -r line; do
      cmd="${line/-A /-D }"; ip6tables $cmd >/dev/null 2>&1 || true
    done < <(ip6tables -S INPUT 2>/dev/null | grep -F "$tag" || true)
    while read -r line; do
      cmd="${line/-A /-D }"; ip6tables $cmd >/dev/null 2>&1 || true
    done < <(ip6tables -S FORWARD 2>/dev/null | grep -F "$tag" || true)
    while read -r line; do
      cmd="${line/-A /-D }"; ip6tables -t raw $cmd >/dev/null 2>&1 || true
    done < <(ip6tables -t raw -S OUTPUT 2>/dev/null | grep -F "$tag" || true)
  fi
}

_remove_all_tagged_rules_remote(){
  local tag="${TAG:-AZHDAR}"
  ssh_run_stdin_env_root_best_effort "TAG=${tag}" <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail

rm_rules() {
  local table="$1" chain="$2"
  if [ "$table" = "filter" ]; then
    iptables -S "$chain" 2>/dev/null | grep -F "${TAG}" | while read -r line; do
      cmd="${line/-A /-D }"; iptables $cmd 2>/dev/null || true
    done
  else
    iptables -t "$table" -S "$chain" 2>/dev/null | grep -F "${TAG}" | while read -r line; do
      cmd="${line/-A /-D }"; iptables -t "$table" $cmd 2>/dev/null || true
    done
  fi
}

rm_rules filter INPUT
rm_rules filter FORWARD
rm_rules nat PREROUTING
rm_rules nat POSTROUTING
rm_rules raw OUTPUT

if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -S INPUT 2>/dev/null | grep -F "${TAG}" | while read -r line; do cmd="${line/-A /-D }"; ip6tables $cmd 2>/dev/null || true; done
  ip6tables -S FORWARD 2>/dev/null | grep -F "${TAG}" | while read -r line; do cmd="${line/-A /-D }"; ip6tables $cmd 2>/dev/null || true; done
  ip6tables -t raw -S OUTPUT 2>/dev/null | grep -F "${TAG}" | while read -r line; do cmd="${line/-A /-D }"; ip6tables -t raw $cmd 2>/dev/null || true; done
fi
REMOTE
}

_remove_mimic_confs_generated_local(){
  [[ -d /etc/mimic ]] || return 0
  local f
  for f in /etc/mimic/*.conf; do
    [[ -f "$f" ]] || continue
    if grep -Fq "Generated by m0000hamad" "$f" 2>/dev/null; then
      rm -f "$f" 2>/dev/null || true
    fi
  done
}

_remove_mimic_confs_generated_remote(){
  ssh_run_stdin_root_best_effort <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail
[ -d /etc/mimic ] || exit 0
for f in /etc/mimic/*.conf; do
  [ -f "$f" ] || continue
  if grep -Fq "Generated by m0000hamad" "$f" 2>/dev/null; then
    rm -f "$f" 2>/dev/null || true
  fi
done
REMOTE
}

_stop_disable_glob_services_local(){
  if have_cmd systemctl; then
    systemctl stop 'azhdar-ssh-fallback@*.service' >/dev/null 2>&1 || true
    systemctl disable 'azhdar-ssh-fallback@*.service' >/dev/null 2>&1 || true
    systemctl stop 'mimic@*.service' >/dev/null 2>&1 || true
    systemctl disable 'mimic@*.service' >/dev/null 2>&1 || true
  fi

  rm -f /etc/systemd/system/azhdar-ssh-fallback@.service 2>/dev/null || true
  rm -rf /etc/systemd/system/azhdar-ssh-fallback@*.service.d 2>/dev/null || true

  systemctl daemon-reload >/dev/null 2>&1 || true
}

azhdar_uninstall_keep_manager(){
  banner
  warn "UNINSTALL (KEEP AZHDAR): This will remove ALL profiles, configs, firewall rules, and installed components (WireGuard/Mimic) from THIS server, and will attempt the same on REMOTE servers (best-effort). AZHDAR itself will remain installed."
  read -rp "Type DELETE to confirm: " ans || true
  [[ "${ans:-}" == "DELETE" ]] || { warn "Canceled."; return 1; }

  # Snapshot profiles before we start deleting state.
  local plist=() p
  while read -r p; do
    p="$(safe_name "$p")"
    [[ -n "$p" ]] && plist+=("$p")
  done < <(profiles_list 2>/dev/null || true)

  # Per-profile cleanup (local+remote)
  for p in "${plist[@]}"; do
    profile_load "$p" >/dev/null 2>&1 || continue
    cleanup_local || true
    cleanup_remote || true
    _remove_all_tagged_rules_remote || true
    _purge_iptables_persistent_remote || true
    purge_mimic_remote || true
    _purge_wireguard_remote || true
    _remove_mimic_confs_generated_remote || true
  done

  # Local global cleanup
  _stop_disable_glob_services_local || true
  _remove_all_tagged_rules_local || true
  _remove_mimic_confs_generated_local || true

  # Remove sysctl artifacts
  rm -f /etc/sysctl.d/99-wg-mimic.conf >/dev/null 2>&1 || true
  sysctl --system >/dev/null 2>&1 || true

  # Purge packages installed by AZHDAR (best-effort)
  _purge_iptables_persistent_local || true
  purge_mimic_local || true
  _purge_wireguard_local || true

  # Remove all profile state but keep AZHDAR itself installed.
  rm -rf "${PROFILE_DIR}" >/dev/null 2>&1 || true
  mkdir -p "${PROFILE_DIR}" >/dev/null 2>&1 || true
  rm -f "${GLOBAL_STATE}" "${LOG_FILE}" >/dev/null 2>&1 || true

  # Clear selection
  CURRENT_PROFILE=""
  GLOBAL_CURRENT=""
  save_global >/dev/null 2>&1 || true

  ok "Uninstall finished (AZHDAR kept)."
  return 0
}
