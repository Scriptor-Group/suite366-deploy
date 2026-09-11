#!/usr/bin/env bash
# =============================================================================
# Tests for update.sh's "is there an update?" decision.
#
# It used to be `cur != want`, which made a channel that LAGS the installer
# look like an update. That is not hypothetical: the stable channel sat at
# chart 0.8.0 while lib/config.sh installed 0.9.0, so every box built in that
# window published `update_available: true, "chart 0.9.0 -> 0.8.0"` and offered
# the admin UI a button that silently removed whatever 0.9.0 had added.
#
# ver_gt and compute_diffs are pulled out of update.sh verbatim.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
ko() { printf '  \033[31mFAIL\033[0m %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail+1)); }

# diffs CUR_CHART WANT_CHART CUR_APP WANT_APP CUR_VLLM WANT_VLLM
# Prints "<chart_diff><app_diff><vllm_diff> <summary>" then any operator output.
diffs() {
  env cur_chart="$1" want_chart="$2" cur_app="$3" want_app="$4" \
      cur_vllm="$5" want_vllm="$6" bash -c '
    set -uo pipefail
    info() { printf "    %s\n" "$*"; }
    warn() { printf "!!  %s\n" "$*"; }
    UPDATE_SOURCE=online; channel=stable
    for f in ver_gt compute_diffs; do
      eval "$(sed -n "/^$f() {/,/^}/p" "$1")"
    done
    compute_diffs > /tmp/_diffout 2>&1
    printf "%s%s%s %s\n" "$chart_diff" "$app_diff" "$vllm_diff" "${summary_line:-<none>}"
    cat /tmp/_diffout; rm -f /tmp/_diffout
  ' _ "$REPO/update.sh" 2>&1
}

echo "== a channel that lags must never look like an update =="
out="$(diffs 0.9.0 0.8.0 1.8.22 1.8.22 img img)"
[[ "${out%% *}" == "000" ]] && ok "chart 0.9.0 with a channel at 0.8.0 is not an update" \
  || ko "chart 0.9.0 with a channel at 0.8.0 is not an update" "$out"
grep -q "BEHIND" <<<"$out" && ok "  and the operator is told the channel is behind" \
  || ko "  and the operator is told the channel is behind" "$out"
out="$(diffs 0.9.0 0.9.0 1.9.0 1.8.22 img img)"
[[ "${out%% *}" == "000" ]] && ok "an app older than the installed one is not an update" \
  || ko "an app older than the installed one is not an update" "$out"

echo "== a real roll forward still is one =="
out="$(diffs 0.9.0 0.10.0 1.8.22 1.8.22 img img)"
[[ "${out%% *}" == "100" ]] && ok "chart 0.9.0 -> 0.10.0 is an update" \
  || ko "chart 0.9.0 -> 0.10.0 is an update" "$out"
grep -q "chart 0.9.0 -> 0.10.0" <<<"$out" && ok "  and says so" || ko "  and says so" "$out"
# The reason ver_gt exists at all: a string compare puts 0.10.0 below 0.9.0.
out="$(diffs 0.10.0 0.9.0 1.8.22 1.8.22 img img)"
[[ "${out%% *}" == "000" ]] && ok "0.10.0 is newer than 0.9.0 (not a string compare)" \
  || ko "0.10.0 is newer than 0.9.0 (not a string compare)" "$out"
out="$(diffs 0.9.0 0.9.0 1.8.9 1.8.10 img img)"
[[ "${out%% *}" == "010" ]] && ok "app 1.8.9 -> 1.8.10 is an update (not a string compare)" \
  || ko "app 1.8.9 -> 1.8.10 is an update (not a string compare)" "$out"

echo "== the vLLM image is a tag, not a version =="
# `cu130-nightly` does not order, so any change is a roll in both directions.
out="$(diffs 0.9.0 0.9.0 1.8.22 1.8.22 vllm:old vllm:new)"
[[ "${out%% *}" == "001" ]] && ok "a changed image tag is an update" \
  || ko "a changed image tag is an update" "$out"
out="$(diffs 0.9.0 0.9.0 1.8.22 1.8.22 vllm:same vllm:same)"
[[ "${out%% *}" == "000" ]] && ok "an unchanged image tag is not" \
  || ko "an unchanged image tag is not" "$out"

echo "== nothing known means nothing proposed =="
# An unreadable helm release (cur_chart empty) must not read as "0 -> 0.8.0".
out="$(diffs "" 0.8.0 "" 1.8.22 "" img)"
[[ "${out%% *}" == "000" ]] && ok "an unreadable current version proposes nothing" \
  || ko "an unreadable current version proposes nothing" "$out"
out="$(diffs 0.9.0 "" 1.8.22 "" img "")"
[[ "${out%% *}" == "000" ]] && ok "a manifest with no target proposes nothing" \
  || ko "a manifest with no target proposes nothing" "$out"

echo "== an app release moves EVERY image pin, or none of them =="
# The four images ride one release train (suite-366's Publish Public Image
# builds them under a single version), so values.yaml must never end up with
# one of them left behind: the workbench runner was, for as long as it was
# pinned to `latest` and therefore had nothing to rewrite. A box that
# pre-pulls one version and runs another only finds out offline.
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/values.yaml" <<'YAML'
image:
  tag: "1.0.0"
sandbox:
  api:
    image: ghcr.io/scriptor-group/suite-366-sandbox-api:1.0.0
  runnerImage: ghcr.io/scriptor-group/suite-366-sandbox-runner:1.0.0
  workbench:
    runnerImage: ghcr.io/scriptor-group/suite-366-workbench-runner:1.0.0
YAML
# The rewrite is EXTRACTED from update.sh, not retyped: a fifth pin added there
# and forgotten here would otherwise pass.
rew="$(grep -n 'sed -i "s|' "$REPO/update.sh" | grep -E 'tag: |sandbox-api|sandbox-runner|workbench-runner' | cut -d: -f2- )"
[[ -n "$rew" ]] && ok "the pin rewrite is found in update.sh" || ko "the pin rewrite is found in update.sh"
( want_app=2.0.0 vals="$WORK/values.yaml"; eval "$rew" )
left="$(grep -c '1\.0\.0' "$WORK/values.yaml")"
[[ "$left" == "0" ]] && ok "no pin is left on the old version" \
  || ko "no pin is left on the old version" "$(grep -n '1\.0\.0' "$WORK/values.yaml" | tr '\n' ' ')"
moved="$(grep -c '2\.0\.0' "$WORK/values.yaml")"
[[ "$moved" == "4" ]] && ok "all four pins moved (app + 3 runners)" \
  || ko "all four pins moved (app + 3 runners)" "$moved moved"
grep -q 'workbench-runner:2.0.0' "$WORK/values.yaml" \
  && ok "  the workbench runner included" || ko "  the workbench runner included"

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
