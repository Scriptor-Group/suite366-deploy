# shellcheck shell=bash
# =============================================================================
# lib/preflight.sh — environment checks, NVIDIA toolkit setup, and interactive
# parameter gathering. Runs before anything is deployed.
# =============================================================================

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
