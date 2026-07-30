#!/usr/bin/env bash
# =============================================================================
# Suite 366 — update checker / applier for the DGX Spark appliance.
#
# Reads a channel manifest (channel.json) that YOU publish in the
# suite366-deploy repo, compares the target versions to what this box is
# actually running, and either:
#   • NOTIFIES (default — used by the daily systemd timer): logs + drops a
#     marker file + machine-readable state.json + optional webhook. Makes NO
#     changes.
#   • APPLIES the upgrade (manual `sudo /opt/suite366/update.sh apply`, or
#     triggered from the app UI via the apply-requested trigger file).
#
# The manifest decouples "the latest version that exists" from "the version
# the fleet should run": you push channel.json -> the fleet rolls out. No
# per-box edits, no in-the-blind tracking of `latest`.
#
# TWO SOURCES, never exclusive:
#   • ONLINE — the channel manifest over HTTPS. The normal path.
#   • USB    — a signed offline package (built by tools/build-offline-package.sh)
#     found on a removable drive. For boxes whose owner cut outbound access.
# `check` tries the network and NEVER dies when it is unreachable: a verified
# USB package still produces an "update available" state, and conversely a
# reachable network never invalidates a staged package. state.json carries both
# sources plus the resolved best target (highest app version wins; online wins a
# tie since it needs no image import).
#
# Modes:
#   check         (default) fetch manifest, load any staged offline package,
#                 compare, write marker + state.json. No changes.
#   apply         helm upgrade (+ vLLM image / app image pin updates), then a
#                 health check. Idempotent (no-op if already up to date). Uses
#                 the resolved source: OCI chart pull, or the staged package's
#                 local chart + image tars when that is the better target.
#   scan-usb DIR  verify a signed offline package under DIR, stage it into
#                 $DATA_DIR/offline/pkg, then refresh state.json so the app
#                 shows the same "update available" prompt as when online.
#                 Applies NOTHING (an admin still confirms in the UI).
#   install-units (re)install the systemd .path units that let the app UI
#                 trigger check/apply, and prepare $DATA_DIR/updates. Called by
#                 install.sh and after every apply (fleet convergence).
#
# App <-> host bridge ($DATA_DIR/updates, hostPath-mounted into drive-app at
# /appliance-update — see values.yaml `extraVolumes`):
#   state.json        written by `check`  — versions, diff summary, notes
#   apply.json        written by `apply`  — idle|running|success|error + msg
#   check-requested   written by the app  — consumed, triggers `check`
#   apply-requested   written by the app  — consumed, triggers `apply`
# The pod runs as uid/gid 1001 and k8s does NOT apply fsGroup to hostPath
# volumes, so the dir is root:1001 mode 0770 (group-writable for triggers).
#
# Config (env, or $DATA_DIR/update.env — all optional, defaults match
# install.sh):
#   MANIFEST_URL    where channel.json lives (default: raw GitHub main)
#   CHART_REF       OCI chart ref          NAMESPACE / RELEASE / DATA_DIR
#   KUBECONFIG_PATH /etc/rancher/k3s/k3s.yaml
#   UPDATE_WEBHOOK  optional URL — POSTed {"text":"…"} on update-available
#   SELF_URL        where to refresh update.sh from after an apply (default:
#                   sibling of MANIFEST_URL). Set SELF_UPDATE=0 to disable
#                   (fleet boxes do: their updater only moves with a SIGNED
#                   package, never with an unauthenticated HTTPS fetch).
#   PACKAGE_PUBLIC_KEY  PEM Ed25519 public key verifying offline packages.
#                   Absent file => every offline package is refused.
# =============================================================================
set -euo pipefail

MODE="${1:-check}"

DATA_DIR="${DATA_DIR:-/opt/suite366}"
# Pull in the install-time config if present (manual runs); the systemd units
# also pass this same file via EnvironmentFile=.
[[ -f "$DATA_DIR/update.env" ]] && . "$DATA_DIR/update.env"

MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/Scriptor-Group/suite366-deploy/main/channel.json}"
# Detached Ed25519 signature over channel.json, published beside it. Required on
# any appliance that holds PACKAGE_PUBLIC_KEY; ignored on one that does not.
MANIFEST_SIG_URL="${MANIFEST_SIG_URL:-$MANIFEST_URL.sig}"
CHART_REF="${CHART_REF:-oci://ghcr.io/scriptor-group/chart/drive}"
NAMESPACE="${NAMESPACE:-suite366}"
RELEASE="${RELEASE:-drive}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
UPDATE_WEBHOOK="${UPDATE_WEBHOOK:-}"
SELF_UPDATE="${SELF_UPDATE:-1}"
SELF_URL="${SELF_URL:-${MANIFEST_URL%/*}/update.sh}"
MARKER="$DATA_DIR/update-available"

# --- Offline (USB) package source ---------------------------------------------
# A verified package is COPIED off the removable drive into $OFFLINE_PKG so the
# key can be pulled out before an admin confirms the update in the UI, and so a
# mid-apply unplug cannot truncate an image tar. $OFFLINE_SRC records the
# outcome (including rejections, which have no staged content to speak for
# them) and is the only thing `check` needs to read.
PACKAGE_PUBLIC_KEY="${PACKAGE_PUBLIC_KEY:-$DATA_DIR/package-release.pub}"
OFFLINE_DIR="$DATA_DIR/offline"
OFFLINE_PKG="$OFFLINE_DIR/pkg"
OFFLINE_SRC="$OFFLINE_DIR/source.json"

# Shared dir with the drive-app pod (hostPath). uid/gid 1001 = runAsUser of
# the drive-app container in the chart.
UPDATES_DIR="$DATA_DIR/updates"
STATE_JSON="$UPDATES_DIR/state.json"
APPLY_JSON="$UPDATES_DIR/apply.json"
APP_GID=1001

export KUBECONFIG="$KUBECONFIG_PATH"

c_b="\033[1m"; c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_0="\033[0m"
log()  { printf "${c_g}==>${c_0} ${c_b}%s${c_0}\n" "$*"; }
info() { printf "    %s\n" "$*"; }
warn() { printf "${c_y}!!  %s${c_0}\n" "$*"; }
die()  { printf "${c_r}xx  %s${c_0}\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
kc()   { k3s kubectl "$@"; }
now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Minimal extractor for the FLAT channel.json (avoids a jq dependency — jq is
# not guaranteed on DGX OS). Reads JSON on stdin, prints the string value.
json_get() { # json_get KEY
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

# Escape a string for embedding in a JSON double-quoted value.
json_esc() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

[[ "$(id -u)" == "0" ]] || die "Run as root (sudo)."

# --- App <-> host shared dir --------------------------------------------------
ensure_updates_dir() {
  mkdir -p "$UPDATES_DIR"
  chown "root:$APP_GID" "$UPDATES_DIR"
  chmod 0770 "$UPDATES_DIR"
}

# Consume (log + delete) a trigger file dropped by the app, if present. The
# file content carries the requesting admin's email for the audit trail.
consume_trigger() { # consume_trigger FILENAME
  local f="$UPDATES_DIR/$1" who=""
  [[ -f "$f" ]] || return 0
  who="$(head -c 200 "$f" 2>/dev/null | tr -d '\r\n' || true)"
  rm -f "$f"
  info "trigger $1 consumed${who:+ (requested by: $who)}"
  logger -t suite366-update "$1 consumed${who:+ (by: $who)}" 2>/dev/null || true
}

# --- state.json / apply.json (read by the app UI) ----------------------------
write_state_json() { # write_state_json AVAILABLE(0|1)
  ensure_updates_dir
  local avail=false; [[ "$1" == "1" ]] && avail=true
  local reachable=false; [[ "${online_reachable:-0}" == "1" ]] && reachable=true
  local tmp="$STATE_JSON.tmp"
  # schema 2 adds `source` + `sources` (online / usb). Readers tolerating only
  # schema 1 keep working: every field they know is unchanged and still carries
  # the RESOLVED best-of-both target, not just the online one.
  cat > "$tmp" <<EOF
{
  "schema": 2,
  "channel": "$(json_esc "${channel:-}")",
  "checked_at": "$(now_utc)",
  "update_available": $avail,
  "summary": "$(json_esc "${summary_line:-}")",
  "notes": "$(json_esc "${notes:-}")",
  "source": "$(json_esc "${UPDATE_SOURCE:-none}")",
  "current": {
    "chart": "$(json_esc "${cur_chart:-}")",
    "app": "$(json_esc "${cur_app:-}")",
    "vllm": "$(json_esc "${cur_vllm:-}")"
  },
  "target": {
    "chart": "$(json_esc "${want_chart:-}")",
    "app": "$(json_esc "${want_app:-}")",
    "vllm": "$(json_esc "${want_vllm:-}")"
  },
  "sources": {
    "online": {
      "reachable": $reachable,
      "error": "$(json_esc "${online_error:-}")",
      "chart": "$(json_esc "${online_chart:-}")",
      "app": "$(json_esc "${online_app:-}")",
      "vllm": "$(json_esc "${online_vllm:-}")"
    },
    "usb": {
      "status": "$(json_esc "${usb_status:-none}")",
      "error": "$(json_esc "${usb_error:-}")",
      "label": "$(json_esc "${usb_label:-}")",
      "chart": "$(json_esc "${usb_chart:-}")",
      "app": "$(json_esc "${usb_app:-}")",
      "vllm": "$(json_esc "${usb_vllm:-}")",
      "verified_at": "$(json_esc "${usb_verified_at:-}")"
    }
  }
}
EOF
  chmod 0644 "$tmp"; mv -f "$tmp" "$STATE_JSON"
}

APPLY_STARTED_AT=""
write_apply_json() { # write_apply_json STATUS MESSAGE
  ensure_updates_dir
  local status="$1" message="$2" finished=""
  case "$status" in success|error) finished="$(now_utc)";; esac
  local tmp="$APPLY_JSON.tmp"
  cat > "$tmp" <<EOF
{
  "schema": 1,
  "status": "$(json_esc "$status")",
  "message": "$(json_esc "$message")",
  "started_at": "$(json_esc "${APPLY_STARTED_AT:-}")",
  "finished_at": "$(json_esc "$finished")",
  "updated_at": "$(now_utc)"
}
EOF
  chmod 0644 "$tmp"; mv -f "$tmp" "$APPLY_JSON"
}

# --- Current state on this box ------------------------------------------------
read_current_state() {
  # helm list reports the chart as "<chart-name>-<version>" (e.g. drive-0.7.0);
  # grab the trailing version (first char a digit) regardless of the chart name.
  cur_chart="$(helm list -n "$NAMESPACE" --filter "^${RELEASE}$" -o json 2>/dev/null \
    | sed -n 's/.*"chart":"[^"]*-\([0-9][^"]*\)".*/\1/p' | head -1)"
  [[ -n "$cur_chart" ]] || warn "Could not read current chart version (release '$RELEASE' in ns '$NAMESPACE')."

  cur_vllm=""
  [[ -f "$DATA_DIR/llm/.env" ]] && cur_vllm="$(sed -n 's/^VLLM_IMAGE=//p' "$DATA_DIR/llm/.env" | head -1)"

  # App release train = the image tag of the RUNNING drive-app deployment.
  # Do NOT read it from the values.yaml pins: apply rewrites those BEFORE the
  # helm upgrade, so if the upgrade fails the pins are ahead of reality and a
  # re-run would wrongly conclude "up to date". Fall back to the pin only when
  # the cluster is unreadable.
  cur_app="$(kc -n "$NAMESPACE" get deploy \
    -o jsonpath='{range .items[*].spec.template.spec.containers[*]}{.image}{"\n"}{end}' 2>/dev/null \
    | sed -n 's|.*/suite-366:||p' | head -1)"
  if [[ -z "$cur_app" && -f "$DATA_DIR/values.yaml" ]]; then
    cur_app="$(sed -n 's/^  tag: "\(.*\)"/\1/p' "$DATA_DIR/values.yaml" | head -1)"
    [[ -n "$cur_app" ]] && warn "App version read from values.yaml pin (cluster unreadable) — may be ahead of the running pod."
  fi
}

# --- Version comparison --------------------------------------------------------
# True when A is strictly newer than B (dotted numeric versions; `sort -V`
# handles 1.8.9 < 1.8.10 correctly, which a string compare does not).
ver_gt() { # ver_gt A B
  [[ -n "$1" ]] || return 1
  [[ -n "$2" ]] || return 0
  [[ "$1" != "$2" ]] || return 1
  [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" == "$1" ]]
}

# --- Target state: source 1, the online channel manifest ------------------------
# Soft failure by design: a box whose owner cut outbound access must still be
# able to update from a signed USB package, so an unreachable manifest is
# RECORDED, not fatal.
fetch_manifest_online() {
  online_reachable=0; online_error=""; online_signed=0
  online_chart=""; online_app=""; online_vllm=""; online_channel=""; online_notes=""
  online_updater_sha=""
  log "Fetching channel manifest"
  info "$MANIFEST_URL"

  # To a file, not a variable: a signature is over exact bytes, and command
  # substitution strips trailing newlines.
  local tmp; tmp="$(mktemp)"
  if ! curl -fsSL -m 20 "$MANIFEST_URL" -o "$tmp" 2>/dev/null || [[ ! -s "$tmp" ]]; then
    rm -f "$tmp"
    online_error="manifest unreachable ($MANIFEST_URL)"
    warn "$online_error — offline package (if any) still applies."
    return 1
  fi

  if ! verify_manifest_signature "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  local manifest; manifest="$(cat "$tmp")"
  rm -f "$tmp"
  online_channel="$(json_get channel        <<<"$manifest")"
  online_chart="$(json_get chart_version    <<<"$manifest")"
  online_vllm="$(json_get vllm_image        <<<"$manifest")"
  online_app="$(json_get app_version        <<<"$manifest")"
  online_notes="$(json_get notes            <<<"$manifest")"
  online_updater_sha="$(json_get updater_sha256 <<<"$manifest")"
  if [[ -z "$online_chart" ]]; then
    online_error="manifest has no chart_version"
    warn "$online_error ($MANIFEST_URL)"
    return 1
  fi
  online_reachable=1
  return 0
}

# Whoever controls MANIFEST_URL decides which chart version and which vLLM image
# every appliance is told to run. TLS proves we reached the right HOST; it says
# nothing about whether the file is ours. So when the appliance holds our public
# key, the manifest must be signed by it — and a bad signature makes the manifest
# UNUSABLE rather than merely suspicious (fail closed; a verified USB package can
# still carry the box forward).
#
# Graduated on purpose: an appliance with no key installed keeps the old
# TLS-only behaviour, so the public one-command install is unchanged. Fleet boxes
# always have the key, so they are always strict.
verify_manifest_signature() { # verify_manifest_signature FILE
  local f="$1"
  if [[ ! -s "$PACKAGE_PUBLIC_KEY" ]]; then
    # Said once, not per-run-per-line: this is the documented posture of the
    # public product, not a misconfiguration.
    info "manifest       : unsigned (no $PACKAGE_PUBLIC_KEY — TLS-only trust)"
    return 0
  fi
  have openssl || { online_error="openssl missing, cannot verify the manifest signature"; warn "$online_error"; return 1; }

  local sig; sig="$(mktemp)"
  if ! curl -fsSL -m 20 "$MANIFEST_SIG_URL" -o "$sig" 2>/dev/null || [[ ! -s "$sig" ]]; then
    rm -f "$sig"
    online_error="manifest signature unavailable ($MANIFEST_SIG_URL)"
    warn "$online_error — refusing the manifest (this appliance requires signed channels)."
    return 1
  fi
  if ! openssl pkeyutl -verify -rawin -pubin -inkey "$PACKAGE_PUBLIC_KEY" \
        -sigfile "$sig" -in "$f" >/dev/null 2>&1; then
    rm -f "$sig"
    online_error="manifest signature INVALID — not signed by this appliance's key"
    warn "$online_error"
    warn "  Refusing it. Either the channel was tampered with, or it was published without signing."
    return 1
  fi
  rm -f "$sig"
  online_signed=1
  info "manifest       : signature verified"
  return 0
}

# --- Target state: source 2, a staged offline package --------------------------
load_offline_source() {
  usb_status=none; usb_error=""; usb_label=""
  usb_chart=""; usb_app=""; usb_vllm=""; usb_notes=""; usb_channel=""; usb_verified_at=""
  [[ -f "$OFFLINE_SRC" ]] || return 0
  local src; src="$(cat "$OFFLINE_SRC" 2>/dev/null)" || return 0
  usb_status="$(json_get status      <<<"$src")"
  usb_error="$(json_get error        <<<"$src")"
  usb_label="$(json_get label        <<<"$src")"
  usb_channel="$(json_get channel    <<<"$src")"
  usb_chart="$(json_get chart_version <<<"$src")"
  usb_app="$(json_get app_version    <<<"$src")"
  usb_vllm="$(json_get vllm_image    <<<"$src")"
  usb_notes="$(json_get notes        <<<"$src")"
  usb_verified_at="$(json_get verified_at <<<"$src")"
  usb_status="${usb_status:-none}"
  # A staged package whose content vanished (manual cleanup, disk wipe) must not
  # keep advertising itself.
  if [[ "$usb_status" == "ready" && ! -f "$OFFLINE_PKG/manifest.json" ]]; then
    usb_status=none; usb_error="staged package missing"
  fi
}

write_offline_source() { # write_offline_source STATUS ERROR
  mkdir -p "$OFFLINE_DIR"; chmod 0700 "$OFFLINE_DIR"
  local tmp="$OFFLINE_SRC.tmp"
  cat > "$tmp" <<EOF
{
  "schema": 1,
  "status": "$(json_esc "$1")",
  "error": "$(json_esc "$2")",
  "label": "$(json_esc "${usb_label:-}")",
  "channel": "$(json_esc "${usb_channel:-}")",
  "chart_version": "$(json_esc "${usb_chart:-}")",
  "app_version": "$(json_esc "${usb_app:-}")",
  "vllm_image": "$(json_esc "${usb_vllm:-}")",
  "notes": "$(json_esc "${usb_notes:-}")",
  "verified_at": "$(json_esc "${usb_verified_at:-}")"
}
EOF
  chmod 0600 "$tmp"; mv -f "$tmp" "$OFFLINE_SRC"
  usb_status="$1"; usb_error="$2"
}

# --- Resolve the best target across both sources -------------------------------
# Highest app version wins. On a tie the ONLINE source wins: same result, no
# multi-GB image import. A source is only a candidate if it is actually newer
# than what runs — so an online apply that overtakes a staged USB package
# silently retires it instead of proposing a downgrade.
resolve_target() {
  local online_ok=0 usb_ok=0
  [[ "${online_reachable:-0}" == "1" ]] && online_ok=1
  [[ "${usb_status:-none}" == "ready" ]] && usb_ok=1

  UPDATE_SOURCE=none
  channel=""; want_chart=""; want_app=""; want_vllm=""; notes=""

  if [[ "$online_ok" == 1 && "$usb_ok" == 1 ]]; then
    if ver_gt "$usb_app" "$online_app"; then UPDATE_SOURCE=usb; else UPDATE_SOURCE=online; fi
  elif [[ "$online_ok" == 1 ]]; then UPDATE_SOURCE=online
  elif [[ "$usb_ok" == 1 ]]; then UPDATE_SOURCE=usb
  fi

  case "$UPDATE_SOURCE" in
    online) channel="$online_channel"; want_chart="$online_chart"
            want_app="$online_app";    want_vllm="$online_vllm"; notes="$online_notes" ;;
    usb)    channel="${usb_channel:-offline}"; want_chart="$usb_chart"
            want_app="$usb_app";       want_vllm="$usb_vllm";    notes="$usb_notes" ;;
  esac
}

compute_diffs() {
  chart_diff=0; vllm_diff=0; app_diff=0; summary_line=""
  if [[ "${UPDATE_SOURCE:-none}" == "none" ]]; then
    warn "No usable update source (network unreachable, no verified offline package)."
    return 0
  fi
  info "source         : $UPDATE_SOURCE"
  info "channel        : ${channel:-?}"
  info "chart  running : ${cur_chart:-unknown}    target : ${want_chart:-?}"
  info "app    running : ${cur_app:-unknown}    target : ${want_app:-unchanged}"
  info "vLLM   running : ${cur_vllm:-unknown}    target : ${want_vllm:-unchanged}"

  [[ -n "$cur_chart" && -n "$want_chart" && "$cur_chart" != "$want_chart" ]] && chart_diff=1
  [[ -n "$want_vllm" && -n "$cur_vllm" && "$cur_vllm" != "$want_vllm" ]] && vllm_diff=1
  [[ -n "$want_app"  && -n "$cur_app"  && "$cur_app"  != "$want_app"  ]] && app_diff=1

  # One-line human summary of what's available.
  local parts=()
  [[ "$chart_diff" == 1 ]] && parts+=("chart ${cur_chart:-?} -> $want_chart")
  [[ "$app_diff"   == 1 ]] && parts+=("app ${cur_app:-?} -> $want_app")
  [[ "$vllm_diff"  == 1 ]] && parts+=("vLLM image -> $want_vllm")
  [[ "$UPDATE_SOURCE" == "usb" && ${#parts[@]} -gt 0 ]] && parts+=("from USB package")
  summary_line="$(IFS='; '; echo "${parts[*]}")"
}

# Full pipeline shared by check / apply / scan-usb.
survey() {
  read_current_state
  fetch_manifest_online || true
  load_offline_source
  resolve_target
  compute_diffs
}

up_to_date() { [[ "$chart_diff" == 0 && "$vllm_diff" == 0 && "$app_diff" == 0 ]]; }

# --- Offline package: verification + staging -----------------------------------
# Layout produced by tools/build-offline-package.sh:
#   manifest.json          flat JSON, same keys as channel.json + min_from_version
#   SHA256SUMS             covers EVERY other file, manifest.json included
#   SHA256SUMS.sig         raw Ed25519 signature over SHA256SUMS
#   chart/<name>-<ver>.tgz
#   images/*.tar           containerd/docker image exports
#   scripts/update.sh      the updater this package expects (see self_update)
#
# ONE signature, over SHA256SUMS. Everything else derives its authenticity from
# a checksum line in that signed file — so there is never a question of which
# signature is authoritative, and a file the builder forgot to list simply is
# not trusted. Verification is all-or-nothing: one bad byte anywhere and the
# whole package is refused.
pkg_error=""

# Accept either a package root or a drive whose top level holds exactly one
# (the "plug the key in and we find it" case: `./` on the drive).
pkg_root() { # pkg_root MOUNT  -> prints the package root
  local m="$1" d
  [[ -f "$m/manifest.json" ]] && { printf '%s' "$m"; return 0; }
  for d in "$m"/suite366-update-*/; do
    [[ -f "$d/manifest.json" ]] && { printf '%s' "${d%/}"; return 0; }
  done
  return 1
}

pkg_verify() { # pkg_verify ROOT — sets pkg_* on success, pkg_error on failure
  local root="$1" f
  pkg_error=""
  pkg_chart=""; pkg_app=""; pkg_vllm=""; pkg_channel=""; pkg_notes=""; pkg_min_from=""

  if [[ ! -s "$PACKAGE_PUBLIC_KEY" ]]; then
    pkg_error="no package signing key on this appliance ($PACKAGE_PUBLIC_KEY)"; return 1
  fi
  for f in manifest.json SHA256SUMS SHA256SUMS.sig; do
    [[ -s "$root/$f" ]] || { pkg_error="incomplete package: $f missing"; return 1; }
  done

  # 1. Is the checksum list itself authentic?
  if ! openssl pkeyutl -verify -rawin -pubin -inkey "$PACKAGE_PUBLIC_KEY" \
        -sigfile "$root/SHA256SUMS.sig" -in "$root/SHA256SUMS" >/dev/null 2>&1; then
    pkg_error="signature check failed — package not signed by this appliance's key"; return 1
  fi
  # 2. Is the manifest actually covered by it? (a manifest outside SHA256SUMS
  #    would be attacker-controlled while everything else verified fine)
  if ! grep -qE '[[:space:]]\*?\./?manifest\.json$' "$root/SHA256SUMS"; then
    pkg_error="manifest.json is not covered by the signed SHA256SUMS"; return 1
  fi
  # 3. Does every listed file match?
  if ! ( cd "$root" && sha256sum -c --strict --quiet SHA256SUMS ) >/dev/null 2>&1; then
    pkg_error="checksum mismatch — package corrupt or truncated"; return 1
  fi

  local mf; mf="$(cat "$root/manifest.json")"
  pkg_channel="$(json_get channel        <<<"$mf")"
  pkg_chart="$(json_get chart_version    <<<"$mf")"
  pkg_app="$(json_get app_version        <<<"$mf")"
  pkg_vllm="$(json_get vllm_image        <<<"$mf")"
  pkg_notes="$(json_get notes            <<<"$mf")"
  pkg_min_from="$(json_get min_from_version <<<"$mf")"
  [[ -n "$pkg_chart" && -n "$pkg_app" ]] \
    || { pkg_error="manifest lacks chart_version / app_version"; return 1; }

  # Exactly one chart archive, or `helm upgrade` would be ambiguous.
  local charts=( "$root"/chart/*.tgz )
  [[ -f "${charts[0]:-}" ]] || { pkg_error="no chart archive under chart/"; return 1; }
  [[ ${#charts[@]} -eq 1 ]] || { pkg_error="${#charts[@]} chart archives found, expected 1"; return 1; }

  # 4. Version policy. A strict downgrade is refused outright: rolling the app
  #    backwards past a Prisma migration is not recoverable from the UI.
  if [[ -n "$cur_app" ]] && ver_gt "$cur_app" "$pkg_app"; then
    pkg_error="package targets app $pkg_app but $cur_app is installed (downgrade refused)"; return 1
  fi
  if [[ -n "$pkg_min_from" && -n "$cur_app" ]] && ver_gt "$pkg_min_from" "$cur_app"; then
    pkg_error="package requires app >= $pkg_min_from first (installed: $cur_app)"; return 1
  fi
  return 0
}

# Copy a verified package off the removable drive, then re-verify the COPY: a
# key pulled mid-copy, or a drive that lies about writes, both show up here.
pkg_stage() { # pkg_stage ROOT
  local root="$1" need avail
  # `|| true` guards: a failing pipeline inside an assignment would abort the
  # whole script under `set -e` (see the same note in lib/preflight.sh).
  need="$(du -sk "$root" 2>/dev/null | cut -f1 || true)"; need="${need:-0}"
  avail="$(df -Pk "$DATA_DIR" 2>/dev/null | awk 'NR==2{print $4}' || true)"; avail="${avail:-0}"
  if (( avail < need * 12 / 10 )); then
    pkg_error="not enough free space in $DATA_DIR ($((need/1024)) MiB needed, $((avail/1024)) MiB free)"
    return 1
  fi
  mkdir -p "$OFFLINE_DIR"; chmod 0700 "$OFFLINE_DIR"
  rm -rf "$OFFLINE_PKG.new"
  log "Staging package into $OFFLINE_PKG ($((need/1024)) MiB)"
  cp -a "$root/." "$OFFLINE_PKG.new/" || { pkg_error="copy from the drive failed"; return 1; }
  if ! ( cd "$OFFLINE_PKG.new" && sha256sum -c --strict --quiet SHA256SUMS ) >/dev/null 2>&1; then
    rm -rf "$OFFLINE_PKG.new"
    pkg_error="staged copy failed verification — drive removed mid-copy?"; return 1
  fi
  rm -rf "$OFFLINE_PKG"
  mv "$OFFLINE_PKG.new" "$OFFLINE_PKG"
  return 0
}

do_scan_usb() { # do_scan_usb MOUNT
  local mount="${1:-}"
  [[ -n "$mount" ]] || die "scan-usb needs a directory (usage: update.sh scan-usb /mnt/key)"
  [[ -d "$mount" ]] || die "not a directory: $mount"

  read_current_state
  load_offline_source

  local root
  if ! root="$(pkg_root "$mount")"; then
    info "no offline package found under $mount — nothing to do."
    return 0
  fi
  log "Offline package found: $root"
  usb_label="$(basename "$root")"

  if pkg_verify "$root"; then
    usb_channel="$pkg_channel"; usb_chart="$pkg_chart"; usb_app="$pkg_app"
    usb_vllm="$pkg_vllm";       usb_notes="$pkg_notes"
    if pkg_stage "$root"; then
      usb_verified_at="$(now_utc)"
      write_offline_source ready ""
      log "Package verified and staged: app $pkg_app, chart $pkg_chart"
      logger -t suite366-update "offline package staged: $usb_label (app $pkg_app)" 2>/dev/null || true
    else
      write_offline_source rejected "$pkg_error"
      warn "Package REJECTED: $pkg_error"
      logger -t suite366-update "offline package rejected: $usb_label ($pkg_error)" 2>/dev/null || true
    fi
  else
    # Keep the versions we could not trust out of state.json.
    usb_channel=""; usb_chart=""; usb_app=""; usb_vllm=""; usb_notes=""; usb_verified_at=""
    write_offline_source rejected "$pkg_error"
    warn "Package REJECTED: $pkg_error"
    logger -t suite366-update "offline package rejected: $usb_label ($pkg_error)" 2>/dev/null || true
  fi

  # Refresh the app-facing state either way: a rejection must be visible in the
  # UI, not just in the journal.
  fetch_manifest_online || true
  load_offline_source
  resolve_target
  compute_diffs
  if up_to_date; then write_state_json 0; else write_state_json 1; fi
}

# --- check (notify-only) -------------------------------------------------------
notify() {
  consume_trigger check-requested
  if [[ "${UPDATE_SOURCE:-none}" == "none" ]]; then
    # Neither source usable. Report it as a failed check rather than "up to
    # date" — silently claiming health while blind is how a fleet drifts.
    warn "Update check inconclusive: ${online_error:-no source}${usb_error:+ / USB: $usb_error}"
    rm -f "$MARKER"
    write_state_json 0
    return 0
  fi
  if up_to_date; then
    log "Up to date (chart ${cur_chart:-?}, app ${cur_app:-?}, channel ${channel:-?})."
    rm -f "$MARKER"
    write_state_json 0
    return 0
  fi
  warn "UPDATE AVAILABLE (channel ${channel:-?}): $summary_line"
  ( umask 077
    cat > "$MARKER" <<EOF
Suite 366 update available — channel ${channel:-?}
  $summary_line
Apply with:  sudo $DATA_DIR/update.sh apply
EOF
  )
  write_state_json 1
  logger -t suite366-update "update available: $summary_line" 2>/dev/null || true
  if [[ -n "$UPDATE_WEBHOOK" ]]; then
    curl -fsS -m 10 -H 'Content-Type: application/json' \
      -d "{\"text\":\"Suite 366 update available ($(hostname)): $summary_line\"}" \
      "$UPDATE_WEBHOOK" >/dev/null 2>&1 \
      && info "webhook notified." || warn "webhook POST failed (non-blocking)."
  fi
  info "Run 'sudo $DATA_DIR/update.sh apply' to upgrade (or use the app's admin UI)."
}

# --- apply ---------------------------------------------------------------------
# Legacy values.yaml (rendered before the appliance-update bridge existed)
# lacks the hostPath mount — inject it via an overlay so the fleet converges
# on its next apply. Fresh installs carry the block in values.yaml directly.
extra_vals=()
ensure_appliance_values() {
  local vals="$DATA_DIR/values.yaml"
  grep -q 'name: appliance-update' "$vals" && return 0
  local ov="$DATA_DIR/values-appliance-update.yaml"
  ( umask 077
    cat > "$ov" <<EOF
# Generated by update.sh — app <-> host update bridge (see suite366-deploy).
extraEnv:
  - name: APPLIANCE_UPDATE_DIR
    value: /appliance-update
extraVolumeMounts:
  - name: appliance-update
    mountPath: /appliance-update
extraVolumes:
  - name: appliance-update
    hostPath:
      path: $UPDATES_DIR
      type: DirectoryOrCreate
EOF
  )
  extra_vals=(-f "$ov")
  info "appliance-update bridge overlay added ($ov)."
}

apply_exit_trap() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    write_apply_json error "update failed (exit $rc) — see 'journalctl -t suite366-update' / 'journalctl -u suite366-update-apply' on the appliance" || true
  fi
}

do_apply() {
  local vals="$DATA_DIR/values.yaml"
  [[ -f "$vals" ]] || die "values.yaml not found at $vals — was this box installed by install.sh?"

  consume_trigger apply-requested

  if [[ "${UPDATE_SOURCE:-none}" == "none" ]]; then
    write_apply_json error "no usable update source: ${online_error:-network unreachable}${usb_error:+ / USB: $usb_error}"
    die "Nothing to apply: no reachable channel and no verified offline package."
  fi

  if up_to_date; then
    log "Up to date (chart ${cur_chart:-?}, app ${cur_app:-?}) — nothing to apply."
    rm -f "$MARKER"
    write_state_json 0
    write_apply_json idle "already up to date (chart ${cur_chart:-?}, app ${cur_app:-?})"
    install_units
    self_update
    return 0
  fi

  APPLY_STARTED_AT="$(now_utc)"
  write_apply_json running "applying: $summary_line"
  trap apply_exit_trap EXIT

  # Offline source: load every bundled image FIRST, so the helm upgrade and the
  # compose recreate below find them locally and never reach for a registry.
  if [[ "$UPDATE_SOURCE" == "usb" ]]; then
    import_package_images
  fi

  if [[ "$vllm_diff" == 1 ]]; then
    log "vLLM image: $cur_vllm -> $want_vllm"
    [[ -f "$DATA_DIR/llm/.env" ]] || die "$DATA_DIR/llm/.env missing — cannot retarget vLLM image."
    sed -i "s|^VLLM_IMAGE=.*|VLLM_IMAGE=$want_vllm|" "$DATA_DIR/llm/.env"
    # Offline: the image is already loaded, so `pull` would only fail. Online:
    # pull first so a bad tag surfaces before the containers are torn down.
    local vllm_ok=0
    if [[ "$UPDATE_SOURCE" == "usb" ]]; then
      ( cd "$DATA_DIR/llm" && docker compose up -d ) && vllm_ok=1
    else
      ( cd "$DATA_DIR/llm" && docker compose pull && docker compose up -d ) && vllm_ok=1
    fi
    if [[ "$vllm_ok" == 1 ]]; then
      info "vLLM containers recreated."
    else
      warn "vLLM image update failed — check: docker logs suite366-vllm-llm"
    fi
  fi

  if [[ "$app_diff" == 1 ]]; then
    # The appliance pins the app + sandbox images in values.yaml (offline
    # safety) — move the pins to the new release train before the upgrade.
    log "App release: $cur_app -> $want_app (rewriting values.yaml pins)"
    sed -i "s|^  tag: \".*\"|  tag: \"$want_app\"|" "$vals"
    sed -i "s|\(suite-366-sandbox-api:\)[^\"[:space:]]*|\1$want_app|" "$vals"
    sed -i "s|\(suite-366-sandbox-runner:\)[^\"[:space:]]*|\1$want_app|" "$vals"
  fi

  if [[ "$chart_diff" == 1 || "$app_diff" == 1 ]]; then
    ensure_appliance_values
    log "helm upgrade $RELEASE: chart ${cur_chart:-?} -> $want_chart, app ${cur_app:-?} -> ${want_app:-unchanged}"
    # Offline: the chart comes from the signed package as a local .tgz, so no
    # `--version` (the archive IS the version) and no OCI pull.
    local chart_args=()
    if [[ "$UPDATE_SOURCE" == "usb" ]]; then
      local pkg_charts=( "$OFFLINE_PKG"/chart/*.tgz )
      [[ -f "${pkg_charts[0]:-}" ]] || die "staged package has no chart archive."
      chart_args=( "${pkg_charts[0]}" )
      info "chart from package: $(basename "${pkg_charts[0]}")"
    else
      chart_args=( "$CHART_REF" --version "$want_chart" )
    fi
    helm upgrade "$RELEASE" "${chart_args[@]}" \
      -n "$NAMESPACE" -f "$vals" "${extra_vals[@]}" \
      --wait --timeout 15m \
      || die "helm upgrade failed — roll back with: sudo helm rollback $RELEASE -n $NAMESPACE"
  fi

  log "Health check"
  kc -n "$NAMESPACE" wait --for=condition=Available deploy --all --timeout=180s \
    || warn "Not all deployments became Available — check: sudo k3s kubectl -n $NAMESPACE get pods"

  if [[ "$app_diff" == 1 && "$UPDATE_SOURCE" != "usb" ]]; then
    # sandbox-runner is spawned on demand (not by Helm) — pre-pull it so the
    # sandbox works offline after the upgrade. Best-effort. (An offline package
    # ships it, so it was already imported above.)
    k3s crictl pull "ghcr.io/scriptor-group/suite-366-sandbox-runner:$want_app" >/dev/null 2>&1 \
      && info "sandbox-runner:$want_app pre-pulled." \
      || warn "sandbox-runner:$want_app pre-pull failed (offline restart may miss it)."
  fi

  rm -f "$MARKER"
  # Reflect the new state for the app UI (target reached).
  cur_chart="$want_chart"
  [[ "$app_diff"  == 1 ]] && cur_app="$want_app"
  [[ "$vllm_diff" == 1 ]] && cur_vllm="$want_vllm"
  chart_diff=0; vllm_diff=0; app_diff=0; summary_line=""

  # Fleet convergence: make sure the app-trigger units exist / are current, and
  # refresh this script for the next run. Ordered BEFORE write_state_json so the
  # retired offline source is reflected in the state the app reads.
  install_units
  if [[ "$UPDATE_SOURCE" == "usb" ]]; then
    self_update_from_package
    retire_staged_package
    load_offline_source
  else
    self_update
  fi

  UPDATE_SOURCE=none
  write_state_json 0
  write_apply_json success "update complete (chart $want_chart, app ${cur_app:-?}, channel ${channel:-?})"
  trap - EXIT
  log "Update complete (now on chart $want_chart, channel ${channel:-?})."
}

# --- Offline package: image import + retirement ---------------------------------
# images/       -> containerd's k8s.io namespace (everything Helm schedules)
# docker-images/ -> the Docker daemon (the vLLM stack runs on compose, not k8s)
import_package_images() {
  local tar n=0
  for tar in "$OFFLINE_PKG"/images/*.tar; do
    [[ -f "$tar" ]] || continue
    log "Importing $(basename "$tar") into containerd"
    k3s ctr -n k8s.io images import "$tar" >/dev/null \
      || die "image import failed: $(basename "$tar")"
    n=$((n+1))
  done
  for tar in "$OFFLINE_PKG"/docker-images/*.tar; do
    [[ -f "$tar" ]] || continue
    log "Loading $(basename "$tar") into Docker"
    docker load -i "$tar" >/dev/null \
      || die "docker load failed: $(basename "$tar")"
    n=$((n+1))
  done
  info "$n image archive(s) imported from the offline package."
}

# A package that has been applied must stop advertising itself — and stop
# occupying several GB. Keep the metadata (status `applied`) so the UI can still
# say where the running version came from.
retire_staged_package() {
  rm -rf "$OFFLINE_PKG"
  write_offline_source applied ""
  info "Offline package retired (staged content removed)."
}

# The updater that a signed package ships is itself covered by SHA256SUMS, so
# this is the ONLY trustworthy way to move update.sh forward on a box with no
# outbound access (see self_update for the online counterpart and its caveat).
self_update_from_package() {
  local src="$OFFLINE_PKG/scripts/update.sh"
  [[ -s "$src" ]] || return 0
  if bash -n "$src" 2>/dev/null && ! cmp -s "$src" "$DATA_DIR/update.sh"; then
    install -m 0700 "$src" "$DATA_DIR/update.sh"
    info "update.sh refreshed from the signed package."
  fi
}

# --- install-units -------------------------------------------------------------
# systemd .path units watching the trigger files the app drops in
# $UPDATES_DIR. Written inline (not fetched) so $DATA_DIR paths are baked in,
# same as the daily-timer units in lib/updater.sh. Idempotent.
install_units() {
  ensure_updates_dir

  cat > /etc/systemd/system/suite366-update-apply.service <<EOF
[Unit]
Description=Suite 366 — apply update (triggered from the app UI)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-$DATA_DIR/update.env
ExecStart=$DATA_DIR/update.sh apply
EOF

  cat > /etc/systemd/system/suite366-update-apply.path <<EOF
[Unit]
Description=Suite 366 — watch for apply requests from the app

[Path]
PathExists=$UPDATES_DIR/apply-requested

[Install]
WantedBy=multi-user.target
EOF

  # A check request reuses the daily-timer service (suite366-update.service,
  # installed by install.sh) — same "update.sh check" one-shot.
  cat > /etc/systemd/system/suite366-update-check.path <<EOF
[Unit]
Description=Suite 366 — watch for check requests from the app

[Path]
PathExists=$UPDATES_DIR/check-requested
Unit=suite366-update.service

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now suite366-update-apply.path suite366-update-check.path >/dev/null 2>&1 \
    || warn "could not enable trigger path units (systemd offline?)."
  info "App-trigger units armed (watching $UPDATES_DIR)."
}

# --- self-update ----------------------------------------------------------------
# Refresh this script from the channel repo after a successful apply, so
# changes to the update mechanism itself roll out with regular updates (no
# per-box SSH). Best-effort, syntax-checked before swapping in.
#
# Trust comes from the SIGNED manifest, not from TLS. channel.json carries
# `updater_sha256`; the manifest's signature covers that field, so a hash match
# means this exact script was published by whoever holds our private key. TLS
# alone would only prove we reached the right host — it says nothing about who
# wrote the file, and the file runs as root on the next apply.
#
# Graduated, same as the manifest check:
#   key present + signed manifest + matching hash -> install
#   key present, anything else                    -> REFUSE (fail closed)
#   no key installed                              -> TLS-only, as before
self_update() {
  [[ "$SELF_UPDATE" == "1" ]] || return 0
  local strict=0
  [[ -s "$PACKAGE_PUBLIC_KEY" ]] && strict=1

  if [[ "$strict" == 1 ]]; then
    if [[ "${online_signed:-0}" != "1" ]]; then
      warn "not refreshing update.sh: the channel manifest was not signature-verified."
      return 0
    fi
    if [[ -z "${online_updater_sha:-}" ]]; then
      warn "not refreshing update.sh: the signed manifest carries no updater_sha256."
      warn "  Publish it with tools/sign-channel.sh, or the updater cannot roll forward."
      return 0
    fi
  fi

  local tmp; tmp="$(mktemp)"
  if ! curl -fsSL -m 20 "$SELF_URL" -o "$tmp" || [[ ! -s "$tmp" ]]; then
    warn "could not fetch update.sh from $SELF_URL (non-blocking)."
    rm -f "$tmp"; return 0
  fi

  if [[ "$strict" == 1 ]]; then
    local got
    got="$(sha256sum "$tmp" | awk '{print $1}')"
    if [[ "$got" != "$online_updater_sha" ]]; then
      warn "REFUSING update.sh from $SELF_URL — hash does not match the signed manifest."
      warn "  expected $online_updater_sha"
      warn "  got      $got"
      warn "  Either the channel is mid-publish, or someone is serving a different script."
      rm -f "$tmp"; return 0
    fi
  fi

  if ! bash -n "$tmp" 2>/dev/null; then
    warn "fetched update.sh does not parse — keeping the current one."
    rm -f "$tmp"; return 0
  fi
  if ! cmp -s "$tmp" "$DATA_DIR/update.sh"; then
    install -m 0700 "$tmp" "$DATA_DIR/update.sh"
    info "update.sh refreshed from $SELF_URL$([[ "$strict" == 1 ]] && printf ' (signature-verified)')."
  fi
  rm -f "$tmp"
}

# --- Mode dispatch ---------------------------------------------------------------
require_cluster_tools() {
  have helm || die "helm not found."
  have k3s  || die "k3s not found."
  have curl || die "curl required."
}

case "$MODE" in
  check)
    require_cluster_tools
    survey
    notify
    ;;
  apply)
    require_cluster_tools
    survey
    do_apply
    ;;
  scan-usb)
    have openssl || die "openssl required to verify offline packages."
    require_cluster_tools
    do_scan_usb "${2:-}"
    ;;
  install-units)
    install_units
    ;;
  *)
    die "Unknown mode '$MODE' (use: check | apply | scan-usb DIR | install-units)"
    ;;
esac
