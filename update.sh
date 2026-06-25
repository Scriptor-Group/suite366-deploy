#!/usr/bin/env bash
# =============================================================================
# Suite 366 — update checker / applier for the DGX Spark appliance.
#
# Reads a channel manifest (channel.json) that YOU publish in the
# suite366-deploy repo, compares the target versions to what this box is
# actually running, and either:
#   • NOTIFIES (default — used by the daily systemd timer): logs + drops a
#     marker file + optional webhook. Makes NO changes.
#   • APPLIES the upgrade (manual: `sudo /opt/suite366/update.sh apply`).
#
# The manifest decouples "the latest version that exists" from "the version
# the fleet should run": you push channel.json -> the fleet rolls out. No
# per-box edits, no in-the-blind tracking of `latest`.
#
# Modes:
#   check   (default) fetch manifest, compare, write marker + log. No changes.
#   apply             helm upgrade (+ vLLM image pull if changed), then a
#                     health check. Idempotent (no-op if already up to date).
#
# Config (env, or $DATA_DIR/update.env — all optional, defaults match
# install.sh):
#   MANIFEST_URL    where channel.json lives (default: raw GitHub main)
#   CHART_REF       OCI chart ref          NAMESPACE / RELEASE / DATA_DIR
#   KUBECONFIG_PATH /etc/rancher/k3s/k3s.yaml
#   UPDATE_WEBHOOK  optional URL — POSTed {"text":"…"} on update-available
# =============================================================================
set -euo pipefail

MODE="${1:-check}"

DATA_DIR="${DATA_DIR:-/opt/suite366}"
# Pull in the install-time config if present (manual runs); the systemd unit
# also passes this same file via EnvironmentFile=.
[[ -f "$DATA_DIR/update.env" ]] && . "$DATA_DIR/update.env"

MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/Scriptor-Group/suite366-deploy/main/channel.json}"
CHART_REF="${CHART_REF:-oci://ghcr.io/scriptor-group/chart/drive}"
NAMESPACE="${NAMESPACE:-suite366}"
RELEASE="${RELEASE:-drive}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
UPDATE_WEBHOOK="${UPDATE_WEBHOOK:-}"
MARKER="$DATA_DIR/update-available"

export KUBECONFIG="$KUBECONFIG_PATH"

c_b="\033[1m"; c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_0="\033[0m"
log()  { printf "${c_g}==>${c_0} ${c_b}%s${c_0}\n" "$*"; }
info() { printf "    %s\n" "$*"; }
warn() { printf "${c_y}!!  %s${c_0}\n" "$*"; }
die()  { printf "${c_r}xx  %s${c_0}\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
kc()   { k3s kubectl "$@"; }

# Minimal extractor for the FLAT channel.json (avoids a jq dependency — jq is
# not guaranteed on DGX OS). Reads JSON on stdin, prints the string value.
json_get() { # json_get KEY
  sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1
}

[[ "$(id -u)" == "0" ]] || die "Run as root (sudo)."
have helm || die "helm not found."
have k3s  || die "k3s not found."
have curl || die "curl required."

# --- Current state on this box ----------------------------------------------
# helm list reports the chart as "<chart-name>-<version>" (e.g. drive-0.7.0);
# grab the trailing version (first char a digit) regardless of the chart name.
cur_chart="$(helm list -n "$NAMESPACE" --filter "^${RELEASE}$" -o json 2>/dev/null \
  | sed -n 's/.*"chart":"[^"]*-\([0-9][^"]*\)".*/\1/p' | head -1)"
[[ -n "$cur_chart" ]] || warn "Could not read current chart version (release '$RELEASE' in ns '$NAMESPACE')."

cur_vllm=""
[[ -f "$DATA_DIR/llm/.env" ]] && cur_vllm="$(sed -n 's/^VLLM_IMAGE=//p' "$DATA_DIR/llm/.env" | head -1)"

# --- Target state from the manifest -----------------------------------------
log "Fetching channel manifest"
info "$MANIFEST_URL"
manifest="$(curl -fsSL -m 20 "$MANIFEST_URL")" || die "Manifest unreachable: $MANIFEST_URL"
channel="$(json_get channel       <<<"$manifest")"
want_chart="$(json_get chart_version <<<"$manifest")"
want_vllm="$(json_get vllm_image    <<<"$manifest")"
[[ -n "$want_chart" ]] || die "Manifest has no chart_version: $MANIFEST_URL"

info "channel        : ${channel:-?}"
info "chart  running : ${cur_chart:-unknown}    target : $want_chart"
info "vLLM   running : ${cur_vllm:-unknown}    target : ${want_vllm:-unchanged}"

chart_diff=0; vllm_diff=0
[[ -n "$cur_chart" && "$cur_chart" != "$want_chart" ]] && chart_diff=1
[[ -n "$want_vllm" && -n "$cur_vllm" && "$cur_vllm" != "$want_vllm" ]] && vllm_diff=1

if [[ "$chart_diff" == 0 && "$vllm_diff" == 0 ]]; then
  log "Up to date (chart ${cur_chart:-?}, channel ${channel:-?})."
  rm -f "$MARKER"
  exit 0
fi

# --- Build a one-line human summary of what's available ----------------------
parts=()
[[ "$chart_diff" == 1 ]] && parts+=("chart ${cur_chart:-?} -> $want_chart")
[[ "$vllm_diff"  == 1 ]] && parts+=("vLLM image -> $want_vllm")
summary_line="$(IFS='; '; echo "${parts[*]}")"

notify() {
  warn "UPDATE AVAILABLE (channel ${channel:-?}): $summary_line"
  ( umask 077
    cat > "$MARKER" <<EOF
Suite 366 update available — channel ${channel:-?}
  $summary_line
Apply with:  sudo $DATA_DIR/update.sh apply
EOF
  )
  logger -t suite366-update "update available: $summary_line" 2>/dev/null || true
  if [[ -n "$UPDATE_WEBHOOK" ]]; then
    curl -fsS -m 10 -H 'Content-Type: application/json' \
      -d "{\"text\":\"Suite 366 update available ($(hostname)): $summary_line\"}" \
      "$UPDATE_WEBHOOK" >/dev/null 2>&1 \
      && info "webhook notified." || warn "webhook POST failed (non-blocking)."
  fi
  info "Run 'sudo $DATA_DIR/update.sh apply' to upgrade."
}

do_apply() {
  local vals="$DATA_DIR/values.yaml"
  [[ -f "$vals" ]] || die "values.yaml not found at $vals — was this box installed by install.sh?"

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

  if [[ "$chart_diff" == 1 ]]; then
    log "helm upgrade $RELEASE: $cur_chart -> $want_chart"
    helm upgrade "$RELEASE" "$CHART_REF" \
      --version "$want_chart" -n "$NAMESPACE" -f "$vals" --wait --timeout 15m \
      || die "helm upgrade failed — roll back with: sudo helm rollback $RELEASE -n $NAMESPACE"
  fi

  log "Health check"
  kc -n "$NAMESPACE" wait --for=condition=Available deploy --all --timeout=180s \
    || warn "Not all deployments became Available — check: sudo k3s kubectl -n $NAMESPACE get pods"
  rm -f "$MARKER"
  log "Update complete (now on chart $want_chart, channel ${channel:-?})."
}

case "$MODE" in
  check) notify ;;
  apply) do_apply ;;
  *)     die "Unknown mode '$MODE' (use: check | apply)" ;;
esac
