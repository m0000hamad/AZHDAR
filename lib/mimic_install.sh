# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Mimic installation --------------------
github_latest_asset_url(){
  # args: repo (owner/name), regex
  local repo="$1"; local pat="$2"
  curl -fsSL --max-time 6 "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null | \
    sed -n 's/.*"browser_download_url"[ ]*:[ ]*"\([^"]*\)".*/\1/p' | \
    grep -E "${pat}" | head -n1 || true
}


# -------------------- IR mirror (fast fallback) --------------------
# If downloads from global sources (GitHub/Ubuntu) are filtered or slow on IR,
# we can fallback to Iranian mirrors. OUT keeps using original URLs.
IR_MIRROR_MIMIC_NOBLE_DEB="${ASSET_MIRROR_BASE}/noble_mimic_0.7.0-1_amd64.deb"
IR_MIRROR_MIMIC_NOBLE_DKMS_DEB="${ASSET_MIRROR_BASE}/noble_mimic-dkms_0.7.0-1_amd64.deb"
IR_MIRROR_MIMIC_BOOKWORM_DEB="${ASSET_MIRROR_BASE}/bookworm_mimic_0.7.0-1_amd64.deb"
IR_MIRROR_MIMIC_BOOKWORM_DKMS_DEB="${ASSET_MIRROR_BASE}/bookworm_mimic-dkms_0.7.0-1_amd64.deb"
IR_MIRROR_WG_TOOLS_DEB="${ASSET_MIRROR_BASE}/wireguard-tools_1.0.20210914-1ubuntu4_amd64.deb"
IR_MIRROR_WG_DKMS_DEB="${ASSET_MIRROR_BASE}/wireguard-dkms_1.0.20210606-1_all.deb"

# curl with strict time + "slow download" detection (abort quickly then fallback).
# Defaults are tuned to avoid waiting too long on filtered/slow links.
curl_fetch_fast(){
  # usage: curl_fetch_fast <url> <out>
  local url="$1" out="$2"
  curl -fL \
    --connect-timeout 4 \
    --max-time 25 \
    --retry 1 --retry-delay 1 --retry-max-time 10 \
    --speed-time 8 --speed-limit 25000 \
    "$url" -o "$out" >/dev/null 2>&1
}

fetch_with_fallback(){
  # usage: fetch_with_fallback <primary_url> <fallback_url> <out>
  # tries primary first; if blocked/slow/fails, tries fallback.
  local primary="$1" fallback="$2" out="$3"
  if [[ -n "$primary" ]] && curl_fetch_fast "$primary" "$out"; then
    return 0
  fi
  [[ -n "$fallback" ]] || return 1
  curl_fetch_fast "$fallback" "$out"
}

asset_mirror_share_api_url(){
  # Convert ASSET_MIRROR_BASE to the File Browser public-share API URL.
  # Accepted inputs:
  #   https://host/share/HASH
  #   https://host/api/public/share/HASH
  #   https://host/api/public/dl/HASH
  local base="${ASSET_MIRROR_BASE%/}" root share
  case "$base" in
    */api/public/dl/*)
      share="${base##*/api/public/dl/}"
      root="${base%%/api/public/dl/*}"
      printf '%s\n' "${root}/api/public/share/${share}"
      ;;
    */api/public/share/*)
      printf '%s\n' "$base"
      ;;
    */share/*)
      share="${base##*/share/}"
      root="${base%%/share/*}"
      printf '%s\n' "${root}/api/public/share/${share}"
      ;;
    *)
      return 1
      ;;
  esac
}

asset_mirror_names(){
  local api json
  api="$(asset_mirror_share_api_url 2>/dev/null || true)"
  [[ -n "$api" ]] || return 1
  json="$(curl -fsSL --max-time 8 "$api" 2>/dev/null || true)"
  [[ -n "$json" ]] || return 1
  # Do not require jq here; installer must work on minimal systems.
  printf '%s' "$json" | grep -oE '"name"[[:space:]]*:[[:space:]]*"[^"]+"' | sed -E 's/.*"name"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/'
}

mimic_mirror_asset_url(){
  # usage: mimic_mirror_asset_url <codename> <mimic|mimic-dkms>
  # Picks the newest matching .deb from the mirror share. It intentionally accepts
  # both codename-prefixed assets (bookworm_mimic_...) and official Debian-style
  # assets (mimic_0.7.0+ds-2_amd64.deb), so filenames are version-flexible.
  local codename="$1" kind="$2" names name pat
  codename="${codename,,}"
  names="$(asset_mirror_names 2>/dev/null || true)"
  [[ -n "$names" ]] || return 1

  local -a patterns
  if [[ "$kind" == "mimic-dkms" ]]; then
    patterns=(
      "^${codename}_mimic-dkms_[^/]+_amd64\.deb$"
      "^mimic-dkms_[^/]+_amd64\.deb$"
      "^[a-z0-9._-]+_mimic-dkms_[^/]+_amd64\.deb$"
    )
  else
    patterns=(
      "^${codename}_mimic_[^/]+_amd64\.deb$"
      "^mimic_[^/]+_amd64\.deb$"
      "^[a-z0-9._-]+_mimic_[^/]+_amd64\.deb$"
    )
  fi

  for pat in "${patterns[@]}"; do
    name="$(printf '%s\n' "$names" | grep -E "$pat" | sort -V | tail -n1 || true)"
    if [[ -n "$name" ]]; then
      printf '%s/%s\n' "${ASSET_MIRROR_BASE%/}" "$name"
      return 0
    fi
  done
  return 1
}

azhdar_apt_get(){
  # Keep apt/needrestart non-interactive and avoid scary raw apt notices in the UI.
  DEBIAN_FRONTEND=noninteractive \
  NEEDRESTART_MODE=a \
  NEEDRESTART_SUSPEND=1 \
  APT_LISTCHANGES_FRONTEND=none \
  apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 "$@"
}

azhdar_prepare_local_debs_for_apt(){
  # apt drops privileges to _apt while reading local .deb files. If root creates
  # a temporary directory with a restrictive umask, apt prints:
  #   Download is performed unsandboxed as root ... couldn't be accessed by _apt
  # Make the temp dir/files readable so that notice does not appear.
  local dir="$1"
  chmod 755 "$dir" 2>/dev/null || true
  chmod 644 "$dir"/*.deb 2>/dev/null || true
}

azhdar_print_apt_failure_log(){
  local log="$1"
  [[ -s "$log" ]] || return 0
  grep -v -E '^(N: Download is performed unsandboxed as root|User sessions running outdated binaries:|No VM guests are running outdated hypervisor)' "$log" 2>/dev/null | tail -n 80 || tail -n 80 "$log" || true
}
ensure_cache_dir(){
  mkdir -p "${BASE_DIR}/cache/mimic" 2>/dev/null || true
}

cache_put(){
  # args: codename, mimic.deb path, mimic-dkms.deb path
  local codename="$1" f1="$2" f2="$3"
  ensure_cache_dir
  mkdir -p "${BASE_DIR}/cache/mimic/${codename}" 2>/dev/null || true
  cp -f "$f1" "${BASE_DIR}/cache/mimic/${codename}/mimic.deb" 2>/dev/null || true
  cp -f "$f2" "${BASE_DIR}/cache/mimic/${codename}/mimic-dkms.deb" 2>/dev/null || true
}


mimic_supported_codename(){
  local codename="$1"
  # Best-effort check against latest release assets.
  # Returns: yes | no | unknown
  have_cmd curl || { echo "unknown"; return 0; }

  local json urls u1 u2
  json="$(curl -fsSL --max-time 6 "https://api.github.com/repos/hack3ric/mimic/releases/latest" 2>/dev/null || true)"
  [[ -n "$json" ]] || { echo "unknown"; return 0; }

  urls="$(printf "%s" "$json" | sed -n 's/.*"browser_download_url"[ ]*:[ ]*"\([^"]*\)".*/\1/p' || true)"
  [[ -n "$urls" ]] || { echo "unknown"; return 0; }

  u1="$(printf "%s\n" "$urls" | grep -E ".*/${codename}_mimic_[^/]*_amd64\.deb$" | head -n1 || true)"
  u2="$(printf "%s\n" "$urls" | grep -E ".*/${codename}_mimic-dkms_[^/]*_amd64\.deb$" | head -n1 || true)"

  if [[ -n "$u1" && -n "$u2" ]]; then
    echo "yes"
  else
    echo "no"
  fi
}

install_mimic_local(){
  step "Install Mimic on IR (local)"
  if have_cmd mimic; then
    ok "Mimic already installed (local)."
    return 0
  fi
  if ! have_cmd apt-get; then
    die "Mimic installer currently supports Debian/Ubuntu (apt) only on this host."
  fi

  local codename=""
  codename="$(detect_codename_local)"
  codename="${codename,,}"
  [[ -n "$codename" ]] || die "Cannot detect OS codename."

  # Asset mirror fallbacks (used when GitHub is blocked).
  # Resolve dynamically from the File Browser share, so exact version filenames do not matter.
  local fb1="" fb2=""
  fb1="$(mimic_mirror_asset_url "$codename" mimic 2>/dev/null || true)"
  fb2="$(mimic_mirror_asset_url "$codename" mimic-dkms 2>/dev/null || true)"

local okcod
okcod="$(mimic_supported_codename "$codename" || true)"
if [[ "$okcod" == "no" ]]; then
  if [[ -n "$fb1" && -n "$fb2" ]]; then
    warn "Mimic GitHub assets not found for codename='${codename}', but an IR mirror is configured; continuing with mirror (best-effort)."
  else
    die "Mimic release assets not found for codename='${codename}'. Use Debian 12 (bookworm) / Ubuntu 24.04 (noble) or newer."
  fi
fi

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
azhdar_apt_get update -y >/dev/null 2>&1 || true

# Ensure build deps for Mimic-DKMS (dkms + toolchain + matching headers)
if ! have_cmd dkms || ! dpkg -s build-essential >/dev/null 2>&1; then
  info "Installing DKMS build deps (dkms, build-essential, headers)..."
fi
if ! apt_install_retry dkms build-essential "linux-headers-$(uname -r)"; then
  err "Failed installing dkms/build-essential/headers. Attempting fix-broken and retry..."
  azhdar_apt_get -f install -y >/dev/null 2>&1 || true
  apt_install_retry dkms build-essential "linux-headers-$(uname -r)" ||       apt_install_retry dkms build-essential linux-headers-generic ||       die "Cannot install build deps. Run: apt --fix-broken install ; apt full-upgrade"
fi

apt_install_retry curl ca-certificates linux-tools-common "linux-tools-$(uname -r)" xz-utils lz4 >/dev/null 2>&1 || true


local tmp="/tmp/mimic-install.$$"
rm -rf "$tmp"; mkdir -p "$tmp"; chmod 755 "$tmp" 2>/dev/null || true

local u1 u2
# Try GitHub first (if reachable); otherwise fall back to the IR mirror.
u1="$(github_latest_asset_url "hack3ric/mimic" ".*/${codename}_mimic_[^/]*_amd64\.deb$" 2>/dev/null || true)"
u2="$(github_latest_asset_url "hack3ric/mimic" ".*/${codename}_mimic-dkms_[^/]*_amd64\.deb$" 2>/dev/null || true)"

if [[ -z "$u1" || -z "$u2" ]]; then
  if [[ -n "$fb1" && -n "$fb2" ]]; then
    warn "GitHub assets lookup failed (or blocked). Using configured mirror for Mimic (${codename})."
  else
    die "Failed to locate Mimic .deb assets for codename=${codename}."
  fi
fi

  fetch_with_fallback "$u1" "$fb1" "$tmp/mimic.deb" || die "Failed to download Mimic package (primary+fallback)."
  fetch_with_fallback "$u2" "$fb2" "$tmp/mimic-dkms.deb" || die "Failed to download Mimic DKMS package (primary+fallback)."
  # Basic sanity check (guard against HTML/blocked pages saved as .deb)
  dpkg-deb -I "$tmp/mimic.deb" >/dev/null 2>&1 || die "Downloaded mimic.deb is not a valid Debian package. Check ASSET_MIRROR_BASE or connectivity."
  dpkg-deb -I "$tmp/mimic-dkms.deb" >/dev/null 2>&1 || die "Downloaded mimic-dkms.deb is not a valid Debian package. Check ASSET_MIRROR_BASE or connectivity."

  # Cache packages for reuse (offline bundle can embed these later)
  cache_put "$codename" "$tmp/mimic.deb" "$tmp/mimic-dkms.deb"

  # Install local .deb packages quietly. Full apt output is kept in a log and
  # printed only on failure; success/failure is summarized by AZHDAR itself.
  azhdar_prepare_local_debs_for_apt "$tmp"
  local apt_log="$tmp/apt-install.log"
  if ! azhdar_apt_get install -y "$tmp/mimic.deb" "$tmp/mimic-dkms.deb" >"$apt_log" 2>&1; then
    err "apt failed installing mimic packages. Trying fix-broken then retry..."
    azhdar_apt_get -f install -y >/dev/null 2>&1 || true
    if ! azhdar_apt_get install -y "$tmp/mimic.deb" "$tmp/mimic-dkms.deb" >>"$apt_log" 2>&1; then
      err "If it still fails, check: /var/lib/dkms/mimic/*/build/make.log"
      azhdar_print_apt_failure_log "$apt_log"
      tail -n 80 /var/log/dpkg.log 2>/dev/null || true
    fi
  fi

  if ! have_cmd mimic; then
    err "Mimic install failed on local host."
    dpkg -l | grep -i mimic || true
    die "Mimic install failed. If DKMS failed, ensure compatible kernel + headers are available."
  fi
  ok "Mimic installed (local)."
}

install_mimic_remote(){
  step "Install Mimic on OUT (remote)"
  if ssh_run "command -v mimic >/dev/null 2>&1 && echo yes || echo no" | tail -n1 | grep -qx yes; then
    ok "Mimic already installed (remote)."
    return 0
  fi

  # Detect remote codename + arch (best-effort)
  local arch codename os_id os_ver info_kv
  info_kv="$(remote_os_info 2>/dev/null | tr -d '\r' || true)"
  arch="$(echo "$info_kv" | awk -F= '/^ARCH=/{print $2; exit}' || true)"
  os_id="$(echo "$info_kv" | awk -F= '/^ID=/{print $2; exit}' || true)"
  os_ver="$(echo "$info_kv" | awk -F= '/^VERSION_ID=/{print $2; exit}' || true)"
  codename="$(echo "$info_kv" | awk -F= '/^CODENAME=/{print $2; exit}' || true)"

  arch="${arch:-unknown}"
  arch="${arch%% *}"
  os_id="${os_id:-unknown}"
  os_ver="${os_ver:-unknown}"
  codename="${codename,,}"
  os_id="${os_id,,}"

  # Robust arch normalization (guards against malformed outputs like x86_64ID)
  if [[ "$arch" == *"x86_64"* || "$arch" == *"amd64"* ]]; then
    arch="x86_64"
  fi

  # Fallback codename mapping when CODENAME is missing.
  if [[ -z "${codename:-}" ]]; then
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

  [[ "$arch" == "x86_64" ]] || die "Remote architecture '${arch}' is not amd64/x86_64; Mimic packages are amd64-only."
  [[ -n "${codename:-}" ]] || die "Cannot detect remote OS codename."

  # Mirror fallbacks for remote install (used when GitHub is blocked).
  # Resolve dynamically from the File Browser share, so exact version filenames do not matter.
  local fb1="" fb2=""
  fb1="$(mimic_mirror_asset_url "$codename" mimic 2>/dev/null || true)"
  fb2="$(mimic_mirror_asset_url "$codename" mimic-dkms 2>/dev/null || true)"

local okcod
okcod="$(mimic_supported_codename "$codename" || true)"
if [[ "$okcod" == "no" ]]; then
  if [[ -n "$fb1" && -n "$fb2" ]]; then
    warn "Mimic GitHub assets not found for remote codename='${codename}', but a mirror is configured; continuing with mirror (best-effort)."
  else
    die "Mimic release assets not found for remote codename='${codename}'. Use Debian 12 (bookworm) / Ubuntu 24.04 (noble) or newer."
  fi
fi

  ssh_run_stdin_env_root "CODENAME=${codename} MIMIC_FB_DEB=${fb1} MIMIC_FB_DKMS=${fb2}" <<'REMOTE'
set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
  echo "NO_APT"
  exit 4
fi

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
aptq(){ DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 "$@"; }
aptq update -y >/dev/null 2>&1 || true
if ! command -v dkms >/dev/null 2>&1; then
  echo "[i] Installing DKMS build deps (dkms, build-essential, headers)..."
fi
if ! aptq install -y dkms build-essential xz-utils lz4 curl ca-certificates >/dev/null 2>&1; then
  aptq -f install -y >/dev/null 2>&1 || true
  aptq install -y dkms build-essential xz-utils lz4 curl ca-certificates >/dev/null 2>&1 || true
fi
if ! aptq install -y "linux-headers-$(uname -r)" >/dev/null 2>&1; then
  aptq -f install -y >/dev/null 2>&1 || true
  aptq install -y "linux-headers-$(uname -r)" >/dev/null 2>&1 || aptq install -y linux-headers-generic >/dev/null 2>&1 || true
fi

codename="${CODENAME:-}"

# If CODENAME wasn't passed, try to detect it on the remote side.
if [ -z "$codename" ] && [ -r /etc/os-release ]; then
  # shellcheck disable=SC1091
  . /etc/os-release 2>/dev/null || true
  codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
  if [ -z "$codename" ] && [ -n "${VERSION:-}" ]; then
    tmp="${VERSION#*(}"; tmp="${tmp%%)*}"
    if [ -n "$tmp" ] && [ "$tmp" != "$VERSION" ]; then
      codename="${tmp%% *}"
    fi
  fi
fi
if [ -z "$codename" ] && command -v lsb_release >/dev/null 2>&1; then
  codename="$(lsb_release -cs 2>/dev/null || true)"
fi

codename="$(printf "%s" "$codename" | tr 'A-Z' 'a-z')"
[ -n "$codename" ] || { echo "NO_CODENAME"; exit 5; }

tmp="/tmp/mimic-install.$$"
rm -rf "$tmp"; mkdir -p "$tmp"; chmod 755 "$tmp" 2>/dev/null || true

fb1="${MIMIC_FB_DEB:-}"
fb2="${MIMIC_FB_DKMS:-}"

latest_json="$(curl -fsSL --max-time 6 https://api.github.com/repos/hack3ric/mimic/releases/latest 2>/dev/null || true)"
urls="$(printf "%s" "$latest_json" | sed -n 's/.*"browser_download_url"[ ]*:[ ]*"\([^"]*\)".*/\1/p')"

deb1="$(printf "%s\n" "$urls" | grep -E "/${codename}_mimic_[^/]*_amd64\.deb$" | head -n1 || true)"
deb2="$(printf "%s\n" "$urls" | grep -E "/${codename}_mimic-dkms_[^/]*_amd64\.deb$" | head -n1 || true)"

if [ -z "$deb1" ] || [ -z "$deb2" ]; then
  if [ -n "$fb1" ] && [ -n "$fb2" ]; then
    echo "GITHUB_BLOCKED_OR_NO_ASSETS: using mirror"
    deb1="$fb1"
    deb2="$fb2"
  else
    echo "NO_ASSETS_FOR_${codename}"
    exit 6
  fi
fi

curl -fL --connect-timeout 4 --max-time 25 "$deb1" -o "$tmp/mimic.deb" >/dev/null
curl -fL --connect-timeout 4 --max-time 25 "$deb2" -o "$tmp/mimic-dkms.deb" >/dev/null
if ! dpkg-deb -I "$tmp/mimic.deb" >/dev/null 2>&1; then
  echo "INVALID_MIMIC_DEB"
  exit 8
fi
if ! dpkg-deb -I "$tmp/mimic-dkms.deb" >/dev/null 2>&1; then
  echo "INVALID_MIMIC_DKMS_DEB"
  exit 8
fi
chmod 644 "$tmp"/mimic*.deb 2>/dev/null || true
aptq install -y "$tmp/mimic.deb" "$tmp/mimic-dkms.deb" >/dev/null 2>&1 || { echo "APT_INSTALL_FAILED"; exit 7; }

command -v mimic >/dev/null 2>&1 || { echo "MIMIC_INSTALL_FAILED"; exit 7; }
REMOTE

  ok "Mimic installed (remote)."
}
