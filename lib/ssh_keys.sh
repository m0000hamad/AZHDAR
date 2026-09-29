# shellcheck shell=bash
# Part of AZHDAR (modular)

# -------------------- Shared SSH key menu --------------------
# One private key, stored root-only at $(ssh_shared_key_path) without a
# passphrase. ssh_identity() in lib/ssh.sh uses it for every OUT profile that
# has no identity file of its own, so any OUT server whose authorized_keys
# holds the matching public key logs in without a password. Saved passwords
# stay as the fallback for servers that do not trust the key yet.

ssh_key_pub_line(){
  # Public half of the shared key as "type base64 azhdar-shared". The comment
  # is normalised so the line is safe inside single quotes on a remote shell.
  local key; key="$(ssh_shared_key_path)"
  [[ -r "$key" ]] || return 0
  ssh-keygen -y -f "$key" 2>/dev/null </dev/null | awk 'NF>=2 {print $1" "$2" azhdar-shared"; exit}' || true
}

ssh_key_fingerprint(){
  local pub; pub="$(ssh_shared_key_path).pub"
  [[ -r "$pub" ]] || return 0
  ssh-keygen -lf "$pub" 2>/dev/null | awk '{print $2" "$NF; exit}' || true
}

ssh_key_store(){
  # usage: ssh_key_store <private-key-file>
  # Validate the key, drop its passphrase (asking for it) and install it as the
  # shared key. The source file itself is never modified.
  local src="$1" key dir work
  key="$(ssh_shared_key_path)"
  dir="$(dirname "$key")"
  have_cmd ssh-keygen || { err "ssh-keygen not found (install openssh-client)."; return 1; }
  mkdir -p "$dir" 2>/dev/null || true
  chmod 700 "$dir" 2>/dev/null || true
  work="$(mktemp -d "${dir}/.import.XXXXXX" 2>/dev/null || true)"
  [[ -n "$work" && -d "$work" ]] || { err "Cannot create a temp dir in ${dir}."; return 1; }
  chmod 700 "$work" 2>/dev/null || true

  # Keys copied from Windows often carry CRLF, which ssh-keygen rejects.
  if ! tr -d '\r' <"$src" >"$work/k" 2>/dev/null; then
    err "Cannot read ${src}."
    rm -rf "$work"; return 1
  fi
  chmod 600 "$work/k" 2>/dev/null || true

  if grep -q '^ssh-\|^ecdsa-\|^sk-' "$work/k" 2>/dev/null && ! grep -q 'PRIVATE KEY' "$work/k" 2>/dev/null; then
    err "That is a PUBLIC key. AZHDAR needs the PRIVATE key; the public one goes on the servers."
    rm -rf "$work"; return 1
  fi

  if grep -q '^PuTTY-User-Key-File' "$work/k" 2>/dev/null; then
    if have_cmd puttygen && puttygen "$work/k" -O private-openssh -o "$work/k2" >/dev/null 2>&1; then
      mv -f "$work/k2" "$work/k" 2>/dev/null || true
      chmod 600 "$work/k" 2>/dev/null || true
    else
      err "This is a PuTTY .ppk key. Convert it first: PuTTYgen > Conversions > Export OpenSSH key."
      rm -rf "$work"; return 1
    fi
  fi

  if ! ssh-keygen -y -P "" -f "$work/k" >/dev/null 2>&1 </dev/null; then
    if ! grep -q 'PRIVATE KEY' "$work/k" 2>/dev/null; then
      err "Not a private key."
      rm -rf "$work"; return 1
    fi
    warn "This key has a passphrase. AZHDAR keeps its copy without one (sshpass cannot answer passphrase prompts). Your original key file is not changed."
    local pp="" tries=0 unlocked=0
    while (( tries < 3 )); do
      read -rsp "Key passphrase: " pp || true
      echo
      if ssh-keygen -p -P "$pp" -N "" -f "$work/k" >/dev/null 2>&1 </dev/null; then
        unlocked=1
        break
      fi
      warn "Wrong passphrase (or unsupported key format)."
      tries=$((tries+1))
    done
    pp=""
    if (( unlocked == 0 )); then
      err "Key not imported."
      rm -rf "$work"; return 1
    fi
  fi

  if ! ssh-keygen -y -f "$work/k" 2>/dev/null </dev/null | awk 'NF>=2 {print $1" "$2" azhdar-shared"; exit}' >"$work/k.pub" 2>/dev/null || [[ ! -s "$work/k.pub" ]]; then
    err "Could not read the public half of this key."
    rm -rf "$work"; return 1
  fi

  if ! mv -f "$work/k" "$key" 2>/dev/null || ! mv -f "$work/k.pub" "${key}.pub" 2>/dev/null; then
    err "Cannot write ${key}."
    rm -rf "$work"; return 1
  fi
  chmod 600 "$key" 2>/dev/null || true
  chmod 644 "${key}.pub" 2>/dev/null || true
  rm -rf "$work"
  ok "Shared SSH key saved: ${key}"
  return 0
}

ssh_key_generate(){
  local key work rc=0
  key="$(ssh_shared_key_path)"
  have_cmd ssh-keygen || { err "ssh-keygen not found (install openssh-client)."; return 1; }
  if ssh_shared_key_present; then
    warn "A shared key already exists. Servers that trust only the old public key will fall back to their saved password."
    if [[ "$(prompt_yesno "Replace it with a new key?" "N")" != "Y" ]]; then
      info "Kept the existing key."
      return 1
    fi
  fi
  mkdir -p "$(dirname "$key")" 2>/dev/null || true
  work="$(mktemp -d 2>/dev/null || true)"
  [[ -n "$work" && -d "$work" ]] || { err "Cannot create a temp dir."; return 1; }
  if ! ssh-keygen -q -t ed25519 -N "" -C "azhdar-shared" -f "$work/k" >/dev/null 2>&1 </dev/null; then
    err "ssh-keygen failed."
    rm -rf "$work"; return 1
  fi
  ssh_key_store "$work/k" || rc=$?
  rm -rf "$work"
  return "$rc"
}

ssh_key_import(){
  local first="" line="" src="" tmp="" dir rc=0
  dir="$(dirname "$(ssh_shared_key_path)")"
  if ssh_shared_key_present; then
    warn "A shared key already exists and will be replaced."
    if [[ "$(prompt_yesno "Continue?" "N")" != "Y" ]]; then
      info "Kept the existing key."
      return 1
    fi
  fi
  echo -e "${DIM}Paste the PRIVATE key (first line -----BEGIN ...), or type the path of a key file on this server.${RST}"
  IFS= read -r first || true
  first="${first//$'\r'/}"
  first="${first#"${first%%[![:space:]]*}"}"
  first="${first%"${first##*[![:space:]]}"}"
  if [[ -z "$first" ]]; then
    warn "Nothing entered."
    return 1
  fi

  if [[ "$first" =~ ^(ssh-|ecdsa-|sk-)[^[:space:]]+[[:space:]]+AAAA ]]; then
    err "That is a PUBLIC key. AZHDAR needs the PRIVATE key; the public one goes on the servers."
    return 1
  fi

  if [[ "$first" == -----BEGIN* || "$first" == PuTTY-User-Key-File* ]]; then
    mkdir -p "$dir" 2>/dev/null || true
    tmp="$(mktemp "${dir}/.paste.XXXXXX" 2>/dev/null || true)"
    [[ -n "$tmp" ]] || { err "Cannot create a temp file in ${dir}."; return 1; }
    chmod 600 "$tmp" 2>/dev/null || true
    printf '%s\n' "$first" >"$tmp"
    while IFS= read -r line; do
      line="${line//$'\r'/}"
      printf '%s\n' "$line" >>"$tmp"
      if [[ "$first" == -----BEGIN* && "$line" == -----END* ]]; then break; fi
      if [[ "$first" == PuTTY-User-Key-File* && "$line" == Private-MAC:* ]]; then break; fi
    done
    src="$tmp"
  else
    src="${first/#\~/${HOME:-/root}}"
    if [[ ! -f "$src" || ! -r "$src" ]]; then
      err "File not found: ${src}"
      return 1
    fi
  fi

  ssh_key_store "$src" || rc=$?
  if [[ -n "$tmp" ]]; then rm -f "$tmp" 2>/dev/null || true; fi
  return "$rc"
}

ssh_key_show_pub(){
  local pub; pub="$(ssh_key_pub_line)"
  if [[ -z "$pub" ]]; then
    warn "No shared SSH key yet. Generate or import one first."
    return 1
  fi
  echo
  echo -e "${BOLD}${WHT}Public key${RST} ${DIM}(put this on every OUT server)${RST}"
  hr
  echo "$pub"
  hr
  echo -e "${DIM}New VPS:${RST} paste it into the provider's SSH key field when creating the server."
  echo -e "${DIM}Existing server:${RST} run this on it as the SSH user:"
  echo "  mkdir -p ~/.ssh && chmod 700 ~/.ssh && echo '${pub}' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
  echo -e "${DIM}Or use the \"Install public key\" options in this menu (logs in once with the saved password).${RST}"
  return 0
}

ssh_key_install_loaded_profile(){
  # Add the shared public key to OUT_SSH_USER's authorized_keys on the loaded
  # profile's OUT server, logging in with whatever works today (password,
  # profile identity or interactive prompt).
  # usage: ssh_key_install_loaded_profile [skip_precheck]
  # skip_precheck=1 when the caller already saw the key fail, to spare one
  # failed login (sshd PerSourcePenalties counts each one).
  local skip_precheck="${1:-0}" key pub blob name="${PROFILE:-?}" target rcmd rc=0
  key="$(ssh_shared_key_path)"
  pub="$(ssh_key_pub_line)"
  [[ -n "$pub" ]] || { warn "No shared SSH key yet."; return 1; }
  if [[ "${WG_MODE:-classic}" == "account" || -z "${OUT_SSH_HOST:-}" ]]; then
    info "${name}: no SSH server (account profile) - skipped."
    return 0
  fi
  target="${OUT_SSH_USER:-root}@${OUT_SSH_HOST}:${OUT_SSH_PORT:-22}"
  if [[ "$skip_precheck" != "1" ]] && ssh_key_only_ok "$OUT_SSH_HOST" "${OUT_SSH_PORT:-22}" "$key"; then
    ok "${name}: key login already works (${target})."
    return 0
  fi

  info "${name}: adding public key on ${target} ..."
  blob="$(awk '{print $2}' <<<"$pub")"
  # Match on the base64 blob so an existing entry with another comment counts.
  # Add a newline first when authorized_keys does not end with one.
  rcmd="umask 077; mkdir -p ~/.ssh && touch ~/.ssh/authorized_keys && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys || exit 3
f=~/.ssh/authorized_keys
if ! grep -qF '${blob}' \"\$f\"; then
  if [ -s \"\$f\" ] && [ -n \"\$(tail -c1 \"\$f\")\" ]; then echo >>\"\$f\"; fi
  echo '${pub}' >>\"\$f\" || exit 3
fi
if command -v restorecon >/dev/null 2>&1; then restorecon -R ~/.ssh >/dev/null 2>&1; fi
exit 0"
  SSH_ACTIVE_HOST=""
  SSH_ACTIVE_PORT=""
  ssh_run "$rcmd" >/dev/null 2>&1 </dev/null || rc=$?
  if (( rc == 255 )); then
    warn "${name}: could not log in to ${target} (password/port/host?)."
    return 1
  elif (( rc != 0 )); then
    warn "${name}: could not write ~/.ssh/authorized_keys on ${target} (exit ${rc})."
    return 1
  fi

  if ssh_key_only_ok "${SSH_ACTIVE_HOST:-$OUT_SSH_HOST}" "${SSH_ACTIVE_PORT:-${OUT_SSH_PORT:-22}}" "$key"; then
    ok "${name}: key installed; logins no longer need the password."
    return 0
  fi
  warn "${name}: key added, but key login still fails. On OUT check sshd_config (PubkeyAuthentication yes, AuthorizedKeysFile) and home dir permissions."
  return 1
}

ssh_key_install_all_profiles(){
  local -a names=()
  local n total=0 failed=0
  # Collect first: ssh inside the loop would otherwise eat a while-read stdin.
  while read -r n; do
    n="$(safe_name "$n")"
    if [[ -n "$n" ]]; then names+=("$n"); fi
  done < <(profiles_list)
  if (( ${#names[@]} == 0 )); then
    warn "No profiles found."
    return 1
  fi
  ssh_shared_key_present || { warn "No shared SSH key yet."; return 1; }

  for n in "${names[@]}"; do
    total=$((total+1))
    # Subshell: each profile loads its own vars without touching the active one.
    if ! ( profile_load "$n" >/dev/null 2>&1 && ssh_key_install_loaded_profile ); then
      failed=$((failed+1))
    fi
  done
  hr
  if (( failed == 0 )); then
    ok "Done: ${total} profile(s)."
  else
    warn "Done: ${total} profile(s), ${failed} need attention (see above)."
  fi
  return 0
}

ssh_key_offer_install_loaded_profile(){
  # After a successful SSH check in a wizard: when a shared key exists but
  # this server does not trust it yet, offer to add it (one question).
  ssh_shared_key_present || return 0
  [[ -n "${OUT_SSH_HOST:-}" ]] || return 0
  ssh_interactive || return 0
  if ssh_key_only_ok "${SSH_ACTIVE_HOST:-$OUT_SSH_HOST}" "${SSH_ACTIVE_PORT:-${OUT_SSH_PORT:-22}}" "$(ssh_shared_key_path)"; then
    return 0
  fi
  if [[ "$(prompt_yesno "Add AZHDAR's shared SSH key to this server (no password needed later)?" "Y")" == "Y" ]]; then
    ssh_key_install_loaded_profile 1 || true
  fi
  return 0
}

ssh_key_remove(){
  local key units=""
  key="$(ssh_shared_key_path)"
  if ! ssh_shared_key_present; then
    info "No shared SSH key is set."
    return 0
  fi
  warn "Servers that only accept this key (no saved password) will become unreachable for AZHDAR."
  units="$(grep -lF "$key" /etc/systemd/system/*.service 2>/dev/null | xargs -r -n1 basename 2>/dev/null | tr '\n' ' ' || true)"
  if [[ -n "$units" ]]; then
    warn "Still used by: ${units}- re-run SSH fallback setup afterwards."
  fi
  if [[ "$(prompt_yesno "Delete ${key}?" "N")" != "Y" ]]; then
    info "Cancelled."
    return 0
  fi
  rm -f "$key" "${key}.pub" 2>/dev/null || true
  ok "Shared SSH key removed."
  return 0
}

menu_ssh_key(){
  while true; do
    banner
    echo -e "${BOLD}${WHT}Shared SSH key (all OUT servers)${RST}"
    hr
    if ssh_shared_key_present; then
      echo -e "${DIM}Key:${RST} $(ssh_shared_key_path)  ${GRN}active${RST}"
      echo -e "${DIM}Fingerprint:${RST} $(ssh_key_fingerprint)"
    else
      echo -e "${DIM}Key:${RST} ${YLW}not set${RST} (logins use saved passwords only)"
    fi
    echo -e "${DIM}OUT servers that have the public key log in without a password; the saved password"
    echo -e "stays as fallback. A profile's own identity file still takes priority.${RST}"
    hr
    echo " 1) Generate new key pair (ed25519)"
    echo " 2) Import existing private key (paste or file path)"
    echo " 3) Show public key (to put on servers)"
    echo " 4) Install public key on current profile's OUT server"
    echo " 5) Install public key on ALL profiles' OUT servers"
    echo " 6) Remove shared key"
    echo " 0) Back"
    hr

    # Empty input picks the first listed option; make that the harmless one.
    local c
    c="$(read_choice "Select [3]" "3" "1" "2" "4" "5" "6" "0")"
    case "$c" in
      1) banner; if ssh_key_generate; then ssh_key_show_pub || true; fi; pause ;;
      2) banner; if ssh_key_import; then ssh_key_show_pub || true; fi; pause ;;
      3) banner; ssh_key_show_pub || true; pause ;;
      4)
        ensure_profile_selected || { pause; continue; }
        banner
        ssh_key_install_loaded_profile || true
        pause
        ;;
      5) banner; ssh_key_install_all_profiles || true; pause ;;
      6) banner; ssh_key_remove || true; pause ;;
      0) return 0 ;;
    esac
  done
}
