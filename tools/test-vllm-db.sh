#!/usr/bin/env bash
# =============================================================================
# Self-test: the vLLM key reaches the database row, a stale row fails the
# install, and a model that is still loading does not.
#
# Why each group of assertions exists — all three come from one production
# incident (15/09/2026: four days of 401 on every LLM call while `docker ps`
# said Up (healthy) and every pod was Running):
#
#  • THE SQL. The row the app reads is written once, at organization creation,
#    and never re-read. The UPDATE that realigns it must be a no-op when
#    already correct (it runs on every daily check), must CREATE an apiKey the
#    app omitted, must not be sent at all when the table does not exist, and
#    must never touch a provider row an admin aimed at another vLLM.
#  • THE VERDICTS. A 401 from the key STORED IN POSTGRES is a broken appliance
#    and must fail the install. A proxy that has not answered yet is a model
#    still loading and must NOT. Those two were indistinguishable before.
#  • THE THREE COPIES. update.sh and backup.sh cannot source lib/, so they
#    carry the block verbatim. If a copy drifts, one of the three paths that
#    can leave a stale key stops being fixed — silently. Hence the sha256s.
#
# No cluster, no database, no network: k3s, curl and sleep are stubbed.
# =============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ORIG_PATH="$PATH"
CLOG="$WORK/curl.log"
c_g="\033[32m"; c_r="\033[31m"; c_0="\033[0m"
pass=0; fail=0
ok() { printf "  ${c_g}PASS${c_0} %s\n" "$1"; pass=$((pass + 1)); }
ko() { printf "  ${c_r}FAIL${c_0} %s\n" "$1"; fail=$((fail + 1)); }
check()    { if [[ "$2" == "$3" ]]; then ok "$1"; else ko "$1 (expected '$2', got '$3')"; fi; }
contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else ko "$3"; fi; }
absent()   { if grep -qF -- "$2" <<<"$1"; then ko "$3"; else ok "$3"; fi; }

# --- stubs -------------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/data"
cat > "$WORK/bin/k3s" <<'EOF'
#!/usr/bin/env bash
shift                       # drop "kubectl"
args="$*"
case "$args" in
  *"get deploy -o name"*)
    if [[ -f "$WORK/no-pg" ]]; then printf '%s\n' deployment.apps/drive-app; exit 0; fi
    printf '%s\n' deployment.apps/drive-app deployment.apps/drive-postgres ;;
  *exec*)
    cat > "$WORK/sql.txt"                 # the SQL arrives on STDIN — capture it
    printf '%s\n' "$args" >> "$WORK/kargs.txt"
    if [[ -f "$WORK/pg-dead" ]]; then exit 1; fi
    cat "$WORK/pg-out" 2>/dev/null || true ;;
  *) exit 0 ;;
esac
EOF
cat > "$WORK/bin/curl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CLOG"
url="${*##* }"
code=200
case "$url" in
  */v1/models)           code="$(cat "$WORK/code-models" 2>/dev/null || printf 200)" ;;
  */v1/chat/completions) code="$(cat "$WORK/code-chat"   2>/dev/null || printf 200)" ;;
  */v1/embeddings)       code="$(cat "$WORK/code-embed"  2>/dev/null || printf 200)" ;;
esac
printf '%s' "$code"
if [[ "$code" == "000" ]]; then exit 7; fi   # curl's own behaviour on a connect failure
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/sleep"   # the retry loop is under test, its 60s are not
chmod +x "$WORK/bin/k3s" "$WORK/bin/curl" "$WORK/bin/sleep"

# --- harness -----------------------------------------------------------------
# The shipped block is SOURCED, never copied (test-local-certs.sh:76-78), and it
# runs under `set -euo pipefail` on purpose: that is install.sh:108's
# environment, and the `[[ ]] &&`-as-last-statement trap documented at
# lib/preflight.sh:470-472 has bitten this repo before.
{
  printf 'NAMESPACE=suite366\nDATA_DIR=%s\nPG_DEPLOY=""\nLLM_MODEL=m\nEMBED_MODEL=e\n' "$WORK/data"
  cat <<'H'
log()  { printf 'LOG %s\n' "$*"; }
info() { printf 'INFO %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die()  { printf 'DIE %s\n' "$*"; exit 1; }
kc()   { k3s kubectl "$@"; }
H
  sed -n '/^# >>> SHARED vllm-db BLOCK/,/^# <<< END SHARED vllm-db BLOCK <<</p' "$REPO/lib/vllm-db.sh"
  sed -n '/^vllm_db_gate() {/,/^}/p' "$REPO/lib/vllm-db.sh"
} > "$WORK/prelude.sh"

# Output on stdout, and the exit status of the code under test as our own — a
# command substitution runs in a subshell, so a variable set inside it never
# reaches the caller. Call sites therefore read `$?` into RC themselves.
run() { # run CODE -> output ; exit status = the code's
  local out rc
  # shellcheck disable=SC2097,SC2098  # deliberate, and the same pattern as
  # lib/backup.sh:32: the prefix assignments are ENV FOR THE CHILD (the stubs
  # read WORK and CLOG), while $WORK inside the command string is expanded by
  # THIS shell, which is exactly what builds the path to the prelude.
  out="$(PATH="$WORK/bin:$ORIG_PATH" WORK="$WORK" CLOG="$CLOG" \
           bash -c "set -euo pipefail
                    source '$WORK/prelude.sh'
                    $1
                    printf 'VERDICT=%s\n' \"\${VLLM_DB_VERIFIED:-unset}\"" 2>&1)"
  rc=$?
  printf '%s' "$out"
  return "$rc"
}
reset() {
  rm -f "$WORK/sql.txt" "$WORK/kargs.txt" "$WORK/pg-out" "$WORK/pg-dead" "$WORK/no-pg" \
        "$WORK/code-models" "$WORK/code-chat" "$WORK/code-embed" "$CLOG"
}
KEY=sk-QWU7gPzIW4k4pZNyoYx9wt07N9y3KBGo
URL=http://10.99.0.1:8000/v1
# A key shaped like an injection attempt. The quotes and the semicolon are the
# POINT of the fixture, so they stay literal on purpose.
# shellcheck disable=SC2089,SC2090
BADKEY='sk-x@; DELETE FROM "AIProvider"; --'
# shellcheck disable=SC2090
export BADKEY          # read inside run()'s subshell, which runs under `set -u`

printf '\n== reconcile: the SQL ==\n'
reset; printf 'realigned=2\n' > "$WORK/pg-out"
out="$(run "reconcile_vllm_db_key '$KEY' '$URL'")"; RC=$?; sql="$(cat "$WORK/sql.txt")"
check "a realignment exits 0" 0 "$RC"
contains "$out" "realigned 2 AIProvider row(s)" "the row count reaches the operator"
contains "$sql" "$KEY"        "the current key is in the statement"
contains "$sql" "$URL"        "the current baseUrl is in the statement"
contains "$sql" 'to_regclass' "the missing-table guard is present"
contains "$sql" '\if :have_ai' "the guard is psql's if — a statement naming a missing table fails at PARSE time"
contains "$sql" "'{apiKey}', to_jsonb" "apiKey is set"
contains "$sql" ', true)'     "create_missing=true — the app omits apiKey when its own env var is empty"
contains "$sql" 'IS DISTINCT FROM' "the no-op property: this runs on every daily check"
contains "$sql" "name = 'vLLM Local'" "the row scope names the app's own seed"
contains "$sql" "LIKE 'http://10.99.0.1:%'" "…and rows already aimed at this box"
contains "$sql" '"updatedAt" = now()' "updatedAt is set — the column has no database default"
absent "$(cat "$WORK/kargs.txt")" "$KEY" "the key travels on stdin, never in an argv (ps, shell history)"

printf '\n== reconcile: never fatal ==\n'
reset; printf 'realigned=0\n' > "$WORK/pg-out"
out="$(run "reconcile_vllm_db_key '$KEY' '$URL'")"; RC=$?
check "an aligned row exits 0" 0 "$RC"
contains "$out" "already matches this box" "…and says so rather than claiming a fix"
absent "$out" "realigned 0 AIProvider" "…and does not report a realignment"
reset; printf 'realigned=no-table\n' > "$WORK/pg-out"
out="$(run "reconcile_vllm_db_key '$KEY' '$URL'")"; RC=$?
check "a pre-migration box exits 0" 0 "$RC"
contains "$out" "no AIProvider table yet" "…with the reason"
reset; touch "$WORK/pg-dead"
out="$(run "reconcile_vllm_db_key '$KEY' '$URL'")"; RC=$?
check "an unreachable database exits 0" 0 "$RC"
contains "$out" "could not reach the database" "…with the reason"
reset; touch "$WORK/no-pg"
out="$(run "reconcile_vllm_db_key '$KEY' '$URL'")"; RC=$?
check "no -postgres deployment exits 0 (the pipefail hazard of backup.sh:319)" 0 "$RC"
contains "$out" "no *-postgres deployment" "…with the reason"
reset
out="$(run "reconcile_vllm_db_key \"\$BADKEY\" '$URL'" )"; RC=$?
check "a key that is not our shape is refused, not escaped" 0 "$RC"
check "…and NO SQL is built at all" "" "$(cat "$WORK/sql.txt" 2>/dev/null || true)"
reset
out="$(run "reconcile_vllm_db_key '$KEY' 'http://10.99.0.1/v1'")"; RC=$?
contains "$out" "not a usable base URL" "a portless URL is refused (its LIKE prefix would be http:%)"

printf '\n== verify: the three outcomes ==\n'
reset; printf 'rows\nk=%s\n' "$KEY" > "$WORK/pg-out"; printf 401 > "$WORK/code-models"
out="$(run "verify_vllm_db_key '$URL' 1")"; RC=$?
check "a stored key vLLM rejects exits 0 (the gate decides, not this)" 0 "$RC"
contains "$out" "VERDICT=stale" "…recorded as stale"
contains "$out" "REJECTED by vLLM" "…and named"
reset; printf 'rows\nk=%s\n' "$KEY" > "$WORK/pg-out"; printf 000 > "$WORK/code-models"
out="$(run "verify_vllm_db_key '$URL' 1")"; RC=$?
contains "$out" "VERDICT=unknown" "a proxy that never answered -> unknown, NOT a failure"
contains "$out" "models can still be loading" "…and says why"
check "…after retrying (6 attempts on a deep check)" 6 "$(grep -c '/v1/models' "$CLOG")"
absent "$(cat "$CLOG")" " -f " "curl never uses -f: it would turn a 401 into exit 22 and lose the code"
reset; printf 'rows\n' > "$WORK/pg-out"
out="$(run "verify_vllm_db_key '$URL' 1")"; RC=$?
contains "$out" "VERDICT=norow" "table present but no row yet -> norow (fresh install)"
reset; printf 'no-table\n' > "$WORK/pg-out"
out="$(run "verify_vllm_db_key '$URL' 1")"; RC=$?
contains "$out" "VERDICT=notable" "no table -> notable"
reset; printf 'rows\nk=\n' > "$WORK/pg-out"
out="$(run "verify_vllm_db_key '$URL' 1")"; RC=$?
contains "$out" "VERDICT=stale" "a row whose config carries NO apiKey -> stale"
reset; printf 'rows\nk=%s\nk=sk-other\n' "$KEY" > "$WORK/pg-out"
out="$(run "verify_vllm_db_key '$URL' 1")"; RC=$?
contains "$out" "VERDICT=stale" "two different stored keys -> stale (realignment did not converge)"
contains "$out" "did not converge" "…and says so"
reset; printf 'rows\nk=%s\n' "$KEY" > "$WORK/pg-out"; printf 401 > "$WORK/code-embed"
out="$(run "verify_vllm_db_key '$URL' 1")"; RC=$?
contains "$out" "VERDICT=stale" "chat OK + embeddings 401 -> stale (the routes are different containers)"
reset; printf 'rows\nk=%s\n' "$KEY" > "$WORK/pg-out"; printf 502 > "$WORK/code-embed"
out="$(run "verify_vllm_db_key '$URL' 1")"; RC=$?
contains "$out" "VERDICT=ok" "an embed model still loading is not a bad key"
reset; printf 'rows\nk=%s\n' "$KEY" > "$WORK/pg-out"; printf 404 > "$WORK/code-chat"
out="$(run "verify_vllm_db_key '$URL' 1")"; RC=$?
contains "$out" "VERDICT=ok" "a 404 proves the key was ACCEPTED (vLLM checks auth before routing)"
reset; printf 'rows\nk=%s\n' "$KEY" > "$WORK/pg-out"
out="$(run "verify_vllm_db_key '$URL' 0")"; RC=$?
contains "$out" "VERDICT=ok" "a shallow check stops at /v1/models"
check "…and POSTs nothing (the daily check must not hit the LLM)" 0 "$(grep -c 'data-binary' "$CLOG")"

printf '\n== the gate ==\n'
for v in ok unknown norow notable skipped; do
  reset; out="$(run "VLLM_DB_VERIFIED=$v; vllm_db_gate")"; RC=$?
  check "the gate lets '$v' through" 0 "$RC"
done
reset; out="$(run "VLLM_DB_VERIFIED=stale; vllm_db_gate")"; RC=$?
check "the gate fails the install on 'stale'" 1 "$RC"
contains "$out" "STORED IN POSTGRES" "…naming the copy at fault"

printf '\n== the three copies cannot drift ==\n'
for f in vllm_key_sane vllm_url_sane vllm_row_scope vllm_pg_deploy vllm_http_code vllm_verdict \
         reconcile_vllm_db_key verify_vllm_db_key vllm_local_env reconcile_and_check_vllm_db; do
  body="$(sed -n "/^$f() {/,/^}/p" "$REPO/lib/vllm-db.sh")"
  # Not padding: without this, a renamed function extracts to three empty
  # strings that compare equal, and the test would pass while guarding nothing
  # (test-backup.sh:589-591 records the same lesson).
  if [[ -z "$body" ]]; then ko "$f is extractable from lib/vllm-db.sh"; continue; fi
  ok "$f is extractable from lib/vllm-db.sh"
  a="$(sed -n "/^$f() {/,/^}/p" "$REPO/lib/vllm-db.sh" | sha256sum)"
  for g in update.sh backup.sh; do
    b="$(sed -n "/^$f() {/,/^}/p" "$REPO/$g" | sha256sum)"
    check "$f is byte-identical in $g" "$a" "$b"
  done
done

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
