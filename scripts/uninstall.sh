#!/usr/bin/env bash
set -Eeuo pipefail
umask 022

PURGE="0"
if [[ "${1:-}" == "--purge" ]]; then
  PURGE="1"
fi

if [[ ${EUID:-999} -ne 0 ]]; then
  echo "Run as root (sudo)." >&2
  exit 1
fi

PREFIX="/usr/local"
LIBDIR="${PREFIX}/lib/azhdar"
BINLINK="${PREFIX}/bin/azhdar"

systemctl disable --now azhdar.service >/dev/null 2>&1 || true
systemctl disable --now azhdar-watchdog.timer azhdar-watchdog.service >/dev/null 2>&1 || true
rm -f /etc/systemd/system/azhdar.service /etc/systemd/system/azhdar-watchdog.service /etc/systemd/system/azhdar-watchdog.timer 2>/dev/null || true
systemctl daemon-reload >/dev/null 2>&1 || true

rm -f "${BINLINK}" 2>/dev/null || true
rm -rf "${LIBDIR}" 2>/dev/null || true

if [[ "${PURGE}" == "1" ]]; then
  rm -rf /etc/azhdar 2>/dev/null || true
fi

echo "✓ Uninstalled AZHDAR"
if [[ "${PURGE}" == "1" ]]; then
  echo "✓ Purged /etc/azhdar state"
fi
