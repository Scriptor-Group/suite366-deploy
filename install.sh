#!/usr/bin/env bash
# =============================================================================
# Suite 366 — all-in-one installer for single-node k3s
#
#   curl -fsSL https://raw.githubusercontent.com/Scriptor-Group/suite366-deploy/main/install.sh | sudo bash
#
# Deploys:
#   • single-node k3s (Traefik ingress + local-path storage + CoreDNS);
#   • the full Suite 366 (drive-app + Postgres/pgvector + Redis + MinIO +
#     OnlyOffice + LiveKit/TURN), in-cluster, via the public Helm chart `drive`;
#   • TLS via a self-signed local CA (cert-manager) + mDNS *.suite366.local (Avahi);
#   • OPTIONAL on-host AI: vLLM ×2 (chat + embeddings) on the GPU — auto-enabled
#     when an NVIDIA GPU is detected (see WITH_GPU below).
#
# Idempotent. Interactive prompts via /dev/tty (works with curl|bash) OR via
# environment variables (non-interactive):
#   DOMAIN                     default: suite366.local
#   ADMIN_EMAIL                default: admin@<DOMAIN>
#   WITH_GPU                   auto|1|0  (default auto: deploy vLLM iff a GPU is found)
#   HF_TOKEN                   HuggingFace token (optional, gated models)
#   LLM_MODEL, EMBED_MODEL     HuggingFace models to serve (GPU path)
#   VLLM_IMAGE                 vLLM image (GPU path — must match your GPU arch, see README)
#   LLM_GPU_MEM_UTIL,          fractions of the (unified) memory pool per vLLM
#   EMBED_GPU_MEM_UTIL         (sum < 1.0 ; defaults 0.55 / 0.20)
#   LLM_MAX_NUM_SEQS,          small-batch generative tuning (defaults 4 / 131072)
#   LLM_MAX_MODEL_LEN
#   CHART_REF, CHART_VERSION   public OCI Helm chart (defaults below)
#   ASSUME_YES=1               accept defaults, no prompts
# =============================================================================
set -euo pipefail

# --- Defaults ----------------------------------------------------------------
DOMAIN="${DOMAIN:-suite366.local}"
CHART_REF="${CHART_REF:-oci://ghcr.io/scriptor-group/charts/drive}"
CHART_VERSION="${CHART_VERSION:-0.5.0}"
NAMESPACE="${NAMESPACE:-suite366}"
RELEASE="${RELEASE:-drive}"

# --- On-host AI (vLLM) — optional, GPU-dependent -----------------------------
# WITH_GPU: auto (deploy vLLM iff an NVIDIA GPU is present), 1 (force, fail if
# none), 0 (never — wire an external/OpenAI provider in the app instead).
WITH_GPU="${WITH_GPU:-auto}"
LLM_MODEL="${LLM_MODEL:-nvidia/Gemma-4-31B-IT-NVFP4}"
EMBED_MODEL="${EMBED_MODEL:-Qwen/Qwen3-VL-Embedding-8B}"
# vLLM image MUST match your GPU. Default = NVIDIA NGC build for the DGX Spark
# (arm64 / Blackwell GB10 / sm_121), PINNED for reproducibility. On a discrete
# x86 GPU set VLLM_IMAGE=vllm/vllm-openai:latest (or a pinned tag).
# Catalog: https://catalog.ngc.nvidia.com/orgs/nvidia/containers/vllm
VLLM_IMAGE="${VLLM_IMAGE:-nvcr.io/nvidia/vllm:25.11-py3}"
LLM_PORT="${LLM_PORT:-8001}"
EMBED_PORT="${EMBED_PORT:-8002}"

# Memory budget inside a shared/unified pool. The 2 vLLM instances share it with
# the OS, runtime and KV cache: bound each (sum < 1.0, margin left). Generative
# has priority; embeddings take a smaller share. Small batch on the generative.
LLM_GPU_MEM_UTIL="${LLM_GPU_MEM_UTIL:-0.55}"
EMBED_GPU_MEM_UTIL="${EMBED_GPU_MEM_UTIL:-0.20}"
LLM_MAX_NUM_SEQS="${LLM_MAX_NUM_SEQS:-4}"
LLM_MAX_MODEL_LEN="${LLM_MAX_MODEL_LEN:-131072}"

DATA_DIR="${DATA_DIR:-/opt/suite366}"
MODELS_DIR="${MODELS_DIR:-$DATA_DIR/models}"
ASSUME_YES="${ASSUME_YES:-0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"
DEPLOY_VLLM=0   # decided in preflight from WITH_GPU + GPU detection

# Companion files: read next to the script when run locally, else fetched from
# BASE_URL (curl|bash mode).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || echo "")"
BASE_URL="${BASE_URL:-https://raw.githubusercontent.com/Scriptor-Group/suite366-deploy/main}"

KUBECONFIG_PATH=/etc/rancher/k3s/k3s.yaml

# --- Output ------------------------------------------------------------------
c_b="\033[1m"; c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_0="\033[0m"
START_TS="$(date +%s)"
_elapsed() { local s=$(( $(date +%s) - START_TS )); printf '%d:%02d' $((s/60)) $((s%60)); }
log()  { printf "${c_g}==>${c_0} ${c_b}[%s] %s${c_0}\n" "$(_elapsed)" "$*"; }
info() { printf "    [%s] %s\n" "$(_elapsed)" "$*"; }
warn() { printf "${c_y}!!  [%s] %s${c_0}\n" "$(_elapsed)" "$*"; }
die()  { printf "${c_r}xx  [%s] %s${c_0}\n" "$(_elapsed)" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
tty_usable() { (exec </dev/tty) >/dev/null 2>&1; }

# Run a long command in the background, printing namespace pod state every ~15s
# so `helm --wait` doesn't look frozen.
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

# Interactive read from the terminal (stdin is a pipe under curl|bash).
ask() { # ask VAR "prompt" "default"
  local __var="$1" __prompt="$2" __def="${3:-}" __ans=""
  if [[ -n "${!__var:-}" ]]; then return 0; fi
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

fetch() { # fetch RELATIVE_PATH -> stdout (local file if present, else BASE_URL)
  local rel="$1"
  if [[ -n "$SCRIPT_DIR" && -f "$SCRIPT_DIR/$rel" ]]; then cat "$SCRIPT_DIR/$rel"
  else curl -fsSL "$BASE_URL/$rel"; fi
}

# --- 0. Preflight ------------------------------------------------------------
preflight() {
  log "Preflight"
  [[ "$(id -u)" == "0" ]] || die "Run as root (sudo)."
  mkdir -p "$DATA_DIR"
  have curl || die "curl is required."

  if [[ "$(uname -m)" != "aarch64" && "$(uname -m)" != "x86_64" ]]; then
    warn "Architecture $(uname -m) is untested — continuing."
  fi

  # --- GPU detection -> decide whether to deploy vLLM ------------------------
  case "$WITH_GPU" in
    0) info "AI (vLLM): disabled (WITH_GPU=0). Configure an external provider in-app." ;;
    1)
      have nvidia-smi && nvidia-smi -L >/dev/null 2>&1 \
        || die "WITH_GPU=1 but no usable NVIDIA GPU (nvidia-smi). Use WITH_GPU=0 or auto."
      DEPLOY_VLLM=1 ;;
    auto)
      if have nvidia-smi && nvidia-smi -L >/dev/null 2>&1; then DEPLOY_VLLM=1
      else warn "No NVIDIA GPU detected — vLLM skipped. Set OPENAI_API_KEY / a CUSTOM provider in-app."; fi ;;
    *) die "WITH_GPU must be auto, 1 or 0 (got '$WITH_GPU')." ;;
  esac

  if [[ "$DEPLOY_VLLM" == "1" ]]; then
    info "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
    have docker || die "Docker is required for the vLLM GPU path."
    if ! docker info 2>/dev/null | grep -qiE 'Runtimes:.*nvidia' && ! have nvidia-ctk; then
      warn "Docker 'nvidia' runtime not detected — installing nvidia-container-toolkit."
      install_nvidia_toolkit
    fi
    [[ "$(uname -m)" == "aarch64" || "$VLLM_IMAGE" != "nvcr.io/nvidia/vllm:25.11-py3" ]] \
      || warn "Default VLLM_IMAGE is the arm64/Blackwell NGC build; on this x86 host set VLLM_IMAGE to an x86 vLLM image (see README)."
  fi

  HOST_IP="${HOST_IP:-$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')}"
  [[ -n "${HOST_IP:-}" ]] || die "Could not determine the LAN IP — export HOST_IP=<ip>."
  info "LAN IP: $HOST_IP"

  local avail_g; avail_g=$(df -BG --output=avail "$(dirname "$DATA_DIR")" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
  local need=80; [[ "$DEPLOY_VLLM" == "1" ]] && need=200
  [[ "${avail_g:-0}" -ge "$need" ]] || warn "Disk ~${avail_g}G (<${need}G advised: images + PVCs${DEPLOY_VLLM:+ + models})."

  check_connectivity
}

# Fail LOUDLY if a required endpoint is unreachable (otherwise pulls die
# silently under set -o pipefail).
check_connectivity() {
  [[ "${SKIP_NET_CHECK:-0}" == "1" ]] && { warn "Connectivity check skipped (SKIP_NET_CHECK)."; return 0; }
  info "Checking outbound connectivity…"
  local endpoints=(
    "https://get.k3s.io"
    "https://get.helm.sh"
    "https://ghcr.io/v2/"
    "https://registry-1.docker.io/v2/"
    "https://charts.jetstack.io"
  )
  [[ "$DEPLOY_VLLM" == "1" ]] && endpoints+=("https://nvcr.io/v2/")
  local u code fails=()
  for u in "${endpoints[@]}"; do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$u" 2>/dev/null || true)"
    if [[ -z "$code" || "$code" == "000" ]]; then fails+=("$u"); info "  ✗ $u (unreachable)"
    else info "  ✓ $u (HTTP $code)"; fi
  done
  if (( ${#fails[@]} )); then
    die "No outbound access to: ${fails[*]}
      The installer downloads k3s/Helm/cert-manager and pulls container images.
      Give the machine outbound access (or an http_proxy/https_proxy) and retry.
      (SKIP_NET_CHECK=1 to force anyway.)"
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

# --- Gather inputs -----------------------------------------------------------
gather_inputs() {
  log "Configuration"
  ask DOMAIN       "Local domain" "$DOMAIN"
  ask ADMIN_EMAIL  "Admin email"  "admin@$DOMAIN"
  if [[ "$DEPLOY_VLLM" == "1" ]]; then
    echo
    info "HuggingFace token (optional) — needed for 'gated' models."
    ask_secret HF_TOKEN "  HF token (leave empty if not required)"
    echo
    ask LLM_MODEL   "Generative model (HF id)" "$LLM_MODEL"
    ask EMBED_MODEL "Embeddings model (HF id)" "$EMBED_MODEL"
    ask VLLM_IMAGE  "vLLM image (match your GPU)" "$VLLM_IMAGE"
    VLLM_API_KEY="${VLLM_API_KEY:-sk-$(head -c24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c32)}"
  fi
}

# --- 1. k3s ------------------------------------------------------------------
install_k3s() {
  log "k3s (single-node)"
  if have k3s; then info "k3s already installed."; else
    info "Downloading + installing k3s (get.k3s.io)…"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh - \
      || die "k3s install failed (network? see above)."
    info "k3s installed."
  fi
  export KUBECONFIG="$KUBECONFIG_PATH"
  log "Waiting for the k3s API + node Ready"
  local i
  for i in $(seq 1 60); do
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

# --- 2. vLLM stack (host Docker) — optional ---------------------------------
deploy_vllm() {
  log "vLLM ×2 (host Docker, GPU)"
  mkdir -p "$MODELS_DIR" "$DATA_DIR/llm"
  fetch "llm/docker-compose.yml" > "$DATA_DIR/llm/docker-compose.yml"
  umask 077
  cat > "$DATA_DIR/llm/.env" <<EOF
VLLM_IMAGE=$VLLM_IMAGE
HF_TOKEN=${HF_TOKEN:-}
VLLM_API_KEY=$VLLM_API_KEY
MODELS_DIR=$MODELS_DIR
HOST_IP=$HOST_IP
LLM_MODEL=$LLM_MODEL
EMBED_MODEL=$EMBED_MODEL
LLM_PORT=$LLM_PORT
EMBED_PORT=$EMBED_PORT
LLM_GPU_MEM_UTIL=$LLM_GPU_MEM_UTIL
EMBED_GPU_MEM_UTIL=$EMBED_GPU_MEM_UTIL
LLM_MAX_NUM_SEQS=$LLM_MAX_NUM_SEQS
LLM_MAX_MODEL_LEN=$LLM_MAX_MODEL_LEN
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
}

# Warm the JIT (Inductor/FlashInfer): without this the first real request can
# take ~25s (cold codegen, cf. vLLM Spark blog). Best-effort.
warmup_chat() { # warmup_chat BASE_URL MODEL
  local base="$1" model="$2"
  info "JIT warmup of the generative model (max_tokens=3)…"
  curl -fsS -m 120 "$base/v1/chat/completions" \
    -H "Authorization: Bearer $VLLM_API_KEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":3}" \
    >/dev/null 2>&1 && info "  generative warm." || warn "  generative warmup skipped (curl failed, non-blocking)."
}
warmup_embed() { # warmup_embed BASE_URL MODEL
  local base="$1" model="$2"
  info "JIT warmup of the embeddings model…"
  curl -fsS -m 120 "$base/v1/embeddings" \
    -H "Authorization: Bearer $VLLM_API_KEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"input\":\"ping\"}" \
    >/dev/null 2>&1 && info "  embeddings warm." || warn "  embeddings warmup skipped (curl failed, non-blocking)."
}

wait_http() { # wait_http URL LABEL  (timeout ~20 min, models slow to load)
  local url="$1" label="$2" i=0
  printf "    %s: waiting" "$label"
  while (( i < 240 )); do
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
  log "Waiting for the CA ClusterIssuer"
  kc wait --for=condition=Ready clusterissuer/suite366-local-ca --timeout=120s || \
    warn "ClusterIssuer suite366-local-ca not ready yet."
  kc -n cert-manager get secret suite366-local-ca -o jsonpath='{.data.ca\.crt}' \
    | base64 -d > "$DATA_DIR/suite366-local-ca.crt" 2>/dev/null || true
}

# --- 4. Deploy Suite 366 (chart drive) --------------------------------------
deploy_suite() {
  log "Suite 366 (chart drive) -> ns/$NAMESPACE"
  kc create namespace "$NAMESPACE" --dry-run=client -o yaml | kc apply -f -

  local vals="$DATA_DIR/values.yaml"
  fetch "values.yaml" | sed "s/@DOMAIN@/$DOMAIN/g; s/@HOST_IP@/$HOST_IP/g" > "$vals"

  info "helm install $RELEASE (pulling the chart + images, several minutes)…"
  KUBECONFIG="$KUBECONFIG_PATH" run_progress "Suite 366 deployment" \
    helm upgrade --install "$RELEASE" "$CHART_REF" \
      --version "$CHART_VERSION" --namespace "$NAMESPACE" -f "$vals" --wait --timeout 15m
}

# --- 5. mDNS DNS (Avahi) -----------------------------------------------------
setup_mdns() {
  log "mDNS DNS (Avahi) — *.$DOMAIN"
  if ! have avahi-daemon; then
    apt-get update -y || warn "apt-get update failed (stale cache?) — install may fail."
    apt-get install -y avahi-daemon avahi-utils \
      || die "avahi install failed (network/apt?)."
  fi
  systemctl enable --now avahi-daemon

  cat > /usr/local/bin/suite366-avahi-aliases.sh <<EOF
#!/usr/bin/env bash
# Generated by install.sh — publishes the Suite 366 mDNS names.
set -eu
IP="$HOST_IP"
for fqdn in $DOMAIN drive.$DOMAIN office.$DOMAIN livekit.$DOMAIN turn.$DOMAIN; do
  avahi-publish -a -R "\$fqdn" "\$IP" &
done
wait
EOF
  chmod +x /usr/local/bin/suite366-avahi-aliases.sh
  fetch "dns/avahi-aliases.service" | sed "s/<DOMAIN>/$DOMAIN/g" > /etc/systemd/system/suite366-avahi-aliases.service
  systemctl daemon-reload
  systemctl enable --now suite366-avahi-aliases.service
}

# --- 6. Summary --------------------------------------------------------------
summary() {
  local ai vllm_svc=""
  [[ "$DEPLOY_VLLM" == "1" ]] && vllm_svc=", suite366-vllm"
  if [[ "$DEPLOY_VLLM" == "1" ]]; then
    ai=$(cat <<AI
 Local AI (vLLM, wire manually in the Suite 366 admin):
   • Generative : http://$HOST_IP:$LLM_PORT/v1   (model: $LLM_MODEL)
   • Embeddings : http://$HOST_IP:$EMBED_PORT/v1  (model: $EMBED_MODEL)
   • vLLM API key : $VLLM_API_KEY
   -> Use the host IP (k3s pods do not resolve the .local mDNS name).
   -> Create 2 "CUSTOM" providers (OpenAI-compatible) in Settings > AI.
      Details: docs/gpu-inference.md.
AI
)
  else
    ai=" Local AI (vLLM): NOT deployed (no GPU / WITH_GPU=0). Set OPENAI_API_KEY
   or a CUSTOM provider in the Suite 366 admin to enable AI features."
  fi
  cat <<EOF

$(printf "${c_g}========================================================================${c_0}")
$(printf "${c_b} Suite 366 installed${c_0}")
$(printf "${c_g}========================================================================${c_0}")

 Application :   https://drive.$DOMAIN
 OnlyOffice  :   https://office.$DOMAIN
 LiveKit     :   wss://livekit.$DOMAIN

$ai

 TLS trust : import the CA on each client machine
   $DATA_DIR/suite366-local-ca.crt

 DNS : *.{$DOMAIN} is published over mDNS. LAN machines with mDNS
       (macOS, Windows 10+, Linux+nss-mdns) resolve it with no config.

 systemd services : k3s${vllm_svc}, suite366-avahi-aliases
 Diagnostics      : KUBECONFIG=$KUBECONFIG_PATH k3s kubectl -n $NAMESPACE get pods

$(printf "${c_g}========================================================================${c_0}")
EOF
}

main() {
  preflight
  gather_inputs
  install_k3s
  [[ "$DEPLOY_VLLM" == "1" ]] && deploy_vllm || warn "vLLM stack not deployed (no GPU / WITH_GPU=0)."
  install_cert_manager
  deploy_suite
  setup_mdns
  summary
}
main "$@"
