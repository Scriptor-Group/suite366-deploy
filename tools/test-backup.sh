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
#   • the config snapshot excludes models/, the cache and the key file itself;
#   • a pg_dump that dies mid-stream makes the run PARTIAL, never success (a
#     truncated dump in a valid snapshot is the worst possible outcome: it
#     looks like a backup until someone restores it);
#   • the secrets snapshot exists at all — it is what carries AUTH_SECRET;
#   • credentials embedded in a repository URL never reach state.json;
#   • restore refuses to extract into a directory that is not empty;
#   • two runs cannot overlap;
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
  restore)   mkdir -p "\${3:-$WORK/unused}"; echo restored > "\${3:-$WORK/unused}/postgres.dump"; exit 0 ;;
  *)         exit 0 ;;
esac
EOF

# k3s kubectl: just enough cluster to exercise discovery + the dump pipe.
cat > "$BIN/k3s" <<EOF
#!/usr/bin/env bash
shift   # drop "kubectl"
args="\$*"
case "\$args" in
  *"get deploy -o name"*)  echo "deployment.apps/drive-postgres" ;;
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
contains "config snapshot excludes the key file"  "--exclude $BACKUP_DIR/repo.pass" "$log"
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
write_env "s3:https://AKIAKEY:supersecret@s3.example.com/bucket/spark-01"
bk test
absent "the URL secret is redacted in state.json" "supersecret" "$(state)"
contains "the redaction marker is there"          "<redacted>" "$(state)"
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

echo "== concurrent runs =="
( flock 9; sleep 3 ) 9>"$BACKUP_DIR/.lock" &
holder=$!
sleep 0.3
bk run
check "a second concurrent run is refused" "$?" "1"
wait "$holder" 2>/dev/null

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
    eval "$(sed -n "/^converge_backup() {/,/^}/p"              "$1")"
    eval "$(sed -n "/^arm_backup_agent() {/,/^}/p"             "$1")"
    eval "$(sed -n "/^converge_backup_from_package() {/,/^}/p" "$1")"
    "$2"
  ' _ "$REPO/update.sh" "$fn" 2>&1
}

CENV=(DATA_DIR="$CDATA" BACKUP_AGENT="$CDATA/backup.sh" BACKUP_DIR="$CDATA/backup"
      BACKUP_URL="http://x/backup.sh" RESTIC_BIN="$BIN/restic" SELF_UPDATE=1
      PATH="$BIN:$PATH")

# 1. A box that never had a backup layer: strict mode, signed manifest, right hash.
rm -f "$CDATA/backup.sh"
o="$(converge converge_backup "${CENV[@]}" \
      PACKAGE_PUBLIC_KEY="$WORK/good.pub" online_signed=1 online_backup_sha="$SERVED_SHA")"
[[ -x "$CDATA/backup.sh" ]] && ok "agent installed on a box that had none" \
  || ko "agent installed on a box that had none" "$o"
contains "it arms the timer on first install" "arming its timer" "$o"
[[ ! -e "$CDATA/backup/repo.pass" ]] && ok "convergence does NOT invent a repository key" \
  || ko "convergence does NOT invent a repository key" "a key appeared"
contains "it says backups are not configured" "NOT configured" "$o"
check "the installed agent is byte-identical to the served one" \
  "$(sha256sum "$CDATA/backup.sh" | awk '{print $1}')" "$SERVED_SHA"

# 2. Same box again: no reinstall churn, no second arming.
o="$(converge converge_backup "${CENV[@]}" \
      PACKAGE_PUBLIC_KEY="$WORK/good.pub" online_signed=1 online_backup_sha="$SERVED_SHA")"
absent "a converged box is not re-armed every apply" "arming its timer" "$o"

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
