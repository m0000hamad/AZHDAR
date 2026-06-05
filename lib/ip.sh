# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- IP/subnet helpers --------------------
set_subnet_vars(){
  local subnet="$1"

  # Normalize subnet (best-effort).
  if have_cmd python3; then
    subnet="$(python3 -c 'import ipaddress,sys
try:
  print(ipaddress.ip_network(sys.argv[1], strict=False).with_prefixlen)
except Exception:
  print(sys.argv[1])' "$subnet" 2>/dev/null || echo "$subnet")"
  fi

  TUN_SUBNET="$subnet"

  # Compute +1 / +2 addresses inside the subnet (best-effort, supports any IPv4 prefix).
  if have_cmd python3; then
    local out a1 a2
    out="$(python3 -c 'import ipaddress,sys
net=ipaddress.ip_network(sys.argv[1], strict=False)
base=int(net.network_address)
a1=str(ipaddress.IPv4Address(base+1))
a2=str(ipaddress.IPv4Address(base+2))
print(a1, a2)' "$subnet" 2>/dev/null || true)"
    a1="$(echo "$out" | awk '{print $1}' || true)"
    a2="$(echo "$out" | awk '{print $2}' || true)"
    if [[ -n "$a1" && -n "$a2" ]]; then
      IR_WG_IP="$a1"
      OUT_WG_IP="$a2"
      return 0
    fi
  fi

  # Fallback (assumes /24 style)
  local base="${subnet%/*}"
  IR_WG_IP="${base%.*}.1"
  OUT_WG_IP="${base%.*}.2"
}

ipv4_host_at(){
  local subnet="$1" host="$2"
  have_cmd python3 || return 1
  python3 - "$subnet" "$host" <<'PY'
import ipaddress,sys
net=ipaddress.ip_network(sys.argv[1], strict=False)
h=int(sys.argv[2])
addr=ipaddress.IPv4Address(int(net.network_address)+h)
if addr not in net:
    sys.exit(1)
print(str(addr))
PY
}

ipv6_host_at(){
  local subnet="$1" host="$2"
  have_cmd python3 || return 1
  python3 - "$subnet" "$host" <<'PY'
import ipaddress,sys
net=ipaddress.ip_network(sys.argv[1], strict=False)
h=int(sys.argv[2])
addr=ipaddress.IPv6Address(int(net.network_address)+h)
if addr not in net:
    sys.exit(1)
print(addr.compressed)
PY
}



subnet_candidates(){
  # A diverse set of RFC1918 /24s. Shuffled each call so we don't always pick the first entry.
  # This helps when some providers already route/bridge common 10.x ranges.
  local -a list=(
    "10.66.66.0/24" "10.77.77.0/24" "10.88.88.0/24" "10.99.99.0/24"
    "10.111.111.0/24" "10.123.45.0/24" "10.124.124.0/24" "10.131.131.0/24"
    "10.150.150.0/24" "10.160.160.0/24" "10.170.170.0/24" "10.180.180.0/24"
    "10.200.200.0/24" "10.210.210.0/24" "10.220.220.0/24" "10.250.250.0/24"

    "172.16.66.0/24" "172.17.66.0/24" "172.18.66.0/24" "172.19.66.0/24"
    "172.20.66.0/24" "172.21.66.0/24" "172.22.66.0/24" "172.23.66.0/24"
    "172.24.66.0/24" "172.25.66.0/24" "172.26.66.0/24" "172.27.66.0/24"
    "172.28.66.0/24" "172.29.66.0/24" "172.30.66.0/24" "172.31.66.0/24"

    "192.168.10.0/24" "192.168.20.0/24" "192.168.30.0/24" "192.168.40.0/24"
    "192.168.50.0/24" "192.168.60.0/24" "192.168.66.0/24" "192.168.70.0/24"
    "192.168.80.0/24" "192.168.90.0/24" "192.168.99.0/24" "192.168.111.0/24"
    "192.168.123.0/24" "192.168.150.0/24" "192.168.200.0/24" "192.168.250.0/24"
  )

  # Shuffle with pure bash (no external deps).
  local -a shuffled=()
  local idx
  while (( ${#list[@]} )); do
    idx=$((RANDOM % ${#list[@]}))
    shuffled+=("${list[$idx]}")
    unset "list[$idx]"
    list=("${list[@]}") # re-index to keep RANDOM%len valid
  done

  printf '%s\n' "${shuffled[@]}"
}


subnet_overlaps_local(){
  local cand="$1"
  python3 - <<PY
import ipaddress, subprocess, sys
cand=ipaddress.ip_network("$cand", strict=False)
routes=subprocess.check_output(["ip","-4","route","show"], text=True).splitlines()
nets=[]
for r in routes:
    tok=r.split()[0]
    if tok=="default": continue
    try: nets.append(ipaddress.ip_network(tok, strict=False))
    except: pass
for n in nets:
    if cand.overlaps(n):
        sys.exit(0)
sys.exit(1)
PY
}

subnet_overlaps_profiles(){
  # Returns 0 if candidate overlaps any saved profile subnet (even if the tunnel is down).
  local cand="$1"
  have_cmd python3 || return 1
  local subs=""
  local n s
  while read -r n; do
    n="$(safe_name "$n")"; [[ -n "$n" ]] || continue
    [[ -n "${PROFILE:-}" && "$n" == "${PROFILE}" ]] && continue
    s="$(profile_read_var "$n" TUN_SUBNET 2>/dev/null || true)"
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

subnet_overlaps_remote(){
  local cand="$1"
  ssh_run_stdin <<'REMOTE' >/dev/null 2>&1
set -euo pipefail
python3 - <<PY
import ipaddress, subprocess, sys
cand=ipaddress.ip_network("'"$cand"'", strict=False)
routes=subprocess.check_output(["ip","-4","route","show"], text=True).splitlines()
nets=[]
for r in routes:
    tok=r.split()[0]
    if tok=="default": continue
    try: nets.append(ipaddress.ip_network(tok, strict=False))
    except: pass
for n in nets:
    if cand.overlaps(n):
        sys.exit(0)
sys.exit(1)
PY
REMOTE
  return $?
}

pick_subnet_pairwise(){
  step "Pick a non-overlapping tunnel subnet"
  local skip="${1:-}"
  local cand
  while read -r cand; do
    [[ -z "$cand" ]] && continue
    [[ -n "$skip" && "$cand" == "$skip" ]] && continue
    if subnet_overlaps_local "$cand"; then
      continue
    fi
    if subnet_overlaps_remote "$cand"; then
      continue
    fi
    if subnet_overlaps_profiles "$cand"; then
      continue
    fi
    set_subnet_vars "$cand"
    ok "Selected subnet: ${TUN_SUBNET} (IR=${IR_WG_IP}, OUT=${OUT_WG_IP})"
    return 0
  done < <(subnet_candidates)
  warn "Could not verify route overlap reliably; using default ${TUN_SUBNET}"
  set_subnet_vars "${TUN_SUBNET}"
}

