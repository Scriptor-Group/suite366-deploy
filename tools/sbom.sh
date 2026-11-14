#!/usr/bin/env bash
# Génère la nomenclature logicielle (SBOM) de l'appliance, au format CycloneDX.
#
# Exigence : règlement (UE) 2024/2847, annexe I partie II point 1 — le fabricant
# identifie et documente les composants, « y compris en établissant une
# nomenclature logicielle couvrant au minimum les dépendances de premier niveau
# du produit ».
#
# Portée : les composants que CE dépôt installe et dont il épingle la version.
# Les dépendances internes de l'application Suite 366 relèvent du SBOM produit
# par son propre dépôt ; celui-ci les référence par la version du chart.
#
#   tools/sbom.sh                 -> sbom.cdx.json
#   tools/sbom.sh chemin.json     -> chemin.json
set -euo pipefail

ici="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
sortie="${1:-$ici/sbom.cdx.json}"

# On lit les versions là où elles font foi plutôt que de les recopier : une
# nomenclature qui diverge du produit est pire que pas de nomenclature.
val() {
  local nom="$1" def="$2"
  local v
  v="$(grep -oE "^${nom}=\"\\\$\{${nom}:-[^}]*\}\"" "$ici/lib/config.sh" 2>/dev/null \
        | head -1 | sed -E "s/.*:-(.*)\}\"/\1/")"
  printf '%s' "${v:-$def}"
}

chart="$(val CHART_VERSION inconnue)"
certmgr="$(val CERT_MANAGER_VERSION inconnue)"
restic="$(val RESTIC_VERSION inconnue)"
vllm="$(val VLLM_IMAGE inconnue)"
release="$(git -C "$ici" describe --tags --always --dirty 2>/dev/null || echo inconnue)"
horodate="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

composant() { # nom version type ref
  printf '    {"type":"%s","name":"%s","version":"%s","purl":"%s"}' "$3" "$1" "$2" "$4"
}

{
  cat <<EOF
{
  "bomFormat": "CycloneDX",
  "specVersion": "1.5",
  "version": 1,
  "metadata": {
    "timestamp": "$horodate",
    "component": {
      "type": "application",
      "name": "suite366-appliance",
      "version": "$release",
      "description": "Suite 366 appliance (Diwy) — installeur DGX Spark",
      "supplier": { "name": "Scriptor Artis" }
    },
    "properties": [
      { "name": "cra:category", "value": "default" },
      { "name": "cra:support-period-years", "value": "5" }
    ]
  },
  "components": [
EOF
  {
    composant "suite366-drive-chart" "$chart" library "pkg:oci/drive@$chart"
    # k3s n'est pas epingle : lib/k3s.sh installe ce que get.k3s.io sert au
    # moment de l'installation. La nomenclature le dit plutot que de pretendre
    # une version. A corriger : l'annexe I partie II exige d'identifier les
    # composants, ce qu'une version flottante ne permet pas.
    k3s_v="$(k3s --version 2>/dev/null | head -1 | grep -oE 'v[0-9.+a-z]+' | head -1)"
    printf ',\n'; composant "k3s" "${k3s_v:-NON-EPINGLE}" application "pkg:generic/k3s"
    printf ',\n'; composant "cert-manager" "$certmgr" library "pkg:helm/cert-manager@$certmgr"
    printf ',\n'; composant "restic" "$restic" application "pkg:generic/restic@$restic"
    printf ',\n'; composant "vllm" "${vllm##*:}" container "pkg:oci/${vllm%%:*}"
    printf '\n'
  }
  cat <<'EOF'
  ]
}
EOF
} > "$sortie"

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$sortie" \
  || { echo "SBOM invalide : $sortie" >&2; exit 1; }

echo "SBOM écrit : $sortie"
grep -c '"type"' "$sortie" | sed 's/^/  entrées : /'
