#!/usr/bin/env bash
# =============================================================================
# Suite 366 — switch the appliance's generative model.
#
# The appliance can serve five profiles (llm/profiles.sh). Switching is not
# just a model id: each needs its share of the unified memory pool and its own
# vLLM flags (four run the unified image, Flash-Next its own), and the id
# itself lives in THREE places that must agree or the app breaks in a way
# nothing reports:
#
#   1. $DATA_DIR/llm/.env         what the vLLM container serves
#   2. $DATA_DIR/values.yaml      -> ConfigMap VLLM_MODEL_* the app reads
#   3. Postgres "AIModel"/"Agent" the rows every LLM call actually resolves
#
# Miss (3) and every call 404s with `docker ps` healthy and every pod Running —
# the same shape of failure as the API-key drift in lib/vllm-db.sh.
#
# A profile may also carry a TRANSCRIPTION model (llm/profiles.sh
# LLM_P_STT_MODEL), served by a third container on /v1/audio/*. It follows the
# same three places: STT_MODEL and COMPOSE_PROFILES in .env, the chart's
# VLLM_MODEL_TRANSCRIPTION, and an "AIModel" row with supportsTranscription that
# is each organisation's default. A profile without one takes the container
# down BEFORE the new generative engine starts (it holds memory the bigger
# model may need) and clears the rows, so the app says "no transcription model"
# instead of calling a route nothing serves.
#
# The EMBEDDING engine follows the same rule since orcasaq-batch (llm/profiles.sh
# LLM_P_EMBED): that profile runs the generative model alone and takes the
# embed's memory, so the embed container goes down BEFORE its engine starts,
# the chart's VLLM_MODEL_EMBEDDING is emptied and the "AIModel" EMBEDDING rows
# are disabled (and each organisation's default cleared); a switch back brings
# all three back.
#
# Order is deliberate: the new engine must be HEALTHY before anything else is
# touched. If it fails to come up, .env is restored, the previous engine is
# brought back, and the chart and the database are never moved — the box ends
# the run exactly where it started.
#
# Usage (as root, on the box):
#   /opt/suite366/switch-model.sh list           what is available, and on what
#   /opt/suite366/switch-model.sh status         what this box runs right now
#   /opt/suite366/switch-model.sh <profile>      switch to it
#   /opt/suite366/switch-model.sh <profile> --dry-run
#                                                print the plan and the SQL,
#                                                change nothing
#   /opt/suite366/switch-model.sh publish-state  refresh state.json for the app
#   /opt/suite366/switch-model.sh consume-trigger  run the switch the app asked for
#   /opt/suite366/switch-model.sh install-units  (re)install the .path unit
#   /opt/suite366/switch-model.sh converge       make the host side match the
#                                                files present WITHOUT changing
#                                                the model: fill llm/.env from the
#                                                profile, recreate what the compose
#                                                changed, reload the proxy, rewrite
#                                                the units, publish state.json.
#                                                What update.sh runs after laying
#                                                down a new host layer.
#   /opt/suite366/switch-model.sh install-vllm-unit
#                                                (re)write suite366-vllm.service
#
# App <-> host bridge ($DATA_DIR/llm-state, hostPath-mounted into drive-app at
# /appliance-llm — see values.yaml `extraVolumes`):
#   state.json        written here     — the profiles, the active one,
#                                        the engine's health, the switch status
#   switch-requested  written by the app — line 1 the profile, line 2 the admin
# The pod runs as uid/gid 1001 and k8s does NOT apply fsGroup to hostPath
# volumes, so the dir is root:1001 mode 0770 (group-writable for the trigger).
# It holds NO secret: llm/.env with the vLLM key stays out of the pod's reach.
#
# Env overrides: DATA_DIR, NAMESPACE, RELEASE, CHART_REF, KUBECONFIG_PATH,
# PG_DEPLOY, VLLM_SYSCTL_FILE, LLM_STATE_DIR.
# =============================================================================
set -euo pipefail

DATA_DIR="${DATA_DIR:-/opt/suite366}"
NAMESPACE="${NAMESPACE:-suite366}"
RELEASE="${RELEASE:-drive}"
CHART_REF="${CHART_REF:-oci://ghcr.io/scriptor-group/chart/drive}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
VLLM_SYSCTL_FILE="${VLLM_SYSCTL_FILE:-/etc/sysctl.d/90-suite366-vllm.conf}"
# Where the units go; the self-test points it at a temp dir.
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
PG_DEPLOY="${PG_DEPLOY:-}"
LLM_DIR="$DATA_DIR/llm"
ENV_FILE="$LLM_DIR/.env"
VALUES="$DATA_DIR/values.yaml"
# Shared with drive-app. Same ownership rule as $DATA_DIR/updates (update.sh).
LLM_STATE_DIR="${LLM_STATE_DIR:-$DATA_DIR/llm-state}"
STATE_JSON="$LLM_STATE_DIR/state.json"
TRIGGER="$LLM_STATE_DIR/switch-requested"
APP_GID=1001

c_b="\033[1m"; c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_0="\033[0m"
log()  { printf "${c_g}==>${c_0} ${c_b}%s${c_0}\n" "$*"; }
info() { printf "    %s\n" "$*"; }
warn() { printf "${c_y}!!  %s${c_0}\n" "$*"; }
die()  { printf "${c_r}xx  %s${c_0}\n" "$*" >&2; exit 1; }
kc()   { k3s kubectl "$@"; }

DRY_RUN=0
TARGET=""
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    -h|--help) sed -n '/^# Usage/,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*) die "unknown option: $arg" ;;
    *) [[ -z "$TARGET" ]] || die "one profile at a time (got '$TARGET' and '$arg')."; TARGET="$arg" ;;
  esac
done
[[ -n "$TARGET" ]] || { TARGET=list; }
REQUESTED_BY=""

[[ -f "$LLM_DIR/profiles.sh" ]] \
  || die "$LLM_DIR/profiles.sh missing — this box predates model profiles. Re-run install.sh."
# shellcheck disable=SC1091
source "$LLM_DIR/profiles.sh"

# --- what the box runs right now ---------------------------------------------
env_get() { # env_get KEY -> value from llm/.env, or empty
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | head -1
}
env_has() { # env_has KEY -> the key is present (even empty)
  [[ -f "$ENV_FILE" ]] && grep -q "^$1=" "$ENV_FILE"
}
ENV_CHANGES=0
set_env() { # set_env KEY VALUE — replace in place, append when absent
  local k="$1" v="$2"
  if env_has "$k"; then
    [[ "$(env_get "$k")" == "$v" ]] && return 0
    sed -i "s|^$k=.*|$k=$v|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
  ENV_CHANGES=$((ENV_CHANGES + 1))
}
set_env_default() { # set_env_default KEY VALUE — only when the key is absent
  env_has "$1" || set_env "$1" "$2"
}
CUR_PROFILE="$(env_get LLM_PROFILE)"
CUR_MODEL="$(env_get LLM_MODEL)"
STT_PORT_CUR="$(env_get STT_PORT)"
BASE_IMAGE="$(env_get VLLM_IMAGE)"
[[ -n "$BASE_IMAGE" ]] || die "VLLM_IMAGE missing from $ENV_FILE — is this an installed appliance?"
FLASH_NEXT_IMAGE="$(llm_flash_next_image "${FLASH_NEXT_PATCHES_COMMIT:-}")"

# The engine image three of the four profiles, the transcription engine and
# the embed run: VLLM_IMAGE itself when it is the unified image (the channel's,
# recognised by its label), else the same Dockerfile built here over it, once
# per tag (ensure_engine_image). lib/vllm.sh carries the same two functions:
# this script has no lib/ to source.
image_is_unified() { # image_is_unified IMAGE -> the image carries the unified label
  [[ -n "$(docker image inspect -f "{{index .Config.Labels \"$LLM_UNIFIED_LABEL\"}}" "$1" 2>/dev/null)" ]]
}
# Resolved without pulling: a `list` or `status` must not start a 10 GB pull.
# An image not on the box yet is taken for the unified one when its name is
# the registry's (the channel just moved VLLM_IMAGE there; ensure_engine_image
# pulls it when a switch or converge needs it), and for a plain base otherwise.
if command -v docker >/dev/null 2>&1 && docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
  if image_is_unified "$BASE_IMAGE"; then ENGINE_IMAGE="$BASE_IMAGE"; else ENGINE_IMAGE="$(llm_unified_image "$BASE_IMAGE")"; fi
elif [[ "$BASE_IMAGE" == "$LLM_UNIFIED_REGISTRY_IMAGE":* ]]; then
  ENGINE_IMAGE="$BASE_IMAGE"
else
  ENGINE_IMAGE="$(llm_unified_image "$BASE_IMAGE")"
fi
STT_IMAGE="$ENGINE_IMAGE"
engine_image_missing() { # -> the engine image is one to build here, and is not built yet
  [[ "$ENGINE_IMAGE" != "$BASE_IMAGE" ]] && ! docker image inspect "$ENGINE_IMAGE" >/dev/null 2>&1
}

# Every model id the profiles can produce: the scope of the Agent rewrite
# below. An agent pointed at OpenAI or Anthropic must not be touched.
all_profile_models() {
  local p
  for p in $LLM_PROFILES; do
    ( llm_profile_apply "$p" "$ENGINE_IMAGE" "$FLASH_NEXT_IMAGE" && printf '%s\n' "$LLM_P_MODEL" )
  done
}

# The profile a model id belongs to, for a box whose .env predates profiles
# (it has LLM_MODEL, no LLM_PROFILE). Empty when no profile serves that model.
profile_for_model() { # profile_for_model HF_ID
  local p
  for p in $LLM_PROFILES; do
    if ( llm_profile_apply "$p" "$ENGINE_IMAGE" "$FLASH_NEXT_IMAGE" && [[ "$LLM_P_MODEL" == "$1" ]] ); then
      printf '%s' "$p"; return 0
    fi
  done
  return 1
}

# The systemd unit that brings the compose stack up at boot. ONE template, used
# by install.sh (lib/vllm.sh) and by `converge`: a box installed before the CDI
# refresh landed still has a unit without the ExecStartPre, and its containers
# lose CUDA on the boot that shifts /dev/nvidia-uvm's major.
install_vllm_unit() {
  local cdi_spec="${CDI_SPEC:-/etc/cdi/nvidia.yaml}"
  cat > "$SYSTEMD_DIR/suite366-vllm.service" <<EOF
[Unit]
Description=Suite 366 — vLLM (generative + embeddings, + transcription where the profile allows)
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=$LLM_DIR
# /dev/nvidia-uvm's major is allocated dynamically at each boot while
# /etc/cdi/nvidia.yaml pins it, so refresh the spec before the containers are
# created: devices are injected at creation, and a boot that shifted the major
# otherwise hands them a node on the wrong char device — nvidia-smi still works
# inside the container, torch.cuda.init() does not, and vLLM crash-loops.
# This lives here rather than in NVIDIA's nvidia-cdi-refresh.service because of
# ordering: that unit is After=multi-user.target, so it runs after this stack —
# and on a box where plymouth-quit-wait hangs (DGX OS, \`quiet splash\`), the
# target is never reached and it never runs at all.
# Best-effort (leading -): never hold the stack down when the spec is fine.
ExecStartPre=-/usr/bin/nvidia-ctk cdi generate --output=$cdi_spec
# The refresh above only reaches containers created AFTER it, and at boot there
# are none: \`restart: unless-stopped\` makes dockerd restart last boot's
# containers before this unit runs, and \`up -d\` then finds them unchanged and
# recreates nothing. So they keep the stale spec, and all three engines load at
# once instead of LLM first (dockerd ignores depends_on), so vllm-llm exits and
# \`up\` fails on "dependency failed to start" (seen on every boot of
# promaxgb10-6452 from 28/09/2026). Taking the stack down first makes a boot
# behave like a restart: the containers are recreated with the fresh spec and
# started in compose order. Best-effort: nothing to remove on a first start.
ExecStartPre=-/usr/bin/docker compose down
ExecStart=/usr/bin/docker compose up -d
ExecStop=/usr/bin/docker compose down
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable suite366-vllm.service >/dev/null 2>&1 || true
}

# The engine image, pulled or built: VLLM_IMAGE when it is the unified one, the
# same Dockerfile built over it otherwise. Idempotent.
ENGINE_IMAGE_READY=0
ensure_engine_image() {
  [[ "$ENGINE_IMAGE_READY" == 1 ]] && return 0
  if [[ "$ENGINE_IMAGE" == "$BASE_IMAGE" ]]; then
    if ! docker image inspect "$ENGINE_IMAGE" >/dev/null 2>&1; then
      log "Pulling $ENGINE_IMAGE"
      docker pull -q "$ENGINE_IMAGE" >/dev/null || die "docker pull $ENGINE_IMAGE failed."
      image_is_unified "$ENGINE_IMAGE" \
        || die "$ENGINE_IMAGE does not carry the $LLM_UNIFIED_LABEL label — not an image this box can serve the profiles from."
    fi
    ENGINE_IMAGE_READY=1; return 0
  fi
  docker image inspect "$ENGINE_IMAGE" >/dev/null 2>&1 && { info "engine image $ENGINE_IMAGE already built."; ENGINE_IMAGE_READY=1; return 0; }
  [[ -f "$LLM_DIR/unified/Dockerfile" ]] \
    || die "$LLM_DIR/unified/Dockerfile missing — cannot build $ENGINE_IMAGE. Re-run install.sh."
  if ! docker image inspect "$BASE_IMAGE" >/dev/null 2>&1; then
    docker pull -q "$BASE_IMAGE" >/dev/null || die "docker pull $BASE_IMAGE failed."
  fi
  log "Building $ENGINE_IMAGE over $BASE_IMAGE (llm/unified/Dockerfile, ~5 min: exllamav3 compiles in ~3)"
  docker build -q -f "$LLM_DIR/unified/Dockerfile" --build-arg "BASE_IMAGE=$BASE_IMAGE" \
    --build-arg "UNIFIED_REV=$LLM_UNIFIED_IMAGE_REV" -t "$ENGINE_IMAGE" "$LLM_DIR" >/dev/null \
    || die "docker build of $ENGINE_IMAGE failed — see $LLM_DIR/unified/Dockerfile"
  ENGINE_IMAGE_READY=1
}

# Build what the profile needs and the box lacks. Shared by a switch and by
# converge; both die on a failed build because nothing below could start.
# Flash-Next is the one profile with an image of its own (LLM_P_NEEDS_BUILD,
# LLM_P_BUILD_DIR = llm/flash-next/, a vendored Dockerfile that pins its own
# FROM — the build argument is passed for form); every other profile, and the
# transcription engine, runs the engine image.
ensure_profile_images() {
  if [[ "$LLM_P_NEEDS_BUILD" == "1" ]]; then
    if docker image inspect "$LLM_P_IMAGE" >/dev/null 2>&1; then
      info "image $LLM_P_IMAGE already built."
    else
      local ctx="$LLM_DIR/${LLM_P_BUILD_DIR:?profile builds an image but names no LLM_P_BUILD_DIR}"
      [[ -f "$ctx/Dockerfile" ]] \
        || die "$ctx/ missing — cannot build $LLM_P_IMAGE. Re-run install.sh."
      log "Building $LLM_P_IMAGE from llm/$LLM_P_BUILD_DIR/ (see its Dockerfile for how long)"
      docker pull -q "$LLM_FLASH_NEXT_BASE_IMAGE" >/dev/null || die "docker pull $LLM_FLASH_NEXT_BASE_IMAGE failed."
      docker build -q --build-arg "BASE_IMAGE=$LLM_FLASH_NEXT_BASE_IMAGE" -t "$LLM_P_IMAGE" "$ctx" >/dev/null \
        || die "docker build of $LLM_P_IMAGE failed — see $ctx/Dockerfile"
    fi
  else
    ensure_engine_image
  fi
  if [[ -n "$LLM_P_STT_MODEL" ]]; then ensure_engine_image; fi
}

# Build with the box's memory free to do it. Compiling exllamav3 next to a
# running Flash-Next — 117/121 GiB before the first nvcc — drove a client Spark
# into 16 GiB of swap and a load of 74, and took the app down with it
# (2026-09-25). A build only happens when an image the target needs is missing
# (its own, or the engine image on a box without the channel's), and the target
# is about to replace the running engine anyway: so the generative and
# transcription engines are STOPPED first (the embed stays, it is 20 GiB and
# needed as is), the build runs, and if it fails the previous stack is brought
# back before the caller dies. The UI is told what is going on: the build is
# the longest silent stretch of a switch otherwise.
needs_build() { # -> an image the target profile needs has to be built here
  if [[ "$LLM_P_NEEDS_BUILD" == "1" ]]; then
    ! docker image inspect "$LLM_P_IMAGE" >/dev/null 2>&1 && return 0
  elif engine_image_missing; then
    return 0
  fi
  [[ -n "$LLM_P_STT_MODEL" ]] && engine_image_missing
}
build_with_engines_down() { # build_with_engines_down LABEL -> 0, or 1 with the previous engines back
  local label="$1"
  if ! needs_build; then
    ensure_profile_images; return 0
  fi
  publish_state running "$label" "building the $label image — the current model is paused while it compiles (a few minutes)"
  log "Stopping the running engines for the build (the box needs its memory to compile)"
  ( cd "$LLM_DIR" && docker compose --profile stt stop vllm-llm vllm-stt >/dev/null 2>&1 ) || true
  # A subshell: ensure_profile_images dies on failure, and the previous engine
  # must come back before anything here exits.
  if ( ensure_profile_images ); then return 0; fi
  warn "The build failed — bringing the previous engines back."
  ( cd "$LLM_DIR" && docker compose up -d >/dev/null 2>&1 ) || true
  publish_state error "$label" "the $label image could not be built; the previous model is back"
  return 1
}

# The transcription keys, ALL of them: a box installed before transcription
# existed has none, and the compose interpolates every one.
set_env_stt_keys() {
  set_env VLLM_STT_IMAGE    "$STT_IMAGE"
  set_env STT_MODEL         "$LLM_P_STT_MODEL"
  # Found by running this for real: an empty STT_PORT sent the warm-up to port
  # 80, i.e. Traefik's 404.
  set_env STT_PORT          "${STT_PORT_CUR:-8003}"
  set_env STT_GPU_MEM_UTIL  "$LLM_STT_GPU_MEM_UTIL"
  set_env STT_KV_CACHE_BYTES "$LLM_STT_KV_CACHE_BYTES"
  set_env STT_MAX_MODEL_LEN "$LLM_STT_MAX_MODEL_LEN"
  set_env STT_MAX_NUM_SEQS  "$LLM_STT_MAX_NUM_SEQS"
  # Which side engines the compose brings up: the embed (every profile but
  # orcasaq-batch) and the transcription engine (the profiles with room).
  set_env COMPOSE_PROFILES  "$(llm_compose_profiles "$LLM_P_EMBED" "$LLM_P_STT_MODEL")"
}
# What the embed serves, for the chart and the database: EMBED_MODEL from .env
# when the profile runs it, empty when it does not. A box from before the
# embed model was written to .env gets the installer's default.
embed_model_for() { # embed_model_for EMBED_FLAG -> model id or empty
  local m
  [[ "$1" == "1" ]] || return 0
  m="$(env_get EMBED_MODEL)"; printf '%s' "${m:-$LLM_EMBED_MODEL_DEFAULT}"
}
# Whether the embed is served right now: .env lists it, or the container runs
# (a box whose .env predates the `embed` compose profile has it running
# unlisted until converge rewrites the key).
embed_on_now() {
  case ",$(env_get COMPOSE_PROFILES)," in *,embed,*) return 0 ;; esac
  [[ "$(docker inspect -f '{{.State.Status}}' suite366-vllm-embed 2>/dev/null || true)" == running ]]
}

# nginx reads its config once at start; a new nginx.conf laid down under the
# running proxy is invisible until told. A reload is zero-downtime and a no-op
# when nothing changed — PROVIDED the container sees the new file. It does
# not: nginx.conf is a bind-mounted FILE, and a file bind mount follows the
# inode it was mounted from, while the host layer lays a new file down (new
# inode). Seen 2026-10-07 on two boxes after the resolver change: the host had
# the new config, `nginx -T` inside the container still showed the old
# upstream blocks, and the reload had re-read the old inode. So compare what
# the container sees with the host file, and recreate the proxy (a 2 s gap on
# the route) when they differ; reload only when they match.
reload_proxy() {
  docker inspect suite366-vllm-proxy >/dev/null 2>&1 || return 0
  if ! docker exec suite366-vllm-proxy cat /etc/nginx/nginx.conf 2>/dev/null | cmp -s - "$LLM_DIR/nginx.conf"; then
    info "nginx.conf changed on the host — recreating the proxy (its bind mount still holds the previous file)."
    if ( cd "$LLM_DIR" && docker compose up -d --force-recreate vllm-proxy >/dev/null 2>&1 ); then
      info "proxy recreated on the new config."
    else
      warn "proxy recreate failed (non-blocking) — restart it by hand: docker restart suite366-vllm-proxy"
    fi
    return 0
  fi
  if docker exec suite366-vllm-proxy nginx -t >/dev/null 2>&1; then
    docker exec suite366-vllm-proxy nginx -s reload >/dev/null 2>&1 \
      && info "proxy config reloaded." || warn "proxy reload failed (non-blocking)."
  else
    warn "the proxy refuses the new nginx.conf — left running on the old one."
  fi
}

wait_healthy() { # wait_healthy CONTAINER MINUTES LABEL -> 0 healthy, 1 not
  local ctr="$1" deadline label="$3" health state
  deadline=$(( $(date +%s) + $2 * 60 ))
  while :; do
    health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$ctr" 2>/dev/null || echo gone)"
    state="$(docker inspect -f '{{.State.Status}}' "$ctr" 2>/dev/null || echo gone)"
    [[ "$health" == healthy ]] && return 0
    [[ "$state" == running ]] || { warn "$label container state: $state"; return 1; }
    [[ "$(date +%s)" -lt "$deadline" ]] || { warn "$label still $health after $2 min"; return 1; }
    publish_state running "${TARGET_LABEL:-}" "waiting for the $label ($health)"
    sleep 10
  done
}

ensure_state_dir() {
  mkdir -p "$LLM_STATE_DIR"
  chown "root:$APP_GID" "$LLM_STATE_DIR" 2>/dev/null || true
  chmod 0770 "$LLM_STATE_DIR" 2>/dev/null || true
}

json_str() { # json_str VALUE -> a JSON string literal, escaped
  printf '%s' "$1" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))'
}

checkpoint_on_disk() { # checkpoint_on_disk HF_ID
  local models_dir; models_dir="$(env_get MODELS_DIR)"
  [[ -n "$models_dir" ]] || return 1
  [[ -d "$models_dir/hub/models--${1//\//--}" ]]
}

# state.json — the app reads this and never runs anything itself. Written via
# tmp+rename so a reader never sees a half-written file.
publish_state() { # publish_state [SWITCH_STATUS] [TARGET] [MESSAGE]
  local st="${1:-idle}" tgt="${2:-}" msg="${3:-}" tmp p first=1
  ensure_state_dir
  tmp="$(mktemp)"
  {
    printf '{\n  "schema": 1,\n'
    printf '  "updated_at": %s,\n' "$(json_str "$(date -Is)")"
    printf '  "active": %s,\n' "$(json_str "$(env_get LLM_PROFILE)")"
    printf '  "engine": {"image": %s, "state": %s, "health": %s},\n' \
      "$(json_str "$(docker inspect -f '{{.Config.Image}}' suite366-vllm-llm 2>/dev/null || true)")" \
      "$(json_str "$(docker inspect -f '{{.State.Status}}' suite366-vllm-llm 2>/dev/null || true)")" \
      "$(json_str "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' suite366-vllm-llm 2>/dev/null || true)")"
    # The transcription engine: `model` is what .env says this box serves (empty
    # = the active profile has none), state/health are the container's, empty
    # when it does not exist.
    printf '  "stt": {"model": %s, "state": %s, "health": %s},\n' \
      "$(json_str "$(env_get STT_MODEL)")" \
      "$(json_str "$(docker inspect -f '{{.State.Status}}' suite366-vllm-stt 2>/dev/null || true)")" \
      "$(json_str "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' suite366-vllm-stt 2>/dev/null || true)")"
    # The embedding engine, the same way: `model` is empty when the active
    # profile runs the generative model alone (orcasaq-batch).
    printf '  "embed": {"model": %s, "state": %s, "health": %s},\n' \
      "$(json_str "$(if embed_on_now; then env_get EMBED_MODEL; fi)")" \
      "$(json_str "$(docker inspect -f '{{.State.Status}}' suite366-vllm-embed 2>/dev/null || true)")" \
      "$(json_str "$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' suite366-vllm-embed 2>/dev/null || true)")"
    printf '  "switch": {"status": %s, "target": %s, "message": %s, "updated_at": %s},\n' \
      "$(json_str "$st")" "$(json_str "$tgt")" "$(json_str "$msg")" "$(json_str "$(date -Is)")"
    printf '  "profiles": ['
    for p in $LLM_PROFILES; do
      ( llm_profile_apply "$p" "$ENGINE_IMAGE" "$FLASH_NEXT_IMAGE"
        local dl=false nb=false; if checkpoint_on_disk "$LLM_P_MODEL"; then dl=true; fi
        # "needs_build" is what the UI warns about: a switch that compiles first.
        if needs_build; then nb=true; fi
        # "embed": false is what lets the card say the profile runs alone
        # (no document search) before the admin clicks.
        printf '%s\n    {"key": %s, "model": %s, "summary": %s, "context_window": %s, "needs_build": %s, "downloaded": %s, "stt_model": %s, "embed": %s}' \
          "$( [[ "$first" == 1 ]] && printf '' || printf ',' )" \
          "$(json_str "$p")" "$(json_str "$LLM_P_MODEL")" "$(json_str "$(llm_profile_summary "$p")")" \
          "$LLM_P_CONTEXT_WINDOW" \
          "$nb" "$dl" \
          "$(json_str "$LLM_P_STT_MODEL")" "$( [[ "$LLM_P_EMBED" == "1" ]] && printf true || printf false )" )
      first=0
    done
    printf '\n  ]\n}\n'
  } > "$tmp"
  chmod 0644 "$tmp"; mv -f "$tmp" "$STATE_JSON"
}

case "$TARGET" in
  install-vllm-unit)
    [[ $EUID -eq 0 || "${SWITCH_MODEL_SELFTEST:-0}" == 1 ]] || die "run me as root."
    install_vllm_unit
    info "suite366-vllm.service written and enabled."
    exit 0 ;;
  converge)
    # The self-test (tools/test-host-layer.sh) runs this as a user with docker,
    # systemctl and sysctl stubbed; nothing else may set the variable.
    [[ $EUID -eq 0 || "${SWITCH_MODEL_SELFTEST:-0}" == 1 ]] || die "run me as root."
    command -v docker >/dev/null || die "docker not found."
    [[ -f "$LLM_DIR/docker-compose.yml" ]] || die "$LLM_DIR/docker-compose.yml missing."
    log "Converging the host side of the vLLM stack (no model change)"
    TARGET_LABEL="$CUR_PROFILE"
    prof="$CUR_PROFILE"
    if [[ -z "$prof" ]]; then
      # A box from before profiles: .env names the model, not the recipe.
      prof="$(profile_for_model "$CUR_MODEL" || true)"
      [[ -n "$prof" ]] && info "profile for $CUR_MODEL: $prof (this box predates profiles)"
    fi
    if [[ -z "$prof" ]] || ! llm_profile_known "$prof"; then
      warn "no profile serves '${CUR_MODEL:-<no LLM_MODEL>}' — the compose and .env are left as they are."
      warn "  Pick a profile to move this box onto the current stack: $0 <profile>"
      install_vllm_unit
      TARGET=install-units; publish_state idle
      exit 0
    fi
    llm_profile_apply "$prof" "$ENGINE_IMAGE" "$FLASH_NEXT_IMAGE"
    TARGET_LABEL="$prof"
    # The images first, BEFORE .env moves: a build that fails must leave a box
    # whose `docker compose up -d` still names an image it has.
    build_with_engines_down "$prof" \
      || die "could not build $LLM_P_IMAGE — see the build output above; .env is untouched and the previous engines are back."
    # .env: the profile is authoritative for what it defines (image, MTP head,
    # transcription); budgets an operator may have tuned are only filled in
    # when missing; keys the old compose never had get their defaults.
    set_env_default LLM_PROFILE       "$prof"
    set_env         VLLM_LLM_IMAGE    "$LLM_P_IMAGE"
    # The share: filled in when missing, LOWERED to the profile's when the box's
    # is higher, never raised. Gemma shipped at 0.55 and moved to 0.45 to seat
    # the transcription engine (2026-09-25): a box left at 0.55 would restart
    # that engine in a loop (7.9 GiB free, 12.2 needed). A share an operator
    # tuned DOWN is a memory decision this script must not undo.
    cur_util="$(env_get LLM_GPU_MEM_UTIL)"
    if [[ -z "$cur_util" ]] || awk -v c="$cur_util" -v p="$LLM_P_GPU_MEM_UTIL" 'BEGIN { exit !(c + 0 > p + 0) }'; then
      set_env LLM_GPU_MEM_UTIL "$LLM_P_GPU_MEM_UTIL"
    fi
    set_env_default LLM_MAX_MODEL_LEN "$LLM_P_MAX_MODEL_LEN"
    set_env_default LLM_MAX_NUM_SEQS  "$LLM_P_MAX_NUM_SEQS"
    set_env         LLM_MTP_TOKENS    "$LLM_P_MTP_TOKENS"
    set_env_default EMBED_MODEL       "$LLM_EMBED_MODEL_DEFAULT"
    set_env_default EMBED_GPU_MEM_UTIL "0.20"
    set_env_default EMBED_MAX_MODEL_LEN "8192"
    set_env_default CACHE_DIR         "$DATA_DIR/cache"
    set_env_stt_keys
    cache_dir="$(env_get CACHE_DIR)"
    mkdir -p "$cache_dir/vllm" "$cache_dir/flashinfer" "$cache_dir/triton"
    info ".env: $ENV_CHANGES key(s) written"
    if [[ -n "$LLM_P_SWAPPINESS" ]]; then
      printf 'vm.swappiness = %s\n' "$LLM_P_SWAPPINESS" > "$VLLM_SYSCTL_FILE"
      sysctl -q -w "vm.swappiness=$LLM_P_SWAPPINESS" >/dev/null 2>&1 || true
    else
      rm -f "$VLLM_SYSCTL_FILE"
    fi
    install_vllm_unit
    # Containers whose definition changed are recreated, the others left alone;
    # a side engine the profile has no room for is taken down.
    if [[ -z "$LLM_P_STT_MODEL" ]]; then
      ( cd "$LLM_DIR" && docker compose --profile stt rm -sf vllm-stt >/dev/null 2>&1 ) || true
    fi
    if [[ "$LLM_P_EMBED" != "1" ]]; then
      ( cd "$LLM_DIR" && docker compose --profile embed rm -sf vllm-embed >/dev/null 2>&1 ) || true
    fi
    publish_state running "$prof" "applying the host layer ($prof)"
    log "docker compose up -d (recreates only what changed)"
    ( cd "$LLM_DIR" && docker compose up -d ) || die "docker compose up failed — see docker compose logs in $LLM_DIR"
    if wait_healthy suite366-vllm-llm 30 "engine"; then info "engine healthy."; else warn "engine not healthy — check: docker logs suite366-vllm-llm"; fi
    if [[ -n "$LLM_P_STT_MODEL" ]]; then
      if wait_healthy suite366-vllm-stt 30 "transcription engine"; then info "transcription engine healthy."; else warn "transcription engine not healthy — check: docker logs suite366-vllm-stt"; fi
    fi
    if [[ "$LLM_P_EMBED" == "1" ]]; then
      if wait_healthy suite366-vllm-embed 20 "embedding engine"; then info "embedding engine healthy."; else warn "embedding engine not healthy — check: docker logs suite366-vllm-embed"; fi
    fi
    reload_proxy
    # The app-trigger unit and state.json, exactly as install-units does.
    TARGET=install-units
    ensure_state_dir
    cat > "$SYSTEMD_DIR/suite366-llm-switch.service" <<EOF
[Unit]
Description=Suite 366 — switch the generative model (triggered from the app UI)
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=$DATA_DIR/switch-model.sh consume-trigger
TimeoutStartSec=0
EOF
    cat > "$SYSTEMD_DIR/suite366-llm-switch.path" <<EOF
[Unit]
Description=Suite 366 — watch for model-switch requests from the app

[Path]
PathExists=$TRIGGER

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now suite366-llm-switch.path >/dev/null 2>&1 \
      || warn "could not enable the switch path unit (systemd offline?)."
    publish_state idle
    log "Host side converged on profile $prof ($LLM_P_MODEL${LLM_P_STT_MODEL:+ + $LLM_P_STT_MODEL}$( [[ "$LLM_P_EMBED" == "1" ]] || printf ', alone: no embeddings' ))."
    exit 0 ;;
  publish-state)
    publish_state idle
    info "state published to $STATE_JSON"
    exit 0 ;;
  install-units)
    [[ $EUID -eq 0 ]] || die "run me as root."
    ensure_state_dir
    cat > "$SYSTEMD_DIR/suite366-llm-switch.service" <<EOF
[Unit]
Description=Suite 366 — switch the generative model (triggered from the app UI)
After=docker.service
Wants=docker.service

[Service]
Type=oneshot
ExecStart=$DATA_DIR/switch-model.sh consume-trigger
TimeoutStartSec=0
EOF
    cat > "$SYSTEMD_DIR/suite366-llm-switch.path" <<EOF
[Unit]
Description=Suite 366 — watch for model-switch requests from the app

[Path]
PathExists=$TRIGGER

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now suite366-llm-switch.path >/dev/null 2>&1 \
      || warn "could not enable the switch path unit (systemd offline?)."
    publish_state idle
    info "App-trigger unit armed (watching $TRIGGER)."
    exit 0 ;;
  consume-trigger)
    [[ $EUID -eq 0 ]] || die "run me as root."
    [[ -f "$TRIGGER" ]] || { info "no pending request."; exit 0; }
    # Read THEN delete: a request that fails must not replay on the next boot.
    want="$(sed -n 1p "$TRIGGER" | tr -dc 'a-z0-9-' | head -c 32)"
    REQUESTED_BY="$(sed -n 2p "$TRIGGER" | tr -d '\r\n' | head -c 200)"
    rm -f "$TRIGGER"
    if ! llm_profile_known "$want"; then
      publish_state error "$want" "unknown profile requested"
      die "trigger asked for an unknown profile: '$want'"
    fi
    info "request from ${REQUESTED_BY:-unknown}: switch to $want"
    TARGET="$want"
    ;;
  list)
    printf '%-14s %-34s %s\n' PROFILE MODEL NOTES
    for p in $LLM_PROFILES; do
      ( llm_profile_apply "$p" "$ENGINE_IMAGE" "$FLASH_NEXT_IMAGE"
        mark=' '; if [[ "$p" == "$CUR_PROFILE" ]]; then mark='*'; fi
        printf '%s%-13s %-34s %s%s\n' "$mark" "$p" "$LLM_P_MODEL" "$(llm_profile_summary "$p")" \
          "${LLM_P_STT_MODEL:+ — with transcription ($LLM_P_STT_MODEL)}" )
    done
    printf '\n(* = active)  switch with: %s <profile>\n' "$0"
    exit 0 ;;
  status)
    printf 'profile        %s\n' "${CUR_PROFILE:-<unset, pre-profiles install>}"
    printf 'model (.env)   %s\n' "${CUR_MODEL:-<unset>}"
    printf 'image          %s\n' "$(env_get VLLM_LLM_IMAGE)"
    printf 'budgets        util=%s max_model_len=%s max_num_seqs=%s\n' \
      "$(env_get LLM_GPU_MEM_UTIL)" "$(env_get LLM_MAX_MODEL_LEN)" "$(env_get LLM_MAX_NUM_SEQS)"
    printf 'chart values   %s\n' "$(sed -n 's/^  VLLM_MODEL_HIGH: "\(.*\)"/\1/p' "$VALUES" 2>/dev/null | head -1)"
    ctr="$(docker inspect -f '{{.Config.Image}} ({{.State.Status}}, {{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}})' suite366-vllm-llm 2>/dev/null || true)"
    printf 'container      %s\n' "${ctr:-absent}"
    if embed_on_now; then
      embed_ctr="$(docker inspect -f '{{.State.Status}}, {{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' suite366-vllm-embed 2>/dev/null || true)"
      printf 'embeddings     %s (%s)\n' "$(env_get EMBED_MODEL)" "${embed_ctr:-container absent}"
    else
      printf 'embeddings     none for this profile (the generative model runs alone)\n'
    fi
    stt_model="$(env_get STT_MODEL)"
    if [[ -n "$stt_model" ]]; then
      stt_ctr="$(docker inspect -f '{{.State.Status}}, {{if .State.Health}}{{.State.Health.Status}}{{else}}no healthcheck{{end}}' suite366-vllm-stt 2>/dev/null || true)"
      printf 'transcription  %s (%s)\n' "$stt_model" "${stt_ctr:-container absent}"
    else
      printf 'transcription  none for this profile\n'
    fi
    exit 0 ;;
esac

llm_profile_known "$TARGET" || die "unknown profile '$TARGET'. Known: $LLM_PROFILES (see '$0 list')."
llm_profile_apply "$TARGET" "$ENGINE_IMAGE" "$FLASH_NEXT_IMAGE"

[[ "$DRY_RUN" == 1 || $EUID -eq 0 ]] || die "run me as root (docker, k3s and $DATA_DIR are root-only)."

log "Switching the generative model: ${CUR_PROFILE:-unknown} -> $TARGET"
info "model      $CUR_MODEL -> $LLM_P_MODEL"
info "image      $(env_get VLLM_LLM_IMAGE) -> $LLM_P_IMAGE"
info "budgets    util=$LLM_P_GPU_MEM_UTIL max_model_len=$LLM_P_MAX_MODEL_LEN slots=$LLM_P_MAX_NUM_SEQS"
info "app ctx    $LLM_P_CONTEXT_WINDOW tokens"
info "swappiness ${LLM_P_SWAPPINESS:-host default}"
info "transcription $(env_get STT_MODEL) -> ${LLM_P_STT_MODEL:-none}"
info "embeddings $(if embed_on_now; then env_get EMBED_MODEL; else printf none; fi) -> $(if [[ "$LLM_P_EMBED" == "1" ]]; then embed_model_for 1; else printf none; fi)"
[[ "$LLM_P_EMBED" == "1" ]] || info "           ($TARGET runs the generative model ALONE: no document search, no transcription while it is active)"

if [[ "$CUR_PROFILE" == "$TARGET" && "$DRY_RUN" == 0 ]]; then
  info "Already on $TARGET — re-applying anyway (idempotent, recreates the container)."
fi

# --- the SQL, built once so --dry-run can show exactly what would run --------
# `\set` + `:'name'` so psql quotes the values; nothing here is user input, but
# a model id with a quote in it would otherwise be a syntax error at best.
# The transcription rows are scoped to THIS box's vLLM providers — the seed's
# name, a row without baseUrl, or a baseUrl on our proxy — the same rule as the
# app's own reconcile (vllm-provider.ts ownsVllmRow). A remote vLLM an admin
# registered on purpose keeps its own model list. `SQL_STT_MODEL`, when set,
# overrides the profile's value: the real run passes what actually came up.
build_sql() {
  local models_in="" m stt embed embed_dims base_like
  stt="${SQL_STT_MODEL-$LLM_P_STT_MODEL}"
  # The embedding row follows the same two rules: `SQL_EMBED_MODEL` is what
  # actually came up (the real run), the profile's answer otherwise.
  embed="${SQL_EMBED_MODEL-$(embed_model_for "$LLM_P_EMBED" || true)}"
  # The vector size the app seeded the row with (pgvector indexes that shape):
  # the chart's value, 4096 (Qwen3-VL-Embedding-8B) when the file lacks it.
  embed_dims="$(sed -n 's/^  VLLM_EMBEDDING_DIMENSIONS: "\([0-9]*\)"/\1/p' "$VALUES" 2>/dev/null | head -1)"
  [[ "$embed_dims" =~ ^[0-9]+$ ]] || embed_dims=4096
  base_like="http://$(env_get BIND_IP):$(env_get PROXY_PORT)/%"
  while IFS= read -r m; do
    if [[ -n "$m" ]]; then models_in+="$(printf "'%s'," "$m")"; fi
  done < <(all_profile_models)
  models_in="${models_in%,}"
  cat <<SQL
\set model '$LLM_P_MODEL'
\set ctx $LLM_P_CONTEXT_WINDOW
\set stt '$stt'
\set embed '$embed'
\set embed_dims $embed_dims
\set base_like '$base_like'
SELECT CASE WHEN to_regclass('"public"."AIModel"') IS NULL THEN 'off' ELSE 'on' END AS have_ai \gset
\if :have_ai
WITH ours AS (
  -- The rows this box owns, in EVERY organisation it hosts: the app's own
  -- seed, a seed without a base URL, or a row already pointing here. A remote
  -- vLLM an org admin registered on purpose is not ours, and is never renamed.
  SELECT id, "organizationId" FROM "public"."AIProvider"
   WHERE provider = 'VLLM'
     AND (name = 'vLLM Local' OR config->>'baseUrl' IS NULL OR config->>'baseUrl' LIKE :'base_like')
), m AS (
  -- The transcription row is modelType LLM too (the app has no STT type; the
  -- flag is what distinguishes it): without the exclusion this rename hits it
  -- on the second run and dies on the (providerId, modelId) unique key.
  UPDATE "public"."AIModel" SET "modelId" = :'model', "displayName" = :'model', "contextWindow" = :ctx
   WHERE "modelType" = 'LLM' AND "supportsTranscription" = false
     AND "providerId" IN (SELECT id FROM ours)
     AND ("modelId" IS DISTINCT FROM :'model' OR "contextWindow" IS DISTINCT FROM :ctx)
  RETURNING 1
), a AS (
  -- Profile names are box-wide, but an organisation whose only vLLM is a
  -- remote one it registered itself keeps its agents; NULL = system agents.
  UPDATE "public"."Agent" SET model = :'model'
   WHERE model IN ($models_in) AND model IS DISTINCT FROM :'model'
     AND ("organizationId" IS NULL OR "organizationId" IN (SELECT "organizationId" FROM ours))
  RETURNING 1
), s_on AS (
  -- The transcription row for this profile, created or re-enabled. Prisma
  -- generates ids client-side, so the insert has to bring its own.
  INSERT INTO "public"."AIModel"
      (id, "providerId", "modelId", "displayName", "modelType",
       "supportsTranscription", "supportsTools", "supportsVision", "isEnabled", "createdAt")
  SELECT gen_random_uuid()::text, o.id, :'stt', :'stt', 'LLM', true, false, false, true, now()
    FROM ours o WHERE :'stt' <> ''
  ON CONFLICT ("providerId", "modelId") DO UPDATE
     SET "isEnabled" = true, "supportsTranscription" = true
  RETURNING id, "providerId"
), s_off AS (
  -- Every other transcription row of ours goes dark (all of them when the
  -- profile has none): the UI must not offer a model nothing serves.
  UPDATE "public"."AIModel" SET "isEnabled" = false
   WHERE "supportsTranscription" = true AND "isEnabled" = true
     AND "providerId" IN (SELECT id FROM ours)
     AND "modelId" IS DISTINCT FROM :'stt'
  RETURNING id
), o_set AS (
  -- Each organisation's default, when it is unset or was one of ours. A default
  -- an admin pointed at another provider (BYO Whisper, a system model) is kept.
  UPDATE "public"."Organization" org SET "defaultTranscriptionModelId" = s.id
    FROM s_on s JOIN ours p ON p.id = s."providerId"
   WHERE org.id = p."organizationId"
     AND org."defaultTranscriptionModelId" IS DISTINCT FROM s.id
     AND (org."defaultTranscriptionModelId" IS NULL
          OR org."defaultTranscriptionModelId" IN
             (SELECT id FROM "public"."AIModel" WHERE "providerId" IN (SELECT id FROM ours)))
  RETURNING 1
), o_clear AS (
  UPDATE "public"."Organization" org SET "defaultTranscriptionModelId" = NULL
   WHERE :'stt' = ''
     AND org."defaultTranscriptionModelId" IN
         (SELECT id FROM "public"."AIModel" WHERE "providerId" IN (SELECT id FROM ours))
  RETURNING 1
), e_on AS (
  -- The embedding row, created or re-enabled when the profile serves the
  -- engine (the app seeds it at organisation creation, but an organisation
  -- created while orcasaq-batch was active has none). Same shape as the
  -- app's seed (vllm-provider.ts), dimensions included: pgvector indexes
  -- that shape.
  INSERT INTO "public"."AIModel"
      (id, "providerId", "modelId", "displayName", "modelType", "contextWindow", "maxOutputTokens",
       "embeddingDimensions", "supportsTools", "supportsVision", "isEnabled", "createdAt")
  SELECT gen_random_uuid()::text, o.id, :'embed', :'embed', 'EMBEDDING', 8192, 0,
         :embed_dims, false, false, true, now()
    FROM ours o WHERE :'embed' <> ''
  ON CONFLICT ("providerId", "modelId") DO UPDATE
     SET "isEnabled" = true
  RETURNING id, "providerId"
), e_off AS (
  -- Every other embedding row of ours goes dark (all of them when the profile
  -- runs the generative model alone): an indexing job must not call a route
  -- nothing serves.
  UPDATE "public"."AIModel" SET "isEnabled" = false
   WHERE "modelType" = 'EMBEDDING' AND "isEnabled" = true
     AND "providerId" IN (SELECT id FROM ours)
     AND "modelId" IS DISTINCT FROM :'embed'
  RETURNING id
), oe_set AS (
  -- Each organisation's default embedding model, when unset or one of ours;
  -- a default an admin pointed at another provider is kept.
  UPDATE "public"."Organization" org SET "defaultEmbeddingModelId" = e.id
    FROM e_on e JOIN ours p ON p.id = e."providerId"
   WHERE org.id = p."organizationId"
     AND org."defaultEmbeddingModelId" IS DISTINCT FROM e.id
     AND (org."defaultEmbeddingModelId" IS NULL
          OR org."defaultEmbeddingModelId" IN
             (SELECT id FROM "public"."AIModel" WHERE "providerId" IN (SELECT id FROM ours)))
  RETURNING 1
), oe_clear AS (
  UPDATE "public"."Organization" org SET "defaultEmbeddingModelId" = NULL
   WHERE :'embed' = ''
     AND org."defaultEmbeddingModelId" IN
         (SELECT id FROM "public"."AIModel" WHERE "providerId" IN (SELECT id FROM ours))
  RETURNING 1
)
SELECT 'aimodel=' || (SELECT count(*) FROM m) || ' agent=' || (SELECT count(*) FROM a)
    || ' stt_on=' || (SELECT count(*) FROM s_on) || ' stt_off=' || (SELECT count(*) FROM s_off)
    || ' stt_default=' || ((SELECT count(*) FROM o_set) + (SELECT count(*) FROM o_clear))
    || ' embed_on=' || (SELECT count(*) FROM e_on) || ' embed_off=' || (SELECT count(*) FROM e_off)
    || ' embed_default=' || ((SELECT count(*) FROM oe_set) + (SELECT count(*) FROM oe_clear));
\else
\echo aimodel=no-table agent=no-table
\endif
SQL
}

if [[ "$DRY_RUN" == 1 ]]; then
  log "--dry-run: nothing will be changed"
  echo; info "llm/.env would become:"
  printf '      LLM_PROFILE=%s\n      LLM_MODEL=%s\n      VLLM_LLM_IMAGE=%s\n      LLM_GPU_MEM_UTIL=%s\n      LLM_MAX_MODEL_LEN=%s\n      LLM_MAX_NUM_SEQS=%s\n      LLM_MTP_TOKENS=%s\n      STT_MODEL=%s\n      STT_PORT=%s\n      COMPOSE_PROFILES=%s\n' \
    "$TARGET" "$LLM_P_MODEL" "$LLM_P_IMAGE" "$LLM_P_GPU_MEM_UTIL" "$LLM_P_MAX_MODEL_LEN" "$LLM_P_MAX_NUM_SEQS" "$LLM_P_MTP_TOKENS" \
    "$LLM_P_STT_MODEL" "${STT_PORT_CUR:-8003}" "$(llm_compose_profiles "$LLM_P_EMBED" "$LLM_P_STT_MODEL")"
  echo; info "values.yaml: VLLM_MODEL_{HIGH,LIGHT,VISION} -> $LLM_P_MODEL, VLLM_MAX_CONTEXT_WINDOW -> $LLM_P_CONTEXT_WINDOW"
  info "             VLLM_MODEL_TRANSCRIPTION -> ${LLM_P_STT_MODEL:-\"\" (this profile has none)}"
  dry_embed="$(embed_model_for "$LLM_P_EMBED" || true)"
  info "             VLLM_MODEL_EMBEDDING -> ${dry_embed:-\"\" (this profile runs the generative model alone)}"
  echo; info "SQL:"; build_sql | sed 's/^/      /'
  if [[ "$LLM_P_NEEDS_BUILD" == "1" ]]; then
    echo; info "image build: $LLM_P_IMAGE (from $LLM_FLASH_NEXT_BASE_IMAGE + llm/$LLM_P_BUILD_DIR/, unless already built)"
  elif [[ "$ENGINE_IMAGE" != "$BASE_IMAGE" ]]; then
    echo; info "image build: $ENGINE_IMAGE (from $BASE_IMAGE + llm/unified/, unless already built)"
  else
    echo; info "engine image: $ENGINE_IMAGE (the channel's unified image, pulled)"
  fi
  if [[ -n "$LLM_P_STT_MODEL" ]]; then
    echo; info "transcription engine: $STT_IMAGE (the engine image)"
    info "transcription container: taken down first, then suite366-vllm-stt up after the engine is healthy"
  else
    echo; info "transcription container: suite366-vllm-stt taken down before the engine starts, and stays down"
  fi
  if [[ "$LLM_P_EMBED" == "1" ]]; then
    info "embedding container: suite366-vllm-embed kept (or brought back after the engine is healthy)"
  else
    info "embedding container: suite366-vllm-embed taken down before the engine starts, and stays down"
  fi
  exit 0
fi

export KUBECONFIG="$KUBECONFIG_PATH"
command -v docker >/dev/null || die "docker not found."
[[ -f "$LLM_DIR/docker-compose.yml" ]] || die "$LLM_DIR/docker-compose.yml missing."

# --- 1. the images this profile needs ----------------------------------------
# A build stops the running engines first (see build_with_engines_down): the
# only thing the previous model can do for the build is to get out of its way.
build_with_engines_down "$TARGET" \
  || die "The $TARGET image could not be built; the previous engines were brought back. See the build output above."

# --- 2. .env, with the previous one kept for the rollback ---------------------
ENV_BACKUP="$(mktemp)"; cp "$ENV_FILE" "$ENV_BACKUP"
SYSCTL_WAS_PRESENT=0
if [[ -f "$VLLM_SYSCTL_FILE" ]]; then SYSCTL_WAS_PRESENT=1; fi

set_env LLM_PROFILE      "$TARGET"
set_env LLM_MODEL        "$LLM_P_MODEL"
set_env VLLM_LLM_IMAGE   "$LLM_P_IMAGE"
set_env LLM_GPU_MEM_UTIL "$LLM_P_GPU_MEM_UTIL"
set_env LLM_MAX_MODEL_LEN "$LLM_P_MAX_MODEL_LEN"
set_env LLM_MAX_NUM_SEQS "$LLM_P_MAX_NUM_SEQS"
set_env LLM_MTP_TOKENS   "$LLM_P_MTP_TOKENS"
set_env_stt_keys
# A box from before the JIT caches or before profiles: give the compose every
# key it interpolates, with the installer's defaults.
set_env_default CACHE_DIR "$DATA_DIR/cache"
set_env_default EMBED_MODEL "$LLM_EMBED_MODEL_DEFAULT"
set_env_default EMBED_MAX_MODEL_LEN "8192"
mkdir -p "$(env_get CACHE_DIR)/vllm" "$(env_get CACHE_DIR)/flashinfer" "$(env_get CACHE_DIR)/triton"

if [[ -n "$LLM_P_SWAPPINESS" ]]; then
  printf 'vm.swappiness = %s\n' "$LLM_P_SWAPPINESS" > "$VLLM_SYSCTL_FILE"
  sysctl -q -w "vm.swappiness=$LLM_P_SWAPPINESS" >/dev/null 2>&1 || true
else
  rm -f "$VLLM_SYSCTL_FILE"
fi

rollback() {
  warn "Rolling back to ${CUR_PROFILE:-the previous configuration}."
  cp "$ENV_BACKUP" "$ENV_FILE"
  if [[ "$SYSCTL_WAS_PRESENT" == 0 ]]; then rm -f "$VLLM_SYSCTL_FILE"; fi
  # The whole stack, not just vllm-llm: the restored .env decides whether the
  # side engines (taken down above when the target had no room for them) come
  # back with the previous engine.
  ( cd "$LLM_DIR" && docker compose up -d >/dev/null 2>&1 ) || true
  publish_state error "$TARGET" "the $TARGET engine did not come up; rolled back to ${CUR_PROFILE:-the previous model}"
  die "The $TARGET engine did not come up. The chart and the database were NOT touched, so the box is back where it started. Logs: docker logs suite366-vllm-llm"
}

# --- 3. bring the new engine up, and wait for it ------------------------------
# The transcription engine goes down FIRST, whatever the target. Two reasons,
# both measured. It holds ~10 GiB a bigger generative model may need to clear
# vLLM's start-up check. And on unified memory vLLM sizes the KV cache as its
# share MINUS everything else resident when it profiles — Gemma at 0.45 got
# 222k tokens of KV with the transcription engine up during its start and
# ~300k without (2026-09-25). Taking it down here and bringing it back in 3b
# gives every switch the same baseline (the embed only, when the target keeps
# it), so a profile's KV does not depend on which profile ran before.
( cd "$LLM_DIR" && docker compose --profile stt rm -sf vllm-stt >/dev/null 2>&1 ) || true
docker rm -f suite366-vllm-stt >/dev/null 2>&1 || true
# The embed goes down too when the target runs alone: its 0.80 share is the
# embed's 20 GiB, and vLLM's start-up check (free memory >= share x total)
# fails with the embed resident. Brought back in 3c when the target keeps it.
if [[ "$LLM_P_EMBED" != "1" ]]; then
  log "Taking the embedding engine down ($TARGET runs the generative model alone)"
  ( cd "$LLM_DIR" && docker compose --profile embed rm -sf vllm-embed >/dev/null 2>&1 ) || true
  docker rm -f suite366-vllm-embed >/dev/null 2>&1 || true
fi
# From here the app's UI can follow along in state.json.
publish_state running "$TARGET" "starting the $TARGET engine"
log "Recreating suite366-vllm-llm on $TARGET"
( cd "$LLM_DIR" && docker compose up -d --force-recreate vllm-llm >/dev/null ) || rollback

# Flash-Next's first boot downloads ~133 GB; the other two load in 2-5 min.
deadline=$(( $(date +%s) + 3600 ))
log "Waiting for the engine to report healthy (up to 60 min on a first download)"
while :; do
  health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' suite366-vllm-llm 2>/dev/null || echo gone)"
  state="$(docker inspect -f '{{.State.Status}}' suite366-vllm-llm 2>/dev/null || echo gone)"
  if [[ "$health" == healthy ]]; then break; fi
  if [[ "$state" != running ]]; then warn "container state: $state"; rollback; fi
  if [[ "$(date +%s)" -ge "$deadline" ]]; then warn "still $health after 60 min"; rollback; fi
  # Republished every tick: a Flash-Next first boot is a ~133 GB download, and
  # the admin watching the UI needs the engine's real state, not the one the
  # previous container had when the switch started.
  publish_state running "$TARGET" "waiting for the $TARGET engine ($health)"
  sleep 10
done
info "engine healthy."
rm -f "$ENV_BACKUP"

# --- 3b. the transcription engine, where the profile has one ------------------
# Not a rollback condition: the generative model is up and serving. A
# transcription engine that does not come up is reported, left OUT of the chart
# values and the database (the app then says "no transcription model" rather
# than calling a route nothing answers), and the switch goes on.
STT_SERVED=""
if [[ -n "$LLM_P_STT_MODEL" ]]; then
  publish_state running "$TARGET" "starting the transcription engine ($LLM_P_STT_MODEL)"
  log "Starting suite366-vllm-stt ($LLM_P_STT_MODEL)"
  # Plain `up`, no --force-recreate: unchanged and already running, it stays.
  if ( cd "$LLM_DIR" && docker compose --profile stt up -d vllm-stt >/dev/null ); then
    stt_deadline=$(( $(date +%s) + 1800 ))
    while :; do
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' suite366-vllm-stt 2>/dev/null || echo gone)"
      state="$(docker inspect -f '{{.State.Status}}' suite366-vllm-stt 2>/dev/null || echo gone)"
      if [[ "$health" == healthy ]]; then STT_SERVED="$LLM_P_STT_MODEL"; break; fi
      if [[ "$state" != running ]]; then warn "transcription container state: $state"; break; fi
      if [[ "$(date +%s)" -ge "$stt_deadline" ]]; then warn "transcription still $health after 30 min"; break; fi
      publish_state running "$TARGET" "waiting for the transcription engine ($health)"
      sleep 10
    done
  else
    warn "docker compose could not start vllm-stt."
  fi
  if [[ -n "$STT_SERVED" ]]; then
    info "transcription engine healthy."
  else
    warn "The transcription engine did not come up; the generative model is unaffected."
    warn "  Transcription stays OFF in the app until it does. Logs: docker logs suite366-vllm-stt"
  fi
fi

# --- 3c. the embedding engine, where the profile has one ----------------------
# The same contract as the transcription engine: not a rollback condition, and
# what did not come up is left OUT of the chart and the database. Coming from
# orcasaq-batch the container does not exist and is created here; otherwise it
# is already running and `up` leaves it alone.
EMBED_SERVED=""
if [[ "$LLM_P_EMBED" == "1" ]]; then
  publish_state running "$TARGET" "starting the embedding engine ($(env_get EMBED_MODEL))"
  log "Starting suite366-vllm-embed ($(env_get EMBED_MODEL))"
  if ( cd "$LLM_DIR" && docker compose --profile embed up -d vllm-embed >/dev/null ); then
    embed_deadline=$(( $(date +%s) + 1200 ))
    while :; do
      health="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' suite366-vllm-embed 2>/dev/null || echo gone)"
      state="$(docker inspect -f '{{.State.Status}}' suite366-vllm-embed 2>/dev/null || echo gone)"
      if [[ "$health" == healthy ]]; then EMBED_SERVED="$(env_get EMBED_MODEL)"; break; fi
      if [[ "$state" != running ]]; then warn "embedding container state: $state"; break; fi
      if [[ "$(date +%s)" -ge "$embed_deadline" ]]; then warn "embedding engine still $health after 20 min"; break; fi
      publish_state running "$TARGET" "waiting for the embedding engine ($health)"
      sleep 10
    done
  else
    warn "docker compose could not start vllm-embed."
  fi
  if [[ -n "$EMBED_SERVED" ]]; then
    info "embedding engine healthy."
  else
    warn "The embedding engine did not come up; the generative model is unaffected."
    warn "  Document search stays OFF in the app until it does. Logs: docker logs suite366-vllm-embed"
  fi
fi

# --- 4. the chart values the app reads ----------------------------------------
# From here the engine is ALREADY serving the new model. A failure below must be
# reported with the command that finishes the job, never abort the script: dying
# here is what leaves the app pointing at a model nothing serves.
set +e
if [[ -f "$VALUES" ]]; then
  log "Updating $VALUES and rolling the release"
  # `#` as the delimiter, not `|`: the alternation below CONTAINS `|`, and with
  # `s|...|...|` sed reads it as the end of the pattern ("unknown option to `s'"'"'").
  # Found by running this script for real, after the engine had already switched.
  sed -i -E "s#^(\s*VLLM_MODEL_(HIGH|LIGHT|VISION):\s*).*#\1\"$LLM_P_MODEL\"#" "$VALUES" \
    || warn "could not rewrite VLLM_MODEL_* in $VALUES"
  sed -i -E "s#^(\s*VLLM_MAX_CONTEXT_WINDOW:\s*).*#\1\"$LLM_P_CONTEXT_WINDOW\"#" "$VALUES" \
    || warn "could not rewrite VLLM_MAX_CONTEXT_WINDOW in $VALUES"
  # Empty when the profile runs alone: the app then says "no embedding model"
  # (document indexing refuses cleanly) instead of 502s on /v1/embeddings.
  sed -i -E "s#^(\s*VLLM_MODEL_EMBEDDING:\s*).*#\1\"$EMBED_SERVED\"#" "$VALUES" \
    || warn "could not rewrite VLLM_MODEL_EMBEDDING in $VALUES"
  if grep -qE '^\s*VLLM_MODEL_TRANSCRIPTION:' "$VALUES"; then
    sed -i -E "s#^(\s*VLLM_MODEL_TRANSCRIPTION:\s*).*#\1\"$STT_SERVED\"#" "$VALUES" \
      || warn "could not rewrite VLLM_MODEL_TRANSCRIPTION in $VALUES"
  else
    # A box installed before transcription existed: give the app the key.
    sed -i -E "/^\s*VLLM_MODEL_EMBEDDING:/a\\  VLLM_MODEL_TRANSCRIPTION: \"$STT_SERVED\"" "$VALUES" \
      || warn "could not add VLLM_MODEL_TRANSCRIPTION to $VALUES"
  fi
  chart_version="$(helm list -n "$NAMESPACE" --filter "^${RELEASE}$" -o json 2>/dev/null \
    | sed -n 's/.*"chart":"[^"]*-\([0-9][^"]*\)".*/\1/p' | head -1 || true)"
  if [[ -n "$chart_version" ]]; then
    helm upgrade --install "$RELEASE" "$CHART_REF" --version "$chart_version" \
      --namespace "$NAMESPACE" -f "$VALUES" --wait --timeout 15m >/dev/null \
      || warn "helm upgrade failed — values.yaml is updated, re-run the upgrade by hand."
  else
    warn "Could not read the deployed chart version; values.yaml is updated but NOT applied."
    warn "  helm upgrade --install $RELEASE $CHART_REF --version <v> -n $NAMESPACE -f $VALUES"
  fi
else
  warn "$VALUES missing — the app's VLLM_MODEL_* were not updated."
fi

# --- 5. the rows every LLM call actually resolves -----------------------------
pg_deploy() {
  [[ -n "$PG_DEPLOY" ]] && { printf '%s' "$PG_DEPLOY"; return 0; }
  kc -n "$NAMESPACE" get deploy -o name 2>/dev/null \
    | sed -n 's|^deployment.apps/||p' | grep -- '-postgres$' | head -1 || true
}
log "Realigning the model ids stored in Postgres"
SQL_STT_MODEL="$STT_SERVED"
SQL_EMBED_MODEL="$EMBED_SERVED"
pg="$(pg_deploy)"
if [[ -z "$pg" ]]; then
  warn "No -postgres deployment found in ns $NAMESPACE — database NOT updated."
  warn "Every LLM call will 404 until AIModel.modelId names $LLM_P_MODEL."
else
  # stdin is redirected explicitly: `kubectl exec -i` reads the caller's stdin
  # and would swallow the rest of this script if it arrived through a pipe.
  # stderr is KEPT: a statement that fails (a constraint, a missing column after
  # a schema change) must be named, not reported as "could not reach Postgres".
  sql_err="$(mktemp)"
  out="$(build_sql | kc -n "$NAMESPACE" exec -i "deploy/$pg" -- \
          sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -tAq -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' 2>"$sql_err")" || out=""
  case "$out" in
    *no-table*) warn "No AIModel table yet (the app's migrations have not run) — nothing to realign." ;;
    aimodel=*)  info "database: $out" ;;
    "")         warn "Postgres realignment FAILED in deploy/$pg — database NOT updated."
                grep -vE '^command terminated' "$sql_err" | tail -3 | sed 's/^/      /' >&2
                warn "  Re-run: $0 $TARGET   (idempotent once the cause is fixed)" ;;
    *)          warn "Unexpected psql output: $out" ;;
  esac
  rm -f "$sql_err"
fi

# --- 6. warm the JIT so the first user does not pay for it --------------------
key="$(env_get VLLM_API_KEY)"; ip="$(env_get BIND_IP)"; port="$(env_get LLM_PORT)"
if [[ -n "$key" && -n "$ip" && -n "$port" ]]; then
  curl -fsS -m 180 "http://$ip:$port/v1/chat/completions" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$LLM_P_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":3}" \
    >/dev/null 2>&1 && info "warm-up ok." || warn "warm-up call failed (non-blocking)."
fi
if [[ -n "$STT_SERVED" && -n "$key" && -n "$ip" ]]; then
  # Two seconds of a 440 Hz tone through the real route: the transcript is
  # noise, the compiled kernels are what the first dictation would wait for.
  wav="$(mktemp --suffix=.wav)"
  python3 - "$wav" <<'PYW'
import math, struct, sys
sr = 16000; n = sr * 2
pcm = b''.join(struct.pack('<h', int(3000 * math.sin(2 * math.pi * 440 * i / sr))) for i in range(n))
hdr = (b'RIFF' + struct.pack('<I', 36 + len(pcm)) + b'WAVEfmt '
       + struct.pack('<IHHIIHH', 16, 1, 1, sr, sr * 2, 2, 16) + b'data' + struct.pack('<I', len(pcm)))
open(sys.argv[1], 'wb').write(hdr + pcm)
PYW
  curl -fsS -m 300 "http://$ip:$(env_get STT_PORT)/v1/audio/transcriptions" \
    -H "Authorization: Bearer $key" -F "model=$STT_SERVED" -F "file=@$wav;type=audio/wav" \
    >/dev/null 2>&1 && info "transcription warm-up ok." || warn "transcription warm-up failed (non-blocking)."
  rm -f "$wav"
fi

publish_state success "$TARGET" "now serving $LLM_P_MODEL${STT_SERVED:+ + $STT_SERVED for transcription}${EMBED_SERVED:+ + $EMBED_SERVED for embeddings}"
set -e
log "Now serving $LLM_P_MODEL ($TARGET)${STT_SERVED:+ with $STT_SERVED for transcription}${EMBED_SERVED:+ and $EMBED_SERVED for embeddings}."
[[ "$LLM_P_EMBED" == "1" ]] || info "The generative model runs alone: no document search and no transcription until another profile is switched to."
info "Check it end to end:  $0 status"
