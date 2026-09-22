# shellcheck shell=bash
# =============================================================================
# llm/profiles.sh — the three generative models the appliance can serve.
#
# SINGLE source of truth, sourced by two callers that cannot share code
# otherwise: lib/config.sh at install time, and switch-model.sh on a running
# box (a standalone script, no lib/). Keep it dependency-free: no logging
# helpers, no `set -e` assumptions, pure parameter assignment.
#
# A profile is the whole recipe, not just a model id. The three differ in the
# IMAGE they need, the share of the unified pool they can take, and the context
# they can actually seat — every number here was measured on the test Spark and
# the reasoning lives next to it. The vLLM FLAGS live in llm/serve-llm.sh,
# which runs inside the container; this file is the host-side table.
# =============================================================================

# Order matters: it is the order the operator sees in `switch-model.sh --list`.
LLM_PROFILES="qwen27b flash-next gemma"

llm_profile_known() { # llm_profile_known KEY
  case " $LLM_PROFILES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# llm_profile_apply KEY BASE_IMAGE FLASH_NEXT_TAG
#
# Sets, for the caller, a LLM_P_* variable per knob: MODEL, IMAGE,
# GPU_MEM_UTIL, MAX_MODEL_LEN, MAX_NUM_SEQS, CONTEXT_WINDOW, MTP_TOKENS,
# NEEDS_BUILD (0|1), SWAPPINESS (empty = leave the host default).
#
# The LLM_P_ prefix is not decoration: it keeps the profile's values distinct
# from the operator's, so install-time code can write `${LLM_MODEL:-$LLM_P_MODEL}`
# and let an explicit override win, while switch-model.sh takes LLM_P_* as
# authoritative — that is the whole point of switching.
#
# BASE_IMAGE is the official vLLM image (also what the embed runs);
# FLASH_NEXT_TAG is the tag lib/config.sh derives for the locally built image.
llm_profile_apply() {
  local key="$1" base_image="$2" flash_next_tag="${3:-}"
  case "$key" in
    qwen27b)
      # NVIDIA's ModelOpt build of Qwen3.8-27B: MLP and lm_head in NVFP4,
      # attention and Gated-DeltaNet projections in FP8, vision tower and MTP
      # head in BF16. 21.9 GB on disk, within a point of BF16 on the card's six
      # benchmarks, and the checkpoint the vLLM recipe marks verified on
      # dgx_spark_gb10.
      LLM_P_MODEL="nvidia/Qwen3.8-27B-NVFP4"
      LLM_P_IMAGE="$base_image"
      # 0.45 -> weights 20.8 GiB + KV 818,650 fp8 tokens = 3.1x a full 262k
      # request. A dense hybrid needs a SMALLER share than the Gemma MoE: only
      # 16 of its 64 layers carry a KV cache, the other 48 are linear attention
      # with a fixed-size state. Measured: 0 swap in use at idle.
      LLM_P_GPU_MEM_UTIL="0.45"
      LLM_P_MAX_MODEL_LEN="262144"
      LLM_P_MAX_NUM_SEQS="2"
      LLM_P_CONTEXT_WINDOW="200000"
      # 3 and 5 measured identical on prose; 3 leaves more KV.
      LLM_P_MTP_TOKENS="3"
      LLM_P_NEEDS_BUILD="0"
      LLM_P_SWAPPINESS=""
      ;;
    flash-next)
      # 176B ultra-sparse MoE, 6B active. 123.5 GB on disk for 121.6 GiB of RAM:
      # it only fits because the 47.7 GiB n-gram table is served from the NVMe
      # by the patch set in llm/flash-next/ instead of being loaded, leaving
      # ~77 GiB resident. Fastest of the three, and the only one that runs the
      # box at its memory wall.
      LLM_P_MODEL="nvidia/Qwen3.8-Flash-Next-NVFP4"
      LLM_P_IMAGE="$flash_next_tag"
      # 0.71 next to the capped embed -> KV 4-7 GiB = 1 to 2 requests of 131k.
      # 0.73 failed vLLM's start-up free-memory check the day after it worked;
      # 0.70 could not seat a single 262k request.
      LLM_P_GPU_MEM_UTIL="0.71"
      LLM_P_MAX_MODEL_LEN="131072"
      LLM_P_MAX_NUM_SEQS="2"
      LLM_P_CONTEXT_WINDOW="131072"
      # The recipe's default. k=3 measured +7 % decode for a point of quality.
      LLM_P_MTP_TOKENS="2"
      LLM_P_NEEDS_BUILD="1"
      # 117/121 GiB used and 7-10 GiB of swap in use once it is up; at the
      # default 60, pages were read back from swap during every generation.
      LLM_P_SWAPPINESS="10"
      ;;
    gemma)
      # The appliance's original model, kept so a box can go back to what it
      # shipped with. MoE, 4B active: it decodes FASTER than the 27B dense
      # (28-30 t/s against 19-20) but is a weaker model with a KV cache 4x
      # more expensive.
      LLM_P_MODEL="nvidia/Gemma-4-26B-A4B-NVFP4"
      # PINNED to the image this model was validated on, deliberately NOT the
      # v0.29.0 the other two need. That tag stopped moving on 2026-04-23
      # (vLLM 0.19) and only knows the Marlin weight-only FP4 path on sm_121;
      # Gemma 4 under v0.29.0 has never been exercised here, so the profile
      # ships the combination that was measured rather than an untested one.
      LLM_P_IMAGE="vllm/vllm-openai:cu130-nightly"
      # 0.55 -> KV cache 401,600 fp8 tokens. Measured with the OLD, uncapped
      # embed; with the capped embed the box has ~16 GiB more headroom.
      LLM_P_GPU_MEM_UTIL="0.55"
      LLM_P_MAX_MODEL_LEN="262144"
      LLM_P_MAX_NUM_SEQS="2"
      LLM_P_CONTEXT_WINDOW="200000"
      LLM_P_MTP_TOKENS=""
      LLM_P_NEEDS_BUILD="0"
      LLM_P_SWAPPINESS=""
      ;;
    *) return 1 ;;
  esac
}

# One line per profile for the operator, without loading anything.
llm_profile_summary() { # llm_profile_summary KEY
  case "$1" in
    qwen27b)    printf 'dense 27B, NVFP4 — 262k context, ~20 t/s, the roomiest of the three' ;;
    flash-next) printf 'MoE 176B-A6B — 131k context, ~30 t/s, n-gram table on the NVMe, no memory headroom' ;;
    gemma)      printf 'MoE 26B-A4B — 262k context, ~29 t/s, the model the appliance shipped with (pinned vLLM 0.19)' ;;
  esac
}
