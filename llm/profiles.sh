# shellcheck shell=bash
# =============================================================================
# llm/profiles.sh — the four generative models the appliance can serve, and
# the transcription model that rides along with the ones that leave room for it.
#
# SINGLE source of truth, sourced by two callers that cannot share code
# otherwise: lib/config.sh at install time, and switch-model.sh on a running
# box (a standalone script, no lib/). Keep it dependency-free: no logging
# helpers, no `set -e` assumptions, pure parameter assignment.
#
# A profile is the whole recipe, not just a model id. The four differ in the
# IMAGE they need, the share of the unified pool they can take, and the context
# they can actually seat — every number here was measured on the test Spark and
# the reasoning lives next to it. The vLLM FLAGS live in llm/serve-llm.sh,
# which runs inside the container; this file is the host-side table.
# =============================================================================

# Order matters: it is the order the operator sees in `switch-model.sh --list`.
LLM_PROFILES="qwen27b orcasaq flash-next gemma"

llm_profile_known() { # llm_profile_known KEY
  case " $LLM_PROFILES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# --- Transcription (speech-to-text) -------------------------------------------
# A THIRD vLLM next to the generative one and the embed, on the OpenAI
# `/v1/audio/transcriptions` route the app already speaks (dictation, voice
# reports, meeting notes — serveur/src/lib/agents/transcription-client.ts).
# Qwen3-ASR-1.7B: 2.35B parameters, 4.4 GiB of BF16 weights, 30 languages with
# automatic detection, 4.75 % WER on FLEURS French (Whisper-large-v3: 6.31), and
# vLLM passes the app's vocabulary `prompt` to it as context — Voxtral's route
# drops it, which is why Voxtral lost despite a better French score.
#
# Only the profiles that leave the room get it. qwen27b runs at 86/121 GiB with
# the two other vLLMs up and at 97/121 with this one added (measured 2026-09-22:
# 4.5 GiB of weights loaded in 43 s, ~10 GiB resident in all, 35 s of French
# transcribed in 2.9 s through the proxy, 5 s in 0.5 s); flash-next sits at
# 116/121 with swap in use (no); gemma and orcasaq were measured next to it on
# 2026-09-25 (the numbers sit in their blocks below). One transcription model
# for now: a profile names it, or leaves LLM_P_STT_MODEL empty and the switch
# takes the container down.
LLM_STT_MODEL_DEFAULT="Qwen/Qwen3-ASR-1.7B"
# Bump when llm/stt/Dockerfile changes: the tag is how a box knows to rebuild.
LLM_STT_IMAGE_REV="1"
# Budgets, the same for every profile that serves it. With the KV budget
# explicit, the fraction only has to clear vLLM's start-up check (free memory
# >= fraction x total): 0.10 = 12 GiB. KV: ~112 KiB per token on this 28-layer,
# 8-KV-head decoder, so 2 GiB seats ~18k tokens; a 30 s window is ~400 audio
# tokens plus its transcript, and the route splits longer audio into 30 s
# windows itself (llm/stt/Dockerfile explains the chunking). max_model_len has
# to stay UNDER what the KV budget seats, or vLLM refuses to start.
LLM_STT_GPU_MEM_UTIL="0.10"
LLM_STT_KV_CACHE_BYTES="2147483648"
LLM_STT_MAX_MODEL_LEN="8192"
LLM_STT_MAX_NUM_SEQS="8"

llm_stt_image() { # llm_stt_image BASE_IMAGE -> the tag of the locally built image
  printf 'suite366/vllm-stt:%s-r%s' "${1##*:}" "$LLM_STT_IMAGE_REV"
}

# --- EXL3 (exllamav3 trellis) checkpoints ------------------------------------
# The orcasaq profile serves a 3.2-bit trellis quantisation that vLLM cannot read
# by itself: llm/exl3/Dockerfile compiles exllamav3's kernels for the GB10 and
# installs the plugin that registers the format. Same rule as the transcription
# image: bump the revision when anything under llm/exl3/ changes.
LLM_EXL3_IMAGE_REV="1"
llm_exl3_image() { # llm_exl3_image BASE_IMAGE -> the tag of the locally built image
  printf 'suite366/vllm-exl3:%s-r%s' "${1##*:}" "$LLM_EXL3_IMAGE_REV"
}

# llm_profile_apply KEY BASE_IMAGE FLASH_NEXT_TAG
#
# Sets, for the caller, a LLM_P_* variable per knob: MODEL, IMAGE,
# GPU_MEM_UTIL, MAX_MODEL_LEN, MAX_NUM_SEQS, CONTEXT_WINDOW, MTP_TOKENS,
# NEEDS_BUILD (0|1) with BUILD_DIR (the llm/ subdirectory holding the
# Dockerfile the image is built from, when NEEDS_BUILD is 1), SWAPPINESS
# (empty = leave the host default), STT_MODEL (the transcription model served
# next to it; empty = none).
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
      LLM_P_BUILD_DIR=""
      LLM_P_SWAPPINESS=""
      # 34 GiB free measured next to it.
      LLM_P_STT_MODEL="$LLM_STT_MODEL_DEFAULT"
      ;;
    orcasaq)
      # OrcaSAQ-2-27B: Qwen3.8-27B again, quantised by orcarouter with a
      # sensitivity-searched mixed-precision trellis code (EXL3 / QTIP family):
      # 3.21 bits per decoder weight, 6-bit lm_head, int8 embedding, 4-bit MTP
      # head, 12.3 GB on disk for 54 GB of BF16 (-77 %), and the card's own
      # figures put it within 0.02 % of BF16 perplexity on WikiText-2 (5.6482
      # against 5.6468, 93.2 % top-1 agreement). Text-only: the vision tower is
      # not shipped, so the app's vision role falls back to the same model
      # without images. Published 2026-09-24; the quantiser itself is not
      # public, only the serving code (llm/exl3/). Same context, same parsers,
      # same MTP head as qwen27b — what changes is the image (built on the box,
      # llm/exl3/Dockerfile, ~4 min: exllamav3 compiles in 160 s on the 20 cores)
      # and the memory. Measured 2026-09-25: 11.5 GiB resident against 20.8,
      # loaded in 56 s, serving 110 s after the container start with the
      # compile cache warm. At 0.45 (the same share as qwen27b) the KV cache is
      # 801,326 fp8 tokens = 3.06x a full 262k request, profiled as a switch
      # does it (embed up, transcription engine down); 0.30 was not enough for
      # ONE 262k request once the embed was charged against the share (7.85 of
      # the 9.13 GiB needed). All three engines up: 97/121 GiB, like qwen27b.
      # Decode 38 t/s on French prose and 45 on code against 19-20 and ~30
      # for the NVFP4 build (12 GiB over the same 273 GB/s); prefill SLOWER,
      # 1,014 tok/s against ~1,400, because above 144 rows every projection is
      # rebuilt to BF16 in a scratch buffer before its GEMM. The 4-bit MTP head
      # is what makes it fast: off, 15.7 t/s on prose and 15.6 on code; k=2
      # 33.9 / 37.5 (52 t/s over two streams); k=3 38.1 / 45.0 (47.7 over two).
      # k=3 as for qwen27b — one user at a time is the case — at 771,787 KV
      # tokens (2.94x a full request) instead of 796,858.
      LLM_P_MODEL="orcarouter/OrcaSAQ-2-27B"
      LLM_P_IMAGE="$(llm_exl3_image "$base_image")"
      LLM_P_GPU_MEM_UTIL="0.45"
      LLM_P_MAX_MODEL_LEN="262144"
      LLM_P_MAX_NUM_SEQS="2"
      LLM_P_CONTEXT_WINDOW="200000"
      LLM_P_MTP_TOKENS="3"
      LLM_P_NEEDS_BUILD="1"
      LLM_P_BUILD_DIR="exl3"
      LLM_P_SWAPPINESS=""
      LLM_P_STT_MODEL="$LLM_STT_MODEL_DEFAULT"
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
      LLM_P_BUILD_DIR="flash-next"
      # 117/121 GiB used and 7-10 GiB of swap in use once it is up; at the
      # default 60, pages were read back from swap during every generation.
      LLM_P_SWAPPINESS="10"
      # 5 GiB free and swap already in use: nothing else fits beside it.
      LLM_P_STT_MODEL=""
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
      # 0.45, down from the 0.55 it shipped with, to leave the transcription
      # engine its room: at 0.55 the box had 7.9 GiB free once Gemma was up and
      # the transcription engine, which needs 12.2 free to clear vLLM's
      # start-up check, restarted nine times (2026-09-25). At 0.45 the KV cache
      # is ~300k fp8 tokens when Gemma profiles with the embed only (a switch)
      # and 222k when the transcription engine was still resident — which is
      # why switch-model.sh takes it down first. Gemma's KV is ~43 KiB per
      # token, 4x the dense 27B's, so 0.45 seats one 262k request, not three.
      LLM_P_GPU_MEM_UTIL="0.45"
      LLM_P_MAX_MODEL_LEN="262144"
      LLM_P_MAX_NUM_SEQS="2"
      LLM_P_CONTEXT_WINDOW="200000"
      LLM_P_MTP_TOKENS=""
      LLM_P_NEEDS_BUILD="0"
      LLM_P_BUILD_DIR=""
      LLM_P_SWAPPINESS=""
      # Measured 2026-09-25 with the share above: both engines up, 87/121 GiB
      # used, 35 s of French transcribed in 2.6 s through the proxy.
      LLM_P_STT_MODEL="$LLM_STT_MODEL_DEFAULT"
      ;;
    *) return 1 ;;
  esac
}

# One line per profile for the operator, without loading anything.
llm_profile_summary() { # llm_profile_summary KEY
  case "$1" in
    qwen27b)    printf 'dense 27B, NVFP4 — 262k context, ~20 t/s, real headroom' ;;
    orcasaq)    printf 'dense 27B, 3.2-bit EXL3 — 262k context, ~38 t/s, 12 GB of weights, image built on the box' ;;
    flash-next) printf 'MoE 176B-A6B — 131k context, ~30 t/s, n-gram table on the NVMe, no memory headroom' ;;
    gemma)      printf 'MoE 26B-A4B — 262k context, ~29 t/s, the model the appliance shipped with (pinned vLLM 0.19)' ;;
  esac
}
