#!/usr/bin/env bash
# =============================================================================
# Suite 366 — appliance backup agent.
#
#   backup.sh init | run | test | status | snapshots | prune | restore
#             | configure | handle-trigger KIND | install-units
#
# `restore` extracts, and nothing else. `restore --in-place` rebuilds this
# appliance from a snapshot: see do_restore_in_place for the order the steps
# have to happen in and why each guard is there.
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
# APP <-> HOST BRIDGE
# $BACKUP_DIR is hostPath-mounted into drive-app at /appliance-backup (root:1001
# 0770), the same idiom update.sh and support.sh already use:
#   state.json           written by us — read by the admin UI
#   run-requested        dropped by the app -> systemd .path unit -> `run`
#   test-requested       dropped by the app -> `test`
#   configure-requested  dropped by the app -> `configure` (destination + retention)
# The app never holds root and never edits backup.env itself: it asks, we
# validate, and the credentials land in a 0600 file it cannot read back.
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
# Overridable so install-units can be exercised without root or a live systemd.
# It is the one part of this agent that writes outside $DATA_DIR, and an untested
# unit file is a timer that silently never fires.
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

# Destination + retention live in backup.env (written by lib/backup.sh at
# install time, or by the host agent when the app UI configures it in lot C).
# Sourced BEFORE the defaults below so an operator editing that file wins.
# shellcheck disable=SC1090
[[ -f "$BACKUP_ENV" ]] && source "$BACKUP_ENV"

BACKUP_REPO="${BACKUP_REPO:-}"
# These three were missing, and only the FIRST configuration from the UI hit
# it: with no backup.env yet, nothing defines them, and `set -u` killed the
# agent inside the systemd unit before it could write anything. Every test had
# created backup.env first, so the one path a new box actually takes was the
# one never exercised.
BACKUP_S3_ACCESS_KEY="${BACKUP_S3_ACCESS_KEY:-}"
BACKUP_S3_SECRET_KEY="${BACKUP_S3_SECRET_KEY:-}"
BACKUP_S3_REGION="${BACKUP_S3_REGION:-}"
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
# Same definition as lib/common.sh. Duplicated rather than sourced: backup.sh is
# fetched and run standalone, including from a signed package, and must not
# depend on the installer's tree being present.
tty_usable() { (exec </dev/tty) >/dev/null 2>&1; }
now_utc() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# Same minimal flat-JSON reader as update.sh and support.sh — one idiom for the
# whole appliance, and no jq dependency to guarantee across OS images.
json_get()     { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1; }
json_get_num() { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -1; }

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
  # Two forms, and the second is the one that matters in practice:
  #   rest:https://user:pass@host/…   credentials after //
  #   s3:AKIA…:secret@endpoint/…      credentials straight after the scheme
  # Only the second is what an operator actually types for S3, and an earlier
  # version of this function handled only the first — so the access key and the
  # secret went into state.json, which is world-readable in the bridge directory
  # and rendered in the admin UI. A bare `user@host` (sftp) is left alone: it is
  # not a credential, and hiding it would only make the destination unreadable.
  printf '%s' "$1" \
    | sed -E 's#(//)[^/@]*:[^/@]*@#\1<redacted>@#' \
    | sed -E 's#^([A-Za-z0-9]+:)[^/@]*:[^/@]*@#\1<redacted>@#'
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
has_destination() { [[ -n "$BACKUP_REPO" ]]; }
has_key()         { [[ -s "$PASS_FILE" ]]; }
configured()      { has_destination && has_key; }

# Which of the two is missing, in words. Reporting "no destination configured"
# on a box whose destination IS set — because the repository key was never
# generated — sends whoever reads it to fix the wrong thing.
unconfigured_reason() {
  if ! has_destination && ! has_key; then printf 'no destination and no repository key'
  elif ! has_destination;                then printf 'no destination configured'
  else                                        printf 'no repository key on this appliance'
  fi
}

# The key, and ONLY until the admin says they have stored it. Written into a
# file the pod can read, because a key nobody ever sees is a backup nobody can
# restore — the exact failure this whole feature exists to prevent. It is the
# same ceremony install.sh performs on a terminal, performed in the browser
# instead, because a box that grew its backup agent from the update channel has
# no terminal moment left.
REVEAL_FILE="${REVEAL_FILE:-$BACKUP_DIR/.key-reveal}"
reveal_pending() { [[ -s "$REVEAL_FILE" ]] && cat "$REVEAL_FILE" || true; }

# Generate the repository key if this appliance has none. Never regenerates:
# a second key silently orphans every existing snapshot.
ensure_key() { # ensure_key REQUESTED_BY
  has_key && return 0
  have openssl || { warn "openssl missing — cannot generate a repository key."; return 1; }
  local key
  key="$(openssl rand -base64 32)"
  ( umask 077; printf '%s\n' "$key" > "$PASS_FILE" )
  chmod 0600 "$PASS_FILE"
  # 0640 root:app-group: readable by the pod that must display it, by nobody
  # else, and only until it is acknowledged.
  ( umask 027; printf '%s' "$key" > "$REVEAL_FILE" )
  chown "root:$APP_GID" "$REVEAL_FILE" 2>/dev/null || true
  chmod 0640 "$REVEAL_FILE"
  log "Repository key generated (requested by ${1:-unknown})"
  warn "It is shown ONCE, in the app, and stored nowhere else. Without it the"
  warn "  backups cannot be read — not by the customer, not by us."
  return 0
}

# The admin pressed "I have stored it".
do_ack_key() {
  ensure_backup_dir
  rm -f "$REVEAL_FILE"
  info "repository key acknowledged — it is not shown again."
  load_previous_state
  write_state_json
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
  "key_present": $([[ -s "$PASS_FILE" ]] && echo true || echo false),
  "key_reveal": "$(json_esc "$(reveal_pending)")",
  "restic_present": $([[ -x "$RESTIC_BIN" ]] && echo true || echo false),
  "restic_version": "$(json_esc "$([[ -x "$RESTIC_BIN" ]] && "$RESTIC_BIN" version 2>/dev/null | awk '{print $2}' | head -1)")",
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
  # $BACKUP_DIR is excluded WHOLESALE, not file by file. The original
  # exclusions named repo.pass and the restic cache individually, and every
  # file added to that directory afterwards was silently swept into the
  # snapshot — which is how backup.env (the destination's S3 credentials in
  # clear) and .key-reveal (the repository key itself) ended up inside the
  # repository they protect, along with several hundred kubectl cache files.
  # Seen in a real snapshot on a real appliance.
  #
  # Nothing in there is worth restoring anyway: the key comes from the vault or
  # the card in the crate, the destination is a per-installation decision, and
  # state.json is regenerated by the next run.
  info "config: $DATA_DIR (excluding models/, bin/ and the backup directory)"
  res backup "$DATA_DIR" \
    --exclude "$DATA_DIR/models" \
    --exclude "$BACKUP_DIR" \
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
  STATE_ERROR="destination unreachable, or no repository there yet"
  write_state_json
  die "cannot read $(redact_repo "$BACKUP_REPO").
    Either nothing has initialised a repository there yet (run: $0 init), or the
    destination is unreachable, or the credentials or the repository key are wrong."
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
  ensure_backup_dir
  # Order matters: an appliance that has the agent but no destination is not
  # broken, it is unconfigured, and it must be able to say so even with no
  # restic on disk — which is exactly the state update.sh's converge_backup
  # leaves a box that never had a backup layer.
  if ! configured; then
    # Deliberately exit 0: an unconfigured appliance has nothing to do, and a
    # timer that goes red every night on purpose is a timer nobody reads.
    STATE_STATUS="unconfigured"
    STATE_ERROR="$(unconfigured_reason)"
    write_state_json
    warn "backup not configured ($(unconfigured_reason)) — nothing to do."
    return 0
  fi
  # Configured but unable to run: that IS broken, and it has to reach the UI.
  # A missing restic used to only ever be a message on someone's terminal.
  if [[ ! -x "$RESTIC_BIN" ]]; then
    STATE_STATUS="error"
    STATE_ERROR="restic missing at $RESTIC_BIN"
    STATE_FINISHED="$(now_utc)"
    write_state_json
    die "restic not found at $RESTIC_BIN (re-run install.sh, or apply an offline package)."
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

# Two restore paths, and the difference matters.
#
#   restore --target DIR   extracts. Touches nothing on this appliance. This is
#                          the right first move in almost every real incident:
#                          get the bytes somewhere safe, look at them, then
#                          decide.
#   restore --in-place     rebuilds THIS appliance from a snapshot. Destructive,
#                          ordered, and guarded — see do_restore_in_place.
do_restore() {
  require_restic
  configured || die "no destination configured."
  local snap="latest" target="" in_place=0 assume_yes=0 force=0 dry=0
  shift || true
  while (( $# )); do
    case "$1" in
      --snapshot) snap="${2:-}"; shift 2 ;;
      --target)   target="${2:-}"; shift 2 ;;
      --in-place) in_place=1; shift ;;
      --dry-run)  dry=1; shift ;;
      --yes)      assume_yes=1; shift ;;
      --force)    force=1; shift ;;
      *) die "unknown argument '$1' (use: restore [--snapshot ID] --target DIR | --in-place [--dry-run] [--yes] [--force])" ;;
    esac
  done

  if (( in_place )); then
    [[ -z "$target" ]] || die "--target and --in-place are mutually exclusive."
    do_restore_in_place "$snap" "$assume_yes" "$force" "$dry"
    return
  fi

  [[ -n "$target" ]] || die "restore needs --target DIR (an EMPTY directory to extract into), or --in-place."
  [[ -e "$target" && -n "$(ls -A "$target" 2>/dev/null)" ]] \
    && die "$target is not empty — extract into a fresh directory."
  mkdir -p "$target"; chmod 0700 "$target"
  restic_env
  log "Extracting snapshot '$snap' into $target"
  res restore "$snap" --target "$target" || die "restic restore failed."
  cat <<EOF

$(printf "${c_b}Extracted. Nothing on this appliance has been modified.${c_0}")

  To rebuild this appliance from the same snapshot:
    sudo $DATA_DIR/backup.sh restore --in-place --snapshot $snap

  To do it by hand instead, the order is not negotiable — see docs/restore.md:
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

# --- in-place restore -----------------------------------------------------------
# The order below is the whole design, and every step is placed where it is
# because putting it elsewhere breaks something quietly:
#
#   1. extract everything first. A restore that discovers a truncated dump
#      halfway through has already stopped the app.
#   2. take a pre-restore snapshot of what is here NOW. This is the only thing
#      that makes the operation reversible, and it costs seconds.
#   3. scale the app to 0 BEFORE touching data: a running app writing to a
#      database that is being reloaded produces a mixture of both.
#   4. patch AUTH_SECRET (and any legacy key the source box carried) BEFORE the
#      data lands. Get this wrong and Postgres restores perfectly while every
#      encrypted column — provider API keys, OAuth tokens — is permanently
#      unreadable, with no error anywhere. suite-366's encryption.ts derives its
#      AES key from AUTH_SECRET, and falls back to NEXTAUTH_SECRET /
#      ENCRYPTION_KEY on decrypt, so all three are carried when present.
#   5. pg_restore.
#   6. MinIO objects, with MinIO stopped, .minio.sys left alone — that directory
#      holds the FRESH install's root credentials, and overwriting it locks you
#      out of the data you just restored.
#   7. scale back up and prove it works.
#
# NOT restored, deliberately: POSTGRES_PASSWORD / DATABASE_URL / MINIO_* (the
# fresh install generated its own and the dump is logical, so carrying the old
# ones over breaks a working stack), values.yaml (the rebuilt box may legitimately
# have different hostnames — it is extracted for reference instead) and the local
# CA (restoring it is a deliberate choice, documented in docs/restore.md).
#
# ⚠️ HONEST STATUS: exercised against stubs and against a real restic repository,
# but NOT yet against a live appliance — doing so means destroying a running
# customer box. Read docs/restore.md before using it in an incident, and prefer
# `--target` plus the manual sequence if you have never run this before.
do_restore_in_place() { # do_restore_in_place SNAP ASSUME_YES FORCE DRY
  local snap="$1" assume_yes="$2" force="$3" dry="$4"
  # mktemp, not just a timestamp: two restores started in the same second would
  # otherwise share a directory, and the second would happily find the first
  # one's extracted dump — silently restoring the wrong snapshot.
  local stage
  stage="$(mktemp -d "$BACKUP_DIR/restore-$(date -u '+%Y%m%dT%H%M%SZ')-XXXXXX")"

  have flock || die "flock required."
  exec 9>"$LOCK_FILE"
  flock -n 9 || die "a backup run holds $LOCK_FILE — wait for it to finish."

  local pg_deploy minio_pvc minio_path app_secret app_deploy minio_deploy
  pg_deploy="$(discover_pg)"
  [[ -n "$pg_deploy" ]] || die "no *-postgres deployment in ns/$NAMESPACE — is the chart installed?"
  minio_pvc="$(discover_minio_pvc)" || true
  [[ -n "$minio_pvc" ]] && minio_path="$(pvc_host_path "$minio_pvc" || true)"
  app_secret="$(kc -n "$NAMESPACE" get secret -o name 2>/dev/null \
    | sed -n 's|^secret/||p' | grep '^secret-' | head -1)"
  [[ -n "$app_secret" ]] || die "no secret-* in ns/$NAMESPACE — refusing: AUTH_SECRET could not be patched."
  app_deploy="$(kc -n "$NAMESPACE" get deploy -o name 2>/dev/null \
    | sed -n 's|^deployment.apps/||p' | grep -v -- '-postgres$\|-minio$\|-redis$\|-onlyoffice$\|-livekit$' | head -1)"
  minio_deploy="$(kc -n "$NAMESPACE" get deploy -o name 2>/dev/null \
    | sed -n 's|^deployment.apps/||p' | grep -- '-minio$' | head -1)"

  cat <<EOF

$(printf "${c_r}────────────────────────────────────────────────────────────────${c_0}")
$(printf "${c_b} IN-PLACE RESTORE — this OVERWRITES live data on this appliance${c_0}")
$(printf "${c_r}────────────────────────────────────────────────────────────────${c_0}")

  snapshot     : $snap
  repository   : $(redact_repo "$BACKUP_REPO")
  namespace    : $NAMESPACE

  will be REPLACED:
    database   : deploy/$pg_deploy (dropped and reloaded from the dump)
    objects    : ${minio_path:-<no minio pvc found — objects NOT restored>}
    AUTH_SECRET: $app_secret (patched from the snapshot, before the data)

  will be STOPPED during the restore:
    ${app_deploy:-<no app deployment found>}${minio_deploy:+, $minio_deploy}

  NOT touched: values.yaml, the local CA, models/, this repository's key.
  A pre-restore snapshot of the CURRENT database and secrets is taken first.

EOF

  if (( dry )); then
    warn "--dry-run: stopping here. Nothing has been changed."
    return 0
  fi

  # A populated database is the case where this command destroys real work. The
  # expected use is a REBUILT box whose database is empty; anything else needs
  # to be said out loud.
  local rows
  rows="$(pg_exec "$pg_deploy" 'psql -tAq -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "select count(*) from information_schema.tables where table_schema='"'"'public'"'"'"' 2>/dev/null | tr -d '[:space:]' || true)"
  if [[ "${rows:-0}" =~ ^[0-9]+$ ]] && (( rows > 0 )) && (( ! force )); then
    die "the target database already has $rows table(s) — this is not a fresh box.
    Restoring would destroy whatever is in it. Re-run with --force if that is
    genuinely what you want, after taking your own copy."
  fi

  if (( ! assume_yes )); then
    tty_usable || die "no TTY and no --yes: refusing to overwrite live data unattended."
    local ack=""
    read -r -p " Type RESTORE to proceed: " ack </dev/tty || true
    [[ "$ack" == "RESTORE" ]] || die "not confirmed — nothing was changed."
  fi

  restic_env

  # --- 1. extract ---------------------------------------------------------------
  chmod 0700 "$stage"
  log "1/7  Extracting snapshot '$snap'"
  res restore "$snap" --target "$stage" || die "restic restore failed — nothing was changed."
  local dump secret_yaml
  dump="$(find "$stage" -name postgres.dump -type f | head -1)"
  secret_yaml="$(find "$stage" -name app-secret.yaml -type f | head -1)"
  [[ -s "$dump" ]] || die "the snapshot carries no postgres.dump — nothing was changed."
  [[ -s "$secret_yaml" ]] || die "the snapshot carries no app-secret.yaml, so AUTH_SECRET cannot be
    carried over. Restoring the data without it would produce a database whose
    encrypted columns are permanently unreadable. Nothing was changed."
  # A dump that was truncated at backup time is unusable, and finding that out
  # after dropping the live database is the worst possible moment.
  #
  # Three outcomes, not two, because "pg_restore said no" and "pg_restore could
  # not run" must not be treated alike: the first is a definitive refusal, the
  # second is an unknown. pg_restore is NOT on the appliance host — verified on
  # a real one, where the original host-side guard silently skipped itself and
  # the check that mattered never ran at all. The postgres pod has it.
  case "$(preflight_dump "$dump" "$pg_deploy")" in
    ok)  info "the extracted dump reads as a valid pg_dump archive." ;;
    bad) die "the extracted dump is not a readable pg_dump archive — nothing was changed." ;;
    *)
      [[ "$(head -c 5 "$dump")" == "PGDMP" ]] \
        || die "the extracted dump is not a pg_dump archive at all — nothing was changed."
      warn "pg_restore is available neither in the postgres pod nor on this host."
      warn "  The dump has the right magic bytes but has NOT been verified as"
      warn "  complete. Continuing; verify the restore especially carefully."
      ;;
  esac
  info "extracted to $stage"

  # --- 2. reversibility ---------------------------------------------------------
  log "2/7  Snapshotting the CURRENT state first (tag pre-restore)"
  kc -n "$NAMESPACE" get secret "$app_secret" -o yaml \
    | res backup --stdin --stdin-filename pre-restore-app-secret.yaml \
        --tag suite366 --tag pre-restore >/dev/null \
    || warn "could not snapshot the current secret — continuing, but this restore is now one-way."
  if kc -n "$NAMESPACE" exec "deploy/$pg_deploy" -- \
       sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc' \
     | res backup --stdin --stdin-filename pre-restore-postgres.dump \
         --tag suite366 --tag pre-restore >/dev/null
  then info "pre-restore snapshot stored."
  else warn "could not dump the current database — continuing, but this restore is now one-way."
  fi

  # --- 3. stop the writers ------------------------------------------------------
  log "3/7  Stopping the app"
  [[ -n "$app_deploy" ]] && kc -n "$NAMESPACE" scale "deploy/$app_deploy" --replicas=0 >/dev/null 2>&1
  [[ -n "$app_deploy" ]] && kc -n "$NAMESPACE" rollout status "deploy/$app_deploy" --timeout=120s >/dev/null 2>&1
  info "${app_deploy:-app} scaled to 0"

  # --- 4. AUTH_SECRET, BEFORE the data ------------------------------------------
  log "4/7  Carrying AUTH_SECRET over (before the data — see the header)"
  local k patched=0
  for k in AUTH_SECRET NEXTAUTH_SECRET ENCRYPTION_KEY; do
    local v
    v="$(sed -n "s/^  $k: //p" "$secret_yaml" | head -1 | tr -d '[:space:]')"
    [[ -n "$v" ]] || continue
    kc -n "$NAMESPACE" patch secret "$app_secret" --type merge \
      -p "{\"data\":{\"$k\":\"$v\"}}" >/dev/null \
      || die "could not patch $k into $app_secret — STOPPING before the data lands."
    info "$k restored"
    patched=$((patched+1))
  done
  (( patched > 0 )) || die "the snapshot's secret carries no AUTH_SECRET — STOPPING before the data lands."

  # --- 5. database ----------------------------------------------------------------
  log "5/7  Reloading the database"
  # --clean --if-exists so a rebuilt-but-migrated schema is replaced rather than
  # collided with; the dump is logical, so the fresh install's own password and
  # role stay in force.
  if kc -n "$NAMESPACE" exec -i "deploy/$pg_deploy" -- \
       sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --no-privileges' \
       < "$dump"
  then info "database reloaded"
  else warn "pg_restore reported errors — review them before declaring this restore good."
  fi

  # --- 6. objects -------------------------------------------------------------------
  if [[ -n "${minio_path:-}" && -d "$minio_path" ]]; then
    log "6/7  Restoring objects into $minio_path"
    local src
    src="$(find "$stage" -type d -name "$(basename "$minio_path")" | head -1)"
    if [[ -n "$src" && -d "$src" ]]; then
      [[ -n "$minio_deploy" ]] && kc -n "$NAMESPACE" scale "deploy/$minio_deploy" --replicas=0 >/dev/null 2>&1
      [[ -n "$minio_deploy" ]] && kc -n "$NAMESPACE" rollout status "deploy/$minio_deploy" --timeout=120s >/dev/null 2>&1
      # --exclude .minio.sys: that directory holds THIS install's root
      # credentials and IAM. Overwriting it locks you out of the very objects
      # being restored.
      if have rsync; then
        rsync -a --exclude '.minio.sys' "$src"/ "$minio_path"/ \
          || warn "rsync reported errors while restoring objects."
      else
        ( cd "$src" && find . -mindepth 1 -maxdepth 1 ! -name '.minio.sys' -exec cp -a {} "$minio_path"/ \; ) \
          || warn "copy reported errors while restoring objects."
      fi
      [[ -n "$minio_deploy" ]] && kc -n "$NAMESPACE" scale "deploy/$minio_deploy" --replicas=1 >/dev/null 2>&1
      info "objects restored (.minio.sys left untouched)"
    else
      warn "the snapshot carries no object directory matching $(basename "$minio_path") — objects NOT restored."
    fi
  else
    log "6/7  No MinIO PVC resolved — skipping objects"
  fi

  # --- 7. back up, and prove it -----------------------------------------------------
  log "7/7  Restarting the app"
  if [[ -n "$app_deploy" ]]; then
    kc -n "$NAMESPACE" scale "deploy/$app_deploy" --replicas=1 >/dev/null 2>&1
    if kc -n "$NAMESPACE" rollout status "deploy/$app_deploy" --timeout=300s >/dev/null 2>&1; then
      info "$app_deploy is Ready"
    else
      warn "$app_deploy did not become Ready within 5 minutes — check its logs."
    fi
  fi

  cat <<EOF

$(printf "${c_b}Restore finished.${c_0}") Staged copy kept at $stage
  (it holds the extracted secret — delete it once you are done: rm -rf $stage)

$(printf "${c_y}It is not done until you have verified it POSITIVELY:${c_0}")
  • open a document — proves the objects and the database agree;
  • make one LLM call using a STORED provider key — this is the only check that
    proves AUTH_SECRET was carried over correctly. A box that merely boots, and
    a user who merely logs in, prove nothing about it.

  If this went wrong, the state from before is in the repository:
    $DATA_DIR/backup.sh snapshots        # look for the 'pre-restore' tag
EOF
}

# ok | bad | unavailable — see the caller for why the third value exists.
preflight_dump() { # preflight_dump DUMP PG_DEPLOY
  local dump="$1" deploy="$2"
  if kc -n "$NAMESPACE" exec "deploy/$deploy" -- sh -c 'command -v pg_restore >/dev/null 2>&1' >/dev/null 2>&1; then
    if kc -n "$NAMESPACE" exec -i "deploy/$deploy" -- \
         sh -c 'cat > /tmp/.preflight.dump; pg_restore --list /tmp/.preflight.dump >/dev/null 2>&1; rc=$?; rm -f /tmp/.preflight.dump; exit $rc' \
         < "$dump" >/dev/null 2>&1
    then printf 'ok'; else printf 'bad'; fi
    return 0
  fi
  if have pg_restore; then
    pg_restore --list "$dump" >/dev/null 2>&1 && printf 'ok' || printf 'bad'
    return 0
  fi
  printf 'unavailable'
}

# Run a command inside the postgres pod. Kept separate because the in-place
# restore probes the database before it is allowed to touch it.
pg_exec() { # pg_exec DEPLOY SHELL_COMMAND
  kc -n "$NAMESPACE" exec "deploy/$1" -- sh -c "$2" 2>/dev/null
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

# --- configure (from the admin UI) ----------------------------------------------
# The app drops a JSON payload; we validate it and own the write. Three rules
# make this safe enough to expose in a UI:
#
#   • the repository string is checked against a whitelist of restic backends
#     rather than sanitised — it ends up in an environment variable read by a
#     process running as root, and "looks harmless" is not a security property;
#   • the encryption key is NEVER regenerated here. A new key silently orphans
#     every existing snapshot, and the customer's copy of the old one becomes
#     the only way to read backups that no longer accumulate;
#   • the payload file is removed before anything else, so a credential does not
#     sit in a directory the app can read for longer than one systemd tick.
CONFIG_TRIGGER="$BACKUP_DIR/configure-requested"

valid_repo() { # valid_repo STRING
  local r="$1"
  # No shell metacharacters, no whitespace: this becomes RESTIC_REPOSITORY for a
  # root process.
  [[ "$r" =~ ^[A-Za-z0-9._:/@+-]+$ ]] || return 1
  case "$r" in
    s3:*|b2:*|azure:*|gs:*|swift:*|rest:*|sftp:*|rclone:*) return 0 ;;
    /*) return 0 ;;   # a local path or a mounted NAS
    *) return 1 ;;
  esac
}

do_configure() {
  ensure_backup_dir
  [[ -s "$CONFIG_TRIGGER" ]] || die "no configuration payload at $CONFIG_TRIGGER."
  local payload; payload="$(cat "$CONFIG_TRIGGER")"
  rm -f "$CONFIG_TRIGGER"

  local repo access secret region keep_d keep_w keep_m sched by
  repo="$(json_get repository   <<<"$payload")"
  access="$(json_get access_key <<<"$payload")"
  secret="$(json_get secret_key <<<"$payload")"
  region="$(json_get region     <<<"$payload")"
  sched="$(json_get schedule    <<<"$payload")"
  by="$(json_get requested_by   <<<"$payload")"
  keep_d="$(json_get_num keep_daily   <<<"$payload")"
  keep_w="$(json_get_num keep_weekly  <<<"$payload")"
  keep_m="$(json_get_num keep_monthly <<<"$payload")"

  log "Configuring the backup destination (requested by ${by:-unknown})"
  valid_repo "$repo" || {
    STATE_ERROR="rejected: '$repo' is not a supported restic repository"
    load_previous_state; write_state_json
    die "refusing '$repo' — expected s3:/b2:/azure:/gs:/swift:/rest:/sftp:/rclone: or an absolute path."
  }
  [[ "$sched" =~ ^[0-2][0-9]:[0-5][0-9]$ ]] || sched="$BACKUP_SCHEDULE"
  [[ "$keep_d" =~ ^[0-9]+$ ]] || keep_d="$BACKUP_KEEP_DAILY"
  [[ "$keep_w" =~ ^[0-9]+$ ]] || keep_w="$BACKUP_KEEP_WEEKLY"
  [[ "$keep_m" =~ ^[0-9]+$ ]] || keep_m="$BACKUP_KEEP_MONTHLY"
  # Retaining nothing would let the first prune delete every snapshot.
  (( keep_d < 1 )) && keep_d=1

  # An empty secret means "keep the one already configured" — the UI shows a
  # masked field and must not have to round-trip a credential to change a
  # schedule.
  [[ -z "$access" ]] && access="$BACKUP_S3_ACCESS_KEY"
  [[ -z "$secret" ]] && secret="$BACKUP_S3_SECRET_KEY"
  [[ -z "$region" ]] && region="$BACKUP_S3_REGION"

  # A destination with no key cannot back up anything, and the admin standing
  # in front of the UI right now is the only person who will ever be offered
  # this key.
  ensure_key "$by" || warn "no repository key — backups will not run until one exists."

  local previous="$BACKUP_REPO"
  ( umask 077
    cat > "$BACKUP_ENV" <<ENV
# Suite 366 backup destination + retention.
# Written by backup.sh from an admin-UI request at $(now_utc) (by ${by:-unknown}).
# 0600 — carries credentials.
BACKUP_REPO=$repo
BACKUP_S3_ACCESS_KEY=$access
BACKUP_S3_SECRET_KEY=$secret
BACKUP_S3_REGION=$region
BACKUP_KEEP_DAILY=$keep_d
BACKUP_KEEP_WEEKLY=$keep_w
BACKUP_KEEP_MONTHLY=$keep_m
BACKUP_SCHEDULE=$sched
NAMESPACE=$NAMESPACE
KUBECONFIG_PATH=$KUBECONFIG_PATH
RESTIC_BIN=$RESTIC_BIN
ENV
  )
  chmod 0600 "$BACKUP_ENV"
  info "destination: $(redact_repo "$repo")"
  if [[ -n "$previous" && "$previous" != "$repo" ]]; then
    warn "the destination CHANGED (was $(redact_repo "$previous"))."
    warn "  Snapshots already at the old location are not moved and not deleted;"
    warn "  they simply stop accumulating. The encryption key is unchanged, so"
    warn "  they remain readable from there."
  fi

  # Re-read, re-arm (the schedule may have moved), then prove it works.
  # shellcheck disable=SC1090
  . "$BACKUP_ENV"
  BACKUP_SCHEDULE="$sched"
  install_units

  # Create the repository before testing it. A destination an admin has just
  # chosen is almost always empty, and `test` on an empty one reports "wrong
  # credentials, wrong key, or unreachable" — which is false on all three
  # counts and sends them to re-check an S3 key that was correct. Failing here
  # instead says "restic init failed", which is the true problem.
  do_init
  do_test
}

# One entry point for every trigger the app can drop, so there is one place that
# consumes the file and one place that records the outcome.
handle_trigger() { # handle_trigger KIND
  local kind="${1:-}"
  case "$kind" in
    run)       rm -f "$BACKUP_DIR/run-requested";  do_run ;;
    test)      rm -f "$BACKUP_DIR/test-requested"; do_test ;;
    configure) do_configure ;;
    ack-key)   rm -f "$BACKUP_DIR/ack-key-requested"; do_ack_key ;;
    *) die "unknown trigger '$kind' (use: run | test | configure | ack-key)" ;;
  esac
}

# --- install-units ------------------------------------------------------------
# Written inline so $DATA_DIR is baked in, same as the update timer.
install_units() {
  ensure_backup_dir
  mkdir -p "$SYSTEMD_DIR"
  cat > "$SYSTEMD_DIR/suite366-backup.service" <<EOF
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

  cat > "$SYSTEMD_DIR/suite366-backup.timer" <<EOF
[Unit]
Description=Suite 366 — nightly backup

[Timer]
OnCalendar=*-*-* $BACKUP_SCHEDULE:00
RandomizedDelaySec=900
Persistent=true

[Install]
WantedBy=timers.target
EOF

  # App-trigger units. Same shape as update.sh's: a .path watching for a file the
  # pod drops, a oneshot that consumes it. `configure` gets its own pair rather
  # than a generic "do what the payload says" unit, so the systemd unit name in
  # the journal says which privileged action was requested.
  local kind
  for kind in run test configure ack-key; do
    cat > "$SYSTEMD_DIR/suite366-backup-$kind.service" <<EOF
[Unit]
Description=Suite 366 — backup $kind (requested from the app)
After=network-online.target k3s.service
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=-$BACKUP_ENV
Environment=DATA_DIR=$DATA_DIR
ExecStart=$DATA_DIR/backup.sh handle-trigger $kind
TimeoutStartSec=6h
EOF
    cat > "$SYSTEMD_DIR/suite366-backup-$kind.path" <<EOF
[Unit]
Description=Suite 366 — watch for backup $kind requests from the app

[Path]
PathExists=$BACKUP_DIR/$kind-requested

[Install]
WantedBy=multi-user.target
EOF
  done

  systemctl daemon-reload
  systemctl enable suite366-backup.timer >/dev/null 2>&1 \
    || warn "could not enable suite366-backup.timer (systemd offline?)."
  systemctl start suite366-backup.timer >/dev/null 2>&1 || true
  systemctl enable --now suite366-backup-run.path suite366-backup-test.path \
      suite366-backup-configure.path suite366-backup-ack-key.path >/dev/null 2>&1 \
    || warn "could not enable the backup trigger units (systemd offline?)."
  info "backup timer armed (daily at $BACKUP_SCHEDULE, +up to 15 min jitter)."
  info "app triggers armed (watching $BACKUP_DIR)."
}

case "$MODE" in
  init)          do_init ;;
  run)           do_run ;;
  test)          do_test ;;
  prune)         do_prune ;;
  snapshots)     do_snapshots ;;
  restore)       do_restore "$@" ;;
  configure)     do_configure ;;
  ack-key)       do_ack_key ;;
  handle-trigger) handle_trigger "${2:-}" ;;
  status)        do_status ;;
  install-units) install_units ;;
  *) die "Unknown mode '$MODE' (use: init | run | test | prune | snapshots | restore | configure | ack-key | handle-trigger KIND | status | install-units)" ;;
esac
