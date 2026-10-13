#!/usr/bin/env bash
# =============================================================================
# Self-test: the trust bootstrap — no appliance runs root code on TLS alone.
#
#  • THE KEY IS ALWAYS THERE: update.sh writes the embedded public key where
#    it is missing (PACKAGE_PUBLIC_KEY_PEM overrides the PEM), never overwrites
#    one that exists, and refuses to run when it cannot write it.
#  • VERIFICATION USES IT: a manifest signed by the embedded key verifies, a
#    foreign one is refused; a second key (PACKAGE_PUBLIC_KEY_NEXT) is accepted
#    during a rotation.
#  • NO SELF-UPDATE ON CHECK: the daily `check` no longer replaces update.sh;
#    `apply` still does (the admin's confirmation is the consent).
#  • HELM IS PINNED: the tarball's sha256 must match lib/config.sh, else the
#    install refuses it.
# =============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ORIG_PATH="$PATH"
c_g="\033[32m"; c_r="\033[31m"; c_0="\033[0m"
pass=0; fail=0
ok() { printf "  ${c_g}PASS${c_0} %s\n" "$1"; pass=$((pass + 1)); }
ko() { printf "  ${c_r}FAIL${c_0} %s\n" "$1"; fail=$((fail + 1)); }
check()    { if [[ "$2" == "$3" ]]; then ok "$1"; else ko "$1 (expected '$3', got '$2')"; fi; }
contains() { if grep -qF -- "$3" <<<"$2"; then ok "$1"; else ko "$1 (missing: $3)"; fi; }
absent()   { if grep -qF -- "$3" <<<"$2"; then ko "$1 (present: $3)"; else ok "$1"; fi; }

mkdir -p "$WORK/bin" "$WORK/data"
openssl genpkey -algorithm ed25519 -out "$WORK/k1.key" 2>/dev/null; openssl pkey -in "$WORK/k1.key" -pubout -out "$WORK/k1.pub" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$WORK/k2.key" 2>/dev/null; openssl pkey -in "$WORK/k2.key" -pubout -out "$WORK/k2.pub" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$WORK/evil.key" 2>/dev/null
printf '{"channel":"stable"}\n' > "$WORK/manifest.json"
openssl pkeyutl -sign -rawin -inkey "$WORK/k1.key" -in "$WORK/manifest.json" -out "$WORK/manifest.sig.k1"
openssl pkeyutl -sign -rawin -inkey "$WORK/k2.key" -in "$WORK/manifest.json" -out "$WORK/manifest.sig.k2"
openssl pkeyutl -sign -rawin -inkey "$WORK/evil.key" -in "$WORK/manifest.json" -out "$WORK/manifest.sig.evil"
printf '#!/usr/bin/env bash\nexit 0\n' > "$WORK/bin/logger"; chmod +x "$WORK/bin/logger"

{
  cat <<'H'
c_g=""; c_b=""; c_y=""; c_r=""; c_0=""
log()  { printf 'LOG %s\n' "$*"; }
info() { printf 'INFO %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die()  { printf 'DIE %s\n' "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
H
  printf 'DATA_DIR=%s\n' "$WORK/data"
  sed -n '/^PACKAGE_PUBLIC_KEY=/p; /^PACKAGE_PUBLIC_KEY_NEXT=/p' "$REPO/update.sh"
  sed -n "/^_EMBEDDED_PACKAGE_PUBLIC_KEY='/,/^-----END PUBLIC KEY-----'/p" "$REPO/update.sh"
  for f in ensure_package_public_key verify_sig; do sed -n "/^$f() {/,/^}/p" "$REPO/update.sh"; done
} > "$WORK/prelude.sh"
run() { # run CODE -> output ; RC = exit status
  local out rc
  # shellcheck disable=SC2097,SC2098
  out="$(PATH="$WORK/bin:$ORIG_PATH" WORK="$WORK" bash -c "set -uo pipefail; . '$WORK/prelude.sh'; $1" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  return "$rc"
}

echo "== the embedded key =="
out="$(run "ensure_package_public_key; cat \"\$PACKAGE_PUBLIC_KEY\"")"; RC=$?
check "written where missing" "$RC" "0"
contains "…is a PEM public key" "$out" "BEGIN PUBLIC KEY"
check "…the production key (the one every box and the CI variable hold)" "$(sed -n 2p "$WORK/data/package-release.pub")" "MCowBQYDK2VwAyEAAAIj33sDi5EbhWnKHuaH8jt0yPph1+Nvrqdr/A7y3bg="
check "…world-readable (it is public)" "$(stat -c %a "$WORK/data/package-release.pub")" "644"
contains "…and the operator is told once" "$out" "signing key installed"
out="$(run "ensure_package_public_key")"; RC=$?
absent "a present key is left alone (no second message)" "$out" "signing key installed"
rm -f "$WORK/data/package-release.pub"
out="$(run "PACKAGE_PUBLIC_KEY_PEM=\"\$(cat '$WORK/k1.pub')\" ensure_package_public_key")"; RC=$?
check "PACKAGE_PUBLIC_KEY_PEM overrides the PEM (a deployment with its own key)" "$(cat "$WORK/data/package-release.pub")" "$(cat "$WORK/k1.pub")"
rm -f "$WORK/data/package-release.pub"; chmod 0500 "$WORK/data"
out="$(run "ensure_package_public_key")"; RC=$?
chmod 0700 "$WORK/data"
if [[ "$(id -u)" == 0 ]]; then ok "(root: the unwritable-dir case cannot be exercised)"; else
  check "cannot write the key -> refuses to run" "$RC" "1"
  contains "…and says why" "$out" "refusing to run without it"
fi

echo "== verification =="
cp "$WORK/k1.pub" "$WORK/data/package-release.pub"
out="$(run "verify_sig '$WORK/manifest.json' '$WORK/manifest.sig.k1' && echo verified")"; RC=$?
check "signed by the installed key -> verified" "$RC" "0"
out="$(run "verify_sig '$WORK/manifest.json' '$WORK/manifest.sig.evil' && echo verified")"; RC=$?
check "signed by a foreign key -> refused" "$RC" "1"
out="$(run "verify_sig '$WORK/manifest.json' '$WORK/manifest.sig.k2' && echo verified")"; RC=$?
check "signed by the rotation key, no rotation declared -> refused" "$RC" "1"
cp "$WORK/k2.pub" "$WORK/data/package-release-next.pub"
out="$(run "verify_sig '$WORK/manifest.json' '$WORK/manifest.sig.k2' && echo verified")"; RC=$?
check "signed by the rotation key, PACKAGE_PUBLIC_KEY_NEXT present -> verified" "$RC" "0"
out="$(run "verify_sig '$WORK/manifest.json' '$WORK/manifest.sig.k1' && echo verified")"; RC=$?
check "…and the first key still verifies during the rotation" "$RC" "0"

echo "== what update.sh does on check and apply =="
U="$REPO/update.sh"
check_branch="$(awk '/^  check\)$/,/^    ;;$/' "$U")"
apply_branch="$(awk '/^  apply\)$/,/^    ;;$/' "$U")"
absent   "check does NOT refresh update.sh" "$check_branch" "self_update_first"
contains "check installs the key before fetching the manifest" "$check_branch" "ensure_package_public_key"
contains "apply still refreshes update.sh" "$apply_branch" "self_update_first"
absent   "no TLS-only rung left in update.sh" "$(grep -v '^#' "$U" | grep -v 'gone\|rung\|used to')" "TLS-only"
for f in verify_manifest_signature stage_host_layer_online self_update converge_backup; do
  contains "$f runs strict (the key is ensured first)" "$(sed -n "/^$f() {/,/^}/p" "$U")" "ensure_package_public_key"
done
contains "the installer writes the key at install" "$(cat "$REPO/lib/updater.sh")" 'printf '"'"'%s\n'"'"' "$PACKAGE_PUBLIC_KEY_PEM" > "$PACKAGE_PUBLIC_KEY"'
check "install.sh and update.sh embed the same key" "$(sed -n "/^_DEFAULT_PACKAGE_PUBLIC_KEY='/,/^-----END/p" "$REPO/lib/config.sh" | sed -n 2p)" "$(sed -n "/^_EMBEDDED_PACKAGE_PUBLIC_KEY='/,/^-----END/p" "$U" | sed -n 2p)"

echo "== helm is pinned =="
{
  cat <<'H'
log()  { printf 'LOG %s\n' "$*"; }
info() { printf 'INFO %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die()  { printf 'DIE %s\n' "$*"; exit 1; }
H
  sed -n '/^K3S_VERSION=/p; /^HELM_VERSION=/p; /^HELM_SHA256_ARM64=/p; /^HELM_SHA256_AMD64=/p' "$REPO/lib/config.sh"
  sed -n '/^install_helm() {/,/^}/p' "$REPO/lib/k3s.sh"
} > "$WORK/helm-prelude.sh"
# A stub curl that serves a tarball with the right layout but the WRONG bytes.
mkdir -p "$WORK/tar/linux-$(uname -m | sed 's/aarch64/arm64/; s/x86_64/amd64/')"
printf '#!/bin/sh\necho stub-helm\n' > "$WORK/tar/linux-$(uname -m | sed 's/aarch64/arm64/; s/x86_64/amd64/')/helm"
tar -czf "$WORK/helm.tgz" -C "$WORK/tar" "linux-$(uname -m | sed 's/aarch64/arm64/; s/x86_64/amd64/')"
printf '#!/usr/bin/env bash\nout=""; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift ;; esac; shift; done; cp "$WORK/helm.tgz" "$out"\n' > "$WORK/bin/curl"; chmod +x "$WORK/bin/curl"
printf '#!/usr/bin/env bash\nprintf "install %%s\\n" "$*" >> "$WORK/install.log"\n' > "$WORK/bin/install"; chmod +x "$WORK/bin/install"
runh() { # runh CODE -> output ; RC = exit status (the helm prelude)
  local out rc
  # shellcheck disable=SC2097,SC2098
  out="$(PATH="$WORK/bin:$ORIG_PATH" WORK="$WORK" bash -c "set -uo pipefail; . '$WORK/helm-prelude.sh'; $1" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  return "$rc"
}
out="$(runh "install_helm")"; RC=$?
check "a tarball whose sha256 is not the pinned one is refused" "$RC" "1"
contains "…and named" "$out" "REFUSING helm tarball"
if [[ -f "$WORK/install.log" ]]; then ko "…nothing installed"; else ok "…nothing installed"; fi
# Now pin the stub's own hash: it installs.
sha="$(sha256sum "$WORK/helm.tgz" | awk '{print $1}')"
out="$(runh "HELM_SHA256_ARM64=$sha; HELM_SHA256_AMD64=$sha; install_helm")"; RC=$?
check "a tarball matching the pin is installed" "$RC" "0"
contains "…to /usr/local/bin/helm" "$(cat "$WORK/install.log" 2>/dev/null)" "/usr/local/bin/helm"
contains "k3s is installed at the pinned version" "$(cat "$REPO/lib/k3s.sh")" 'INSTALL_K3S_VERSION="$K3S_VERSION"'
absent   "helm's get-helm-3 | bash is gone" "$(grep -v '^\s*#' "$REPO/lib/k3s.sh")" "get-helm-3"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
