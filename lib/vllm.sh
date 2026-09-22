# shellcheck shell=bash
# =============================================================================
# lib/vllm.sh — vLLM ×2 (generative + embeddings), ×3 with transcription, +
# nginx unifying proxy on the Docker host, wired to the Blackwell GPU and
# managed by a systemd unit.
# =============================================================================

# --- Flash-Next: the patched vLLM image, built on the box ---------------------
# Qwen3.8-Flash-Next only fits on one Spark with its 47.7 GiB n-gram table served
# from the NVMe by mmap — a vLLM patch set (llm/flash-next/, vendored from
# blazux/qwen3.8-Flash-DGX) laid over the official v0.29.0 image. No registry
# holds that image: it is built here, once per (base image, patch commit) tag.
#
# The patch SOURCES are laid down whatever the active profile, and the image is
# built only for the profile that needs it: switching to Flash-Next later must
# not require reaching the deploy repo again, on a box that may have no route
# to it.
FLASH_NEXT_FILES=(Dockerfile UPSTREAM_COMMIT serve-flash-next.sh
  src/vllm_ple_mmap.py src/patch_mamba_block_size.py src/patch_qsa_exact_topk.py
  src/vllm_fp8_hybrid_modelopt.py src/patch_mtp_draft_vocab.py src/draft_vocab_65536.npy
  src/patch_block_fp8_mtp.py src/patches/qwen-tool-preamble.patch)

fetch_flash_next_files() {
  local ctx="$DATA_DIR/llm/flash-next" f
  mkdir -p "$ctx/src/patches"
  for f in "${FLASH_NEXT_FILES[@]}"; do fetch "llm/flash-next/$f" > "$ctx/$f"; done
  chmod 755 "$ctx/serve-flash-next.sh"
}

build_flash_next_image() { # build_flash_next_image TAG
  local tag="$1" ctx="$DATA_DIR/llm/flash-next"
  if docker image inspect "$tag" >/dev/null 2>&1; then
    info "vLLM image $tag already built."
    return 0
  fi
  log "Building $tag ($VLLM_IMAGE + the Flash-Next patch set, ~3 min)"
  docker pull -q "$VLLM_IMAGE" >/dev/null
  # stdout (the image id) is noise; stderr is where a failing step explains itself.
  docker build -q -t "$tag" "$ctx" >/dev/null \
    || die "docker build of $tag failed — see llm/flash-next/README.md"
}

# --- Transcription: the audio extras, built over the base image ---------------
# vllm/vllm-openai (arm64) decodes no audio at all without soundfile and PyAV
# (llm/stt/Dockerfile has the evidence). One thin layer, built here at install
# for the profiles that serve a transcription model, and by switch-model.sh
# when a later switch turns it on. The Dockerfile is laid down whatever the
# profile, for the same reason as the Flash-Next sources.
fetch_stt_files() {
  mkdir -p "$DATA_DIR/llm/stt"
  fetch "llm/stt/Dockerfile" > "$DATA_DIR/llm/stt/Dockerfile"
}

build_stt_image() { # build_stt_image TAG
  local tag="$1" ctx="$DATA_DIR/llm/stt"
  if docker image inspect "$tag" >/dev/null 2>&1; then
    info "vLLM transcription image $tag already built."
    return 0
  fi
  log "Building $tag ($VLLM_IMAGE + the audio extras, ~1 min)"
  docker pull -q "$VLLM_IMAGE" >/dev/null
  docker build -q --build-arg "BASE_IMAGE=$VLLM_IMAGE" -t "$tag" "$ctx" >/dev/null \
    || die "docker build of $tag failed — see llm/stt/Dockerfile"
}

# Only Flash-Next asks for this: with it up the box has no memory headroom
# (117/121 GiB used) and 7-10 GiB of swap in use, and at the default swappiness
# of 60 pages were read back from swap during every generation. The other two
# profiles leave the host default alone — and REMOVE the drop-in, so a box that
# switched away does not keep a tuning meant for a model it no longer runs.
VLLM_SYSCTL_FILE="${VLLM_SYSCTL_FILE:-/etc/sysctl.d/90-suite366-vllm.conf}"
apply_vllm_sysctl() { # apply_vllm_sysctl [SWAPPINESS]  (empty = restore default)
  local want="${1:-}"
  if [[ -z "$want" ]]; then
    [[ -f "$VLLM_SYSCTL_FILE" ]] || return 0
    rm -f "$VLLM_SYSCTL_FILE"
    info "vm.swappiness drop-in removed (this profile does not need it)."
    return 0
  fi
  printf 'vm.swappiness = %s\n' "$want" > "$VLLM_SYSCTL_FILE"
  sysctl -q -w "vm.swappiness=$want" >/dev/null 2>&1 || true
}

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
  # The three things switch-model.sh needs on the box to change model without
  # the deploy repo: the profile table, the entrypoint that knows every
  # profile's flags, and Gemma's chat template (mounted by the compose for all
  # three, read by one).
  # switch-model.sh lives at $DATA_DIR, next to update.sh and backup.sh, because
  # it is an OPERATOR script: `sudo /opt/suite366/switch-model.sh`. Without this
  # a box could read the profile table and never act on it.
  fetch "switch-model.sh"                       > "$DATA_DIR/switch-model.sh"
  chmod 750 "$DATA_DIR/switch-model.sh"
  fetch "llm/profiles.sh"                       > "$DATA_DIR/llm/profiles.sh"
  fetch "llm/serve-llm.sh"                      > "$DATA_DIR/llm/serve-llm.sh"
  fetch "llm/tool_chat_template_gemma4.jinja"   > "$DATA_DIR/llm/tool_chat_template_gemma4.jinja"
  chmod 755 "$DATA_DIR/llm/serve-llm.sh"
  fetch_flash_next_files
  fetch_stt_files
  # `if`, not `[[ ]] &&`: as the last command of a function the && form
  # returns 1 when the test is false and `set -e` kills the install.
  if [[ "$LLM_P_NEEDS_BUILD" == "1" ]]; then build_flash_next_image "$VLLM_LLM_IMAGE"; fi
  if [[ -n "$LLM_STT_MODEL" ]]; then build_stt_image "$VLLM_STT_IMAGE"; fi
  apply_vllm_sysctl "$LLM_P_SWAPPINESS"
  # Arms the .path unit that lets an org admin switch model from the app, and
  # writes the first state.json the UI reads. Idempotent, re-run on every
  # install — the fleet converges here, `update.sh` never replays deploy_vllm.
  "$DATA_DIR/switch-model.sh" install-units \
    || warn "could not arm the model-switch trigger (the CLI still works)."
  local env_file="$DATA_DIR/llm/.env" env_old=""
  [[ -f "$env_file" ]] && env_old="$(cat "$env_file")"
  local env_new
  env_new="$(cat <<EOF
VLLM_IMAGE=$VLLM_IMAGE
VLLM_LLM_IMAGE=$VLLM_LLM_IMAGE
LLM_PROFILE=$LLM_PROFILE
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
LLM_MTP_TOKENS=${LLM_MTP_TOKENS:-}
EMBED_MAX_MODEL_LEN=$EMBED_MAX_MODEL_LEN
VLLM_STT_IMAGE=$VLLM_STT_IMAGE
STT_MODEL=$LLM_STT_MODEL
STT_PORT=$STT_PORT
STT_GPU_MEM_UTIL=$LLM_STT_GPU_MEM_UTIL
STT_KV_CACHE_BYTES=$LLM_STT_KV_CACHE_BYTES
STT_MAX_MODEL_LEN=$LLM_STT_MAX_MODEL_LEN
STT_MAX_NUM_SEQS=$LLM_STT_MAX_NUM_SEQS
COMPOSE_PROFILES=${LLM_STT_MODEL:+stt}
EOF
)"
  ( umask 077; printf '%s\n' "$env_new" > "$env_file" )

  cat > /etc/systemd/system/suite366-vllm.service <<EOF
[Unit]
Description=Suite 366 — vLLM (generative + embeddings, + transcription where the profile allows)
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
  info "Downloading + loading models ($LLM_PROFILE; first boot for Flash-Next is ~133 GB, 25 min, then ~10 min to load)…"
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
  if [[ -n "$LLM_STT_MODEL" ]]; then
    if wait_http "http://$SUITE_IP:$STT_PORT/health" "vLLM transcription"; then
      warmup_stt "http://$SUITE_IP:$STT_PORT" "$LLM_STT_MODEL"
    else
      warn "vLLM transcription not ready yet (see: docker logs suite366-vllm-stt)."
    fi
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
# Two seconds of a 440 Hz tone: enough to run the encoder and the decoder once.
# The transcript is noise; the point is the compiled kernels the first real
# dictation would otherwise wait for.
write_warmup_wav() { # write_warmup_wav PATH
  python3 - "$1" <<'PYW'
import math, struct, sys
sr = 16000; n = sr * 2
pcm = b''.join(struct.pack('<h', int(3000 * math.sin(2 * math.pi * 440 * i / sr))) for i in range(n))
hdr = (b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVEfmt '
       + struct.pack('<IHHIIHH', 16, 1, 1, sr, sr * 2, 2, 16) + b'data' + struct.pack('<I', len(pcm)))
open(sys.argv[1], 'wb').write(hdr + pcm)
PYW
}
warmup_stt() { # warmup_stt BASE_URL MODEL
  local base="$1" model="$2" wav
  info "Warming up transcription JIT…"
  wav="$(mktemp --suffix=.wav)"
  if write_warmup_wav "$wav" && curl -fsS -m 300 "$base/v1/audio/transcriptions" \
       -H "Authorization: Bearer $VLLM_API_KEY" \
       -F "model=$model" -F "file=@$wav;type=audio/wav" >/dev/null 2>&1; then
    info "  transcription warm."
  else
    warn "  transcription warmup skipped (curl failed, non-blocking)."
  fi
  rm -f "$wav"
}
warmup_embed() { # warmup_embed BASE_URL MODEL
  local base="$1" model="$2"
  info "Warming up embeddings JIT…"
  curl -fsS -m 120 "$base/v1/embeddings" \
    -H "Authorization: Bearer $VLLM_API_KEY" -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"input\":\"ping\"}" \
    >/dev/null 2>&1 && info "  embeddings warm." || warn "  embeddings warmup skipped (curl failed, non-blocking)."
}
