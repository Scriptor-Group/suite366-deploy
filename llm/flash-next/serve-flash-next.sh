#!/usr/bin/env bash
# Entrypoint of the vllm-llm container when the generative model is
# Qwen3.8-Flash-Next. It does the two things a bare `vllm serve` cannot:
#
#  1. Make sure the checkpoint is on disk, then resolve its snapshot DIRECTORY.
#     The PLE mmap patch opens the checkpoint's own shards and refuses an HF id
#     ("point --model at the downloaded snapshot"). First boot downloads ~133 GB
#     (25 min at 85 MB/s); later boots find it and start in ~10 min.
#  2. Hand vLLM the flag set measured on the GB10 (documented next to each flag
#     in docker-compose.yml). Everything tunable comes in through the
#     environment the compose passes.
set -euo pipefail
: "${LLM_MODEL:?}" "${LLM_MAX_MODEL_LEN:?}" "${LLM_MAX_NUM_SEQS:?}" "${LLM_GPU_MEM_UTIL:?}"
HF_HOME="${HF_HOME:-/root/.cache/huggingface}"
repo="$HF_HOME/hub/models--${LLM_MODEL//\//--}"

snapshot() { # -> the snapshot directory refs/main points at, or nothing
  local rev; rev="$(cat "$repo/refs/main" 2>/dev/null || true)"
  [[ -n "$rev" && -d "$repo/snapshots/$rev" ]] && printf '%s' "$repo/snapshots/$rev"
}
complete() { # every file the index names is present (a resumed download can leave a hole)
  local snap="$1"
  [[ -f "$snap/model.safetensors.index.json" && -f "$snap/tokenizer.json" ]] || return 1
  python3 - "$snap" <<'PY'
import json, os, sys
snap = sys.argv[1]
files = set(json.load(open(os.path.join(snap, "model.safetensors.index.json")))["weight_map"].values())
sys.exit(0 if all(os.path.exists(os.path.join(snap, f)) for f in files) else 1)
PY
}

snap="$(snapshot || true)"
if [[ -z "$snap" ]] || ! complete "$snap"; then
  echo ">> $LLM_MODEL is not (fully) on disk — downloading (one-time, ~133 GB)"
  HF_HUB_OFFLINE=0 hf download "$LLM_MODEL"
  snap="$(snapshot)"
fi
echo ">> checkpoint: $snap"
export VLLM_PLE_MMAP_DIR="$snap"

# torch.compile splitting ops for the v0.29 base: the recipe's list plus the
# mmap lookup op the patch registers, so the n-gram gather stays outside the
# compiled/captured graph (it reads from the page cache).
SPLIT='["vllm::unified_attention_with_output","vllm::unified_mla_attention_with_output","vllm::mamba_mixer2","vllm::mamba_mixer","vllm::short_conv","vllm::qwen4_exp_compute_ple_ngram_ids","vllm::qwen4_exp_ple_short_conv","vllm::qwen4_exp_qsa_with_output","vllm::linear_attention","vllm::qwen_gdn_attention_core","vllm::qwen_gdn_attention_core_fused_norm_packed","vllm::sparse_attn_indexer","vllm::ple_mmap_lookup_ids"]'

exec vllm serve "$snap" --served-model-name "$LLM_MODEL" \
  --host 0.0.0.0 --port 8000 --load-format safetensors \
  --max-model-len "$LLM_MAX_MODEL_LEN" --max-num-seqs "$LLM_MAX_NUM_SEQS" \
  --gpu-memory-utilization "$LLM_GPU_MEM_UTIL" \
  --enable-prefix-caching --enable-chunked-prefill --max-num-batched-tokens 8192 \
  -cc.cudagraph_mode=PIECEWISE -cc.splitting_ops="$SPLIT" \
  --no-enable-flashinfer-autotune --kv-cache-dtype auto \
  --enable-auto-tool-choice --tool-call-parser qwen3_coder --reasoning-parser qwen3 \
  --default-chat-template-kwargs '{"enable_thinking": false}' \
  --speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":${LLM_MTP_TOKENS:-2}}" \
  --limit-mm-per-prompt.video=0
