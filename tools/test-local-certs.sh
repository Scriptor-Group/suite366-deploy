#!/usr/bin/env bash
# =============================================================================
# Tests for the two TLS faults that only appeared against real hardware, on the
# first `install.sh` re-run of a published GB10:
#
#   1. The LAN Certificates were requested with CLUSTER_ISSUER, which preflight
#      deliberately EMPTIES in `pushed` mode (it doubles as "annotate the
#      chart's Ingresses with this"). The API server answered
#         The Certificate "drive-local-tls" is invalid:
#         spec.issuerRef.name: Required value
#      and the install stopped there.
#
#   2. Before stopping, it had already overwritten all four public TLS Secrets
#      with the self-signed bootstrap placeholder. curl went to verify error 18
#      on every public name and stayed there; remote.sh did not notice, because
#      it compares what it fetched against its own cached copy, not against the
#      cluster. Re-running the installer must never take a working certificate
#      away.
#
# Both functions are extracted from lib/cert-manager.sh verbatim, with `kc`
# stubbed so the manifest that WOULD be applied can be read.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
ko() { printf '  \033[31mFAIL\033[0m %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail+1)); }

command -v openssl >/dev/null || { echo "openssl required"; exit 1; }
# A real certificate, so the parse check is exercised rather than mimicked.
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=test" \
  -keyout "$WORK/t.key" -out "$WORK/t.crt" >/dev/null 2>&1

run() { # run FUNC VAR=VALUE...
  local fn="$1"; shift
  # `env` is load-bearing: without it the trailing VAR=VALUE arguments are
  # taken as the command to run, every call fails, and the greps below pass or
  # fail for reasons unrelated to what is being tested.
  env WORK="$WORK" REPO="$REPO" NAMESPACE=suite366 \
  LOCAL_APP_HOST=drive.suite366.local LOCAL_OFFICE_HOST=office.suite366.local \
  LOCAL_LIVEKIT_HOST=livekit.suite366.local \
  LOCAL_APP_TLS_SECRET=drive-local-tls \
  LOCAL_OFFICE_TLS_SECRET=drive-onlyoffice-local-tls \
  LOCAL_LIVEKIT_TLS_SECRET=drive-livekit-local-tls \
  APP_TLS_SECRET=drive-tls OFFICE_TLS_SECRET=drive-onlyoffice-tls \
  LIVEKIT_TLS_SECRET=drive-livekit-tls TURN_TLS_SECRET=drive-turn-tls \
  APP_HOST=acme.box.diwy.ai OFFICE_HOST=acme-office.box.diwy.ai \
  LIVEKIT_HOST=acme-livekit.box.diwy.ai TURN_HOST=acme-turn.box.diwy.ai \
  DATA_DIR="$WORK" FN="$fn" "$@" bash -c '
    set -uo pipefail
    log() { printf "==> %s\n" "$*"; }
    info() { printf "    %s\n" "$*"; }
    warn() { printf "!!  %s\n" "$*"; }
    die()  { printf "xx  %s\n" "$*" >&2; exit 1; }
    have() { command -v "$1" >/dev/null 2>&1; }
    install_local_ca() { :; }   # helm/cert-manager are not what is under test
    # kc stub: records every manifest it is handed, answers `get secret` from
    # the SECRET_STATE map the test set up.
    kc() {
      if [[ "${1:-}" == "-n" && "${3:-}" == "get" && "${4:-}" == "secret" ]]; then
        local name="$5"
        case " ${SECRETS_WITH_CERT:-} " in
          *" $name "*) base64 -w0 < "$WORK/t.crt"; return 0 ;;
        esac
        case " ${SECRETS_EMPTY:-} " in
          *" $name "*) printf ""; return 0 ;;
        esac
        return 1
      fi
      if [[ "${1:-}" == "apply" || "${2:-}" == "apply" ]]; then cat >> "$WORK/applied.yaml"; return 0; fi
      cat >/dev/null 2>&1
      return 0
    }
    for f in secret_holds_a_certificate install_bootstrap_certs issue_local_certs; do
      eval "$(sed -n "/^$f() {/,/^}/p" "$REPO/lib/cert-manager.sh")"
    done
    "$FN"
  ' 2>&1
}

echo "== the LAN certificates must name an issuer that exists =="
: > "$WORK/applied.yaml"
# CLUSTER_ISSUER empty is not a mistake here — it is what preflight does in
# `pushed` mode, and it is the state this ran under on the box.
out="$(run issue_local_certs CLUSTER_ISSUER="" LOCAL_CLUSTER_ISSUER=suite366-local-ca)"
grep -q "issuerRef" "$WORK/applied.yaml" && ok "a Certificate is requested" \
  || ko "a Certificate is requested" "$out"
if grep -A2 "issuerRef:" "$WORK/applied.yaml" | grep -qE "^\s+name:\s*$"; then
  ko "issuerRef.name is not empty (the API server rejects that)" "$(grep -A2 issuerRef: "$WORK/applied.yaml" | head -3 | tr '\n' ' ')"
else
  ok "issuerRef.name is not empty (the API server rejects that)"
fi
grep -q "name: suite366-local-ca" "$WORK/applied.yaml" \
  && ok "and it is the local CA ClusterIssuer" || ko "and it is the local CA ClusterIssuer"
for h in drive.suite366.local office.suite366.local livekit.suite366.local; do
  grep -q -- "- $h" "$WORK/applied.yaml" && ok "  covers $h" || ko "  covers $h"
done
grep -q "turn.suite366.local" "$WORK/applied.yaml" \
  && ko "TURN gets no LAN certificate (livekit serves one)" \
  || ok "TURN gets no LAN certificate (livekit serves one)"

# The guard itself: an empty issuer must stop the install, not produce a
# manifest the API server will reject with a message about a field nobody set.
out="$(run issue_local_certs CLUSTER_ISSUER="" LOCAL_CLUSTER_ISSUER="")"
grep -q "no issuer" <<<"$out" && ok "an empty issuer fails loudly instead of at the API server" \
  || ko "an empty issuer fails loudly instead of at the API server" "$out"

echo "== a re-run must never take a working certificate away =="
: > "$WORK/applied.yaml"
out="$(run install_bootstrap_certs \
  SECRETS_WITH_CERT="drive-tls drive-onlyoffice-tls drive-livekit-tls drive-turn-tls" \
  LOCAL_APP_HOST="")"
grep -q "left alone" <<<"$out" && ok "a populated Secret is left alone" || ko "a populated Secret is left alone" "$out"
grep -q "kind: Secret\|tls.crt" "$WORK/applied.yaml" \
  && ko "nothing is written over it" "$(head -2 "$WORK/applied.yaml")" \
  || ok "nothing is written over it"
grep -q "SELF-SIGNED" <<<"$out" \
  && ko "and no misleading self-signed warning is printed" \
  || ok "and no misleading self-signed warning is printed"

: > "$WORK/applied.yaml"
out="$(run install_bootstrap_certs SECRETS_WITH_CERT="" LOCAL_APP_HOST="")"
grep -q "(bootstrap)" <<<"$out" && ok "an empty cluster still gets its bootstrap" \
  || ko "an empty cluster still gets its bootstrap" "$out"
grep -q "SELF-SIGNED" <<<"$out" && ok "  with the warning that they are self-signed" \
  || ko "  with the warning that they are self-signed" "$out"

: > "$WORK/applied.yaml"
out="$(run install_bootstrap_certs SECRETS_WITH_CERT="drive-tls" \
  SECRETS_EMPTY="drive-onlyoffice-tls" LOCAL_APP_HOST="")"
grep -q "3 bootstrapped\|1 of 4" <<<"$out" && ok "a partially-populated cluster fills only the gaps" \
  || ko "a partially-populated cluster fills only the gaps" "$out"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
