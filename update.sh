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
#   BACKUP_URL      same, for the backup agent (default: sibling of
#                   MANIFEST_URL). Governed by the same SELF_UPDATE switch and
#                   the same signature rules — see converge_backup.
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

# --- Backup agent ---------------------------------------------------------------
# The updater refreshes itself on every apply. If the backup agent did not move
# with it, a fleet would drift into new updaters running old backup agents — and
# the nightly job would keep reporting success while backing up the wrong things
# (or, on a box installed before the backup layer existed, nothing at all). So
# backup.sh is converged here, under the same signature rules as update.sh.
BACKUP_URL="${BACKUP_URL:-${MANIFEST_URL%/*}/backup.sh}"
BACKUP_AGENT="$DATA_DIR/backup.sh"
# The HOST LAYER — switch-model.sh, the model profiles, the compose, the nginx
# proxy config, the container entrypoint and the image build contexts — travels
# as ONE bundle (host-layer.sh, tools/bundle-host-layer.sh), pinned in
# channel.json as host_layer_sha256 under the same signature as this script and
# backup.sh. The stamp records the bundle a box carries; a channel that pins a
# different one is an update, applied by laying the bundle down and running
# `switch-model.sh converge`. See stage_host_layer_online / apply_host_layer.
HOST_LAYER_URL="${HOST_LAYER_URL:-${MANIFEST_URL%/*}/host-layer.sh}"
HOST_LAYER_STAMP="$DATA_DIR/llm/.host-layer.sha256"
BACKUP_DIR="${BACKUP_DIR:-$DATA_DIR/backup}"
BACKUP_ENV="${BACKUP_ENV:-$BACKUP_DIR/backup.env}"
RESTIC_BIN="${RESTIC_BIN:-$DATA_DIR/bin/restic}"
# One line, read deliberately rather than sourcing the file: backup.env also
# carries the destination's S3 credentials, and the updater has no business
# holding them even briefly.
if [[ -f "$BACKUP_ENV" ]]; then
  _rb="$(sed -n 's/^RESTIC_BIN=//p' "$BACKUP_ENV" | head -1)"
  [[ -n "$_rb" ]] && RESTIC_BIN="$_rb"
  unset _rb
fi

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
  "values_behind": $( [[ "${values_diff:-0}" == 1 ]] && printf true || printf false ),
  "notes": "$(json_esc "${notes:-}")",
  "source": "$(json_esc "${UPDATE_SOURCE:-none}")",
  "current": {
    "chart": "$(json_esc "${cur_chart:-}")",
    "app": "$(json_esc "${cur_app:-}")",
    "vllm": "$(json_esc "${cur_vllm:-}")",
    "host_layer": "$(json_esc "${cur_host:-}")"
  },
  "target": {
    "chart": "$(json_esc "${want_chart:-}")",
    "app": "$(json_esc "${want_app:-}")",
    "vllm": "$(json_esc "${want_vllm:-}")",
    "host_layer": "$(json_esc "${want_host:-}")"
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
  # `|| true` is load-bearing, not defensive noise: under `set -euo pipefail` an
  # assignment takes the pipeline's status, so a `helm list` that cannot reach the
  # cluster killed this script HERE — silently, exit 1, no output — and the warn
  # below plus the values.yaml fallback further down were unreachable code. That
  # is the degraded box this whole offline path exists for: k3s down, a verified
  # USB package waiting, and `check` dying before it can report it.
  cur_chart="$(helm list -n "$NAMESPACE" --filter "^${RELEASE}$" -o json 2>/dev/null \
    | sed -n 's/.*"chart":"[^"]*-\([0-9][^"]*\)".*/\1/p' | head -1 || true)"
  [[ -n "$cur_chart" ]] || warn "Could not read current chart version (release '$RELEASE' in ns '$NAMESPACE')."

  cur_vllm=""
  [[ -f "$DATA_DIR/llm/.env" ]] && cur_vllm="$(sed -n 's/^VLLM_IMAGE=//p' "$DATA_DIR/llm/.env" | head -1)"

  # The host layer only means something on a box that runs the vLLM stack
  # (llm/.env exists); a SKIP_VLLM box must never see it as a pending update.
  # No stamp = a box from before the bundle existed: stale by definition.
  host_applicable=0; cur_host=""
  if [[ -f "$DATA_DIR/llm/.env" ]]; then
    host_applicable=1
    [[ -s "$HOST_LAYER_STAMP" ]] && cur_host="$(head -1 "$HOST_LAYER_STAMP" | tr -dc 'a-f0-9')"
  fi

  # App release train = the image tag of the RUNNING drive-app deployment.
  # Do NOT read it from the values.yaml pins: apply rewrites those BEFORE the
  # helm upgrade, so if the upgrade fails the pins are ahead of reality and a
  # re-run would wrongly conclude "up to date". Fall back to the pin only when
  # the cluster is unreadable.
  cur_app="$(kc -n "$NAMESPACE" get deploy \
    -o jsonpath='{range .items[*].spec.template.spec.containers[*]}{.image}{"\n"}{end}' 2>/dev/null \
    | sed -n 's|.*/suite-366:||p' | head -1 || true)"
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
  online_updater_sha=""; online_backup_sha=""; online_host_sha=""
  online_restic_ver=""; online_restic_sha=""
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
  online_backup_sha="$(json_get backup_sha256  <<<"$manifest")"
  online_host_sha="$(json_get host_layer_sha256 <<<"$manifest")"
  online_restic_ver="$(json_get restic_version <<<"$manifest")"
  case "$(uname -m)" in
    aarch64) online_restic_sha="$(json_get restic_sha256_arm64 <<<"$manifest")" ;;
    x86_64)  online_restic_sha="$(json_get restic_sha256_amd64 <<<"$manifest")" ;;
  esac
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
  usb_chart=""; usb_app=""; usb_vllm=""; usb_notes=""; usb_channel=""; usb_verified_at=""; usb_host_sha=""
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
  usb_host_sha="$(json_get host_layer_sha256 <<<"$src")"
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
  "host_layer_sha256": "$(json_esc "${usb_host_sha:-}")",
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
  channel=""; want_chart=""; want_app=""; want_vllm=""; want_host=""; notes=""

  if [[ "$online_ok" == 1 && "$usb_ok" == 1 ]]; then
    if ver_gt "$usb_app" "$online_app"; then UPDATE_SOURCE=usb; else UPDATE_SOURCE=online; fi
  elif [[ "$online_ok" == 1 ]]; then UPDATE_SOURCE=online
  elif [[ "$usb_ok" == 1 ]]; then UPDATE_SOURCE=usb
  fi

  case "$UPDATE_SOURCE" in
    online) channel="$online_channel"; want_chart="$online_chart"
            want_app="$online_app";    want_vllm="$online_vllm"; notes="$online_notes"
            want_host="${online_host_sha:-}" ;;
    usb)    channel="${usb_channel:-offline}"; want_chart="$usb_chart"
            want_app="$usb_app";       want_vllm="$usb_vllm";    notes="$usb_notes"
            want_host="${usb_host_sha:-}" ;;
  esac
}

compute_diffs() {
  chart_diff=0; vllm_diff=0; app_diff=0; host_diff=0; values_diff=0; summary_line=""
  if [[ "${UPDATE_SOURCE:-none}" == "none" ]]; then
    warn "No usable update source (network unreachable, no verified offline package)."
    return 0
  fi
  info "source         : $UPDATE_SOURCE"
  info "channel        : ${channel:-?}"
  info "chart  running : ${cur_chart:-unknown}    target : ${want_chart:-?}"
  info "app    running : ${cur_app:-unknown}    target : ${want_app:-unchanged}"
  info "vLLM   running : ${cur_vllm:-unknown}    target : ${want_vllm:-unchanged}"
  if [[ "${host_applicable:-0}" == 1 ]]; then
    local _ch="${cur_host:-}" _wh="${want_host:-}"
    _ch="${_ch:0:12}"; _wh="${_wh:0:12}"
    info "host   layer   : ${_ch:-none (pre-bundle box)}    target : ${_wh:-unpinned}"
  fi

  # STRICTLY NEWER, not merely different. The channel is rolled deliberately and
  # the installer's own default runs ahead of it between rolls, so a box
  # installed in that window found itself one button away from going backwards:
  # observed on the GB10 as `update_available: true, "chart 0.9.0 -> 0.8.0"`,
  # with the admin UI offering it as an update. A silent downgrade takes back
  # whatever the newer chart added — which is exactly the kind of loss nobody
  # attributes to an update that presented itself as one.
  #
  # A genuine rollback is still possible: publish it as a HIGHER version of the
  # older content, which is a deliberate act and leaves a trace. Reaching it by
  # lowering a number is not something a fleet should follow automatically.
  if ver_gt "$want_chart" "$cur_chart" && [[ -n "$cur_chart" ]]; then chart_diff=1; fi
  if ver_gt "$want_app"  "$cur_app"  && [[ -n "$cur_app"  ]]; then app_diff=1; fi
  # The vLLM image is a tag, not a version: `cu130-nightly` does not order, so
  # difference is the only signal available and a change is always a roll.
  if [[ -n "$want_vllm" && -n "$cur_vllm" && "$cur_vllm" != "$want_vllm" ]]; then vllm_diff=1; fi
  # The host layer is a content hash, like the vLLM image a tag: different is
  # the only signal, and a channel that pins one this box does not carry — or a
  # box that carries none — is an update. Only where the vLLM stack runs.
  if [[ "${host_applicable:-0}" == 1 && -n "${want_host:-}" && "${cur_host:-}" != "${want_host:-}" ]]; then host_diff=1; fi
  # values.yaml lagging the template (a bridge, the workbench block) is an
  # update too: it is what `apply` converges, and without this line an
  # up-to-date box could only get it from a root shell. Guarded so the diffs
  # self-test, which extracts this function alone, is unaffected.
  if declare -F ensure_appliance_values >/dev/null && ensure_appliance_values --check; then values_diff=1; fi
  if [[ "$values_diff" == 1 ]]; then info "config values : behind the template (bridges / workbench) — converged on apply"; fi

  # A channel BEHIND the box is not an update, but it is worth saying out loud:
  # it usually means the channel has not been rolled since this box was built,
  # and someone is waiting for a fix that is already installed here.
  local behind=""
  if [[ -n "$cur_chart" ]] && ver_gt "$cur_chart" "$want_chart"; then
    behind="chart $want_chart < $cur_chart"
  fi
  if [[ -n "$cur_app" ]] && ver_gt "$cur_app" "$want_app"; then
    behind="${behind:+$behind; }app $want_app < $cur_app"
  fi
  if [[ -n "$behind" ]]; then
    info "channel is BEHIND this box ($behind) — not offered as an update."
  fi

  # One-line human summary of what's available.
  local parts=()
  [[ "$chart_diff" == 1 ]] && parts+=("chart ${cur_chart:-?} -> $want_chart")
  [[ "$app_diff"   == 1 ]] && parts+=("app ${cur_app:-?} -> $want_app")
  [[ "$vllm_diff"  == 1 ]] && parts+=("vLLM image -> $want_vllm")
  [[ "$host_diff"  == 1 ]] && parts+=("host layer (model switch, transcription) -> ${want_host:0:12}")
  [[ "$values_diff" == 1 ]] && parts+=("configuration (values.yaml: bridges, workbench)")
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

up_to_date() { [[ "$chart_diff" == 0 && "$vllm_diff" == 0 && "$app_diff" == 0 && "${host_diff:-0}" == 0 && "${values_diff:-0}" == 0 ]]; }

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
  pkg_chart=""; pkg_app=""; pkg_vllm=""; pkg_channel=""; pkg_notes=""; pkg_min_from=""; pkg_host_sha=""

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

  # 3b. sha256sum -c validates every file it LISTS, but is SILENT about files
  #     that are present and NOT listed — and import_package_images globs
  #     images/*.tar / docker-images/*.tar, so an unsigned tar dropped in beside
  #     the real ones would be imported while every check above still passed.
  #     Require the present set to equal the signed set exactly, nothing extra.
  local listed present
  listed="$(sed 's/^[0-9a-f]\{64\} [ *]//' "$root/SHA256SUMS" | sort)"
  present="$( ( cd "$root" && find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.sig ) | sort )"
  if [[ "$listed" != "$present" ]]; then
    pkg_error="extra file(s) not covered by the signed SHA256SUMS"; return 1
  fi

  local mf; mf="$(cat "$root/manifest.json")"
  pkg_channel="$(json_get channel        <<<"$mf")"
  pkg_chart="$(json_get chart_version    <<<"$mf")"
  pkg_app="$(json_get app_version        <<<"$mf")"
  pkg_vllm="$(json_get vllm_image        <<<"$mf")"
  pkg_notes="$(json_get notes            <<<"$mf")"
  pkg_min_from="$(json_get min_from_version <<<"$mf")"
  # Optional: packages built before the host layer existed ship none. Its hash
  # is what the stamp on the box is compared with, and SHA256SUMS already vouches
  # for the file.
  if [[ -s "$root/scripts/host-layer.sh" ]]; then
    pkg_host_sha="$(sha256sum "$root/scripts/host-layer.sh" | awk '{print $1}')"
  fi
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
    usb_vllm="$pkg_vllm";       usb_notes="$pkg_notes"; usb_host_sha="$pkg_host_sha"
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
    usb_channel=""; usb_chart=""; usb_app=""; usb_vllm=""; usb_notes=""; usb_verified_at=""; usb_host_sha=""
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
# --- values.yaml: every app <-> host bridge, IN PLACE ------------------------------
# The app hides a feature whose hostPath bridge is missing (update, backup, the
# model page, remote access). install.sh renders all five from the template;
# a box installed earlier keeps the values.yaml of its day, and `helm upgrade`
# from a NEWER chart does not add what values.yaml does not say. Seen on a
# client Spark at app 1.11.7 with no model page: the bridge only install.sh knew.
#
# In place, not as a `-f` overlay: switch-model.sh (and any operator) runs
# `helm upgrade -f values.yaml` on its own, and an overlay it does not know
# about would silently fall off the release at that moment. One file, every
# writer sees the same thing. The legacy overlay of the update bridge is folded
# in and removed. Idempotent: returns 0 when something was added, 1 when not.
#
# `config.VLLM_MODEL_TRANSCRIPTION` rides along: the app reads it from the
# ConfigMap, and it must exist — empty for a profile without transcription —
# before switch-model.sh can keep it in step. Its value follows the profile
# the box runs (llm/profiles.sh), which is why the host layer is laid down
# BEFORE this runs.
#
# So does `sandbox.workbench`: the per-user workbench landed in the template on
# 2026-08-05 and the chart defaults it OFF, so every box installed before that
# date runs 1.11.x with `workbenchEnabled: false` and no way to turn it on from
# an update — the pin rewrite above only touches lines that exist. The block is
# added whole when absent, pinned on the app version this apply installs, and
# never edited when present: an admin who turned it off keeps it off.
detect_stt_model() { # -> the transcription model the box's profile serves, or empty
  local envf="$DATA_DIR/llm/.env" profiles="$DATA_DIR/llm/profiles.sh" prof model
  [[ -f "$envf" && -f "$profiles" ]] || return 0
  prof="$(sed -n 's/^LLM_PROFILE=//p' "$envf" | head -1)"
  model="$(sed -n 's/^LLM_MODEL=//p' "$envf" | head -1)"
  ( set +u
    # shellcheck disable=SC1090
    source "$profiles" 2>/dev/null || exit 0
    if [[ -z "$prof" ]]; then
      for p in ${LLM_PROFILES:-}; do
        if llm_profile_apply "$p" base tag 2>/dev/null && [[ "${LLM_P_MODEL:-}" == "$model" ]]; then prof="$p"; break; fi
      done
    fi
    [[ -n "$prof" ]] || exit 0
    llm_profile_apply "$prof" base tag 2>/dev/null && printf '%s' "${LLM_P_STT_MODEL:-}" ) || true
}

extra_vals=()
# `--check`: report what WOULD be added and write nothing — what `check` uses
# to offer the convergence as an update, so an up-to-date box gets the Apply
# button in the UI instead of a root shell.
ensure_appliance_values() { # ensure_appliance_values [--check] -> 0 changed/would change, 1 nothing
  local vals="$DATA_DIR/values.yaml" out stt d check=0
  [[ "${1:-}" == "--check" ]] && check=1
  [[ -f "$vals" ]] || return 1
  if ! have python3; then
    [[ "$check" == 1 ]] || warn "python3 missing — values.yaml bridges NOT converged (the model page stays hidden)."
    return 1
  fi
  stt="$(detect_stt_model)"
  out="$(DATA_DIR="$DATA_DIR" STT_MODEL="$stt" APP_VERSION="${want_app:-${cur_app:-}}" CHECK_ONLY="$check" python3 - "$vals" <<'PY'
import os, re, sys
path = sys.argv[1]
data_dir = os.environ["DATA_DIR"]
stt = os.environ.get("STT_MODEL", "")
app_version = os.environ.get("APP_VERSION", "")
check_only = os.environ.get("CHECK_ONLY", "0") == "1"
text = open(path, encoding="utf-8").read()
lines = text.split("\n")
if lines and lines[-1] == "":
    lines.pop()
# name, env var, mount path, host dir -- the five bridges values.yaml renders.
BRIDGES = [
    ("appliance-update", "APPLIANCE_UPDATE_DIR", "/appliance-update", "updates"),
    ("support-access",   "SUPPORT_ACCESS_DIR",   "/support-access",   "support"),
    ("appliance-backup", "APPLIANCE_BACKUP_DIR", "/appliance-backup", "backup"),
    ("appliance-llm",    "APPLIANCE_LLM_DIR",    "/appliance-llm",    "llm-state"),
    ("appliance-remote", "APPLIANCE_REMOTE_DIR", "/appliance-remote", "remote"),
]
def item(kind, b):
    name, env, mount, sub = b
    if kind == "extraEnv":
        return ["  - name: " + env, "    value: " + mount]
    if kind == "extraVolumeMounts":
        return ["  - name: " + name, "    mountPath: " + mount]
    return ["  - name: " + name, "    hostPath:", "      path: " + data_dir + "/" + sub, "      type: DirectoryOrCreate"]
def marker(kind, b):
    return "name: " + (b[1] if kind == "extraEnv" else b[0])
def region(key):
    """(index of the top-level key line, end index exclusive), or (None, None)."""
    for i, l in enumerate(lines):
        if re.match(r"^" + re.escape(key) + r":\s*(\[\]\s*)?(#.*)?$", l):
            j = i + 1
            while j < len(lines) and (lines[j] == "" or lines[j].startswith(" ") or lines[j].startswith("#")):
                j += 1
            return i, j
    return None, None
added = 0
for kind in ("extraEnv", "extraVolumeMounts", "extraVolumes"):
    i, j = region(kind)
    if i is None:
        lines.append("")
        lines.append(kind + ":")
        for b in BRIDGES:
            lines.extend(item(kind, b)); added += 1
        continue
    if re.match(r"^" + re.escape(kind) + r":\s*\[\]", lines[i]):
        lines[i] = kind + ":"
    body = "\n".join(lines[i:j])
    ins = []
    for b in BRIDGES:
        if marker(kind, b) not in body:
            ins.extend(item(kind, b)); added += 1
    lines[i + 1:i + 1] = ins
# sandbox.workbench: the whole block, as the template renders it, when the
# sandbox block has none. Placed right after `runnerImage:` (or after the key
# line) so it reads like a fresh render; two-space children of `sandbox:`.
si, sj = region("sandbox")
if si is not None and app_version and not any(re.match(r"^  workbench:", l) for l in lines[si:sj]):
    at = si + 1
    for k in range(si + 1, sj):
        if re.match(r"^  runnerImage:", lines[k]):
            at = k + 1
    lines[at:at] = [
        "  workbench:",
        "    enabled: true",
        "    runnerImage: ghcr.io/scriptor-group/suite-366-workbench-runner:" + app_version,
        "    pullPolicy: IfNotPresent",
        "    storageClass: local-path",
        "    limits:",
        '      idleStopMs: "7200000"',
        "    resourceQuota:",
        '      pods: "10"',
        '      requestsCpu: "4"',
        '      requestsMemory: "4Gi"',
        '      limitsCpu: "20"',
        '      limitsMemory: "40Gi"',
        '      persistentVolumeClaims: "30"',
        '      requestsStorage: "300Gi"',
    ]
    added += 1
# The two idle limits, QUOTED: Helm 3.21.1 renders a plain 1800000 as "1.8e+06"
# and sandbox-api's parseInt makes 1 ms of it -- every session and workbench
# then dies at the reaper's first pass. A string renders verbatim on every
# Helm. Added under sandbox.limits and sandbox.workbench.limits when absent,
# never edited when present (an operator may have tuned them).
def sub_block(start, end, indent):
    # Lines after `start` that belong to the mapping opened there (deeper than `indent`).
    j = start + 1
    while j < end and (lines[j] == "" or lines[j].startswith(" " * (indent + 1)) or lines[j].lstrip().startswith("#")):
        j += 1
    return j
def ensure_quoted_limit(parent_start, parent_end, indent, key, value):
    # Within a mapping (children at `indent`), make sure `limits:` holds key: "value". 1 when added.
    global lines
    pad = " " * indent
    for k in range(parent_start + 1, parent_end):
        if re.match(r"^" + pad + r"limits:\s*$", lines[k]):
            lend = sub_block(k, parent_end, indent)
            if any(re.match(r"^" + pad + r"  " + re.escape(key) + r":", l) for l in lines[k:lend]):
                return 0
            lines[k + 1:k + 1] = [pad + "  " + key + ': "' + value + '"']
            return 1
    lines[parent_start + 1:parent_start + 1] = [pad + "limits:", pad + "  " + key + ': "' + value + '"']
    return 1
si, sj = region("sandbox")
if si is not None:
    added += ensure_quoted_limit(si, sj, 2, "idleTimeoutMs", "1800000")
    si, sj = region("sandbox")
    for k in range(si + 1, sj):
        if re.match(r"^  workbench:\s*$", lines[k]):
            added += ensure_quoted_limit(k, sub_block(k, sj, 2), 4, "idleStopMs", "7200000")
            break
ci, cj = region("config")
if ci is not None:
    if not any(re.match(r"^\s+VLLM_MODEL_TRANSCRIPTION:", l) for l in lines[ci:cj]):
        at = ci + 1
        for k in range(ci + 1, cj):
            if re.match(r"^\s+VLLM_MODEL_EMBEDDING:", lines[k]):
                at = k + 1
        lines[at:at] = ['  VLLM_MODEL_TRANSCRIPTION: "' + stt + '"']
        added += 1
new = "\n".join(lines) + "\n"
if new != text:
    if not check_only:
        open(path, "w", encoding="utf-8").write(new)
    print("changed: %d entr%s added" % (added, "y" if added == 1 else "ies"))
else:
    print("unchanged")
PY
)" || { [[ "$check" == 1 ]] || warn "could not converge values.yaml: $out"; return 1; }
  if [[ "$check" == 1 ]]; then
    case "$out" in changed*) return 0 ;; *) return 1 ;; esac
  fi
  # The host dirs behind the bridges, owned like install.sh makes them (the pod
  # is uid/gid 1001 and k8s does not fsGroup-chown a hostPath).
  for d in updates support backup remote llm-state; do
    mkdir -p "$DATA_DIR/$d"
    chown "root:$APP_GID" "$DATA_DIR/$d" 2>/dev/null || true   # not root under the self-test
    chmod 0770 "$DATA_DIR/$d" 2>/dev/null || true
  done
  if [[ -f "$DATA_DIR/values-appliance-update.yaml" ]]; then
    rm -f "$DATA_DIR/values-appliance-update.yaml"
    info "legacy values-appliance-update.yaml overlay removed (folded into values.yaml)."
  fi
  case "$out" in
    changed*) info "values.yaml: $out (app <-> host bridges)"; return 0 ;;
    *) return 1 ;;
  esac
}

# --- the host layer: fetch, verify, lay down, converge --------------------------
# Same trust ladder as backup.sh, for the same reason: switch-model.sh runs as
# root and rewrites the vLLM stack. Key present + signed manifest + matching
# hash -> lay down; key present, anything else -> REFUSE; no key -> TLS-only.
# Staging (files on disk) and applying (containers, units) are separate so
# that the compose in place is the NEW one before any container is recreated:
# on a legacy compose a base-image move would drag the LLM along with it.
host_layer_new_sha=""
stage_host_layer_online() {
  local strict=0
  [[ -s "$PACKAGE_PUBLIC_KEY" ]] && strict=1
  if [[ "$strict" == 1 ]]; then
    if [[ "${online_signed:-0}" != "1" ]]; then
      warn "not laying down the host layer: the channel manifest was not signature-verified."; return 1
    fi
    if [[ -z "${online_host_sha:-}" ]]; then
      warn "not laying down the host layer: the signed manifest carries no host_layer_sha256."
      warn "  Publish it with tools/sign-channel.sh, or this box keeps the host side it was installed with."
      return 1
    fi
  fi
  local tmp; tmp="$(mktemp)"
  if ! curl -fsSL -m 60 "$HOST_LAYER_URL" -o "$tmp" || [[ ! -s "$tmp" ]]; then
    warn "could not fetch host-layer.sh from $HOST_LAYER_URL (non-blocking)."; rm -f "$tmp"; return 1
  fi
  local got; got="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$strict" == 1 && "$got" != "$online_host_sha" ]]; then
    warn "REFUSING host-layer.sh from $HOST_LAYER_URL — hash does not match the signed manifest."
    warn "  expected $online_host_sha"
    warn "  got      $got"
    rm -f "$tmp"; return 1
  fi
  local origin="$HOST_LAYER_URL"
  [[ "$strict" == 1 ]] && origin="$origin (signature-verified)"
  stage_host_layer_file "$tmp" "$got" "$origin"
  local rc=$?; rm -f "$tmp"; return $rc
}
stage_host_layer_from_package() {
  local src="$OFFLINE_PKG/scripts/host-layer.sh"
  [[ -s "$src" ]] || { warn "the staged package ships no host-layer.sh — host side left as is."; return 1; }
  stage_host_layer_file "$src" "$(sha256sum "$src" | awk '{print $1}')" "the signed package"
}
stage_host_layer_file() { # stage_host_layer_file FILE SHA ORIGIN
  if ! bash -n "$1" 2>/dev/null; then warn "host-layer.sh does not parse — not laid down."; return 1; fi
  log "Laying down the host layer from $3"
  if ! bash "$1" extract "$DATA_DIR"; then
    warn "host-layer.sh could not unpack into $DATA_DIR — host side left as is."; return 1
  fi
  host_layer_new_sha="$2"
  info "switch-model.sh + llm/ updated (bundle ${2:0:12})."
}
# Recreates what the new compose or the new base image changed, in ONE pass,
# through the operator script that owns the stack. The stamp is written only
# when convergence succeeded, so a failed run is retried by the next apply.
apply_host_layer() { # apply_host_layer STAGED(0|1) VLLM_MOVED(0|1)
  local sw="$DATA_DIR/switch-model.sh"
  if [[ -x "$sw" && -f "$DATA_DIR/llm/profiles.sh" ]]; then
    log "Converging the vLLM host side (switch-model.sh converge)"
    if DATA_DIR="$DATA_DIR" "$sw" converge; then
      if [[ "$1" == 1 && -n "$host_layer_new_sha" ]]; then
        printf '%s\n' "$host_layer_new_sha" > "$HOST_LAYER_STAMP"; chmod 0644 "$HOST_LAYER_STAMP"
        cur_host="$host_layer_new_sha"; host_diff=0
        info "host layer stamped ${host_layer_new_sha:0:12}."
      fi
    else
      warn "host-side convergence reported errors — the stamp is NOT written; the next apply retries."
      warn "  Details: sudo $sw converge"
    fi
  elif [[ "$2" == 1 ]]; then
    # No host layer on this box (a fetch that was refused): the pre-bundle
    # behaviour, a plain recreate on the new image. Offline: the image is
    # already loaded, so `pull` would only fail.
    local vllm_ok=0
    if [[ "$UPDATE_SOURCE" == "usb" ]]; then
      ( cd "$DATA_DIR/llm" && docker compose up -d ) && vllm_ok=1
    else
      ( cd "$DATA_DIR/llm" && docker compose pull && docker compose up -d ) && vllm_ok=1
    fi
    if [[ "$vllm_ok" == 1 ]]; then info "vLLM containers recreated."
    else warn "vLLM image update failed — check: docker logs suite366-vllm-llm"; fi
  fi
}

# One helm roll, from whichever source is in play. Offline: the chart comes
# from the signed package as a local .tgz, so no `--version` (the archive IS
# the version) and no OCI pull.
roll_release() { # roll_release CHART_VERSION
  local vals="$DATA_DIR/values.yaml" chart_args=()
  if [[ "$UPDATE_SOURCE" == "usb" ]]; then
    local pkg_charts=( "$OFFLINE_PKG"/chart/*.tgz )
    [[ -f "${pkg_charts[0]:-}" ]] || die "staged package has no chart archive."
    chart_args=( "${pkg_charts[0]}" )
    info "chart from package: $(basename "${pkg_charts[0]}")"
  else
    chart_args=( "$CHART_REF" --version "$1" )
  fi
  helm upgrade "$RELEASE" "${chart_args[@]}" \
    -n "$NAMESPACE" -f "$vals" "${extra_vals[@]}" \
    --wait --timeout 15m \
    || die "helm upgrade failed — roll back with: sudo helm rollback $RELEASE -n $NAMESPACE"
}

# sandbox-api reads its configuration through `envFrom` on configmap-sandbox-api
# at start, and the chart puts no checksum on its pod template: a converged
# values.yaml that turned the workbench on rewrites the ConfigMap and nothing
# restarts the pod. Seen on the client Spark: workbench tab present, "service
# unreachable", sandbox-api still on its pre-workbench environment. Two seconds
# to restart; done whenever values.yaml was converged and rolled.
restart_sandbox_api() {
  local ns
  ns="$(awk '/^sandbox:/{f=1;next} f&&/^[a-z]/{f=0} f&&/^  namespace:/{print $2; exit}' "$DATA_DIR/values.yaml" 2>/dev/null | tr -d '"')"
  [[ -n "$ns" ]] || return 0
  kc -n "$ns" get deploy sandbox-api >/dev/null 2>&1 || return 0
  if kc -n "$ns" rollout restart deploy/sandbox-api >/dev/null 2>&1 \
     && kc -n "$ns" rollout status deploy/sandbox-api --timeout=120s >/dev/null 2>&1; then
    info "sandbox-api restarted on the converged configuration (workbench)."
  else
    warn "sandbox-api did not come back after the restart — check: sudo k3s kubectl -n $ns get pods"
  fi
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
    log "Up to date (chart ${cur_chart:-?}, app ${cur_app:-?}, host layer ${cur_host:0:12}) — nothing to apply."
    rm -f "$MARKER"
    # values.yaml can lag the template while every version matches: a box
    # installed before a block existed (the bridges, the workbench) stays
    # without it until something else moves. Converge it here too, and roll the
    # release when it changed — this is what a manual `apply` on an up-to-date
    # box is for.
    if [[ -n "${cur_chart:-}" ]] && ensure_appliance_values; then
      log "helm upgrade $RELEASE: chart $cur_chart (values.yaml converged)"
      roll_release "$cur_chart"
      kc -n "$NAMESPACE" wait --for=condition=Available deploy --all --timeout=180s \
        || warn "Not all deployments became Available — check: sudo k3s kubectl -n $NAMESPACE get pods"
      restart_sandbox_api
    fi
    write_state_json 0
    write_apply_json idle "already up to date (chart ${cur_chart:-?}, app ${cur_app:-?})"
    install_units
    self_update
    converge_backup
    reconcile_and_check_vllm_db 0
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

  # The host layer FIRST, files only: the compose and switch-model.sh in place
  # must be the new ones before .env moves or any container is recreated.
  local host_staged=0 vllm_moved=0
  if [[ "$host_diff" == 1 ]]; then
    if [[ "$UPDATE_SOURCE" == "usb" ]]; then
      stage_host_layer_from_package && host_staged=1
    else
      stage_host_layer_online && host_staged=1
    fi
  fi

  # The vLLM base image: .env only. VLLM_IMAGE is what the embed and the
  # transcription run and what the profiles derive the generative image from —
  # a pinned profile (gemma on cu130-nightly) does NOT follow it. The recreate
  # happens once, in apply_host_layer below, after the app is upgraded.
  if [[ "$vllm_diff" == 1 ]]; then
    log "vLLM image: $cur_vllm -> $want_vllm"
    [[ -f "$DATA_DIR/llm/.env" ]] || die "$DATA_DIR/llm/.env missing — cannot retarget vLLM image."
    sed -i "s|^VLLM_IMAGE=.*|VLLM_IMAGE=$want_vllm|" "$DATA_DIR/llm/.env"
    vllm_moved=1
  fi

  if [[ "$app_diff" == 1 ]]; then
    # The appliance pins the app + sandbox images in values.yaml (offline
    # safety) — move the pins to the new release train before the upgrade.
    log "App release: $cur_app -> $want_app (rewriting values.yaml pins)"
    sed -i "s|^  tag: \".*\"|  tag: \"$want_app\"|" "$vals"
    sed -i "s|\(suite-366-sandbox-api:\)[^\"[:space:]]*|\1$want_app|" "$vals"
    sed -i "s|\(suite-366-sandbox-runner:\)[^\"[:space:]]*|\1$want_app|" "$vals"
    # The workbench runner rides the same release train and was left out while
    # it was pinned to `latest`, where nothing had to be rewritten. Pinning it
    # without adding it here would have frozen it at the version of whatever
    # release happened to pin it, silently, while the other three moved on.
    sed -i "s|\(suite-366-workbench-runner:\)[^\"[:space:]]*|\1$want_app|" "$vals"
  fi

  # Every app <-> host bridge, in place — a box updated from an older values.yaml
  # gets the model page, the backup page and remote access wired like a fresh
  # install. A change here is a reason to roll the release on its own.
  local values_changed=0 target_chart="${want_chart:-$cur_chart}"
  if ensure_appliance_values; then values_changed=1; fi
  [[ "$chart_diff" == 1 ]] || target_chart="${cur_chart:-$want_chart}"
  if [[ "$chart_diff" == 1 || "$app_diff" == 1 || "$values_changed" == 1 ]]; then
    log "helm upgrade $RELEASE: chart ${cur_chart:-?} -> $target_chart, app ${cur_app:-?} -> ${want_app:-unchanged}$([[ "$values_changed" == 1 ]] && printf ', values.yaml converged')"
    roll_release "$target_chart"
    # After the health check below; the flag is read there.
  fi

  log "Health check"
  kc -n "$NAMESPACE" wait --for=condition=Available deploy --all --timeout=180s \
    || warn "Not all deployments became Available — check: sudo k3s kubectl -n $NAMESPACE get pods"
  if [[ "$values_changed" == 1 ]]; then restart_sandbox_api; fi

  # The vLLM stack, one pass: the new host layer and/or the new base image.
  if [[ "$host_staged" == 1 || "$vllm_moved" == 1 ]]; then
    apply_host_layer "$host_staged" "$vllm_moved"
  fi

  # The helm upgrade above re-pushed the Secret from values.yaml, so the app may
  # have restarted onto a key the database row does not carry. DEEP=1: a POST is
  # affordable once per apply, and it is the only thing that proves the path.
  reconcile_and_check_vllm_db 1

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
  # host_diff stays 1 when the layer could not be laid down or converged: the
  # state the app reads keeps offering it, and the next apply retries.
  chart_diff=0; vllm_diff=0; app_diff=0; values_diff=0; summary_line=""

  # Fleet convergence: make sure the app-trigger units exist / are current, and
  # refresh this script for the next run. Ordered BEFORE write_state_json so the
  # retired offline source is reflected in the state the app reads.
  install_units
  if [[ "$UPDATE_SOURCE" == "usb" ]]; then
    self_update_from_package
    # BEFORE retire_staged_package: retiring deletes the staged content, and the
    # backup agent plus the restic binary live inside it.
    converge_backup_from_package
    retire_staged_package
    load_offline_source
  else
    self_update
    converge_backup
  fi

  UPDATE_SOURCE=none
  write_state_json 0
  write_apply_json success "update complete (chart $want_chart, app ${cur_app:-?}, channel ${channel:-?})$( [[ "${VLLM_DB_VERIFIED:-}" == "stale" ]] && printf ' — WARNING: the vLLM key stored in the database is rejected by vLLM' )"
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

# --- backup agent convergence -----------------------------------------------------
# Same trust ladder as self_update, for the same reason: backup.sh runs as root,
# nightly, holding the destination's credentials.
#
#   key present + signed manifest + matching hash -> install
#   key present, anything else                    -> REFUSE (fail closed)
#   no key installed                              -> TLS-only, as before
#
# Two things make this more than a copy of self_update:
#
#   • A box installed before the backup layer existed has NO agent. Refreshing
#     it is not enough — the timer has to be armed too, or the file sits there
#     doing nothing. So a first install also runs `install-units`.
#   • Arming a timer is not the same as being backed up. Convergence deliberately
#     does NOT invent a repository key or a destination: the key is shown exactly
#     once, to a human, at install (see lib/backup.sh), and one silently
#     generated here would exist on precisely one disk with nobody holding a
#     copy. Instead the agent is asked to publish its state, so the box reports
#     "unconfigured" to the UI rather than looking installed and being empty.
converge_backup() {
  [[ "$SELF_UPDATE" == "1" ]] || return 0
  local strict=0 fresh=0
  [[ -s "$PACKAGE_PUBLIC_KEY" ]] && strict=1
  [[ -x "$BACKUP_AGENT" ]] || fresh=1

  if [[ "$strict" == 1 ]]; then
    if [[ "${online_signed:-0}" != "1" ]]; then
      warn "not refreshing backup.sh: the channel manifest was not signature-verified."
      return 0
    fi
    if [[ -z "${online_backup_sha:-}" ]]; then
      warn "not refreshing backup.sh: the signed manifest carries no backup_sha256."
      warn "  Publish it with tools/sign-channel.sh, or the backup agent cannot roll forward"
      warn "  and this box keeps whatever agent it was installed with."
      return 0
    fi
  fi

  local tmp; tmp="$(mktemp)"
  if ! curl -fsSL -m 20 "$BACKUP_URL" -o "$tmp" || [[ ! -s "$tmp" ]]; then
    warn "could not fetch backup.sh from $BACKUP_URL (non-blocking)."
    rm -f "$tmp"; return 0
  fi

  if [[ "$strict" == 1 ]]; then
    local got; got="$(sha256sum "$tmp" | awk '{print $1}')"
    if [[ "$got" != "$online_backup_sha" ]]; then
      warn "REFUSING backup.sh from $BACKUP_URL — hash does not match the signed manifest."
      warn "  expected $online_backup_sha"
      warn "  got      $got"
      rm -f "$tmp"; return 0
    fi
  fi

  if ! bash -n "$tmp" 2>/dev/null; then
    warn "fetched backup.sh does not parse — keeping the current one."
    rm -f "$tmp"; return 0
  fi
  if ! cmp -s "$tmp" "$BACKUP_AGENT" 2>/dev/null; then
    install -m 0700 "$tmp" "$BACKUP_AGENT"
    info "backup.sh refreshed from $BACKUP_URL$([[ "$strict" == 1 ]] && printf ' (signature-verified)')."
  fi
  rm -f "$tmp"
  # Before arming: a timer whose agent has no restic can only ever report an
  # error, and it would do so nightly.
  install_restic_online || true
  arm_backup_agent "$fresh"
}

# Shared by the online and offline paths.
arm_backup_agent() { # arm_backup_agent FRESH(0|1)
  local fresh="$1"
  [[ -x "$BACKUP_AGENT" ]] || return 0
  if [[ "$fresh" == 1 ]]; then
    log "Backup agent installed on a box that had none — arming its timer"
    DATA_DIR="$DATA_DIR" "$BACKUP_AGENT" install-units \
      || warn "could not arm the backup timer."
  fi
  # Only on a first install, and only then. A box that had no agent has no
  # destination either, so this is a cheap no-op that publishes `unconfigured`
  # and lets the UI say so. On an already-converged box it would be a full
  # backup on every daily check, on top of the nightly timer.
  if [[ "$fresh" == 1 ]]; then
    DATA_DIR="$DATA_DIR" "$BACKUP_AGENT" run >/dev/null 2>&1 || true
    if [[ ! -s "$BACKUP_DIR/repo.pass" ]]; then
      warn "backups are NOT configured on this appliance (no repository key)."
      warn "  Run: sudo $DATA_DIR/install.sh   (or set one up per docs/restore.md)"
    fi
  fi
}

# An agent with no restic is an armed timer that can never run. The offline
# package carries the binary; a networked box has to fetch it, and the version
# and checksum come from the SIGNED manifest so the box verifies the download
# against a hash we published rather than against whatever the server served.
#
# Best effort by design: no restic means backups do not work yet, which
# `backup.sh run` reports as an error state the UI shows. It does not mean the
# update failed.
install_restic_online() {
  [[ -x "$RESTIC_BIN" ]] && return 0
  local ver="${online_restic_ver:-}" want="${online_restic_sha:-}" arch
  if [[ -z "$ver" || -z "$want" ]]; then
    warn "no restic pin in the channel manifest — the backup agent has no binary to run."
    warn "  Publish restic_version + restic_sha256_* (tools/sign-channel.sh), or run install.sh."
    return 1
  fi
  case "$(uname -m)" in
    aarch64) arch=arm64 ;;
    x86_64)  arch=amd64 ;;
    *) warn "no pinned restic for $(uname -m)."; return 1 ;;
  esac
  have bunzip2 || { warn "bzip2 missing — cannot unpack restic."; return 1; }

  local url="https://github.com/restic/restic/releases/download/v$ver/restic_${ver}_linux_${arch}.bz2"
  local tmp; tmp="$(mktemp)"
  info "Fetching restic $ver ($arch) for the backup agent…"
  if ! curl -fsSL -m 180 "$url" -o "$tmp"; then
    rm -f "$tmp"; warn "could not download restic (offline?) — backups stay unavailable."; return 1
  fi
  local got; got="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$got" != "$want" ]]; then
    rm -f "$tmp"
    # Fail closed: this binary runs as root, nightly, holding the destination's
    # credentials and every document that goes into the repository.
    warn "REFUSING restic — checksum does not match the signed manifest."
    warn "  expected $want"
    warn "  got      $got"
    return 1
  fi
  mkdir -p "$(dirname "$RESTIC_BIN")"; chmod 0700 "$(dirname "$RESTIC_BIN")"
  if ! bunzip2 -c "$tmp" > "$RESTIC_BIN"; then
    rm -f "$tmp"; warn "could not unpack restic."; return 1
  fi
  rm -f "$tmp"; chmod 0700 "$RESTIC_BIN"
  "$RESTIC_BIN" version >/dev/null 2>&1 || { warn "the restic binary does not run here."; return 1; }
  info "restic installed: $RESTIC_BIN ($("$RESTIC_BIN" version 2>/dev/null | head -1))"
}

# The package ships both the agent and the restic binary, and both are covered
# by the signed SHA256SUMS — the only trustworthy way to move them forward on a
# box with no outbound access. Shipping restic matters more than it looks: an
# air-gapped appliance cannot download it, so without this an offline fleet
# would carry a backup agent it can never run.
converge_backup_from_package() {
  local src="$OFFLINE_PKG/scripts/backup.sh" fresh=0
  [[ -x "$BACKUP_AGENT" ]] || fresh=1

  if [[ -s "$src" ]] && bash -n "$src" 2>/dev/null; then
    if ! cmp -s "$src" "$BACKUP_AGENT" 2>/dev/null; then
      install -m 0700 "$src" "$BACKUP_AGENT"
      info "backup.sh refreshed from the signed package."
    fi
  fi

  local rsrc="$OFFLINE_PKG/bin/restic"
  if [[ -s "$rsrc" ]]; then
    # Replace only on a real difference: an identical copy every apply would
    # churn a binary the nightly timer may be executing at that very moment.
    if ! cmp -s "$rsrc" "$RESTIC_BIN" 2>/dev/null; then
      mkdir -p "$(dirname "$RESTIC_BIN")"; chmod 0700 "$(dirname "$RESTIC_BIN")"
      install -m 0700 "$rsrc" "$RESTIC_BIN" \
        && info "restic installed from the signed package ($("$RESTIC_BIN" version 2>/dev/null | head -1))."
    fi
  fi

  [[ -x "$BACKUP_AGENT" ]] && arm_backup_agent "$fresh"
  return 0
}

# >>> SHARED vllm-db BLOCK — duplicated VERBATIM into update.sh and backup.sh
# (they are fetched and run standalone and must not depend on lib/ being
# present: backup.sh:109-111). Re-sync with tools/sync-vllm-db-block.sh;
# tools/test-vllm-db.sh FAILS if the three copies drift.
# Every function here is extracted by that test with
# `sed -n "/^name() {/,/^}/p"`, so: no one-liner bodies, and no line inside a
# body may start with `}` at column 0. >>>

# The key and the URL are interpolated into a statement run as the database
# owner, so both are WHITELISTED rather than escaped — "it looks harmless" is
# not a security property (backup.sh:898-900 makes the same argument about
# repository strings). lib/preflight.sh:469 draws `sk-` + 32 base62 chars, but
# :467 parses a re-run's key out of values.yaml with `sk-[^"]*`, which a
# hand-edited file could turn into anything: assert the shape, never assume it.
vllm_key_sane() { # vllm_key_sane KEY
  [[ "$1" =~ ^[A-Za-z0-9._-]{8,200}$ ]]
}

# `_` is deliberately absent from the host class: this string also becomes the
# left side of a SQL LIKE, where `_` and `%` are wildcards. The port is
# REQUIRED — vllm_row_scope derives the LIKE prefix by stripping `:<port>/v1`,
# and a portless URL would yield the far too broad `http:%`.
vllm_url_sane() { # vllm_url_sane URL
  [[ "$1" =~ ^https?://[0-9A-Za-z.-]+:[0-9]{2,5}/v1$ ]]
}

# The rows that are aimed at THIS box, and nothing else: the app's own seed by
# name, a seed that carries no baseUrl at all, or a row already pointing here.
vllm_row_scope() { # vllm_row_scope URL -> SQL predicate
  local prefix="${1%:*}:"
  printf "provider = 'VLLM' AND (name = 'vLLM Local' OR config->>'baseUrl' IS NULL OR config->>'baseUrl' LIKE '%s%%')" "$prefix"
}

# Postgres deployment by name pattern, never hardcoded: the chart derives every
# resource name from `appName` (backup.sh:295-297). The `|| true` is not
# decoration — the pipeline's grep exits 1 when nothing matches, and under
# `set -o pipefail` that kills the CALLER before it can report why.
vllm_pg_deploy() {
  if [[ -n "${PG_DEPLOY:-}" ]]; then
    printf '%s' "$PG_DEPLOY"
    return 0
  fi
  kc -n "$NAMESPACE" get deploy -o name 2>/dev/null \
    | sed -n 's|^deployment.apps/||p' | grep -- '-postgres$' | head -1 || true
}

# The one curl here that is NOT `-fsS`, and it has to be: `-f` turns a 401 into
# exit 22 and throws the status code away, and the status code IS the answer.
# `|| true` sits INSIDE the substitution so curl's own "000" survives a connect
# failure (it prints 000 and exits 7).
vllm_http_code() { # vllm_http_code URL KEY TIMEOUT [JSON_BODY]
  local url="$1" key="$2" tmo="$3" body="${4:-}" code=""
  if [[ -n "$body" ]]; then
    code="$(curl -s -o /dev/null -m "$tmo" -w '%{http_code}' \
              -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
              --data-binary "$body" "$url" 2>/dev/null || true)"
  else
    code="$(curl -s -o /dev/null -m "$tmo" -w '%{http_code}' \
              -H "Authorization: Bearer $key" "$url" 2>/dev/null || true)"
  fi
  printf '%s' "${code:-000}"
}

# vLLM's api-key check is ASGI middleware: it runs BEFORE routing and before
# body validation. So 400/404/422/500 all mean the Authorization header was
# ACCEPTED and something else was wrong — which is what makes a cheap probe
# definitive. Only 401/403 is a bad key; only a transport failure or an nginx
# upstream error means vLLM was never reached.
vllm_verdict() { # vllm_verdict HTTP_CODE -> ok|denied|down
  case "$1" in
    401|403)            printf 'denied' ;;
    000|502|503|504|"") printf 'down' ;;
    *)                  printf 'ok' ;;
  esac
}

# Realign the stored row. Idempotent, and never fatal to its caller: a database
# that is not up yet, or an app whose migrations have not run, is a normal state
# during a first install.
reconcile_vllm_db_key() { # reconcile_vllm_db_key KEY BASE_URL
  local key="$1" url="$2" pg="" out="" scope=""
  if ! vllm_key_sane "$key"; then
    warn "vLLM provider key: '$key' is not a key shape this installer produces —"
    warn "  the AIProvider row was left alone and NO SQL was built."
    return 0
  fi
  if ! vllm_url_sane "$url"; then
    warn "vLLM provider key: '$url' is not a usable base URL (host:port required) —"
    warn "  the AIProvider row was left alone and NO SQL was built."
    return 0
  fi
  pg="$(vllm_pg_deploy)"
  if [[ -z "$pg" ]]; then
    warn "vLLM provider key: no *-postgres deployment in ns/$NAMESPACE — nothing to realign."
    return 0
  fi
  scope="$(vllm_row_scope "$url")"

  # One round trip, SQL on stdin. Three deliberate choices:
  #  • the `sh -c` argument is SINGLE-quoted so $POSTGRES_* expand INSIDE the
  #    pod (backup.sh:869's rule): no password on a host argv, and the API key
  #    never reaches an argv at all — it arrives on stdin.
  #  • the heredoc is UNQUOTED so the values interpolate, which is why the SQL
  #    contains no `$`, no backtick and no backslash-escape anywhere, and why
  #    the table guard is psql's `\if` rather than a `DO $$ ... $$` block.
  #  • the guard CANNOT live inside the statement: naming a missing table fails
  #    at PARSE time. `\if` discards the branch client-side, so nothing is sent.
  # The data-modifying CTE makes stdout a deterministic `realigned=N` from a
  # SELECT rather than psql's `UPDATE n` command tag, which `-q` suppresses.
  out="$(kc -n "$NAMESPACE" exec -i "deploy/$pg" -- \
           sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -tAq -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' 2>/dev/null <<SQL
SELECT CASE WHEN to_regclass('"public"."AIProvider"') IS NULL THEN 'off' ELSE 'on' END AS have_ai \gset
\if :have_ai
WITH realigned AS (
  UPDATE "public"."AIProvider"
     SET config = jsonb_set(
                    jsonb_set(coalesce(config, '{}'::jsonb),
                              '{apiKey}', to_jsonb('$key'::text), true),
                    '{baseUrl}', to_jsonb('$url'::text), true),
         "updatedAt" = now()
   WHERE $scope
     AND (config->>'apiKey' IS DISTINCT FROM '$key'
       OR config->>'baseUrl' IS DISTINCT FROM '$url')
  RETURNING 1
)
SELECT 'realigned=' || count(*) FROM realigned;
\else
\echo realigned=no-table
\endif
SQL
  )" || out=""
  case "$out" in
    realigned=no-table)
      info "vLLM provider key: no AIProvider table yet (the app's migrations have not run) — nothing to realign." ;;
    realigned=0)
      info "vLLM provider key: the stored row already matches this box." ;;
    realigned=[1-9]*)
      log "vLLM provider key: realigned ${out#realigned=} AIProvider row(s) onto the current key."
      info "  That row is the only copy an LLM call reads; a key change anywhere"
      info "  else leaves it stale and every call 401s with every pod Running." ;;
    "")
      warn "vLLM provider key: could not reach the database in deploy/$pg — row NOT realigned." ;;
    *)
      warn "vLLM provider key: unexpected psql output while realigning: $out" ;;
  esac
  :
}

# Read the key back OUT of Postgres and ask vLLM about it. Never dies: it
# records its verdict in VLLM_DB_VERIFIED and lets the caller decide. DEEP=1
# also exercises chat + embeddings (the two routes the nginx proxy sends to
# DIFFERENT containers), DEEP=0 stops at /v1/models.
verify_vllm_db_key() { # verify_vllm_db_key BASE_URL [DEEP]
  VLLM_DB_VERIFIED=unknown
  local url="$1" deep="${2:-0}" pg="" raw="" base="" dbkey="" scope=""
  local code="" verdict="" tries=2 i=0 bad=0
  local -a klist=()
  if ! vllm_url_sane "$url"; then
    warn "stored vLLM key NOT verified: '$url' is not a usable base URL."
    return 0
  fi
  pg="$(vllm_pg_deploy)"
  if [[ -z "$pg" ]]; then
    warn "stored vLLM key NOT verified: no *-postgres deployment in ns/$NAMESPACE."
    return 0
  fi
  base="${url%/v1}"
  scope="$(vllm_row_scope "$url")"

  # The SAME row scope the reconcile used, so the two can never disagree about
  # which row is ours. The `rows` sentinel is what separates "the table is there
  # and empty" from "psql never ran" — both are otherwise an empty string.
  raw="$(kc -n "$NAMESPACE" exec -i "deploy/$pg" -- \
           sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -tAq -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' 2>/dev/null <<SQL
SELECT CASE WHEN to_regclass('"public"."AIProvider"') IS NULL THEN 'off' ELSE 'on' END AS have_ai \gset
\if :have_ai
\echo rows
SELECT DISTINCT 'k=' || coalesce(config->>'apiKey', '')
  FROM "public"."AIProvider"
 WHERE $scope;
\else
\echo no-table
\endif
SQL
  )" || raw=""

  if [[ -z "$raw" ]]; then
    warn "could not read the stored provider key out of deploy/$pg — NOT verified."
    return 0
  fi
  if [[ "$raw" == "no-table" ]]; then
    warn "no AIProvider table yet (the app's migrations have not run) — nothing to verify."
    VLLM_DB_VERIFIED=notable
    return 0
  fi
  # Every row comes back as `k=<key>`, so a row whose config carries NO apiKey
  # is an EMPTY key rather than an absent line — otherwise it would be
  # indistinguishable from "no row at all" and a stale box would pass as fresh.
  mapfile -t klist < <(awk '/^k=/ {print substr($0, 3)}' <<<"$raw")
  if (( ${#klist[@]} == 0 )); then
    warn "no vLLM provider row on this box yet — nothing to verify."
    warn "  The app seeds it ONCE, at the first organization creation. Until"
    warn "  then there is nothing that can be stale."
    VLLM_DB_VERIFIED=norow
    return 0
  fi
  if (( ${#klist[@]} > 1 )); then
    warn "${#klist[@]} DIFFERENT stored keys across the vLLM rows — realignment did not converge."
    VLLM_DB_VERIFIED=stale
    return 0
  fi
  dbkey="${klist[0]}"
  if [[ -z "$dbkey" ]]; then
    warn "the stored vLLM provider row carries NO apiKey field at all."
    warn "  The app omits it when its own env var is empty (vllm-provider.ts:42-44)."
    VLLM_DB_VERIFIED=stale
    return 0
  fi

  if [[ "$deep" == "1" ]]; then
    tries=6
  fi
  verdict=down
  for (( i = 0; i < tries; i++ )); do
    code="$(vllm_http_code "$base/v1/models" "$dbkey" 5)"
    verdict="$(vllm_verdict "$code")"
    if [[ "$verdict" != "down" ]]; then
      break
    fi
    sleep 10
  done
  if [[ "$verdict" == "denied" ]]; then
    warn "the key STORED IN POSTGRES is REJECTED by vLLM (HTTP $code on /v1/models)."
    VLLM_DB_VERIFIED=stale
    return 0
  fi
  if [[ "$verdict" == "down" ]]; then
    warn "vLLM did not answer /v1/models (HTTP $code) — stored key NOT verified."
    warn "  This is NOT a failure: the models can still be loading."
    warn "  Watch: docker logs -f suite366-vllm-llm"
    return 0
  fi
  info "  stored key accepted on /v1/models (HTTP $code)."
  VLLM_DB_VERIFIED=ok
  if [[ "$deep" != "1" ]]; then
    return 0
  fi

  # /v1/embeddings is the ONLY call that proves the embed container holds the
  # same key: lib/vllm.sh:66-73 recreates the stack only when llm/.env changed,
  # so a partial restart really can leave one container on the old key.
  if [[ -n "${LLM_MODEL:-}" ]]; then
    case "$(vllm_verdict "$(vllm_http_code "$base/v1/chat/completions" "$dbkey" 60 \
              "{\"model\":\"$LLM_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}")")" in
      denied) bad=1; warn "  /v1/chat/completions REJECTED the stored key." ;;
      down)   warn "  /v1/chat/completions did not answer — not verified (models loading?)." ;;
      *)      info "  stored key accepted on /v1/chat/completions." ;;
    esac
  fi
  if [[ -n "${EMBED_MODEL:-}" ]]; then
    case "$(vllm_verdict "$(vllm_http_code "$base/v1/embeddings" "$dbkey" 30 \
              "{\"model\":\"$EMBED_MODEL\",\"input\":\"ping\"}")")" in
      denied) bad=1; warn "  /v1/embeddings REJECTED the stored key (the embed container is on another key)." ;;
      down)   warn "  /v1/embeddings did not answer — not verified (models loading?)." ;;
      *)      info "  stored key accepted on /v1/embeddings." ;;
    esac
  fi
  if (( bad )); then
    VLLM_DB_VERIFIED=stale
  fi
  :
}

# Derive the key, the unified-proxy URL and the model names from the box itself,
# for the two standalone scripts that know none of them. llm/.env comes FIRST on
# purpose: it is the file the vLLM containers read at start, so it holds the key
# that will actually be ACCEPTED. values.yaml is only what the app was TOLD.
# Read line by line rather than sourced — llm/.env also carries HF_TOKEN, and
# these scripts have no business holding it even briefly.
# Returns NON-ZERO when no key can be found, so callers must use `if`.
vllm_local_env() {
  VLLM_KEY=""; VLLM_URL=""
  local envf="$DATA_DIR/llm/.env" vals="$DATA_DIR/values.yaml" ip="" port="" vkey=""
  if [[ -f "$envf" ]]; then
    VLLM_KEY="$(sed -n 's/^VLLM_API_KEY=//p' "$envf" | head -1)"
    ip="$(sed -n 's/^BIND_IP=//p' "$envf" | head -1)"
    port="$(sed -n 's/^PROXY_PORT=//p' "$envf" | head -1)"
    LLM_MODEL="${LLM_MODEL:-$(sed -n 's/^LLM_MODEL=//p' "$envf" | head -1)}"
    EMBED_MODEL="${EMBED_MODEL:-$(sed -n 's/^EMBED_MODEL=//p' "$envf" | head -1)}"
    if [[ -n "$ip" && -n "$port" ]]; then
      VLLM_URL="http://$ip:$port/v1"
    fi
  fi
  # A SKIP_VLLM box has no llm/.env at all; values.yaml always exists — it is
  # what lib/preflight.sh:466-467 itself reads back on a re-run.
  if [[ -z "$VLLM_KEY" && -f "$vals" ]]; then
    VLLM_KEY="$(sed -n 's/.*VLLM_API_KEY: *"\(sk-[^"]*\)".*/\1/p' "$vals" | head -1)"
  fi
  if [[ -z "$VLLM_URL" && -f "$vals" ]]; then
    VLLM_URL="$(sed -n 's|.*VLLM_BASE_URL: *"\(http://[^"]*\)".*|\1|p' "$vals" | head -1)"
  fi
  # The divergence nobody checks today: if these two disagree, the app's own env
  # and the running containers hold DIFFERENT keys, and realigning the database
  # to either one still leaves the other path 401ing. Only a re-render plus a
  # helm upgrade fixes that, so say it instead of silently picking a winner.
  if [[ -f "$envf" && -f "$vals" ]]; then
    vkey="$(sed -n 's/.*VLLM_API_KEY: *"\(sk-[^"]*\)".*/\1/p' "$vals" | head -1)"
    if [[ -n "$vkey" && -n "$VLLM_KEY" && "$vkey" != "$VLLM_KEY" ]]; then
      warn "values.yaml and llm/.env carry DIFFERENT vLLM keys — the app's own env is"
      warn "  wrong whatever the database says. Re-run: sudo $DATA_DIR/install.sh"
    fi
  fi
  [[ -n "$VLLM_KEY" && -n "$VLLM_URL" ]]
}

# One line per call site in the standalone scripts. DEEP=1 after something that
# re-pushed the Secret or reloaded the database; DEEP=0 for the daily check,
# which must not POST to the LLM every night.
reconcile_and_check_vllm_db() { # reconcile_and_check_vllm_db DEEP(0|1)
  local deep="${1:-0}"
  if ! vllm_local_env; then
    warn "vLLM provider key: no key in $DATA_DIR/llm/.env nor values.yaml — DB row left alone."
    return 0
  fi
  reconcile_vllm_db_key "$VLLM_KEY" "$VLLM_URL"
  verify_vllm_db_key "$VLLM_URL" "$deep"
  if [[ "${VLLM_DB_VERIFIED:-unknown}" == "stale" ]]; then
    warn "The vLLM key stored in Postgres is REJECTED by vLLM — every LLM call in"
    warn "  the app will 401. Re-run: sudo $DATA_DIR/install.sh"
  fi
  :
}

# <<< END SHARED vllm-db BLOCK <<<

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
    # Convergence belongs here, not only in `apply`. `apply` runs when there is
    # something to apply; a box sitting on the current version never triggers
    # it, so putting convergence there alone means the appliances that need the
    # backup agent most — the ones nobody has touched in months — are exactly
    # the ones that never receive it.
    converge_backup
    # Same argument, applied to the vLLM key the app reads out of Postgres: the
    # box that has drifted is the box nobody has touched, so the daily check is
    # what turns "undetected until a customer complains" into "self-healed
    # within 24 hours". DEEP=0 — no nightly POST to the LLM.
    reconcile_and_check_vllm_db 0
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
