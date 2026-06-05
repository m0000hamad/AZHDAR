# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Menu UI helpers --------------------
status_badge(){
  local okflag="$1" label="$2" degrade="${3:-0}" suffix="${4:-}"
  # Color meaning:
  #   green  = connected/active now
  #   yellow = degraded/temporary issue, likely recoverable
  #   red    = down/failing
  #   dim ○  = not checked in the fast menu (use full status for exact remote state)
  if [[ "$okflag" == "1" ]]; then
    if [[ -n "$suffix" ]]; then
      echo -e "${GRN}●${RST} ${label}${DIM} ${GRN}${suffix}${RST}"
    else
      echo -e "${GRN}●${RST} ${label}"
    fi
  else
    case "$degrade" in
      1|degraded|yellow)
        echo -e "${YLW}●${RST} ${label}"
        ;;
      2|skip|unknown|unchecked)
        echo -e "${DIM}○ ${label}${RST}"
        ;;
      *)
        echo -e "${RED}●${RST} ${label}"
        ;;
    esac
  fi
}

