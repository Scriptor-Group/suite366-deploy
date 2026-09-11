#!/usr/bin/env bash
# =============================================================================
# Tests for the dual-name rendering of values.yaml (HOST_MODE=proxy keeping the
# LAN names alongside the public ones).
#
# Two failures are being guarded against, and both produce a box that installs
# cleanly and is then wrong:
#
#   • the LAN block leaking into a box that has no LAN names. `#@local` is a
#     comment, so a broken deletion does not fail the YAML parse — it renders
#     an Ingress rule for the literal string `@LOCAL_APP_HOST@` and Traefik
#     serves it.
#   • the two names not serving the same thing. The public host routes
#     /socket.io/, /wb-desktop/ and /dav/ to port 3001; a LAN host that only
#     got `/` looks perfect until someone opens a document or a meeting.
#
# The substitution pipeline is EXTRACTED from lib/suite.sh rather than copied,
# so a token added there and forgotten here shows up as an unsubstituted
# @TOKEN@ in the assertions below instead of passing silently.
# =============================================================================
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok() { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
ko() { printf '  \033[31mFAIL\033[0m %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail+1)); }

# --- the values under test ---------------------------------------------------
# Deliberately NOT the defaults: a substitution that silently does nothing
# still leaves a plausible-looking file when the token and its value match.
export DOMAIN=box.diwy.ai
export APP_HOST=acme.box.diwy.ai OFFICE_HOST=acme-office.box.diwy.ai
export LIVEKIT_HOST=acme-livekit.box.diwy.ai TURN_HOST=acme-turn.box.diwy.ai
export APP_TLS_SECRET=drive-tls OFFICE_TLS_SECRET=drive-onlyoffice-tls
export LIVEKIT_TLS_SECRET=drive-livekit-tls TURN_TLS_SECRET=drive-turn-tls
export LOCAL_OFFICE_HOST=office.suite366.local LOCAL_LIVEKIT_HOST=livekit.suite366.local
export LOCAL_APP_TLS_SECRET=drive-local-tls
export LOCAL_OFFICE_TLS_SECRET=drive-onlyoffice-local-tls
export LOCAL_LIVEKIT_TLS_SECRET=drive-livekit-local-tls
export CLUSTER_ISSUER=suite366-local-ca HOST_IP=10.0.0.1 SUITE_IP=10.9.9.1
export PROXY_PORT=8000 LLM_MODEL=m EMBED_MODEL=e VLLM_API_KEY=sk-test
export VLLM_EMBEDDING_DIMENSIONS=1024 VLLM_MAX_CONTEXT_WINDOW=8192
export SANDBOX_NAMESPACE=sandbox DATA_DIR=/opt/suite366
export cert_annotation='suite366.ai/tls-mode: "pushed"' turn_cert_manager=false
export lpk_esc=PUBKEY

# `fetch` is how install.sh reads a shipped file; in the test it is the repo.
fetch() { cat "$REPO/$1"; }
export -f fetch

# Pull the two things that decide the outcome straight out of lib/suite.sh:
# the `#@local` expressions, and the sed pipeline they feed.
eval "$(sed -n '/^appliance_origins_json() {/,/^}/p' "$REPO/lib/suite.sh")"
PIPELINE="$(awk '/\| sed -e "\$local_lines"/,/> "\$vals" \)/' "$REPO/lib/suite.sh" \
            | sed -e 's|> "\$vals" )||' -e '$ s|\\[[:space:]]*$||')"
[[ -n "$PIPELINE" ]] || { echo "could not extract the sed pipeline from lib/suite.sh"; exit 1; }

render() { # render <keep-local:0|1> <outfile>
  local keep="$1" out="$2"
  if (( keep )); then
    local_lines='s|[[:space:]]*#@local$||'
    LOCAL_APP_HOST=drive.suite366.local
    origins="$(appliance_origins_json)"
  else
    local_lines='/#@local$/d'
    LOCAL_APP_HOST=""; origins=""
  fi
  eval "fetch values.yaml $PIPELINE" > "$out"
}

echo "== a box without LAN names renders exactly what it always did =="
render 0 "$WORK/plain.yaml"
# `@[A-Z_]@`, not a bare `@`: values.yaml legitimately contains an e-mail
# address, and the comment header names the tokens it documents.
left="$(grep -o '@[A-Z_][A-Z_]*@' "$WORK/plain.yaml" | sort -u | tr '\n' ' ')"
[[ -z "$left" ]] && ok "every token is substituted" || ko "every token is substituted" "$left"
# Comments stripped first — the header explains what the .local defaults are.
sed 's/#.*//' "$WORK/plain.yaml" | grep -q 'suite366[.]local' \
  && ko "no LAN name survives" "$(sed 's/#.*//' "$WORK/plain.yaml" | grep -n 'suite366[.]local' | head -1)" \
  || ok "no LAN name survives"
grep -q '#@local$' "$WORK/plain.yaml" && ko "no marker survives" || ok "no marker survives"
grep -q 'APPLIANCE_ORIGINS' "$WORK/plain.yaml" \
  && ko "APPLIANCE_ORIGINS is absent (the app keeps its single canonical origin)" \
  || ok "APPLIANCE_ORIGINS is absent (the app keeps its single canonical origin)"
# Byte-for-byte against a checked-in golden, captured from the render that
# predates the dual-name work. Not a diff against HEAD: that stops being a
# comparison the moment this lands. A legitimate change to values.yaml has to
# update the golden, which puts the diff in front of a reviewer instead of
# leaving it to be discovered on a customer's box.
GOLDEN="$REPO/tools/testdata/values-plain.rendered.yaml"
if [[ "${UPDATE_GOLDEN:-0}" == "1" ]]; then
  mkdir -p "$(dirname "$GOLDEN")"; cp "$WORK/plain.yaml" "$GOLDEN"
  printf '  \033[33mUPDATED\033[0m %s\n' "${GOLDEN#"$REPO"/}"
fi
if [[ -f "$GOLDEN" ]]; then
  diff -q "$GOLDEN" "$WORK/plain.yaml" >/dev/null \
    && ok "byte-identical to the golden render (an unpublished box is untouched)" \
    || ko "byte-identical to the golden render (an unpublished box is untouched)" \
         "$(diff "$GOLDEN" "$WORK/plain.yaml" | head -4 | tr '\n' ' ') — rerun with UPDATE_GOLDEN=1 if intended"
else
  ko "golden render present" "$GOLDEN missing — generate it with UPDATE_GOLDEN=1"
fi

echo "== a published box serves both names =="
render 1 "$WORK/dual.yaml"
left="$(grep -o '@[A-Z_][A-Z_]*@' "$WORK/dual.yaml" | sort -u | tr '\n' ' ')"
[[ -z "$left" ]] && ok "every token is substituted" || ko "every token is substituted" "$left"
# Anchored: the header comment quotes `#@local` when explaining the mechanism.
grep -q '#@local$' "$WORK/dual.yaml" && ko "no marker survives" || ok "no marker survives"
grep -q -- '- host: acme.box.diwy.ai' "$WORK/dual.yaml" \
  && ok "the public name is an app ingress host" || ko "the public name is an app ingress host"
grep -q -- '- host: drive.suite366.local' "$WORK/dual.yaml" \
  && ok "the LAN name is an app ingress host too" || ko "the LAN name is an app ingress host too"
grep -q 'secretName: drive-local-tls' "$WORK/dual.yaml" \
  && ok "with its own TLS secret" || ko "with its own TLS secret"
grep -q 'host: office.suite366.local' "$WORK/dual.yaml" \
  && ok "onlyoffice gets the LAN name as an extraHost" || ko "onlyoffice gets the LAN name as an extraHost"
grep -q 'host: livekit.suite366.local' "$WORK/dual.yaml" \
  && ok "livekit gets the LAN name as an extraHost" || ko "livekit gets the LAN name as an extraHost"
# TURN is single-name on purpose (livekit reads one cert_file for one domain).
grep -q 'turn.suite366.local' "$WORK/dual.yaml" \
  && ko "TURN is NOT duplicated (livekit serves one TURN certificate)" \
  || ok "TURN is NOT duplicated (livekit serves one TURN certificate)"

echo "== the browser is told where to load things from =="
o="$(sed -n "s/.*APPLIANCE_ORIGINS: '\(.*\)'.*/\1/p" "$WORK/dual.yaml")"
[[ -n "$o" ]] && ok "APPLIANCE_ORIGINS is rendered" || ko "APPLIANCE_ORIGINS is rendered"
grep -q '"host":"drive.suite366.local"' <<<"$o" \
  && ok "  it maps the LAN name" || ko "  it maps the LAN name" "$o"
grep -q '"officeUrl":"https://office.suite366.local"' <<<"$o" \
  && ok "  to the LAN OnlyOffice" || ko "  to the LAN OnlyOffice" "$o"
grep -q '"livekitUrl":"wss://livekit.suite366.local"' <<<"$o" \
  && ok "  and the LAN LiveKit" || ko "  and the LAN LiveKit" "$o"
grep -q '"host":"acme.box.diwy.ai"' <<<"$o" \
  && ok "  and keeps the public name mapped to the public services" \
  || ko "  and keeps the public name mapped to the public services" "$o"
# The canonical origin is what e-mail links and the OnlyOffice callback use; it
# must stay the public name whatever the browser is told.
grep -q '^  APP_URL: https://acme.box.diwy.ai$' "$WORK/dual.yaml" \
  && ok "APP_URL stays canonical (public)" || ko "APP_URL stays canonical (public)"
grep -q '^  ONLYOFFICE_URL: https://acme-office.box.diwy.ai$' "$WORK/dual.yaml" \
  && ok "ONLYOFFICE_URL stays canonical (public)" || ko "ONLYOFFICE_URL stays canonical (public)"

# Structural checks need a YAML parser. Optional, like the real-restic half of
# tools/test-backup.sh: absent, the greps above already cover the failures that
# produced a broken box.
if python3 -c 'import yaml' 2>/dev/null; then
  echo "== structure (PyYAML) =="
  out="$(python3 - "$WORK/dual.yaml" "$WORK/plain.yaml" <<'PY'
import sys, json, yaml
dual = yaml.safe_load(open(sys.argv[1])); plain = yaml.safe_load(open(sys.argv[2]))
def check(label, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + label + ((" — " + str(detail)) if not cond and detail else ""))
h = dual["ingress"]["hosts"]
check("two app ingress hosts", len(h) == 2, [x["host"] for x in h])
check("both serve the same paths", h[0]["paths"] == h[1]["paths"],
      [[p["path"] for p in x["paths"]] for x in h])
check("both route socket.io/dav to port 3001",
      all(p["port"] == 3001 for x in h for p in x["paths"] if p["path"] != "/"))
t = dual["ingress"]["tls"]
check("one TLS entry per host", sorted(x for e in t for x in e["hosts"]) ==
      sorted(x["host"] for x in h), t)
check("the two TLS secrets are distinct", t[0]["secretName"] != t[1]["secretName"], t)
o = json.loads(dual["config"]["APPLIANCE_ORIGINS"])
check("APPLIANCE_ORIGINS is valid JSON with both names",
      {e["host"] for e in o} == {x["host"] for x in h}, o)
check("every origin carries all four URLs",
      all({"appUrl","wsUrl","officeUrl","livekitUrl"} <= set(e) for e in o))
check("a plain box has ONE app ingress host", len(plain["ingress"]["hosts"]) == 1)
check("a plain box has no extraHosts",
      plain["onlyoffice"]["ingress"].get("extraHosts") is None and
      plain["livekit"]["ingress"].get("extraHosts") is None)
PY
)"
  while read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      PASS*) ok "${line#PASS }" ;;
      *)     ko "${line#FAIL }" ;;
    esac
  done <<<"$out"
else
  printf '  \033[33mSKIP\033[0m structural checks (no PyYAML)\n'
fi

echo
printf '%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" == 0 ]]
