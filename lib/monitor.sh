#!/usr/bin/env bash
# AZHDAR live monitor: clients online, uptime and restarts, tunnel traffic, wire
# overhead. Read-only except for the optional accounting rules, which are jumps
# to empty chains and so cannot change what happens to a packet.

MON_INTERVAL="${AZHDAR_MONITOR_INTERVAL:-2}"
MON_HISTORY=24
MON_WIDTH=62

_mon_state_dir(){ echo "${BASE_DIR}/monitor"; }
_mon_state_file(){ echo "$(_mon_state_dir)/${PROFILE:-default}.state"; }

# ---------- formatting ----------

_mon_bytes(){
  local b="${1:-0}"
  [[ "$b" =~ ^[0-9]+$ ]] || b=0
  awk -v b="$b" 'BEGIN{
    split("B KB MB GB TB PB", u, " ");
    i = 1;
    while (b >= 1024 && i < 6) { b /= 1024; i++ }
    if (i == 1) printf "%d %s", b, u[i]; else printf "%.2f %s", b, u[i];
  }'
}

_mon_rate(){ printf '%s/s' "$(_mon_bytes "${1:-0}")"; }

_mon_dur(){
  local s="${1:-0}"
  [[ "$s" =~ ^[0-9]+$ ]] || s=0
  local d=$(( s / 86400 )) h=$(( (s % 86400) / 3600 )) m=$(( (s % 3600) / 60 ))
  if   (( d > 0 )); then printf '%dd %dh' "$d" "$h"
  elif (( h > 0 )); then printf '%dh %dm' "$h" "$m"
  elif (( m > 0 )); then printf '%dm %ds' "$m" "$(( s % 60 ))"
  else printf '%ds' "$s"
  fi
}

_mon_spark(){
  local -a vals=("$@")
  (( ${#vals[@]} > 0 )) || { printf ' '; return; }
  local max=0 v
  for v in "${vals[@]}"; do
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    (( v > max )) && max="$v"
  done
  local -a blocks=('▁' '▂' '▃' '▄' '▅' '▆' '▇' '█')
  local out="" idx
  for v in "${vals[@]}"; do
    [[ "$v" =~ ^[0-9]+$ ]] || v=0
    if (( max == 0 )); then idx=0; else idx=$(( v * 7 / max )); fi
    (( idx < 0 )) && idx=0
    (( idx > 7 )) && idx=7
    out+="${blocks[$idx]}"
  done
  printf '%s' "$out"
}

# ---------- box drawing ----------

_mon_line(){
  # tr works on bytes and would mangle a 3-byte box character, so build it up.
  local n="${1:-0}" out=""
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  while (( n-- > 0 )); do out+=$'─'; done
  printf '%s' "$out"
}

_mon_box_top(){
  local title="${1:-}"
  printf '%b┌─ %s %s┐%b\n' "$DIM" "$title" "$(_mon_line $(( MON_WIDTH - 3 - ${#title} )))" "$RST"
}

_mon_box_bot(){ printf '%b└%s┘%b\n' "$DIM" "$(_mon_line "$MON_WIDTH")" "$RST"; }

_mon_row(){
  # usage: _mon_row <plain-text> [color-escape]
  local t="${1:-}" c="${2:-}" pad
  (( ${#t} > MON_WIDTH - 2 )) && t="${t:0:$(( MON_WIDTH - 2 ))}"
  pad=$(( MON_WIDTH - 1 - ${#t} ))
  printf '%b│%b %b%s%b%*s%b│%b\n' "$DIM" "$RST" "$c" "$t" "$RST" "$pad" '' "$DIM" "$RST"
}

# ---------- sources ----------

_mon_clients(){
  # usage: _mon_clients <csv-of-tcp-ports> -> "<established> <unique-ips>"
  local csv="${1:-}" port filter="" raw="" conns=0 ips=0
  [[ -n "$csv" ]] || { echo "0 0"; return; }
  for port in ${csv//,/ }; do
    port="${port// /}"
    [[ -n "$port" ]] || continue
    filter+="${filter:+|}dport=${port}"
  done
  [[ -n "$filter" ]] || { echo "0 0"; return; }

  if have_cmd conntrack; then
    raw="$(conntrack -L -p tcp 2>/dev/null | grep -E "$filter" | grep ESTABLISHED || true)"
  elif [[ -r /proc/net/nf_conntrack ]]; then
    raw="$(grep -E "$filter" /proc/net/nf_conntrack 2>/dev/null | grep ESTABLISHED || true)"
  fi
  [[ -n "$raw" ]] || { echo "0 0"; return; }
  conns="$(printf '%s\n' "$raw" | grep -c . || true)"
  ips="$(printf '%s\n' "$raw" | grep -oE 'src=[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u | grep -c . || true)"
  [[ "$conns" =~ ^[0-9]+$ ]] || conns=0
  [[ "$ips" =~ ^[0-9]+$ ]] || ips=0
  echo "$conns $ips"
}

_mon_unit_uptime(){
  local unit="${1:-}" ts epoch
  [[ -n "$unit" ]] || { echo 0; return; }
  systemctl is-active --quiet "$unit" 2>/dev/null || { echo 0; return; }
  ts="$(systemctl show "$unit" -p ActiveEnterTimestamp --value 2>/dev/null || true)"
  [[ -n "$ts" ]] || { echo 0; return; }
  epoch="$(date -d "$ts" +%s 2>/dev/null || echo 0)"
  [[ "$epoch" =~ ^[0-9]+$ ]] && (( epoch > 0 )) || { echo 0; return; }
  echo $(( $(date +%s) - epoch ))
}

_mon_unit_restarts(){
  local n
  n="$(systemctl show "${1:-}" -p NRestarts --value 2>/dev/null || echo 0)"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  echo "$n"
}

_mon_wg_transfer(){
  if ! have_cmd wg || ! ip link show "${WG_IF}" >/dev/null 2>&1; then echo "0 0"; return; fi
  wg show "${WG_IF}" transfer 2>/dev/null | awk 'NR==1{print $2" "$3}' || echo "0 0"
}

# ---------- framing overhead ----------

# Mimic rewrites packets in XDP, which runs before netfilter and before any
# capture hook, so the TCP frames it puts on the wire are invisible to iptables
# and to tcpdump on this host: both only ever see the UDP form. Wire bytes
# therefore cannot be measured locally, and this is an arithmetic estimate
# instead: Mimic replaces an 8-byte UDP header with a 20-byte TCP header, so
# each packet grows by about 12 bytes.
MON_FRAMING_BYTES_PER_PACKET=12

_mon_wg_packets(){
  # usage: _mon_wg_packets -> "<rx-packets> <tx-packets>"
  local d="/sys/class/net/${WG_IF}/statistics"
  local rx=0 tx=0
  [[ -r "$d/rx_packets" ]] && rx="$(cat "$d/rx_packets" 2>/dev/null || echo 0)"
  [[ -r "$d/tx_packets" ]] && tx="$(cat "$d/tx_packets" 2>/dev/null || echo 0)"
  [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
  [[ "$tx" =~ ^[0-9]+$ ]] || tx=0
  echo "$rx $tx"
}

_mon_count(){
  # usage: _mon_count <n> -> "40.8 M"
  local n="${1:-0}"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  awk -v n="$n" 'BEGIN{
    if (n >= 1000000000) printf "%.2f G", n / 1000000000;
    else if (n >= 1000000) printf "%.2f M", n / 1000000;
    else if (n >= 1000) printf "%.1f k", n / 1000;
    else printf "%d", n;
  }'
}


# ---------- lifetime totals across service restarts ----------

_mon_totals_load(){
  MON_BASE_RX=0; MON_BASE_TX=0; MON_LAST_RX=0; MON_LAST_TX=0
  local f
  f="$(_mon_state_file)"
  [[ -r "$f" ]] || return 0
  # shellcheck disable=SC1090
  source "$f" 2>/dev/null || true
  [[ "${MON_BASE_RX:-}" =~ ^[0-9]+$ ]] || MON_BASE_RX=0
  [[ "${MON_BASE_TX:-}" =~ ^[0-9]+$ ]] || MON_BASE_TX=0
  [[ "${MON_LAST_RX:-}" =~ ^[0-9]+$ ]] || MON_LAST_RX=0
  [[ "${MON_LAST_TX:-}" =~ ^[0-9]+$ ]] || MON_LAST_TX=0
}

_mon_totals_update(){
  # WireGuard counters restart from zero whenever the interface is recreated, so
  # carry the previous run forward instead of losing it.
  local rx="${1:-0}" tx="${2:-0}"
  (( rx < MON_LAST_RX )) && MON_BASE_RX=$(( MON_BASE_RX + MON_LAST_RX ))
  (( tx < MON_LAST_TX )) && MON_BASE_TX=$(( MON_BASE_TX + MON_LAST_TX ))
  MON_LAST_RX="$rx"
  MON_LAST_TX="$tx"
  install -d -m 700 "$(_mon_state_dir)" 2>/dev/null || true
  {
    echo "MON_BASE_RX=${MON_BASE_RX}"
    echo "MON_BASE_TX=${MON_BASE_TX}"
    echo "MON_LAST_RX=${MON_LAST_RX}"
    echo "MON_LAST_TX=${MON_LAST_TX}"
  } > "$(_mon_state_file)" 2>/dev/null || true
}

# ---------- main loop ----------

azhdar_monitor_live(){
  ensure_profile_selected || return 1
  if ! have_cmd wg; then
    err "wg is not installed; nothing to monitor."
    pause
    return 1
  fi

  local -a h_ips=() h_rx=() h_tx=()
  local prev_rx=0 prev_tx=0 prev_t=0 first=1 wan
  wan="$(mimic_detect_local_if 2>/dev/null || true)"
  _mon_totals_load

  printf '\e[?25l'

  while :; do
    local now rx tx d_rx=0 d_tx=0 dt=1
    now="$(date +%s)"
    read -r rx tx <<<"$(_mon_wg_transfer)"
    [[ "$rx" =~ ^[0-9]+$ ]] || rx=0
    [[ "$tx" =~ ^[0-9]+$ ]] || tx=0

    if (( first == 0 )); then
      dt=$(( now - prev_t ))
      (( dt < 1 )) && dt=1
      (( rx >= prev_rx )) && d_rx=$(( (rx - prev_rx) / dt ))
      (( tx >= prev_tx )) && d_tx=$(( (tx - prev_tx) / dt ))
    fi
    prev_rx="$rx"; prev_tx="$tx"; prev_t="$now"; first=0

    _mon_totals_update "$rx" "$tx"
    local total=$(( MON_BASE_RX + rx + MON_BASE_TX + tx ))

    local conns ips
    read -r conns ips <<<"$(_mon_clients "${FORWARD_TCP_PORTS:-}")"

    h_ips+=("$ips"); h_rx+=("$d_rx"); h_tx+=("$d_tx")
    if (( ${#h_ips[@]} > MON_HISTORY )); then
      h_ips=("${h_ips[@]:1}"); h_rx=("${h_rx[@]:1}"); h_tx=("${h_tx[@]:1}")
    fi

    local hs age state_txt state_col
    hs="$(wg show "${WG_IF}" latest-handshakes 2>/dev/null | awk 'NR==1{print $2}')"
    [[ "$hs" =~ ^[0-9]+$ ]] || hs=0
    if (( hs == 0 )); then
      state_txt="no handshake"; state_col="$RED"; age="never"
    else
      age="$(( now - hs ))s ago"
      if (( now - hs <= 180 )); then
        state_txt="connected"; state_col="$GRN"
      else
        state_txt="stale"; state_col="$YLW"
      fi
    fi

    local sys_up wg_up mi_up wg_re mi_re
    sys_up="$(cut -d' ' -f1 /proc/uptime 2>/dev/null | cut -d. -f1)"
    [[ "$sys_up" =~ ^[0-9]+$ ]] || sys_up=0
    wg_up="$(_mon_unit_uptime "wg-quick@${WG_IF}")"
    mi_up="$(_mon_unit_uptime "mimic@${wan}")"
    wg_re="$(_mon_unit_restarts "wg-quick@${WG_IF}")"
    mi_re="$(_mon_unit_restarts "mimic@${wan}")"


    printf '\e[H\e[2J'
    printf '%b%bAZHDAR MONITOR%b  %bprofile %s · %s%b\n\n' \
      "$BOLD" "$WHT" "$RST" "$DIM" "${PROFILE}" "$(date '+%H:%M:%S')" "$RST"

    _mon_box_top "TUNNEL"
    _mon_row "$(printf 'state      %-14s handshake %s' "$state_txt" "$age")" "$state_col"
    _mon_row "$(printf 'peer       %s:%s' "${OUT_PUBLIC_IP:-?}" "${WG_PORT:-?}")"
    _mon_box_bot

    _mon_box_top "UPTIME"
    _mon_row "$(printf 'system     %s' "$(_mon_dur "$sys_up")")"
    _mon_row "$(printf 'wireguard  %-14s restarts %s' "$(_mon_dur "$wg_up")" "$wg_re")"
    _mon_row "$(printf 'mimic      %-14s restarts %s' "$(_mon_dur "$mi_up")" "$mi_re")"
    _mon_box_bot

    _mon_box_top "CLIENTS"
    _mon_row "$(printf 'online     %s unique IP · %s connections' "$ips" "$conns")" "$BOLD"
    _mon_row "$(printf 'trend      %s' "$(_mon_spark "${h_ips[@]}")")" "$CYN"
    _mon_box_bot

    _mon_box_top "TRAFFIC"
    _mon_row "$(printf 'in         %-12s %-13s %s' "$(_mon_bytes "$rx")" "$(_mon_rate "$d_rx")" "$(_mon_spark "${h_rx[@]}")")"
    _mon_row "$(printf 'out        %-12s %-13s %s' "$(_mon_bytes "$tx")" "$(_mon_rate "$d_tx")" "$(_mon_spark "${h_tx[@]}")")"
    _mon_row "$(printf 'session    %s' "$(_mon_bytes $(( rx + tx )))")"
    _mon_row "$(printf 'lifetime   %s  carried across restarts' "$(_mon_bytes "$total")")" "$DIM"
    _mon_box_bot

    local pkt_rx pkt_tx pkts framing
    read -r pkt_rx pkt_tx <<<"$(_mon_wg_packets)"
    pkts=$(( pkt_rx + pkt_tx ))
    framing=$(( pkts * MON_FRAMING_BYTES_PER_PACKET ))

    _mon_box_top "FRAMING"
    _mon_row "$(printf 'payload    %-14s inside the tunnel' "$(_mon_bytes $(( rx + tx )))")"
    _mon_row "$(printf 'packets    %s' "$(_mon_count "$pkts")")"
    _mon_row "$(printf 'mimic adds ~%-13s estimate, +%s B per packet' "$(_mon_bytes "$framing")" "$MON_FRAMING_BYTES_PER_PACKET")" "$YLW"
    _mon_row 'nothing here compresses; TCP framing only adds bytes' "$DIM"
    _mon_box_bot

    printf '\n%b q quit · refresh %ss%b\n' "$DIM" "$MON_INTERVAL" "$RST"

    if [[ -n "${AZHDAR_MONITOR_ONCE:-}" ]]; then
      break
    fi

    # Without a terminal on stdin, read returns instantly on EOF and the loop
    # would spin, so pace it with sleep instead.
    local key=""
    if [[ -t 0 ]]; then
      read -rsn1 -t "$MON_INTERVAL" key || true
    else
      sleep "$MON_INTERVAL"
    fi
    case "$key" in
      q|Q) break ;;
    esac
  done

  printf '\e[?25h'
  return 0
}

menu_monitor(){ azhdar_monitor_live || true; printf '\e[?25h'; }
