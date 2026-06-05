# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Service control --------------------


_service_name_safe(){
  # Conservative guard before passing dynamic service names to systemctl/remote shell.
  # Allows normal units such as wg-quick@ali and mimic@ens160.
  local svc="${1:-}"
  [[ -n "$svc" && "$svc" =~ ^[A-Za-z0-9_.@:-]+$ ]]
}

restart_svc_local(){
  # Generic local service restart used by the advanced port/tunnel menu.
  # Must exist because apply_mimic_confs_best_effort calls it after rewriting
  # Mimic configs. Without this, changing WG_PORT writes config but leaves
  # mimic running on the old port until reboot/manual restart.
  local svc="${1:-}"
  _service_name_safe "$svc" || { warn "Unsafe/empty local service name: ${svc:-<empty>}"; return 1; }
  services_guard_local_ports || return 1
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl restart "$svc" >/dev/null 2>&1 || true
  status_cache_invalidate || true
  return 0
}

restart_svc_remote(){
  # Generic remote service restart used by the advanced port/tunnel menu.
  local svc="${1:-}"
  _service_name_safe "$svc" || { warn "Unsafe/empty remote service name: ${svc:-<empty>}"; return 1; }
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    ok "Remote service restart skipped (account mode)."
    status_cache_invalidate || true
    return 0
  fi
  local qsvc
  qsvc="$(printf '%q' "$svc")"
  ssh_run_root_best_effort "systemctl daemon-reload >/dev/null 2>&1 || true; systemctl restart ${qsvc} >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  status_cache_invalidate || true
  return 0
}

services_guard_local_ports(){
  normalize_ir_ssh_port || true
  if [[ -n "${IR_SSH_PORT:-}" && -n "${WG_PORT:-}" && "${WG_PORT}" == "${IR_SSH_PORT}" ]]; then
    err "WG_PORT ${WG_PORT} equals the IR SSH protected port; local services will not be started/restarted to avoid SSH lockout. Change WG_PORT first."
    return 1
  fi
  azhdar_firewall_safety_local || true
}

svc_wg(){ echo "wg-quick@${WG_IF}"; }
restart_wg_only_local(){
  services_guard_local_ports || return 1
  step "Restart WireGuard only (local)"
  systemctl restart "$(svc_wg)" >/dev/null 2>&1 || true
  ok "Local WireGuard restarted."
  status_cache_invalidate || true
}

restart_wg_only_remote(){
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    ok "Remote services skipped (account mode)."
    status_cache_invalidate || true
    return 0
  fi
  step "Restart WireGuard only (remote)"
  ssh_run_root_best_effort "systemctl restart wg-quick@${WG_IF} >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
  ok "Remote WireGuard restarted (best-effort)."
  status_cache_invalidate || true
}


start_services_local(){
  services_guard_local_ports || return 1
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    step "Start Services Local"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable --now "$(svc_wg)" >/dev/null 2>&1 || true
    ok "Local WireGuard started."
    status_cache_invalidate || true
    return 0
  fi
  step "Start services (local)"
  local mimic_ok=0 wg_ok=0
  enable_mimic_local && mimic_ok=1 || warn "Local Mimic service did not start cleanly."
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl enable --now "$(svc_wg)" >/dev/null 2>&1 && wg_ok=1 || warn "Local WireGuard service did not start cleanly."
  status_cache_invalidate || true
  if (( mimic_ok == 1 && wg_ok == 1 )); then
    ok "Local services started."
    return 0
  fi
  return 1
}

start_services_remote(){
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    ok "Remote services skipped (account mode)."
    status_cache_invalidate || true
    return 0
  fi
  step "Start services (remote)"
  local mimic_ok=0 wg_ok=0
  enable_mimic_remote && mimic_ok=1 || warn "Remote Mimic service did not start cleanly."
  ssh_run_root_best_effort "systemctl enable --now wg-quick@${WG_IF} >/dev/null 2>&1" >/dev/null 2>&1 && wg_ok=1 || warn "Remote WireGuard service did not start cleanly."
  status_cache_invalidate || true
  if (( mimic_ok == 1 && wg_ok == 1 )); then
    ok "Remote services started (best-effort)."
    return 0
  fi
  return 1
}

restart_services_local(){
  services_guard_local_ports || return 1
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    step "Restart Services Local"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl restart "$(svc_wg)" >/dev/null 2>&1 || true
    ok "Local WireGuard restarted."
    status_cache_invalidate || true
    return 0
  fi
  step "Restart services (local)"
  local wan mimic_ok=0 wg_ok=0
  wan="$(mimic_detect_local_if 2>/dev/null || true)"
  [[ -n "$wan" ]] && mimic_restart_local_checked "$wan" && mimic_ok=1 || warn "Local Mimic restart was not confirmed."
  systemctl restart "$(svc_wg)" >/dev/null 2>&1 && wg_ok=1 || warn "Local WireGuard restart was not confirmed."
  status_cache_invalidate || true
  if (( mimic_ok == 1 && wg_ok == 1 )); then
    ok "Local services restarted."
    return 0
  fi
  return 1
}

restart_services_remote(){
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    ok "Remote services skipped (account mode)."
    status_cache_invalidate || true
    return 0
  fi
  step "Restart services (remote)"
  local wan="${REMOTE_WAN_IF:-}" mimic_ok=0 wg_ok=0
  if [[ -z "$wan" ]]; then
    wan="$(remote_detect_wan_if_quiet || true)"
  fi
  [[ -n "$wan" ]] && mimic_remote_restart_checked "$wan" && mimic_ok=1 || warn "Remote Mimic restart was not confirmed."
  ssh_run_root_best_effort "systemctl restart wg-quick@${WG_IF} >/dev/null 2>&1" >/dev/null 2>&1 && wg_ok=1 || warn "Remote WireGuard restart was not confirmed."
  status_cache_invalidate || true
  if (( mimic_ok == 1 && wg_ok == 1 )); then
    ok "Remote services restarted (best-effort)."
    return 0
  fi
  return 1
}

stop_services_local(){
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    step "Stop Services Local"
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl stop "$(svc_wg)" >/dev/null 2>&1 || true
    ok "Local WireGuard stopped."
    status_cache_invalidate || true
    return 0
  fi
  step "Stop services (local)"
  local wan svc
  wan="$(mimic_detect_local_if 2>/dev/null || true)"
  if command -v systemctl >/dev/null 2>&1; then
    while read -r svc; do
      [[ -n "$svc" ]] && systemctl stop "$svc" >/dev/null 2>&1 || true
    done < <(systemctl list-units --all 'mimic@*.service' --no-legend --plain 2>/dev/null | awk '{print $1}')
  fi
  [[ -n "$wan" ]] && systemctl stop "mimic@${wan}" >/dev/null 2>&1 || true
  systemctl stop "$(svc_wg)" >/dev/null 2>&1 || true
  ok "Local services stopped."
  status_cache_invalidate || true
}

stop_services_remote(){
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    ok "Remote services skipped (account mode)."
    status_cache_invalidate || true
    return 0
  fi
  step "Stop services (remote)"
  ssh_run_root_best_effort "systemctl stop wg-quick@${WG_IF} >/dev/null 2>&1 || true" >/dev/null 2>&1 || true

  local wan="${REMOTE_WAN_IF:-}"
  if [[ -z "$wan" ]]; then
    wan="$(remote_detect_wan_if_quiet || true)"
  fi
  [[ -n "$wan" ]] && ssh_run_root_best_effort "systemctl stop mimic@${wan} >/dev/null 2>&1 || true" >/dev/null 2>&1 || true

  ok "Remote services stopped (best-effort)."
  status_cache_invalidate || true
}


