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


# -------------------- m0000hamad mirror (fast fallback) --------------------
# If downloads from global sources (GitHub/Ubuntu) are filtered or slow on IR,
# we can fallback to Iranian mirrors. OUT keeps using original URLs.
IR_MIRROR_MIMIC_NOBLE_DEB="${ASSET_MIRROR_BASE}/noble_mimic_0.7.0-1_amd64.deb"
IR_MIRROR_MIMIC_NOBLE_DKMS_DEB="${ASSET_MIRROR_BASE}/noble_mimic-dkms_0.7.0-1_amd64.deb"
IR_MIRROR_MIMIC_BOOKWORM_DEB="${ASSET_MIRROR_BASE}/bookworm_mimic_0.7.0-1_amd64.deb"
IR_MIRROR_MIMIC_BOOKWORM_DKMS_DEB="${ASSET_MIRROR_BASE}/bookworm_mimic-dkms_0.7.0-1_amd64.deb"
IR_MIRROR_WG_TOOLS_DEB="${ASSET_MIRROR_BASE}/wireguard-tools_1.0.20210914-1ubuntu4_amd64.deb"
IR_MIRROR_WG_DKMS_DEB="${ASSET_MIRROR_BASE}/wireguard-dkms_1.0.20210606-1_all.deb"


# AZHDAR pins Mimic to the last known-good DKMS package by default.
# Newer upstream packages can break on some Ubuntu 24.04 kernels (BTF/ksym
# mismatch). Keep the default stable unless the operator explicitly overrides it.
AZHDAR_MIMIC_VERSION_PIN="${AZHDAR_MIMIC_VERSION_PIN:-0.7.0}"

mimic_static_mirror_asset_url(){
  # usage: mimic_static_mirror_asset_url <codename> <mimic|mimic-dkms>
  # Return the pinned, known-good mirror assets when available.
  local codename="$1" kind="$2"
  codename="${codename,,}"
  case "${codename}:${kind}" in
    noble:mimic) printf '%s\n' "$IR_MIRROR_MIMIC_NOBLE_DEB" ;;
    noble:mimic-dkms) printf '%s\n' "$IR_MIRROR_MIMIC_NOBLE_DKMS_DEB" ;;
    bookworm:mimic) printf '%s\n' "$IR_MIRROR_MIMIC_BOOKWORM_DEB" ;;
    bookworm:mimic-dkms) printf '%s\n' "$IR_MIRROR_MIMIC_BOOKWORM_DKMS_DEB" ;;
    *) return 1 ;;
  esac
}

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

curl_fetch_relaxed(){
  # Manual curl often succeeds even when the fast path aborts because of
  # speed limits or short max-time. Use this second pass before blaming the
  # mirror/GitHub URL.
  local url="$1" out="$2"
  curl -fL \
    --connect-timeout 10 \
    --max-time 180 \
    --retry 2 --retry-delay 2 --retry-max-time 80 \
    "$url" -o "$out" >/dev/null 2>&1
}

fetch_with_fallback(){
  # usage: fetch_with_fallback <primary_url> <fallback_url> <out>
  # Tries fast primary/fallback first, then relaxed primary/fallback. This
  # fixes false failures where manual curl works but Smart Wizard's strict
  # downloader timed out too early.
  local primary="$1" fallback="$2" out="$3"
  if [[ -n "$primary" ]] && curl_fetch_fast "$primary" "$out"; then
    return 0
  fi
  if [[ -n "$fallback" ]] && curl_fetch_fast "$fallback" "$out"; then
    return 0
  fi
  if [[ -n "$primary" ]] && curl_fetch_relaxed "$primary" "$out"; then
    return 0
  fi
  if [[ -n "$fallback" ]] && curl_fetch_relaxed "$fallback" "$out"; then
    return 0
  fi
  return 1
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

azhdar_url_path_escape_name(){
  # File Browser public-download paths need literal filename components. Encode
  # characters such as + from Debian versions (0.7.0+ds-2), otherwise some
  # proxies/servers may resolve the path incorrectly.
  local s="$1"
  s="${s//%/%25}"
  s="${s// /%20}"
  s="${s//+/%2B}"
  s="${s//#/%23}"
  s="${s//\?/%3F}"
  s="${s//&/%26}"
  printf '%s' "$s"
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

  # Prefer the pinned known-good version when it exists in the mirror;
  # otherwise fall back to the newest matching asset.
  for pat in "${patterns[@]}"; do
    name="$(printf '%s
' "$names" | grep -E "$pat" | grep -F "${AZHDAR_MIMIC_VERSION_PIN}" | sort -V | tail -n1 || true)"
    if [[ -n "$name" ]]; then
      printf '%s/%s
' "${ASSET_MIRROR_BASE%/}" "$(azhdar_url_path_escape_name "$name")"
      return 0
    fi
  done
  for pat in "${patterns[@]}"; do
    name="$(printf '%s
' "$names" | grep -E "$pat" | sort -V | tail -n1 || true)"
    if [[ -n "$name" ]]; then
      printf '%s/%s
' "${ASSET_MIRROR_BASE%/}" "$(azhdar_url_path_escape_name "$name")"
      return 0
    fi
  done
  return 1
}

azhdar_policy_rcd_begin_local(){
  # Prevent package maintainer scripts from restarting ssh/systemd services while
  # AZHDAR is only repairing apt or installing DKMS. This avoids failures like:
  #   Could not execute systemctl ... deb-systemd-invoke
  # which can leave openssh-server half-configured and poison later apt runs.
  local path="/usr/sbin/policy-rc.d" bak="/usr/sbin/policy-rc.d.azhdar-bak"
  mkdir -p /usr/sbin 2>/dev/null || true
  if [[ -e "$path" && ! -e "$bak" ]]; then
    cp -a "$path" "$bak" 2>/dev/null || true
  fi
  cat >"$path" <<'EOF' 2>/dev/null || true
#!/bin/sh
exit 101
EOF
  chmod +x "$path" 2>/dev/null || true
}

azhdar_policy_rcd_end_local(){
  local path="/usr/sbin/policy-rc.d" bak="/usr/sbin/policy-rc.d.azhdar-bak"
  if [[ -e "$bak" ]]; then
    mv -f "$bak" "$path" 2>/dev/null || true
  else
    rm -f "$path" 2>/dev/null || true
  fi
}

azhdar_apt_force_unlock_local(){
  # Aggressive apt/dpkg recovery for one-step installs.
  # The user expects Smart Wizard to continue quickly; unattended-upgrades or
  # stale apt/dpkg locks should not block Mimic build-deps forever.
  local locks=(
    /var/lib/dpkg/lock-frontend
    /var/lib/dpkg/lock
    /var/cache/apt/archives/lock
    /var/lib/apt/lists/lock
  )
  local pids="" pid name

  # Stop timers/services that commonly grab apt locks in the background.
  if have_cmd systemctl; then
    systemctl stop apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1 || true
    systemctl stop unattended-upgrades.service packagekit.service >/dev/null 2>&1 || true
  fi

  if have_cmd fuser; then
    pids="$(fuser "${locks[@]}" 2>/dev/null | tr ' ' '\n' | awk 'NF && !seen[$0]++' || true)"
  fi

  # Also catch processes that may not show up via fuser yet but are clearly
  # package-manager frontends/background jobs.
  if have_cmd pgrep; then
    for name in apt apt-get apt.systemd.daily aptitude dpkg unattended-upgrade unattended-upgrades packagekitd; do
      pids="${pids}
$(pgrep -x "$name" 2>/dev/null || true)"
    done
  fi

  pids="$(printf '%s\n' "$pids" | awk -v self="$$" 'NF && $1 != self && !seen[$0]++')"
  if [[ -n "$pids" ]]; then
    warn "Aggressive apt repair: killing stuck apt/dpkg/unattended-upgrades processes." >&2
    for pid in $pids; do kill "$pid" >/dev/null 2>&1 || true; done
    sleep 1
    for pid in $pids; do kill -9 "$pid" >/dev/null 2>&1 || true; done
    sleep 1
  fi

  rm -f "${locks[@]}" /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock 2>/dev/null || true
  mkdir -p /var/lib/dpkg /var/cache/apt/archives/partial /var/lib/apt/lists/partial 2>/dev/null || true
}

azhdar_apt_get(){
  # Keep apt/needrestart non-interactive and avoid scary raw apt notices in the UI.
  # While apt/dpkg is configuring packages, suppress service restarts so a broken
  # ssh.service restart does not leave openssh-server half-configured.
  local rc
  azhdar_apt_force_unlock_local >/dev/null 2>&1 || true
  azhdar_policy_rcd_begin_local >/dev/null 2>&1 || true
  DEBIAN_FRONTEND=noninteractive \
  NEEDRESTART_MODE=a \
  NEEDRESTART_SUSPEND=1 \
  APT_LISTCHANGES_FRONTEND=none \
  apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 "$@"
  rc=$?
  azhdar_policy_rcd_end_local >/dev/null 2>&1 || true
  return "$rc"
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

azhdar_apt_wait_locks_local(){
  # No long wait: force-clear apt/dpkg locks and continue.
  azhdar_apt_force_unlock_local || true
  return 0
}

azhdar_apt_self_heal_local(){
  # Automatic repair for broken/half-configured apt states.
  # Keep this lightweight: do not run apt update here. Package-list refresh is
  # done only by apt_install_retry when an actual install cannot resolve packages.
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
  azhdar_apt_force_unlock_local || true
  azhdar_apt_wait_locks_local || true
  dpkg --configure -a >/dev/null 2>&1 || true
  azhdar_apt_get -f install -y >/dev/null 2>&1 || true
  dpkg --configure -a >/dev/null 2>&1 || true
  azhdar_apt_get -f install -y >/dev/null 2>&1 || true
}

azhdar_kernel_header_candidates_local(){
  # Print header meta-packages most likely to match the running Ubuntu/Debian kernel.
  local kver flavor
  kver="$(uname -r)"
  flavor="${kver##*-}"
  printf '%s
' "linux-headers-${kver}"
  case "$kver" in
    *azure*) printf '%s
' linux-headers-azure ;;
    *aws*) printf '%s
' linux-headers-aws ;;
    *gcp*) printf '%s
' linux-headers-gcp ;;
    *oracle*) printf '%s
' linux-headers-oracle ;;
    *kvm*) printf '%s
' linux-headers-kvm ;;
    *lowlatency*) printf '%s
' linux-headers-lowlatency ;;
    *virtual*) printf '%s
' linux-headers-virtual ;;
  esac
  [[ -n "$flavor" && "$flavor" != "$kver" ]] && printf '%s
' "linux-headers-${flavor}"
  printf '%s
' linux-headers-generic
}

azhdar_install_mimic_build_deps_local(){
  # Self-healing build dependency installer for Mimic-DKMS.
  # Fixes broken dpkg states automatically instead of stopping with a manual
  # "apt --fix-broken install ; apt full-upgrade" instruction.
  export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
  local log="/tmp/azhdar-mimic-build-deps.$$.log"
  local -a common=(dkms build-essential xz-utils lz4 curl ca-certificates pahole dwarves bpftool)
  local hdr

  azhdar_apt_self_heal_local >/dev/null 2>&1 || true
  if apt_install_retry "${common[@]}" "linux-headers-$(uname -r)" >"$log" 2>&1; then
    return 0
  fi

  warn "Build deps/header install failed once; running apt self-heal and trying safe fallbacks."
  azhdar_apt_self_heal_local >/dev/null 2>&1 || true
  apt_install_retry "${common[@]}" >>"$log" 2>&1 || true

  for hdr in $(azhdar_kernel_header_candidates_local | awk 'NF && !seen[$0]++'); do
    if apt_install_retry "$hdr" >>"$log" 2>&1; then
      break
    fi
  done

  if have_cmd dkms && dpkg -s build-essential >/dev/null 2>&1; then
    if [[ ! -e "/lib/modules/$(uname -r)/build" ]]; then
      warn "Exact running-kernel headers are not available yet; Mimic-DKMS install will still try generic/provider headers. A reboot after kernel upgrade may be needed."
    fi
    return 0
  fi

  warn "apt is still inconsistent; avoiding full-upgrade during AZHDAR install and retrying only required build deps."
  azhdar_apt_self_heal_local >>"$log" 2>&1 || true
  apt_install_retry "${common[@]}" >>"$log" 2>&1 || true
  for hdr in $(azhdar_kernel_header_candidates_local | awk 'NF && !seen[$0]++'); do
    apt_install_retry "$hdr" >>"$log" 2>&1 && break || true
  done

  if have_cmd dkms && dpkg -s build-essential >/dev/null 2>&1; then
    return 0
  fi

  err "Cannot auto-repair apt/build deps for Mimic. Last apt output:"
  azhdar_print_apt_failure_log "$log"
  return 1
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

azhdar_mimic_local_healthy(){
  have_cmd mimic || return 1
  if have_cmd dpkg-query; then
    dpkg-query -W -f='${Status}' mimic 2>/dev/null | grep -qx 'install ok installed' || return 1
    dpkg-query -W -f='${Status}' mimic-dkms 2>/dev/null | grep -qx 'install ok installed' || return 1
  fi
  modinfo mimic >/dev/null 2>&1 || return 1
  return 0
}

azhdar_mimic_purge_broken_local(){
  warn "Existing Mimic install is broken or half-configured; purging it before reinstalling stable Mimic ${AZHDAR_MIMIC_VERSION_PIN}."
  systemctl stop 'mimic@*' >/dev/null 2>&1 || true
  pkill -TERM -f 'mimic' >/dev/null 2>&1 || true
  sleep 0.5
  pkill -KILL -f 'mimic' >/dev/null 2>&1 || true
  rm -f /run/mimic/*.lock /var/crash/mimic-dkms*.crash 2>/dev/null || true
  azhdar_apt_get purge -y mimic mimic-dkms >/dev/null 2>&1 || true
  dpkg --remove --force-remove-reinstreq mimic mimic-dkms >/dev/null 2>&1 || true
  rm -rf /var/lib/dkms/mimic 2>/dev/null || true
  azhdar_apt_self_heal_local >/dev/null 2>&1 || true
}

install_mimic_local(){
  step "Install Mimic on IR (local)"
  if have_cmd mimic; then
    azhdar_mimic_ensure_service_user_local || true
    if azhdar_mimic_local_healthy; then
      ok "Mimic already installed (local); package/module checked."
      return 0
    fi
    if declare -F azhdar_mimic_ensure_kernel_module_local >/dev/null 2>&1; then
      azhdar_mimic_ensure_kernel_module_local >/dev/null 2>&1 || true
    fi
    if azhdar_mimic_local_healthy; then
      ok "Mimic already installed (local); module repaired."
      return 0
    fi
    azhdar_mimic_purge_broken_local || true
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
  fb1="$(mimic_static_mirror_asset_url "$codename" mimic 2>/dev/null || mimic_mirror_asset_url "$codename" mimic 2>/dev/null || true)"
  fb2="$(mimic_static_mirror_asset_url "$codename" mimic-dkms 2>/dev/null || mimic_mirror_asset_url "$codename" mimic-dkms 2>/dev/null || true)"

local okcod
okcod="$(mimic_supported_codename "$codename" || true)"
if [[ "$okcod" == "no" ]]; then
  if [[ -n "$fb1" && -n "$fb2" ]]; then
    warn "Mimic GitHub assets not found for codename='${codename}', but an m0000hamad mirror is configured; continuing with mirror (best-effort)."
  else
    die "Mimic release assets not found for codename='${codename}'. Use Debian 12 (bookworm) / Ubuntu 24.04 (noble) or newer."
  fi
fi

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
# No unconditional apt update here; build-dep installer refreshes package lists only if needed.

# Ensure build deps for Mimic-DKMS (dkms + toolchain + matching headers)
if ! have_cmd dkms || ! dpkg -s build-essential >/dev/null 2>&1 || [[ ! -e "/lib/modules/$(uname -r)/build" ]]; then
  info "Installing/repairing DKMS build deps (dkms, build-essential, headers)..."
fi
azhdar_install_mimic_build_deps_local || die "Cannot install/repair Mimic build deps automatically. See ${LOG_FILE}."

apt_install_retry curl ca-certificates linux-tools-common "linux-tools-$(uname -r)" xz-utils lz4 >/dev/null 2>&1 || true


local tmp="/tmp/mimic-install.$$"
rm -rf "$tmp"; mkdir -p "$tmp"; chmod 755 "$tmp" 2>/dev/null || true

local u1 u2
# Prefer the pinned mirror package first. GitHub latest is only a fallback;
# using latest by default caused 0.7.1 DKMS/BTF failures on some noble kernels.
u1=""
u2=""
if [[ -z "$fb1" || -z "$fb2" ]]; then
  u1="$(github_latest_asset_url "hack3ric/mimic" ".*/${codename}_mimic_[^/]*_amd64\.deb$" 2>/dev/null || true)"
  u2="$(github_latest_asset_url "hack3ric/mimic" ".*/${codename}_mimic-dkms_[^/]*_amd64\.deb$" 2>/dev/null || true)"
fi

if [[ -n "$fb1" && -n "$fb2" ]]; then
  info "Using stable Mimic ${AZHDAR_MIMIC_VERSION_PIN} package from ${ASSET_MIRROR_NAME:-m0000hamad} mirror."
elif [[ -z "$u1" || -z "$u2" ]]; then
  die "Failed to locate Mimic .deb assets for codename=${codename}."
fi

  fetch_with_fallback "$fb1" "$u1" "$tmp/mimic.deb" || {
    err "Failed to download Mimic package (primary+fallback)."
    [[ -n "$fb1" ]] && echo "Mirror URL tried: $fb1"
    die "Mimic package download failed."
  }
  fetch_with_fallback "$fb2" "$u2" "$tmp/mimic-dkms.deb" || {
    err "Failed to download Mimic DKMS package (primary+fallback)."
    [[ -n "$fb2" ]] && echo "Mirror URL tried: $fb2"
    die "Mimic DKMS package download failed."
  }
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

  if ! azhdar_mimic_local_healthy; then
    err "Mimic install did not complete cleanly on local host."
    dpkg -l | grep -i mimic || true
    err "Check DKMS log: /var/lib/dkms/mimic/*/build/make.log"
    die "Mimic install failed. AZHDAR did not continue with a half-configured Mimic package."
  fi
  azhdar_mimic_ensure_service_user_local || true
  ok "Mimic installed (local)."
}

install_mimic_remote(){
  step "Install Mimic on OUT (remote)"
  if ssh_run "command -v mimic >/dev/null 2>&1 && dpkg-query -W -f='\${Status}' mimic 2>/dev/null | grep -qx 'install ok installed' && dpkg-query -W -f='\${Status}' mimic-dkms 2>/dev/null | grep -qx 'install ok installed' && modinfo mimic >/dev/null 2>&1 && echo yes || echo no" | tail -n1 | grep -qx yes; then
    azhdar_mimic_ensure_service_user_remote || true
    ok "Mimic already installed (remote); package/module checked."
    return 0
  fi
  if ssh_run "command -v mimic >/dev/null 2>&1 && echo broken || true" | tail -n1 | grep -qx broken; then
    warn "Remote Mimic install is broken or half-configured; purging it before reinstalling stable Mimic ${AZHDAR_MIMIC_VERSION_PIN}."
    ssh_run "systemctl stop 'mimic@*' >/dev/null 2>&1 || true; pkill -TERM -f mimic >/dev/null 2>&1 || true; sleep 0.5; pkill -KILL -f mimic >/dev/null 2>&1 || true; rm -f /run/mimic/*.lock /var/crash/mimic-dkms*.crash 2>/dev/null || true; DEBIAN_FRONTEND=noninteractive apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 purge -y mimic mimic-dkms >/dev/null 2>&1 || true; dpkg --remove --force-remove-reinstreq mimic mimic-dkms >/dev/null 2>&1 || true; rm -rf /var/lib/dkms/mimic 2>/dev/null || true" >/dev/null 2>&1 || true
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
  fb1="$(mimic_static_mirror_asset_url "$codename" mimic 2>/dev/null || mimic_mirror_asset_url "$codename" mimic 2>/dev/null || true)"
  fb2="$(mimic_static_mirror_asset_url "$codename" mimic-dkms 2>/dev/null || mimic_mirror_asset_url "$codename" mimic-dkms 2>/dev/null || true)"

local okcod
okcod="$(mimic_supported_codename "$codename" || true)"
if [[ "$okcod" == "no" ]]; then
  if [[ -n "$fb1" && -n "$fb2" ]]; then
    warn "Mimic GitHub assets not found for remote codename='${codename}', but ${ASSET_MIRROR_NAME:-m0000hamad} mirror is configured; continuing with mirror (best-effort)."
  else
    die "Mimic release assets not found for remote codename='${codename}'. Use Debian 12 (bookworm) / Ubuntu 24.04 (noble) or newer."
  fi
fi

  ssh_run_stdin_env_root "CODENAME=${codename}" "MIMIC_FB_DEB=${fb1}" "MIMIC_FB_DKMS=${fb2}" "ASSET_MIRROR_NAME=${ASSET_MIRROR_NAME:-m0000hamad}" <<'REMOTE'
set -euo pipefail

if ! command -v apt-get >/dev/null 2>&1; then
  echo "NO_APT"
  exit 4
fi

export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
apt_force_unlock(){
  locks="/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock /var/lib/apt/lists/lock"
  if command -v systemctl >/dev/null 2>&1; then
    systemctl stop apt-daily.timer apt-daily-upgrade.timer apt-daily.service apt-daily-upgrade.service >/dev/null 2>&1 || true
    systemctl stop unattended-upgrades.service packagekit.service >/dev/null 2>&1 || true
  fi
  pids=""
  if command -v fuser >/dev/null 2>&1; then
    pids="$(fuser $locks 2>/dev/null | tr ' ' '\n' | awk 'NF && !seen[$0]++' || true)"
  fi
  if command -v pgrep >/dev/null 2>&1; then
    for name in apt apt-get apt.systemd.daily aptitude dpkg unattended-upgrade unattended-upgrades packagekitd; do
      pids="${pids}
$(pgrep -x "$name" 2>/dev/null || true)"
    done
  fi
  pids="$(printf '%s\n' "$pids" | awk -v self="$$" 'NF && $1 != self && !seen[$0]++')"
  if [ -n "$pids" ]; then
    echo "[i] Aggressive apt repair: killing stuck apt/dpkg/unattended-upgrades processes..." >&2
    for pid in $pids; do kill "$pid" >/dev/null 2>&1 || true; done
    sleep 1
    for pid in $pids; do kill -9 "$pid" >/dev/null 2>&1 || true; done
    sleep 1
  fi
  rm -f $locks >/dev/null 2>&1 || true
  mkdir -p /var/lib/dpkg /var/cache/apt/archives/partial /var/lib/apt/lists/partial >/dev/null 2>&1 || true
}
policy_begin(){
  path="/usr/sbin/policy-rc.d"; bak="/usr/sbin/policy-rc.d.azhdar-bak"
  mkdir -p /usr/sbin 2>/dev/null || true
  if [ -e "$path" ] && [ ! -e "$bak" ]; then cp -a "$path" "$bak" 2>/dev/null || true; fi
  cat >"$path" <<'EOF' 2>/dev/null || true
#!/bin/sh
exit 101
EOF
  chmod +x "$path" 2>/dev/null || true
}
policy_end(){
  path="/usr/sbin/policy-rc.d"; bak="/usr/sbin/policy-rc.d.azhdar-bak"
  if [ -e "$bak" ]; then mv -f "$bak" "$path" 2>/dev/null || true; else rm -f "$path" 2>/dev/null || true; fi
}
aptq(){ apt_force_unlock >/dev/null 2>&1 || true; policy_begin >/dev/null 2>&1 || true; DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none apt-get -o Dpkg::Use-Pty=0 -o APT::Color=0 "$@"; rc=$?; policy_end >/dev/null 2>&1 || true; return "$rc"; }
apt_wait_locks(){ apt_force_unlock || true; return 0; }
apt_repair(){
  apt_force_unlock || true
  apt_wait_locks || true
  dpkg --configure -a >/dev/null 2>&1 || true
  aptq -f install -y >/dev/null 2>&1 || true
  dpkg --configure -a >/dev/null 2>&1 || true
  aptq -f install -y >/dev/null 2>&1 || true
}
header_candidates(){
  kver="$(uname -r)"; flavor="${kver##*-}"
  printf '%s
' "linux-headers-${kver}"
  case "$kver" in
    *azure*) printf '%s
' linux-headers-azure ;;
    *aws*) printf '%s
' linux-headers-aws ;;
    *gcp*) printf '%s
' linux-headers-gcp ;;
    *oracle*) printf '%s
' linux-headers-oracle ;;
    *kvm*) printf '%s
' linux-headers-kvm ;;
    *lowlatency*) printf '%s
' linux-headers-lowlatency ;;
    *virtual*) printf '%s
' linux-headers-virtual ;;
  esac
  [ -n "$flavor" ] && [ "$flavor" != "$kver" ] && printf '%s
' "linux-headers-${flavor}"
  printf '%s
' linux-headers-generic
}
install_build_deps(){
  apt_repair || true
  if aptq install --no-install-recommends -y dkms build-essential xz-utils lz4 curl ca-certificates pahole dwarves bpftool "linux-headers-$(uname -r)" >/dev/null 2>&1; then
    return 0
  fi
  echo "[i] Remote apt build deps failed once; refreshing package list once and trying header fallback..."
  aptq update -y >/dev/null 2>&1 || true
  apt_repair || true
  aptq install --no-install-recommends -y dkms build-essential xz-utils lz4 curl ca-certificates pahole dwarves bpftool >/dev/null 2>&1 || true
  for hdr in $(header_candidates | awk 'NF && !seen[$0]++'); do
    aptq install --no-install-recommends -y "$hdr" >/dev/null 2>&1 && break || true
  done
  if command -v dkms >/dev/null 2>&1 && dpkg -s build-essential >/dev/null 2>&1; then
    return 0
  fi
  echo "[i] Remote apt is still inconsistent; avoiding full-upgrade during AZHDAR install and retrying only required build deps..."
  apt_repair || true
  aptq install --no-install-recommends -y dkms build-essential xz-utils lz4 curl ca-certificates pahole dwarves bpftool >/dev/null 2>&1 || true
  for hdr in $(header_candidates | awk 'NF && !seen[$0]++'); do
    aptq install --no-install-recommends -y "$hdr" >/dev/null 2>&1 && break || true
  done
  command -v dkms >/dev/null 2>&1 && dpkg -s build-essential >/dev/null 2>&1
}
# No unconditional remote apt update; install_build_deps refreshes only after a real failure.
if ! command -v dkms >/dev/null 2>&1 || ! dpkg -s build-essential >/dev/null 2>&1; then
  echo "[i] Installing/repairing DKMS build deps (dkms, build-essential, headers)..."
fi
install_build_deps || { echo "BUILD_DEPS_FAILED"; exit 13; }

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

primary1=""
primary2=""
if [ -z "$fb1" ] || [ -z "$fb2" ]; then
  latest_json="$(curl -fsSL --connect-timeout 6 --max-time 20 https://api.github.com/repos/hack3ric/mimic/releases/latest 2>/dev/null || true)"
  urls="$(printf "%s" "$latest_json" | sed -n 's/.*"browser_download_url"[ ]*:[ ]*"\([^"]*\)".*/\1/p')"
  primary1="$(printf "%s\n" "$urls" | grep -E "/${codename}_mimic_[^/]*_amd64\.deb$" | head -n1 || true)"
  primary2="$(printf "%s\n" "$urls" | grep -E "/${codename}_mimic-dkms_[^/]*_amd64\.deb$" | head -n1 || true)"
fi

if [ -n "$fb1" ] && [ -n "$fb2" ]; then
  echo "USING_STABLE_MIRROR: ${ASSET_MIRROR_NAME:-m0000hamad}"
elif [ -z "$primary1" ] || [ -z "$primary2" ]; then
  echo "NO_ASSETS_FOR_${codename}"
  exit 6
fi

fetch_remote_with_fallback(){
  primary="$1"
  fallback="$2"
  out="$3"
  if [ -n "$primary" ] && curl -fL --connect-timeout 4 --max-time 25 --retry 1 --retry-delay 1 --retry-max-time 10 --speed-time 8 --speed-limit 25000 "$primary" -o "$out" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "$fallback" ] && curl -fL --connect-timeout 4 --max-time 25 --retry 1 --retry-delay 1 --retry-max-time 10 --speed-time 8 --speed-limit 25000 "$fallback" -o "$out" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "$primary" ] && curl -fL --connect-timeout 10 --max-time 180 --retry 2 --retry-delay 2 --retry-max-time 80 "$primary" -o "$out" >/dev/null 2>&1; then
    return 0
  fi
  if [ -n "$fallback" ] && curl -fL --connect-timeout 10 --max-time 180 --retry 2 --retry-delay 2 --retry-max-time 80 "$fallback" -o "$out" >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

fetch_remote_with_fallback "$fb1" "$primary1" "$tmp/mimic.deb" || { echo "DOWNLOAD_MIMIC_FAILED: primary=${primary1:-none} fallback=${fb1:-none}"; exit 8; }
fetch_remote_with_fallback "$fb2" "$primary2" "$tmp/mimic-dkms.deb" || { echo "DOWNLOAD_MIMIC_DKMS_FAILED: primary=${primary2:-none} fallback=${fb2:-none}"; exit 8; }
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

command -v mimic >/dev/null 2>&1 && dpkg-query -W -f='${Status}' mimic 2>/dev/null | grep -qx 'install ok installed' && dpkg-query -W -f='${Status}' mimic-dkms 2>/dev/null | grep -qx 'install ok installed' && modinfo mimic >/dev/null 2>&1 || { echo "MIMIC_INSTALL_FAILED_OR_DKMS_MODULE_MISSING"; exit 7; }
REMOTE

  azhdar_mimic_ensure_service_user_remote || true
  ok "Mimic installed (remote)."
}
