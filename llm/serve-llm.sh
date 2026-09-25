#!/usr/bin/env bash
# Entrypoint of the vllm-llm container. ONE script for the four generative
# profiles, because the compose must not change when the operator switches
# model: everything profile-specific lives here and in llm/profiles.sh.
#
# Split of responsibilities:
#   llm/profiles.sh  (host)      model id, image, memory budgets, context window
#   this file        (container) the vLLM flags and env each model needs
#
# Every flag below was measured on the test Spark; the reasoning is in
# docker-compose.yml and the README. Do not "harmonise" the four lists: they
# are four validated recipes, not one recipe with variables.
set -euo pipefail
: "${LLM_PROFILE:?}" "${LLM_MODEL:?}" "${LLM_MAX_MODEL_LEN:?}" "${LLM_MAX_NUM_SEQS:?}" "${LLM_GPU_MEM_UTIL:?}"

# Shared by the four: bind, budgets, and the fact that the app never sends
# video (not reserving encoder budget for it). The video limit is a no-op on a
# text-only model (orcasaq), vLLM ignores it there.
common=(
  --host 0.0.0.0 --port 8000
  --served-model-name "$LLM_MODEL"
  --max-model-len "$LLM_MAX_MODEL_LEN"
  --max-num-seqs "$LLM_MAX_NUM_SEQS"
  --gpu-memory-utilization "$LLM_GPU_MEM_UTIL"
  --enable-chunked-prefill
  --enable-prefix-caching
  --limit-mm-per-prompt.video=0
)

case "$LLM_PROFILE" in

  # --- Qwen3.8-27B-NVFP4 — dense hybrid, the vLLM recipe's GB10 profile ------
  qwen27b)
    # No --quantization: the ModelOpt mixed NVFP4/FP8 recipe is read from
    # hf_quant_config.json. No --trust-remote-code: config.json carries no
    # auto_map, vLLM's own handler loads this architecture.
    exec vllm serve "$LLM_MODEL" "${common[@]}" \
      --kv-cache-dtype fp8 \
      --max-num-batched-tokens 8192 \
      --async-scheduling \
      --load-format fastsafetensors \
      --reasoning-parser qwen3 \
      --enable-auto-tool-choice --tool-call-parser qwen3_xml \
      --default-chat-template-kwargs '{"enable_thinking": false}' \
      --speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":${LLM_MTP_TOKENS:-3}}"
    ;;

  # --- OrcaSAQ-2-27B — Qwen3.8-27B in a 3.2-bit EXL3 trellis ------------------
  orcasaq)
    # The same recipe as qwen27b, minus what the format changes. No
    # --quantization: config.json says `exl3` and the orcasaq2 plugin baked into
    # the image (llm/exl3/) registers that method when vLLM loads its plugins.
    # No --load-format fastsafetensors: the plugin captures each shard through
    # vLLM's default loader, and 12 GB load in 56 s that way — not worth
    # validating a second loader. Text-only checkpoint: no vision tower to
    # budget for.
    exec vllm serve "$LLM_MODEL" "${common[@]}" \
      --kv-cache-dtype fp8 \
      --max-num-batched-tokens 8192 \
      --async-scheduling \
      --reasoning-parser qwen3 \
      --enable-auto-tool-choice --tool-call-parser qwen3_xml \
      --default-chat-template-kwargs '{"enable_thinking": false}' \
      --speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":${LLM_MTP_TOKENS:-3}}"
    ;;

  # --- Qwen3.8-Flash-Next-NVFP4 — n-gram table mmap-ed from the NVMe ---------
  flash-next)
    # The patch set's knobs (blazux scripts/serve.sh defaults, v0.29 base).
    # Set HERE and not in the compose: VLLM_NVFP4_GEMM_BACKEND and friends are
    # read by every profile's engine, and forcing them on the other two would
    # cost them their native kernels.
    export VLLM_PLE_MMAP=1                  # table served from the NVMe, never loaded
    export VLLM_PLE_MMAP_WORKERS=32
    export VLLM_PLE_MMAP_PREWARM=0
    export VLLM_PLE_MMAP_MADVISE=random     # no readahead on 16-row gathers
    export VLLM_PLE_MMAP_FAST_ROWS=0
    export VLLM_QSA_EXACT_TOPK=0
    export VLLM_QSA_DET_TOPK=1              # stock persistent_topk is non-deterministic on GB10
    export VLLM_QSA_DET_LIB=/opt/llm/kernel-det/_C_det.so
    export VLLM_MTP_DRAFT_VOCAB=/opt/llm/draft_vocab_65536.npy
    export VLLM_FP8_PAD_M4=0
    export VLLM_USE_FLASHINFER_SAMPLER=1
    export VLLM_ALLOW_LONG_MAX_MODEL_LEN=0

    # The mmap patch opens the checkpoint's own shards and refuses an HF id
    # ("point --model at the downloaded snapshot"), so resolve the snapshot
    # directory here. First boot downloads ~133 GB (25 min at 85 MB/s).
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

    # `--model` is the snapshot PATH here, so `common` is expanded after it and
    # --served-model-name (in common) restores the id the app and the database
    # know. fastsafetensors is NOT used: the mmap patch hooks the default loader.
    exec vllm serve "$snap" "${common[@]}" \
      --load-format safetensors \
      --max-num-batched-tokens 8192 \
      -cc.cudagraph_mode=PIECEWISE -cc.splitting_ops="$SPLIT" \
      --no-enable-flashinfer-autotune --kv-cache-dtype auto \
      --reasoning-parser qwen3 \
      --enable-auto-tool-choice --tool-call-parser qwen3_coder \
      --default-chat-template-kwargs '{"enable_thinking": false}' \
      --speculative-config "{\"method\":\"mtp\",\"num_speculative_tokens\":${LLM_MTP_TOKENS:-2}}"
    ;;

  # --- Gemma-4-26B-A4B-NVFP4 — what the appliance shipped with ---------------
  gemma)
    # Only MARLIN (weight-only) is functional for NVFP4 MoE in the vLLM 0.19
    # this profile pins; the FLASHINFER_TRTLLM/CUTLASS paths crash at load.
    # Scoped to this profile on purpose: forcing marlin under v0.29.0 would
    # cost the other two models their native W4A4 kernel.
    export VLLM_USE_FLASHINFER_MOE_FP4=0
    export VLLM_NVFP4_GEMM_BACKEND=marlin
    # --quantization=modelopt is required: auto-detection loads the checkpoint
    # but skips the MoE marlin optimisations. The chat template is mandatory
    # for --tool-call-parser=gemma4 (without it vLLM crashes at boot).
    exec vllm serve "$LLM_MODEL" "${common[@]}" \
      --trust-remote-code \
      --dtype auto \
      --quantization modelopt \
      --moe-backend marlin \
      --kv-cache-dtype fp8 \
      --async-scheduling \
      --chat-template /app/tool_chat_template_gemma4.jinja \
      --enable-auto-tool-choice --tool-call-parser gemma4 --reasoning-parser gemma4
    ;;

  *)
    echo "unknown LLM_PROFILE: $LLM_PROFILE" >&2
    exit 64
    ;;
esac
