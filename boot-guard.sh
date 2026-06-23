#!/usr/bin/env bash
# Garde de boot GPU pour le conteneur vLLM.
# Au reboot du GB10, le driver/CUDA n'est pas toujours pret quand Docker relance
# le conteneur -> la 1re init du moteur vLLM crashe. On attend donc que
# `nvidia-smi` reponde avant de lancer `vllm serve`. Monte dans le conteneur et
# utilise comme entrypoint ; les args (modele + flags) arrivent via "$@".
set -uo pipefail
n=0
until nvidia-smi -L >/dev/null 2>&1; do
  n=$((n+1))
  if [ "$n" -gt 100 ]; then
    echo "[boot-guard] GPU toujours pas pret apres ~300s, on lance quand meme"
    break
  fi
  echo "[boot-guard] GPU pas pret, attente ($n)..."
  sleep 3
done
echo "[boot-guard] GPU pret, demarrage de vLLM"
sleep 5
exec vllm serve "$@"
