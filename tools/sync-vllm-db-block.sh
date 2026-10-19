#!/usr/bin/env bash
# =============================================================================
# Copy the SHARED vllm-db block from lib/vllm-db.sh into update.sh and
# backup.sh, which cannot source lib/ (they are fetched and run standalone —
# backup.sh:109-111) and therefore carry a verbatim copy.
#
# Run this after editing the block, then ./tools/test-vllm-db.sh to prove the
# three copies agree. switch-model.sh receives the two app-version functions
# only (suite_app_version, app_has_local_provider). CI runs the test, not this
# script: a drift must fail the build, not be silently repaired.
# =============================================================================
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$REPO/lib/vllm-db.sh"
BEGIN='# >>> SHARED vllm-db BLOCK'
END='# <<< END SHARED vllm-db BLOCK <<<'

block="$(sed -n "/^$BEGIN/,/^$END/p" "$SRC")"
[[ -n "$block" ]] || { printf 'no block found in %s\n' "$SRC" >&2; exit 1; }

for f in update.sh backup.sh; do
  target="$REPO/$f"
  grep -q "^$BEGIN" "$target" || { printf '%s carries no block markers — insert it once by hand.\n' "$f" >&2; exit 1; }
  BLOCK="$block" python3 - "$target" "$BEGIN" "$END" <<'PY'
import os, sys, pathlib
path, begin, end = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path); s = p.read_text()
i = s.index(begin); j = s.index(end) + len(end)
new = s[:i] + os.environ['BLOCK'] + s[j:]
if new != s:
    p.write_text(new)
    print('%s: block refreshed' % path)
else:
    print('%s: already in sync' % path)
PY
done

# switch-model.sh carries only the two app-version functions of the block (it
# needs to know whether the app still keeps AIModel rows, nothing else).
python3 - "$SRC" "$REPO/switch-model.sh" suite_app_version app_has_local_provider <<'PY'
import re, sys, pathlib
src = pathlib.Path(sys.argv[1]).read_text()
p = pathlib.Path(sys.argv[2]); s = p.read_text(); new = s
for name in sys.argv[3:]:
    pat = re.compile(r'^' + name + r'\(\) \{.*?^\}\n', re.S | re.M)
    m = pat.search(src)
    if not m:
        sys.exit('%s: no %s() in lib/vllm-db.sh' % (p, name))
    if not pat.search(new):
        sys.exit('%s carries no %s() — insert it once by hand.' % (p, name))
    new = pat.sub(lambda _: m.group(0), new, count=1)
if new != s:
    p.write_text(new)
    print('%s: functions refreshed' % p)
else:
    print('%s: already in sync' % p)
PY
