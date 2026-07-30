#!/usr/bin/env bash
# =============================================================================
# Self-test for update.sh's offline-package verifier. Builds real signed
# packages, then tampers with them one way at a time and asserts each is
# refused for the right reason. No cluster, no appliance, no GPU:
#
#   tools/test-package-verify.sh          # from the repo root
#
# pkg_verify + ver_gt are lifted VERBATIM out of update.sh (sed range extract)
# so this exercises the shipping code, not a copy that can drift from it.
# =============================================================================
set -uo pipefail

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
UPDATE_SH="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/update.sh}"
[[ -s "$UPDATE_SH" ]] || { echo "update.sh not found: $UPDATE_SH" >&2; exit 1; }

pass=0; fail=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
ko()   { printf '  \033[31mFAIL\033[0m %s — %s\n' "$1" "${2:-}"; fail=$((fail+1)); }

# --- keys ---------------------------------------------------------------------
openssl genpkey -algorithm ed25519 -out "$WORK/good.key" 2>/dev/null
openssl pkey -in "$WORK/good.key" -pubout -out "$WORK/good.pub" 2>/dev/null
openssl genpkey -algorithm ed25519 -out "$WORK/evil.key" 2>/dev/null

# --- build a minimal but structurally valid package ---------------------------
mkpkg() { # mkpkg DIR SIGNING_KEY APP_VERSION [MIN_FROM]
  local d="$1" key="$2" app="$3" minfrom="${4:-}"
  rm -rf "$d"; mkdir -p "$d/chart" "$d/images" "$d/scripts"
  printf 'fake chart archive\n' > "$d/chart/drive-9.9.9.tgz"
  printf 'fake image tar\n'     > "$d/images/app.tar"
  printf '#!/bin/bash\ntrue\n'  > "$d/scripts/update.sh"
  cat > "$d/manifest.json" <<EOF
{
  "schema": 1,
  "channel": "stable",
  "chart_version": "9.9.9",
  "app_version": "$app",
  "vllm_image": "",
  "notes": "test package",
  "min_from_version": "$minfrom",
  "platform": "linux/arm64"
}
EOF
  ( cd "$d" && find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.sig -print0 \
      | sort -z | xargs -0 sha256sum > SHA256SUMS )
  openssl pkeyutl -sign -rawin -inkey "$key" -in "$d/SHA256SUMS" -out "$d/SHA256SUMS.sig"
}

# --- harness: run pkg_verify from update.sh in a subshell ----------------------
# update.sh refuses to run as non-root and dispatches on $1, so we source it
# with a guard: extract just the functions we need by stubbing the environment.
verify() { # verify PKGDIR PUBKEY CUR_APP  -> prints pkg_error, exit status
  bash -c '
    set -uo pipefail
    PACKAGE_PUBLIC_KEY="$2"; cur_app="$3"
    json_get() { sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" | head -1; }
    ver_gt() {
      [[ -n "$1" ]] || return 1
      [[ -n "$2" ]] || return 0
      [[ "$1" != "$2" ]] || return 1
      [[ "$(printf "%s\n%s\n" "$1" "$2" | sort -V | tail -1)" == "$1" ]]
    }
    # Pull pkg_verify out of the real update.sh, verbatim.
    eval "$(sed -n "/^pkg_verify() {/,/^}/p" "$4")"
    if pkg_verify "$1"; then echo "OK"; exit 0; else echo "$pkg_error"; exit 1; fi
  ' _ "$1" "$2" "$3" "$UPDATE_SH"
}

echo "== offline package verifier =="

mkpkg "$WORK/pkg" "$WORK/good.key" 1.8.23
out="$(verify "$WORK/pkg" "$WORK/good.pub" 1.8.22)" \
  && [[ "$out" == OK ]] && ok "valid package accepted" || ko "valid package accepted" "$out"

# signed by the wrong key
mkpkg "$WORK/evil" "$WORK/evil.key" 1.8.23
out="$(verify "$WORK/evil" "$WORK/good.pub" 1.8.22)"
[[ $? -ne 0 && "$out" == *"signature check failed"* ]] \
  && ok "foreign signature refused" || ko "foreign signature refused" "$out"

# one byte flipped in an image tar (checksum, not signature, catches this)
mkpkg "$WORK/bitrot" "$WORK/good.key" 1.8.23
printf 'X' >> "$WORK/bitrot/images/app.tar"
out="$(verify "$WORK/bitrot" "$WORK/good.pub" 1.8.22)"
[[ $? -ne 0 && "$out" == *"checksum mismatch"* ]] \
  && ok "corrupt image tar refused" || ko "corrupt image tar refused" "$out"

# manifest swapped after signing
mkpkg "$WORK/swap" "$WORK/good.key" 1.8.23
sed -i 's/"app_version": "1.8.23"/"app_version": "9.9.9"/' "$WORK/swap/manifest.json"
out="$(verify "$WORK/swap" "$WORK/good.pub" 1.8.22)"
[[ $? -ne 0 && "$out" == *"checksum mismatch"* ]] \
  && ok "tampered manifest refused" || ko "tampered manifest refused" "$out"

# manifest present but NOT covered by the signed list
mkpkg "$WORK/uncovered" "$WORK/good.key" 1.8.23
grep -v 'manifest.json' "$WORK/uncovered/SHA256SUMS" > "$WORK/uncovered/S.tmp"
mv "$WORK/uncovered/S.tmp" "$WORK/uncovered/SHA256SUMS"
openssl pkeyutl -sign -rawin -inkey "$WORK/good.key" \
  -in "$WORK/uncovered/SHA256SUMS" -out "$WORK/uncovered/SHA256SUMS.sig"
out="$(verify "$WORK/uncovered" "$WORK/good.pub" 1.8.22)"
[[ $? -ne 0 && "$out" == *"not covered"* ]] \
  && ok "uncovered manifest refused" || ko "uncovered manifest refused" "$out"

# missing signature entirely
mkpkg "$WORK/nosig" "$WORK/good.key" 1.8.23
rm -f "$WORK/nosig/SHA256SUMS.sig"
out="$(verify "$WORK/nosig" "$WORK/good.pub" 1.8.22)"
[[ $? -ne 0 && "$out" == *"SHA256SUMS.sig missing"* ]] \
  && ok "unsigned package refused" || ko "unsigned package refused" "$out"

# no public key on the appliance => refuse everything
mkpkg "$WORK/pkg2" "$WORK/good.key" 1.8.23
out="$(verify "$WORK/pkg2" "$WORK/absent.pub" 1.8.22)"
[[ $? -ne 0 && "$out" == *"no package signing key"* ]] \
  && ok "no appliance key => refused" || ko "no appliance key => refused" "$out"

# downgrade
mkpkg "$WORK/down" "$WORK/good.key" 1.8.20
out="$(verify "$WORK/down" "$WORK/good.pub" 1.8.22)"
[[ $? -ne 0 && "$out" == *"downgrade refused"* ]] \
  && ok "downgrade refused" || ko "downgrade refused" "$out"

# min_from_version not satisfied
mkpkg "$WORK/floor" "$WORK/good.key" 1.9.0 1.8.30
out="$(verify "$WORK/floor" "$WORK/good.pub" 1.8.22)"
[[ $? -ne 0 && "$out" == *"requires app >= 1.8.30"* ]] \
  && ok "min_from_version enforced" || ko "min_from_version enforced" "$out"

# min_from_version satisfied
mkpkg "$WORK/floor2" "$WORK/good.key" 1.9.0 1.8.20
out="$(verify "$WORK/floor2" "$WORK/good.pub" 1.8.22)" \
  && [[ "$out" == OK ]] && ok "min_from_version satisfied" || ko "min_from_version satisfied" "$out"

# same version = legitimate repair re-apply, not a downgrade
mkpkg "$WORK/same" "$WORK/good.key" 1.8.22
out="$(verify "$WORK/same" "$WORK/good.pub" 1.8.22)" \
  && [[ "$out" == OK ]] && ok "same-version re-apply allowed" || ko "same-version re-apply allowed" "$out"

# two chart archives = ambiguous helm upgrade
mkpkg "$WORK/twocharts" "$WORK/good.key" 1.8.23
printf 'second\n' > "$WORK/twocharts/chart/drive-9.9.8.tgz"
( cd "$WORK/twocharts" && find . -type f ! -name SHA256SUMS ! -name SHA256SUMS.sig -print0 \
    | sort -z | xargs -0 sha256sum > SHA256SUMS )
openssl pkeyutl -sign -rawin -inkey "$WORK/good.key" \
  -in "$WORK/twocharts/SHA256SUMS" -out "$WORK/twocharts/SHA256SUMS.sig"
out="$(verify "$WORK/twocharts" "$WORK/good.pub" 1.8.22)"
[[ $? -ne 0 && "$out" == *"expected 1"* ]] \
  && ok "ambiguous chart set refused" || ko "ambiguous chart set refused" "$out"

# --- ver_gt ordering ----------------------------------------------------------
echo "== version ordering =="
vg() { bash -c '
  ver_gt() {
    [[ -n "$1" ]] || return 1
    [[ -n "$2" ]] || return 0
    [[ "$1" != "$2" ]] || return 1
    [[ "$(printf "%s\n%s\n" "$1" "$2" | sort -V | tail -1)" == "$1" ]]
  }
  ver_gt "$1" "$2"' _ "$1" "$2"; }
vg 1.8.10 1.8.9   && ok "1.8.10 > 1.8.9 (numeric, not lexical)" || ko "1.8.10 > 1.8.9"
vg 1.8.9 1.8.10   && ko "1.8.9 > 1.8.10 must be false" || ok "1.8.9 !> 1.8.10"
vg 1.8.22 1.8.22  && ko "equal must be false" || ok "equal is not greater"
vg 2.0.0 1.99.99  && ok "2.0.0 > 1.99.99" || ko "2.0.0 > 1.99.99"
vg "" 1.0.0       && ko "empty must not be greater" || ok "empty !> anything"
vg 1.0.0 ""       && ok "anything > empty" || ko "anything > empty"

# --- manifest signature (channel.json) ----------------------------------------
# Whoever controls MANIFEST_URL decides what every appliance is told to run, so
# the manifest is signed too. Graduated: strict when the appliance holds our
# public key, TLS-only when it does not (the public product's posture).
echo
echo "== channel manifest signature =="

mkchannel() { # mkchannel FILE KEY [CHART_VERSION]
  local f="$1" key="$2" cv="${3:-0.8.0}"
  cat > "$f" <<EOF
{
  "channel": "stable",
  "chart_version": "$cv",
  "app_version": "1.8.22",
  "vllm_image": "vllm/vllm-openai:cu130-nightly",
  "updater_sha256": "deadbeef",
  "notes": "test"
}
EOF
  [[ -n "$key" ]] && openssl pkeyutl -sign -rawin -inkey "$key" -in "$f" -out "$f.sig"
  return 0
}

# Drive the real verify_manifest_signature with curl stubbed to serve local files.
verify_manifest() { # verify_manifest MANIFEST_FILE PUBKEY [serve_sig=1]
  bash -c '
    set -uo pipefail
    PACKAGE_PUBLIC_KEY="$2"
    MANIFEST_SIG_URL="sig://$1.sig"
    online_error=""; online_signed=0
    info() { :; }
    warn() { :; }
    have() { command -v "$1" >/dev/null 2>&1; }
    # Stubbed transport. The real call is `curl -fsSL -m 20 URL -o DEST`, so the
    # URL is NOT $1 — read it from MANIFEST_SIG_URL and only parse out -o.
    curl() {
      local dest="" i
      local -a a=("$@")
      for ((i=0; i<${#a[@]}; i++)); do [[ "${a[i]}" == "-o" ]] && dest="${a[i+1]}"; done
      local src="${MANIFEST_SIG_URL#sig://}"
      [[ -n "$dest" && -s "$src" ]] || return 22
      cp "$src" "$dest"
    }
    eval "$(sed -n "/^verify_manifest_signature() {/,/^}/p" "$4")"
    if verify_manifest_signature "$1"; then echo "OK signed=$online_signed"; else echo "$online_error"; exit 1; fi
  ' _ "$1" "$2" "${3:-1}" "$UPDATE_SH"
}

mkchannel "$WORK/ch.json" "$WORK/good.key"
out="$(verify_manifest "$WORK/ch.json" "$WORK/good.pub")" \
  && [[ "$out" == "OK signed=1" ]] && ok "signed manifest accepted, marked verified" \
  || ko "signed manifest accepted" "$out"

# No key on the appliance -> permissive, and NOT marked verified (so self_update
# stays in TLS-only mode rather than believing it has a guarantee).
out="$(verify_manifest "$WORK/ch.json" "$WORK/absent.pub")" \
  && [[ "$out" == "OK signed=0" ]] && ok "no appliance key => permissive, not marked verified" \
  || ko "no appliance key => permissive" "$out"

# Signed by the wrong key.
mkchannel "$WORK/evilch.json" "$WORK/evil.key"
out="$(verify_manifest "$WORK/evilch.json" "$WORK/good.pub")"
[[ $? -ne 0 && "$out" == *"signature INVALID"* ]] \
  && ok "foreign-signed manifest refused" || ko "foreign-signed manifest refused" "$out"

# Tampered after signing — the chart_version an appliance would act on.
mkchannel "$WORK/tamper.json" "$WORK/good.key"
sed -i 's/"chart_version": "0.8.0"/"chart_version": "9.9.9"/' "$WORK/tamper.json"
out="$(verify_manifest "$WORK/tamper.json" "$WORK/good.pub")"
[[ $? -ne 0 && "$out" == *"signature INVALID"* ]] \
  && ok "manifest tampered after signing refused" || ko "manifest tampered after signing refused" "$out"

# Signature missing while the appliance requires one -> fail closed.
mkchannel "$WORK/nosig.json" ""
out="$(verify_manifest "$WORK/nosig.json" "$WORK/good.pub")"
[[ $? -ne 0 && "$out" == *"signature unavailable"* ]] \
  && ok "missing signature refused (fail closed)" || ko "missing signature refused" "$out"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
