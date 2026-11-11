#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat >"$TMP/iptables" <<'MOCK'
#!/usr/bin/env bash
if [[ "$*" == "-S INPUT" ]]; then
  cat <<'RULES'
-A INPUT -p tcp --dport 22 -m comment --comment "AZHDAR:test-SSH-GUARD" -j ACCEPT
-A INPUT -p tcp --dport 8443 -m comment --comment "AZHDAR:test" -j ACCEPT
RULES
  exit 0
fi
printf '%s\n' "$*" >>"${IPTABLES_TEST_LOG}"
MOCK
chmod +x "$TMP/iptables"
export PATH="$TMP:$PATH" IPTABLES_TEST_LOG="$TMP/deletes.log"

step(){ :; }
ok(){ :; }
warn(){ :; }
profile_save(){ :; }
TAG="AZHDAR"
RULE_TAG="AZHDAR:test"
FORWARD_TCP_PORTS=""
FORWARD_UDP_PORTS=""
WG_IF="testwg"

# shellcheck source=../lib/ports.sh
source "$ROOT/lib/ports.sh"
# shellcheck source=../lib/firewall.sh
source "$ROOT/lib/firewall.sh"

remove_allow_rules_local
grep -q -- '--dport 8443' "$IPTABLES_TEST_LOG"
if grep -q -- '--dport 22' "$IPTABLES_TEST_LOG"; then
  echo "SSH guard rule was deleted" >&2
  exit 1
fi

IR_SSH_PORT=2222
FORWARD_TCP_PORTS="22,8443,2222"
protect_ir_ssh_port
[[ "$FORWARD_TCP_PORTS" == "8443" ]]

declare -gA PORT_REG_PROFILE=() PORT_REG_KIND=()
WG_PORT=""
OUT_SSH_PORT=2200
if ports_wg_port_candidate_ok 22; then
  echo "port 22 was accepted as WG_PORT" >&2
  exit 1
fi
if ports_forward_tcp_candidate_ok 22; then
  echo "port 22 was accepted as a forward port" >&2
  exit 1
fi

echo "ssh port guard tests passed"
