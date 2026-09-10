#!/usr/bin/env bash
# =============================================================================
# End-to-end test for backup.sh, with `restic` and `k3s kubectl` stubbed.
# Runs in a temp tree — no cluster, no S3, no appliance, no privilege.
#
#   tools/test-backup.sh
#
# What it actually proves, i.e. the failures worth a test:
#   • an unconfigured box reports "unconfigured" and exits 0, so a timer on a
#     box with no destination is not permanently red;
#   • the MinIO snapshot EXCLUDES .minio.sys — restoring one install's IAM over
#     another's root credentials locks you out of the data you just restored;
#   • the config snapshot excludes models/, bin/ and the WHOLE backup
#     directory — naming its sensitive files one by one is how backup.env (S3
#     credentials in clear) and the repository key ended up inside the
#     repository they protect;
#   • a pg_dump that dies mid-stream makes the run PARTIAL, never success (a
#     truncated dump in a valid snapshot is the worst possible outcome: it
#     looks like a backup until someone restores it);
#   • the secrets snapshot exists at all — it is what carries AUTH_SECRET;
#   • credentials embedded in a repository URL never reach state.json;
#   • restore refuses to extract into a directory that is not empty;
#   • two runs cannot overlap;
#   • a destination configured from the admin UI is VALIDATED before it becomes
#     an environment variable for a root process, the credential file it writes
#     is not readable by the pod, and the encryption key is never regenerated —
#     a new key silently orphans every existing snapshot;
#   • update.sh's convergence installs the agent on a box that never had one,
#     arms its timer, and does NOT invent a repository key — a key generated
#     with nobody watching exists on exactly one disk and is in nobody's hands.
#
# When a real `restic` is on PATH, it additionally does a genuine
# init -> backup -> restore -> diff against a local repository.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
ko() { printf '  \033[31mFAIL\033[0m %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail+1)); }
check()    { if [[ "$2" == "$3" ]]; then ok "$1"; else ko "$1" "expected '$3', got '$2'"; fi; }
contains() { if grep -qF -- "$2" <<<"$3"; then ok "$1"; else ko "$1" "missing '$2'"; fi; }
absent()   { if grep -qF -- "$2" <<<"$3"; then ko "$1" "unexpectedly found '$2'"; else ok "$1"; fi; }

# --- stubs --------------------------------------------------------------------
BIN="$WORK/bin"; mkdir -p "$BIN"
RLOG="$WORK/restic.log"; : > "$RLOG"
MINIO_DATA="$WORK/minio"; mkdir -p "$MINIO_DATA/.minio.sys" "$MINIO_DATA/suite-366"
echo object > "$MINIO_DATA/suite-366/file.bin"
echo iam    > "$MINIO_DATA/.minio.sys/iam.json"

# restic: records every invocation, and answers the few queries backup.sh makes.
# $WORK/no-repo and $WORK/pg-fails switch the two failure modes under test.
cat > "$BIN/restic" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$RLOG"
case "\$1" in
  version)   echo "restic 0.19.1 compiled with go1.24" ;;
  init)      exit 0 ;;
  snapshots)
    [[ -f "$WORK/no-repo" ]] && exit 1
    if [[ "\${2:-}" == "--json" ]]; then
      echo '[{"short_id":"a1b2c3d4","time":"2026-09-03T02:40:11Z","tags":["suite366","postgres"]}]'
    else
      echo "a1b2c3d4  2026-09-03 02:40:11  suite366,postgres"
    fi ;;
  cat)       exit 0 ;;
  backup)    case "\$*" in *--stdin*) cat >/dev/null 2>&1 || true ;; esac; exit 0 ;;
  forget)    exit 0 ;;
  stats)     echo "Total Size: 1.234 GiB" ;;
  restore)
    # Parse --target properly (the in-place restore reads what lands there) and
    # lay out a tree shaped like a real snapshot.
    tgt=""; while [[ \$# -gt 0 ]]; do [[ "\$1" == "--target" ]] && { tgt="\$2"; break; }; shift; done
    tgt="\${tgt:-$WORK/unused}"; mkdir -p "\$tgt"
    [[ -f "$WORK/no-dump" ]]   || printf 'PGDMP-fake-dump-content' > "\$tgt/postgres.dump"
    [[ -f "$WORK/no-secret" ]] || cat > "\$tgt/app-secret.yaml" <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: secret-drive-app
data:
  AUTH_SECRET: b2xkLWF1dGgtc2VjcmV0
  NEXTAUTH_SECRET: bGVnYWN5LWtleQ==
  POSTGRES_PASSWORD: c2hvdWxkLW5vdC1iZS1yZXN0b3JlZA==
YAML
    mkdir -p "\$tgt/minio/suite-366/doc" "\$tgt/minio/.minio.sys"
    echo restored-object > "\$tgt/minio/suite-366/doc/part.1"
    echo snapshot-iam    > "\$tgt/minio/.minio.sys/iam.json"
    exit 0 ;;
  *)         exit 0 ;;
esac
EOF

# k3s kubectl: just enough cluster to exercise discovery + the dump pipe.
KLOG="$WORK/k3s.log"; : > "$KLOG"
cat > "$BIN/k3s" <<EOF
#!/usr/bin/env bash
shift   # drop "kubectl"
args="\$*"
echo "\$args" >> "$KLOG"
case "\$args" in
  *"get deploy -o name"*)
    printf '%s\\n' deployment.apps/drive-app deployment.apps/drive-postgres \\
                    deployment.apps/drive-minio deployment.apps/drive-redis \\
                    deployment.apps/drive-onlyoffice ;;
  *scale*|*"rollout status"*) exit 0 ;;
  *"patch secret"*) exit 0 ;;
  *"command -v pg_restore"*) [[ -f "$WORK/no-pgrestore" ]] && exit 1; exit 0 ;;
  *preflight.dump*) cat >/dev/null 2>&1 || true; [[ -f "$WORK/bad-dump" ]] && exit 1; exit 0 ;;
  *pg_restore*)     cat >/dev/null 2>&1 || true; exit 0 ;;
  *information_schema.tables*) cat "$WORK/pg-tables" 2>/dev/null || echo 0 ;;
  *"get pvc -o name"*)     echo "persistentvolumeclaim/drive-minio-pvc" ;;
  *"get pvc drive-minio-pvc -o jsonpath"*) echo "pvc-abc123" ;;
  *"get pv pvc-abc123 -o jsonpath={.spec.local.path}"*) echo "$MINIO_DATA" ;;
  *"get pv "*)             echo "" ;;
  *"get secret -o name"*)  echo "secret/secret-drive-app" ;;
  *"get secret secret-drive-app -o yaml"*) echo "apiVersion: v1"; echo "kind: Secret" ;;
  *"cert-manager get secret suite366-local-ca"*) exit 1 ;;
  *exec*)
    # The dump itself. With \$WORK/pg-fails present it writes a few bytes and
    # THEN fails, which is precisely the truncated-dump case.
    if [[ -f "$WORK/pg-fails" ]]; then printf 'PGDMP-trunc'; exit 1; fi
    printf 'PGDMP-fake-dump-content'; exit 0 ;;
  *) exit 0 ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/systemctl"
# pg_restore --list is the pre-flight that refuses a truncated dump.
cat > "$BIN/pg_restore" <<EOF
#!/usr/bin/env bash
[[ -f "$WORK/bad-dump" ]] && exit 1
exit 0
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/chown"
printf '#!/usr/bin/env bash\nif [[ "${1:-}" == "-u" ]]; then echo 0; else exec /usr/bin/id "$@"; fi\n' > "$BIN/id"
chmod +x "$BIN"/*
ORIG_PATH="$PATH"          # kept so the real-restic section can bypass the stubs
export PATH="$BIN:$PATH"

# A public key file is all the strict-mode branches look at (they check that it
# EXISTS, the signature itself having been verified earlier by update.sh).
openssl genpkey -algorithm ed25519 -out "$WORK/conv.key" 2>/dev/null
openssl pkey -in "$WORK/conv.key" -pubout -out "$WORK/good.pub" 2>/dev/null

DATA="$WORK/opt/suite366"
mkdir -p "$DATA/models" "$DATA/bin"
echo weights > "$DATA/models/big.safetensors"
install -m 0700 "$REPO/backup.sh" "$DATA/backup.sh"

export DATA_DIR="$DATA"
export BACKUP_DIR="$DATA/backup"
export RESTIC_BIN="$BIN/restic"
mkdir -p "$BACKUP_DIR"

bk() { "$DATA/backup.sh" "$@" >"$WORK/out" 2>&1 </dev/null; }
out() { cat "$WORK/out"; }
state() { cat "$BACKUP_DIR/state.json" 2>/dev/null; }
field() { sed -n "s/.*\"$1\": *\"\\([^\"]*\\)\".*/\\1/p" "$BACKUP_DIR/state.json" | head -1; }

write_env() { # write_env REPO
  cat > "$BACKUP_DIR/backup.env" <<EOF
BACKUP_REPO=$1
BACKUP_S3_ACCESS_KEY=AKIAtest
BACKUP_S3_SECRET_KEY=secrettest
BACKUP_KEEP_DAILY=7
BACKUP_KEEP_WEEKLY=4
BACKUP_KEEP_MONTHLY=6
NAMESPACE=suite366
RESTIC_BIN=$BIN/restic
EOF
  chmod 0600 "$BACKUP_DIR/backup.env"
}

echo "== unconfigured appliance =="
rm -f "$BACKUP_DIR/backup.env" "$BACKUP_DIR/repo.pass"
bk run; rc=$?
check "run on an unconfigured box exits 0 (timer stays green)" "$rc" "0"
contains "state says unconfigured" '"configured": false' "$(state)"
check "last_run.status is 'unconfigured'" "$(field status)" "unconfigured"
bk status; check "status exits non-zero when unconfigured" "$?" "1"
bk init;   check "init refuses without a destination" "$?" "1"

echo "== configured appliance =="
printf 'test-encryption-key\n' > "$BACKUP_DIR/repo.pass"; chmod 0600 "$BACKUP_DIR/repo.pass"
write_env "s3:s3.example.com/bucket/spark-01"
: > "$RLOG"
bk run; rc=$?
check "a full run succeeds" "$rc" "0"
check "last_run.status is 'success'" "$(field status)" "success"
log="$(cat "$RLOG")"
contains "postgres arrives as a stdin snapshot"   "--stdin-filename postgres.dump" "$log"
contains "minio directory is backed up"           "backup $MINIO_DATA" "$log"
contains "minio EXCLUDES .minio.sys"              "--exclude $MINIO_DATA/.minio.sys" "$log"
contains "config snapshot excludes models/"       "--exclude $DATA/models" "$log"
contains "config snapshot excludes the whole backup dir" "--exclude $BACKUP_DIR" "$log"
# The three that were actually swept in on a real appliance. Asserted by name
# rather than by the directory alone, so a future change that goes back to
# per-file exclusions fails here instead of on someone's box.
for secret in repo.pass backup.env .key-reveal; do
  absent "  …so $secret is not in the snapshot" "$BACKUP_DIR/$secret " "$log"
done
contains "secrets snapshot carries the app secret" "--stdin-filename app-secret.yaml" "$log"
contains "retention applied"                      "--keep-daily 7" "$log"
contains "retention applied (weekly)"             "--keep-weekly 4" "$log"
contains "prune runs with forget"                 "--prune" "$log"
contains "snapshots recorded in state"            "a1b2c3d4" "$(state)"
contains "repo size recorded"                     "1.234 GiB" "$(state)"
if [[ -n "$(field key_fingerprint)" ]]; then ok "key fingerprint published"; else ko "key fingerprint published"; fi

echo "== the truncated-dump trap =="
touch "$WORK/pg-fails"; : > "$RLOG"
bk run; rc=$?
check "a failed pg_dump makes the run fail" "$rc" "1"
check "last_run.status is 'partial', not success" "$(field status)" "partial"
contains "the failing component is named" "postgres" "$(field error)"
rm -f "$WORK/pg-fails"

echo "== an uninitialised repository is initialised =="
touch "$WORK/no-repo"; : > "$RLOG"
bk run
contains "restic init is called when the repo is absent" "init" "$(cat "$RLOG")"
rm -f "$WORK/no-repo"

echo "== credentials never reach state.json =="
# state.json is 0644 inside a directory the pod reads, and the admin UI renders
# the repository string. Both credential-carrying URL forms have to be covered:
# an earlier version only handled the one with `//`, which is NOT the form an
# operator types for S3 — so the access key and secret went straight into the UI.
write_env "s3:https://AKIAKEY:supersecret@s3.example.com/bucket/spark-01"
bk test
absent "rest-style URL: the secret is redacted"  "supersecret" "$(state)"
contains "rest-style URL: the marker is there"   "<redacted>"  "$(state)"

write_env "s3:AKIAKEY:supersecret@s3.fr-par.scw.cloud/bucket/spark-01"
bk test
absent "S3-style URL: the secret is redacted"    "supersecret" "$(state)"
absent "S3-style URL: the access key too"        "AKIAKEY"     "$(state)"
contains "S3-style URL: the marker is there"     "<redacted>"  "$(state)"
contains "S3-style URL: the endpoint stays readable" "s3.fr-par.scw.cloud" "$(state)"

# A bare user@host is not a credential; redacting it would only make the
# destination unidentifiable in the UI.
write_env "sftp:backupuser@nas.local:/srv/suite366"
bk test
contains "sftp user@host is left readable" "backupuser@nas.local" "$(state)"
write_env "s3:s3.example.com/bucket/spark-01"

echo "== test mode preserves the previous run =="
bk run >/dev/null 2>&1
bk test
check "a connectivity test does not erase last_run" "$(field status)" "success"

echo "== restore is extract-only and guarded =="
bk restore
check "restore without --target is refused" "$?" "1"
mkdir -p "$WORK/notempty"; echo x > "$WORK/notempty/x"
bk restore --target "$WORK/notempty"
check "restore into a non-empty directory is refused" "$?" "1"
bk restore --target "$WORK/fresh"; rc=$?
check "restore into a fresh directory works" "$rc" "0"
contains "it says nothing was modified" "Nothing on this appliance has been modified" "$(out)"
contains "it points at the AUTH_SECRET step first" "patch AUTH_SECRET" "$(out)"

echo "== the repository key, when the UI is the only ceremony left =="
# A box that grew its backup agent from the update channel never had an
# install.sh moment, so nobody was ever offered a key. Configuring a
# destination in the UI is the last chance to hand one over, and a key nobody
# receives is a backup nobody can restore.
KWORK="$WORK/keyui"; mkdir -p "$KWORK/opt/suite366/backup" "$KWORK/systemd"
install -m 0700 "$REPO/backup.sh" "$KWORK/opt/suite366/backup.sh"
kb() { DATA_DIR="$KWORK/opt/suite366" BACKUP_DIR="$KWORK/opt/suite366/backup" \
       SYSTEMD_DIR="$KWORK/systemd" RESTIC_BIN="$BIN/restic" \
       "$KWORK/opt/suite366/backup.sh" "$@" >"$WORK/kout" 2>&1 </dev/null; }
kstate() { cat "$KWORK/opt/suite366/backup/state.json" 2>/dev/null; }

# Before anything: no destination, no key. The message must name BOTH, because
# "no destination configured" on a box whose destination is set sends whoever
# reads it to fix the wrong thing.
kb run; check "an empty box exits 0" "$?" "0"
contains "and names both missing pieces" "no destination and no repository key" "$(kstate)"

printf '%s\n' '{"repository":"/var/tmp/k/repo","requested_by":"admin@acme.tld"}' \
  > "$KWORK/opt/suite366/backup/configure-requested"
kb handle-trigger configure
[[ -s "$KWORK/opt/suite366/backup/repo.pass" ]] \
  && ok "configuring from the UI generates the repository key" \
  || ko "configuring from the UI generates the repository key" "$(cat "$WORK/kout")"
contains "the key is revealed to the UI exactly once" '"key_reveal": "' "$(kstate)"
revealed="$(python3 -c "import json,sys;print(json.load(sys.stdin)['key_reveal'])" <<<"$(kstate)" 2>/dev/null)"
[[ -n "$revealed" && "$revealed" == "$(cat "$KWORK/opt/suite366/backup/repo.pass")" ]] \
  && ok "and it is the key actually in use" || ko "and it is the key actually in use"
check "the reveal file is not world readable" \
  "$(stat -c '%a' "$KWORK/opt/suite366/backup/.key-reveal")" "640"

# Reconfiguring must NOT mint a second key: that silently orphans every
# existing snapshot while the old key becomes the only way to read them.
before="$(cat "$KWORK/opt/suite366/backup/repo.pass")"
printf '%s\n' '{"repository":"/var/tmp/k/repo2","requested_by":"admin@acme.tld"}' \
  > "$KWORK/opt/suite366/backup/configure-requested"
kb handle-trigger configure
check "reconfiguring does not mint a second key" \
  "$(cat "$KWORK/opt/suite366/backup/repo.pass")" "$before"

# Acknowledged = gone, and never shown again.
: > "$KWORK/opt/suite366/backup/ack-key-requested"
kb handle-trigger ack-key
[[ ! -e "$KWORK/opt/suite366/backup/.key-reveal" ]] \
  && ok "acknowledging clears the reveal" || ko "acknowledging clears the reveal"
contains "state no longer carries it" '"key_reveal": ""' "$(kstate)"
contains "but the fingerprint stays, to match against the vault" '"key_fingerprint": "' "$(kstate)"

echo "== in-place restore is guarded, ordered and reversible =="
# This is the one command in the appliance that destroys data on purpose, so
# what is tested here is mostly what it REFUSES to do.
export MINIO_PVC=drive-minio-pvc

bk restore --in-place --target "$WORK/x"
check "--in-place and --target are mutually exclusive" "$?" "1"

: > "$KLOG"
bk restore --in-place --dry-run
check "--dry-run exits 0" "$?" "0"
contains "--dry-run names what would be replaced" "will be REPLACED" "$(out)"
contains "--dry-run says nothing changed" "Nothing has been changed" "$(out)"
absent  "--dry-run patches no secret" "patch secret" "$(cat "$KLOG")"
absent  "--dry-run scales nothing down" "--replicas=0" "$(cat "$KLOG")"

# No TTY and no --yes: refuse rather than overwrite live data unattended.
bk restore --in-place
check "unattended without --yes is refused" "$?" "1"
contains "and says why" "refusing to overwrite live data unattended" "$(out)"

# A populated database is not a fresh box.
echo 42 > "$WORK/pg-tables"
bk restore --in-place --yes
check "a populated database is refused without --force" "$?" "1"
contains "and says how many tables it found" "already has 42 table" "$(out)"
echo 0 > "$WORK/pg-tables"

# A snapshot with no secret cannot carry AUTH_SECRET: refuse BEFORE any data
# lands, because the alternative is a database that restores perfectly and is
# permanently unreadable.
: > "$KLOG"; touch "$WORK/no-secret"
bk restore --in-place --yes
check "a snapshot without app-secret.yaml is refused" "$?" "1"
contains "and explains the consequence" "permanently unreadable" "$(out)"
absent  "nothing was reloaded" "--clean --if-exists" "$(cat "$KLOG")"
rm -f "$WORK/no-secret"

: > "$KLOG"; touch "$WORK/no-dump"
bk restore --in-place --yes
check "a snapshot without postgres.dump is refused" "$?" "1"
absent  "and the app was never stopped" "--replicas=0" "$(cat "$KLOG")"
rm -f "$WORK/no-dump"

# A dump that was truncated at backup time must be caught BEFORE the live
# database is dropped — finding out afterwards is the worst possible moment.
# The check runs INSIDE the postgres pod: pg_restore is not installed on a real
# appliance host, so the host-side version of this guard skipped itself.
: > "$KLOG"; touch "$WORK/bad-dump"
bk restore --in-place --yes
check "an unreadable dump is refused" "$?" "1"
contains "and says so" "not a readable pg_dump archive" "$(out)"
absent  "and the app was never stopped" "--replicas=0" "$(cat "$KLOG")"
rm -f "$WORK/bad-dump"

# preflight_dump has THREE outcomes and the third is the one that actually
# happens on an appliance: pg_restore is installed neither in the pod nor on
# the host. Tested directly, because a dev machine with postgresql-client
# cannot produce that condition end to end.
# Driven by POD_HAS / VERDICT / HOST_HAS in the environment (0 = yes/success).
pf() {
  bash -c '
    set -uo pipefail
    NAMESPACE=suite366
    kc() {
      case "$*" in
        *"command -v pg_restore"*) return "$POD_HAS" ;;
        *preflight.dump*) cat >/dev/null 2>&1 || true; return "$VERDICT" ;;
      esac
      return 0
    }
    have() { [[ "$1" == "pg_restore" ]] && return "$HOST_HAS"; command -v "$1" >/dev/null 2>&1; }
    pg_restore() { return "$VERDICT"; }
    eval "$(sed -n "/^preflight_dump() {/,/^}/p" "$1")"
    preflight_dump "$2" drive-postgres
  ' _ "$REPO/backup.sh" "$WORK/anydump"
}
printf 'PGDMP-x' > "$WORK/anydump"
check "pod has pg_restore and accepts the dump  -> ok"          "$(POD_HAS=0 VERDICT=0 HOST_HAS=1 pf)" "ok"
check "pod has pg_restore and REFUSES the dump  -> bad"         "$(POD_HAS=0 VERDICT=1 HOST_HAS=1 pf)" "bad"
check "no pod pg_restore, host has one, accepts -> ok"          "$(POD_HAS=1 VERDICT=0 HOST_HAS=0 pf)" "ok"
check "no pg_restore anywhere                   -> unavailable" "$(POD_HAS=1 VERDICT=1 HOST_HAS=1 pf)" "unavailable"

# --- the happy path, and the ordering that is the whole design ----------------
: > "$KLOG"; : > "$RLOG"
bk restore --in-place --yes; rc=$?
check "a valid in-place restore succeeds" "$rc" "0"

klog="$(cat "$KLOG")"
contains "it takes a pre-restore snapshot" "pre-restore" "$(cat "$RLOG")"
contains "it patches AUTH_SECRET" "patch secret secret-drive-app" "$klog"
contains "it carries the legacy key too" "NEXTAUTH_SECRET" "$klog"
# Scoped to the patch calls: POSTGRES_PASSWORD legitimately appears in the
# pg_restore command line (the pod reads it from its own environment).
absent  "it does NOT restore POSTGRES_PASSWORD" "POSTGRES_PASSWORD" \
        "$(grep 'patch secret' "$KLOG" || true)"
absent  "it does NOT restore MinIO credentials" "MINIO" \
        "$(grep 'patch secret' "$KLOG" || true)"
contains "it reloads the database" "--clean --if-exists" "$klog"
contains "it stops the app first" "scale deploy/drive-app --replicas=0" "$klog"
contains "it brings the app back" "scale deploy/drive-app --replicas=1" "$klog"

# THE ordering guarantee: the secret has to be in place before the data is.
patch_at=$(grep -n "patch secret" "$KLOG" | head -1 | cut -d: -f1)
# The preflight also mentions pg_restore, so anchor on the reload itself.
restore_at=$(grep -n -- "--clean --if-exists" "$KLOG" | head -1 | cut -d: -f1)
stop_at=$(grep -n -- "--replicas=0" "$KLOG" | head -1 | cut -d: -f1)
if [[ -n "$patch_at" && -n "$restore_at" && "$patch_at" -lt "$restore_at" ]]; then
  ok "AUTH_SECRET is patched BEFORE the data is reloaded"
else
  ko "AUTH_SECRET is patched BEFORE the data is reloaded" "patch@${patch_at:-none} restore@${restore_at:-none}"
fi
if [[ -n "$stop_at" && -n "$restore_at" && "$stop_at" -lt "$restore_at" ]]; then
  ok "the app is stopped BEFORE the data is reloaded"
else
  ko "the app is stopped BEFORE the data is reloaded" "stop@${stop_at:-none} restore@${restore_at:-none}"
fi

# .minio.sys holds THIS install's root credentials. Restoring the snapshot's
# copy over it locks you out of the objects you just restored.
check "the live .minio.sys is untouched" "$(cat "$MINIO_DATA/.minio.sys/iam.json")" "iam"
[[ -f "$MINIO_DATA/suite-366/doc/part.1" ]] \
  && ok "objects from the snapshot are restored" || ko "objects from the snapshot are restored"
contains "it demands a positive verification" "LLM call using a STORED provider key" "$(out)"
contains "it points at the way back" "pre-restore" "$(out)"
unset MINIO_PVC

echo "== concurrent runs =="
( flock 9; sleep 3 ) 9>"$BACKUP_DIR/.lock" &
holder=$!
sleep 0.3
bk run
check "a second concurrent run is refused" "$?" "1"
wait "$holder" 2>/dev/null

echo "== configuration from the admin UI =="
export SYSTEMD_DIR="$WORK/systemd"; mkdir -p "$SYSTEMD_DIR"
cfg() { # cfg JSON -> runs the configure trigger
  printf '%s\n' "$1" > "$BACKUP_DIR/configure-requested"
  "$DATA/backup.sh" handle-trigger configure >"$WORK/out" 2>&1 </dev/null
}
key_before="$(sha256sum "$BACKUP_DIR/repo.pass" | awk '{print $1}')"

# THE path a new appliance actually takes: an admin configures a destination on
# a box that has never had a backup.env. Every other test in this file writes
# one first, which is exactly why this went unnoticed until it died inside a
# systemd unit on real hardware.
command rm -f "$BACKUP_DIR/backup.env"
cfg '{"repository":"/var/tmp/first-run/repo","requested_by":"admin@acme.tld"}'
check "the FIRST configuration, with no backup.env, succeeds" "$?" "0"
contains "and writes the destination" "BACKUP_REPO=/var/tmp/first-run/repo" \
  "$(cat "$BACKUP_DIR/backup.env" 2>/dev/null)"
contains "with empty credentials rather than an unbound variable" \
  "BACKUP_S3_ACCESS_KEY=" "$(cat "$BACKUP_DIR/backup.env" 2>/dev/null)"

# A repository string that is not a restic backend must never reach
# RESTIC_REPOSITORY: that variable is read by a process running as root.
for bad in 'rm -rf /' 'file:///etc/passwd' 's3:bucket;curl evil' '$(id)' 'http://x/y'; do
  cfg "{\"repository\":\"$bad\",\"requested_by\":\"a@b.c\"}"
  if [[ $? -ne 0 ]] && grep -q 'refusing' "$WORK/out"; then
    ok "rejected: $bad"
  else
    ko "rejected: $bad" "$(out)"
  fi
done

cfg '{"repository":"s3:s3.fr-par.scw.cloud/bucket/box-1","access_key":"AK","secret_key":"SK","region":"fr-par","keep_daily":14,"keep_weekly":8,"keep_monthly":12,"schedule":"03:15","requested_by":"admin@acme.tld"}'
check "a valid destination is accepted" "$?" "0"
env_file="$BACKUP_DIR/backup.env"
check "backup.env is 0600 (the pod runs as 1001 and must not read it back)" \
  "$(stat -c '%a' "$env_file")" "600"
contains "the repository is written" "BACKUP_REPO=s3:s3.fr-par.scw.cloud/bucket/box-1" "$(cat "$env_file")"
contains "retention is written"      "BACKUP_KEEP_DAILY=14" "$(cat "$env_file")"
contains "the schedule is written"   "BACKUP_SCHEDULE=03:15" "$(cat "$env_file")"
check "the trigger file is consumed" "$([[ -e "$BACKUP_DIR/configure-requested" ]] && echo present || echo gone)" "gone"
check "the encryption key is NOT regenerated" \
  "$(sha256sum "$BACKUP_DIR/repo.pass" | awk '{print $1}')" "$key_before"
contains "the timer is re-armed at the new time" "OnCalendar=*-*-* 03:15:00" \
  "$(cat "$SYSTEMD_DIR/suite366-backup.timer")"
for k in run test configure; do
  [[ -f "$SYSTEMD_DIR/suite366-backup-$k.path" ]] \
    && ok "the $k trigger unit is installed" || ko "the $k trigger unit is installed"
done
contains "the configure unit runs the right verb" "handle-trigger configure" \
  "$(cat "$SYSTEMD_DIR/suite366-backup-configure.service")"

# A destination an admin has just chosen is almost always EMPTY, and `test` on
# an empty one used to report "wrong credentials, wrong key, or unreachable" —
# false on all three counts, and it sends them to re-check a correct S3 key.
touch "$WORK/no-repo"; : > "$RLOG"
cfg '{"repository":"s3:s3.fr-par.scw.cloud/bucket/fresh","requested_by":"admin@acme.tld"}'
check "configuring an EMPTY destination succeeds" "$?" "0"
contains "because it initialises the repository first" "init" "$(cat "$RLOG")"
command rm -f "$WORK/no-repo"


# Changing only the schedule must not require the UI to round-trip a secret.
cfg '{"repository":"s3:s3.fr-par.scw.cloud/bucket/box-1","access_key":"","secret_key":"","schedule":"04:05","requested_by":"admin@acme.tld"}'
contains "an empty secret keeps the stored one" "BACKUP_S3_SECRET_KEY=SK" "$(cat "$env_file")"
contains "and the schedule still changes" "BACKUP_SCHEDULE=04:05" "$(cat "$env_file")"

# Retaining nothing would let the first prune delete every snapshot.
cfg '{"repository":"s3:s3.fr-par.scw.cloud/bucket/box-1","keep_daily":0,"requested_by":"a@b.c"}'
contains "keep_daily=0 is floored to 1" "BACKUP_KEEP_DAILY=1" "$(cat "$env_file")"

# Moving the destination is legitimate, but it must be said out loud.
cfg '{"repository":"s3:s3.fr-par.scw.cloud/other/box-1","requested_by":"a@b.c"}'
contains "changing the destination warns about the old snapshots" "destination CHANGED" "$(out)"

# The run/test triggers consume their own file, so the .path unit does not loop.
: > "$RLOG"; write_env "s3:s3.example.com/bucket/spark-01"
touch "$BACKUP_DIR/run-requested"
"$DATA/backup.sh" handle-trigger run >"$WORK/out" 2>&1 </dev/null
check "the run trigger is consumed" \
  "$([[ -e "$BACKUP_DIR/run-requested" ]] && echo present || echo gone)" "gone"
contains "and a run really happened" "backup" "$(cat "$RLOG")"
unset SYSTEMD_DIR

echo "== update.sh converges the backup agent =="
# The functions under test live in update.sh. Pull them out verbatim, the same
# way test-package-verify.sh pulls out pkg_verify, so the test cannot drift from
# the shipped code by copying it.
CONV="$WORK/conv"; mkdir -p "$CONV"
CDATA="$CONV/opt/suite366"; mkdir -p "$CDATA/backup"
cp "$REPO/backup.sh" "$CONV/served-backup.sh"
SERVED_SHA="$(sha256sum "$CONV/served-backup.sh" | awk '{print $1}')"

# curl stub: serves the agent from a file:// style local path.
cat > "$BIN/curl" <<EOF
#!/usr/bin/env bash
out=""; url=""
while [[ \$# -gt 0 ]]; do
  case "\$1" in
    -o) out="\$2"; shift 2 ;;
    -*) shift ;;
    *)  url="\$1"; shift ;;
  esac
done
[[ -f "$CONV/serve/\$(basename "\$url")" ]] || exit 22
cp "$CONV/serve/\$(basename "\$url")" "\$out"
EOF
chmod +x "$BIN/curl"
mkdir -p "$CONV/serve"; cp "$CONV/served-backup.sh" "$CONV/serve/backup.sh"

converge() { # converge FUNC EXTRA_ENV...
  local fn="$1"; shift
  env "$@" bash -c '
    set -uo pipefail
    c_b=""; c_g=""; c_y=""; c_r=""; c_0=""
    log()  { printf "==> %s\n" "$*"; }
    info() { printf "    %s\n" "$*"; }
    warn() { printf "!!  %s\n" "$*"; }
    have() { command -v "$1" >/dev/null 2>&1; }
    eval "$(sed -n "/^converge_backup() {/,/^}/p"              "$1")"
    eval "$(sed -n "/^install_restic_online() {/,/^}/p"        "$1")"
    eval "$(sed -n "/^arm_backup_agent() {/,/^}/p"             "$1")"
    eval "$(sed -n "/^converge_backup_from_package() {/,/^}/p" "$1")"
    "$2"
  ' _ "$REPO/update.sh" "$fn" 2>&1
}

CSYSD="$CONV/systemd"; mkdir -p "$CSYSD"
CENV=(DATA_DIR="$CDATA" BACKUP_AGENT="$CDATA/backup.sh" BACKUP_DIR="$CDATA/backup"
      BACKUP_URL="http://x/backup.sh" RESTIC_BIN="$BIN/restic" SELF_UPDATE=1
      SYSTEMD_DIR="$CSYSD" PATH="$BIN:$PATH")

# 1. A box that never had a backup layer: strict mode, signed manifest, right hash.
rm -f "$CDATA/backup.sh"
o="$(converge converge_backup "${CENV[@]}" \
      PACKAGE_PUBLIC_KEY="$WORK/good.pub" online_signed=1 online_backup_sha="$SERVED_SHA")"
[[ -x "$CDATA/backup.sh" ]] && ok "agent installed on a box that had none" \
  || ko "agent installed on a box that had none" "$o"
contains "it arms the timer on first install" "arming its timer" "$o"
# Assert the units, not the log line: the first version of this test checked
# only the message and passed while install-units was failing on a permission
# error nobody read.
[[ -f "$CSYSD/suite366-backup.timer" && -f "$CSYSD/suite366-backup-run.path" ]] \
  && ok "the timer and trigger units really exist" \
  || ko "the timer and trigger units really exist"
[[ ! -e "$CDATA/backup/repo.pass" ]] && ok "convergence does NOT invent a repository key" \
  || ko "convergence does NOT invent a repository key" "a key appeared"
contains "it says backups are not configured" "NOT configured" "$o"
check "the installed agent is byte-identical to the served one" \
  "$(sha256sum "$CDATA/backup.sh" | awk '{print $1}')" "$SERVED_SHA"

# 2. Same box again: no reinstall churn, no second arming — and, the one that
#    bites now that convergence runs on the DAILY check, no backup run. Doing
#    that unconditionally meant a full backup every day at check time on top of
#    the nightly timer.
# `backup.sh run` is the only thing that writes state.json, so removing it and
# checking it stays gone proves convergence did not invoke a run.
command rm -f "$CDATA/backup/state.json"
o="$(converge converge_backup "${CENV[@]}" \
      PACKAGE_PUBLIC_KEY="$WORK/good.pub" online_signed=1 online_backup_sha="$SERVED_SHA")"
absent "a converged box is not re-armed every apply" "arming its timer" "$o"
if [[ -e "$CDATA/backup/state.json" ]]; then
  ko "converging an existing agent does not run a backup" "state.json was rewritten"
else
  ok "converging an existing agent does not run a backup"
fi

# 3. The hash in the signed manifest does not match what the server returned.
printf '\n# tampered\n' >> "$CONV/serve/backup.sh"
o="$(converge converge_backup "${CENV[@]}" \
      PACKAGE_PUBLIC_KEY="$WORK/good.pub" online_signed=1 online_backup_sha="$SERVED_SHA")"
contains "a mismatched hash is REFUSED" "REFUSING backup.sh" "$o"
check "and the on-disk agent is untouched" \
  "$(sha256sum "$CDATA/backup.sh" | awk '{print $1}')" "$SERVED_SHA"
cp "$CONV/served-backup.sh" "$CONV/serve/backup.sh"

# 4. Key present but the manifest carries no backup_sha256: fail closed. This is
#    the case a forgotten tools/sign-channel.sh produces, and it must refuse
#    rather than fall back to trusting TLS.
o="$(converge converge_backup "${CENV[@]}" \
      PACKAGE_PUBLIC_KEY="$WORK/good.pub" online_signed=1 online_backup_sha="")"
contains "no backup_sha256 in a signed manifest => refuse" "carries no backup_sha256" "$o"

# 5. Key present, manifest NOT signature-verified: refuse.
o="$(converge converge_backup "${CENV[@]}" \
      PACKAGE_PUBLIC_KEY="$WORK/good.pub" online_signed=0 online_backup_sha="$SERVED_SHA")"
contains "an unverified manifest => refuse" "was not signature-verified" "$o"

# 6. SELF_UPDATE=0 (a fleet box that only moves with signed packages).
rm -f "$CDATA/backup.sh"
o="$(converge converge_backup "${CENV[@]/SELF_UPDATE=1/SELF_UPDATE=0}" \
      PACKAGE_PUBLIC_KEY="$WORK/good.pub" online_signed=1 online_backup_sha="$SERVED_SHA")"
[[ ! -e "$CDATA/backup.sh" ]] && ok "SELF_UPDATE=0 installs nothing" \
  || ko "SELF_UPDATE=0 installs nothing" "$o"

# 6b. An agent with no restic is an armed timer that can never run, so a
#     networked box must be able to fetch the binary — verified against the
#     hash in the SIGNED manifest, not against whatever the server returned.
RB2="$CDATA/bin/restic"; command rm -f "$RB2" "$CDATA/backup.sh"
printf 'fake restic payload\n' | bzip2 -c > "$CONV/serve/restic.bz2" 2>/dev/null || true
if [[ -s "$CONV/serve/restic.bz2" ]]; then
  RSHA="$(sha256sum "$CONV/serve/restic.bz2" | awk '{print $1}')"
  # curl stub already serves anything under $CONV/serve by basename; point the
  # download at it by giving the loop a matching name.
  cp "$CONV/serve/restic.bz2" "$CONV/serve/restic_9.9.9_linux_$(uname -m | sed 's/aarch64/arm64/;s/x86_64/amd64/').bz2"
  o="$(converge converge_backup "${CENV[@]/RESTIC_BIN=$BIN\/restic/RESTIC_BIN=$RB2}" \
        PACKAGE_PUBLIC_KEY="$WORK/good.pub" online_signed=1 online_backup_sha="$SERVED_SHA" \
        online_restic_ver=9.9.9 online_restic_sha="$RSHA")"
  [[ -s "$RB2" ]] && ok "restic is fetched online when the agent has none" \
    || ko "restic is fetched online when the agent has none" "$o"

  # The whole point of pinning: a binary that does not match the signed hash
  # runs nightly as root with the destination's credentials.
  command rm -f "$RB2" "$CDATA/backup.sh"
  o="$(converge converge_backup "${CENV[@]/RESTIC_BIN=$BIN\/restic/RESTIC_BIN=$RB2}" \
        PACKAGE_PUBLIC_KEY="$WORK/good.pub" online_signed=1 online_backup_sha="$SERVED_SHA" \
        online_restic_ver=9.9.9 online_restic_sha="0000000000000000000000000000000000000000000000000000000000000000")"
  [[ ! -e "$RB2" ]] && ok "a restic that does not match the signed hash is REFUSED" \
    || ko "a restic that does not match the signed hash is REFUSED" "$o"
  contains "and says why" "REFUSING restic" "$o"

  # No pin published at all: say so rather than install something unverified.
  command rm -f "$RB2" "$CDATA/backup.sh"
  o="$(converge converge_backup "${CENV[@]/RESTIC_BIN=$BIN\/restic/RESTIC_BIN=$RB2}" \
        PACKAGE_PUBLIC_KEY="$WORK/good.pub" online_signed=1 online_backup_sha="$SERVED_SHA" \
        online_restic_ver="" online_restic_sha="")"
  contains "no restic pin in the manifest is reported, not guessed" "no restic pin" "$o"
  # …and the agent still lands, so the box reports its state instead of nothing.
  [[ -x "$CDATA/backup.sh" ]] && ok "the agent installs anyway" || ko "the agent installs anyway"
else
  printf '  \033[33mSKIP\033[0m online restic fetch (no bzip2)\n'
fi

# 7. The offline path: agent AND restic come out of the staged package.
PKGD="$CONV/pkg"; mkdir -p "$PKGD/scripts" "$PKGD/bin"
cp "$CONV/served-backup.sh" "$PKGD/scripts/backup.sh"
printf '#!/usr/bin/env bash\necho "restic 0.19.1 from package"\n' > "$PKGD/bin/restic"
chmod +x "$PKGD/bin/restic"
RB="$CDATA/bin/restic"; rm -f "$RB" "$CDATA/backup.sh"
o="$(converge converge_backup_from_package "${CENV[@]/RESTIC_BIN=$BIN\/restic/RESTIC_BIN=$RB}" \
      OFFLINE_PKG="$PKGD")"
[[ -x "$CDATA/backup.sh" ]] && ok "package installs the agent" || ko "package installs the agent" "$o"
[[ -x "$RB" ]] && ok "package installs restic (an air-gapped box cannot fetch it)" \
  || ko "package installs restic (an air-gapped box cannot fetch it)" "$o"
contains "and arms the timer" "arming its timer" "$o"

echo "== real restic round trip (skipped if restic is absent) =="
if PATH="$ORIG_PATH" command -v restic >/dev/null 2>&1; then
  RREPO="$WORK/realrepo"; RSRC="$WORK/realsrc"; RDST="$WORK/realdst"
  mkdir -p "$RSRC"; echo "the original bytes" > "$RSRC/data.txt"
  export RESTIC_REPOSITORY="$RREPO" RESTIC_PASSWORD="test-encryption-key"
  export RESTIC_CACHE_DIR="$WORK/rcache"
  PATH="$ORIG_PATH" restic init >/dev/null 2>&1 \
    && PATH="$ORIG_PATH" restic backup "$RSRC" >/dev/null 2>&1 \
    && PATH="$ORIG_PATH" restic restore latest --target "$RDST" >/dev/null 2>&1
  if [[ -f "$RDST$RSRC/data.txt" ]] && diff -q "$RSRC/data.txt" "$RDST$RSRC/data.txt" >/dev/null; then
    ok "real restic: backup -> restore returns identical bytes"
  else
    ko "real restic: backup -> restore returns identical bytes"
  fi
  unset RESTIC_REPOSITORY RESTIC_PASSWORD RESTIC_CACHE_DIR
else
  printf '  \033[33mSKIP\033[0m real restic round trip (no restic on PATH)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == "0" ]]
