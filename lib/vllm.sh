# shellcheck shell=bash
# =============================================================================
# lib/vllm.sh — vLLM ×2 (generative + embeddings) + nginx unifying proxy on the
# Docker host, wired to the Blackwell GPU and managed by a systemd unit.
# =============================================================================

# --- 2. vLLM stack (Docker host) --------------------------------------------
deploy_vllm() {
  log "vLLM ×2 + nginx proxy (Docker host, Blackwell GPU)"
  # $CACHE_DIR holds the JIT state the compose mounts into both vLLM containers
  # (torch.compile artifacts, FlashInfer autotune + JIT cubins, Triton
  # kernels). It is what turns a 257 s restart into a 96 s one; safe to wipe.
  mkdir -p "$MODELS_DIR" "$DATA_DIR/llm" "$CACHE_DIR/vllm" "$CACHE_DIR/flashinfer" "$CACHE_DIR/triton"
  fetch "llm/docker-compose.yml"                > "$DATA_DIR/llm/docker-compose.yml"
  # nginx proxy config (static URL-path routing, no templating needed).
  fetch "llm/nginx.conf"                        > "$DATA_DIR/llm/nginx.conf"
  local env_file="$DATA_DIR/llm/.env" env_old=""
  [[ -f "$env_file" ]] && env_old="$(cat "$env_file")"
  local env_new
  env_new="$(cat <<EOF
VLLM_IMAGE=$VLLM_IMAGE
PROXY_IMAGE=$PROXY_IMAGE
HF_TOKEN=${HF_TOKEN:-}
VLLM_API_KEY=$VLLM_API_KEY
MODELS_DIR=$MODELS_DIR
CACHE_DIR=$CACHE_DIR
BIND_IP=$SUITE_IP
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
)"
  ( umask 077; printf '%s\n' "$env_new" > "$env_file" )

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
# /dev/nvidia-uvm's major is allocated dynamically at each boot while
# /etc/cdi/nvidia.yaml pins it, so refresh the spec before the containers are
# created: devices are injected at creation, and a boot that shifted the major
# otherwise hands them a node on the wrong char device — nvidia-smi still works
# inside the container, torch.cuda.init() does not, and vLLM crash-loops.
# This lives here rather than in NVIDIA's nvidia-cdi-refresh.service because of
# ordering: that unit is After=multi-user.target, so it runs after this stack —
# and on a box where plymouth-quit-wait hangs (DGX OS, `quiet splash`), the
# target is never reached and it never runs at all.
# Best-effort (leading -): never hold the stack down when the spec is fine.
ExecStartPre=-/usr/bin/nvidia-ctk cdi generate --output=$CDI_SPEC
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable suite366-vllm.service >/dev/null 2>&1 || true
  # The unit is oneshot + RemainAfterExit: once active, `start` is a no-op, so a
  # re-run that changed .env (e.g. a new VLLM_API_KEY) would leave the running
  # containers on the stale config. Recreate them only when the config actually
  # changed; otherwise leave the stack up (avoids a needless multi-minute model
  # reload on an unchanged re-run).
  if ! systemctl is-active --quiet suite366-vllm.service; then
    systemctl start suite366-vllm.service
  elif [[ "$env_new" != "$env_old" ]]; then
    info "vLLM config changed — restarting the stack to apply it (models reload)."
    systemctl restart suite366-vllm.service
  else
    info "vLLM config unchanged — leaving the running stack in place."
  fi
  info "Downloading + loading models (may take several minutes)…"
  # Health-check on the stable internal IP: local, always reachable, offline-safe.
  if wait_http "http://$SUITE_IP:$LLM_PORT/health" "vLLM generative"; then
    warmup_chat "http://$SUITE_IP:$LLM_PORT" "$LLM_MODEL"
  else
    warn "vLLM generative not ready yet (see: docker logs suite366-vllm-llm)."
  fi
  if wait_http "http://$SUITE_IP:$EMBED_PORT/health" "vLLM embeddings"; then
    warmup_embed "http://$SUITE_IP:$EMBED_PORT" "$EMBED_MODEL"
  else
    warn "vLLM embeddings not ready yet (see: docker logs suite366-vllm-embed)."
  fi
  # The nginx proxy only becomes healthy once both vLLM backends are healthy
  # (depends_on: service_healthy). nginx itself starts in ~1s.
  if wait_http "http://$SUITE_IP:$PROXY_PORT/health" "vLLM unified proxy"; then
    info "  unified proxy ready at http://$SUITE_IP:$PROXY_PORT/v1"
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
