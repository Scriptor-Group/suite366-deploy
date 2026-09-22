#!/usr/bin/env bash
# =============================================================================
# Suite 366 — switch the appliance's generative model.
#
# The appliance can serve three models (llm/profiles.sh). Switching is not just
# a model id: each needs its own image, its own share of the unified memory
# pool and its own vLLM flags, and the id itself lives in THREE places that
# must agree or the app breaks in a way nothing reports:
#
#   1. $DATA_DIR/llm/.env         what the vLLM container serves
#   2. $DATA_DIR/values.yaml      -> ConfigMap VLLM_MODEL_* the app reads
#   3. Postgres "AIModel"/"Agent" the rows every LLM call actually resolves
#
# Miss (3) and every call 404s with `docker ps` healthy and every pod Running —
# the same shape of failure as the API-key drift in lib/vllm-db.sh.
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
#
# Env overrides: DATA_DIR, NAMESPACE, RELEASE, CHART_REF, KUBECONFIG_PATH,
# PG_DEPLOY, VLLM_SYSCTL_FILE.
# =============================================================================
set -euo pipefail

DATA_DIR="${DATA_DIR:-/opt/suite366}"
NAMESPACE="${NAMESPACE:-suite366}"
RELEASE="${RELEASE:-drive}"
CHART_REF="${CHART_REF:-oci://ghcr.io/scriptor-group/chart/drive}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
VLLM_SYSCTL_FILE="${VLLM_SYSCTL_FILE:-/etc/sysctl.d/90-suite366-vllm.conf}"
PG_DEPLOY="${PG_DEPLOY:-}"
LLM_DIR="$DATA_DIR/llm"
ENV_FILE="$LLM_DIR/.env"
VALUES="$DATA_DIR/values.yaml"

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

[[ -f "$LLM_DIR/profiles.sh" ]] \
  || die "$LLM_DIR/profiles.sh missing — this box predates model profiles. Re-run install.sh."
# shellcheck disable=SC1091
source "$LLM_DIR/profiles.sh"

# --- what the box runs right now ---------------------------------------------
env_get() { # env_get KEY -> value from llm/.env, or empty
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | head -1
}
CUR_PROFILE="$(env_get LLM_PROFILE)"
CUR_MODEL="$(env_get LLM_MODEL)"
BASE_IMAGE="$(env_get VLLM_IMAGE)"
[[ -n "$BASE_IMAGE" ]] || die "VLLM_IMAGE missing from $ENV_FILE — is this an installed appliance?"
FLASH_NEXT_IMAGE="suite366/vllm-flash-next:${BASE_IMAGE##*:}-${FLASH_NEXT_PATCHES_COMMIT:-b002c8a}"

# Every model id the three profiles can produce: the scope of the Agent rewrite
# below. An agent pointed at OpenAI or Anthropic must not be touched.
all_profile_models() {
  local p
  for p in $LLM_PROFILES; do
    ( llm_profile_apply "$p" "$BASE_IMAGE" "$FLASH_NEXT_IMAGE" && printf '%s\n' "$LLM_P_MODEL" )
  done
}

case "$TARGET" in
  list)
    printf '%-12s %-34s %s\n' PROFILE MODEL NOTES
    for p in $LLM_PROFILES; do
      ( llm_profile_apply "$p" "$BASE_IMAGE" "$FLASH_NEXT_IMAGE"
        mark=' '; if [[ "$p" == "$CUR_PROFILE" ]]; then mark='*'; fi
        printf '%s%-11s %-34s %s\n' "$mark" "$p" "$LLM_P_MODEL" "$(llm_profile_summary "$p")" )
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
    exit 0 ;;
esac

llm_profile_known "$TARGET" || die "unknown profile '$TARGET'. Known: $LLM_PROFILES (see '$0 list')."
llm_profile_apply "$TARGET" "$BASE_IMAGE" "$FLASH_NEXT_IMAGE"

[[ "$DRY_RUN" == 1 || $EUID -eq 0 ]] || die "run me as root (docker, k3s and $DATA_DIR are root-only)."

log "Switching the generative model: ${CUR_PROFILE:-unknown} -> $TARGET"
info "model      $CUR_MODEL -> $LLM_P_MODEL"
info "image      $(env_get VLLM_LLM_IMAGE) -> $LLM_P_IMAGE"
info "budgets    util=$LLM_P_GPU_MEM_UTIL max_model_len=$LLM_P_MAX_MODEL_LEN slots=$LLM_P_MAX_NUM_SEQS"
info "app ctx    $LLM_P_CONTEXT_WINDOW tokens"
info "swappiness ${LLM_P_SWAPPINESS:-host default}"

if [[ "$CUR_PROFILE" == "$TARGET" && "$DRY_RUN" == 0 ]]; then
  info "Already on $TARGET — re-applying anyway (idempotent, recreates the container)."
fi

# --- the SQL, built once so --dry-run can show exactly what would run --------
# `\set` + `:'name'` so psql quotes the values; nothing here is user input, but
# a model id with a quote in it would otherwise be a syntax error at best.
build_sql() {
  local models_in="" m
  while IFS= read -r m; do
    if [[ -n "$m" ]]; then models_in+="$(printf "'%s'," "$m")"; fi
  done < <(all_profile_models)
  models_in="${models_in%,}"
  cat <<SQL
\set model '$LLM_P_MODEL'
\set ctx $LLM_P_CONTEXT_WINDOW
SELECT CASE WHEN to_regclass('"public"."AIModel"') IS NULL THEN 'off' ELSE 'on' END AS have_ai \gset
\if :have_ai
WITH m AS (
  UPDATE "public"."AIModel" SET "modelId" = :'model', "displayName" = :'model', "contextWindow" = :ctx
   WHERE "modelType" = 'LLM'
     AND "providerId" IN (SELECT id FROM "public"."AIProvider" WHERE provider = 'VLLM')
     AND ("modelId" IS DISTINCT FROM :'model' OR "contextWindow" IS DISTINCT FROM :ctx)
  RETURNING 1
), a AS (
  UPDATE "public"."Agent" SET model = :'model'
   WHERE model IN ($models_in) AND model IS DISTINCT FROM :'model'
  RETURNING 1
)
SELECT 'aimodel=' || (SELECT count(*) FROM m) || ' agent=' || (SELECT count(*) FROM a);
\else
\echo aimodel=no-table agent=no-table
\endif
SQL
}

if [[ "$DRY_RUN" == 1 ]]; then
  log "--dry-run: nothing will be changed"
  echo; info "llm/.env would become:"
  printf '      LLM_PROFILE=%s\n      LLM_MODEL=%s\n      VLLM_LLM_IMAGE=%s\n      LLM_GPU_MEM_UTIL=%s\n      LLM_MAX_MODEL_LEN=%s\n      LLM_MAX_NUM_SEQS=%s\n      LLM_MTP_TOKENS=%s\n' \
    "$TARGET" "$LLM_P_MODEL" "$LLM_P_IMAGE" "$LLM_P_GPU_MEM_UTIL" "$LLM_P_MAX_MODEL_LEN" "$LLM_P_MAX_NUM_SEQS" "$LLM_P_MTP_TOKENS"
  echo; info "values.yaml: VLLM_MODEL_{HIGH,LIGHT,VISION} -> $LLM_P_MODEL, VLLM_MAX_CONTEXT_WINDOW -> $LLM_P_CONTEXT_WINDOW"
  echo; info "SQL:"; build_sql | sed 's/^/      /'
  if [[ "$LLM_P_NEEDS_BUILD" == "1" ]]; then
    echo; info "image build: $LLM_P_IMAGE (from $BASE_IMAGE + llm/flash-next/)"
  fi
  exit 0
fi

export KUBECONFIG="$KUBECONFIG_PATH"
command -v docker >/dev/null || die "docker not found."
[[ -f "$LLM_DIR/docker-compose.yml" ]] || die "$LLM_DIR/docker-compose.yml missing."

# --- 1. the image this profile needs -----------------------------------------
if [[ "$LLM_P_NEEDS_BUILD" == "1" ]]; then
  if docker image inspect "$LLM_P_IMAGE" >/dev/null 2>&1; then
    info "image $LLM_P_IMAGE already built."
  else
    [[ -f "$LLM_DIR/flash-next/Dockerfile" ]] \
      || die "$LLM_DIR/flash-next/ missing — cannot build $LLM_P_IMAGE. Re-run install.sh."
    log "Building $LLM_P_IMAGE (~3 min)"
    docker pull -q "$BASE_IMAGE" >/dev/null || die "docker pull $BASE_IMAGE failed."
    docker build -q -t "$LLM_P_IMAGE" "$LLM_DIR/flash-next" >/dev/null \
      || die "docker build of $LLM_P_IMAGE failed."
  fi
elif ! docker image inspect "$LLM_P_IMAGE" >/dev/null 2>&1; then
  log "Pulling $LLM_P_IMAGE"
  docker pull -q "$LLM_P_IMAGE" >/dev/null || die "docker pull $LLM_P_IMAGE failed."
fi

# --- 2. .env, with the previous one kept for the rollback ---------------------
ENV_BACKUP="$(mktemp)"; cp "$ENV_FILE" "$ENV_BACKUP"
SYSCTL_WAS_PRESENT=0
if [[ -f "$VLLM_SYSCTL_FILE" ]]; then SYSCTL_WAS_PRESENT=1; fi

set_env() { # set_env KEY VALUE — replace in place, append when absent
  local k="$1" v="$2"
  if grep -q "^$k=" "$ENV_FILE" 2>/dev/null; then
    sed -i "s|^$k=.*|$k=$v|" "$ENV_FILE"
  else
    printf '%s=%s\n' "$k" "$v" >> "$ENV_FILE"
  fi
}
set_env LLM_PROFILE      "$TARGET"
set_env LLM_MODEL        "$LLM_P_MODEL"
set_env VLLM_LLM_IMAGE   "$LLM_P_IMAGE"
set_env LLM_GPU_MEM_UTIL "$LLM_P_GPU_MEM_UTIL"
set_env LLM_MAX_MODEL_LEN "$LLM_P_MAX_MODEL_LEN"
set_env LLM_MAX_NUM_SEQS "$LLM_P_MAX_NUM_SEQS"
set_env LLM_MTP_TOKENS   "$LLM_P_MTP_TOKENS"

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
  ( cd "$LLM_DIR" && docker compose up -d vllm-llm >/dev/null 2>&1 ) || true
  die "The $TARGET engine did not come up. The chart and the database were NOT touched, so the box is back where it started. Logs: docker logs suite366-vllm-llm"
}

# --- 3. bring the new engine up, and wait for it ------------------------------
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
  sleep 10
done
info "engine healthy."
rm -f "$ENV_BACKUP"

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
log "Realigning the model id stored in Postgres"
pg="$(pg_deploy)"
if [[ -z "$pg" ]]; then
  warn "No -postgres deployment found in ns $NAMESPACE — database NOT updated."
  warn "Every LLM call will 404 until AIModel.modelId names $LLM_P_MODEL."
else
  # stdin is redirected explicitly: `kubectl exec -i` reads the caller's stdin
  # and would swallow the rest of this script if it arrived through a pipe.
  out="$(build_sql | kc -n "$NAMESPACE" exec -i "deploy/$pg" -- \
          sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -tAq -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' 2>/dev/null)" || out=""
  case "$out" in
    *no-table*) warn "No AIModel table yet (the app's migrations have not run) — nothing to realign." ;;
    aimodel=*)  info "database: $out" ;;
    "")         warn "Could not reach Postgres in deploy/$pg — database NOT updated." ;;
    *)          warn "Unexpected psql output: $out" ;;
  esac
fi

# --- 6. warm the JIT so the first user does not pay for it --------------------
key="$(env_get VLLM_API_KEY)"; ip="$(env_get BIND_IP)"; port="$(env_get LLM_PORT)"
if [[ -n "$key" && -n "$ip" && -n "$port" ]]; then
  curl -fsS -m 180 "http://$ip:$port/v1/chat/completions" \
    -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$LLM_P_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":3}" \
    >/dev/null 2>&1 && info "warm-up ok." || warn "warm-up call failed (non-blocking)."
fi

set -e
log "Now serving $LLM_P_MODEL ($TARGET)."
info "Check it end to end:  $0 status"
