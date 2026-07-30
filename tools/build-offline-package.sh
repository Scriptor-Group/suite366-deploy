#!/usr/bin/env bash
# =============================================================================
# Build a SIGNED, self-sufficient offline update package for an appliance with
# no outbound access. The result is copied to a USB drive; the appliance's
# `update.sh scan-usb` verifies it and surfaces the very same "update
# available" prompt in the admin UI as an online check would.
#
# Source of truth is channel.json — the same file the online updater polls — so
# an offline package can never describe a release the channel does not.
#
# Usage:
#   PACKAGE_PRIVATE_KEY=~/.secrets/package-release.key tools/build-offline-package.sh
#   … --arch amd64 --out /tmp/pkgs --min-from 1.8.0 --no-vllm
#
# Options:
#   --key FILE      Ed25519 private key (PEM). Default: $PACKAGE_PRIVATE_KEY
#   --arch ARCH     image platform: arm64 (default, DGX/GB10) | amd64
#   --out DIR       output directory (default: ./dist)
#   --min-from VER  refuse to apply on appliances older than VER
#   --no-vllm       skip the multi-GB vLLM image (box already runs the right one)
#   --channel FILE  channel manifest to build from (default: ./channel.json)
#
# Layout produced (see update.sh `pkg_verify` for the verifier):
#   suite366-update-<app_version>/
#   ├── manifest.json          flat JSON: channel.json keys + min_from_version
#   ├── SHA256SUMS             covers EVERY other file, manifest.json included
#   ├── SHA256SUMS.sig         raw Ed25519 signature over SHA256SUMS  <- the only sig
#   ├── chart/drive-<ver>.tgz
#   ├── images/*.tar           imported into containerd's k8s.io namespace
#   ├── docker-images/*.tar    loaded into the Docker daemon (vLLM/compose stack)
#   └── scripts/update.sh      the updater this package expects
#
# ONE signature, over SHA256SUMS. Every other file earns trust from a checksum
# line inside that signed list, so there is no ambiguity about which signature
# is authoritative and a file the builder forgot to list is simply not trusted.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

KEY="${PACKAGE_PRIVATE_KEY:-}"
ARCH="arm64"
OUT="$REPO_ROOT/dist"
MIN_FROM=""
WITH_VLLM=1
CHANNEL_FILE="$REPO_ROOT/channel.json"

c_b="\033[1m"; c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_0="\033[0m"
log()  { printf "${c_g}==>${c_0} ${c_b}%s${c_0}\n" "$*"; }
info() { printf "    %s\n" "$*"; }
warn() { printf "${c_y}!!  %s${c_0}\n" "$*"; }
die()  { printf "${c_r}xx  %s${c_0}\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --key)       KEY="$2"; shift 2 ;;
    --arch)      ARCH="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    --min-from)  MIN_FROM="$2"; shift 2 ;;
    --channel)   CHANNEL_FILE="$2"; shift 2 ;;
    --no-vllm)   WITH_VLLM=0; shift ;;
    -h|--help)   sed -n '2,40p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)           die "unknown option: $1" ;;
  esac
done

for t in helm docker openssl sha256sum; do have "$t" || die "$t required."; done
[[ -n "$KEY" ]]  || die "no signing key: pass --key or set PACKAGE_PRIVATE_KEY."
[[ -s "$KEY" ]]  || die "signing key not readable: $KEY"
[[ -s "$CHANNEL_FILE" ]] || die "channel manifest not found: $CHANNEL_FILE"
case "$ARCH" in arm64|amd64) ;; *) die "--arch must be arm64 or amd64." ;; esac

# Same minimal flat-JSON reader as update.sh, for the same reason (no jq
# dependency) and so both sides agree on what a manifest key means.
json_get() { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1; }
json_esc() {
  local s=${1//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; printf '%s' "$s"
}

CHANNEL="$(json_get channel        < "$CHANNEL_FILE")"
CHART_VERSION="$(json_get chart_version < "$CHANNEL_FILE")"
APP_VERSION="$(json_get app_version < "$CHANNEL_FILE")"
VLLM_IMAGE="$(json_get vllm_image   < "$CHANNEL_FILE")"
NOTES="$(json_get notes             < "$CHANNEL_FILE")"
CHART_REF="${CHART_REF:-oci://ghcr.io/scriptor-group/chart/drive}"
[[ -n "$CHART_VERSION" && -n "$APP_VERSION" ]] \
  || die "channel.json must carry chart_version and app_version."

PKG_NAME="suite366-update-$APP_VERSION"
PKG="$OUT/$PKG_NAME"

log "Building $PKG_NAME"
info "channel      : ${CHANNEL:-?}"
info "chart        : $CHART_VERSION"
info "app          : $APP_VERSION"
info "vLLM image   : ${VLLM_IMAGE:-none}$([[ "$WITH_VLLM" == 0 ]] && echo ' (skipped)')"
info "platform     : linux/$ARCH"
[[ -n "$MIN_FROM" ]] && info "min_from     : $MIN_FROM"

# A stale directory would leave orphaned files that SHA256SUMS still covers.
rm -rf "$PKG"
mkdir -p "$PKG"/{chart,images,docker-images,scripts}

# --- Chart -------------------------------------------------------------------
log "Pulling chart $CHART_VERSION"
helm pull "$CHART_REF" --version "$CHART_VERSION" -d "$PKG/chart" \
  || die "helm pull failed for $CHART_REF --version $CHART_VERSION"

# --- Images ------------------------------------------------------------------
# Enumerate from the chart itself (rendered with the appliance's own values) so
# a new sidecar added upstream lands in the package without editing this script.
# `helm template` needs no cluster.
log "Enumerating images from the rendered chart"
rendered="$(mktemp)"
trap 'rm -f "$rendered"' EXIT
# The repo's values.yaml carries @TOKEN@ placeholders that are not valid YAML
# values for every field; substitute the few that matter for image resolution
# and let the rest render as literals (we only read `image:` lines back out).
sed -e "s|@DOMAIN@|suite366.local|g" \
    -e "s|@HOST_IP@|127.0.0.1|g" -e "s|@SUITE_IP@|10.99.0.1|g" \
    -e "s|@PROXY_PORT@|8000|g" -e "s|@LLM_MODEL@|m|g" -e "s|@EMBED_MODEL@|m|g" \
    -e "s|@VLLM_API_KEY@|x|g" -e "s|@VLLM_EMBEDDING_DIMENSIONS@|4096|g" \
    -e "s|@VLLM_MAX_CONTEXT_WINDOW@|200000|g" -e "s|@LICENSE_PUBLIC_KEY@|x|g" \
    -e "s|@SANDBOX_NAMESPACE@|sandbox|g" -e "s|@DATA_DIR@|/opt/suite366|g" \
    "$REPO_ROOT/values.yaml" > "$rendered"

mapfile -t images < <(
  helm template pkg "$PKG/chart"/*.tgz -f "$rendered" 2>/dev/null \
    | sed -n 's/^[[:space:]]*image:[[:space:]]*"\?\([^"[:space:]]*\)"\?.*/\1/p' \
    | sort -u
)
[[ ${#images[@]} -gt 0 ]] || die "no images resolved from the chart — check values rendering."

# Images Helm never schedules but the box needs offline: the livekit
# initContainer and the sandbox runner (spawned on demand by sandbox-api).
# Kept in sync with prepull_images() in lib/suite.sh.
images+=( "busybox:1.37" "ghcr.io/scriptor-group/suite-366-sandbox-runner:$APP_VERSION" )
mapfile -t images < <(printf '%s\n' "${images[@]}" | sort -u)

info "${#images[@]} image(s) to export"
for img in "${images[@]}"; do
  # One tar per image: a single multi-image archive would force a full re-export
  # on any change, and `ctr images import` is happy to take them one by one.
  safe="$(printf '%s' "$img" | tr '/:' '__')"
  log "docker pull $img (linux/$ARCH)"
  docker pull --platform "linux/$ARCH" "$img" >/dev/null \
    || die "docker pull failed: $img"
  docker save "$img" -o "$PKG/images/$safe.tar" || die "docker save failed: $img"
  info "  -> images/$safe.tar ($(du -h "$PKG/images/$safe.tar" | cut -f1))"
done

if [[ "$WITH_VLLM" == 1 && -n "$VLLM_IMAGE" ]]; then
  safe="$(printf '%s' "$VLLM_IMAGE" | tr '/:' '__')"
  log "docker pull $VLLM_IMAGE (linux/$ARCH) — several GB"
  docker pull --platform "linux/$ARCH" "$VLLM_IMAGE" >/dev/null \
    || die "docker pull failed: $VLLM_IMAGE"
  docker save "$VLLM_IMAGE" -o "$PKG/docker-images/$safe.tar" \
    || die "docker save failed: $VLLM_IMAGE"
  info "  -> docker-images/$safe.tar ($(du -h "$PKG/docker-images/$safe.tar" | cut -f1))"
else
  rmdir "$PKG/docker-images"
fi

# --- Updater -----------------------------------------------------------------
# The appliance installs THIS update.sh after applying the package: it is the
# only signed path to move the updater forward on an air-gapped box.
install -m 0644 "$REPO_ROOT/update.sh" "$PKG/scripts/update.sh"
bash -n "$PKG/scripts/update.sh" || die "bundled update.sh does not parse."

# --- Manifest ----------------------------------------------------------------
cat > "$PKG/manifest.json" <<EOF
{
  "schema": 1,
  "channel": "$(json_esc "$CHANNEL")",
  "chart_version": "$(json_esc "$CHART_VERSION")",
  "app_version": "$(json_esc "$APP_VERSION")",
  "vllm_image": "$(json_esc "$([[ "$WITH_VLLM" == 1 ]] && printf '%s' "$VLLM_IMAGE")")",
  "notes": "$(json_esc "$NOTES")",
  "min_from_version": "$(json_esc "$MIN_FROM")",
  "platform": "linux/$ARCH",
  "built_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
EOF

# --- Sign --------------------------------------------------------------------
log "Checksumming + signing"
( cd "$PKG" && find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.sig -print0 \
    | sort -z | xargs -0 sha256sum > SHA256SUMS )
grep -qE '[[:space:]]\*?\./?manifest\.json$' "$PKG/SHA256SUMS" \
  || die "internal error: manifest.json missing from SHA256SUMS."

openssl pkeyutl -sign -rawin -inkey "$KEY" \
  -in "$PKG/SHA256SUMS" -out "$PKG/SHA256SUMS.sig" \
  || die "signing failed — is $KEY an Ed25519 private key?"

# Fail here rather than on the appliance: verify with the public half now.
pub="$(mktemp)"
openssl pkey -in "$KEY" -pubout -out "$pub" 2>/dev/null || die "cannot derive the public key."
openssl pkeyutl -verify -rawin -pubin -inkey "$pub" \
  -sigfile "$PKG/SHA256SUMS.sig" -in "$PKG/SHA256SUMS" >/dev/null 2>&1 \
  || { rm -f "$pub"; die "self-verification failed — the package would be refused."; }
rm -f "$pub"
( cd "$PKG" && sha256sum -c --strict --quiet SHA256SUMS ) \
  || die "self-verification failed — checksums do not match their own files."

log "Package ready: $PKG"
info "size: $(du -sh "$PKG" | cut -f1)"
info "Copy the DIRECTORY to the root of a USB drive (FAT32/exFAT/ext4), then plug"
info "it into the appliance — or run: sudo /opt/suite366/update.sh scan-usb <mount>"
