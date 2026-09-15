#!/usr/bin/env bash
# =============================================================================
# Copy the SHARED vllm-db block from lib/vllm-db.sh into update.sh and
# backup.sh, which cannot source lib/ (they are fetched and run standalone —
# backup.sh:109-111) and therefore carry a verbatim copy.
#
# Run this after editing the block, then ./tools/test-vllm-db.sh to prove the
# three copies agree. CI runs the test, not this script: a drift must fail the
# build, not be silently repaired.
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
