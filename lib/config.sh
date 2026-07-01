# shellcheck shell=bash
# =============================================================================
# lib/config.sh — default settings (all overridable via environment variables).
# Sourced first by install.sh. See the install.sh header for documentation of
# every variable below.
# =============================================================================

# --- Default settings --------------------------------------------------------
DOMAIN="${DOMAIN:-suite366.local}"
# Suite 366 drive chart + container images both live on GHCR under the
# Scriptor-Group org. Public, no login required. Override CHART_REF if you
# mirror it.
CHART_REF="${CHART_REF:-oci://ghcr.io/scriptor-group/chart/drive}"
CHART_VERSION="${CHART_VERSION:-0.7.1}"
# Channel manifest polled daily by the update timer (see setup_update_timer).
# Publishing a new chart_version/vllm_image here rolls the fleet forward;
# appliances NOTIFY only (no auto-apply). Override to pin a box to a private
# channel. UPDATE_WEBHOOK (optional) gets a JSON POST when an update is found.
MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/Scriptor-Group/suite366-deploy/main/channel.json}"
UPDATE_WEBHOOK="${UPDATE_WEBHOOK:-}"
NAMESPACE="${NAMESPACE:-suite366}"
SANDBOX_NAMESPACE="${SANDBOX_NAMESPACE:-sandbox}"
RELEASE="${RELEASE:-drive}"

LLM_MODEL="${LLM_MODEL:-nvidia/Gemma-4-26B-A4B-NVFP4}"
EMBED_MODEL="${EMBED_MODEL:-Qwen/Qwen3-VL-Embedding-8B}"
# vLLM image: MUST be arm64 + validated for Blackwell GB10/sm_121. Default is
# the official Docker Hub image `vllm/vllm-openai:cu130-nightly` (cu13 + arm64
# multi-arch, validated on DGX Spark — no `docker login` required). Alternative
# if you want the NGC NVIDIA build, override with
# VLLM_IMAGE=nvcr.io/nvidia/vllm:25.11-py3 (requires `docker login nvcr.io`).
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:cu130-nightly}"
# Tiny URL-path proxy unifying the two vLLM instances behind a single
# OpenAI-compatible endpoint — matches the Suite 366 PR #325 contract
# (one VLLM_BASE_URL, per-role VLLM_MODEL_*). We use nginx:alpine (~50 MB,
# no Python, no startup overhead) over heavier alternatives like LiteLLM.
PROXY_IMAGE="${PROXY_IMAGE:-nginx:alpine}"
LLM_PORT="${LLM_PORT:-8001}"
EMBED_PORT="${EMBED_PORT:-8002}"
PROXY_PORT="${PROXY_PORT:-8000}"
# Embedding dimension served by the local embed model — exposed to the app
# via VLLM_EMBEDDING_DIMENSIONS so pgvector indexes the right shape.
VLLM_EMBEDDING_DIMENSIONS="${VLLM_EMBEDDING_DIMENSIONS:-4096}"
# Max context window (tokens) the app advertises for the local model — exposed
# via VLLM_MAX_CONTEXT_WINDOW so prompt assembly / truncation sizes correctly.
VLLM_MAX_CONTEXT_WINDOW="${VLLM_MAX_CONTEXT_WINDOW:-200000}"

# --- Licensing ---------------------------------------------------------------
# Ed25519 (EdDSA) PUBLIC key shipped to the app to VERIFY signed license
# tokens. Public/verification-only -> safe to ship with the appliance; it
# cannot sign or forge licenses (the private key stays with Devana). Stored
# single-line with literal `\n`; YAML turns them into real PEM newlines when
# the chart renders the value. Override per-deployment via the env var.
_DEFAULT_LICENSE_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAk84/ONPJm9WFpnlQAf7IpRTfdcwwH4Ua3f7NAZtf6/4=\n-----END PUBLIC KEY-----\n'
LICENSE_PUBLIC_KEY="${LICENSE_PUBLIC_KEY:-$_DEFAULT_LICENSE_PUBLIC_KEY}"

# --- vLLM tuning for the GB10 UNIFIED memory (one shared pool ~121 GiB) -------
# Both vLLM instances share this pool (along with the OS, runtime, and KV
# cache): we bound each one (sum < 1.0, headroom kept). The generative is
# prioritized; embeddings get a smaller share.
#
# Values validated on Spark (fresh install test):
#   LLM 0.55 -> KV cache = 402,416 tokens (fp8) -> fits max_model_len=262144 ×
#     max_num_seqs=2 without preemption (measured, 0% swap).
#   EMBED 0.30 -> effective KV cache ~4 GiB for Qwen3-VL-Embedding-8B (8192
#     max model len), once the pool is shared with a warm LLM. 0.25 fails in
#     practice: vLLM sees the LLM's memory as "workspace" on the unified pool
#     -> KV cache computed at 0.41 GiB, not enough. 0.20 -> negative KV.
#   Sum 0.85 -> ~18 GiB of OS headroom on 121 GiB. Measured workable but
#     tight: `free -h` shows ~110/121 GiB used at idle.
#   max_num_seqs=2: above that, chunked_prefill collapses gen throughput
#     (the bottleneck is GB10's prefill compute, not memory). 4 = no
#     measurable improvement, just more OS pressure.
LLM_GPU_MEM_UTIL="${LLM_GPU_MEM_UTIL:-0.55}"
EMBED_GPU_MEM_UTIL="${EMBED_GPU_MEM_UTIL:-0.30}"
LLM_MAX_NUM_SEQS="${LLM_MAX_NUM_SEQS:-2}"
LLM_MAX_MODEL_LEN="${LLM_MAX_MODEL_LEN:-262144}"
EMBED_MAX_MODEL_LEN="${EMBED_MAX_MODEL_LEN:-8192}"

DATA_DIR="${DATA_DIR:-/opt/suite366}"
MODELS_DIR="${MODELS_DIR:-$DATA_DIR/models}"
ASSUME_YES="${ASSUME_YES:-0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"

# --- Test mode (VM/box without DGX): relax hardware checks ------------------
#   SKIP_ARCH_CHECK=1  allow arches other than aarch64/x86_64 (both native now)
#   SKIP_GPU=1         don't require an NVIDIA GPU (implies SKIP_VLLM=1)
#   SKIP_VLLM=1        don't deploy the vLLM stack (infra + app only)
SKIP_ARCH_CHECK="${SKIP_ARCH_CHECK:-0}"
SKIP_GPU="${SKIP_GPU:-0}"
SKIP_VLLM="${SKIP_VLLM:-0}"
[[ "$SKIP_GPU" == "1" ]] && SKIP_VLLM=1

KUBECONFIG_PATH=/etc/rancher/k3s/k3s.yaml
