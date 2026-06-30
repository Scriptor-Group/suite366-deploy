#!/usr/bin/env bash
# =============================================================================
# Suite 366 — all-in-one installer for NVIDIA DGX Spark (Ubuntu 22.04 / DGX OS)
#
#   curl -fsSL https://<host>/install.sh | sudo bash
#
# Deploys:
#   • single-node k3s (Traefik + local-path + CoreDNS);
#   • vLLM ×2 (generative + embeddings) on Docker host, on the Blackwell GPU;
#   • the full Suite 366 (drive + Postgres + Redis + MinIO + OnlyOffice +
#     LiveKit/TURN) via the `drive` Helm chart;
#   • local TLS (self-signed CA) + mDNS *.suite366.local (Avahi).
#
# Idempotent. Interactive prompts via /dev/tty (compatible with curl|bash), OR
# via environment variables (non-interactive mode):
#   HF_TOKEN                   HuggingFace token (optional, gated models)
#   DOMAIN                     default: suite366.local
#   ADMIN_EMAIL                default: admin@<DOMAIN>
#   LLM_MODEL, EMBED_MODEL     HuggingFace models to serve (defaults validated
#                              on Spark: Gemma-4-26B-A4B-NVFP4 + Qwen3-VL-Embedding-8B)
#   VLLM_IMAGE                 vLLM image arm64/Blackwell sm_121 (default
#                              vllm/vllm-openai:cu130-nightly, see README)
#   PROXY_IMAGE                URL-path proxy image (default nginx:alpine) —
#                              unifies the 2 vLLM instances behind a single
#                              OpenAI-compatible endpoint, wired into the
#                              Suite 366 chart.
#   LLM_GPU_MEM_UTIL,          fractions of the 121 GiB unified pool allocated
#   EMBED_GPU_MEM_UTIL         to each vLLM (sum < 1.0; defaults 0.55 / 0.30)
#   LLM_MAX_NUM_SEQS,          generative tuning (defaults 2 / 262144 — covers
#   LLM_MAX_MODEL_LEN          100% of prod traffic up to 256k tokens)
#   EMBED_MAX_MODEL_LEN        embed max length (default 8192, enough for RAG)
#   VLLM_EMBEDDING_DIMENSIONS  embedding vector dimension served by the local
#                              model (default 4096 = Qwen3-VL-Embedding-8B)
#   VLLM_MAX_CONTEXT_WINDOW    max context window (tokens) the app advertises
#                              for the local model (default 200000)
#   LICENSE_PUBLIC_KEY         Ed25519 SPKI PEM the app uses to VERIFY signed
#                              license tokens (default: shipped public key).
#                              Verification-only — cannot sign/forge licenses.
#   ASSUME_YES=1               don't prompt, accept defaults
#
# -----------------------------------------------------------------------------
# Structure: this file is a thin BOOTSTRAP. The real logic lives in lib/*.sh,
# loaded at runtime by load_module() below. When run locally (repo cloned) the
# modules are sourced from $SCRIPT_DIR/lib; in curl|bash mode they are fetched
# from $BASE_URL/lib (same local-first/remote-fallback rule as fetch()). To add
# a step, drop a lib/<name>.sh defining a function and wire it into MODULES +
# main() here.
# =============================================================================
set -euo pipefail

# --- Source of accompanying files --------------------------------------------
# Next to the script if run locally, otherwise downloaded from BASE_URL
# (curl|bash mode). Applies to both lib/*.sh modules and data files (values.yaml,
# llm/*, tls/*, dns/*, update.sh).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/Scriptor-Group/suite366-deploy/main}"

# --- Output helpers (kept here: the loader needs them before lib/common.sh) --
c_b="\033[1m"; c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_0="\033[0m"
START_TS="$(date +%s)"
_elapsed() { local s=$(( $(date +%s) - START_TS )); printf '%d:%02d' $((s/60)) $((s%60)); }
log()  { printf "${c_g}==>${c_0} ${c_b}[%s] %s${c_0}\n" "$(_elapsed)" "$*"; }
info() { printf "    [%s] %s\n" "$(_elapsed)" "$*"; }
warn() { printf "${c_y}!!  [%s] %s${c_0}\n" "$(_elapsed)" "$*"; }
die()  { printf "${c_r}xx  [%s] %s${c_0}\n" "$(_elapsed)" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

fetch() { # fetch RELATIVE_PATH -> stdout (local file if available, otherwise BASE_URL)
  local rel="$1"
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$rel" ]]; then cat "$SCRIPT_DIR/$rel"
  else curl -fsSL "$BASE_URL/$rel"; fi
}

# --- Module loader -----------------------------------------------------------
# Source a lib/*.sh module: directly from the local checkout if present,
# otherwise download it to a temp file (with a hard error on failure — process
# substitution would hide a failed curl under `set -o pipefail`) and source it.
load_module() { # load_module NAME  (=> sources lib/NAME.sh)
  local name="$1" rel="lib/$1.sh"
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$rel" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/$rel"
  else
    local tmp; tmp="$(mktemp)"
    curl -fsSL "$BASE_URL/$rel" -o "$tmp" \
      || die "Failed to download module $rel from $BASE_URL (network? wrong BASE_URL?)."
    # shellcheck disable=SC1090
    source "$tmp"
    rm -f "$tmp"
  fi
}

# Load order matters: config (defaults) and common (helpers) first, then each
# deploy step in the order main() calls it.
MODULES=(config common preflight k3s vllm cert-manager suite mdns updater summary)
for _m in "${MODULES[@]}"; do load_module "$_m"; done

main() {
  preflight
  gather_inputs
  install_k3s
  if [[ "$SKIP_VLLM" == "1" ]]; then warn "vLLM stack not deployed (SKIP_VLLM)."; else deploy_vllm; fi
  install_cert_manager
  deploy_suite
  setup_mdns
  setup_update_timer
  summary
}
main "$@"
