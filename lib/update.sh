# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Self update (auto-discover) --------------------

semver_normalize(){
  # Converts "v2.0.0" -> "2.0.0"; missing parts -> 0
  local v="${1:-}"
  v="${v#v}"
  IFS='.' read -r a b c <<<"$v"
  a="${a:-0}"; b="${b:-0}"; c="${c:-0}"
  echo "${a}.${b}.${c}"
}

semver_cmp(){
  # Usage: semver_cmp A B ; echo $?  (0: equal, 1: A>B, 2: A<B)
  local A; A="$(semver_normalize "${1:-0}")"
  local B; B="$(semver_normalize "${2:-0}")"
  local a1 a2 a3 b1 b2 b3
  IFS='.' read -r a1 a2 a3 <<<"$A"
  IFS='.' read -r b1 b2 b3 <<<"$B"
  for x in 1 2 3; do
    local av bv
    av="$(eval echo \${a${x}})"
    bv="$(eval echo \${b${x}})"
    [[ "$av" =~ ^[0-9]+$ ]] || av=0
    [[ "$bv" =~ ^[0-9]+$ ]] || bv=0
    if (( av > bv )); then return 1; fi
    if (( av < bv )); then return 2; fi
  done
  return 0
}

_update_fetch(){
  # Best-effort fetch with curl/wget, including common TLS quirks.
  local url="$1"
  local out="$2"

  if have_cmd curl; then
    # strict
    if curl -fsSL --connect-timeout 10 --max-time 30 "$url" -o "$out"; then
      return 0
    fi
    # if https, retry insecure and http fallback
    if [[ "$url" == https://* ]]; then
      if curl -kfsSL --connect-timeout 10 --max-time 30 "$url" -o "$out"; then
        return 0
      fi
      local http_url="http://${url#https://}"
      if curl -fsSL --connect-timeout 10 --max-time 30 "$http_url" -o "$out"; then
        return 0
      fi
    fi
    return 1
  fi

  if have_cmd wget; then
    if wget -qO "$out" "$url"; then
      return 0
    fi
    if [[ "$url" == https://* ]]; then
      if wget --no-check-certificate -qO "$out" "$url"; then
        return 0
      fi
      local http_url="http://${url#https://}"
      if wget -qO "$out" "$http_url"; then
        return 0
      fi
    fi
    return 1
  fi

  die "Need curl or wget for updates."
}

_update_pick_latest_zip(){
  # Input: list of zip names on stdin. Output: latest zip name.
  local latest=""
  local z

  # Prefer GNU sort -V if available.
  if have_cmd sort && sort -V </dev/null >/dev/null 2>&1; then
    latest="$(cat | sort -u | sort -V | tail -n1)"
    echo "$latest"
    return 0
  fi

  # Fallback: manual semver comparison.
  while read -r z; do
    [[ -n "$z" ]] || continue
    if [[ -z "$latest" ]]; then
      latest="$z"
      continue
    fi
    local zv lv
    zv="${z#azhdar-}"; zv="${zv%.zip}"
    lv="${latest#azhdar-}"; lv="${lv%.zip}"
    semver_cmp "$zv" "$lv"
    case $? in
      1) latest="$z" ;; # z newer
      *) : ;;
    esac
  done
  echo "$latest"
}

azhdar_update_check(){
  # Sets: UPDATE_LATEST_VERSION UPDATE_PACKAGE_URL UPDATE_PACKAGE_ZIP
  local base="${UPDATE_BASE_URL:-}"
  if [[ -z "$base" ]]; then
    base="https://dl.digitsell.shop/share/gZ1XGygF"
  fi


  # Ensure trailing slash for directory listing
  local list_url="$base"
  [[ "$list_url" == */ ]] || list_url+="/"

  local tmp; tmp="$(mktemp -t azhdar-listing.XXXXXX.html)"
  if ! _update_fetch "$list_url" "$tmp"; then
    rm -f "$tmp" 2>/dev/null || true
    return 4
  fi

  local zips
  zips="$(grep -oE 'azhdar-[0-9]+\.[0-9]+\.[0-9]+\.zip' "$tmp" | sort -u || true)"
  rm -f "$tmp" 2>/dev/null || true

  [[ -n "$zips" ]] || return 5

  local latest_zip latest_ver
  latest_zip="$(printf '%s\n' "$zips" | _update_pick_latest_zip)"
  [[ -n "$latest_zip" ]] || return 5

  latest_ver="${latest_zip#azhdar-}"
  latest_ver="${latest_ver%.zip}"

  UPDATE_LATEST_VERSION="$(semver_normalize "$latest_ver")"
  UPDATE_PACKAGE_ZIP="$latest_zip"
  UPDATE_PACKAGE_URL="${base%/}/${latest_zip}"

  semver_cmp "$UPDATE_LATEST_VERSION" "$SCRIPT_VERSION"
  case $? in
    1) return 0 ;; # update available
    0) return 1 ;; # already latest
    2) return 2 ;; # local newer (dev)
  esac
}

azhdar_update_apply(){
  need_root

  local pkg_url="${UPDATE_PACKAGE_URL:-}"
  [[ -n "$pkg_url" ]] || die "No update package URL."

  local tmp_zip; tmp_zip="$(mktemp -t azhdar-update.XXXXXX.zip)"
  step "Downloading update package"
  _update_fetch "$pkg_url" "$tmp_zip" || die "Failed to download update package."

  step "Unpacking"
  local tmp_dir; tmp_dir="$(mktemp -d -t azhdar-update.XXXXXX)"
  if have_cmd unzip; then
    unzip -oq "$tmp_zip" -d "$tmp_dir" || die "Unzip failed."
  else
    rm -f "$tmp_zip" 2>/dev/null || true
    rm -rf "$tmp_dir" 2>/dev/null || true
    die "Need unzip to apply updates."
  fi

  # Find install script inside extracted package
  local inst
  inst="$(find "$tmp_dir" -maxdepth 3 -type f -name install.sh | head -n1 2>/dev/null || true)"
  [[ -n "$inst" ]] || die "install.sh not found in update package."

  step "Applying update"
  bash "$inst" --noninteractive || die "Update install failed."

  rm -f "$tmp_zip" 2>/dev/null || true
  rm -rf "$tmp_dir" 2>/dev/null || true

  ok "Update applied."

  # Relaunch newest binary (if available)
  if [[ -x "/usr/local/bin/azhdar" ]]; then
    echo
    warn "Relaunching AZHDAR..."
    exec /usr/local/bin/azhdar
  fi
}

azhdar_update_menu(){
  banner
  echo -e "${BOLD}${WHT}AZHDAR Update${RST}"
  hr
  echo -e "${DIM}Source:${RST} ${UPDATE_BASE_URL:-https://dl.digitsell.shop/share/gZ1XGygF}"
  echo -e "${DIM}Current version:${RST} ${SCRIPT_VERSION}"
  hr

  local c
  echo " 1) Check for update"
  echo " 0) Back"
  hr
  read -rp "Select: " c || true
  case "${c:-}" in
    1)
      if azhdar_update_check; then
        echo
        ok "New version available: ${UPDATE_LATEST_VERSION}"
        echo -e "${DIM}Package:${RST} ${UPDATE_PACKAGE_URL}"
        echo
        if [[ "$(prompt_yesno "Apply update now?" "Y")" == "Y" ]]; then
          azhdar_update_apply
        else
          warn "Cancelled."
        fi
      else
        case $? in
          1) ok "You are up to date." ;;
          2) ok "Local version is newer than remote (dev build)." ;;
          3) warn "No update source URL set." ;;
          4) err "Failed to fetch update source (directory listing)." ;;
          5) err "No matching azhdar-*.zip found at source." ;;
          *) err "Update check failed." ;;
        esac
      fi
      pause
      ;;
    0) return 0 ;;
    *) warn "Invalid."; pause ;;
  esac
}
