# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- IPv6 tunnel helpers --------------------
set_subnet6_vars(){
  local subnet="$1"

  # Normalize subnet to compressed form if possible.
  if have_cmd python3; then
    subnet="$(python3 -c 'import ipaddress,sys;

try:
 print(ipaddress.ip_network(sys.argv[1], strict=False).compressed)
except Exception:
 print(sys.argv[1])' "$subnet" 2>/dev/null || echo "$subnet")"
  fi

  TUN_SUBNET6="$subnet"

  # Compute ::1 and ::2 inside the subnet (best-effort) and keep them compressed.
  if have_cmd python3; then
    local out a1 a2
    out="$(python3 -c 'import ipaddress,sys;

net=ipaddress.ip_network(sys.argv[1], strict=False)
base=int(net.network_address)
a1=ipaddress.IPv6Address(base+1).compressed
a2=ipaddress.IPv6Address(base+2).compressed
print(a1, a2)' "$subnet" 2>/dev/null || true)"
    a1="$(echo "$out" | awk '{print $1}' || true)"
    a2="$(echo "$out" | awk '{print $2}' || true)"
    if [[ -n "$a1" && -n "$a2" ]]; then
      IR_WG_IP6="$a1"
      OUT_WG_IP6="$a2"
    fi
  fi
}

subnet6_candidates(){
  # Short, type-1 style ULAs (compressed IPv6).
  cat <<EOF
fd00:1::/64
fd00:2::/64
fd00:3::/64
fd00:4::/64
fd00:5::/64
fd00:6::/64
fd00:7::/64
fd00:8::/64
fd00:9::/64
fd00:10::/64
fd00:66::/64
EOF
}

subnet6_overlaps_local(){
  local cand="$1"
  python3 - <<PY
import ipaddress, subprocess, sys
cand=ipaddress.ip_network("$cand", strict=False)
routes=subprocess.check_output(["ip","-6","route","show"], text=True).splitlines()
nets=[]
skip={"default","unreachable","blackhole","prohibit","throw","local","broadcast","multicast"}
for r in routes:
    if not r.strip(): 
        continue
    tok=r.split()[0]
    if tok in skip:
        continue
    try:
        nets.append(ipaddress.ip_network(tok, strict=False))
    except Exception:
        pass
for n in nets:
    if cand.overlaps(n):
        sys.exit(0)
sys.exit(1)
PY
}

subnet6_overlaps_remote(){
  local cand="$1"
  ssh_run_stdin <<'REMOTE' >/dev/null 2>&1
set -euo pipefail
python3 - <<PY
import ipaddress, subprocess, sys
cand=ipaddress.ip_network("'"$cand"'", strict=False)
routes=subprocess.check_output(["ip","-6","route","show"], text=True).splitlines()
nets=[]
skip={"default","unreachable","blackhole","prohibit","throw","local","broadcast","multicast"}
for r in routes:
    if not r.strip(): 
        continue
    tok=r.split()[0]
    if tok in skip:
        continue
    try:
        nets.append(ipaddress.ip_network(tok, strict=False))
    except Exception:
        pass
for n in nets:
    if cand.overlaps(n):
        sys.exit(0)
sys.exit(1)
PY
REMOTE
  return $?
}

subnet6_overlaps_profiles(){
  # Returns 0 if candidate overlaps any saved profile IPv6 subnet.
  have_cmd python3 || return 1
  local cand="$1"
  local subs=""
  local n s
  while read -r n; do
    n="$(safe_name "$n")"; [[ -n "$n" ]] || continue
    [[ -n "${PROFILE:-}" && "$n" == "${PROFILE}" ]] && continue
    s="$(profile_read_var "$n" TUN_SUBNET6 2>/dev/null || true)"
    [[ -n "$s" ]] && subs+="$s\n"
  done < <(profiles_list)

  python3 - <<PY
import ipaddress,sys
cand=ipaddress.ip_network("$cand", strict=False)
subs="""$subs""".strip().splitlines()
for s in subs:
  try:
    n=ipaddress.ip_network(s.strip(), strict=False)
  except Exception:
    continue
  if cand.overlaps(n):
    sys.exit(0)
sys.exit(1)
PY
}

pick_subnet6_pairwise(){
  step "Pick a non-overlapping IPv6 tunnel subnet"
  local skip="${1:-}"
  local cand
  while read -r cand; do
    [[ -z "$cand" ]] && continue
    [[ -n "$skip" && "$cand" == "$skip" ]] && continue
    if subnet6_overlaps_local "$cand"; then
      continue
    fi
    if subnet6_overlaps_remote "$cand"; then
      continue
    fi
    if subnet6_overlaps_profiles "$cand"; then
      continue
    fi
    set_subnet6_vars "$cand"
    ok "Selected IPv6 subnet: ${TUN_SUBNET6} (IR=${IR_WG_IP6}, OUT=${OUT_WG_IP6})"
    return 0
  done < <(subnet6_candidates)
  warn "Could not verify IPv6 route overlap reliably; using default ${TUN_SUBNET6}"
  set_subnet6_vars "${TUN_SUBNET6}"
  return 0
}

format_ipport(){
  # For config fields that use ip:port. For IPv6, emit [ip]:port.
  local host="$1" port="$2"
  if is_ipv6 "$host"; then
    echo "[${host}]:${port}"
  else
    echo "${host}:${port}"
  fi
}

detect_src_ip(){
  local target="$1"
  ip route get "$target" 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}'
}

auto_detect_local_ips(){
  step "Auto-detect Mimic filter IPs"
  if [[ -z "${IR_LOCAL_IP:-}" && -n "${OUT_PUBLIC_IP:-}" ]]; then
    IR_LOCAL_IP="$(detect_src_ip "${OUT_PUBLIC_IP}" | tr -d '\n\r' || true)"
  fi
  if [[ -z "${OUT_LOCAL_IP:-}" && -n "${IR_PUBLIC_IP:-}" ]]; then
    OUT_LOCAL_IP="$(ssh_run "ip route get ${IR_PUBLIC_IP} 2>/dev/null | awk '/src/ {for(i=1;i<=NF;i++){if(\$i==\"src\"){print \$(i+1); exit}}}'" 2>/dev/null | tr -d '\n\r' | tail -n1 || true)"
  fi
  [[ -n "${IR_LOCAL_IP:-}" ]] && ok "IR local IP: ${IR_LOCAL_IP}" || warn "Could not auto-detect IR local IP."
  [[ -n "${OUT_LOCAL_IP:-}" ]] && ok "OUT local IP: ${OUT_LOCAL_IP}" || warn "Could not auto-detect OUT local IP."
}

