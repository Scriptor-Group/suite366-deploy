#!/usr/bin/env bash
# =============================================================================
# Sign channel.json, so an appliance can trust what it is told to run.
#
#   PACKAGE_PRIVATE_KEY=~/.secrets/package-release.key tools/sign-channel.sh
#
# Two holes, one signature:
#
#   1. THE MANIFEST ITSELF. Whoever controls MANIFEST_URL decides the chart
#      version and the vLLM image every appliance is told to run. TLS proves we
#      reached the right host; it says nothing about who wrote the file.
#   2. THE UPDATER. `update.sh` is fetched over HTTPS and then runs as root on the
#      next apply. Rather than a second detached signature, the manifest carries
#      `updater_sha256` — covered by the manifest's own signature — so verifying
#      the manifest transitively verifies the updater.
#
# This script therefore, in order:
#   • recomputes `updater_sha256` from the update.sh in this repo,
#   • signs the resulting channel.json,
#   • verifies its own output, then re-checks it the way an appliance would.
#
# Both channel.json and channel.json.sig must be published together. An appliance
# holding our public key REFUSES an unsigned or stale-signed channel (fail
# closed), so publishing one without the other stops the fleet rather than
# breaking it silently.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KEY="${PACKAGE_PRIVATE_KEY:-}"
CHANNEL="$REPO_ROOT/channel.json"
UPDATER="$REPO_ROOT/update.sh"

c_b="\033[1m"; c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_0="\033[0m"
log()  { printf "${c_g}==>${c_0} ${c_b}%s${c_0}\n" "$*"; }
info() { printf "    %s\n" "$*"; }
warn() { printf "${c_y}!!  %s${c_0}\n" "$*"; }
die()  { printf "${c_r}xx  %s${c_0}\n" "$*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)     KEY="$2"; shift 2 ;;
    --channel) CHANNEL="$2"; shift 2 ;;
    --updater) UPDATER="$2"; shift 2 ;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v openssl >/dev/null || die "openssl required."
[[ -n "$KEY" ]]   || die "no signing key: pass --key or set PACKAGE_PRIVATE_KEY."
[[ -s "$KEY" ]]   || die "signing key not readable: $KEY"
[[ -s "$CHANNEL" ]] || die "channel manifest not found: $CHANNEL"
[[ -s "$UPDATER" ]] || die "updater not found: $UPDATER"

# --- 1. Pin the updater ------------------------------------------------------
bash -n "$UPDATER" || die "$UPDATER does not parse — refusing to publish it."
sha="$(sha256sum "$UPDATER" | awk '{print $1}')"
log "Pinning updater_sha256"
info "$(basename "$UPDATER") -> $sha"

if grep -q '"updater_sha256"' "$CHANNEL"; then
  # In place, preserving the rest of the file byte for byte — the signature is
  # over exact bytes, so a reformat here is a needless churn in every diff.
  sed -i -E "s|(\"updater_sha256\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")|\1$sha\2|" "$CHANNEL"
else
  die "$CHANNEL has no updater_sha256 field — add \"updater_sha256\": \"\" first."
fi

got="$(sed -n 's/.*"updater_sha256"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CHANNEL" | head -1)"
[[ "$got" == "$sha" ]] || die "failed to write updater_sha256 into $CHANNEL (got '$got')."

# --- 2. Sign ------------------------------------------------------------------
log "Signing $(basename "$CHANNEL")"
openssl pkeyutl -sign -rawin -inkey "$KEY" \
  -in "$CHANNEL" -out "$CHANNEL.sig" \
  || die "signing failed — is $KEY an Ed25519 private key?"

# --- 3. Verify our own output, as the appliance will --------------------------
pub="$(mktemp)"; trap 'rm -f "$pub"' EXIT
openssl pkey -in "$KEY" -pubout -out "$pub" 2>/dev/null || die "cannot derive the public key."
openssl pkeyutl -verify -rawin -pubin -inkey "$pub" \
  -sigfile "$CHANNEL.sig" -in "$CHANNEL" >/dev/null 2>&1 \
  || die "self-verification failed — appliances would refuse this channel."

log "Signed and verified"
info "$CHANNEL"
info "$CHANNEL.sig"
printf '\n'
warn "Publish BOTH files together, and in this order matters little — but never one alone:"
warn "  an appliance holding the public key refuses an unsigned or mismatched channel,"
warn "  which stops the fleet from updating rather than letting it update wrongly."
info "Sanity check as an appliance sees it:"
info "  curl -fsSL <MANIFEST_URL>     -o /tmp/c.json"
info "  curl -fsSL <MANIFEST_URL>.sig -o /tmp/c.sig"
info "  openssl pkeyutl -verify -rawin -pubin -inkey package-release.pub \\"
info "    -sigfile /tmp/c.sig -in /tmp/c.json"
