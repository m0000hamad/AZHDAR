# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Main --------------------
azhdar_boot(){
  need_root
  ensure_dirs
  migrate_legacy
  azhdar_ensure_system_ssh_local || true
  load_global

  if [[ -z "${CURRENT_PROFILE:-}" ]] || ! profile_exists "${CURRENT_PROFILE}"; then
    exit 0
  fi

  profile_load "${CURRENT_PROFILE}" 2>/dev/null || true
  defaults_profile
  if [[ "${WG_MODE:-classic}" == "account" ]]; then
    wg_account_apply_runtime_vars || true
  fi

  # v3.1.2 boot policy: LOCAL-ONLY, non-persistent, non-destructive.
  # Do not SSH to OUT and do not rewrite/restart remote services at boot. The
  # previous behavior could leave the IR host in a poisoned state if public SSH
  # timed out while stale iptables/systemd state was restored. Remote services
  # are enabled during install and should boot on the OUT host independently.
  azhdar_firewall_safety_local || true
  azhdar_ssh_guard_local || true

  # Rebuild local runtime from the selected profile only.
  if [[ "${WG_MODE:-classic}" != "account" ]]; then
    if [[ -n "${IR_LOCAL_IP:-}" && -n "${OUT_PUBLIC_IP:-}" ]]; then
      ( write_mimic_conf_local ) >/dev/null 2>&1 || true
    fi
  fi

  if [[ -f "/etc/wireguard/${WG_IF}.key" && -n "${OUT_PUBKEY:-}" ]]; then
    ( write_wg_conf_local ) >/dev/null 2>&1 || true
  fi

  if [[ "${WG_MODE:-classic}" != "account" ]]; then
    allow_mimic_port_local || true
    setup_rst_drop_local || true
  fi
  remove_forwarding_local || true
  if [[ -n "${FORWARD_TCP_PORTS:-}${FORWARD_UDP_PORTS:-}" ]]; then
    setup_forward_ir || true
  fi

  azhdar_ssh_guard_local || true
  start_services_local || true
  azhdar_ssh_guard_local || true
  exit 0
}

azhdar_main(){
  need_root
  ensure_dirs
  # Keep interactive menus open on recoverable failures. Fatal helpers such as
  # die() still exit, but ordinary non-zero statuses become warnings/return codes.
  azhdar_interactive_mode
  migrate_legacy
  azhdar_ensure_system_ssh_local || true
  load_global

  if ! startup_profile_prompt; then
    banner
    echo -e "${YLW}No profiles found.${RST}"
    echo
    if [[ "$(prompt_yesno "Add a new profile now?" "Y")" == "Y" ]]; then
      profile_add_wizard
    else
      exit 0
    fi
  fi

  # Ensure active profile loaded
  if [[ -n "${CURRENT_PROFILE:-}" ]] && profile_exists "$CURRENT_PROFILE"; then
    profile_load "$CURRENT_PROFILE" 2>/dev/null || true
  elif [[ -n "${CURRENT_PROFILE:-}" ]]; then
    warn "Stored CURRENT_PROFILE '${CURRENT_PROFILE}' not found; clearing selection."
    CURRENT_PROFILE=""
    save_global 2>/dev/null || true
  fi

  main_menu
}
