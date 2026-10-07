#!/usr/bin/env bash
# =============================================================================
# Regression test for the ORDER of deploy_vllm (lib/vllm.sh) on a FRESH box.
#
# switch-model.sh refuses to start without VLLM_IMAGE in $DATA_DIR/llm/.env,
# and deploy_vllm writes that file itself. `switch-model.sh install-units` —
# which creates the llm-state bridge, arms the model-switch .path unit and
# publishes the first state.json — used to run BEFORE the write, so on every
# fresh install it died with "VLLM_IMAGE missing from …/.env". Only a warning:
# the box shipped with no bridge (kubelet then created llm-state root:root
# 0755) and the app's model page stuck on "the appliance has not published the
# state of its models yet" (gb10-812nqm4, 2026-10-05). Re-runs never showed it:
# by then .env exists.
#
# What it proves: on a box with NO llm/.env, install-units runs after the .env
# carries VLLM_IMAGE and succeeds, and the warning is not printed.
#
# No GPU, no Docker, no systemd: switch-model.sh is a stub that applies the
# real guard, every heavy helper is overridden, the rest runs for real.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
ko() { printf '  \033[31mFAIL\033[0m %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail+1)); }
contains() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else ko "$1" "missing: $3"; fi; }
absent()   { if grep -qF -- "$3" <<<"$2"; then ko "$1" "present: $3"; else ok "$1"; fi; }

BIN="$WORK/bin"; mkdir -p "$BIN"
printf '#!/bin/sh\nexit 0\n' > "$BIN/systemctl"; chmod +x "$BIN/systemctl"
export PATH="$BIN:$PATH"

export DATA_DIR="$WORK/opt/suite366"; mkdir -p "$DATA_DIR"
export MODELS_DIR="$WORK/models" CACHE_DIR="$WORK/cache"

# switch-model.sh, reduced to the guard that bit and a trace of each verb.
cat > "$DATA_DIR/switch-model.sh" <<'EOF'
#!/usr/bin/env bash
env_file="$DATA_DIR/llm/.env"
if ! grep -q '^VLLM_IMAGE=.' "$env_file" 2>/dev/null; then
  echo "xx  VLLM_IMAGE missing from $env_file — is this an installed appliance?" >&2
  exit 1
fi
echo "switch-model $1 OK"
EOF
chmod +x "$DATA_DIR/switch-model.sh"

# install.sh defines the output helpers, not lib/common.sh. Without these, the
# "does not warn" check below passed on the broken order too — `warn` was
# simply not found — and `info` ran texinfo.
log()  { printf '==> %s\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '!!  %s\n' "$*"; }
die()  { printf 'xx  %s\n' "$*" >&2; exit 1; }
# shellcheck source=/dev/null
. "$REPO/lib/common.sh"
# shellcheck source=/dev/null
. "$REPO/lib/vllm.sh"
# The profile table: deploy_vllm re-applies the profile once the engine image
# is resolved (the real one asks docker; here it is VLLM_IMAGE itself).
# shellcheck source=/dev/null
. "$REPO/llm/profiles.sh"
FLASH_NEXT_IMAGE="$(llm_flash_next_image)"
# Everything that would need the host, the network or a GPU.
fetch_host_layer()    { :; }
ensure_engine_image() { ENGINE_IMAGE="$VLLM_IMAGE"; }
build_profile_image() { :; }
apply_vllm_sysctl()   { :; }
wait_http()           { return 1; }
warmup_chat()  { :; }; warmup_embed() { :; }; warmup_stt() { :; }

# The variables deploy_vllm writes into .env; values do not matter here.
export VLLM_IMAGE=vllm/vllm-openai:v0.29.0 VLLM_LLM_IMAGE=vllm/vllm-openai:v0.29.0 \
  LLM_PROFILE=qwen27b PROXY_IMAGE=nginx:alpine VLLM_API_KEY=k SUITE_IP=10.99.0.1 \
  LLM_MODEL=m EMBED_MODEL=e LLM_PORT=8000 EMBED_PORT=8001 STT_PORT=8002 PROXY_PORT=8080 \
  LLM_STT_MODEL="" LLM_P_NEEDS_BUILD=0 LLM_P_SWAPPINESS=10 CDI_SPEC=/etc/cdi/nvidia.yaml

printf '\n%s\n' "fresh install (no llm/.env yet)"
[[ ! -e "$DATA_DIR/llm/.env" ]] && ok "the box starts with no llm/.env" || ko "the box starts with no llm/.env"
out="$( (set +u; deploy_vllm) 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
contains "install-units runs and succeeds"            "$out" "switch-model install-units OK"
absent   "  …the guard does not fire"                 "$out" "VLLM_IMAGE missing"
absent   "  …and the install does not warn about it"  "$out" "could not arm the model-switch trigger"
contains "install-vllm-unit still runs too"           "$out" "switch-model install-vllm-unit OK"
order="$(grep -oE 'switch-model (install-units|install-vllm-unit) OK' <<<"$out" | awk '{print $2}' | tr '\n' ' ')"
contains "  …both after .env is written"             "$order" "install-units"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
