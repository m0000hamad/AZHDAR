# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Legacy migration (from wg-reverse.*.state.v6) --------------------
migrate_legacy(){
  # Best-effort: if legacy state files exist, import them as profiles (once).
  local legacy_dir="/etc/wireguard"
  shopt -s nullglob
  local f name
  for f in "${legacy_dir}"/wg-reverse.*.state.v6; do
    name="${f##*/wg-reverse.}"
    name="${name%.state.v6}"
    name="$(safe_name "$name")"
    [[ -n "$name" ]] || continue
    local outp; outp="$(profile_path "$name")"
    [[ -f "$outp" ]] && continue

    # Create profile and source legacy vars
    PROFILE="$name"; WG_IF="$name"
    # shellcheck disable=SC1090
    source "$f" 2>/dev/null || true

    # Legacy used TUN_NAME and WG_IF inconsistently; force WG_IF to profile name
    WG_IF="$name"
    PROFILE="$name"

    # Some legacy fields:
    # - OUT_SSH_HOST/PORT/USER/IDENTITY/PASS
    # - IR_PUBLIC_IP / OUT_PUBLIC_IP
    # - WG_PORT / MTU / KEEPALIVE / USE_PSK / PSK_VALUE
    # - TUN_SUBNET / IR_WG_IP / OUT_WG_IP
    # - FORWARD_TCP_PORTS / FORWARD_UDP_PORTS / VLESS_DST_PORT
    # - IR_LOCAL_IP / OUT_LOCAL_IP
    PROFILE_ENABLED="${PROFILE_ENABLED:-1}"

    profile_save >/dev/null 2>&1 || true
  done
  shopt -u nullglob
}

