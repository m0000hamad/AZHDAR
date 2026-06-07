# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Mimic configs (local/remote) --------------------

# ---- Robust Mimic interface/service helpers ----

# Repair/normalize the systemd service account used by mimic@.service.
# A previously installed Mimic package can leave the unit with User=mimic while
# the system account is missing. systemd then fails with status=217/USER.
azhdar_mimic_unit_text_local(){
  if command -v systemctl >/dev/null 2>&1; then
    systemctl cat mimic@.service 2>/dev/null && return 0
  fi
  cat /etc/systemd/system/mimic@.service /usr/lib/systemd/system/mimic@.service /lib/systemd/system/mimic@.service 2>/dev/null || true
}

azhdar_mimic_extract_unit_value(){
  # usage: azhdar_mimic_extract_unit_value User|Group
  local key="$1"
  awk -F= -v k="$key" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      v=$2
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (v != "") last=v
    }
    END { if (last != "") print last }
  '
}

azhdar_mimic_safe_account_name(){
  local v="${1:-}"
  [[ -n "$v" ]] || return 1
  [[ "$v" != "root" ]] || return 1
  [[ "$v" != *'%'* && "$v" != *'$'* && "$v" != *'/'* && "$v" != *':'* ]] || return 1
  [[ "$v" =~ ^[A-Za-z_][A-Za-z0-9_.-]*\$?$ ]] || return 1
  return 0
}

azhdar_mimic_ensure_service_user_local(){
  command -v systemctl >/dev/null 2>&1 || return 0
  local unit user group primary shell
  unit="$(azhdar_mimic_unit_text_local 2>/dev/null || true)"
  [[ -n "$unit" ]] || return 0
  user="$(printf '%s\n' "$unit" | azhdar_mimic_extract_unit_value User | tail -n1 || true)"
  group="$(printf '%s\n' "$unit" | azhdar_mimic_extract_unit_value Group | tail -n1 || true)"
  azhdar_mimic_safe_account_name "$user" || return 0
  if [[ -n "$group" ]]; then
    azhdar_mimic_safe_account_name "$group" || group=""
  fi
  primary="${group:-$user}"
  if ! getent group "$primary" >/dev/null 2>&1; then
    groupadd --system "$primary" >/dev/null 2>&1 || true
  fi
  if ! getent passwd "$user" >/dev/null 2>&1; then
    shell="/usr/sbin/nologin"
    [[ -x "$shell" ]] || shell="/bin/false"
    useradd --system --no-create-home --home-dir /var/lib/mimic --shell "$shell" --gid "$primary" "$user" >/dev/null 2>&1 || \
      useradd -r -M -d /var/lib/mimic -s "$shell" -g "$primary" "$user" >/dev/null 2>&1 || true
  fi
  mkdir -p /etc/mimic /var/lib/mimic /run/mimic 2>/dev/null || true
  chown "$user:$primary" /var/lib/mimic /run/mimic 2>/dev/null || true
  chmod 755 /etc/mimic /var/lib/mimic /run/mimic 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
}

azhdar_mimic_ensure_service_user_remote(){
  ssh_run_stdin_env_root_best_effort <<'REMOTE' >/dev/null 2>&1 || true
set +e
unit=""
if command -v systemctl >/dev/null 2>&1; then
  unit="$(systemctl cat mimic@.service 2>/dev/null || true)"
fi
if [ -z "$unit" ]; then
  unit="$(cat /etc/systemd/system/mimic@.service /usr/lib/systemd/system/mimic@.service /lib/systemd/system/mimic@.service 2>/dev/null || true)"
fi
[ -n "$unit" ] || exit 0
extract_unit_value(){
  key="$1"
  printf '%s\n' "$unit" | awk -F= -v k="$key" '
    $0 ~ "^[[:space:]]*" k "[[:space:]]*=" {
      v=$2
      sub(/^[[:space:]]+/, "", v)
      sub(/[[:space:]]+$/, "", v)
      if (v != "") last=v
    }
    END { if (last != "") print last }
  ' | tail -n1
}
safe_account_name(){
  v="$1"
  [ -n "$v" ] || return 1
  [ "$v" != "root" ] || return 1
  case "$v" in *%*|*\$*|*/*|*:*) return 1;; esac
  printf '%s' "$v" | grep -Eq '^[A-Za-z_][A-Za-z0-9_.-]*\$?$'
}
user="$(extract_unit_value User)"
group="$(extract_unit_value Group)"
safe_account_name "$user" || exit 0
if [ -n "$group" ] && ! safe_account_name "$group"; then group=""; fi
primary="${group:-$user}"
getent group "$primary" >/dev/null 2>&1 || groupadd --system "$primary" >/dev/null 2>&1 || true
if ! getent passwd "$user" >/dev/null 2>&1; then
  shell=/usr/sbin/nologin
  [ -x "$shell" ] || shell=/bin/false
  useradd --system --no-create-home --home-dir /var/lib/mimic --shell "$shell" --gid "$primary" "$user" >/dev/null 2>&1 || \
    useradd -r -M -d /var/lib/mimic -s "$shell" -g "$primary" "$user" >/dev/null 2>&1 || true
fi
mkdir -p /etc/mimic /var/lib/mimic /run/mimic 2>/dev/null || true
chown "$user:$primary" /var/lib/mimic /run/mimic 2>/dev/null || true
chmod 755 /etc/mimic /var/lib/mimic /run/mimic 2>/dev/null || true
systemctl daemon-reload >/dev/null 2>&1 || true
exit 0
REMOTE

}

# Some Mimic .deb/package states can leave the binary installed while the
# systemd template unit is missing. In that case systemctl reports
# mimic@<if> as "not-found" and the WireGuard tunnel never comes up even
# though Mimic package/module checks passed. Create a minimal root-run unit as
# a safe fallback; only do this when the package did not provide mimic@.service.
azhdar_mimic_ensure_unit_local(){
  command -v systemctl >/dev/null 2>&1 || return 0
  if systemctl cat mimic@.service >/dev/null 2>&1 || \
     [[ -f /etc/systemd/system/mimic@.service || -f /usr/lib/systemd/system/mimic@.service || -f /lib/systemd/system/mimic@.service ]]; then
    return 0
  fi
  local exe=""
  exe="$(command -v mimic 2>/dev/null || true)"
  [[ -n "$exe" ]] || exe="/usr/sbin/mimic"
  [[ -x "$exe" ]] || return 1
  mkdir -p /etc/systemd/system /etc/mimic /run/mimic /var/lib/mimic 2>/dev/null || true
  cat >/etc/systemd/system/mimic@.service <<EOF
[Unit]
Description=Start Mimic on %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${exe} run %i -F /etc/mimic/%i.conf
Restart=on-failure
RestartSec=1
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 /etc/systemd/system/mimic@.service 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
}

azhdar_mimic_ensure_unit_remote(){
  ssh_run_stdin_env_root_best_effort <<'REMOTE' >/dev/null 2>&1 || true
set +e
if ! command -v systemctl >/dev/null 2>&1; then exit 0; fi
if systemctl cat mimic@.service >/dev/null 2>&1 || \
   [ -f /etc/systemd/system/mimic@.service ] || [ -f /usr/lib/systemd/system/mimic@.service ] || [ -f /lib/systemd/system/mimic@.service ]; then
  exit 0
fi
exe="$(command -v mimic 2>/dev/null || true)"
[ -n "$exe" ] || exe="/usr/sbin/mimic"
[ -x "$exe" ] || exit 1
mkdir -p /etc/systemd/system /etc/mimic /run/mimic /var/lib/mimic 2>/dev/null || true
cat >/etc/systemd/system/mimic@.service <<EOF
[Unit]
Description=Start Mimic on %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${exe} run %i -F /etc/mimic/%i.conf
Restart=on-failure
RestartSec=1
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
chmod 644 /etc/systemd/system/mimic@.service 2>/dev/null || true
systemctl daemon-reload >/dev/null 2>&1 || true
exit 0
REMOTE
}

azhdar_cmd_timeout_local(){
  # usage: azhdar_cmd_timeout_local <seconds> <command> [args...]
  # Prevent Smart Wizard from appearing frozen during DKMS/systemd repairs.
  local secs="${1:-60}"; shift || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground --kill-after=5s "${secs}s" "$@"
  else
    "$@"
  fi
}

azhdar_systemctl_quick_local(){
  # systemctl can block for the unit timeout while mimic auto-restarts. Bound it.
  local secs="${1:-25}"; shift || return 1
  azhdar_cmd_timeout_local "$secs" systemctl "$@"
}

azhdar_mimic_fast_module_ok_local(){
  modprobe mimic >/dev/null 2>&1 && azhdar_mimic_kallsyms_has_hook_local
}

azhdar_mimic_clear_runtime_local(){
  # Remove stale Mimic runtime locks after a failed/crashed start.
  # Mimic may leave /run/mimic/*.lock behind; next start then exits with
  # status=17 and "no version found in lock file" / "failed to lock".
  local wan="${1:-}"
  if command -v systemctl >/dev/null 2>&1 && [[ -n "$wan" ]]; then
    systemctl stop "mimic@${wan}" >/dev/null 2>&1 || true
    systemctl reset-failed "mimic@${wan}" >/dev/null 2>&1 || true
  fi
  if command -v pkill >/dev/null 2>&1 && [[ -n "$wan" ]]; then
    pkill -TERM -f "(^|[ /])mimic([ ]+run)?[ ]+${wan}([ ]|$)" >/dev/null 2>&1 || true
    sleep 0.3
    pkill -KILL -f "(^|[ /])mimic([ ]+run)?[ ]+${wan}([ ]|$)" >/dev/null 2>&1 || true
  fi
  mkdir -p /run/mimic /var/lib/mimic 2>/dev/null || true
  # Safe in AZHDAR because one mimic@<wan> unit owns the combined config for all profiles on this host.
  find /run/mimic -maxdepth 1 -type f -name '*.lock' -delete 2>/dev/null || true
  find /run/mimic -maxdepth 1 -type s -delete 2>/dev/null || true
}

azhdar_mimic_kallsyms_has_hook_local(){
  # The Mimic userspace BPF loader needs the ksym exported by the DKMS module.
  # If the module loads but the symbol/BTF is missing, mimic exits with:
  #   extern (func ksym) 'mimic_change_csum_offset': not found in kernel or module BTFs
  grep -qw 'mimic_change_csum_offset' /proc/kallsyms 2>/dev/null
}

azhdar_mimic_install_btf_tools_local(){
  # pahole/dwarves are required on many Ubuntu/Debian kernels for DKMS module BTF.
  # Without module BTF, libbpf cannot resolve Mimic's ksym even when modprobe succeeds.
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
    if declare -F azhdar_apt_self_heal_local >/dev/null 2>&1; then
      azhdar_apt_self_heal_local >/dev/null 2>&1 || true
    fi
    if declare -F azhdar_apt_get >/dev/null 2>&1; then
      azhdar_cmd_timeout_local 45 azhdar_apt_get update -y >/dev/null 2>&1 || true
      azhdar_cmd_timeout_local 90 azhdar_apt_get install -y pahole dwarves bpftool linux-tools-common "linux-tools-$(uname -r)" linux-tools-generic >/dev/null 2>&1 ||         azhdar_cmd_timeout_local 60 azhdar_apt_get install -y pahole dwarves bpftool >/dev/null 2>&1 ||         azhdar_cmd_timeout_local 45 azhdar_apt_get install -y pahole dwarves >/dev/null 2>&1 || true
    else
      azhdar_cmd_timeout_local 45 apt-get update -y >/dev/null 2>&1 || true
      azhdar_cmd_timeout_local 90 apt-get install -y pahole dwarves bpftool linux-tools-common "linux-tools-$(uname -r)" linux-tools-generic >/dev/null 2>&1 ||         azhdar_cmd_timeout_local 60 apt-get install -y pahole dwarves bpftool >/dev/null 2>&1 ||         azhdar_cmd_timeout_local 45 apt-get install -y pahole dwarves >/dev/null 2>&1 || true
    fi
  fi
}

azhdar_mimic_dkms_versions_local(){
  local v
  if [[ -d /var/lib/dkms/mimic ]]; then
    find /var/lib/dkms/mimic -mindepth 1 -maxdepth 1 -type d -printf '%f
' 2>/dev/null || true
  fi
  dkms status 2>/dev/null | awk -F'[,/]' '/^mimic\//{print $2}' | awk 'NF && !seen[$0]++' || true
}

azhdar_mimic_rebuild_module_local(){
  local kver="$(uname -r)" ver seen=""
  command -v dkms >/dev/null 2>&1 || return 1
  azhdar_mimic_install_btf_tools_local || true
  azhdar_cmd_timeout_local 15 modprobe -r mimic >/dev/null 2>&1 || true
  while read -r ver; do
    [[ -n "$ver" ]] || continue
    case " $seen " in *" $ver "*) continue;; esac
    seen+=" $ver"
    azhdar_cmd_timeout_local 45 dkms remove -m mimic -v "$ver" -k "$kver" --force >/dev/null 2>&1 || true
    azhdar_cmd_timeout_local 120 dkms build  -m mimic -v "$ver" -k "$kver" >/dev/null 2>&1 || true
    azhdar_cmd_timeout_local 60 dkms install -m mimic -v "$ver" -k "$kver" --force >/dev/null 2>&1 || true
  done < <(azhdar_mimic_dkms_versions_local)
  # If DKMS database was stale/empty, reinstalling the package repopulates /var/lib/dkms/mimic.
  if [[ -z "${seen// /}" ]] && dpkg -s mimic-dkms >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    if declare -F azhdar_apt_get >/dev/null 2>&1; then
      azhdar_cmd_timeout_local 120 azhdar_apt_get install --reinstall -y mimic-dkms >/dev/null 2>&1 || true
    else
      DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y mimic-dkms >/dev/null 2>&1 || true
    fi
  fi
  azhdar_cmd_timeout_local 90 dkms autoinstall -k "$kver" >/dev/null 2>&1 || azhdar_cmd_timeout_local 90 dkms autoinstall >/dev/null 2>&1 || true
  azhdar_cmd_timeout_local 30 depmod -a >/dev/null 2>&1 || true
  azhdar_cmd_timeout_local 15 modprobe mimic >/dev/null 2>&1 || return 1
}

azhdar_mimic_ensure_kernel_module_local(){
  # Best-effort DKMS/module recovery. A plain modprobe is not enough when the
  # module was built before pahole/BTF tooling was present: libbpf then cannot
  # resolve mimic_change_csum_offset and the service exits with status=22.
  if azhdar_cmd_timeout_local 15 modprobe mimic >/dev/null 2>&1 && azhdar_mimic_kallsyms_has_hook_local; then
    return 0
  fi
  # During service start/restart do not run unbounded apt repairs; those belong to
  # the install/check phase. This keeps Smart Wizard from sitting at
  # "Start services (local)" for many minutes on small VPS kernels.
  if [[ "${AZHDAR_MIMIC_SERVICE_START_FAST:-0}" != "1" ]]; then
    if declare -F azhdar_install_mimic_build_deps_local >/dev/null 2>&1; then
      azhdar_install_mimic_build_deps_local >/dev/null 2>&1 || true
    fi
  fi
  azhdar_mimic_rebuild_module_local >/dev/null 2>&1 || true
  if azhdar_cmd_timeout_local 15 modprobe mimic >/dev/null 2>&1 && azhdar_mimic_kallsyms_has_hook_local; then
    return 0
  fi
  return 1
}

# Mimic is a per-interface systemd unit: mimic@<interface>.service.
# On VPS/virtual NICs, native XDP can fail; SKB mode is the safe default.

mimic_conf_force_skb(){
  local cfg="${1:-}"
  [[ -n "$cfg" && -f "$cfg" ]] || return 0
  if grep -Eq '^[[:space:]]*xdp_mode[[:space:]]*=' "$cfg" 2>/dev/null; then
    sed -i -E 's/^[[:space:]]*xdp_mode[[:space:]]*=.*/xdp_mode = skb/' "$cfg" 2>/dev/null || true
  else
    # Put it near the top so it is obvious in diagnostics.
    awk 'BEGIN{done=0} {print; if(!done && $0 ~ /^log\.verbosity[[:space:]]*=/){print "xdp_mode = skb"; done=1}} END{if(!done) print "xdp_mode = skb"}' "$cfg" >"${cfg}.tmp.$$" 2>/dev/null && mv -f "${cfg}.tmp.$$" "$cfg" || true
  fi
  chmod 644 "$cfg" 2>/dev/null || true
}

mimic_detect_local_if(){
  # Prefer the current WAN route, then an existing Mimic config/unit.
  local ifc=""
  ifc="$(detect_wan_if 2>/dev/null || true)"
  if [[ -n "$ifc" && "$ifc" != "lo" ]]; then
    echo "$ifc"
    return 0
  fi
  if command -v systemctl >/dev/null 2>&1; then
    ifc="$(systemctl list-units --all 'mimic@*.service' --no-legend --plain 2>/dev/null | awk '{print $1}' | sed -n 's/^mimic@\(.*\)\.service$/\1/p' | head -n1 || true)"
    if [[ -n "$ifc" && "$ifc" != "lo" ]]; then
      echo "$ifc"
      return 0
    fi
  fi
  local f
  for f in /etc/mimic/*.conf; do
    [[ -f "$f" ]] || continue
    ifc="$(basename "$f" .conf)"
    [[ -n "$ifc" && "$ifc" != "lo" ]] || continue
    echo "$ifc"
    return 0
  done
  return 1
}

mimic_local_active_quiet(){
  local wan="${1:-}"
  if command -v systemctl >/dev/null 2>&1; then
    if [[ -n "$wan" ]] && systemctl is-active --quiet "mimic@${wan}" 2>/dev/null; then
      return 0
    fi
    local svc
    while read -r svc; do
      [[ -n "$svc" ]] || continue
      systemctl is-active --quiet "$svc" 2>/dev/null && return 0
    done < <(systemctl list-units --all 'mimic@*.service' --no-legend --plain 2>/dev/null | awk '{print $1}')
  fi
  return 1
}

mimic_restart_local_checked(){
  local wan="${1:-}"
  [[ -n "$wan" ]] || wan="$(mimic_detect_local_if 2>/dev/null || true)"
  [[ -n "$wan" ]] || { err "Cannot detect local interface for Mimic."; return 1; }
  local cfg="/etc/mimic/${wan}.conf"
  [[ -f "$cfg" ]] || { err "Mimic config not found: ${cfg}"; return 1; }

  mimic_conf_force_skb "$cfg"
  azhdar_mimic_ensure_unit_local || true
  azhdar_mimic_ensure_service_user_local || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  AZHDAR_MIMIC_SERVICE_START_FAST=1 azhdar_mimic_ensure_kernel_module_local || true
  azhdar_mimic_clear_runtime_local "$wan" || true
  systemctl reset-failed "mimic@${wan}" >/dev/null 2>&1 || true
  azhdar_systemctl_quick_local 15 enable "mimic@${wan}" >/dev/null 2>&1 || true

  if azhdar_systemctl_quick_local 25 restart "mimic@${wan}" >/dev/null 2>&1; then
    return 0
  fi

  warn "Local Mimic failed on ${wan}; clearing stale locks, repairing module/account, and retrying."
  mimic_conf_force_skb "$cfg"
  azhdar_mimic_ensure_unit_local || true
  azhdar_mimic_ensure_service_user_local || true
  AZHDAR_MIMIC_SERVICE_START_FAST=1 azhdar_mimic_ensure_kernel_module_local || true
  azhdar_mimic_clear_runtime_local "$wan" || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed "mimic@${wan}" >/dev/null 2>&1 || true
  if azhdar_systemctl_quick_local 25 restart "mimic@${wan}" >/dev/null 2>&1; then
    ok "Local Mimic recovered on ${wan} after stale-lock/module repair."
    return 0
  fi

  warn "Local Mimic still failed on ${wan}; running bounded DKMS/BTF repair (max about 2 minutes) and one final retry."
  azhdar_mimic_clear_runtime_local "$wan" || true
  azhdar_mimic_rebuild_module_local >/dev/null 2>&1 || true
  azhdar_mimic_clear_runtime_local "$wan" || true
  systemctl daemon-reload >/dev/null 2>&1 || true
  systemctl reset-failed "mimic@${wan}" >/dev/null 2>&1 || true
  if azhdar_systemctl_quick_local 25 restart "mimic@${wan}" >/dev/null 2>&1; then
    ok "Local Mimic recovered on ${wan} after DKMS/BTF rebuild."
    return 0
  fi

  systemctl stop "mimic@${wan}" >/dev/null 2>&1 || true
  systemctl reset-failed "mimic@${wan}" >/dev/null 2>&1 || true
  err "Local Mimic service failed: mimic@${wan}"
  systemctl status "mimic@${wan}" --no-pager -l 2>/dev/null | sed -n '1,80p' || true
  journalctl -u "mimic@${wan}" -n 80 --no-pager -l 2>/dev/null || true
  warn "If the error mentions native XDP/driver support, xdp_mode=skb is already forced. If it mentions the kernel module, check: dkms status; modinfo mimic."
  return 1
}

mimic_remote_restart_checked(){
  local rif="${1:-}"
  [[ -n "$rif" ]] || rif="${REMOTE_WAN_IF:-}"
  [[ -n "$rif" ]] || rif="$(remote_detect_wan_if_quiet 2>/dev/null || true)"
  [[ -n "$rif" ]] || { warn "Remote interface not detected for Mimic restart."; return 1; }
  REMOTE_WAN_IF="$rif"
  local qrif
  qrif="$(printf '%q' "$rif")"
  ssh_run_stdin_env_root_best_effort "REMOTE_WAN_IF=${rif}" <<'REMOTE'
set -u
WAN_IF="${REMOTE_WAN_IF:-}"
[ -n "$WAN_IF" ] || { echo "ERR:NO_REMOTE_IF"; exit 1; }
CFG="/etc/mimic/${WAN_IF}.conf"
[ -f "$CFG" ] || { echo "ERR:NO_REMOTE_MIMIC_CONF:$CFG"; exit 1; }
if grep -Eq '^[[:space:]]*xdp_mode[[:space:]]*=' "$CFG" 2>/dev/null; then
  sed -i -E 's/^[[:space:]]*xdp_mode[[:space:]]*=.*/xdp_mode = skb/' "$CFG" 2>/dev/null || true
else
  awk 'BEGIN{done=0} {print; if(!done && $0 ~ /^log\.verbosity[[:space:]]*=/){print "xdp_mode = skb"; done=1}} END{if(!done) print "xdp_mode = skb"}' "$CFG" >"${CFG}.tmp.$$" 2>/dev/null && mv -f "${CFG}.tmp.$$" "$CFG" || true
fi
chmod 644 "$CFG" 2>/dev/null || true
# Repair missing systemd template. Some partial installs leave /usr/sbin/mimic
# available but no mimic@.service, so systemctl reports the unit as not-found
# and the real tunnel never starts.
ensure_mimic_unit(){
  if ! command -v systemctl >/dev/null 2>&1; then return 0; fi
  if systemctl cat mimic@.service >/dev/null 2>&1 || [ -f /etc/systemd/system/mimic@.service ] || [ -f /usr/lib/systemd/system/mimic@.service ] || [ -f /lib/systemd/system/mimic@.service ]; then
    return 0
  fi
  exe="$(command -v mimic 2>/dev/null || true)"
  [ -n "$exe" ] || exe="/usr/sbin/mimic"
  [ -x "$exe" ] || return 1
  mkdir -p /etc/systemd/system /etc/mimic /run/mimic /var/lib/mimic 2>/dev/null || true
  cat >/etc/systemd/system/mimic@.service <<EOF_UNIT
[Unit]
Description=Start Mimic on %i
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${exe} run %i -F /etc/mimic/%i.conf
Restart=on-failure
RestartSec=1
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF_UNIT
  chmod 644 /etc/systemd/system/mimic@.service 2>/dev/null || true
  systemctl daemon-reload >/dev/null 2>&1 || true
}
ensure_mimic_unit || true
# Repair missing service account before start; fixes status=217/USER after partial/old Mimic installs.
unit="$(systemctl cat mimic@.service 2>/dev/null || cat /etc/systemd/system/mimic@.service /usr/lib/systemd/system/mimic@.service /lib/systemd/system/mimic@.service 2>/dev/null || true)"
if [ -n "$unit" ]; then
  u="$(printf '%s
' "$unit" | awk -F= '/^[[:space:]]*User[[:space:]]*=/{v=$2; sub(/^[[:space:]]+/,"",v); sub(/[[:space:]]+$/,"",v); if(v!="") last=v} END{print last}' | tail -n1)"
  g="$(printf '%s
' "$unit" | awk -F= '/^[[:space:]]*Group[[:space:]]*=/{v=$2; sub(/^[[:space:]]+/,"",v); sub(/[[:space:]]+$/,"",v); if(v!="") last=v} END{print last}' | tail -n1)"
  case "$u" in ""|root|*%*|*\$*|*/*|*:*) :;; *)
    case "$g" in ""|*%*|*\$*|*/*|*:*) g="$u";; esac
    getent group "$g" >/dev/null 2>&1 || groupadd --system "$g" >/dev/null 2>&1 || true
    getent passwd "$u" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir /var/lib/mimic --shell /usr/sbin/nologin --gid "$g" "$u" >/dev/null 2>&1 || true
    mkdir -p /var/lib/mimic /run/mimic /etc/mimic 2>/dev/null || true
    chown "$u:$g" /var/lib/mimic /run/mimic 2>/dev/null || true
    chmod 755 /var/lib/mimic /run/mimic /etc/mimic 2>/dev/null || true
  esac
fi
cmd_timeout(){
  secs="${1:-60}"; shift || return 1
  if command -v timeout >/dev/null 2>&1; then
    timeout --foreground --kill-after=5s "${secs}s" "$@"
  else
    "$@"
  fi
}
systemctl_quick(){
  secs="${1:-25}"; shift || return 1
  cmd_timeout "$secs" systemctl "$@"
}
clear_mimic_runtime(){
  systemctl stop "mimic@${WAN_IF}" >/dev/null 2>&1 || true
  systemctl reset-failed "mimic@${WAN_IF}" >/dev/null 2>&1 || true
  if command -v pkill >/dev/null 2>&1; then
    pkill -TERM -f "(^|[ /])mimic([ ]+run)?[ ]+${WAN_IF}([ ]|$)" >/dev/null 2>&1 || true
    sleep 0.3
    pkill -KILL -f "(^|[ /])mimic([ ]+run)?[ ]+${WAN_IF}([ ]|$)" >/dev/null 2>&1 || true
  fi
  mkdir -p /run/mimic /var/lib/mimic 2>/dev/null || true
  find /run/mimic -maxdepth 1 -type f -name '*.lock' -delete 2>/dev/null || true
  find /run/mimic -maxdepth 1 -type s -delete 2>/dev/null || true
}
mimic_kallsyms_has_hook(){ grep -qw 'mimic_change_csum_offset' /proc/kallsyms 2>/dev/null; }
install_btf_tools(){
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1 APT_LISTCHANGES_FRONTEND=none
    cmd_timeout 45 apt-get update -y >/dev/null 2>&1 || true
    cmd_timeout 90 apt-get install -y pahole dwarves bpftool linux-tools-common "linux-tools-$(uname -r)" linux-tools-generic >/dev/null 2>&1 ||       cmd_timeout 60 apt-get install -y pahole dwarves bpftool >/dev/null 2>&1 ||       cmd_timeout 45 apt-get install -y pahole dwarves >/dev/null 2>&1 || true
  fi
}
dkms_versions(){
  if [ -d /var/lib/dkms/mimic ]; then find /var/lib/dkms/mimic -mindepth 1 -maxdepth 1 -type d -printf '%f
' 2>/dev/null || true; fi
  dkms status 2>/dev/null | awk -F'[,/]' '/^mimic\//{print $2}' | awk 'NF && !seen[$0]++' || true
}
rebuild_mimic_module(){
  command -v dkms >/dev/null 2>&1 || return 1
  kver="$(uname -r)"; seen=""
  install_btf_tools || true
  cmd_timeout 15 modprobe -r mimic >/dev/null 2>&1 || true
  while read -r ver; do
    [ -n "$ver" ] || continue
    case " $seen " in *" $ver "*) continue;; esac
    seen="$seen $ver"
    cmd_timeout 45 dkms remove -m mimic -v "$ver" -k "$kver" --force >/dev/null 2>&1 || true
    cmd_timeout 120 dkms build  -m mimic -v "$ver" -k "$kver" >/dev/null 2>&1 || true
    cmd_timeout 60 dkms install -m mimic -v "$ver" -k "$kver" --force >/dev/null 2>&1 || true
  done <<EOF_DKMS
$(dkms_versions)
EOF_DKMS
  if [ -z "$(printf '%s' "$seen" | tr -d ' ')" ] && dpkg -s mimic-dkms >/dev/null 2>&1 && command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install --reinstall -y mimic-dkms >/dev/null 2>&1 || true
  fi
  cmd_timeout 90 dkms autoinstall -k "$kver" >/dev/null 2>&1 || cmd_timeout 90 dkms autoinstall >/dev/null 2>&1 || true
  cmd_timeout 30 depmod -a >/dev/null 2>&1 || true
  cmd_timeout 15 modprobe mimic >/dev/null 2>&1 || return 1
}
ensure_mimic_module(){
  if modprobe mimic >/dev/null 2>&1 && mimic_kallsyms_has_hook; then return 0; fi
  rebuild_mimic_module >/dev/null 2>&1 || true
  if modprobe mimic >/dev/null 2>&1 && mimic_kallsyms_has_hook; then return 0; fi
  return 1
}
systemctl daemon-reload >/dev/null 2>&1 || true
ensure_mimic_module || true
clear_mimic_runtime || true
systemctl reset-failed "mimic@${WAN_IF}" >/dev/null 2>&1 || true
systemctl_quick 15 enable "mimic@${WAN_IF}" >/dev/null 2>&1 || true
if systemctl_quick 25 restart "mimic@${WAN_IF}" >/dev/null 2>&1; then
  echo "OK:REMOTE_MIMIC:${WAN_IF}"
  exit 0
fi
echo "WARN:REMOTE_MIMIC_RETRY:${WAN_IF}"
ensure_mimic_module || true
clear_mimic_runtime || true
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed "mimic@${WAN_IF}" >/dev/null 2>&1 || true
if systemctl_quick 25 restart "mimic@${WAN_IF}" >/dev/null 2>&1; then
  echo "OK:REMOTE_MIMIC:${WAN_IF}:recovered"
  exit 0
fi
echo "WARN:REMOTE_MIMIC_DEEP_REPAIR:${WAN_IF}"
clear_mimic_runtime || true
rebuild_mimic_module >/dev/null 2>&1 || true
clear_mimic_runtime || true
systemctl daemon-reload >/dev/null 2>&1 || true
systemctl reset-failed "mimic@${WAN_IF}" >/dev/null 2>&1 || true
if systemctl_quick 25 restart "mimic@${WAN_IF}" >/dev/null 2>&1; then
  echo "OK:REMOTE_MIMIC:${WAN_IF}:dkms-btf-recovered"
  exit 0
fi
echo "ERR:REMOTE_MIMIC_FAILED:${WAN_IF}"
systemctl status "mimic@${WAN_IF}" --no-pager -l 2>/dev/null | sed -n '1,80p' || true
journalctl -u "mimic@${WAN_IF}" -n 80 --no-pager -l 2>/dev/null || true
exit 1
REMOTE
}


mimic_local_conf_path(){
  local wan; wan="$(mimic_detect_local_if 2>/dev/null || true)"
  [[ -n "$wan" ]] || return 1
  echo "/etc/mimic/${wan}.conf"
}

mimic_profile_block_local(){
  # Print Mimic filter lines for a profile on the IR host.
  local name="$1"
  local wg_port ir_local out_ip
  wg_port="$(profile_read_var "$name" WG_PORT 2>/dev/null || true)"
  ir_local="$(profile_read_var "$name" IR_LOCAL_IP 2>/dev/null || true)"
  out_ip="$(profile_read_var "$name" OUT_PUBLIC_IP 2>/dev/null || true)"
  [[ -n "$wg_port" && -n "$ir_local" && -n "$out_ip" ]] || return 1
  cat <<EOF

# Profile: ${name}
filter = local=${ir_local}:${wg_port}
filter = remote=${out_ip}:${wg_port}
EOF
}

mimic_profile_block_remote(){
  # Print Mimic filter lines for a profile on the OUT host.
  local name="$1"
  local wg_port out_local ir_ip
  wg_port="$(profile_read_var "$name" WG_PORT 2>/dev/null || true)"
  out_local="$(profile_read_var "$name" OUT_LOCAL_IP 2>/dev/null || true)"
  ir_ip="$(profile_read_var "$name" IR_PUBLIC_IP 2>/dev/null || true)"
  [[ -n "$wg_port" && -n "$out_local" && -n "$ir_ip" ]] || return 1
  cat <<EOF

# Profile: ${name}
filter = local=${out_local}:${wg_port}
filter = remote=${ir_ip}:${wg_port}
EOF
}

mimic_should_include_profile(){
  # Include if enabled OR is the currently active profile (during install/repair).
  local name="$1"
  local enabled
  enabled="$(profile_read_var "$name" PROFILE_ENABLED 2>/dev/null || echo 0)"
  [[ "$enabled" == "1" ]] && return 0
  [[ -n "${PROFILE:-}" && "$name" == "$PROFILE" ]] && return 0
  return 1
}

mimic_should_include_profile_for_remote(){
  # Include only profiles that target the same remote host, plus current.
  local name="$1"
  local host
  host="$(profile_read_var "$name" OUT_SSH_HOST 2>/dev/null || true)"
  [[ -n "${OUT_SSH_HOST:-}" && "$host" == "${OUT_SSH_HOST}" ]] || return 1
  mimic_should_include_profile "$name"
}

mimic_rebuild_local_excluding(){
  # Rebuild local Mimic config for all enabled profiles, excluding the given name.
  local exclude="${1:-}"
  local wan; wan="$(mimic_detect_local_if 2>/dev/null || true)"
  [[ -n "$wan" ]] || return 0
  mkdir -p /etc/mimic

  local cfg="/etc/mimic/${wan}.conf"
  local tmp; tmp="$(mktemp -t azhdar-mimic.local.XXXXXX.conf)"

  cat >"$tmp" <<EOF
# Generated by AZHDAR v${SCRIPT_VERSION} - Mimic config (IR)
log.verbosity = info
xdp_mode = skb
handshake = 2:3
keepalive = 180:10:3:600
EOF

  local n any=0
  while read -r n; do
    n="$(safe_name "$n")"; [[ -n "$n" ]] || continue
    [[ -n "$exclude" && "$n" == "$exclude" ]] && continue
    local enabled
    enabled="$(profile_read_var "$n" PROFILE_ENABLED 2>/dev/null || echo 0)"
    [[ "$enabled" == "1" ]] || continue
    if mimic_profile_block_local "$n" >>"$tmp" 2>/dev/null; then
      any=1
    fi
  done < <(profiles_list)

  if (( any == 0 )); then
    # No active filters left -> stop mimic and remove config.
    command -v systemctl >/dev/null 2>&1 && systemctl stop "mimic@${wan}" >/dev/null 2>&1 || true
    rm -f "$cfg" 2>/dev/null || true
    rm -f "$tmp" 2>/dev/null || true
    return 0
  fi

  mv -f "$tmp" "$cfg"
  chmod 644 "$cfg" 2>/dev/null || true
  command -v systemctl >/dev/null 2>&1 && mimic_restart_local_checked "$wan" >/dev/null 2>&1 || true
  return 0
}

mimic_rebuild_remote_excluding(){
  # Rebuild remote Mimic config for all enabled profiles pointing to this OUT host, excluding the given name.
  local exclude="${1:-}"
  [[ -n "${OUT_SSH_HOST:-}" ]] || return 0
  [[ -n "${REMOTE_WAN_IF:-}" ]] || REMOTE_WAN_IF="$(remote_detect_wan_if_quiet || true)"
  [[ -n "${REMOTE_WAN_IF:-}" ]] || return 0

  local blocks=""
  local n
  while read -r n; do
    n="$(safe_name "$n")"; [[ -n "$n" ]] || continue
    [[ -n "$exclude" && "$n" == "$exclude" ]] && continue
    local host enabled
    host="$(profile_read_var "$n" OUT_SSH_HOST 2>/dev/null || true)"
    enabled="$(profile_read_var "$n" PROFILE_ENABLED 2>/dev/null || echo 0)"
    [[ "$host" == "${OUT_SSH_HOST}" ]] || continue
    [[ "$enabled" == "1" ]] || continue
    blocks+="$(mimic_profile_block_remote "$n" 2>/dev/null || true)"
  done < <(profiles_list)

  if [[ -z "$blocks" ]]; then
    ssh_run_root_best_effort "systemctl stop mimic@${REMOTE_WAN_IF} >/dev/null 2>&1 || true; rm -f /etc/mimic/${REMOTE_WAN_IF}.conf >/dev/null 2>&1 || true" >/dev/null 2>&1 || true
    return 0
  fi

  local blocks_b64
  blocks_b64="$(printf '%s' "$blocks" | base64 -w0 2>/dev/null || printf '%s' "$blocks" | base64 2>/dev/null | tr -d '\n')"

  ssh_run_stdin_env_root_best_effort "SCRIPT_VERSION=${SCRIPT_VERSION}" "REMOTE_WAN_IF=${REMOTE_WAN_IF}" "MIMIC_BLOCKS_B64=${blocks_b64}" <<'REMOTE' >/dev/null 2>&1 || true
set -euo pipefail
WAN_IF="${REMOTE_WAN_IF}"
mkdir -p /etc/mimic

MIMIC_BLOCKS="$(printf '%s' "${MIMIC_BLOCKS_B64:-}" | base64 -d 2>/dev/null || true)"

cat >"/etc/mimic/${WAN_IF}.conf" <<EOF
# Generated by AZHDAR v${SCRIPT_VERSION} - Mimic config (OUT)
log.verbosity = info
xdp_mode = skb
handshake = 0:0
${MIMIC_BLOCKS}
EOF

chmod 644 "/etc/mimic/${WAN_IF}.conf" 2>/dev/null || true
systemctl restart "mimic@${WAN_IF}" >/dev/null 2>&1 || true
REMOTE
  return 0
}

mimic_profile_present_local(){
  local name="$1"
  local wan; wan="$(mimic_detect_local_if 2>/dev/null || true)"
  [[ -n "$wan" ]] || return 1
  local cfg="/etc/mimic/${wan}.conf"
  [[ -f "$cfg" ]] || return 1
  grep -Fq "# Profile: ${name}" "$cfg" 2>/dev/null
}

mimic_profile_present_remote(){
  local name="$1"
  [[ -n "${REMOTE_WAN_IF:-}" ]] || REMOTE_WAN_IF="$(remote_detect_wan_if_quiet || true)"
  [[ -n "${REMOTE_WAN_IF:-}" ]] || return 1
  ssh_run "grep -Fq '# Profile: ${name}' /etc/mimic/${REMOTE_WAN_IF}.conf 2>/dev/null" >/dev/null 2>&1
}

write_mimic_conf_local(){
  step "Write Mimic config (local)"
  local wan; wan="$(mimic_detect_local_if 2>/dev/null || true)"
  [[ -n "$wan" ]] || die "Cannot detect WAN interface."
  mkdir -p /etc/mimic

  local cfg="/etc/mimic/${wan}.conf"
  local tmp; tmp="$(mktemp -t azhdar-mimic.local.XXXXXX.conf)"

  cat >"$tmp" <<EOF
# Generated by AZHDAR v${SCRIPT_VERSION} - Mimic config (IR)
log.verbosity = info
xdp_mode = skb
handshake = 2:3
keepalive = 180:10:3:600
EOF

  local n any=0
  while read -r n; do
    n="$(safe_name "$n")"; [[ -n "$n" ]] || continue
    mimic_should_include_profile "$n" || continue
    if mimic_profile_block_local "$n" >>"$tmp" 2>/dev/null; then
      any=1
    fi
  done < <(profiles_list)

  if (( any == 0 )); then
    warn "No enabled profiles found for Mimic(local). Leaving config with base settings only."
  fi

  mv -f "$tmp" "$cfg"
  chmod 644 "$cfg" 2>/dev/null || true
  ok "Local Mimic config written: ${cfg}"
}

write_mimic_conf_remote(){
  step "Write Mimic config (remote)"
  # Build one config per remote host; include all profiles that target this OUT host.
  local blocks=""
  local n
  while read -r n; do
    n="$(safe_name "$n")"; [[ -n "$n" ]] || continue
    mimic_should_include_profile_for_remote "$n" || continue
    blocks+="$(mimic_profile_block_remote "$n" 2>/dev/null || true)"
  done < <(profiles_list)

  # Transport blocks safely (newlines) via base64.
  local blocks_b64=""
  if have_cmd base64; then
    blocks_b64="$(printf '%s' "$blocks" | base64 -w0 2>/dev/null || printf '%s' "$blocks" | base64 2>/dev/null | tr -d '\n')"
  else
    die "base64 is required for remote Mimic config generation."
  fi

  local out
  out="$(ssh_run_stdin_env_root \
    "SCRIPT_VERSION=${SCRIPT_VERSION}" \
    "MIMIC_BLOCKS_B64=${blocks_b64}" <<'REMOTE'
set -euo pipefail

detect_if() {
  local ifc=""
  ifc="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' || true)"
  [[ -n "${ifc}" ]] || ifc="$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $5; exit}' || true)"
  [[ -n "${ifc}" ]] || ifc="$(ip -br link 2>/dev/null | awk '$1!="lo" && $2 ~ /UP/ {print $1; exit}' || true)"
  echo "${ifc}"
}

WAN_IF="$(detect_if)"
[[ -n "${WAN_IF}" ]] || { echo "ERR:NO_IF"; exit 7; }

mkdir -p /etc/mimic

MIMIC_BLOCKS=""
if command -v base64 >/dev/null 2>&1; then
  MIMIC_BLOCKS="$(printf '%s' "${MIMIC_BLOCKS_B64:-}" | base64 -d 2>/dev/null || true)"
fi

cat >"/etc/mimic/${WAN_IF}.conf" <<EOF
# Generated by AZHDAR v${SCRIPT_VERSION} - Mimic config (OUT)
log.verbosity = info
xdp_mode = skb
handshake = 0:0
${MIMIC_BLOCKS}
EOF

chmod 644 "/etc/mimic/${WAN_IF}.conf"
echo "WAN_IF=${WAN_IF}"
REMOTE
)" || true

  if echo "$out" | grep -q "ERR:NO_IF"; then
    die "Remote WAN interface detection failed."
  fi
  REMOTE_WAN_IF="$(echo "$out" | sed -n 's/^WAN_IF=//p' | tail -n1 | tr -d '\r')"
  [[ -n "${REMOTE_WAN_IF:-}" ]] || die "Remote Mimic interface name not detected."
  ok "Remote Mimic config written: /etc/mimic/${REMOTE_WAN_IF}.conf"
}

enable_mimic_local(){
  local wan; wan="$(mimic_detect_local_if 2>/dev/null || true)"
  [[ -n "$wan" ]] || return 1
  mimic_restart_local_checked "$wan"
}

enable_mimic_remote(){
  local rif="${REMOTE_WAN_IF:-}"
  if [[ -z "$rif" ]]; then
    rif="$(remote_detect_wan_if_quiet || true)"
    if [[ -n "$rif" ]]; then
      REMOTE_WAN_IF="$rif"
      profile_save >/dev/null 2>&1 || true
    fi
  fi
  [[ -n "$rif" ]] || return 1
  mimic_remote_restart_checked "$rif"
}

