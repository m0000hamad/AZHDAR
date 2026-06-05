#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

NONINTERACTIVE="0"
if [[ "${1:-}" == "--noninteractive" ]]; then
  NONINTERACTIVE="1"
  shift || true
fi

if [[ ${EUID:-999} -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

PREFIX="${PREFIX:-/usr/local}"
LIBDIR="${PREFIX}/lib/azhdar"
BINDIR="${PREFIX}/bin"
SRC_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="unknown"
if [[ -f "${SRC_ROOT}/lib/core.sh" ]]; then
  VERSION="$(awk -F'"' '/^SCRIPT_VERSION=/ {print $2; exit}' "${SRC_ROOT}/lib/core.sh" 2>/dev/null || true)"
  VERSION="${VERSION:-unknown}"
fi

ensure_system_ssh_service(){
  command -v systemctl >/dev/null 2>&1 || return 0
  local svc
  for svc in ssh.service sshd.service ssh.socket sshd.socket; do
    if systemctl list-unit-files "$svc" >/dev/null 2>&1 || systemctl status "$svc" >/dev/null 2>&1; then
      systemctl unmask "$svc" >/dev/null 2>&1 || true
      systemctl enable "$svc" >/dev/null 2>&1 || true
      systemctl is-active --quiet "$svc" >/dev/null 2>&1 || systemctl start "$svc" >/dev/null 2>&1 || true
    fi
  done
}

install_systemd_units(){
  command -v systemctl >/dev/null 2>&1 || { echo "i systemctl not found; skipped systemd unit install."; return 0; }
  [[ -d /etc/systemd/system ]] || { echo "i /etc/systemd/system not found; skipped systemd unit install."; return 0; }

  install -m 644 "${SRC_ROOT}/systemd/azhdar.service" /etc/systemd/system/azhdar.service || return 1
  [[ -f "${SRC_ROOT}/systemd/azhdar-watchdog.service" ]] && install -m 644 "${SRC_ROOT}/systemd/azhdar-watchdog.service" /etc/systemd/system/azhdar-watchdog.service || true
  [[ -f "${SRC_ROOT}/systemd/azhdar-watchdog.timer" ]] && install -m 644 "${SRC_ROOT}/systemd/azhdar-watchdog.timer" /etc/systemd/system/azhdar-watchdog.timer || true

  systemctl daemon-reload >/dev/null 2>&1 || true
  ensure_system_ssh_service || true
  systemctl enable azhdar.service >/dev/null 2>&1 || true

  # Operational safety: do NOT start azhdar.service immediately during install/update.
  # The boot unit re-applies firewall/NAT/WG state; starting it unexpectedly on a
  # live server can interrupt an active tunnel/SSH session. It will run on next boot,
  # or you can explicitly opt in with AZHDAR_START_ON_INSTALL=1.
  if [[ "${AZHDAR_START_ON_INSTALL:-0}" == "1" ]]; then
    systemctl start azhdar.service >/dev/null 2>&1 || true
    echo "✓ systemd unit installed and started by request."
  else
    echo "i azhdar.service enabled for boot, not started now for SSH/tunnel safety."
  fi
}

[[ -d "${SRC_ROOT}/lib" ]] || { echo "ERROR: missing source lib directory: ${SRC_ROOT}/lib" >&2; exit 2; }
[[ -f "${SRC_ROOT}/azhdar" ]] || { echo "ERROR: missing main executable: ${SRC_ROOT}/azhdar" >&2; exit 2; }

install -d -m 755 "${LIBDIR}/lib" "${LIBDIR}/scripts" "${BINDIR}"
cp -a "${SRC_ROOT}/lib/." "${LIBDIR}/lib/"
cp -a "${SRC_ROOT}/azhdar" "${LIBDIR}/azhdar"
if [[ -d "${SRC_ROOT}/scripts" ]]; then
  cp -a "${SRC_ROOT}/scripts/." "${LIBDIR}/scripts/"
  find "${LIBDIR}/scripts" -type f -name '*.sh' -exec chmod 755 {} + 2>/dev/null || true
fi
chmod 755 "${LIBDIR}/azhdar"
ln -sfn "${LIBDIR}/azhdar" "${BINDIR}/azhdar"

if [[ -d "${SRC_ROOT}/systemd" && -f "${SRC_ROOT}/systemd/azhdar.service" ]]; then
  install_systemd_units || echo "! systemd unit install failed; command was installed anyway."
else
  echo "i systemd unit files not present; skipped systemd unit install."
fi

echo "✓ Installed AZHDAR v${VERSION}"
echo "Run: azhdar"
echo "Tunnel repair now: azhdar --repair-tunnel --yes"
echo "Emergency IR repair without rebuild: azhdar --recover-ir"
