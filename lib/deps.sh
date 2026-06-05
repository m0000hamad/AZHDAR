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
  # 1st attempt normal install; if broken deps, run fix-broken then retry.
  export DEBIAN_FRONTEND=noninteractive
  azhdar_apt_get install -y "$@" >/dev/null 2>&1 && return 0
  azhdar_apt_get -f install -y >/dev/null 2>&1 || true
  azhdar_apt_get install -y "$@" >/dev/null 2>&1
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
      azhdar_apt_get update -y >/dev/null 2>&1 || true

      # Core deps
      apt_install_retry \
        wireguard-tools wireguard \
        iptables iproute2 iputils-ping \
        curl ca-certificates git \
        build-essential dkms libpcap-dev \
        netcat-openbsd tcpdump \
        openssh-client \
        python3 \
        xz-utils lz4 >/dev/null 2>&1 || true

      # Kernel headers needed for DKMS-based components (Mimic)
      apt_install_retry "linux-headers-$(uname -r)" >/dev/null 2>&1 || \
        apt_install_retry linux-headers-generic >/dev/null 2>&1 || true

      ensure_wireguard_local_apt >/dev/null 2>&1 || true
      ;;
    dnf)
      dnf install -y wireguard-tools iptables iproute iputils curl ca-certificates git make gcc dkms libpcap-devel nmap-ncat tcpdump openssh-clients python3 xz lz4 >/dev/null 2>&1 || true
      ;;
    yum)
      yum install -y wireguard-tools iptables iproute iputils curl ca-certificates git make gcc dkms libpcap-devel nmap-ncat tcpdump openssh-clients python3 xz lz4 >/dev/null 2>&1 || true
      ;;
    pacman)
      pacman -Sy --noconfirm wireguard-tools iptables iproute2 iputils curl ca-certificates git base-devel dkms libpcap netcat tcpdump openssh python xz lz4 >/dev/null 2>&1 || true
      ;;
    *)
      warn "Unknown package manager; please ensure installed: wireguard-tools, iptables, iproute2, ping, curl, git, make/gcc, python3."
      ;;
  esac

  for c in wg wg-quick ip iptables ping curl git nc systemctl python3 ssh; do
    have_cmd "$c" || die "Missing command: $c (dependency install failed)."
  done

  modprobe wireguard >/dev/null 2>&1 || true

  if ! have_cmd dkms; then
    warn "dkms is not installed; Mimic-DKMS install may fail."
  fi

  ok "Local dependencies OK."
}
