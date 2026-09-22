#!/usr/bin/env bash
# =============================================================================
# Self-test of the model-profile machinery — no hardware, no network, no Docker.
#
# What it actually guards:
#   • the three profiles resolve to the model, image and budgets that were
#     measured, and nothing silently shares a value it should not;
#   • llm/serve-llm.sh builds the right flag set per profile, and refuses an
#     unknown one instead of serving something arbitrary;
#   • switch-model.sh reads a box's state, rejects a bad profile, and its
#     --dry-run tells the truth about the three places a model id lives;
#   • the SQL it would run touches the LLM row and the three known agents, and
#     never the embedding row.
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

# --- 1. la table de profils ---------------------------------------------------
head_ "llm/profiles.sh"
# shellcheck disable=SC1091
source "$REPO_ROOT/llm/profiles.sh"

check "les trois profils sont déclarés" "$LLM_PROFILES" "qwen27b flash-next gemma"
for p in qwen27b flash-next gemma; do
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

llm_profile_apply flash-next "$BASE" "$FLASH"
check "flash-next : modèle"     "$LLM_P_MODEL"          "nvidia/Qwen3.8-Flash-Next-NVFP4"
check "flash-next : image construite" "$LLM_P_IMAGE"    "$FLASH"
check "flash-next : build requis" "$LLM_P_NEEDS_BUILD"  "1"
check "flash-next : swappiness 10" "$LLM_P_SWAPPINESS"  "10"
check "flash-next : contexte 131k" "$LLM_P_CONTEXT_WINDOW" "131072"

llm_profile_apply gemma "$BASE" "$FLASH"
check "gemma : modèle"          "$LLM_P_MODEL"          "nvidia/Gemma-4-26B-A4B-NVFP4"
# Le piège que ce test existe pour attraper : Gemma n'a jamais tourné sous
# v0.29.0. Si quelqu'un « harmonise » les images, la régression est silencieuse.
check "gemma : image épinglée sur la 0.19" "$LLM_P_IMAGE" "vllm/vllm-openai:cu130-nightly"
check "gemma : pas de tête MTP"  "$LLM_P_MTP_TOKENS"    ""

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
EOF
printf '  VLLM_MODEL_HIGH: "nvidia/Qwen3.8-Flash-Next-NVFP4"\n  VLLM_MAX_CONTEXT_WINDOW: "131072"\n' > "$BOX/values.yaml"
sw() { DATA_DIR="$BOX" bash "$REPO_ROOT/switch-model.sh" "$@" 2>&1; }

l="$(sw list)"
contains "list : les trois profils"      "$l" "qwen27b"
contains "list : marque l'actif"         "$l" "*flash-next"
s_="$(sw status)"
contains "status : lit le profil de .env" "$s_" "profile        flash-next"
contains "status : lit les valeurs du chart" "$s_" "chart values   nvidia/Qwen3.8-Flash-Next-NVFP4"

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

# Flash-Next est le seul à demander un build et un réglage de swappiness.
f="$(sw flash-next --dry-run)"
contains "dry-run flash-next : annonce le build" "$f" "image build: $FLASH"
contains "dry-run flash-next : swappiness 10"    "$f" "swappiness 10"
absent   "dry-run qwen27b : aucun build"         "$d" "image build:"
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
check "state : les trois profils"      "$(probe 'len(d["profiles"])')" "3"
check "state : statut de bascule au repos" "$(probe 'd["switch"]["status"]')" "idle"
# Ce que l'UI doit pouvoir dire à l'admin AVANT qu'il clique : ce modèle est-il
# déjà sur le disque, ou est-ce 133 Go à télécharger ?
check "state : checkpoint présent détecté" "$(probe '[p for p in d["profiles"] if p["key"]=="qwen27b"][0]["downloaded"]')" "True"
check "state : checkpoint absent détecté"  "$(probe '[p for p in d["profiles"] if p["key"]=="flash-next"][0]["downloaded"]')" "False"
check "state : flash-next demande un build" "$(probe '[p for p in d["profiles"] if p["key"]=="flash-next"][0]["needs_build"]')" "True"
# Aucun secret ne doit transiter par le répertoire partagé avec le pod.
if grep -rqi "api.key\|sk-" "$BOX2/llm-state/" 2>/dev/null; then
  ko "le répertoire partagé ne contient aucun secret"
else
  ok "le répertoire partagé ne contient aucun secret"
fi
rm -rf "$BOX2"

printf '\n%d ok, %d KO\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
