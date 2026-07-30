#!/usr/bin/env bash
# =============================================================================
# Generate the Ed25519 keypair that signs offline update packages.
#
#   tools/gen-package-key.sh ~/.secrets/package-release
#     -> ~/.secrets/package-release.key   PRIVATE — never leaves the vault / CI
#     -> ~/.secrets/package-release.pub   ships with every appliance
#
# The PUBLIC half goes onto each appliance as $DATA_DIR/package-release.pub
# (see PACKAGE_PUBLIC_KEY in lib/config.sh). It can only verify, never sign.
#
# This is deliberately NOT the license keypair: a license key must never gain
# the power to authorise code execution, and the two rotate on different
# schedules for different reasons.
# =============================================================================
set -euo pipefail

BASE="${1:-}"
[[ -n "$BASE" ]] || { echo "usage: $0 <output-basename>" >&2; exit 1; }
[[ -e "$BASE.key" ]] && { echo "refusing to overwrite $BASE.key" >&2; exit 1; }

mkdir -p "$(dirname "$BASE")"
umask 077
openssl genpkey -algorithm ed25519 -out "$BASE.key"
chmod 0600 "$BASE.key"
openssl pkey -in "$BASE.key" -pubout -out "$BASE.pub"
chmod 0644 "$BASE.pub"

echo "private : $BASE.key  (0600 — store in the vault, load into CI as a secret)"
echo "public  : $BASE.pub  (deploy to appliances as \$DATA_DIR/package-release.pub)"
