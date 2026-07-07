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
# Modes:
#   check         (default) fetch manifest, compare, write marker + state.json.
#                 No changes.
#   apply         helm upgrade (+ vLLM image / app image pin updates), then a
#                 health check. Idempotent (no-op if already up to date).
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
#                   sibling of MANIFEST_URL). Set SELF_UPDATE=0 to disable.
# =============================================================================
set -euo pipefail

MODE="${1:-check}"

DATA_DIR="${DATA_DIR:-/opt/suite366}"
# Pull in the install-time config if present (manual runs); the systemd units
# also pass this same file via EnvironmentFile=.
[[ -f "$DATA_DIR/update.env" ]] && . "$DATA_DIR/update.env"

MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/Scriptor-Group/suite366-deploy/main/channel.json}"
CHART_REF="${CHART_REF:-oci://ghcr.io/scriptor-group/chart/drive}"
NAMESPACE="${NAMESPACE:-suite366}"
RELEASE="${RELEASE:-drive}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
UPDATE_WEBHOOK="${UPDATE_WEBHOOK:-}"
SELF_UPDATE="${SELF_UPDATE:-1}"
SELF_URL="${SELF_URL:-${MANIFEST_URL%/*}/update.sh}"
MARKER="$DATA_DIR/update-available"

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
  local tmp="$STATE_JSON.tmp"
  cat > "$tmp" <<EOF
{
  "schema": 1,
  "channel": "$(json_esc "${channel:-}")",
  "checked_at": "$(now_utc)",
  "update_available": $avail,
  "summary": "$(json_esc "${summary_line:-}")",
  "notes": "$(json_esc "${notes:-}")",
  "current": {
    "chart": "$(json_esc "${cur_chart:-}")",
    "app": "$(json_esc "${cur_app:-}")",
    "vllm": "$(json_esc "${cur_vllm:-}")"
  },
  "target": {
    "chart": "$(json_esc "${want_chart:-}")",
    "app": "$(json_esc "${want_app:-}")",
    "vllm": "$(json_esc "${want_vllm:-}")"
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

# --- Target state from the manifest -------------------------------------------
fetch_manifest() {
  log "Fetching channel manifest"
  info "$MANIFEST_URL"
  manifest="$(curl -fsSL -m 20 "$MANIFEST_URL")" || die "Manifest unreachable: $MANIFEST_URL"
  channel="$(json_get channel        <<<"$manifest")"
  want_chart="$(json_get chart_version <<<"$manifest")"
  want_vllm="$(json_get vllm_image     <<<"$manifest")"
  want_app="$(json_get app_version     <<<"$manifest")"
  notes="$(json_get notes              <<<"$manifest")"
  [[ -n "$want_chart" ]] || die "Manifest has no chart_version: $MANIFEST_URL"

  info "channel        : ${channel:-?}"
  info "chart  running : ${cur_chart:-unknown}    target : $want_chart"
  info "app    running : ${cur_app:-unknown}    target : ${want_app:-unchanged}"
  info "vLLM   running : ${cur_vllm:-unknown}    target : ${want_vllm:-unchanged}"

  chart_diff=0; vllm_diff=0; app_diff=0
  [[ -n "$cur_chart" && "$cur_chart" != "$want_chart" ]] && chart_diff=1
  [[ -n "$want_vllm" && -n "$cur_vllm" && "$cur_vllm" != "$want_vllm" ]] && vllm_diff=1
  [[ -n "$want_app"  && -n "$cur_app"  && "$cur_app"  != "$want_app"  ]] && app_diff=1

  # One-line human summary of what's available.
  local parts=()
  [[ "$chart_diff" == 1 ]] && parts+=("chart ${cur_chart:-?} -> $want_chart")
  [[ "$app_diff"   == 1 ]] && parts+=("app ${cur_app:-?} -> $want_app")
  [[ "$vllm_diff"  == 1 ]] && parts+=("vLLM image -> $want_vllm")
  summary_line="$(IFS='; '; echo "${parts[*]}")"
}

up_to_date() { [[ "$chart_diff" == 0 && "$vllm_diff" == 0 && "$app_diff" == 0 ]]; }

# --- check (notify-only) -------------------------------------------------------
notify() {
  consume_trigger check-requested
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

  if [[ "$vllm_diff" == 1 ]]; then
    log "vLLM image: $cur_vllm -> $want_vllm"
    [[ -f "$DATA_DIR/llm/.env" ]] || die "$DATA_DIR/llm/.env missing — cannot retarget vLLM image."
    sed -i "s|^VLLM_IMAGE=.*|VLLM_IMAGE=$want_vllm|" "$DATA_DIR/llm/.env"
    if ( cd "$DATA_DIR/llm" && docker compose pull && docker compose up -d ); then
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
    helm upgrade "$RELEASE" "$CHART_REF" \
      --version "$want_chart" -n "$NAMESPACE" -f "$vals" "${extra_vals[@]}" \
      --wait --timeout 15m \
      || die "helm upgrade failed — roll back with: sudo helm rollback $RELEASE -n $NAMESPACE"
  fi

  log "Health check"
  kc -n "$NAMESPACE" wait --for=condition=Available deploy --all --timeout=180s \
    || warn "Not all deployments became Available — check: sudo k3s kubectl -n $NAMESPACE get pods"

  if [[ "$app_diff" == 1 ]]; then
    # sandbox-runner is spawned on demand (not by Helm) — pre-pull it so the
    # sandbox works offline after the upgrade. Best-effort.
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
  write_state_json 0
  write_apply_json success "update complete (chart $want_chart, app ${cur_app:-?}, channel ${channel:-?})"
  trap - EXIT
  log "Update complete (now on chart $want_chart, channel ${channel:-?})."

  # Fleet convergence: make sure the app-trigger units exist / are current,
  # and refresh this script from the channel repo for the next run.
  install_units
  self_update
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
self_update() {
  [[ "$SELF_UPDATE" == "1" ]] || return 0
  local tmp; tmp="$(mktemp)"
  if curl -fsSL -m 20 "$SELF_URL" -o "$tmp" && [[ -s "$tmp" ]] && bash -n "$tmp" 2>/dev/null; then
    if ! cmp -s "$tmp" "$DATA_DIR/update.sh"; then
      install -m 0700 "$tmp" "$DATA_DIR/update.sh"
      info "update.sh refreshed from $SELF_URL."
    fi
  else
    warn "could not refresh update.sh from $SELF_URL (non-blocking)."
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
    read_current_state
    fetch_manifest
    notify
    ;;
  apply)
    require_cluster_tools
    read_current_state
    fetch_manifest
    do_apply
    ;;
  install-units)
    install_units
    ;;
  *)
    die "Unknown mode '$MODE' (use: check | apply | install-units)"
    ;;
esac
