# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Package management / deps --------------------
detect_pkg_mgr(){
  if have_cmd apt-get; then echo "apt"; return; fi
  if have_cmd dnf; then echo "dnf"; return; fi
  if have_cmd yum; then echo "yum"; return; fi
  if have_cmd pacman; then echo "pacman"; return; fi
  echo "unknown"
}

apt_install_retry(){
  # usage: apt_install_retry pkg1 pkg2 ...
  # Fast path first: do not refresh package lists unless the install actually fails.
  # This keeps Smart Wizard from sitting 2-5 minutes on fresh Ubuntu images when
  # the required package metadata is already present.
  export DEBIAN_FRONTEND=noninteractive
  azhdar_apt_get install --no-install-recommends -y "$@" >/dev/null 2>&1 && return 0
  azhdar_apt_get -f install -y >/dev/null 2>&1 || true
  azhdar_apt_get install --no-install-recommends -y "$@" >/dev/null 2>&1 && return 0
  azhdar_apt_get update -y >/dev/null 2>&1 || true
  azhdar_apt_get install --no-install-recommends -y "$@" >/dev/null 2>&1
}

apt_missing_runtime_pkgs_local(){
  # Minimal runtime deps only. Mimic/DKMS build deps are installed later, only
  # when Mimic is actually needed, so this first dependency check stays light.
  local pkgs=()
  have_cmd wg && have_cmd wg-quick || pkgs+=(wireguard-tools)
  have_cmd iptables || pkgs+=(iptables)
  have_cmd ip || pkgs+=(iproute2)
  have_cmd ping || pkgs+=(iputils-ping)
  have_cmd curl || pkgs+=(curl ca-certificates)
  have_cmd nc || pkgs+=(netcat-openbsd)
  have_cmd ssh || pkgs+=(openssh-client)
  have_cmd python3 || pkgs+=(python3)
  have_cmd xz || pkgs+=(xz-utils)
  have_cmd lz4 || pkgs+=(lz4)
  printf '%s
' "${pkgs[@]}" | awk 'NF && !seen[$0]++'
}

ensure_wireguard_local_apt(){
  # For IR: if apt mirrors are slow/blocked, try direct wireguard-tools .deb (fast fallback).
  # On modern Ubuntu/Debian, the WireGuard kernel module is usually built-in; avoid forcing wireguard-dkms.
  if have_cmd wg && have_cmd wg-quick; then
    return 0
  fi
  if ! have_cmd apt-get; then
    return 0
  fi
  step "WireGuard missing; trying direct wireguard-tools .deb install (fast fallback)"
  local tmp="/tmp/wg-debs.$$"
  rm -rf "$tmp"; mkdir -p "$tmp"

  local primary_tools="https://archive.ubuntu.com/ubuntu/pool/main/w/wireguard/wireguard-tools_1.0.20210914-1ubuntu4_amd64.deb"
  fetch_with_fallback "$primary_tools" "$IR_MIRROR_WG_TOOLS_DEB" "$tmp/wireguard-tools.deb" || true

  if [[ -s "$tmp/wireguard-tools.deb" ]]; then
    export DEBIAN_FRONTEND=noninteractive
    azhdar_apt_get install -y "$tmp/wireguard-tools.deb" >/dev/null 2>&1 || true
  fi

  modprobe wireguard >/dev/null 2>&1 || true
}

install_deps_local(){
  step "Install/check local dependencies"
  local pm; pm="$(detect_pkg_mgr)"
  info "Package manager: ${pm}"
  case "$pm" in
    apt)
      export DEBIAN_FRONTEND=noninteractive
      local -a missing=()
      mapfile -t missing < <(apt_missing_runtime_pkgs_local)
      if ((${#missing[@]} == 0)); then
        info "Runtime deps already present; skipped apt install."
      else
        info "Installing missing runtime deps only: ${missing[*]}"
        # No unconditional apt update here. Try install first, update only if needed.
        apt_install_retry "${missing[@]}" >/dev/null 2>&1 || true
      fi
      ensure_wireguard_local_apt >/dev/null 2>&1 || true
      ;;
    dnf)
      dnf install -y wireguard-tools iptables iproute iputils curl ca-certificates nmap-ncat openssh-clients python3 xz lz4 >/dev/null 2>&1 || true
      ;;
    yum)
      yum install -y wireguard-tools iptables iproute iputils curl ca-certificates nmap-ncat openssh-clients python3 xz lz4 >/dev/null 2>&1 || true
      ;;
    pacman)
      pacman -Sy --noconfirm wireguard-tools iptables iproute2 iputils curl ca-certificates netcat openssh python xz lz4 >/dev/null 2>&1 || true
      ;;
    *)
      warn "Unknown package manager; please ensure installed: wireguard-tools, iptables, iproute2, ping, curl, python3, ssh."
      ;;
  esac

  for c in wg wg-quick ip iptables ping curl nc systemctl python3 ssh; do
    have_cmd "$c" || die "Missing command: $c (dependency install failed)."
  done

  modprobe wireguard >/dev/null 2>&1 || true

  ok "Local dependencies OK."
}

