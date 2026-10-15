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
#   • the proxy-mode alias wildcard (`#@proxy`) either leaking into a box that
#     is not published, or missing a route / the AUTH_URL swap on one that is.
#     An alias added on the proxy later must work without touching the box,
#     so whatever it needs has to be in the render from day one.
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
export PROXY_PORT=8000 LLM_MODEL=m EMBED_MODEL=e EMBED_MODEL_SERVED=e LLM_STT_MODEL=s VLLM_API_KEY=sk-test
export VLLM_EMBEDDING_DIMENSIONS=1024 VLLM_MAX_CONTEXT_WINDOW=8192
export SANDBOX_NAMESPACE=sandbox DATA_DIR=/opt/suite366
export cert_annotation='suite366.ai/tls-mode: "pushed"' turn_cert_manager=false
export lpk_esc=PUBKEY
# Instance licence + appliance administrator: both deliberately non-default
# too. The token is a forged three-segment shape, never verified here.
export LICENSE_KEY=eyJhbGciOiJFZERTQSJ9.eyJzY29wZSI6Imluc3RhbmNlIn0.c2ln ADMIN_EMAIL=ops@acme.example

# `fetch` is how install.sh reads a shipped file; in the test it is the repo.
fetch() { cat "$REPO/$1"; }
export -f fetch

# Pull the three things that decide the outcome straight out of lib/suite.sh:
# the tag expressions (`#@local`, `#@proxy`, `#@!proxy`, `#@origins`), the
# origins JSON, and the sed pipeline they feed.
eval "$(sed -n '/^appliance_origins_json() {/,/^}/p' "$REPO/lib/suite.sh")"
TAGS="$(awk '/^  local local_lines /,/^  local cert_annotation/' "$REPO/lib/suite.sh" | sed '$d')"
[[ "$TAGS" == *proxy_lines* ]] || { echo "could not extract the tag expressions from lib/suite.sh"; exit 1; }
PIPELINE="$(awk '/\| sed -e "\$local_lines"/,/> "\$vals" \)/' "$REPO/lib/suite.sh" \
            | sed -e 's|> "\$vals" )||' -e '$ s|\\[[:space:]]*$||')"
[[ -n "$PIPELINE" ]] || { echo "could not extract the sed pipeline from lib/suite.sh"; exit 1; }

render() { # render <HOST_MODE> <with-LAN-names:0|1> <outfile>
  local HOST_MODE="$1" lan="$2" out="$3" LOCAL_APP_HOST=""
  (( lan )) && LOCAL_APP_HOST=drive.suite366.local
  eval "$TAGS"
  eval "fetch values.yaml $PIPELINE" > "$out"
}

echo "== a box without LAN names renders exactly what it always did =="
render mdns 0 "$WORK/plain.yaml"
# `@[A-Z_]@`, not a bare `@`: values.yaml legitimately contains an e-mail
# address, and the comment header names the tokens it documents.
left="$(grep -o '@[A-Z_][A-Z_]*@' "$WORK/plain.yaml" | sort -u | tr '\n' ' ')"
[[ -z "$left" ]] && ok "every token is substituted" || ko "every token is substituted" "$left"
# Comments stripped first — the header explains what the .local defaults are.
sed 's/#.*//' "$WORK/plain.yaml" | grep -q 'suite366[.]local' \
  && ko "no LAN name survives" "$(sed 's/#.*//' "$WORK/plain.yaml" | grep -n 'suite366[.]local' | head -1)" \
  || ok "no LAN name survives"
grep -Eq '#@(local|!?proxy|origins)$' "$WORK/plain.yaml" && ko "no marker survives" || ok "no marker survives"
sed 's/#.*//' "$WORK/plain.yaml" | grep -q '[*][.]' \
  && ko "no alias wildcard outside proxy mode" || ok "no alias wildcard outside proxy mode"
grep -q '^  AUTH_URL: https://acme.box.diwy.ai$' "$WORK/plain.yaml" \
  && ok "AUTH_URL is still pinned outside proxy mode" || ko "AUTH_URL is still pinned outside proxy mode"
grep -q 'AUTH_TRUST_HOST' "$WORK/plain.yaml" \
  && ko "no AUTH_TRUST_HOST outside proxy mode" || ok "no AUTH_TRUST_HOST outside proxy mode"
grep -q 'APPLIANCE_ORIGINS' "$WORK/plain.yaml" \
  && ko "APPLIANCE_ORIGINS is absent (the app keeps its single canonical origin)" \
  || ok "APPLIANCE_ORIGINS is absent (the app keeps its single canonical origin)"
grep -q '^  LICENSE_KEY: "eyJhbGciOiJFZERTQSJ9.eyJzY29wZSI6Imluc3RhbmNlIn0.c2ln"$' "$WORK/plain.yaml" \
  && ok "the instance licence lands under secrets:" || ko "the instance licence lands under secrets:"
grep -q '^  APPLIANCE_ADMIN_EMAIL: "ops@acme.example"$' "$WORK/plain.yaml" \
  && ok "the appliance administrator lands under config:" || ko "the appliance administrator lands under config:"
if python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); assert d['secrets']['LICENSE_KEY'].startswith('eyJ') and d['secrets']['VLLM_API_KEY']=='sk-test'; assert d['config']['APPLIANCE_ADMIN_EMAIL']=='ops@acme.example'; assert d['sandbox']['workbench']['limits']['maxPerOrg']=='8'" "$WORK/plain.yaml" 2>/dev/null; then
  ok "YAML: licence and VLLM key both under secrets, admin under config, workbench capped per org (quoted)"
else
  ko "YAML: licence and VLLM key both under secrets, admin under config, workbench capped per org (quoted)"
fi
# An unlicensed box renders an EMPTY value, not a missing key or a broken file:
# the app's trim() reads "" as "no licence", and the daily converge never has
# to add the line later.
( export LICENSE_KEY=""; render mdns 0 "$WORK/unlicensed.yaml" )
grep -q '^  LICENSE_KEY: ""$' "$WORK/unlicensed.yaml" \
  && ok "an unlicensed box renders an empty LICENSE_KEY (valid YAML, nothing to add later)" \
  || ko "an unlicensed box renders an empty LICENSE_KEY (valid YAML, nothing to add later)"
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
# HOST_MODE=dns takes the same branches as mdns (no LAN names, not proxy).
render dns 0 "$WORK/plain-dns.yaml"
cmp -s "$WORK/plain.yaml" "$WORK/plain-dns.yaml" \
  && ok "HOST_MODE=dns renders the same file" || ko "HOST_MODE=dns renders the same file"

echo "== a published box serves both names =="
render proxy 1 "$WORK/dual.yaml"
left="$(grep -o '@[A-Z_][A-Z_]*@' "$WORK/dual.yaml" | sort -u | tr '\n' ' ')"
[[ -z "$left" ]] && ok "every token is substituted" || ko "every token is substituted" "$left"
# Anchored: the header comment quotes `#@local` when explaining the mechanism.
grep -Eq '#@(local|!?proxy|origins)$' "$WORK/dual.yaml" && ko "no marker survives" || ok "no marker survives"
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
grep -q '^  LIVEKIT_PUBLIC_URL: wss://acme-livekit.box.diwy.ai$' "$WORK/dual.yaml" \
  && ok "LIVEKIT_PUBLIC_URL stays the native infra name" || ko "LIVEKIT_PUBLIC_URL stays the native infra name"
grep -q '^  WS_URL: wss://acme.box.diwy.ai$' "$WORK/dual.yaml" \
  && ok "WS_URL stays native (server-side DAV base; browsers get theirs from APPLIANCE_ORIGINS)" \
  || ko "WS_URL stays native (server-side DAV base; browsers get theirs from APPLIANCE_ORIGINS)"

echo "== aliases added on the proxy work without touching the box =="
grep -q '^ *AUTH_URL:' "$WORK/dual.yaml" \
  && ko "AUTH_URL is NOT set (Auth.js follows the request host)" "$(grep -n '^ *AUTH_URL:' "$WORK/dual.yaml")" \
  || ok "AUTH_URL is NOT set (Auth.js follows the request host)"
grep -q '^  AUTH_TRUST_HOST: "true"$' "$WORK/dual.yaml" \
  && ok "AUTH_TRUST_HOST is \"true\"" || ko "AUTH_TRUST_HOST is \"true\""
grep -q -- '- host: "\*.box.diwy.ai"' "$WORK/dual.yaml" \
  && ok "the alias wildcard is an app ingress host" || ko "the alias wildcard is an app ingress host"
grep -q '^      hosts: \[acme.box.diwy.ai, "\*.box.diwy.ai"\]$' "$WORK/dual.yaml" \
  && ok "drive-tls lists the wildcard next to the native name" \
  || ko "drive-tls lists the wildcard next to the native name"
grep -q '"host":"\*.box.diwy.ai","appUrl":"https://{host}","wsUrl":"wss://{host}","officeUrl":"https://acme-office.box.diwy.ai","livekitUrl":"wss://acme-livekit.box.diwy.ai"}' <<<"$o" \
  && ok "APPLIANCE_ORIGINS maps the wildcard to {host} + the native office/livekit" \
  || ko "APPLIANCE_ORIGINS maps the wildcard to {host} + the native office/livekit" "$o"

echo "== a published box without LAN names =="
render proxy 0 "$WORK/proxy.yaml"
left="$(grep -o '@[A-Z_][A-Z_]*@' "$WORK/proxy.yaml" | sort -u | tr '\n' ' ')"
[[ -z "$left" ]] && ok "every token is substituted" || ko "every token is substituted" "$left"
grep -Eq '#@(local|!?proxy|origins)$' "$WORK/proxy.yaml" && ko "no marker survives" || ok "no marker survives"
sed 's/#.*//' "$WORK/proxy.yaml" | grep -q 'suite366[.]local' \
  && ko "no LAN name survives" || ok "no LAN name survives"
op="$(sed -n "s/.*APPLIANCE_ORIGINS: '\(.*\)'.*/\1/p" "$WORK/proxy.yaml")"
[[ "$op" == '[{"host":"acme.box.diwy.ai",'*'{"host":"*.box.diwy.ai",'*']' ]] \
  && ok "APPLIANCE_ORIGINS is still rendered (native + wildcard)" \
  || ko "APPLIANCE_ORIGINS is still rendered (native + wildcard)" "$op"
grep -q '^ *AUTH_URL:' "$WORK/proxy.yaml" && ko "AUTH_URL is NOT set" || ok "AUTH_URL is NOT set"
grep -q '^  AUTH_TRUST_HOST: "true"$' "$WORK/proxy.yaml" \
  && ok "AUTH_TRUST_HOST is \"true\"" || ko "AUTH_TRUST_HOST is \"true\""
grep -q '^  APP_URL: https://acme.box.diwy.ai$' "$WORK/proxy.yaml" \
  && ok "APP_URL is the native name" || ko "APP_URL is the native name"

# Structural checks need a YAML parser. Optional, like the real-restic half of
# tools/test-backup.sh: absent, the greps above already cover the failures that
# produced a broken box.
if python3 -c 'import yaml' 2>/dev/null; then
  echo "== structure (PyYAML) =="
  out="$(python3 - "$WORK/dual.yaml" "$WORK/plain.yaml" "$WORK/proxy.yaml" <<'PY'
import sys, json, yaml
dual = yaml.safe_load(open(sys.argv[1])); plain = yaml.safe_load(open(sys.argv[2]))
proxy = yaml.safe_load(open(sys.argv[3]))
WILD = "*.box.diwy.ai"
def check(label, cond, detail=""):
    print(("PASS " if cond else "FAIL ") + label + ((" — " + str(detail)) if not cond and detail else ""))
h = dual["ingress"]["hosts"]
check("three app ingress hosts: native, alias wildcard, LAN",
      [x["host"] for x in h] == ["acme.box.diwy.ai", WILD, "drive.suite366.local"],
      [x["host"] for x in h])
check("all serve the same paths", all(x["paths"] == h[0]["paths"] for x in h),
      [[p["path"] for p in x["paths"]] for x in h])
check("all route socket.io/dav to port 3001",
      all(p["port"] == 3001 for x in h for p in x["paths"] if p["path"] != "/"))
t = dual["ingress"]["tls"]
check("every app host is covered by exactly one TLS entry",
      sorted(x for e in t for x in e["hosts"]) == sorted(x["host"] for x in h), t)
check("the wildcard rides on the native secret (drive-tls), the LAN name has its own",
      {e["secretName"]: e["hosts"] for e in t} ==
      {"drive-tls": ["acme.box.diwy.ai", WILD], "drive-local-tls": ["drive.suite366.local"]}, t)
o = json.loads(dual["config"]["APPLIANCE_ORIGINS"])
check("APPLIANCE_ORIGINS is valid JSON with every app host",
      {e["host"] for e in o} == {x["host"] for x in h}, o)
check("every origin carries all four URLs",
      all({"appUrl","wsUrl","officeUrl","livekitUrl"} <= set(e) for e in o))
w = [e for e in o if e["host"] == WILD]
check("the wildcard origin follows the request host for app/ws, native names for office/livekit",
      w == [{"host": WILD, "appUrl": "https://{host}", "wsUrl": "wss://{host}",
             "officeUrl": "https://acme-office.box.diwy.ai",
             "livekitUrl": "wss://acme-livekit.box.diwy.ai"}], w)
c = dual["config"]
check("proxy config: AUTH_TRUST_HOST, no AUTH_URL, APP_URL native",
      c.get("AUTH_TRUST_HOST") == "true" and "AUTH_URL" not in c
      and c["APP_URL"] == "https://acme.box.diwy.ai", {k: c.get(k) for k in ("AUTH_URL","AUTH_TRUST_HOST","APP_URL")})
ph = proxy["ingress"]["hosts"]
check("proxy without LAN: native + wildcard, same paths",
      [x["host"] for x in ph] == ["acme.box.diwy.ai", WILD] and ph[0]["paths"] == ph[1]["paths"],
      [x["host"] for x in ph])
check("proxy without LAN: one TLS entry, drive-tls with both",
      proxy["ingress"]["tls"] == [{"secretName": "drive-tls", "hosts": ["acme.box.diwy.ai", WILD]}],
      proxy["ingress"]["tls"])
po = json.loads(proxy["config"]["APPLIANCE_ORIGINS"])
check("proxy without LAN: origins = native + wildcard",
      [e["host"] for e in po] == ["acme.box.diwy.ai", WILD], po)
check("proxy without LAN: no extraHosts",
      proxy["onlyoffice"]["ingress"].get("extraHosts") is None and
      proxy["livekit"]["ingress"].get("extraHosts") is None)
# Traefik turns `*.box.diwy.ai` into a HostRegexp whose default priority (rule
# length) beats `Host(<native>-office...)`: without a pinned priority the app
# would answer on the OnlyOffice and LiveKit names.
def longest_wild(paths):
    rx = "HostRegexp(`^[a-zA-Z0-9-]+\\.box\\.diwy\\.ai$`)"
    return max(len(rx + " && PathPrefix(`" + p["path"] + "`)") for p in paths)
for name, doc in (("proxy+LAN", dual), ("proxy", proxy)):
    lw = longest_wild(doc["ingress"]["hosts"][1]["paths"])
    for svc in ("onlyoffice", "livekit"):
        a = (doc[svc]["ingress"].get("annotations") or {})
        pr = int(a.get("traefik.ingress.kubernetes.io/router.priority", "0"))
        check(f"{name}: {svc} router.priority ({pr}) outranks the alias wildcard (max {lw})", pr > lw, a)
for svc in ("onlyoffice", "livekit"):
    check(f"a plain box: no router.priority on {svc}", not plain[svc]["ingress"].get("annotations"))
check("a plain box keeps AUTH_URL and has no AUTH_TRUST_HOST",
      plain["config"].get("AUTH_URL") == "https://acme.box.diwy.ai" and "AUTH_TRUST_HOST" not in plain["config"])
check("a plain box: TLS hosts == rule hosts",
      plain["ingress"]["tls"] == [{"secretName": "drive-tls", "hosts": ["acme.box.diwy.ai"]}], plain["ingress"]["tls"])
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
