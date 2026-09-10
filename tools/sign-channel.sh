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
#   2. THE SCRIPTS THAT RUN AS ROOT. `update.sh` and `backup.sh` are fetched over
#      HTTPS and then run as root — the updater on the next apply, the backup
#      agent every night with the destination's credentials. Rather than a
#      detached signature each, the manifest carries `updater_sha256` and
#      `backup_sha256` — covered by the manifest's own signature — so verifying
#      the manifest transitively verifies both scripts.
#
#      backup.sh is pinned for a second reason beyond trust: update.sh rolls
#      itself forward on every apply, so without a hash to fetch against, a box
#      would move to a new updater while keeping whatever backup agent it was
#      installed with — and nothing would say so. A box that quietly stops being
#      backed up is worse than one that never was.
#
# This script therefore, in order:
#   • recomputes `updater_sha256` from the update.sh in this repo,
#   • recomputes `backup_sha256`  from the backup.sh in this repo,
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
BACKUP="$REPO_ROOT/backup.sh"

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
    --backup)  BACKUP="$2";  shift 2 ;;
    -h|--help) sed -n '2,36p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

command -v openssl >/dev/null || die "openssl required."
[[ -n "$KEY" ]]   || die "no signing key: pass --key or set PACKAGE_PRIVATE_KEY."
[[ -s "$KEY" ]]   || die "signing key not readable: $KEY"
[[ -s "$CHANNEL" ]] || die "channel manifest not found: $CHANNEL"
[[ -s "$UPDATER" ]] || die "updater not found: $UPDATER"
[[ -s "$BACKUP" ]]  || die "backup agent not found: $BACKUP"

# --- 1. Pin the scripts the appliance fetches and runs as root ----------------
# Both are pinned the same way, and a missing field is fatal rather than skipped:
# an appliance that holds the package key refuses to refresh a script the signed
# manifest does not vouch for, so publishing a channel without one of these
# fields stops that script from ever rolling forward — silently, on every box.
pin_script() { # pin_script FIELD FILE
  local field="$1" file="$2" sha got tmp
  bash -n "$file" || die "$file does not parse — refusing to publish it."
  sha="$(sha256sum "$file" | awk '{print $1}')"
  info "$(basename "$file") -> $sha"

  grep -q "\"$field\"" "$CHANNEL" \
    || die "$CHANNEL has no $field field — add \"$field\": \"\" first."

  # In place, preserving the rest of the file byte for byte — the signature is
  # over exact bytes, so a reformat here is needless churn in every diff.
  # Not `sed -i`: GNU sed takes no argument there, BSD sed (macOS) demands one,
  # and a release can be cut from either. Rewrite through a temp file instead,
  # then `cat` it back so $CHANNEL keeps its inode and mode.
  tmp="$(mktemp)"
  sed -E "s|(\"$field\"[[:space:]]*:[[:space:]]*\")[^\"]*(\")|\\1$sha\\2|" \
    "$CHANNEL" > "$tmp" && cat "$tmp" > "$CHANNEL"
  rm -f "$tmp"

  got="$(sed -n "s/.*\"$field\"[[:space:]]*:[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$CHANNEL" | head -1)"
  [[ "$got" == "$sha" ]] || die "failed to write $field into $CHANNEL (got '$got')."
}

log "Pinning the scripts an appliance fetches"
pin_script updater_sha256 "$UPDATER"
pin_script backup_sha256  "$BACKUP"

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
