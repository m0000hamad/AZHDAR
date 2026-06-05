# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Remote preflight analysis --------------------
remote_preflight(){
  banner
  echo -e "${BOLD}${WHT}Remote preflight analysis${RST}"
  hr

  [[ -n "${OUT_SSH_HOST:-}" ]] || die "OUT_SSH_HOST is empty. Configure a profile first."
  ssh_check || return 1

  step "Detect remote privilege/sudo"
  local uid
  uid="$(ssh_run "id -u" 2>/dev/null | tr -d '\r' | tail -n1 || true)"
  if [[ "$uid" == "0" ]]; then
    REMOTE_SUDO=""
    REMOTE_SUDO_DETECTED="1"
    ok "Remote user is root."
  else
    if ssh_run "sudo -n true >/dev/null 2>&1 && echo OK || echo NO" | tail -n1 | grep -qx OK; then
      REMOTE_SUDO="sudo -n"
      REMOTE_SUDO_DETECTED="1"
      warn "Remote user is not root; using sudo -n for remote commands."
    else
      err "Remote user is not root and passwordless sudo is not available."
      echo -e "${YLW}Fix:${RST} Use root SSH, or configure passwordless sudo for this user."
      return 1
    fi
  fi

  step "Collect remote OS info"
  local arch os_id os_ver codename has_systemd has_apt info_kv

  info_kv="$(remote_os_info 2>/dev/null | tr -d '\r' || true)"
  arch="$(echo "$info_kv" | awk -F= '/^ARCH=/{print $2; exit}' || true)"
  os_id="$(echo "$info_kv" | awk -F= '/^ID=/{print $2; exit}' || true)"
  os_ver="$(echo "$info_kv" | awk -F= '/^VERSION_ID=/{print $2; exit}' || true)"
  codename="$(echo "$info_kv" | awk -F= '/^CODENAME=/{print $2; exit}' || true)"
  has_systemd="$(echo "$info_kv" | awk -F= '/^SYSTEMD=/{print $2; exit}' || true)"
  has_apt="$(echo "$info_kv" | awk -F= '/^APT=/{print $2; exit}' || true)"

  arch="${arch:-unknown}"
  arch="${arch%% *}"
  if [[ "$arch" == *"x86_64"* || "$arch" == *"amd64"* ]]; then
    arch="x86_64"
  fi

  os_id="${os_id:-unknown}"
  os_id="${os_id,,}"
  os_ver="${os_ver:-unknown}"

  codename="${codename:-}"
  codename="${codename,,}"
  if [[ -z "$codename" ]]; then
    case "${os_id}:${os_ver}" in
      debian:13*|debian:13.*) codename="trixie" ;;
      debian:12*|debian:12.*) codename="bookworm" ;;
      debian:11*|debian:11.*) codename="bullseye" ;;
      debian:10*|debian:10.*) codename="buster" ;;
      ubuntu:24.04*|ubuntu:24.04.*) codename="noble" ;;
      ubuntu:23.10*|ubuntu:23.10.*) codename="mantic" ;;
      ubuntu:22.04*|ubuntu:22.04.*) codename="jammy" ;;
      ubuntu:20.04*|ubuntu:20.04.*) codename="focal" ;;
    esac
  fi

  has_systemd="${has_systemd:-no}"
  has_apt="${has_apt:-no}"

  echo -e "${DIM}Remote:${RST} arch=${arch}  os=${os_id} ${os_ver}  codename=${codename:-unknown}"

  echo -e "${DIM}Remote:${RST} systemd=${has_systemd}  apt=${has_apt}"
  hr

  step "IPv6 capability (optional)"
  local ipv6_local_disable ipv6_remote_disable
  ipv6_local_disable="$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0)"
  ipv6_remote_disable="$(ssh_run "cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null || echo 0" 2>/dev/null | tr -d '\r' | tail -n1 || true)"
  ipv6_remote_disable="${ipv6_remote_disable:-0}"
  echo -e "${DIM}IPv6:${RST} local_disable=${ipv6_local_disable}  remote_disable=${ipv6_remote_disable}"
  if [[ "${ENABLE_TUN_IPV6:-0}" == "1" ]]; then
    if [[ "${ipv6_local_disable}" == "1" || "${ipv6_remote_disable}" == "1" ]]; then
      warn "IPv6 is disabled on at least one side; tunnel IPv6 addresses may not work."
      echo -e "${YLW}Fix:${RST} enable IPv6 (disable_ipv6=0) and re-run Install/Repair."
    else
      ok "IPv6 appears enabled on both sides."
    fi
  else
    info "IPv6 inside tunnel is disabled in profile; this is OK."
  fi
  hr

  local blockers=0

  if [[ "$has_systemd" != "yes" ]]; then
    err "BLOCKER: systemd/systemctl not found on remote. This script relies on systemd services."
    blockers=$((blockers+1))
  fi

  if [[ "$arch" != "x86_64" && "$arch" != "amd64" ]]; then
    err "BLOCKER: remote architecture '${arch}' is not amd64/x86_64."
    echo -e "${YLW}Reason:${RST} Mimic release packages are amd64-only."
    blockers=$((blockers+1))
  fi

  if [[ "$has_apt" != "yes" ]]; then
    err "BLOCKER: apt-get not found on remote."
    echo -e "${YLW}Reason:${RST} This script installs Mimic via Debian/Ubuntu .deb packages."
    echo -e "${YLW}Fix:${RST} Use Debian/Ubuntu (apt-based) on the remote server."
    blockers=$((blockers+1))
  else
    if [[ -n "${codename:-}" ]]; then
      local sup
      sup="$(mimic_supported_codename "$codename" || true)"
      if [[ "$sup" == "no" ]]; then
        err "BLOCKER: Mimic release assets not found for remote codename '${codename}'."
        echo -e "${YLW}Fix:${RST} Use Debian 12 (bookworm) / Ubuntu 24.04 (noble) or newer."
        blockers=$((blockers+1))
      elif [[ "$sup" == "unknown" ]]; then
        warn "WARNING: cannot verify Mimic release assets (curl missing or GitHub blocked). Install may fail."
      else
        ok "Mimic packages appear available for codename '${codename}'."
      fi
    else
      warn "WARNING: remote codename not detected; Mimic install may fail."
    fi
  fi

  # Port checks (WG_PORT is the external 'fake TCP' port)
  step "Port availability checks"
  local inuse_local="no" inuse_remote="no"
  if local_port_in_use "${WG_PORT}"; then inuse_local="yes"; fi
  if remote_port_in_use "${WG_PORT}"; then inuse_remote="yes"; fi

  if [[ "$inuse_local" == "yes" || "$inuse_remote" == "yes" ]]; then
    warn "Selected port ${WG_PORT} looks busy (local=${inuse_local}, remote=${inuse_remote})."
    local sug
    sug="$(suggest_wg_port || true)"
    if [[ -n "$sug" && "$sug" != "$WG_PORT" ]]; then
      warn "Suggested free port: ${sug}"
    fi
  else
    ok "Port ${WG_PORT} looks free on both sides (best-effort)."
  fi

  hr
  if (( blockers > 0 )); then
    err "Preflight result: NOT OK (blockers=${blockers})."
    return 1
  fi

  ok "Preflight result: OK."
  return 0
}

