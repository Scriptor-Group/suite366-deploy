#!/usr/bin/env bash
# =============================================================================
# Tests for update.sh's extension hooks (run_update_hooks).
#
# A layer installed on top of the product (suite366-fleet) is converged by the
# same check/apply through $HOOKS_DIR. Root runs these hooks, so the cases that
# matter are the ones that must NOT run: a directory or a file someone else
# could have written, a symlink. And a failing hook must never fail the update.
#
# run_update_hooks is pulled out of update.sh verbatim.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
ko() { printf '  \033[31mFAIL\033[0m %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail+1)); }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# hooks MODE -> runs run_update_hooks MODE against $T/hooks.d; prints its output
# then "rc=<n>".
hooks() {
  HOOKS_DIR="$T/hooks.d" DATA_DIR="$T" bash -c '
    set -euo pipefail
    log()  { printf "==> %s\n" "$*"; }
    warn() { printf "!!  %s\n" "$*"; }
    UPDATE_SOURCE=online OFFLINE_PKG="$DATA_DIR/offline/pkg"
    PACKAGE_PUBLIC_KEY="$DATA_DIR/k.pub" PACKAGE_PUBLIC_KEY_NEXT="$DATA_DIR/k2.pub"
    eval "$(sed -n "/^run_update_hooks() {/,/^}/p" "$1")"
    run_update_hooks "$2"
    echo "rc=$?"
  ' _ "$REPO/update.sh" "$1" 2>&1
}

mkhook() { # mkhook NAME BODY
  printf '#!/usr/bin/env bash\n%s\n' "$2" > "$T/hooks.d/$1"
  chmod 0755 "$T/hooks.d/$1"
}

echo "== no hooks directory: nothing happens =="
out="$(hooks check)"
[[ "$out" == "rc=0" ]] && ok "absent hooks.d is a no-op" || ko "absent hooks.d is a no-op" "$out"

echo "== a hook is called with the verb and the update context =="
mkdir -m 0755 "$T/hooks.d"
mkhook 50-fleet 'echo "called $1 src=$UPDATE_SOURCE data=$DATA_DIR pkg=$OFFLINE_PKG key=$PACKAGE_PUBLIC_KEY"'
out="$(hooks apply)"
grep -q "called apply src=online data=$T pkg=$T/offline/pkg key=$T/k.pub" <<<"$out" \
  && ok "hook gets apply, UPDATE_SOURCE, DATA_DIR, OFFLINE_PKG, PACKAGE_PUBLIC_KEY" \
  || ko "hook gets apply and its context" "$out"
out="$(hooks check)"
grep -q "called check" <<<"$out" && ok "hook gets check" || ko "hook gets check" "$out"

echo "== hooks run in name order =="
mkhook 10-first 'echo first'
out="$(hooks check)"
[[ "$(grep -n 'first' <<<"$out" | head -1 | cut -d: -f1)" -lt "$(grep -n 'called' <<<"$out" | cut -d: -f1)" ]] \
  && ok "10-first before 50-fleet" || ko "10-first before 50-fleet" "$out"
rm -f "$T/hooks.d/10-first"

echo "== a failing hook never fails the update =="
mkhook 60-broken 'echo boom; exit 3'
out="$(hooks apply)"
grep -q "60-broken apply exited 3" <<<"$out" && ok "the failure is reported" || ko "the failure is reported" "$out"
grep -q "rc=0" <<<"$out" && ok "  and run_update_hooks still returns 0 (under set -e)" || ko "run_update_hooks returns 0" "$out"
rm -f "$T/hooks.d/60-broken"

echo "== what someone else could have written is NOT run =="
mkhook 70-gw 'echo GROUPWRITABLE-RAN'; chmod 0775 "$T/hooks.d/70-gw"
out="$(hooks check)"
! grep -q "GROUPWRITABLE-RAN" <<<"$out" && grep -q "skipping .*70-gw" <<<"$out" \
  && ok "a group-writable hook is skipped" || ko "a group-writable hook is skipped" "$out"
rm -f "$T/hooks.d/70-gw"

printf '#!/usr/bin/env bash\necho SYMLINK-RAN\n' > "$T/target"; chmod 0755 "$T/target"
ln -s "$T/target" "$T/hooks.d/80-link"
out="$(hooks check)"
! grep -q "SYMLINK-RAN" <<<"$out" && grep -q "skipping .*80-link" <<<"$out" \
  && ok "a symlinked hook is skipped" || ko "a symlinked hook is skipped" "$out"
rm -f "$T/hooks.d/80-link"

printf 'echo NOEXEC-RAN\n' > "$T/hooks.d/90-noexec"; chmod 0644 "$T/hooks.d/90-noexec"
out="$(hooks check)"
! grep -q "NOEXEC-RAN" <<<"$out" && ok "a non-executable file is skipped" || ko "a non-executable file is skipped" "$out"
rm -f "$T/hooks.d/90-noexec"

chmod 0777 "$T/hooks.d"
out="$(hooks check)"
! grep -q "called" <<<"$out" && grep -q "writable by others — no hook run" <<<"$out" \
  && ok "a world-writable hooks.d runs nothing" || ko "a world-writable hooks.d runs nothing" "$out"
chmod 0755 "$T/hooks.d"

mv "$T/hooks.d" "$T/real-hooks"; ln -s "$T/real-hooks" "$T/hooks.d"
out="$(hooks check)"
! grep -q "called" <<<"$out" && grep -q "is a symlink" <<<"$out" \
  && ok "a symlinked hooks.d runs nothing" || ko "a symlinked hooks.d runs nothing" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
