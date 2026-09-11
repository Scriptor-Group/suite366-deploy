#!/usr/bin/env bash
# =============================================================================
# Tests for the hostname / TLS decision logic in lib/preflight.sh.
#
# These checks exist because each one corresponds to an install that SUCCEEDS
# and then does not work, with nothing in any log to say why:
#   • mDNS names outside .local are published and resolved by nobody;
#   • .local names in dns mode are queried over multicast whatever the resolver
#     is told;
#   • a provided certificate that omits ONE of the four names looks perfectly
#     healthy until the first document is opened;
#   • proxy mode with a .local name publishes to the internet a name that
#     resolves nowhere.
#
# The functions are pulled out of lib/preflight.sh verbatim rather than copied,
# so the test cannot drift from the shipped code.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
ko() { printf '  \033[31mFAIL\033[0m %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail+1)); }

# Run one extracted function with a given environment. Prints its output;
# returns its status.
run_fn() { # run_fn FUNC 'VAR=val' ...
  local fn="$1"; shift
  env "$@" bash -c '
    set -uo pipefail
    c_b=""; c_g=""; c_y=""; c_r=""; c_0=""
    log()  { printf "==> %s\n" "$*"; }
    info() { printf "    %s\n" "$*"; }
    warn() { printf "!!  %s\n" "$*"; }
    die()  { printf "xx  %s\n" "$*" >&2; exit 1; }
    have() { command -v "$1" >/dev/null 2>&1; }
    DNS_TODO=()
    for f in check_host_mode check_tls_inputs resolve_tls_pair cert_sans \
             cert_covers_host check_proxy_addressing; do
      eval "$(sed -n "/^$f() {/,/^}/p" "$1")"
    done
    "$2"
  ' _ "$REPO/lib/preflight.sh" "$fn" 2>&1
}

H4="APP_HOST=drive.suite366.local OFFICE_HOST=office.suite366.local
    LIVEKIT_HOST=livekit.suite366.local TURN_HOST=turn.suite366.local"
D4="APP_HOST=drive.acme.internal OFFICE_HOST=office.acme.internal
    LIVEKIT_HOST=livekit.acme.internal TURN_HOST=turn.acme.internal"
P4="APP_HOST=acme.box.diwy.ai OFFICE_HOST=acme-office.box.diwy.ai
    LIVEKIT_HOST=acme-livekit.box.diwy.ai TURN_HOST=acme-turn.box.diwy.ai"

echo "== mDNS and .local are one decision, not two =="
# shellcheck disable=SC2086
run_fn check_host_mode HOST_MODE=mdns $H4 >/dev/null 2>&1 \
  && ok "mdns + .local is accepted" || ko "mdns + .local is accepted"
# shellcheck disable=SC2086
out="$(run_fn check_host_mode HOST_MODE=mdns $D4)"
[[ $? -ne 0 ]] && grep -q "requires every hostname to end in .local" <<<"$out" \
  && ok "mdns + a routable domain is refused" || ko "mdns + a routable domain is refused" "$out"
# shellcheck disable=SC2086
out="$(run_fn check_host_mode HOST_MODE=dns $H4)"
[[ $? -ne 0 ]] && grep -q "reserved for mDNS" <<<"$out" \
  && ok "dns + .local is refused" || ko "dns + .local is refused" "$out"
# shellcheck disable=SC2086
run_fn check_host_mode HOST_MODE=dns $D4 >/dev/null 2>&1 \
  && ok "dns + a routable domain is accepted" || ko "dns + a routable domain is accepted"

echo "== proxy mode =="
# shellcheck disable=SC2086
run_fn check_host_mode HOST_MODE=proxy $P4 >/dev/null 2>&1 \
  && ok "proxy + public names is accepted" || ko "proxy + public names is accepted"
# shellcheck disable=SC2086
out="$(run_fn check_host_mode HOST_MODE=proxy $H4)"
[[ $? -ne 0 ]] && grep -qi "resolves nowhere outside the LAN" <<<"$out" \
  && ok "proxy + .local is refused" || ko "proxy + .local is refused" "$out"

# In proxy mode the LAN keeps its own names, so the interesting assertion is
# which of the two stories the operator is told — and that the fallback story
# is still there for a deployment that deliberately turns the LAN names off.
# shellcheck disable=SC2086
out="$(run_fn check_proxy_addressing HOST_MODE=proxy HOST_IP=192.168.1.50 $P4 \
        LOCAL_APP_HOST=drive.suite366.local)"
grep -q "LAN keeps its own names" <<<"$out" && ok "with LAN names, it says nothing has to be configured" \
  || ko "with LAN names, it says nothing has to be configured" "$out"
grep -q "Sessions are per-name" <<<"$out" && ok "and warns that sessions do not cross" \
  || ko "and warns that sessions do not cross" "$out"
grep -q "INTERNAL resolver only" <<<"$out" && ko "it should NOT ask for DNS records" "$out" \
  || ok "and asks for no DNS records at all"

# shellcheck disable=SC2086
out="$(run_fn check_proxy_addressing HOST_MODE=proxy HOST_IP=192.168.1.50 $P4)"
grep -q "PUBLIC name only" <<<"$out" && ok "without LAN names, it says so" \
  || ko "without LAN names, it says so" "$out"
grep -q "WAN outage" <<<"$out" && ok "and what that costs" || ko "and what that costs" "$out"
grep -q "INTERNAL resolver only" <<<"$out" && ok "and falls back to asking for split-horizon" \
  || ko "and falls back to asking for split-horizon" "$out"
grep -q "192.168.1.50" <<<"$out" && ok "with this host's LAN address" \
  || ko "with this host's LAN address" "$out"

echo "== TLS modes =="
run_fn check_tls_inputs TLS_MODE=local-ca >/dev/null 2>&1 \
  && ok "local-ca is accepted" || ko "local-ca is accepted"
out="$(run_fn check_tls_inputs TLS_MODE=acme)"
[[ $? -ne 0 ]] && grep -q "not implemented" <<<"$out" \
  && ok "acme is refused, not half-implemented" || ko "acme is refused" "$out"
out="$(run_fn check_tls_inputs TLS_MODE=nonsense)"
[[ $? -ne 0 ]] && ok "an unknown TLS_MODE is refused" || ko "an unknown TLS_MODE is refused" "$out"
# pushed without proxy would leave four Secrets nobody ever replaces.
out="$(run_fn check_tls_inputs TLS_MODE=pushed HOST_MODE=dns)"
[[ $? -ne 0 ]] && grep -q "only makes sense with HOST_MODE=proxy" <<<"$out" \
  && ok "pushed outside proxy mode is refused" || ko "pushed outside proxy mode is refused" "$out"
run_fn check_tls_inputs TLS_MODE=pushed HOST_MODE=proxy >/dev/null 2>&1 \
  && ok "pushed + proxy is accepted" || ko "pushed + proxy is accepted"

echo "== a provided certificate must cover the name it will serve =="
mk() { # mk BASE CN [SAN...]
  local b="$1" cn="$2"; shift 2
  local san=""
  for h in "$@"; do san="${san:+$san,}DNS:$h"; done
  openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/$b.key" -out "$WORK/$b.crt" \
    -days 2 -subj "/CN=$cn" ${san:+-addext "subjectAltName=$san"} >/dev/null 2>&1
}
mk good drive.acme.internal drive.acme.internal office.acme.internal \
   livekit.acme.internal turn.acme.internal
mk wild '*.acme.internal' '*.acme.internal'
mk short drive.acme.internal drive.acme.internal
mk other other other.example

E="TLS_MODE=provided $D4 TLS_CA_FILE="
# shellcheck disable=SC2086
run_fn check_tls_inputs $E TLS_CERT_FILE=$WORK/good.crt TLS_KEY_FILE=$WORK/good.key >/dev/null 2>&1 \
  && ok "a four-name certificate is accepted" || ko "a four-name certificate is accepted"
# A wildcard matches one label deep, which is exactly what these names need.
# shellcheck disable=SC2086
run_fn check_tls_inputs $E TLS_CERT_FILE=$WORK/wild.crt TLS_KEY_FILE=$WORK/wild.key >/dev/null 2>&1 \
  && ok "a wildcard one label deep is accepted" || ko "a wildcard one label deep is accepted"
# shellcheck disable=SC2086
out="$(run_fn check_tls_inputs $E TLS_CERT_FILE=$WORK/short.crt TLS_KEY_FILE=$WORK/short.key)"
[[ $? -ne 0 ]] && grep -q "does not cover" <<<"$out" \
  && ok "a certificate missing three names is refused" \
  || ko "a certificate missing three names is refused" "$out"
# shellcheck disable=SC2086
out="$(run_fn check_tls_inputs $E TLS_CERT_FILE=$WORK/good.crt TLS_KEY_FILE=$WORK/other.key)"
[[ $? -ne 0 ]] && grep -q "does not match" <<<"$out" \
  && ok "a mismatched key is refused" || ko "a mismatched key is refused" "$out"
# shellcheck disable=SC2086
out="$(run_fn check_tls_inputs $E TLS_CERT_FILE=/nope.crt TLS_KEY_FILE=/nope.key)"
[[ $? -ne 0 ]] && ok "a missing certificate file is refused" \
  || ko "a missing certificate file is refused" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == "0" ]]
