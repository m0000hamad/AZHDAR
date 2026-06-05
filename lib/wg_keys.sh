# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- WireGuard key management --------------------
ensure_privkey_local(){
  mkdir -p /etc/wireguard || { err "Cannot create /etc/wireguard."; return 1; }
  local k="/etc/wireguard/${WG_IF}.key"
  if [[ ! -s "$k" ]]; then
    have_cmd wg || { err "WireGuard tool 'wg' is not installed."; return 1; }
    if ! wg genkey >"$k" 2>/dev/null; then
      rm -f "$k" >/dev/null 2>&1 || true
      err "Failed to generate local WireGuard key: $k"
      return 1
    fi
    chmod 600 "$k" 2>/dev/null || true
  fi
  return 0
}

get_pubkey_local(){
  local k="/etc/wireguard/${WG_IF}.key"
  [[ -s "$k" ]] || return 1
  have_cmd wg || return 1
  wg pubkey <"$k" 2>/dev/null
}

ensure_psk(){
  if [[ "${USE_PSK}" != "1" ]]; then
    PSK_VALUE=""
    return 0
  fi
  if [[ -n "${PSK_VALUE:-}" ]]; then
    return 0
  fi
  PSK_VALUE="$(wg genpsk 2>/dev/null | tr -d '\n\r' || true)"
  [[ -n "${PSK_VALUE:-}" ]] || die "Failed to generate PSK."
}

