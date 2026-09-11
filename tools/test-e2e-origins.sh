#!/usr/bin/env bash
# =============================================================================
# End-to-end test of per-origin behaviour, run ON an appliance.
#
# Everything else in tools/ tests a decision in isolation. This one signs in as
# a real user over HTTPS, uploads a real document, and asks the running app
# what it would hand a browser — once per name the box answers to. It is the
# only check that exercises the whole chain: Traefik's SNI routing, the two
# certificate chains, the Host header, APPLIANCE_ORIGINS, and the app's own
# split between "what the browser loads" and "what the server calls".
#
# The distinction it exists to protect, and which no unit test can observe on a
# live box:
#
#   the OnlyOffice URL the browser loads  MUST follow the name it arrived on
#   the callback URL OnlyOffice calls back  MUST stay the canonical public name
#
# Get that backwards and documents stop saving — for some users, on some names,
# days after an unrelated change.
#
#   sudo tools/test-e2e-origins.sh
#
# Creates a throwaway organisation and user, and deletes both on exit (also on
# failure). Nothing else in the database is touched.
# =============================================================================
set -uo pipefail

DATA_DIR="${DATA_DIR:-/opt/suite366}"
[[ -f "$DATA_DIR/update.env" ]] || { echo "no $DATA_DIR/update.env — run this on an appliance."; exit 1; }
# shellcheck disable=SC1091
. "$DATA_DIR/update.env"
NAMESPACE="${NAMESPACE:-suite366}"
export KUBECONFIG="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"
CA="${CA:-/usr/local/share/suite366-local-ca.crt}"

pass=0; fail=0; skip=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; pass=$((pass+1)); }
ko()   { printf '  \033[31mFAIL\033[0m %s%s\n' "$1" "${2:+ — $2}"; fail=$((fail+1)); }
note() { printf '  \033[33mSKIP\033[0m %s%s\n' "$1" "${2:+ — $2}"; skip=$((skip+1)); }
head_() { printf '\n== %s ==\n' "$1"; }

kc()   { k3s kubectl "$@"; }
psql_() { kc -n "$NAMESPACE" exec deploy/drive-postgres -- psql -U suite366 -d suite366 -tAc "$1" 2>/dev/null; }
# `psql -tAc` prints the command tag ("INSERT 0 1") after a RETURNING row, and
# collapsing whitespace glues the two together into an id that looks plausible
# and fails a foreign key three statements later. First line, trimmed.
scalar() { psql_ "$1" | head -1 | tr -d "[:space:]"; }

WORK="$(mktemp -d)"; chmod 0700 "$WORK"
USER_ID=""; FILE_ID=""; declare -A JAR
# The LiveKit access token, minted exactly as the app mints it: HS256 over the
# API secret. Written out rather than inlined so the quoting stays readable.
cat > "$WORK/mint.py" <<'MINT'
import base64, hashlib, hmac, json, os, time
def b64(b): return base64.urlsafe_b64encode(b).rstrip(b'=').decode()
now = int(time.time())
hdr = b64(json.dumps({"alg": "HS256", "typ": "JWT"}, separators=(',', ':')).encode())
pl = b64(json.dumps({
    "iss": os.environ["LK_KEY"], "sub": "e2e-probe", "nbf": now, "exp": now + 120,
    "video": {"room": "e2e-origins-probe", "roomJoin": True,
              "canPublish": False, "canSubscribe": True},
}, separators=(',', ':')).encode())
sig = b64(hmac.new(os.environ["LK_SECRET"].encode(), f"{hdr}.{pl}".encode(),
                   hashlib.sha256).digest())
print(f"{hdr}.{pl}.{sig}")
MINT
EMAIL="e2e-origins-$$@suite366.invalid"
ORG_SLUG="e2e-origins-$$"
# Order matters and is not obvious: File_ownerId_fkey is RESTRICT, so the user
# cannot go until their files do. The first version of this deleted the user
# first, the statement failed, psql's stderr went to /dev/null, and three runs
# left three accounts behind before anyone counted. Deletions are verified here
# for the same reason every other check in this repo is: a cleanup that reports
# nothing is indistinguishable from one that did nothing.
cleanup() {
  # Through the API while the session lasts, so the object leaves MinIO too;
  # SQL only mops up what that could not reach.
  if [[ -n "${FILE_ID:-}" && -n "${JAR[public]:-}" ]]; then
    fetch "$APP_HOST" "/api/files/$FILE_ID" -b "${JAR[public]}" -X DELETE -o /dev/null
  fi
  if [[ -n "${USER_ID:-}" ]]; then
    psql_ "DELETE FROM \"File\" WHERE \"ownerId\" = '$USER_ID';" >/dev/null
    psql_ "DELETE FROM \"User\" WHERE id = '$USER_ID';" >/dev/null
  fi
  psql_ "DELETE FROM \"Organization\" WHERE slug = '$ORG_SLUG';" >/dev/null
  local left
  left="$(scalar "SELECT (SELECT count(*) FROM \"User\" WHERE email = '$EMAIL')
                       + (SELECT count(*) FROM \"Organization\" WHERE slug = '$ORG_SLUG');")"
  if [[ "$left" != "0" ]]; then
    printf '  \033[31m!!\033[0m cleanup left %s row(s) behind: user %s / org %s\n' \
      "$left" "$EMAIL" "$ORG_SLUG" >&2
  fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# Traefik routes on SNI, so the name must be in the request; the box's own
# resolver is not part of what is being tested (and does not resolve multi-label
# .local anyway). --resolve pins each name to the node, exactly as a LAN client
# that resolved it over mDNS would have.
NODE_IP="$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')"
[[ -n "$NODE_IP" ]] || { echo "no LAN IP on this host"; exit 1; }

# curl for a given name: pin it to this node and trust the right CA.
CURL_PUBLIC=(--resolve "x:443:$NODE_IP")
fetch() { # fetch HOST PATH [curl args...]
  local host="$1" path="$2"; shift 2
  local -a args=(-s -m 30 --resolve "$host:443:$NODE_IP")
  [[ "$host" == *.local && -s "$CA" ]] && args+=(--cacert "$CA")
  curl "${args[@]}" "$@" "https://$host$path"
}

echo "appliance : $APP_HOST${LOCAL_APP_HOST:+  +  $LOCAL_APP_HOST}"
echo "node      : $NODE_IP"

# --- a real account ----------------------------------------------------------
head_ "a real account, created for this run only"
HASH="$(python3 -c "
import bcrypt,sys
print(bcrypt.hashpw(sys.argv[1].encode(), bcrypt.gensalt(12)).decode())" "e2e-Passw0rd!" 2>/dev/null)"
if [[ -z "$HASH" ]]; then echo "python3 bcrypt unavailable — cannot create the test user"; exit 1; fi

ORG_ID="$(scalar "INSERT INTO \"Organization\" (id,name,slug,\"createdAt\",\"updatedAt\")
  VALUES (gen_random_uuid()::text,'E2E origins','$ORG_SLUG',now(),now())
  ON CONFLICT (slug) DO UPDATE SET name=EXCLUDED.name RETURNING id;")"
[[ -n "$ORG_ID" ]] && ok "organisation created" || { ko "organisation created"; exit 1; }

USER_ID="$(scalar "INSERT INTO \"User\" (id,email,name,\"passwordHash\",\"emailVerified\",\"createdAt\",\"updatedAt\",\"defaultOrganizationId\")
  VALUES (gen_random_uuid()::text,'$EMAIL','E2E Origins','$HASH',now(),now(),now(),'$ORG_ID')
  RETURNING id;")"
[[ -n "$USER_ID" ]] && ok "user created" || { ko "user created"; exit 1; }

# Only the columns that exist and have no default: this table carries
# invitedAt/joinedAt, not the createdAt/updatedAt pair the other models use.
psql_ "INSERT INTO \"OrganizationMember\" (id,\"organizationId\",\"userId\",role)
  VALUES (gen_random_uuid()::text,'$ORG_ID','$USER_ID','OWNER')
  ON CONFLICT DO NOTHING;" >/dev/null
[[ -n "$(psql_ "SELECT 1 FROM \"OrganizationMember\" WHERE \"userId\"='$USER_ID';")" ]] \
  && ok "membership created (OWNER)" || ko "membership created (OWNER)"

# --- sign in, once per name --------------------------------------------------
# NextAuth credentials over its REST surface: /api/auth/csrf then the callback.
signin() { # signin HOST JAR -> 0 on success
  local host="$1" jar="$2" csrf
  rm -f "$jar"
  csrf="$(fetch "$host" "/api/auth/csrf" -c "$jar" | python3 -c "import json,sys;print(json.load(sys.stdin)['csrfToken'])" 2>/dev/null)"
  [[ -n "$csrf" ]] || return 1
  fetch "$host" "/api/auth/callback/credentials" -b "$jar" -c "$jar" -o /dev/null \
    --data-urlencode "csrfToken=$csrf" \
    --data-urlencode "email=$EMAIL" \
    --data-urlencode "password=e2e-Passw0rd!" \
    --data-urlencode "redirect=false" || return 1
  fetch "$host" "/api/auth/session" -b "$jar" | grep -q "$EMAIL"
}

head_ "signing in over each name"
for pair in "public:$APP_HOST" "lan:${LOCAL_APP_HOST:-}"; do
  side="${pair%%:*}"; host="${pair#*:}"
  [[ -n "$host" ]] || { note "$side: no LAN name on this box"; continue; }
  JAR[$side]="$WORK/$side.jar"
  if signin "$host" "${JAR[$side]}"; then ok "signed in on $host"; else ko "signed in on $host"; unset 'JAR[$side]'; fi
done
[[ -n "${JAR[public]:-}" ]] || { echo; echo "cannot continue without a session on the public name."; exit 1; }

# --- a real document ----------------------------------------------------------
head_ "a real document"
# A minimal but genuine .docx: OnlyOffice is asked about THIS file, so a text
# file renamed .docx would be rejected before the question is even reached.
python3 - "$WORK/e2e.docx" <<'PY'
import sys, zipfile
p = sys.argv[1]
ct = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
<Default Extension="xml" ContentType="application/xml"/>
<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>
</Types>'''
rels = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>
</Relationships>'''
doc = '''<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
<w:body><w:p><w:r><w:t>suite366 e2e</w:t></w:r></w:p></w:body></w:document>'''
with zipfile.ZipFile(p, 'w', zipfile.ZIP_DEFLATED) as z:
    z.writestr('[Content_Types].xml', ct); z.writestr('_rels/.rels', rels)
    z.writestr('word/document.xml', doc)
PY
up="$(fetch "$APP_HOST" "/api/files/upload" -b "${JAR[public]}" -F "file=@$WORK/e2e.docx;type=application/vnd.openxmlformats-officedocument.wordprocessingml.document")"
FILE_ID="$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read() or '{}')
print(d.get('fileId') or (d.get('file') or {}).get('id') or '')" <<<"$up" 2>/dev/null)"
if [[ -n "$FILE_ID" ]]; then ok "document uploaded ($FILE_ID)"; else ko "document uploaded" "$(head -c 200 <<<"$up")"; fi

# --- the question this file exists to ask ------------------------------------
head_ "what the app hands a browser, per name"
host_of() { sed -E 's#^[a-z]+://([^/]+).*#\1#' <<<"$1"; }

declare -A API_URL CALLBACK
for side in public lan; do
  [[ -n "${JAR[$side]:-}" && -n "$FILE_ID" ]] || continue
  host="$APP_HOST"; [[ "$side" == lan ]] && host="$LOCAL_APP_HOST"
  body="$(fetch "$host" "/api/onlyoffice/config?fileId=$FILE_ID&mode=edit" -b "${JAR[$side]}")"
  API_URL[$side]="$(python3 -c "import json,sys;print(json.loads(sys.stdin.read() or '{}').get('apiUrl',''))" <<<"$body" 2>/dev/null)"
  CALLBACK[$side]="$(python3 -c "
import json,sys
d=json.loads(sys.stdin.read() or '{}')
print(((d.get('config') or {}).get('editorConfig') or {}).get('callbackUrl','') or (d.get('config') or {}).get('callbackUrl',''))" <<<"$body" 2>/dev/null)"
  if [[ -n "${API_URL[$side]}" ]]; then
    ok "$side: the editor script URL is served ($(host_of "${API_URL[$side]}"))"
  else
    ko "$side: the editor script URL is served" "$(head -c 200 <<<"$body")"
  fi
done

# The browser-facing URL follows the name. This is the whole feature.
if [[ -n "${API_URL[public]:-}" ]]; then
  [[ "$(host_of "${API_URL[public]}")" == "$OFFICE_HOST" ]] \
    && ok "public name -> public OnlyOffice ($OFFICE_HOST)" \
    || ko "public name -> public OnlyOffice" "${API_URL[public]}"
fi
if [[ -n "${API_URL[lan]:-}" ]]; then
  [[ "$(host_of "${API_URL[lan]}")" == "$LOCAL_OFFICE_HOST" ]] \
    && ok "LAN name -> LAN OnlyOffice ($LOCAL_OFFICE_HOST)" \
    || ko "LAN name -> LAN OnlyOffice" "${API_URL[lan]}"
  [[ "${API_URL[lan]}" != "${API_URL[public]:-}" ]] \
    && ok "the two names really differ" || ko "the two names really differ"
fi

# The server-facing URL must NOT follow the request. What it points at is a
# deployment choice — this appliance sets ONLYOFFICE_INTERNAL_APP_URL to the
# in-cluster Service, which is better than either public name (no DNS detour,
# no TLS) — but it must be the SAME whichever name the browser used, and it
# must never be the LAN name: that would be a server-side call across a
# local-CA certificate, which is exactly how document saving breaks.
if [[ -n "${CALLBACK[public]:-}" ]]; then
  ok "the OnlyOffice callback is set ($(host_of "${CALLBACK[public]}"))"
  if [[ -n "${CALLBACK[lan]:-}" ]]; then
    [[ "${CALLBACK[lan]}" == "${CALLBACK[public]}" ]] \
      && ok "  and is identical on both names" \
      || ko "  and is identical on both names" "lan=${CALLBACK[lan]}"
  fi
  for side in public lan; do
    [[ -n "${CALLBACK[$side]:-}" ]] || continue
    [[ -n "${LOCAL_APP_HOST:-}" && "$(host_of "${CALLBACK[$side]}")" == "$LOCAL_APP_HOST" ]] \
      && ko "  $side: it must never be the LAN name" "${CALLBACK[$side]}" \
      || ok "  $side: it is not the LAN name"
  done
else
  ko "the OnlyOffice callback is set"
fi

# --- and it is not just a string: the editor really serves there --------------
head_ "the editor script actually loads from each name"
for side in public lan; do
  u="${API_URL[$side]:-}"; [[ -n "$u" ]] || continue
  h="$(host_of "$u")"; p="${u#*://$h}"
  code="$(fetch "$h" "$p" -o /dev/null -w '%{http_code}')"
  [[ "$code" == "200" ]] && ok "$side: GET $h$p -> 200" || ko "$side: GET $h$p" "HTTP $code"
done

# --- LiveKit: a real signalling check, on each name ---------------------------
# The runtime config already says which socket the browser is told to open; this
# proves the socket is actually there and would accept a join, over each name's
# own certificate. The token is minted from the cluster secret, which is what
# the app does — nothing here is simulated except the participant.
head_ "LiveKit authorises a join, per name"
LK_KEY=""; LK_SECRET=""
for sec in $(kc -n "$NAMESPACE" get secret -o name 2>/dev/null | sed "s|secret/||"); do
  LK_KEY="$(kc -n "$NAMESPACE" get secret "$sec" -o jsonpath="{.data.LIVEKIT_API_KEY}" 2>/dev/null | base64 -d 2>/dev/null)"
  LK_SECRET="$(kc -n "$NAMESPACE" get secret "$sec" -o jsonpath="{.data.LIVEKIT_API_SECRET}" 2>/dev/null | base64 -d 2>/dev/null)"
  [[ -n "$LK_KEY" && -n "$LK_SECRET" ]] && break
done
if [[ -z "$LK_KEY" || -z "$LK_SECRET" ]]; then
  note "LiveKit credentials not found in ns/$NAMESPACE"
else
  TOKEN="$(LK_KEY="$LK_KEY" LK_SECRET="$LK_SECRET" python3 "$WORK/mint.py")"
  for side in public lan; do
    host="$LIVEKIT_HOST"; [[ "$side" == lan ]] && host="${LOCAL_LIVEKIT_HOST:-}"
    [[ -n "$host" ]] || { note "$side: no LiveKit name"; continue; }
    # /rtc/validate runs the same token check the WebSocket upgrade performs, so
    # a 200 means: this name reached LiveKit, its certificate was accepted, and
    # the join would be authorised.
    code="$(fetch "$host" "/rtc/validate?access_token=$TOKEN" -o "$WORK/lk-$side.txt" -w "%{http_code}")"
    [[ "$code" == "200" ]] \
      && ok "$side: LiveKit authorised a join over $host" \
      || ko "$side: LiveKit authorised a join over $host" "HTTP $code $(head -c 120 "$WORK/lk-$side.txt" 2>/dev/null)"
  done
  # And one it must refuse, so that the 200s above mean something.
  code="$(fetch "$LIVEKIT_HOST" "/rtc/validate?access_token=not-a-token" -o /dev/null -w "%{http_code}")"
  [[ "$code" != "200" ]] && ok "an invalid token is refused (HTTP $code)" \
    || ko "an invalid token is refused" "it returned 200"
fi

echo
printf '%d passed, %d failed, %d skipped\n' "$pass" "$fail" "$skip"
[[ "$fail" == 0 ]]
