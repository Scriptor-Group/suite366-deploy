#!/usr/bin/env bash
# =============================================================================
# Self-test of the model-profile machinery — no hardware, no network, no Docker.
#
# What it actually guards:
#   • the four profiles resolve to the model, image and budgets that were
#     measured, and nothing silently shares a value it should not;
#   • llm/serve-llm.sh builds the right flag set per profile, and refuses an
#     unknown one instead of serving something arbitrary;
#   • switch-model.sh reads a box's state, rejects a bad profile, and its
#     --dry-run tells the truth about the three places a model id lives;
#   • the SQL it would run touches the LLM row and the three known agents, and
#     never the embedding row;
#   • the transcription model rides along with the profiles that have the room
#     (qwen27b, orcasaq, gemma), through a compose profile, a lazily resolved
#     nginx route and its own AIModel row — and a profile without one
#     (flash-next) turns all of that off rather than leaving it half on;
#   • the two profiles that build an image name their build context, and the
#     EXL3 context pins every third-party input by content.
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

BASE=vllm/vllm-openai:v0.29.0
FLASH=suite366/vllm-flash-next:v0.29.0-b002c8a
STT=suite366/vllm-stt:v0.29.0-r1
EXL3=suite366/vllm-exl3:v0.29.0-r1
STT_MODEL=Qwen/Qwen3-ASR-1.7B

# --- 1. la table de profils ---------------------------------------------------
head_ "llm/profiles.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/llm/profiles.sh"

check "les quatre profils sont déclarés" "$LLM_PROFILES" "qwen27b orcasaq flash-next gemma"
for p in qwen27b orcasaq flash-next gemma; do
  if llm_profile_known "$p"; then ok "profil connu : $p"; else ko "profil connu : $p"; fi
done
if llm_profile_known nope; then ko "un profil inconnu est refusé"; else ok "un profil inconnu est refusé"; fi

llm_profile_apply qwen27b "$BASE" "$FLASH"
check "qwen27b : modèle"        "$LLM_P_MODEL"          "nvidia/Qwen3.8-27B-NVFP4"
check "qwen27b : image de base" "$LLM_P_IMAGE"          "$BASE"
check "qwen27b : fraction"      "$LLM_P_GPU_MEM_UTIL"   "0.45"
check "qwen27b : contexte app"  "$LLM_P_CONTEXT_WINDOW" "200000"
check "qwen27b : pas de build"  "$LLM_P_NEEDS_BUILD"    "0"
check "qwen27b : swappiness hôte" "$LLM_P_SWAPPINESS"   ""
check "qwen27b : transcription Qwen3-ASR" "$LLM_P_STT_MODEL" "$STT_MODEL"

llm_profile_apply orcasaq "$BASE" "$FLASH"
check "orcasaq : modèle"        "$LLM_P_MODEL"          "orcarouter/OrcaSAQ-2-27B"
# L'image porte la base ET la révision du contexte : l'une ou l'autre bouge, la box reconstruit.
check "orcasaq : image EXL3 construite sur la box" "$LLM_P_IMAGE" "$EXL3"
check "orcasaq : build requis"  "$LLM_P_NEEDS_BUILD"    "1"
check "orcasaq : contexte de build llm/exl3" "$LLM_P_BUILD_DIR" "exl3"
check "orcasaq : contexte app"  "$LLM_P_CONTEXT_WINDOW" "200000"
# 0.30 ne logeait pas UNE requête de 262k une fois l'embed compté dans la part.
check "orcasaq : fraction"      "$LLM_P_GPU_MEM_UTIL"   "0.45"
check "orcasaq : swappiness hôte" "$LLM_P_SWAPPINESS"   ""
check "orcasaq : transcription Qwen3-ASR" "$LLM_P_STT_MODEL" "$STT_MODEL"
check "tag de l'image EXL3"     "$(llm_exl3_image "$BASE")" "$EXL3"
if grep -q '^LLM_EXL3_IMAGE_REV=' "$REPO_ROOT/llm/profiles.sh"; then ok "LLM_EXL3_IMAGE_REV déclaré"; else ko "LLM_EXL3_IMAGE_REV déclaré"; fi

llm_profile_apply flash-next "$BASE" "$FLASH"
check "flash-next : modèle"     "$LLM_P_MODEL"          "nvidia/Qwen3.8-Flash-Next-NVFP4"
check "flash-next : image construite" "$LLM_P_IMAGE"    "$FLASH"
check "flash-next : build requis" "$LLM_P_NEEDS_BUILD"  "1"
check "flash-next : contexte de build llm/flash-next" "$LLM_P_BUILD_DIR" "flash-next"
check "flash-next : swappiness 10" "$LLM_P_SWAPPINESS"  "10"
check "flash-next : contexte 131k" "$LLM_P_CONTEXT_WINDOW" "131072"
# 5 Gio de libre et du swap en usage : rien ne tient à côté.
check "flash-next : pas de transcription" "$LLM_P_STT_MODEL" ""

llm_profile_apply gemma "$BASE" "$FLASH"
check "gemma : modèle"          "$LLM_P_MODEL"          "nvidia/Gemma-4-26B-A4B-NVFP4"
# Le piège que ce test existe pour attraper : Gemma n'a jamais tourné sous
# v0.29.0. Si quelqu'un « harmonise » les images, la régression est silencieuse.
check "gemma : image épinglée sur la 0.19" "$LLM_P_IMAGE" "vllm/vllm-openai:cu130-nightly"
check "gemma : pas de tête MTP"  "$LLM_P_MTP_TOKENS"    ""
check "gemma : pas de build"     "$LLM_P_NEEDS_BUILD"    "0"
# 0.55 laissait 7,9 Gio libres : le moteur de transcription (12,2 requis) redémarrait en boucle.
check "gemma : fraction abaissée à 0.45 pour la transcription" "$LLM_P_GPU_MEM_UTIL" "0.45"
# Mesuré le 25/09/2026 à côté du moteur de transcription : il tient.
check "gemma : transcription Qwen3-ASR" "$LLM_P_STT_MODEL" "$STT_MODEL"
check "tag de l'image de transcription" "$(llm_stt_image "$BASE")" "$STT"
# Le tag est ce qui dit à une box de reconstruire : la révision doit bouger avec le Dockerfile.
if grep -q '^LLM_STT_IMAGE_REV=' "$REPO_ROOT/llm/profiles.sh"; then ok "LLM_STT_IMAGE_REV déclaré"; else ko "LLM_STT_IMAGE_REV déclaré"; fi

if llm_profile_apply bogus "$BASE" "$FLASH" 2>/dev/null; then
  ko "llm_profile_apply refuse un profil inconnu"
else
  ok "llm_profile_apply refuse un profil inconnu"
fi

# --- 2. le lanceur dans le conteneur -----------------------------------------
head_ "llm/serve-llm.sh"
STUB="$(mktemp -d)"; printf '#!/bin/sh\necho "$*"\n' > "$STUB/vllm"; chmod +x "$STUB/vllm"
serve() { # serve PROFILE -> la ligne de commande vllm
  PATH="$STUB:$PATH" LLM_PROFILE="$1" LLM_MODEL=the-model LLM_MAX_MODEL_LEN=262144 \
    LLM_MAX_NUM_SEQS=2 LLM_GPU_MEM_UTIL=0.45 LLM_MTP_TOKENS=3 \
    bash "$REPO_ROOT/llm/serve-llm.sh" 2>&1
}
q="$(serve qwen27b)"
contains "qwen27b : parseur de raisonnement qwen3" "$q" "--reasoning-parser qwen3"
contains "qwen27b : parseur d'outils qwen3_xml"    "$q" "--tool-call-parser qwen3_xml"
contains "qwen27b : KV en fp8"                     "$q" "--kv-cache-dtype fp8"
contains "qwen27b : chargement fastsafetensors"    "$q" "--load-format fastsafetensors"
contains "qwen27b : tête MTP à 3"                  "$q" -- '"num_speculative_tokens":3'
absent   "qwen27b : pas le gabarit Gemma"          "$q" "tool_chat_template_gemma4"

o="$(serve orcasaq)"
contains "orcasaq : parseur de raisonnement qwen3" "$o" "--reasoning-parser qwen3"
contains "orcasaq : parseur d'outils qwen3_xml"    "$o" "--tool-call-parser qwen3_xml"
contains "orcasaq : KV en fp8"                     "$o" "--kv-cache-dtype fp8"
contains "orcasaq : tête MTP à 3 (valeur passée)"  "$o" -- '"num_speculative_tokens":3'
# Le format est lu depuis config.json par le plugin de l'image : aucun flag de quantification.
absent   "orcasaq : pas de --quantization"         "$o" "--quantization"
absent   "orcasaq : pas de fastsafetensors (chargeur du plugin)" "$o" "fastsafetensors"
absent   "orcasaq : pas le gabarit Gemma"          "$o" "tool_chat_template_gemma4"

g="$(serve gemma)"
contains "gemma : parseur d'outils gemma4"         "$g" "--tool-call-parser gemma4"
contains "gemma : gabarit de chat monté"           "$g" "/app/tool_chat_template_gemma4.jinja"
contains "gemma : quantification modelopt"         "$g" "--quantization modelopt"
contains "gemma : backend MoE marlin"              "$g" "--moe-backend marlin"
absent   "gemma : aucune tête MTP"                 "$g" "speculative-config"

# Le vrai risque de mélange : forcer marlin pour Gemma coûterait aux deux autres
# leur noyau W4A4 natif. Les variables doivent rester dans la branche gemma.
if grep -q 'export VLLM_NVFP4_GEMM_BACKEND=marlin' "$REPO_ROOT/llm/serve-llm.sh" \
   && ! grep -q 'VLLM_NVFP4_GEMM_BACKEND' "$REPO_ROOT/llm/docker-compose.yml"; then
  ok "le backend marlin est réglé dans la branche gemma, pas dans le compose"
else
  ko "le backend marlin fuit hors de la branche gemma"
fi

out="$(PATH="$STUB:$PATH" LLM_PROFILE=bogus LLM_MODEL=m LLM_MAX_MODEL_LEN=1 LLM_MAX_NUM_SEQS=1 \
        LLM_GPU_MEM_UTIL=0.5 bash "$REPO_ROOT/llm/serve-llm.sh" 2>&1)"; rc=$?
check "un profil inconnu sort en 64" "$rc" "64"
contains "…en le nommant" "$out" "unknown LLM_PROFILE: bogus"
rm -rf "$STUB"

# --- 2a. le contexte EXL3 : tout est épinglé par contenu ------------------------
head_ "llm/exl3/"
X="$(cat "$REPO_ROOT/llm/exl3/Dockerfile")"
contains "Dockerfile : base paramétrée"             "$X" 'FROM ${BASE_IMAGE}'
contains "Dockerfile : exllamav3 épinglé par sha256" "$X" 'ADD --checksum=sha256:${EXL3_SHA256}'
contains "Dockerfile : compilé pour sm_121"         "$X" 'TORCH_CUDA_ARCH_LIST="${CUDA_ARCH}"'
contains "Dockerfile : correctif arm64 appliqué avant pip" "$X" 'arm64-build.sh'
contains "Dockerfile : plugin épinglé sur un commit" "$X" 'ARG ORCASAQ2_COMMIT='
check    "Dockerfile : le commit du plugin est celui d'UPSTREAM_COMMIT" \
  "$(sed -n 's/^ARG ORCASAQ2_COMMIT=//p' "$REPO_ROOT/llm/exl3/Dockerfile")" "$(cat "$REPO_ROOT/llm/exl3/UPSTREAM_COMMIT")"
# Huit fichiers du plugin, chacun avec sa somme : aucun ADD sans --checksum.
check    "Dockerfile : 8 fichiers du plugin, tous épinglés" \
  "$(grep -c 'ADD --checksum=sha256:[0-9a-f]\{64\} ${ORCASAQ2}/' "$REPO_ROOT/llm/exl3/Dockerfile")" "8"
absent   "Dockerfile : aucun ADD non épinglé"       "$(grep '^ADD ' "$REPO_ROOT/llm/exl3/Dockerfile" | grep -v -- '--checksum=')" "ADD"
contains "Dockerfile : le plugin est bien un plugin vLLM (entry point vérifié)" "$X" "vllm.general_plugins"
# Le script de correctif refuse un arbre où upstream aurait déplacé ce qu'il patche.
A="$(cat "$REPO_ROOT/llm/exl3/arm64-build.sh")"
contains "arm64-build.sh : échoue si une source x86 attendue manque" "$A" "expected x86 source missing"
contains "arm64-build.sh : échoue si le builtin pause a changé"     "$A" "expected x86 pause builtin missing"
contains "arm64-build.sh : ne touche à rien hors aarch64"           "$A" "nothing to patch"
S_="$(cat "$REPO_ROOT/llm/exl3/aarch64_stubs.cpp")"
contains "stubs : les sondes ISA répondent absent"   "$S_" "bool is_avx2_supported() { return false; }"
contains "stubs : la voie CPU refuse plutôt que calculer" "$S_" "TORCH_CHECK(false"

# --- 2b. le conteneur de transcription : compose, nginx, Dockerfile -----------
head_ "llm/docker-compose.yml + nginx.conf + stt/Dockerfile"
C="$(cat "$REPO_ROOT/llm/docker-compose.yml")"
contains "compose : service vllm-stt"                 "$C" "container_name: suite366-vllm-stt"
contains "compose : derrière le profil compose stt"   "$C" 'profiles: ["stt"]'
contains "compose : image construite localement"      "$C" 'image: ${VLLM_STT_IMAGE:-'
contains "compose : budget KV explicite"              "$C" -- '--kv-cache-memory-bytes=${STT_KV_CACHE_BYTES:-'
contains "compose : max_model_len borné"              "$C" -- '--max-model-len=${STT_MAX_MODEL_LEN:-'
contains "compose : port dédié"                       "$C" '${BIND_IP}:${STT_PORT:-8003}:8000'
# Le proxy ne doit PAS dépendre du service : un depends_on activerait le profil
# de force et le conteneur tournerait pour tous les modèles.
proxy_block="$(sed -n '/^  vllm-proxy:/,$p' "$REPO_ROOT/llm/docker-compose.yml")"
absent   "compose : le proxy ne dépend pas de vllm-stt" "$proxy_block" "vllm-stt"

N="$(cat "$REPO_ROOT/llm/nginx.conf")"
contains "nginx : route /v1/audio/"                   "$N" "location /v1/audio/ {"
contains "nginx : résolution à la requête (resolver)" "$N" "resolver           127.0.0.11"
contains "nginx : proxy_pass par variable"            "$N" 'proxy_pass         $stt_upstream'
# Un bloc upstream statique ferait refuser le démarrage à nginx quand le service
# est absent, et emporterait le LLM et l'embedding avec lui.
absent   "nginx : pas d'upstream statique vers vllm-stt" "$N" "server vllm-stt:8000"

D="$(cat "$REPO_ROOT/llm/stt/Dockerfile")"
contains "Dockerfile : base paramétrée"               "$D" 'FROM ${BASE_IMAGE}'
contains "Dockerfile : soundfile épinglé"             "$D" "soundfile=="
contains "Dockerfile : PyAV épinglé"                  "$D" "av=="
# Sur la ligne RUN, pas dans les commentaires qui expliquent justement pourquoi pas.
absent   "Dockerfile : pas de vllm[audio] (re-résolution de vllm sur arm64)" "$(grep '^RUN' "$REPO_ROOT/llm/stt/Dockerfile")" 'vllm[audio]'

# Le chart reçoit le modèle, vide quand le profil n'en a pas, et install.sh le substitue.
contains "values.yaml : VLLM_MODEL_TRANSCRIPTION"     "$(cat "$REPO_ROOT/values.yaml")" 'VLLM_MODEL_TRANSCRIPTION: "@STT_MODEL@"'
contains "lib/suite.sh : substitue @STT_MODEL@"       "$(cat "$REPO_ROOT/lib/suite.sh")" '@STT_MODEL@|$LLM_STT_MODEL'
V="$(cat "$REPO_ROOT/lib/vllm.sh")"
contains "lib/vllm.sh : COMPOSE_PROFILES dans .env"   "$V" 'COMPOSE_PROFILES=${LLM_STT_MODEL:+stt}'
contains "lib/vllm.sh : STT_MODEL dans .env"          "$V" 'STT_MODEL=$LLM_STT_MODEL'
contains "lib/vllm.sh : construit l'image quand le profil le demande" "$V" 'if [[ -n "$LLM_STT_MODEL" ]]; then build_stt_image'

# --- 3. switch-model.sh sur une fausse box ------------------------------------
head_ "switch-model.sh"
BOX="$(mktemp -d)"; mkdir -p "$BOX/llm"; cp "$REPO_ROOT/llm/profiles.sh" "$BOX/llm/"
cat > "$BOX/llm/.env" <<EOF
VLLM_IMAGE=$BASE
VLLM_LLM_IMAGE=$FLASH
LLM_PROFILE=flash-next
LLM_MODEL=nvidia/Qwen3.8-Flash-Next-NVFP4
LLM_GPU_MEM_UTIL=0.71
LLM_MAX_MODEL_LEN=131072
LLM_MAX_NUM_SEQS=2
BIND_IP=10.99.0.1
PROXY_PORT=8000
EOF
printf '  VLLM_MODEL_HIGH: "nvidia/Qwen3.8-Flash-Next-NVFP4"\n  VLLM_MAX_CONTEXT_WINDOW: "131072"\n' > "$BOX/values.yaml"
sw() { DATA_DIR="$BOX" bash "$REPO_ROOT/switch-model.sh" "$@" 2>&1; }

l="$(sw list)"
contains "list : les quatre profils"     "$l" "qwen27b"
contains "list : orcasaq listé avec sa transcription" "$l" "orcasaq"
contains "list : marque l'actif"         "$l" "*flash-next"
s_="$(sw status)"
contains "status : lit le profil de .env" "$s_" "profile        flash-next"
contains "status : lit les valeurs du chart" "$s_" "chart values   nvidia/Qwen3.8-Flash-Next-NVFP4"
contains "status : transcription absente sur flash-next" "$s_" "transcription  none for this profile"

sw bogus >/dev/null 2>&1; check "un profil inconnu sort en erreur" "$?" "1"

d="$(sw qwen27b --dry-run)"
contains "dry-run : nouveau modèle dans .env"   "$d" "LLM_MODEL=nvidia/Qwen3.8-27B-NVFP4"
contains "dry-run : nouvelle fraction"          "$d" "LLM_GPU_MEM_UTIL=0.45"
contains "dry-run : image de base, pas de build" "$d" "VLLM_LLM_IMAGE=$BASE"
contains "dry-run : contexte annoncé à l'app"   "$d" "VLLM_MAX_CONTEXT_WINDOW -> 200000"
contains "dry-run : cible la ligne AIModel LLM" "$d" -- '"modelType" = '"'"'LLM'"'"
contains "dry-run : borne aux agents des 3 modèles connus" "$d" "'nvidia/Gemma-4-26B-A4B-NVFP4'"
# La ligne d'embedding ne doit JAMAIS être réécrite : elle sert un autre modèle.
absent "dry-run : ne touche pas l'embedding"    "$d" "Qwen3-VL-Embedding"
absent "dry-run : ne modifie rien"              "$(cat "$BOX/llm/.env")" "qwen27b"

# Flash-Next et OrcaSAQ demandent un build, chacun depuis son contexte ; seul
# Flash-Next touche à la swappiness.
f="$(sw flash-next --dry-run)"
contains "dry-run flash-next : annonce le build" "$f" "image build: $FLASH"
contains "dry-run flash-next : depuis llm/flash-next/" "$f" "llm/flash-next/"
contains "dry-run flash-next : swappiness 10"    "$f" "swappiness 10"
absent   "dry-run qwen27b : aucun build de l'image Flash-Next" "$d" "image build: $FLASH"
o_="$(sw orcasaq --dry-run)"
contains "dry-run orcasaq : annonce le build EXL3" "$o_" "image build: $EXL3"
contains "dry-run orcasaq : depuis llm/exl3/"    "$o_" "llm/exl3/"
contains "dry-run orcasaq : swappiness hôte"     "$o_" "swappiness host default"
contains "dry-run orcasaq : transcription activée" "$o_" "STT_MODEL=$STT_MODEL"
absent   "dry-run orcasaq : aucun build de l'image Flash-Next" "$o_" "image build: $FLASH"

# --- 3b. la transcription suit le profil ---------------------------------------
head_ "switch-model.sh : transcription"
contains "dry-run qwen27b : STT_MODEL dans .env"        "$d" "STT_MODEL=$STT_MODEL"
contains "dry-run qwen27b : profil compose stt activé"  "$d" "COMPOSE_PROFILES=stt"
# La fausse box date d'avant la transcription (pas de STT_PORT) : le port doit
# tomber sur 8003, pas sur vide — le vide envoyait le warm-up sur le 80 de Traefik.
contains "dry-run qwen27b : STT_PORT par défaut sur une box d'avant" "$d" "STT_PORT=8003"
contains "dry-run qwen27b : image des extras audio"     "$d" "image build: $STT"
contains "dry-run qwen27b : conteneur démarré après le moteur" "$d" "suite366-vllm-stt up after the engine is healthy"
contains "dry-run qwen27b : chart informé"              "$d" "VLLM_MODEL_TRANSCRIPTION -> $STT_MODEL"
contains "dry-run qwen27b : SQL — la ligne de transcription" "$d" '"supportsTranscription", "supportsTools", "supportsVision", "isEnabled"'
contains "dry-run qwen27b : SQL — modèle passé à psql"  "$d" "\\set stt '$STT_MODEL'"
contains "dry-run qwen27b : SQL — défaut d'organisation" "$d" 'SET "defaultTranscriptionModelId" = s.id'
contains "dry-run qwen27b : SQL — bornée à NOS providers vLLM" "$d" "http://10.99.0.1:8000/%"
contains "dry-run qwen27b : SQL — id fourni (Prisma ne le génère que côté client)" "$d" "gen_random_uuid()::text"
# Trouvé à la deuxième bascule réelle : la ligne STT est modelType LLM elle aussi,
# et le renommage du modèle génératif la percutait sur la clé unique.
contains "dry-run : le renommage LLM épargne la ligne de transcription" "$d" '"modelType" = '"'"'LLM'"'"' AND "supportsTranscription" = false'
# Vers un profil sans transcription : tout s'éteint, rien ne reste à moitié allumé.
contains "dry-run flash-next : STT_MODEL vidé"          "$f" "STT_MODEL="$'\n'
contains "dry-run flash-next : profil compose désactivé" "$f" "COMPOSE_PROFILES="$'\n'
contains "dry-run flash-next : conteneur arrêté AVANT le moteur" "$f" "taken down before the engine starts"
contains "dry-run flash-next : SQL — modèle vide"       "$f" "\\set stt ''"
contains "dry-run flash-next : SQL — défaut effacé"     "$f" 'SET "defaultTranscriptionModelId" = NULL'
absent   "dry-run flash-next : pas de build des extras audio" "$f" "image build: $STT"
# La ligne d'embedding reste hors de portée, transcription comprise.
absent   "dry-run : le SQL ne cite jamais l'embedding"  "$d$f" "Qwen3-VL-Embedding"
rm -rf "$BOX"

# --- 4. le pont vers l'app : state.json ---------------------------------------
head_ "switch-model.sh publish-state (pont UI)"
BOX2="$(mktemp -d)"; mkdir -p "$BOX2/llm" "$BOX2/models/hub/models--nvidia--Qwen3.8-27B-NVFP4"
cp "$REPO_ROOT/llm/profiles.sh" "$BOX2/llm/"
printf 'VLLM_IMAGE=%s\nLLM_PROFILE=qwen27b\nLLM_MODEL=nvidia/Qwen3.8-27B-NVFP4\nMODELS_DIR=%s/models\n' \
  "$BASE" "$BOX2" > "$BOX2/llm/.env"
DATA_DIR="$BOX2" LLM_STATE_DIR="$BOX2/llm-state" bash "$REPO_ROOT/switch-model.sh" publish-state >/dev/null 2>&1
STATE="$BOX2/llm-state/state.json"
if [[ -f "$STATE" ]]; then ok "state.json est écrit"; else ko "state.json est écrit"; fi
if python3 -m json.tool "$STATE" >/dev/null 2>&1; then ok "state.json est du JSON valide"; else ko "state.json est du JSON valide"; fi
probe() { python3 -c "import json,sys; d=json.load(open('$STATE')); print($1)" 2>/dev/null; }
check "state : profil actif"           "$(probe 'd["active"]')" "qwen27b"
check "state : les quatre profils"     "$(probe 'len(d["profiles"])')" "4"
check "state : orcasaq demande un build"  "$(probe '[p for p in d["profiles"] if p["key"]=="orcasaq"][0]["needs_build"]')" "True"
check "state : orcasaq annonce sa transcription" "$(probe '[p for p in d["profiles"] if p["key"]=="orcasaq"][0]["stt_model"]')" "$STT_MODEL"
check "state : statut de bascule au repos" "$(probe 'd["switch"]["status"]')" "idle"
# Ce que l'UI doit pouvoir dire à l'admin AVANT qu'il clique : ce modèle est-il
# déjà sur le disque, ou est-ce 133 Go à télécharger ?
check "state : checkpoint présent détecté" "$(probe '[p for p in d["profiles"] if p["key"]=="qwen27b"][0]["downloaded"]')" "True"
check "state : checkpoint absent détecté"  "$(probe '[p for p in d["profiles"] if p["key"]=="flash-next"][0]["downloaded"]')" "False"
check "state : flash-next demande un build" "$(probe '[p for p in d["profiles"] if p["key"]=="flash-next"][0]["needs_build"]')" "True"
# Ce que la carte du profil peut annoncer : avec ou sans transcription.
check "state : qwen27b annonce sa transcription" "$(probe '[p for p in d["profiles"] if p["key"]=="qwen27b"][0]["stt_model"]')" "$STT_MODEL"
check "state : flash-next n'en annonce pas"      "$(probe '[p for p in d["profiles"] if p["key"]=="flash-next"][0]["stt_model"]')" ""
check "state : moteur de transcription publié"   "$(probe 'sorted(d["stt"].keys())')" "['health', 'model', 'state']"
# Aucun secret ne doit transiter par le répertoire partagé avec le pod.
if grep -rqi "api.key\|sk-" "$BOX2/llm-state/" 2>/dev/null; then
  ko "le répertoire partagé ne contient aucun secret"
else
  ok "le répertoire partagé ne contient aucun secret"
fi
rm -rf "$BOX2"

printf '\n%d ok, %d KO\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
