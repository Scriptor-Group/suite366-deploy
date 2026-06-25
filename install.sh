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
#   ASSUME_YES=1               don't prompt, accept defaults
# =============================================================================
set -euo pipefail

# --- Default settings --------------------------------------------------------
DOMAIN="${DOMAIN:-suite366.local}"
# Suite 366 drive chart + container images both live on GHCR under the
# Scriptor-Group org. Public, no login required. Override CHART_REF if you
# mirror it.
CHART_REF="${CHART_REF:-oci://ghcr.io/scriptor-group/chart/drive}"
CHART_VERSION="${CHART_VERSION:-0.6.0}"
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
#   SKIP_ARCH_CHECK=1  don't require aarch64 (test on x86/arm64 VMs)
#   SKIP_GPU=1         don't require an NVIDIA GPU (implies SKIP_VLLM=1)
#   SKIP_VLLM=1        don't deploy the vLLM stack (infra + app only)
SKIP_ARCH_CHECK="${SKIP_ARCH_CHECK:-0}"
SKIP_GPU="${SKIP_GPU:-0}"
SKIP_VLLM="${SKIP_VLLM:-0}"
[[ "$SKIP_GPU" == "1" ]] && SKIP_VLLM=1

# Source of accompanying files: next to the script if run locally, otherwise
# downloaded from BASE_URL (curl|bash mode).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/Scriptor-Group/suite366-deploy/main}"

KUBECONFIG_PATH=/etc/rancher/k3s/k3s.yaml

# --- Output helpers ----------------------------------------------------------
c_b="\033[1m"; c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_0="\033[0m"
START_TS="$(date +%s)"
_elapsed() { local s=$(( $(date +%s) - START_TS )); printf '%d:%02d' $((s/60)) $((s%60)); }
log()  { printf "${c_g}==>${c_0} ${c_b}[%s] %s${c_0}\n" "$(_elapsed)" "$*"; }
info() { printf "    [%s] %s\n" "$(_elapsed)" "$*"; }
warn() { printf "${c_y}!!  [%s] %s${c_0}\n" "$(_elapsed)" "$*"; }
die()  { printf "${c_r}xx  [%s] %s${c_0}\n" "$(_elapsed)" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
tty_usable() { (exec </dev/tty) >/dev/null 2>&1; }   # /dev/tty exists AND is openable

# Runs a long command in the background and prints the namespace's pod state
# every ~15s, so we don't stare at nothing during `helm --wait`.
run_progress() { # run_progress "label" cmd...
  local label="$1"; shift
  ( "$@" ) & local pid=$! rc=0 n=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 15; n=$((n+15))
    local summary
    summary="$(k3s kubectl -n "$NAMESPACE" get pods --no-headers 2>/dev/null \
      | awk '{c[$3]++} END{for(s in c) printf "%s:%d ", s, c[s]}')"
    info "$label … ${n}s elapsed${summary:+ — pods: $summary}"
  done
  wait "$pid" || rc=$?
  return "$rc"
}

# Interactive read from the terminal (stdin = pipe when curl|bash).
ask() { # ask VAR "prompt" "default"
  local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
  if [[ -n "${!__var:-}" ]]; then return 0; fi          # already supplied via env
  if [[ "$ASSUME_YES" == "1" ]] || ! tty_usable; then printf -v "$__var" '%s' "$__def"; return 0; fi
  read -r -p "$__prompt${__def:+ [$__def]}: " __ans </dev/tty || true
  printf -v "$__var" '%s' "${__ans:-$__def}"
}
ask_secret() { # ask_secret VAR "prompt"
  local __var="$1" __prompt="$2" __ans=""
  if [[ -n "${!__var:-}" ]]; then return 0; fi
  if [[ "$ASSUME_YES" == "1" ]] || ! tty_usable; then return 0; fi
  read -r -s -p "$__prompt: " __ans </dev/tty || true; echo
  printf -v "$__var" '%s' "$__ans"
}

fetch() { # fetch RELATIVE_PATH -> stdout (local file if available, otherwise BASE_URL)
  local rel="$1"
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$rel" ]]; then cat "$SCRIPT_DIR/$rel"
  else curl -fsSL "$BASE_URL/$rel"; fi
}

# --- 0. Preflight ------------------------------------------------------------
preflight() {
  log "Preflight"
  [[ "$(id -u)" == "0" ]] || die "Run as root (sudo)."
  # used by cert-manager (CA) and the chart (values). Locked root-only to
  # keep VLLM_API_KEY (values.yaml), chart secrets render, and
  # other generated tokens out of reach of non-root local users.
  mkdir -p "$DATA_DIR" && chmod 0700 "$DATA_DIR"
  [[ "$SKIP_VLLM" == "1" || "$SKIP_GPU" == "1" || "$SKIP_ARCH_CHECK" == "1" ]] && \
    warn "TEST MODE (SKIP_ARCH_CHECK=$SKIP_ARCH_CHECK SKIP_GPU=$SKIP_GPU SKIP_VLLM=$SKIP_VLLM)."
  if [[ "$(uname -m)" != "aarch64" ]]; then
    [[ "$SKIP_ARCH_CHECK" == "1" ]] || die "Architecture $(uname -m) ≠ aarch64. The DGX Spark is ARM64 (set SKIP_ARCH_CHECK=1 to test)."
    warn "Architecture $(uname -m) ≠ aarch64 — tolerated (test mode)."
  fi
  if have lsb_release; then
    local rel; rel="$(lsb_release -rs 2>/dev/null || echo '?')"
    [[ "$rel" == "22.04" ]] || warn "Ubuntu $rel detected (expected 22.04) — continuing."
  fi
  have curl || die "curl required."

  if [[ "$SKIP_GPU" == "1" ]]; then
    warn "GPU/vLLM checks skipped (SKIP_GPU)."
  else
    have nvidia-smi || die "nvidia-smi not found: NVIDIA driver missing? (SKIP_GPU=1 to test without GPU)"
    nvidia-smi -L >/dev/null 2>&1 || die "nvidia-smi failed: GPU not available."
    info "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
    have docker || die "Docker required (preinstalled on DGX OS)."
    # DGX OS often ships with the `nvidia-container-toolkit` package BUT
    # without having run `nvidia-ctk runtime configure --runtime=docker`:
    # Docker then doesn't see the runtime, and `runtime: nvidia` in the
    # compose file crashes. We decouple toolkit install from runtime
    # registration. (The modern compose uses `gpus: all`, which works via
    # CDI without this step, but registration is still useful for other
    # tools.)
    if ! docker info 2>/dev/null | grep -qiE 'Runtimes:.*nvidia'; then
      if ! have nvidia-ctk; then
        warn "nvidia-container-toolkit missing — installing."
        install_nvidia_toolkit
      else
        warn "nvidia-container-toolkit present but Docker runtime not registered — running nvidia-ctk runtime configure."
        nvidia-ctk runtime configure --runtime=docker && systemctl restart docker
      fi
    fi
    # Persistent CDI specs. The compose uses `gpus: all`, which resolves via
    # CDI device "nvidia.com/gpu=all". DGX OS does NOT ship a persistent spec
    # under /etc/cdi/ ; the toolkit auto-generates one in /var/run/cdi/ (tmpfs)
    # at first container start. After a reboot, /var/run is wiped, the spec
    # is gone, and the next `docker compose up` fails with
    #   "CDI device injection failed: unresolvable CDI devices nvidia.com/gpu=all"
    # which crash-loops every container that requests GPU. Generate the spec
    # ONCE into /etc/cdi/ so it survives reboots.
    if ! [[ -s /etc/cdi/nvidia.yaml ]]; then
      info "Generating persistent CDI spec at /etc/cdi/nvidia.yaml…"
      mkdir -p /etc/cdi
      nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml >/dev/null 2>&1 \
        || warn "nvidia-ctk cdi generate failed — gpus:all may not resolve after reboot."
    fi
  fi

  HOST_IP="${HOST_IP:-$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')}"
  [[ -n "${HOST_IP:-}" ]] || die "LAN IP not found — export HOST_IP=<ip>."
  info "LAN IP: $HOST_IP"

  local avail_g; avail_g=$(df -BG --output=avail "$(dirname "$DATA_DIR")" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
  [[ "${avail_g:-0}" -ge 200 ]] || warn "Disk space ~${avail_g}GB (<200GB recommended: models + images + PVCs)."

  check_connectivity
}

# Fail LOUDLY if any required endpoint is unreachable (otherwise `curl | sh` /
# image pulls die silently under `set -o pipefail`).
check_connectivity() {
  [[ "${SKIP_NET_CHECK:-0}" == "1" ]] && { warn "Connectivity check skipped (SKIP_NET_CHECK)."; return 0; }
  info "Checking outbound connectivity…"
  local endpoints=(
    "https://get.k3s.io"
    "https://get.helm.sh"
    "https://ghcr.io/v2/"
    "https://registry-1.docker.io/v2/"
    "https://huggingface.co"
    "https://charts.jetstack.io"
  )
  # NGC only if we actually pull the vLLM image from nvcr.io
  [[ "${VLLM_IMAGE:-}" == nvcr.io/* ]] && endpoints+=("https://nvcr.io/v2/")
  local u code fails=()
  for u in "${endpoints[@]}"; do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$u" 2>/dev/null || true)"
    if [[ -z "$code" || "$code" == "000" ]]; then fails+=("$u"); info "  ✗ $u (unreachable)"
    else info "  ✓ $u (HTTP $code)"; fi
  done
  if (( ${#fails[@]} )); then
    die "No outbound access to: ${fails[*]}
      The installer downloads k3s/Helm/cert-manager and pulls container images.
      Give the machine outbound access (or set http_proxy/https_proxy),
      then re-run. (SKIP_NET_CHECK=1 to force through.)"
  fi
}

install_nvidia_toolkit() {
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -y && apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker && systemctl restart docker
}

# --- Gather parameters -------------------------------------------------------
gather_inputs() {
  log "Configuration"
  ask DOMAIN       "Local domain" "$DOMAIN"
  ask ADMIN_EMAIL  "Admin email"  "admin@$DOMAIN"
  echo
  info "HuggingFace token (optional) — needed for 'gated' models."
  ask_secret HF_TOKEN "  HF token (leave empty if not required)"
  echo
  ask LLM_MODEL   "Generative model (HF id)" "$LLM_MODEL"
  ask EMBED_MODEL "Embeddings model (HF id)" "$EMBED_MODEL"
  ask VLLM_IMAGE  "vLLM image (arm64/Blackwell)" "$VLLM_IMAGE"

  VLLM_API_KEY="${VLLM_API_KEY:-sk-$(head -c24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c32)}"
  # Bash `set -e` + `[[ test ]] && cmd` as the last statement of a function
  # propagates the exit code of `[[ test ]]`: if false, the function returns 1
  # and the script dies silently. We use `if/fi` (plus a final `:`).
  if [[ "$VLLM_IMAGE" == "vllm/vllm-openai:latest" ]]; then
    warn "vllm/vllm-openai:latest is NOT validated arm64/Blackwell. Prefer vllm/vllm-openai:cu130-nightly (default)."
  fi
  :
}

# --- 1. k3s ------------------------------------------------------------------
install_k3s() {
  log "k3s (single-node)"
  if have k3s; then info "k3s already installed."; else
    info "Downloading + installing k3s (get.k3s.io)…"
    # k3s default kubeconfig mode is 0600 (root-only) — we keep that to avoid
    # giving cluster-admin to any local user (the kubeconfig contains client
    # certs that bypass RBAC). Diagnostics on the host go via `sudo k3s
    # kubectl ...` (k3s embeds kubectl + reads /etc/rancher/k3s/k3s.yaml as
    # root automatically).
    curl -sfL https://get.k3s.io | sh - \
      || die "k3s install failed (network? see above)."
    info "k3s installed."
  fi
  export KUBECONFIG="$KUBECONFIG_PATH"
  log "Waiting for k3s API + node Ready"
  local i
  for i in $(seq 1 60); do          # the node isn't registered immediately at start
    [[ -n "$(k3s kubectl get nodes -o name 2>/dev/null)" ]] && break
    sleep 5
  done
  k3s kubectl wait --for=condition=Ready node --all --timeout=300s \
    || die "k3s node did not become Ready (see: journalctl -u k3s)."
  info "Node Ready."

  if ! have helm; then
    log "Installing Helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
}
kc()   { k3s kubectl "$@"; }

# --- 2. vLLM stack (Docker host) --------------------------------------------
deploy_vllm() {
  log "vLLM ×2 + nginx proxy (Docker host, Blackwell GPU)"
  mkdir -p "$MODELS_DIR" "$DATA_DIR/llm"
  fetch "llm/docker-compose.yml"                > "$DATA_DIR/llm/docker-compose.yml"
  # The Gemma 4 chat template is volume-mounted in the compose. Without this
  # file next to it, --chat-template crashes at boot.
  fetch "llm/tool_chat_template_gemma4.jinja"   > "$DATA_DIR/llm/tool_chat_template_gemma4.jinja"
  # nginx proxy config (static URL-path routing, no templating needed).
  fetch "llm/nginx.conf"                        > "$DATA_DIR/llm/nginx.conf"
  umask 077
  cat > "$DATA_DIR/llm/.env" <<EOF
VLLM_IMAGE=$VLLM_IMAGE
PROXY_IMAGE=$PROXY_IMAGE
HF_TOKEN=${HF_TOKEN:-}
VLLM_API_KEY=$VLLM_API_KEY
MODELS_DIR=$MODELS_DIR
HOST_IP=$HOST_IP
LLM_MODEL=$LLM_MODEL
EMBED_MODEL=$EMBED_MODEL
LLM_PORT=$LLM_PORT
EMBED_PORT=$EMBED_PORT
PROXY_PORT=$PROXY_PORT
LLM_GPU_MEM_UTIL=$LLM_GPU_MEM_UTIL
EMBED_GPU_MEM_UTIL=$EMBED_GPU_MEM_UTIL
LLM_MAX_NUM_SEQS=$LLM_MAX_NUM_SEQS
LLM_MAX_MODEL_LEN=$LLM_MAX_MODEL_LEN
EMBED_MAX_MODEL_LEN=$EMBED_MAX_MODEL_LEN
EOF
  umask 022

  cat > /etc/systemd/system/suite366-vllm.service <<EOF
[Unit]
Description=Suite 366 — vLLM (generative + embeddings)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$DATA_DIR/llm
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now suite366-vllm.service
  info "Downloading + loading models (may take several minutes)…"
  if wait_http "http://$HOST_IP:$LLM_PORT/health" "vLLM generative"; then
    warmup_chat "http://$HOST_IP:$LLM_PORT" "$LLM_MODEL"
  else
    warn "vLLM generative not ready yet (see: docker logs suite366-vllm-llm)."
  fi
  if wait_http "http://$HOST_IP:$EMBED_PORT/health" "vLLM embeddings"; then
    warmup_embed "http://$HOST_IP:$EMBED_PORT" "$EMBED_MODEL"
  else
    warn "vLLM embeddings not ready yet (see: docker logs suite366-vllm-embed)."
  fi
  # The nginx proxy only becomes healthy once both vLLM backends are healthy
  # (depends_on: service_healthy). nginx itself starts in ~1s.
  if wait_http "http://$HOST_IP:$PROXY_PORT/health" "vLLM unified proxy"; then
    info "  unified proxy ready at http://$HOST_IP:$PROXY_PORT/v1"
  else
    warn "vLLM proxy not ready yet (see: docker logs suite366-vllm-proxy)."
  fi
}

# JIT warmup (Inductor/FlashInfer): without this, the first real request can
# take ~25s (cold codegen, cf. vLLM DGX Spark blog). We exercise the real path
# once so the first user doesn't pay this latency. Best-effort.
warmup_chat() { # warmup_chat BASE_URL MODEL
  local base="$1" model="$2"
  info "Warming up generative JIT (max_tokens=3)…"
  curl -fsS -m 120 "$base/v1/chat/completions" \
    -H "Authorization: Bearer $VLLM_API_KEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":3}" \
    >/dev/null 2>&1 && info "  generative warm." || warn "  generative warmup skipped (curl failed, non-blocking)."
}
warmup_embed() { # warmup_embed BASE_URL MODEL
  local base="$1" model="$2"
  info "Warming up embeddings JIT…"
  curl -fsS -m 120 "$base/v1/embeddings" \
    -H "Authorization: Bearer $VLLM_API_KEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"input\":\"ping\"}" \
    >/dev/null 2>&1 && info "  embeddings warm." || warn "  embeddings warmup skipped (curl failed, non-blocking)."
}

wait_http() { # wait_http URL LABEL  (timeout ~30 min: HF DL 15+ GiB + recovery)
  # 30 min covers: HuggingFace DL (5-10 min/model), Inductor compile +
  # cudagraph capture (3-6 min), and 1-2 restart cycles if the first attempt
  # fails (e.g. transient OOM on GB10's unified memory). Non-blocking: on
  # timeout we continue with just a `warn`.
  local url="$1" label="$2" i=0
  printf "    %s: waiting" "$label"
  while (( i < 360 )); do
    if curl -fsS -m 3 "$url" >/dev/null 2>&1; then printf " OK\n"; return 0; fi
    printf "."; sleep 5; ((i++))
  done
  printf " timeout\n"; return 1
}

# --- 3. cert-manager + local CA ---------------------------------------------
install_cert_manager() {
  log "cert-manager + local CA"
  if ! kc -n cert-manager get deploy cert-manager >/dev/null 2>&1; then
    helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
    helm repo update >/dev/null
    info "Deploying cert-manager $CERT_MANAGER_VERSION…"
    NAMESPACE=cert-manager run_progress "cert-manager" \
      helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --version "$CERT_MANAGER_VERSION" --set crds.enabled=true --wait \
      || die "cert-manager deployment failed."
  fi
  fetch "tls/local-ca-issuer.yaml" | kc apply -f -
  log "Waiting for CA ClusterIssuer"
  kc wait --for=condition=Ready clusterissuer/suite366-local-ca --timeout=120s || \
    warn "ClusterIssuer suite366-local-ca not ready yet."
  # Export the CA to distribute to client machines. The CA is a *public*
  # certificate by design, so it's safe to also publish a world-readable
  # copy under /usr/local/share/ — useful because $DATA_DIR is locked 0700
  # and the cert otherwise needs `sudo cat` to extract.
  if kc -n cert-manager get secret suite366-local-ca -o jsonpath='{.data.ca\.crt}' \
       | base64 -d > "$DATA_DIR/suite366-local-ca.crt" 2>/dev/null
  then
    chmod 0644 "$DATA_DIR/suite366-local-ca.crt"
    install -m 0644 "$DATA_DIR/suite366-local-ca.crt" /usr/local/share/suite366-local-ca.crt
  fi
}

# --- 4. Deploy Suite 366 (drive chart) --------------------------------------
deploy_suite() {
  log "Suite 366 (drive chart) -> ns/$NAMESPACE (+ sandbox/$SANDBOX_NAMESPACE)"

  # Pre-create both namespaces. The sandbox one needs the chart's PSS labels
  # before helm rolls out anything inside it, and we set
  # `sandbox.createNamespace: false` so helm doesn't fight us over ownership.
  kc create namespace "$NAMESPACE" --dry-run=client -o yaml | kc apply -f -
  kc create namespace "$SANDBOX_NAMESPACE" --dry-run=client -o yaml | kc apply -f -
  kc label ns "$SANDBOX_NAMESPACE" \
    app=sandbox \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/warn=restricted \
    --overwrite >/dev/null

  local vals="$DATA_DIR/values.yaml"
  # values.yaml carries `secrets.VLLM_API_KEY` in clear and feeds it
  # to Helm — write it under a restrictive umask so the rendered file lands
  # at 0600 (root-only), and follow with an explicit chmod as belt-and-braces
  # in case umask was inherited from elsewhere.
  ( umask 077
    fetch "values.yaml" \
      | sed -e "s|@DOMAIN@|$DOMAIN|g" \
            -e "s|@HOST_IP@|$HOST_IP|g" \
            -e "s|@PROXY_PORT@|$PROXY_PORT|g" \
            -e "s|@LLM_MODEL@|$LLM_MODEL|g" \
            -e "s|@EMBED_MODEL@|$EMBED_MODEL|g" \
            -e "s|@VLLM_API_KEY@|$VLLM_API_KEY|g" \
            -e "s|@VLLM_EMBEDDING_DIMENSIONS@|$VLLM_EMBEDDING_DIMENSIONS|g" \
            -e "s|@SANDBOX_NAMESPACE@|$SANDBOX_NAMESPACE|g" \
        > "$vals" )
  chmod 0600 "$vals"

  patch_coredns_for_local_domain
  info "helm install $RELEASE (pulling chart + images, several minutes)…"
  KUBECONFIG="$KUBECONFIG_PATH" run_progress "Suite 366 deployment" \
    helm upgrade --install "$RELEASE" "$CHART_REF" \
      --version "$CHART_VERSION" --namespace "$NAMESPACE" -f "$vals" --wait --timeout 15m
}

# Workaround pour les fetches server-to-server entre drive-app et OnlyOffice :
# le drive-app utilise aujourd'hui ONLYOFFICE_URL (https://office.$DOMAIN, en
# mDNS) pour les callbacks de forcesave, mais les pods k3s n'ont pas de
# résolveur mDNS — getaddrinfo() renvoie ENOTFOUND et la sauvegarde du doc
# plante avec "Failed to save document".
#
# On injecte donc les 5 noms *.$DOMAIN dans le ConfigMap NodeHosts de CoreDNS
# pour qu'ils résolvent vers le ClusterIP de Traefik. Le trafic reste
# in-cluster, traefik termine le TLS et route vers le bon service.
#
# ⚠️ TEMPORAIRE : à supprimer dès que suite-366 utilise ONLYOFFICE_INTERNAL_URL
# (déjà fourni par le chart) pour ses fetches server-side au lieu de
# ONLYOFFICE_URL. Cf. /etc/cm/coredns dans le cluster pour l'état courant.
patch_coredns_for_local_domain() {
  log "CoreDNS : *.$DOMAIN -> Traefik ClusterIP (in-cluster resolution)"
  local traefik_ip
  traefik_ip="$(kc -n kube-system get svc traefik -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  [[ -n "$traefik_ip" ]] || { warn "Traefik ClusterIP introuvable — skip CoreDNS patch."; return 0; }
  info "Traefik ClusterIP : $traefik_ip"
  local nh corefile
  nh="$(kc -n kube-system get cm coredns -o jsonpath='{.data.NodeHosts}')"
  corefile="$(kc -n kube-system get cm coredns -o jsonpath='{.data.Corefile}')"
  if grep -q "${traefik_ip}.*drive\.${DOMAIN}" <<<"$nh"; then
    info "Entrées *.$DOMAIN déjà présentes — skip."
    return 0
  fi
  # Append les 5 noms à NodeHosts puis re-créé le CM (kubectl create … --dry-run | apply)
  local new_nh
  new_nh="$(printf '%s\n%s drive.%s\n%s office.%s\n%s livekit.%s\n%s turn.%s\n%s %s\n' \
    "$nh" \
    "$traefik_ip" "$DOMAIN" \
    "$traefik_ip" "$DOMAIN" \
    "$traefik_ip" "$DOMAIN" \
    "$traefik_ip" "$DOMAIN" \
    "$traefik_ip" "$DOMAIN")"
  printf '%s' "$new_nh" > /tmp/_corefile_nodehosts
  kc -n kube-system create cm coredns \
    --from-file=NodeHosts=/tmp/_corefile_nodehosts \
    --from-literal=Corefile="$corefile" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  rm -f /tmp/_corefile_nodehosts
  kc -n kube-system rollout restart deploy/coredns >/dev/null
  kc -n kube-system rollout status deploy/coredns --timeout=60s >/dev/null || \
    warn "CoreDNS rollout incomplete — DNS may take ~30s to settle."
  info "CoreDNS NodeHosts updated."
}

# --- 5. mDNS (Avahi) ---------------------------------------------------------
setup_mdns() {
  log "mDNS (Avahi) — *.$DOMAIN"
  if ! have avahi-daemon; then
    apt-get update -y || warn "apt-get update failed (stale cache?) — install may fail."
    apt-get install -y avahi-daemon avahi-utils \
      || die "avahi install failed (network/apt?)."
  fi
  systemctl enable --now avahi-daemon

  cat > /usr/local/bin/suite366-avahi-aliases.sh <<EOF
#!/usr/bin/env bash
# Generated by install.sh — publishes Suite 366 mDNS names.
set -eu
IP="$HOST_IP"
for fqdn in $DOMAIN drive.$DOMAIN office.$DOMAIN livekit.$DOMAIN turn.$DOMAIN; do
  avahi-publish -a -R "\$fqdn" "\$IP" &
done
wait
EOF
  chmod +x /usr/local/bin/suite366-avahi-aliases.sh
  fetch "dns/avahi-aliases.service" > /etc/systemd/system/suite366-avahi-aliases.service
  systemctl daemon-reload
  systemctl enable --now suite366-avahi-aliases.service
}

# --- 6. Summary --------------------------------------------------------------
summary() {
  local ai
  if [[ "$SKIP_VLLM" == "1" ]]; then
    ai=" Local AI (vLLM): NOT deployed (test mode)."
  else
    ai=$(cat <<AI
 Local AI (wired AUTOMATICALLY into Suite 366 via PR #325 env contract):
   • Unified endpoint (nginx)    : http://$HOST_IP:$PROXY_PORT/v1
       /v1/embeddings -> vllm-embed ; everything else -> vllm-llm.
   • Direct vLLM endpoints (debug):
       - Generative : http://$HOST_IP:$LLM_PORT/v1   (model: $LLM_MODEL)
       - Embeddings : http://$HOST_IP:$EMBED_PORT/v1 (model: $EMBED_MODEL)
   • API key (shared by vLLM + Suite 366): $VLLM_API_KEY
   -> The chart receives VLLM_BASE_URL + VLLM_MODEL_* + VLLM_API_KEY via
      values.yaml; chooseDefaultModel() picks vLLM by default.
   -> Org admins can still register additional "CUSTOM" providers for
      per-org overrides; the system defaults stay on local vLLM.
AI
)
  fi
  cat <<EOF

$(printf "${c_g}========================================================================${c_0}")
$(printf "${c_b} Suite 366 installed on the DGX Spark${c_0}")
$(printf "${c_g}========================================================================${c_0}")

 Application :   https://drive.$DOMAIN
 OnlyOffice  :   https://office.$DOMAIN
 LiveKit     :   wss://livekit.$DOMAIN

$ai

 TLS trust: install the CA on each client machine
   /usr/local/share/suite366-local-ca.crt   (world-readable, ready to scp)
   $DATA_DIR/suite366-local-ca.crt          (same file, root-only)

 DNS: *.{$DOMAIN} is published via mDNS. LAN machines with mDNS support
      (macOS, Windows 10+, Linux+nss-mdns) resolve it without config.

 systemd services: suite366-vllm, suite366-avahi-aliases, k3s
 Diagnostics     : sudo k3s kubectl -n $NAMESPACE get pods
 Security        : $DATA_DIR is 0700 (root-only); the kubeconfig at
                   $KUBECONFIG_PATH is 0600 — use sudo to inspect.

$(printf "${c_g}========================================================================${c_0}")
EOF
}

main() {
  preflight
  gather_inputs
  install_k3s
  if [[ "$SKIP_VLLM" == "1" ]]; then warn "vLLM stack not deployed (SKIP_VLLM)."; else deploy_vllm; fi
  install_cert_manager
  deploy_suite
  setup_mdns
  summary
}
main "$@"
