#!/usr/bin/env bash
# =============================================================================
# Suite 366 — appliance backup agent.
#
#   backup.sh init | run | test | status | snapshots | prune | restore
#             | install-units
#
# WHY THIS RUNS ON THE HOST, NOT AS A CronJob
# The one moment a backup matters is the moment the appliance is broken — which
# is exactly when an in-cluster CronJob is not running. This agent also reads
# things no pod can see: $DATA_DIR (values.yaml, the CA *and its private key*)
# and the local-path PVC directories on the node's disk. Hence: root, a systemd
# timer, and restic.
#
# WHAT A BACKUP CONTAINS, and why each piece is in or out
#   postgres  pg_dump -Fc streamed straight into `restic backup --stdin`. A
#             logical dump, so it restores into a fresh Postgres whose password
#             differs — which is the normal case after a reinstall.
#   minio     the PVC directory, with `.minio.sys` EXCLUDED. Objects are whole
#             files; MinIO's own IAM/config is not, and restoring one install's
#             .minio.sys over another's root credentials locks you out of the
#             very data you just restored.
#   config    $DATA_DIR minus models/ (33+ GiB, re-downloadable) — values.yaml,
#             llm/.env, update.env, the local CA.
#   secrets   `secret-<app>` and the cert-manager CA secret, as YAML.
#             See below: this is the part that decides whether a restore works.
#   NOT       redis (sessions/queues), the OnlyOffice PVC (cache), workbench
#             PVCs (per-user scratch, hundreds of GiB), models/.
#
# THE ONE SECRET THAT MATTERS: AUTH_SECRET
# The app derives its at-rest encryption key from AUTH_SECRET (see
# suite-366 serveur/src/lib/encryption.ts). The chart REGENERATES any secret it
# cannot find, so a restore that does not carry AUTH_SECRET over produces a
# database that starts up fine and whose stored provider keys and OAuth tokens
# are permanently unreadable — with no error anywhere. That is why the secrets
# snapshot exists, and why the restore runbook patches AUTH_SECRET before
# touching the data.
#
# ENCRYPTION
# restic encrypts the repository with a key held ONLY in $BACKUP_DIR/repo.pass
# (0600) — generated at install and printed once. Lose it and the backups are
# unreadable: that is the point of the key, and the reason a rented appliance
# escrows it (suite366-fleet) while a sold one ships it on a card in the box.
# =============================================================================
set -euo pipefail

MODE="${1:-status}"

DATA_DIR="${DATA_DIR:-/opt/suite366}"
BACKUP_DIR="${BACKUP_DIR:-$DATA_DIR/backup}"
BACKUP_ENV="${BACKUP_ENV:-$BACKUP_DIR/backup.env}"
PASS_FILE="${PASS_FILE:-$BACKUP_DIR/repo.pass}"
STATE_JSON="$BACKUP_DIR/state.json"
LOCK_FILE="$BACKUP_DIR/.lock"
RESTIC_BIN="${RESTIC_BIN:-$DATA_DIR/bin/restic}"
NAMESPACE="${NAMESPACE:-suite366}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
APP_GID="${APP_GID:-1001}"

# Destination + retention live in backup.env (written by lib/backup.sh at
# install time, or by the host agent when the app UI configures it in lot C).
# Sourced BEFORE the defaults below so an operator editing that file wins.
# shellcheck disable=SC1090
[[ -f "$BACKUP_ENV" ]] && source "$BACKUP_ENV"

BACKUP_REPO="${BACKUP_REPO:-}"
BACKUP_KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"
BACKUP_KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"
BACKUP_KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-6}"
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-02:40}"
# Resource discovery. Derived from the cluster by default (so renaming appName
# does not silently break the backup), overridable when discovery guesses wrong.
PG_DEPLOY="${PG_DEPLOY:-}"
MINIO_PVC="${MINIO_PVC:-}"

export KUBECONFIG="$KUBECONFIG_PATH"

c_b="\033[1m"; c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_0="\033[0m"
log()  { printf "${c_g}==>${c_0} ${c_b}%s${c_0}\n" "$*"; }
info() { printf "    %s\n" "$*"; }
warn() { printf "${c_y}!!  %s${c_0}\n" "$*"; }
die()  { printf "${c_r}xx  %s${c_0}\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
kc()   { k3s kubectl "$@"; }
now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

json_esc() {
  local s=${1//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# A repository URL may legitimately carry credentials (s3:https://key:secret@…).
# state.json is world-readable so the app can display it — strip anything
# between the scheme and an @ before it is ever written or logged.
redact_repo() { # redact_repo URL
  printf '%s' "$1" | sed -E 's#(//)[^/@]*@#\1<redacted>@#'
}

[[ "$(id -u)" == "0" ]] || die "Run as root (sudo)."

ensure_backup_dir() {
  mkdir -p "$BACKUP_DIR"
  # root:APP_GID 0770, matching $DATA_DIR/updates: lot C mounts this directory
  # into drive-app so the UI can read state.json and drop config requests, and
  # k8s does not fsGroup-chown a hostPath.
  chown "root:$APP_GID" "$BACKUP_DIR" 2>/dev/null || true
  chmod 0770 "$BACKUP_DIR"
}

# --- restic invocation --------------------------------------------------------
# HOME and RESTIC_CACHE_DIR are not optional. Under systemd there is no HOME,
# and restic >= 0.19 refuses to run without a usable cache directory rather
# than falling back to a temp one — a backup that works by hand and fails from
# the timer is exactly the failure this avoids.
restic_env() {
  export HOME="$BACKUP_DIR"
  export XDG_CACHE_HOME="$BACKUP_DIR/cache"
  export RESTIC_CACHE_DIR="$BACKUP_DIR/cache"
  export RESTIC_REPOSITORY="$BACKUP_REPO"
  export RESTIC_PASSWORD_FILE="$PASS_FILE"
  mkdir -p "$RESTIC_CACHE_DIR"; chmod 0700 "$RESTIC_CACHE_DIR"
  # S3-compatible destinations read the standard AWS names. Set from the
  # BACKUP_S3_* pair when present so backup.env needs only one naming scheme.
  [[ -n "${BACKUP_S3_ACCESS_KEY:-}" ]] && export AWS_ACCESS_KEY_ID="$BACKUP_S3_ACCESS_KEY"
  [[ -n "${BACKUP_S3_SECRET_KEY:-}" ]] && export AWS_SECRET_ACCESS_KEY="$BACKUP_S3_SECRET_KEY"
  [[ -n "${BACKUP_S3_REGION:-}"     ]] && export AWS_DEFAULT_REGION="$BACKUP_S3_REGION"
  :
}

res() { "$RESTIC_BIN" "$@"; }

require_restic() {
  [[ -x "$RESTIC_BIN" ]] || die "restic not found at $RESTIC_BIN (re-run install.sh, or set RESTIC_BIN)."
}

# Is this box configured to back up at all? A fresh appliance is not: the
# destination is a customer decision. Callers distinguish "nothing to do" from
# "broken", because a timer that fails nightly on an unconfigured box trains
# everyone to ignore it.
configured() {
  [[ -n "$BACKUP_REPO" && -s "$PASS_FILE" ]]
}

key_fingerprint() {
  [[ -s "$PASS_FILE" ]] || return 0
  sha256sum "$PASS_FILE" | cut -c1-12
}

# --- state.json (read by `status`, and by the app UI in lot C) ----------------
STATE_STATUS="unknown"; STATE_ERROR=""; STATE_STARTED=""; STATE_FINISHED=""
STATE_SNAPSHOTS="[]"; STATE_REPO_SIZE=""
write_state_json() {
  ensure_backup_dir
  local tmp="$STATE_JSON.tmp" cfg=false
  configured && cfg=true
  cat > "$tmp" <<EOF
{
  "schema": 1,
  "configured": $cfg,
  "repository": "$(json_esc "$(redact_repo "$BACKUP_REPO")")",
  "key_fingerprint": "$(json_esc "$(key_fingerprint)")",
  "updated_at": "$(now_utc)",
  "schedule": "$(json_esc "$BACKUP_SCHEDULE")",
  "retention": {
    "daily": $BACKUP_KEEP_DAILY,
    "weekly": $BACKUP_KEEP_WEEKLY,
    "monthly": $BACKUP_KEEP_MONTHLY
  },
  "last_run": {
    "status": "$(json_esc "$STATE_STATUS")",
    "started_at": "$(json_esc "$STATE_STARTED")",
    "finished_at": "$(json_esc "$STATE_FINISHED")",
    "error": "$(json_esc "$STATE_ERROR")"
  },
  "repo_size": "$(json_esc "$STATE_REPO_SIZE")",
  "snapshots": $STATE_SNAPSHOTS
}
EOF
  chmod 0644 "$tmp"; mv -f "$tmp" "$STATE_JSON"
}

# Preserve the previous run's outcome when writing state for a reason other
# than a run (e.g. `test`), so a connectivity check does not erase the record
# of last night's backup.
load_previous_state() {
  [[ -f "$STATE_JSON" ]] || return 0
  STATE_STATUS="$(sed -n 's/.*"status": *"\([^"]*\)".*/\1/p' "$STATE_JSON" | head -1)"
  STATE_STARTED="$(sed -n 's/.*"started_at": *"\([^"]*\)".*/\1/p' "$STATE_JSON" | head -1)"
  STATE_FINISHED="$(sed -n 's/.*"finished_at": *"\([^"]*\)".*/\1/p' "$STATE_JSON" | head -1)"
  STATE_ERROR="$(sed -n 's/.*"error": *"\([^"]*\)".*/\1/p' "$STATE_JSON" | head -1)"
  :
}

# --- resource discovery -------------------------------------------------------
# By name pattern rather than a hardcoded `drive-postgres`: the chart derives
# every resource name from `appName`, so a deployment that sets it to something
# else would otherwise back up nothing at all — silently.
discover_pg() {
  [[ -n "$PG_DEPLOY" ]] && { printf '%s' "$PG_DEPLOY"; return 0; }
  kc -n "$NAMESPACE" get deploy -o name 2>/dev/null \
    | sed -n 's|^deployment.apps/||p' | grep -- '-postgres$' | head -1
}

discover_minio_pvc() {
  [[ -n "$MINIO_PVC" ]] && { printf '%s' "$MINIO_PVC"; return 0; }
  kc -n "$NAMESPACE" get pvc -o name 2>/dev/null \
    | sed -n 's|^persistentvolumeclaim/||p' | grep -- '-minio-pvc$' | head -1
}

# local-path publishes a `local` volume; older provisioners used hostPath.
# Try both rather than assume.
pvc_host_path() { # pvc_host_path PVC_NAME
  local pvc="$1" pv path
  pv="$(kc -n "$NAMESPACE" get pvc "$pvc" -o jsonpath='{.spec.volumeName}' 2>/dev/null || true)"
  [[ -n "$pv" ]] || return 1
  path="$(kc get pv "$pv" -o jsonpath='{.spec.local.path}' 2>/dev/null || true)"
  [[ -n "$path" ]] || path="$(kc get pv "$pv" -o jsonpath='{.spec.hostPath.path}' 2>/dev/null || true)"
  [[ -n "$path" ]] || return 1
  printf '%s' "$path"
}

# --- the four backup units ----------------------------------------------------
# The password never leaves the cluster and never appears in an argv: the
# postgres pod already holds POSTGRES_* in its environment, so the dump command
# reads them there.
backup_postgres() {
  local deploy; deploy="$(discover_pg)"
  [[ -n "$deploy" ]] || { warn "no *-postgres deployment in ns/$NAMESPACE — skipping the database."; return 1; }
  info "postgres: pg_dump from deploy/$deploy"
  # `if` rather than `|| rc=1`: PIPESTATUS survives only until the next
  # pipeline, and an assignment IS one — reading it after `|| rc=1` yields the
  # assignment's status, not the dump's. Under `set -u` that then blew up on
  # the unset second element and killed the whole run.
  if kc -n "$NAMESPACE" exec "deploy/$deploy" -- \
       sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
     | res backup --stdin --stdin-filename postgres.dump --tag suite366 --tag postgres
  then
    return 0
  fi
  # Which side failed matters: a pg_dump that dies mid-stream still hands
  # restic a perfectly storable TRUNCATED dump. That is the worst outcome
  # available — it looks like a successful backup until someone restores it —
  # so it is reported as a failure of the run, not a warning inside a success.
  local st=("${PIPESTATUS[@]}")
  if [[ "${st[0]:-1}" != "0" ]]; then
    warn "pg_dump failed (exit ${st[0]:-?}) — refusing to count a truncated dump as a backup."
  else
    warn "restic refused the database stream (exit ${st[1]:-?})."
  fi
  return 1
}

backup_minio() {
  local pvc path
  pvc="$(discover_minio_pvc)"
  [[ -n "$pvc" ]] || { warn "no *-minio-pvc in ns/$NAMESPACE — skipping object storage."; return 1; }
  path="$(pvc_host_path "$pvc")" || { warn "could not resolve the host path of $pvc — skipping object storage."; return 1; }
  [[ -d "$path" ]] || { warn "$path does not exist on this node — skipping object storage."; return 1; }
  info "minio: $path (excluding .minio.sys)"
  res backup "$path" \
    --exclude "$path/.minio.sys" \
    --tag suite366 --tag minio || return 1
}

backup_config() {
  info "config: $DATA_DIR (excluding models/, cache/, the key itself)"
  res backup "$DATA_DIR" \
    --exclude "$DATA_DIR/models" \
    --exclude "$DATA_DIR/backup/cache" \
    --exclude "$PASS_FILE" \
    --exclude "$DATA_DIR/bin" \
    --tag suite366 --tag config || return 1
}

# AUTH_SECRET lives here. See the header.
backup_secrets() {
  local app_secret ca_secret rc=0
  app_secret="$(kc -n "$NAMESPACE" get secret -o name 2>/dev/null \
    | sed -n 's|^secret/||p' | grep '^secret-' | head -1)"
  if [[ -n "$app_secret" ]]; then
    info "secrets: $app_secret (carries AUTH_SECRET)"
    kc -n "$NAMESPACE" get secret "$app_secret" -o yaml \
      | res backup --stdin --stdin-filename app-secret.yaml --tag suite366 --tag secrets || rc=1
  else
    warn "no secret-* found in ns/$NAMESPACE — a restore will NOT be able to keep AUTH_SECRET."
    rc=1
  fi
  # The local CA's PRIVATE key. Without it a rebuilt box gets a new CA and every
  # client machine has to be re-trusted by hand.
  if kc -n cert-manager get secret suite366-local-ca >/dev/null 2>&1; then
    info "secrets: cert-manager/suite366-local-ca (CA private key)"
    kc -n cert-manager get secret suite366-local-ca -o yaml \
      | res backup --stdin --stdin-filename local-ca-secret.yaml --tag suite366 --tag secrets || rc=1
  fi
  return "$rc"
}

# --- modes --------------------------------------------------------------------
do_init() {
  require_restic
  configured || die "no destination configured: set BACKUP_REPO in $BACKUP_ENV."
  restic_env
  if res snapshots >/dev/null 2>&1; then
    info "repository already initialised: $(redact_repo "$BACKUP_REPO")"
    return 0
  fi
  log "Initialising the restic repository"
  res init || die "restic init failed — check the destination and its credentials."
  info "initialised: $(redact_repo "$BACKUP_REPO")"
}

do_test() {
  require_restic
  load_previous_state
  if ! configured; then
    write_state_json
    die "no destination configured: set BACKUP_REPO in $BACKUP_ENV."
  fi
  restic_env
  log "Testing the destination"
  if res snapshots --json >/dev/null 2>&1; then
    info "reachable, repository readable: $(redact_repo "$BACKUP_REPO")"
    write_state_json
    return 0
  fi
  if res cat config >/dev/null 2>&1; then
    info "reachable, but no snapshots yet."
    write_state_json
    return 0
  fi
  STATE_ERROR="destination unreachable or wrong credentials/key"
  write_state_json
  die "cannot read $(redact_repo "$BACKUP_REPO") — wrong credentials, wrong key, or unreachable."
}

collect_snapshots() {
  local raw
  raw="$(res snapshots --json 2>/dev/null || true)"
  [[ -n "$raw" ]] || { STATE_SNAPSHOTS="[]"; return 0; }
  # Reduced to what a UI shows, with no jq dependency (not guaranteed on DGX OS):
  # id, time and tags per snapshot, newest last as restic prints them.
  STATE_SNAPSHOTS="$(printf '%s' "$raw" | python3 -c '
import json,sys
try: snaps = json.load(sys.stdin)
except Exception: snaps = []
out = [{"id": s.get("short_id",""), "time": s.get("time",""),
        "tags": [t for t in s.get("tags",[]) if t != "suite366"]}
       for s in snaps]
print(json.dumps(out[-40:], indent=2))
' 2>/dev/null || printf '[]')"
}

do_run() {
  require_restic
  ensure_backup_dir
  if ! configured; then
    # Deliberately exit 0: an unconfigured appliance has nothing to do, and a
    # timer that goes red every night on purpose is a timer nobody reads.
    STATE_STATUS="unconfigured"
    STATE_ERROR="no destination configured"
    write_state_json
    warn "backup not configured (no BACKUP_REPO) — nothing to do."
    return 0
  fi
  # One run at a time. The timer and an operator running this by hand would
  # otherwise fight over the repository lock, which restic resolves by making
  # one of them wait for a stale lock timeout.
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "another backup run holds $LOCK_FILE."

  restic_env
  STATE_STARTED="$(now_utc)"; STATE_STATUS="running"; STATE_ERROR=""
  write_state_json

  log "Backup -> $(redact_repo "$BACKUP_REPO")"
  res snapshots >/dev/null 2>&1 || do_init

  local failed=()
  backup_postgres || failed+=("postgres")
  backup_minio    || failed+=("minio")
  backup_config   || failed+=("config")
  backup_secrets  || failed+=("secrets")

  do_prune_inner || failed+=("prune")

  collect_snapshots
  STATE_REPO_SIZE="$(res stats --mode raw-data 2>/dev/null | sed -n 's/.*Total Size: *//p' | head -1)"
  STATE_FINISHED="$(now_utc)"
  if (( ${#failed[@]} )); then
    # Partial is NOT success. A run that saved the database but lost the
    # secrets restores into an unreadable app, so it must not report green.
    STATE_STATUS="partial"
    STATE_ERROR="failed: ${failed[*]}"
    write_state_json
    warn "backup incomplete — failed: ${failed[*]}"
    return 1
  fi
  STATE_STATUS="success"
  write_state_json
  log "Backup complete (${STATE_REPO_SIZE:-size unknown})"
}

do_prune_inner() {
  info "retention: keep ${BACKUP_KEEP_DAILY}d / ${BACKUP_KEEP_WEEKLY}w / ${BACKUP_KEEP_MONTHLY}m"
  res forget --tag suite366 \
    --keep-daily "$BACKUP_KEEP_DAILY" \
    --keep-weekly "$BACKUP_KEEP_WEEKLY" \
    --keep-monthly "$BACKUP_KEEP_MONTHLY" \
    --prune >/dev/null || return 1
}

do_prune() {
  require_restic
  configured || die "no destination configured."
  restic_env
  log "Applying retention"
  do_prune_inner || die "restic forget/prune failed."
  collect_snapshots
  load_previous_state
  write_state_json
}

do_snapshots() {
  require_restic
  configured || die "no destination configured."
  restic_env
  res snapshots --tag suite366
}

# Lot B extracts; it does not overwrite. An in-place restore has to patch
# AUTH_SECRET before the data lands, stop MinIO, and reinitialise Postgres —
# a sequence that must be exercised on a real box before it is automated, and
# automating it untested is how a recovery turns into a second outage. So this
# gets the data OUT of the repository safely and prints what to do with it.
do_restore() {
  require_restic
  configured || die "no destination configured."
  local snap="latest" target=""
  shift || true
  while (( $# )); do
    case "$1" in
      --snapshot) snap="${2:-}"; shift 2 ;;
      --target)   target="${2:-}"; shift 2 ;;
      *) die "unknown argument '$1' (use: restore [--snapshot ID] --target DIR)" ;;
    esac
  done
  [[ -n "$target" ]] || die "restore needs --target DIR (an EMPTY directory to extract into)."
  [[ -e "$target" && -n "$(ls -A "$target" 2>/dev/null)" ]] \
    && die "$target is not empty — extract into a fresh directory."
  mkdir -p "$target"; chmod 0700 "$target"
  restic_env
  log "Extracting snapshot '$snap' into $target"
  res restore "$snap" --target "$target" || die "restic restore failed."
  cat <<EOF

$(printf "${c_b}Extracted. Nothing on this appliance has been modified.${c_0}")

  Next steps are MANUAL and order-dependent — see docs/restore.md:
    1. patch AUTH_SECRET from $target/…/app-secret.yaml into secret-<app>
       BEFORE loading any data, or every encrypted column in the database
       becomes unreadable while appearing to restore fine;
    2. pg_restore the dump into the fresh database;
    3. copy the MinIO objects back with MinIO stopped, leaving .minio.sys alone;
    4. restore values.yaml / llm/.env / the CA secret, then restart the app;
    5. verify POSITIVELY: open a document AND make one LLM call with a stored
       provider key. A box that merely boots proves nothing about step 1.
EOF
}

do_status() {
  if [[ ! -f "$STATE_JSON" ]]; then
    warn "no backup state yet ($STATE_JSON absent)."
    return 1
  fi
  cat "$STATE_JSON"
  configured || return 1
  local st
  st="$(sed -n 's/.*"status": *"\([^"]*\)".*/\1/p' "$STATE_JSON" | head -1)"
  [[ "$st" == "success" ]]
}

# --- install-units ------------------------------------------------------------
# Written inline so $DATA_DIR is baked in, same as the update timer.
install_units() {
  ensure_backup_dir
  cat > /etc/systemd/system/suite366-backup.service <<EOF
[Unit]
Description=Suite 366 — appliance backup (restic)
After=network-online.target k3s.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-$BACKUP_ENV
Environment=DATA_DIR=$DATA_DIR
ExecStart=$DATA_DIR/backup.sh run
# The repository is remote and the box is a single node: a run that hangs on a
# dead endpoint must not still be holding the lock at the next tick.
TimeoutStartSec=6h
Nice=10
IOSchedulingClass=idle
EOF

  cat > /etc/systemd/system/suite366-backup.timer <<EOF
[Unit]
Description=Suite 366 — nightly backup

[Timer]
OnCalendar=*-*-* $BACKUP_SCHEDULE:00
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable suite366-backup.timer >/dev/null 2>&1 \
    || warn "could not enable suite366-backup.timer (systemd offline?)."
  systemctl start suite366-backup.timer >/dev/null 2>&1 || true
  info "backup timer armed (daily at $BACKUP_SCHEDULE, +up to 15 min jitter)."
}

case "$MODE" in
  init)          do_init ;;
  run)           do_run ;;
  test)          do_test ;;
  prune)         do_prune ;;
  snapshots)     do_snapshots ;;
  restore)       do_restore "$@" ;;
  status)        do_status ;;
  install-units) install_units ;;
  *) die "Unknown mode '$MODE' (use: init | run | test | prune | snapshots | restore | status | install-units)" ;;
esac
