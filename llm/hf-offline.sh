#!/usr/bin/env bash
# =============================================================================
# llm/hf-offline.sh — an engine whose checkpoint is on disk starts without the
# Hugging Face Hub.
#
# `vllm serve <repo id>` talks to the Hub at EVERY start, checkpoint on disk or
# not: to decide what kind of model it is handed, it lists the repository's
# files (vllm/transformers_utils/repo_utils.py, list_repo_files), and that call
# has no fallback to the cache. No answer => the engine exits 1 in a few
# seconds, before it has read one byte of the 20 GiB sitting next to it.
#
# On a box that boots faster than its network, that is every boot. Seen on a
# client box, 2026-11-12 and again 2026-11-13: suite366-vllm.service starts
# 7 s after the kernel (network-online.target is reached on the box's own
# interfaces), the WiFi associates 90 s to 3 min later. In between vllm-llm
# crash-loops on "Temporary failure in name resolution", compose reads the
# restarting container as unhealthy and gives up on its dependants, the unit
# fails — and the box is left for the day with a generative engine that came up
# by itself 4 s after the WiFi did, and no proxy, no embeddings, no
# transcription in front of it. Four boots compared: WiFi before the unit,
# everything up; WiFi after, this.
#
# The rule here, in that order:
#   1. HF_HUB_OFFLINE already set (either value): an operator's decision, kept.
#   2. no checkpoint on disk: nothing to serve offline — the start needs the
#      Hub to download it, and says so in its own words if it cannot.
#   3. the Hub answers for this repository: NOTHING changes. Same start as
#      before this file existed, on every profile and every engine version.
#   4. it does not: HF_HUB_OFFLINE=1. vLLM then resolves the repo id to the
#      snapshot directory and reads everything from there.
#
# (3) is deliberate. Going offline whenever a checkpoint is on disk would also
# pin the revision and survive a Hub outage, but it would change the start of
# every box on every profile at once; this only changes a start that was going
# to fail.
#
# Two uses:
#   • sourced by serve-llm.sh (vllm-llm):  hf_offline_unless_hub "$LLM_MODEL"
#   • entrypoint of vllm-embed / vllm-stt: hf-offline.sh serve MODEL [flags…]
#     i.e. the image's own `vllm serve`, with the decision taken first.
# =============================================================================

# Seconds the probe may take in all. A resolver with no upstream answers at
# once (the case above); this bounds a network that accepts and never replies
# (captive portal, upstream down behind a live access point).
HF_PROBE_TIMEOUT="${HF_PROBE_TIMEOUT:-5}"

hf_snapshot_dir() { # hf_snapshot_dir MODEL -> the snapshot refs/main names, when it holds a config.json
  local repo="${HF_HOME:-/root/.cache/huggingface}/hub/models--${1//\//--}" rev
  rev="$(cat "$repo/refs/main" 2>/dev/null || true)"
  [[ -n "$rev" && -f "$repo/snapshots/$rev/config.json" ]] || return 1
  printf '%s' "$repo/snapshots/$rev"
}

hf_hub_answers() { # hf_hub_answers MODEL -> 0 when the Hub answers for this repository
  local url="${HF_ENDPOINT:-https://huggingface.co}/api/models/$1"
  local token="${HF_TOKEN:-${HUGGING_FACE_HUB_TOKEN:-}}"
  # No probe, no verdict: an image without curl starts as it always did.
  command -v curl >/dev/null 2>&1 || return 0
  # -f: a 5xx, a 429 or a captive portal's page is not an answer. The token of
  # a gated model goes through curl's config on stdin, never on its argv.
  if [[ -n "$token" ]]; then
    curl -fsS -m "$HF_PROBE_TIMEOUT" -o /dev/null -K - "$url" 2>/dev/null \
      <<<"header = \"Authorization: Bearer $token\""
  else
    curl -fsS -m "$HF_PROBE_TIMEOUT" -o /dev/null "$url" 2>/dev/null
  fi
}

hf_offline_unless_hub() { # hf_offline_unless_hub MODEL -> may export HF_HUB_OFFLINE=1
  local model="$1" snap
  if [[ -n "${HF_HUB_OFFLINE:-}" ]]; then
    echo ">> $model: HF_HUB_OFFLINE=$HF_HUB_OFFLINE set by the environment — kept"
    return 0
  fi
  if ! snap="$(hf_snapshot_dir "$model")"; then
    echo ">> $model: no checkpoint on disk yet — this start needs the Hugging Face Hub (download)"
    return 0
  fi
  if hf_hub_answers "$model"; then
    echo ">> $model: the Hugging Face Hub answers — normal start"
    return 0
  fi
  export HF_HUB_OFFLINE=1
  echo ">> $model: the Hugging Face Hub does not answer — serving the checkpoint on disk (revision ${snap##*/}, HF_HUB_OFFLINE=1)"
}

# Run, not sourced: the entrypoint of the engines that have no script of their
# own. The compose keeps their flags; this only decides, then hands over.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  case "${1:-}" in
    serve)
      shift
      [[ $# -ge 1 ]] || { echo "usage: hf-offline.sh serve MODEL [vllm serve flags…]" >&2; exit 64; }
      hf_offline_unless_hub "$1"
      exec vllm serve "$@"
      ;;
    *)
      echo "usage: hf-offline.sh serve MODEL [vllm serve flags…]" >&2
      exit 64
      ;;
  esac
fi
