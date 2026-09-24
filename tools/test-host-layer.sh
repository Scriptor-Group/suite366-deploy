#!/usr/bin/env bash
# =============================================================================
# Self-test of the host layer — no hardware, no Docker, no root.
#
# What it guards:
#   • host-layer.sh is what tools/bundle-host-layer.sh produces from this tree
#     (a stale committed copy would be signed and shipped), and unpacks to the
#     very files it was built from, with the installer's modes;
#   • `switch-model.sh converge` turns a July 2026 box (LLM_MODEL, no profile,
#     no cache dir, no transcription keys, base image already moved to v0.29.0
#     by the channel) into a profile-driven one WITHOUT moving its model: Gemma
#     keeps its pinned nightly, tuned budgets are kept, missing keys get the
#     installer's defaults, the transcription container is taken down, the
#     proxy is reloaded, the units are rewritten;
#   • update.sh's in-place values.yaml patch adds every missing app <-> host
#     bridge, is idempotent, and leaves a current file untouched;
#   • a missing stamp shows up as an update — only on a box with a vLLM stack.
# =============================================================================
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()      { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
ko()      { printf '  \033[31mKO\033[0m   %s\n' "$1"; FAIL=$((FAIL+1)); }
check()   { if [[ "$2" == "$3" ]]; then ok "$1"; else ko "$1 (attendu '$3', obtenu '$2')"; fi; }
contains(){ case "$2" in *"$3"*) ok "$1" ;; *) ko "$1 (absent : $3)" ;; esac; }
absent()  { case "$2" in *"$3"*) ko "$1 (présent alors qu'il ne devrait pas : $3)" ;; *) ok "$1" ;; esac; }
head_()   { printf '\n== %s ==\n' "$1"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

# --- 1. le bundle ---------------------------------------------------------------
head_ "host-layer.sh"
if "$REPO_ROOT/tools/bundle-host-layer.sh" --stdout | cmp -s - "$REPO_ROOT/host-layer.sh"; then
  ok "host-layer.sh est à jour (régénération identique octet pour octet)"
else
  ko "host-layer.sh est PÉRIMÉ — lance tools/bundle-host-layer.sh et committe le résultat"
fi
X="$WORK/extract"; bash "$REPO_ROOT/host-layer.sh" extract "$X" >/dev/null 2>&1 || ko "extract a échoué"
n=0; bad=0
while IFS= read -r f; do
  n=$((n+1)); cmp -s "$REPO_ROOT/$f" "$X/$f" || { bad=$((bad+1)); ko "contenu différent : $f"; }
done < <(bash "$REPO_ROOT/host-layer.sh" list)
[[ "$bad" == 0 ]] && ok "les $n fichiers extraits sont identiques aux sources"
check "switch-model.sh est root-only (750)" "$(stat -c %a "$X/switch-model.sh")" "750"
check "serve-llm.sh est exécutable (755)"   "$(stat -c %a "$X/llm/serve-llm.sh")" "755"
check "profiles.sh est une donnée (644)"     "$(stat -c %a "$X/llm/profiles.sh")" "644"
contains "le bundle embarque le contexte Flash-Next" "$(bash "$REPO_ROOT/host-layer.sh" list)" "llm/flash-next/Dockerfile"
contains "le bundle embarque le contexte STT"        "$(bash "$REPO_ROOT/host-layer.sh" list)" "llm/stt/Dockerfile"
absent   "le bundle ne transporte pas de doc"        "$(bash "$REPO_ROOT/host-layer.sh" list)" "README"

# --- 2. converge sur une box de juillet ----------------------------------------------
head_ "switch-model.sh converge (box de juillet 2026)"
STUB="$WORK/stub"; mkdir -p "$STUB"
cat > "$STUB/docker" <<'STUBEOF'
#!/bin/bash
echo "docker $*" >> "$DOCKER_LOG"
case "$1 $2" in
  "inspect -f")
    # health / state / image for any container; healthy so the waits return at once
    case "$3" in
      *Health*) echo healthy ;;
      *Status*) echo running ;;
      *) echo "img" ;;
    esac ;;
  "image inspect") exit 0 ;;      # every image is present: no build, no pull
  "compose "*) exit 0 ;;
  "exec "*) exit 0 ;;
  *) exit 0 ;;
esac
STUBEOF
printf '#!/bin/bash\necho "systemctl $*" >> "$DOCKER_LOG"; exit 0\n' > "$STUB/systemctl"
printf '#!/bin/bash\nexit 0\n' > "$STUB/sysctl"
chmod +x "$STUB"/*
mkbox() { # mkbox DIR MODEL [EXTRA_ENV_LINES]
  local box="$1"; mkdir -p "$box/llm"
  bash "$REPO_ROOT/host-layer.sh" extract "$box" >/dev/null
  cat > "$box/llm/.env" <<ENV
VLLM_IMAGE=vllm/vllm-openai:v0.29.0
PROXY_IMAGE=nginx:1.31-alpine
HF_TOKEN=
VLLM_API_KEY=sk-test
MODELS_DIR=$box/models
BIND_IP=10.99.0.1
LLM_MODEL=$2
EMBED_MODEL=Qwen/Qwen3-VL-Embedding-8B
LLM_PORT=8001
EMBED_PORT=8002
PROXY_PORT=8000
LLM_GPU_MEM_UTIL=0.55
EMBED_GPU_MEM_UTIL=0.30
LLM_MAX_NUM_SEQS=2
LLM_MAX_MODEL_LEN=262144
EMBED_MAX_MODEL_LEN=8192
${3:-}
ENV
  mkdir -p "$box/models/hub"
}
conv() { # conv BOX -> output
  DOCKER_LOG="$1/docker.log" PATH="$STUB:$PATH" DATA_DIR="$1" SYSTEMD_DIR="$1/systemd" \
  VLLM_SYSCTL_FILE="$1/sysctl.conf" LLM_STATE_DIR="$1/llm-state" SWITCH_MODEL_SELFTEST=1 \
    bash "$1/switch-model.sh" converge 2>&1
}
envv() { sed -n "s/^$2=//p" "$1/llm/.env" | head -1; }

BOX="$WORK/gemma-box"; mkbox "$BOX" nvidia/Gemma-4-26B-A4B-NVFP4; mkdir -p "$BOX/systemd"
out="$(conv "$BOX")"; rc=$?
check "converge sort en 0"                          "$rc" "0"
contains "reconnaît le profil d'après le modèle"    "$out" "profile for nvidia/Gemma-4-26B-A4B-NVFP4: gemma"
check ".env : LLM_PROFILE posé"                     "$(envv "$BOX" LLM_PROFILE)" "gemma"
# Le piège que ce test existe pour attraper : le canal a déplacé VLLM_IMAGE sur
# v0.29.0 et l'ancien compose y aurait entraîné Gemma. Le profil le garde épinglé.
check ".env : Gemma reste sur sa nightly épinglée"  "$(envv "$BOX" VLLM_LLM_IMAGE)" "vllm/vllm-openai:cu130-nightly"
check ".env : la base reste celle du canal"         "$(envv "$BOX" VLLM_IMAGE)" "vllm/vllm-openai:v0.29.0"
check ".env : budget réglé conservé"                "$(envv "$BOX" LLM_GPU_MEM_UTIL)" "0.55"
check ".env : budget embed conservé"                "$(envv "$BOX" EMBED_GPU_MEM_UTIL)" "0.30"
check ".env : CACHE_DIR par défaut"                 "$(envv "$BOX" CACHE_DIR)" "$BOX/cache"
check ".env : pas de tête MTP pour Gemma"           "$(envv "$BOX" LLM_MTP_TOKENS)" ""
check ".env : pas de transcription pour Gemma"      "$(envv "$BOX" STT_MODEL)" ""
check ".env : profil compose stt désactivé"         "$(envv "$BOX" COMPOSE_PROFILES)" ""
check ".env : STT_PORT par défaut"                  "$(envv "$BOX" STT_PORT)" "8003"
if [[ -d "$BOX/cache/vllm" && -d "$BOX/cache/flashinfer" && -d "$BOX/cache/triton" ]]; then ok "caches JIT créés"; else ko "caches JIT créés"; fi
D="$(cat "$BOX/docker.log")"
contains "conteneur STT retiré (le profil n'en a pas)"  "$D" "docker compose --profile stt rm -sf vllm-stt"
contains "compose up -d (recrée ce qui a changé)"       "$D" "docker compose up -d"
absent   "pas de --force-recreate (rien d'inutile)"     "$D" "force-recreate"
contains "proxy rechargé"                               "$D" "docker exec suite366-vllm-proxy nginx -s reload"
contains "daemon-reload après les unités"               "$D" "systemctl daemon-reload"
U="$(cat "$BOX/systemd/suite366-vllm.service" 2>/dev/null)"
contains "unité vLLM réécrite avec le rafraîchissement CDI" "$U" "ExecStartPre=-/usr/bin/nvidia-ctk cdi generate"
contains "unité vLLM : WorkingDirectory de la box"          "$U" "WorkingDirectory=$BOX/llm"
if [[ -f "$BOX/systemd/suite366-llm-switch.path" ]]; then ok "unité .path du déclencheur écrite"; else ko "unité .path du déclencheur écrite"; fi
ST="$BOX/llm-state/state.json"
if python3 -m json.tool "$ST" >/dev/null 2>&1; then ok "state.json publié et valide"; else ko "state.json publié et valide"; fi
check "state : profil actif gemma" "$(python3 -c "import json;print(json.load(open('$ST'))['active'])")" "gemma"
check "state : bascule au repos"   "$(python3 -c "import json;print(json.load(open('$ST'))['switch']['status'])")" "idle"
# Idempotent : une seconde passe n'écrit rien dans .env.
env1="$(cat "$BOX/llm/.env")"; out2="$(conv "$BOX")"
check "seconde passe : .env inchangé"  "$(cat "$BOX/llm/.env")" "$env1"
contains "seconde passe : 0 clé écrite" "$out2" ".env: 0 key(s) written"

BOX2="$WORK/qwen-box"; mkbox "$BOX2" nvidia/Qwen3.8-27B-NVFP4; mkdir -p "$BOX2/systemd"
out="$(conv "$BOX2")"
check "qwen27b : profil reconnu"            "$(envv "$BOX2" LLM_PROFILE)" "qwen27b"
check "qwen27b : image = la base"           "$(envv "$BOX2" VLLM_LLM_IMAGE)" "vllm/vllm-openai:v0.29.0"
check "qwen27b : transcription activée"     "$(envv "$BOX2" STT_MODEL)" "Qwen/Qwen3-ASR-1.7B"
check "qwen27b : profil compose stt"        "$(envv "$BOX2" COMPOSE_PROFILES)" "stt"
check "qwen27b : tête MTP à 3"              "$(envv "$BOX2" LLM_MTP_TOKENS)" "3"
absent "qwen27b : le conteneur STT n'est pas retiré" "$(cat "$BOX2/docker.log")" "rm -sf vllm-stt"

BOX3="$WORK/custom-box"; mkbox "$BOX3" someone/Custom-Model; mkdir -p "$BOX3/systemd"
out="$(conv "$BOX3")"; rc=$?
check "modèle inconnu : sort en 0 sans casser"   "$rc" "0"
contains "modèle inconnu : le dit et n'invente rien" "$out" "no profile serves 'someone/Custom-Model'"
check "modèle inconnu : .env sans LLM_PROFILE"   "$(envv "$BOX3" LLM_PROFILE)" ""
absent "modèle inconnu : aucun compose up"       "$(cat "$BOX3/docker.log" 2>/dev/null)" "compose up"
if [[ -f "$BOX3/systemd/suite366-vllm.service" ]]; then ok "modèle inconnu : l'unité est quand même réécrite"; else ko "modèle inconnu : l'unité est quand même réécrite"; fi

# --- 3. values.yaml : les ponts, en place ---------------------------------------------
head_ "update.sh ensure_appliance_values"
vals_run() { # vals_run BOX -> rc ; output in $VOUT
  VOUT="$(bash -c '
    set -uo pipefail
    info() { printf "    %s\n" "$*"; }; warn() { printf "!!  %s\n" "$*"; }
    have() { command -v "$1" >/dev/null 2>&1; }
    DATA_DIR="$1"; APP_GID=1001; cur_app=1.11.8; want_app=""
    for f in detect_stt_model ensure_appliance_values; do eval "$(sed -n "/^$f() {/,/^}/p" "$2")"; done
    ensure_appliance_values ${3:-}
  ' _ "$1" "$REPO_ROOT/update.sh" "${2:-}" 2>&1)"
}
JULY="$WORK/july"; mkdir -p "$JULY/llm"
cat > "$JULY/values.yaml" <<'Y'
image:
  tag: "1.8.22"
config:
  NODE_ENV: "production"
  VLLM_BASE_URL: "http://10.99.0.1:8000/v1"
  VLLM_MODEL_HIGH: "nvidia/Gemma-4-26B-A4B-NVFP4"
  VLLM_MODEL_EMBEDDING: "Qwen/Qwen3-VL-Embedding-8B"
  VLLM_MAX_CONTEXT_WINDOW: "200000"

sandbox:
  enabled: true
  namespace: sandbox
  createNamespace: false
  api:
    image: ghcr.io/scriptor-group/suite-366-sandbox-api:1.8.22
    pullPolicy: IfNotPresent
  runnerImage: ghcr.io/scriptor-group/suite-366-sandbox-runner:1.8.22

ingress:
  enabled: true
Y
cp "$BOX/llm/.env" "$JULY/llm/.env"; cp "$REPO_ROOT/llm/profiles.sh" "$JULY/llm/profiles.sh"
# --check d'abord : dit qu'il y a à faire, n'écrit RIEN — c'est ce que `check` publie comme mise à jour.
j0="$(cat "$JULY/values.yaml")"; vals_run "$JULY" --check; rc=$?
check "juillet --check : annonce un changement (rc 0)" "$rc" "0"
check "juillet --check : n'écrit rien"                 "$(cat "$JULY/values.yaml")" "$j0"
if [[ -d "$JULY/llm-state" ]]; then ko "juillet --check : ne crée pas les répertoires"; else ok "juillet --check : ne crée pas les répertoires"; fi
vals_run "$JULY"; rc=$?
check "juillet : signale un changement (rc 0)" "$rc" "0"
V="$(cat "$JULY/values.yaml")"
for b in APPLIANCE_UPDATE_DIR SUPPORT_ACCESS_DIR APPLIANCE_BACKUP_DIR APPLIANCE_LLM_DIR APPLIANCE_REMOTE_DIR; do
  contains "juillet : env $b" "$V" "name: $b"
done
for m in appliance-update support-access appliance-backup appliance-llm appliance-remote; do
  contains "juillet : montage + volume $m" "$V" "- name: $m"
done
contains "juillet : hostPath sous DATA_DIR"           "$V" "path: $JULY/llm-state"
contains "juillet : VLLM_MODEL_TRANSCRIPTION vide (Gemma)" "$V" 'VLLM_MODEL_TRANSCRIPTION: ""'
# Insérée dans le bloc config, juste après l'embedding, pas en fin de fichier.
check "juillet : la clé suit VLLM_MODEL_EMBEDDING" "$(grep -A1 'VLLM_MODEL_EMBEDDING' "$JULY/values.yaml" | tail -1 | sed 's/ *$//')" '  VLLM_MODEL_TRANSCRIPTION: ""'
for d in updates support backup remote llm-state; do [[ -d "$JULY/$d" ]] || ko "répertoire de pont $d créé"; done; ok "répertoires de pont créés"
# Le workbench : le bloc entier, épinglé sur la version d'app installée, sous sandbox.
contains "juillet : bloc workbench ajouté"           "$V" "  workbench:"
contains "juillet : workbench activé"                "$V" "    enabled: true"
contains "juillet : runner épinglé sur l'app"        "$V" "suite-366-workbench-runner:1.11.8"
contains "juillet : quota du gabarit"                "$V" 'requestsStorage: "300Gi"'
# Les deux délais d'inactivité, CITÉS : Helm 3.21.1 rend 1800000 en "1.8e+06" et parseInt en fait 1 ms.
contains "juillet : sandbox.limits.idleTimeoutMs cité"      "$V" '    idleTimeoutMs: "1800000"'
contains "juillet : workbench.limits.idleStopMs cité"       "$V" '      idleStopMs: "7200000"'
check    "juillet : un seul bloc limits sous sandbox"       "$(grep -c '^  limits:' "$JULY/values.yaml")" "1"
check "juillet : le bloc suit runnerImage, sous sandbox" "$(grep -A1 'suite-366-sandbox-runner' "$JULY/values.yaml" | tail -1)" "  workbench:"
absent "juillet : l'ingress qui suit n'a pas bougé de place" "$(sed -n '/^ingress:/,$p' "$JULY/values.yaml")" "workbench"
if python3 -c "import yaml" 2>/dev/null; then
  if python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); assert len(d['extraEnv'])==5 and len(d['extraVolumes'])==5 and len(d['extraVolumeMounts'])==5; assert d['sandbox']['workbench']['enabled'] is True and d['sandbox']['workbench']['resourceQuota']['pods']=='10' and d['sandbox']['enabled'] is True; assert d['sandbox']['limits']['idleTimeoutMs']=='1800000' and d['sandbox']['workbench']['limits']['idleStopMs']=='7200000'" "$JULY/values.yaml" 2>/dev/null; then ok "juillet : YAML valide, 5 ponts par liste, workbench sous sandbox, délais en chaînes"; else ko "juillet : YAML valide, 5 ponts par liste, workbench sous sandbox, délais en chaînes"; fi
else
  ok "juillet : (PyYAML absent — validation structurelle sautée)"
fi
v1="$(cat "$JULY/values.yaml")"; vals_run "$JULY"; rc=$?
check "juillet : seconde passe sans changement (rc 1)" "$rc" "1"
check "juillet : seconde passe, fichier identique"     "$(cat "$JULY/values.yaml")" "$v1"

SEP="$WORK/sep"; mkdir -p "$SEP/llm"; cp "$BOX2/llm/.env" "$SEP/llm/.env"; cp "$REPO_ROOT/llm/profiles.sh" "$SEP/llm/profiles.sh"
cat > "$SEP/values.yaml" <<'Y'
config:
  VLLM_MODEL_EMBEDDING: "Qwen/Qwen3-VL-Embedding-8B"
extraEnv:
  - name: APPLIANCE_UPDATE_DIR
    value: /appliance-update
extraVolumeMounts:
  - name: appliance-update
    mountPath: /appliance-update
extraVolumes:
  - name: appliance-update
    hostPath:
      path: /opt/suite366/updates
      type: DirectoryOrCreate
Y
touch "$SEP/values-appliance-update.yaml"
vals_run "$SEP"
V="$(cat "$SEP/values.yaml")"
check "pont update déjà là : non dupliqué" "$(grep -c 'name: APPLIANCE_UPDATE_DIR' "$SEP/values.yaml")" "1"
contains "les quatre autres ajoutés"        "$V" "name: APPLIANCE_LLM_DIR"
contains "qwen27b : VLLM_MODEL_TRANSCRIPTION suit le profil" "$V" 'VLLM_MODEL_TRANSCRIPTION: "Qwen/Qwen3-ASR-1.7B"'
if [[ ! -f "$SEP/values-appliance-update.yaml" ]]; then ok "overlay legacy supprimé (replié dans values.yaml)"; else ko "overlay legacy supprimé"; fi
contains "…et dit qu'il l'a fait" "$VOUT" "overlay removed"

# Un admin qui a ÉTEINT le workbench le garde éteint : présent = pas touché.
OFF="$WORK/off"; mkdir -p "$OFF/llm"; cp "$BOX/llm/.env" "$OFF/llm/.env"; cp "$REPO_ROOT/llm/profiles.sh" "$OFF/llm/profiles.sh"
cat > "$OFF/values.yaml" <<'Y'
config:
  VLLM_MODEL_EMBEDDING: "e"
sandbox:
  enabled: true
  runnerImage: ghcr.io/scriptor-group/suite-366-sandbox-runner:1.11.7
  workbench:
    enabled: false
    runnerImage: ghcr.io/scriptor-group/suite-366-workbench-runner:1.11.7
Y
vals_run "$OFF"
check "workbench éteint par l'admin : un seul bloc"  "$(grep -c '^  workbench:' "$OFF/values.yaml")" "1"
contains "workbench éteint par l'admin : reste éteint" "$(cat "$OFF/values.yaml")" "    enabled: false"
absent   "workbench éteint par l'admin : pas de quota injecté" "$(cat "$OFF/values.yaml")" "resourceQuota"

# Un admin qui a déjà réglé les délais garde ses valeurs, même non citées.
TUNED="$WORK/tuned"; mkdir -p "$TUNED/llm"; cp "$BOX/llm/.env" "$TUNED/llm/.env"; cp "$REPO_ROOT/llm/profiles.sh" "$TUNED/llm/profiles.sh"
cat > "$TUNED/values.yaml" <<'Y'
config:
  VLLM_MODEL_EMBEDDING: "e"
  VLLM_MODEL_TRANSCRIPTION: ""
sandbox:
  enabled: true
  limits:
    idleTimeoutMs: 900000
  workbench:
    enabled: true
    limits:
      idleStopMs: 3600000
Y
vals_run "$TUNED"
check "délais réglés : idleTimeoutMs conservé" "$(grep -c 'idleTimeoutMs: 900000' "$TUNED/values.yaml")" "1"
check "délais réglés : idleStopMs conservé"    "$(grep -c 'idleStopMs: 3600000' "$TUNED/values.yaml")" "1"
check "délais réglés : pas de doublon"          "$(grep -c 'idleStopMs' "$TUNED/values.yaml")" "1"

CUR="$WORK/current"; mkdir -p "$CUR/llm"; cp "$BOX2/llm/.env" "$CUR/llm/.env"; cp "$REPO_ROOT/llm/profiles.sh" "$CUR/llm/profiles.sh"
sed "s#@DATA_DIR@#$CUR#g" "$REPO_ROOT/tools/testdata/values-plain.rendered.yaml" > "$CUR/values.yaml"
c0="$(cat "$CUR/values.yaml")"; vals_run "$CUR"; rc=$?
check "un values.yaml courant : rien à faire (rc 1)" "$rc" "1"
vals_run "$CUR" --check; check "un values.yaml courant --check : rien à annoncer (rc 1)" "$?" "1"
check "un values.yaml courant : intact"              "$(cat "$CUR/values.yaml")" "$c0"

# --- 4. la décision « mise à jour disponible » -------------------------------------------
head_ "update.sh compute_diffs (couche hôte)"
diffs() { # diffs HOST_APPLICABLE CUR_HOST WANT_HOST
  bash -c '
    set -uo pipefail
    info() { :; }; warn() { :; }
    UPDATE_SOURCE=online; channel=stable
    cur_chart=0.10.0; want_chart=0.10.0; cur_app=1.11.7; want_app=1.11.7; cur_vllm=img; want_vllm=img
    host_applicable="$1"; cur_host="$2"; want_host="$3"
    for f in ver_gt compute_diffs up_to_date; do eval "$(sed -n "/^$f() {/,/^}/p" "$4")"; done
    compute_diffs >/dev/null 2>&1
    if up_to_date; then u=up-to-date; else u=update; fi
    printf "%s %s %s\n" "$host_diff" "$u" "${summary_line:-<none>}"
  ' _ "$1" "$2" "$3" "$REPO_ROOT/update.sh" 2>&1
}
out="$(diffs 1 "" abc123def456)";  check "box sans stamp : la couche hôte est une mise à jour" "${out%% *}" "1"
contains "…et le résumé le dit"     "$out" "host layer (model switch, transcription) -> abc123def456"
out="$(diffs 1 abc123def456 abc123def456)"; check "stamp = canal : rien" "${out%% *}" "0"
contains "…et la box est à jour"    "$out" "up-to-date"
out="$(diffs 1 old000000000 abc123def456)"; check "stamp différent : mise à jour" "${out%% *}" "1"
out="$(diffs 0 "" abc123def456)";  check "box SKIP_VLLM : jamais concernée" "${out%% *}" "0"
out="$(diffs 1 "" "")";            check "canal sans host_layer_sha256 : rien à proposer" "${out%% *}" "0"
# La dérive de values.yaml est une mise à jour à part entière : bouton Appliquer dans l'UI.
vdiff() { # vdiff RC — the stubbed `ensure_appliance_values --check` returns RC: 0 = would change, 1 = nothing
  bash -c '
    set -uo pipefail
    info() { :; }; warn() { :; }
    UPDATE_SOURCE=online; channel=stable
    cur_chart=0.10.0; want_chart=0.10.0; cur_app=1.11.8; want_app=1.11.8; cur_vllm=img; want_vllm=img
    host_applicable=1; cur_host=a; want_host=a
    ensure_appliance_values() { [[ "$1" == "--check" ]] && return '"$1"'; return 1; }
    for f in ver_gt compute_diffs up_to_date; do eval "$(sed -n "/^$f() {/,/^}/p" "$2")"; done
    compute_diffs >/dev/null 2>&1
    if up_to_date; then u=up-to-date; else u=update; fi
    printf "%s %s %s
" "$values_diff" "$u" "${summary_line:-<none>}"
  ' _ "$1" "$REPO_ROOT/update.sh" 2>&1
}
out="$(vdiff 1)"; check "values.yaml à jour : pas une mise à jour"  "${out%% *}" "0"
contains "…et la box est à jour" "$out" "up-to-date"
out="$(vdiff 0)"; check "values.yaml en retard : mise à jour"      "${out%% *}" "1"
contains "…nommée pour l'admin" "$out" "configuration (values.yaml: bridges, workbench)"

# --- 5. sandbox-api suit la ConfigMap convergée ------------------------------------------
head_ "update.sh restart_sandbox_api"
U="$(cat "$REPO_ROOT/update.sh")"
contains "la fonction existe"                         "$U" "restart_sandbox_api() {"
check    "appelée après CHAQUE roll de values.yaml"   "$(grep -c '^\s*if \[\[ "\$values_changed" == 1 \]\]; then restart_sandbox_api; fi\|^\s*restart_sandbox_api$' "$REPO_ROOT/update.sh")" "2"
# Le namespace vient du bloc sandbox de values.yaml, pas d'un autre `namespace:`.
NSBOX="$WORK/ns"; mkdir -p "$NSBOX"; printf 'other:\n  namespace: wrong\nsandbox:\n  enabled: true\n  namespace: sbx\n' > "$NSBOX/values.yaml"
ns="$(DATA_DIR="$NSBOX" bash -c 'eval "$(sed -n "/^restart_sandbox_api() {/,/^}/p" "$1")"; awk "/^sandbox:/{f=1;next} f&&/^[a-z]/{f=0} f&&/^  namespace:/{print \$2; exit}" "$DATA_DIR/values.yaml"' _ "$REPO_ROOT/update.sh")"
check    "lit le namespace sous sandbox: (pas le premier venu)" "$ns" "sbx"

# --- 6. l'updater se rafraîchit EN PREMIER ----------------------------------------
head_ "update.sh self_update_first"
contains "check : rafraîchissement avant survey"  "$(awk '/^  check\)/,/;;/' "$REPO_ROOT/update.sh" | tr -s ' \n' ' ')" "fetch_manifest_online || true load_offline_source self_update_first survey"
contains "apply : rafraîchissement avant survey"  "$(awk '/^  apply\)/,/;;/' "$REPO_ROOT/update.sh" | tr -s ' \n' ' ')" "fetch_manifest_online || true load_offline_source self_update_first survey"
RX="$WORK/reexec"; mkdir -p "$RX"; printf '#!/bin/bash\necho OLD\n' > "$RX/update.sh"; chmod +x "$RX/update.sh"
out="$(bash -c '
  set -uo pipefail
  info() { :; }
  DATA_DIR="$1"; SELF_UPDATE=1; online_reachable=1; ORIG_ARGS=(check --flag)
  self_update() { printf "#!/bin/bash\necho NEW-UPDATER args=[\$*] reexec=\${SUITE366_UPDATER_REEXEC:-0}\n" > "$DATA_DIR/update.sh"; chmod +x "$DATA_DIR/update.sh"; }
  eval "$(sed -n "/^self_update_first() {/,/^}/p" "$2")"
  self_update_first
  echo "NOT-REEXECED"
' _ "$RX" "$REPO_ROOT/update.sh" 2>&1)"
contains "un updater plus récent est relancé avec les mêmes arguments" "$out" "NEW-UPDATER args=[check --flag] reexec=1"
absent   "…et l'ancien ne continue pas"                               "$out" "NOT-REEXECED"
out="$(bash -c '
  set -uo pipefail
  info() { :; }
  DATA_DIR="$1"; SELF_UPDATE=1; online_reachable=1; ORIG_ARGS=(check)
  self_update() { :; }
  eval "$(sed -n "/^self_update_first() {/,/^}/p" "$2")"
  self_update_first; echo "CONTINUES"
' _ "$RX" "$REPO_ROOT/update.sh" 2>&1)"
contains "updater déjà à jour : on continue sans relance" "$out" "CONTINUES"
out="$(SUITE366_UPDATER_REEXEC=1 bash -c '
  set -uo pipefail
  info() { :; }
  DATA_DIR="$1"; SELF_UPDATE=1; online_reachable=1; ORIG_ARGS=(check)
  self_update() { printf "#!/bin/bash\necho LOOP\n" > "$DATA_DIR/update.sh"; }
  eval "$(sed -n "/^self_update_first() {/,/^}/p" "$2")"
  self_update_first; echo "GUARDED"
' _ "$RX" "$REPO_ROOT/update.sh" 2>&1)"
contains "le marqueur d'environnement coupe toute boucle" "$out" "GUARDED"
absent   "…pas de seconde relance"                        "$out" "LOOP"

printf '\n%d ok, %d KO\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
