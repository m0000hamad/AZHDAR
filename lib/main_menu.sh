# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Main menu --------------------
set_ir_ssh_port_menu(){
  ensure_profile_selected || return 0
  banner
  echo -e "${BOLD}${WHT}IR SSH exempt port${RST}"
  hr
  echo -e "${DIM}This is the SSH port of the IR server itself. AZHDAR will keep this TCP port out of tunnels/forwarding so the remote console stays reachable.${RST}"
  echo
  IR_SSH_PORT="$(prompt_port "IR server SSH port to exempt" "${IR_SSH_PORT:-22}")"
  protect_ir_ssh_port || true
  profile_save
  ok "IR SSH exempt port saved: ${IR_SSH_PORT}"
  pause
}

menu_manage_profiles(){
  while true; do
    banner
    echo -e "${BOLD}${WHT}Profiles${RST}"
    hr
    echo -e "${DIM}Current:${RST} ${CURRENT_PROFILE:-<none>}"
    echo
    echo " 1) Select/switch profile"
    echo " 2) Add new profile"
    echo " 3) Delete profile"
    echo " 0) Back"
    hr
    read -rp "Select: " c || true
    case "${c:-}" in
      1)
        profile_select || true
        # if user selected, ensure loaded
        if [[ -n "${CURRENT_PROFILE:-}" ]] && profile_exists "$CURRENT_PROFILE"; then
    profile_load "$CURRENT_PROFILE" 2>/dev/null || true
  elif [[ -n "${CURRENT_PROFILE:-}" ]]; then
    warn "Stored CURRENT_PROFILE '${CURRENT_PROFILE}' not found; clearing selection."
    CURRENT_PROFILE=""
    save_global 2>/dev/null || true
  fi
        ;;
      2) profile_add_wizard || true ;;
      3)
        read -rp "Profile name to delete: " n || true
        n="$(safe_name "$n")"
        [[ -n "$n" ]] || { warn "Empty name."; pause; continue; }
        [[ "$(prompt_yesno "Confirm FULL delete '${n}' (local+remote)?" "N")" == "Y" ]] || { warn "Cancelled."; pause; continue; }
        profile_full_delete "$n" || true
        pause
        ;;
      0) return 0 ;;
      *) warn "Invalid."; pause ;;
    esac
  done
}

menu_services(){
  while true; do
    banner
    echo -e "${BOLD}${WHT}Services (profile: ${PROFILE})${RST}"
    hr
    profile_status_line_fast
    hr
    echo " 1) Start services"
    echo " 2) Stop services"
    echo " 3) Restart services"
    echo " 4) Status summary"
    echo " 0) Back"
    hr
    read -rp "Select: " c || true
    case "${c:-}" in
      1) start_services_remote || true; start_services_local || true; pause ;;
      2) stop_services_local || true; stop_services_remote || true; pause ;;
      3) restart_services_remote || true; restart_services_local || true; pause ;;
      4)
        local wan; wan="$(detect_wan_if)"
        azhdar_unit_brief_local "Local WG" "$(svc_wg)"
        azhdar_unit_brief_local "Local Mimic" "mimic@${wan}"
        pause
        ;;
      0) return 0 ;;
      *) warn "Invalid."; pause ;;
    esac
  done
}

menu_forwarding(){
  while true; do
    banner
    echo -e "${BOLD}${WHT}Forwarding (IR)${RST}"
    hr
    echo -e "${DIM}TCP ports:${RST} ${FORWARD_TCP_PORTS:-<none>}"
    echo -e "${DIM}UDP ports:${RST} ${FORWARD_UDP_PORTS:-<none>}"
    echo -e "${DIM}OUT dst port:${RST} ${VLESS_DST_PORT:-<none>}"
    echo -e "${DIM}IR SSH protected:${RST} ${IR_SSH_PORT:-22}"
    hr
    echo " 1) Apply forwarding rules"
    echo " 2) Remove forwarding rules"
    echo " 0) Back"
    hr
    read -rp "Select: " c || true
    case "${c:-}" in
      1) azhdar_firewall_safety_local || true; setup_forward_ir || warn "Forwarding apply failed; check Diagnostics."; pause ;;
      2) remove_forward_rules_local || warn "Forwarding cleanup failed; check Diagnostics."; pause ;;
      0) return 0 ;;
      *) warn "Invalid."; pause ;;
    esac
  done
}

main_menu(){
  while true; do
    banner

    if [[ -n "${CURRENT_PROFILE:-}" ]] && profile_exists "${CURRENT_PROFILE}"; then
      profile_load "${CURRENT_PROFILE}" 2>/dev/null || true
      echo -e "${BOLD}${WHT}Active profile:${RST} ${BOLD}${CYN}${PROFILE}${RST}"
      profile_status_line_fast
      profile_quick_info_panel
    else
      echo -e "${YLW}No profile selected.${RST}"
    fi
    hr

    echo " 1) Set IR SSH exempt port (default 22)"
    echo " 2) Manage profiles (select/add/delete)"
    echo " 3) Install / Update / Repair (wizard)"
    echo " 4) Offline install (no SSH) - build remote bundle"
    echo " 5) Status indicator"
    echo " 6) Diagnostics (summary)"
    echo " 7) Services (start/stop/restart)"
    echo " 8) Forwarding (DNAT)"
    echo " 9) Advanced settings"
    echo "10) Cleanup / Uninstall"
    echo "11) SSH fallback (reverse tunnel)"
    echo "12) Update AZHDAR"
    echo "13) Repair tunnel / auto watchdog"
    echo "14) Emergency IR recovery (no rebuild)"
    echo " 0) Exit"
    hr

    read -rp "Select: " c || true
    c="${c:-}"

    case "$c" in
      1)
        set_ir_ssh_port_menu || true
        ;;
      2)
        menu_manage_profiles || true
        ;;
      3)
        ensure_profile_selected || { pause; continue; }
        install_wizard || true
        ;;
      4)
        ensure_profile_selected || { pause; continue; }
        offline_bundle_wizard || true
        ;;
      5)
        ensure_profile_selected || { pause; continue; }
        banner; connection_indicator || true; pause
        ;;
      6)
        ensure_profile_selected || { pause; continue; }
        diagnostics_full || true
        ;;
      7)
        ensure_profile_selected || { pause; continue; }
        menu_services || true
        ;;
      8)
        ensure_profile_selected || { pause; continue; }
        menu_forwarding || true
        ;;
      9)
        ensure_profile_selected || { pause; continue; }
        menu_advanced || true
        ;;
      10)
        ensure_profile_selected || { pause; continue; }
        menu_cleanup || true
        ;;
      11)
        ensure_profile_selected || { pause; continue; }
        menu_ssh_fallback || true
        ;;
      12)
        azhdar_update_menu || true
        pause
        ;;
      13)
        ensure_profile_selected || { pause; continue; }
        menu_tunnel_repair || true
        ;;
      14)
        azhdar_recover_ir_runtime || true
        pause
        ;;
      0)
        exit 0
        ;;
      *)
        warn "Invalid choice."
        pause
        ;;
    esac
  done
}
