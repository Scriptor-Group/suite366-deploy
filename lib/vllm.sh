# shellcheck shell=bash
# =============================================================================
# lib/vllm.sh — vLLM ×2 (generative + embeddings) + nginx unifying proxy on the
# Docker host, wired to the Blackwell GPU and managed by a systemd unit.
# =============================================================================

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
