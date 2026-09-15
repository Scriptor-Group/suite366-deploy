# shellcheck shell=bash
# =============================================================================
# lib/vllm-db.sh — the FIFTH copy of VLLM_API_KEY, and the only one an LLM call
# actually reads.
#
# The key exists five times on an appliance:
#   1. $DATA_DIR/llm/.env                  written by deploy_vllm (lib/vllm.sh:24)
#   2. the vLLM containers' environment    read from (1) AT START ONLY — this is
#                                          the copy that VALIDATES a request
#   3. $DATA_DIR/values.yaml               written by deploy_suite (lib/suite.sh:90)
#   4. the chart's Secret -> the app's env
#   5. Postgres "AIProvider".config->>'apiKey'
#
# The app seeds (5) ONCE, at the first organization creation, out of (4) — see
# suite-366 serveur/src/lib/ai-providers/vllm-provider.ts:24-54 — with a plain
# `create` and no upsert, and it never re-reads its environment afterwards. Its
# resolver then PREFERS that row over the env fallback. So a key that changes
# anywhere in 1-4 leaves (5) stale and every LLM call in the app returns 401
# while `docker ps` says Up (healthy), every pod is Running, and the app's own
# provider health check reports HEALTHY — it writes that verdict without making
# any request at all (actions/ai-providers.ts:492). That combination ran for
# four days in production before anyone could name it.
#
# Hence both halves below: realign (5), then prove it by asking vLLM with the
# key read back OUT of Postgres. Asking with the installer's own copy is what
# the warmups at lib/vllm.sh:98-113 already do, and is exactly why they cannot
# catch this — they validate a path that cannot fail.
#
# Two things the row scope protects, and one escape hatch:
#   • an admin may legitimately add a VLLM provider pointing at ANOTHER vLLM
#     (actions/ai-providers.ts:114; the unique key is (organizationId, provider,
#     name)). Those rows are neither realigned nor blamed — see vllm_row_scope.
#   • a key deliberately edited in the UI for THIS box is overwritten, on
#     purpose: the only key that works here is the one the containers hold.
#   • PG_DEPLOY overrides Postgres discovery, as it does for backup.sh.
# =============================================================================

# >>> SHARED vllm-db BLOCK — duplicated VERBATIM into update.sh and backup.sh
# (they are fetched and run standalone and must not depend on lib/ being
# present: backup.sh:109-111). Re-sync with tools/sync-vllm-db-block.sh;
# tools/test-vllm-db.sh FAILS if the three copies drift.
# Every function here is extracted by that test with
# `sed -n "/^name() {/,/^}/p"`, so: no one-liner bodies, and no line inside a
# body may start with `}` at column 0. >>>

# The key and the URL are interpolated into a statement run as the database
# owner, so both are WHITELISTED rather than escaped — "it looks harmless" is
# not a security property (backup.sh:898-900 makes the same argument about
# repository strings). lib/preflight.sh:469 draws `sk-` + 32 base62 chars, but
# :467 parses a re-run's key out of values.yaml with `sk-[^"]*`, which a
# hand-edited file could turn into anything: assert the shape, never assume it.
vllm_key_sane() { # vllm_key_sane KEY
  [[ "$1" =~ ^[A-Za-z0-9._-]{8,200}$ ]]
}

# `_` is deliberately absent from the host class: this string also becomes the
# left side of a SQL LIKE, where `_` and `%` are wildcards. The port is
# REQUIRED — vllm_row_scope derives the LIKE prefix by stripping `:<port>/v1`,
# and a portless URL would yield the far too broad `http:%`.
vllm_url_sane() { # vllm_url_sane URL
  [[ "$1" =~ ^https?://[0-9A-Za-z.-]+:[0-9]{2,5}/v1$ ]]
}

# The rows that are aimed at THIS box, and nothing else: the app's own seed by
# name, a seed that carries no baseUrl at all, or a row already pointing here.
vllm_row_scope() { # vllm_row_scope URL -> SQL predicate
  local prefix="${1%:*}:"
  printf "provider = 'VLLM' AND (name = 'vLLM Local' OR config->>'baseUrl' IS NULL OR config->>'baseUrl' LIKE '%s%%')" "$prefix"
}

# Postgres deployment by name pattern, never hardcoded: the chart derives every
# resource name from `appName` (backup.sh:295-297). The `|| true` is not
# decoration — the pipeline's grep exits 1 when nothing matches, and under
# `set -o pipefail` that kills the CALLER before it can report why.
vllm_pg_deploy() {
  if [[ -n "${PG_DEPLOY:-}" ]]; then
    printf '%s' "$PG_DEPLOY"
    return 0
  fi
  kc -n "$NAMESPACE" get deploy -o name 2>/dev/null \
    | sed -n 's|^deployment.apps/||p' | grep -- '-postgres$' | head -1 || true
}

# The one curl here that is NOT `-fsS`, and it has to be: `-f` turns a 401 into
# exit 22 and throws the status code away, and the status code IS the answer.
# `|| true` sits INSIDE the substitution so curl's own "000" survives a connect
# failure (it prints 000 and exits 7).
vllm_http_code() { # vllm_http_code URL KEY TIMEOUT [JSON_BODY]
  local url="$1" key="$2" tmo="$3" body="${4:-}" code=""
  if [[ -n "$body" ]]; then
    code="$(curl -s -o /dev/null -m "$tmo" -w '%{http_code}' \
              -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
              --data-binary "$body" "$url" 2>/dev/null || true)"
  else
    code="$(curl -s -o /dev/null -m "$tmo" -w '%{http_code}' \
              -H "Authorization: Bearer $key" "$url" 2>/dev/null || true)"
  fi
  printf '%s' "${code:-000}"
}

# vLLM's api-key check is ASGI middleware: it runs BEFORE routing and before
# body validation. So 400/404/422/500 all mean the Authorization header was
# ACCEPTED and something else was wrong — which is what makes a cheap probe
# definitive. Only 401/403 is a bad key; only a transport failure or an nginx
# upstream error means vLLM was never reached.
vllm_verdict() { # vllm_verdict HTTP_CODE -> ok|denied|down
  case "$1" in
    401|403)            printf 'denied' ;;
    000|502|503|504|"") printf 'down' ;;
    *)                  printf 'ok' ;;
  esac
}

# Realign the stored row. Idempotent, and never fatal to its caller: a database
# that is not up yet, or an app whose migrations have not run, is a normal state
# during a first install.
reconcile_vllm_db_key() { # reconcile_vllm_db_key KEY BASE_URL
  local key="$1" url="$2" pg="" out="" scope=""
  if ! vllm_key_sane "$key"; then
    warn "vLLM provider key: '$key' is not a key shape this installer produces —"
    warn "  the AIProvider row was left alone and NO SQL was built."
    return 0
  fi
  if ! vllm_url_sane "$url"; then
    warn "vLLM provider key: '$url' is not a usable base URL (host:port required) —"
    warn "  the AIProvider row was left alone and NO SQL was built."
    return 0
  fi
  pg="$(vllm_pg_deploy)"
  if [[ -z "$pg" ]]; then
    warn "vLLM provider key: no *-postgres deployment in ns/$NAMESPACE — nothing to realign."
    return 0
  fi
  scope="$(vllm_row_scope "$url")"

  # One round trip, SQL on stdin. Three deliberate choices:
  #  • the `sh -c` argument is SINGLE-quoted so $POSTGRES_* expand INSIDE the
  #    pod (backup.sh:869's rule): no password on a host argv, and the API key
  #    never reaches an argv at all — it arrives on stdin.
  #  • the heredoc is UNQUOTED so the values interpolate, which is why the SQL
  #    contains no `$`, no backtick and no backslash-escape anywhere, and why
  #    the table guard is psql's `\if` rather than a `DO $$ ... $$` block.
  #  • the guard CANNOT live inside the statement: naming a missing table fails
  #    at PARSE time. `\if` discards the branch client-side, so nothing is sent.
  # The data-modifying CTE makes stdout a deterministic `realigned=N` from a
  # SELECT rather than psql's `UPDATE n` command tag, which `-q` suppresses.
  out="$(kc -n "$NAMESPACE" exec -i "deploy/$pg" -- \
           sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -tAq -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' 2>/dev/null <<SQL
SELECT CASE WHEN to_regclass('"public"."AIProvider"') IS NULL THEN 'off' ELSE 'on' END AS have_ai \gset
\if :have_ai
WITH realigned AS (
  UPDATE "public"."AIProvider"
     SET config = jsonb_set(
                    jsonb_set(coalesce(config, '{}'::jsonb),
                              '{apiKey}', to_jsonb('$key'::text), true),
                    '{baseUrl}', to_jsonb('$url'::text), true),
         "updatedAt" = now()
   WHERE $scope
     AND (config->>'apiKey' IS DISTINCT FROM '$key'
       OR config->>'baseUrl' IS DISTINCT FROM '$url')
  RETURNING 1
)
SELECT 'realigned=' || count(*) FROM realigned;
\else
\echo realigned=no-table
\endif
SQL
  )" || out=""
  case "$out" in
    realigned=no-table)
      info "vLLM provider key: no AIProvider table yet (the app's migrations have not run) — nothing to realign." ;;
    realigned=0)
      info "vLLM provider key: the stored row already matches this box." ;;
    realigned=[1-9]*)
      log "vLLM provider key: realigned ${out#realigned=} AIProvider row(s) onto the current key."
      info "  That row is the only copy an LLM call reads; a key change anywhere"
      info "  else leaves it stale and every call 401s with every pod Running." ;;
    "")
      warn "vLLM provider key: could not reach the database in deploy/$pg — row NOT realigned." ;;
    *)
      warn "vLLM provider key: unexpected psql output while realigning: $out" ;;
  esac
  :
}

# Read the key back OUT of Postgres and ask vLLM about it. Never dies: it
# records its verdict in VLLM_DB_VERIFIED and lets the caller decide. DEEP=1
# also exercises chat + embeddings (the two routes the nginx proxy sends to
# DIFFERENT containers), DEEP=0 stops at /v1/models.
verify_vllm_db_key() { # verify_vllm_db_key BASE_URL [DEEP]
  VLLM_DB_VERIFIED=unknown
  local url="$1" deep="${2:-0}" pg="" raw="" base="" dbkey="" scope=""
  local code="" verdict="" tries=2 i=0 bad=0
  local -a klist=()
  if ! vllm_url_sane "$url"; then
    warn "stored vLLM key NOT verified: '$url' is not a usable base URL."
    return 0
  fi
  pg="$(vllm_pg_deploy)"
  if [[ -z "$pg" ]]; then
    warn "stored vLLM key NOT verified: no *-postgres deployment in ns/$NAMESPACE."
    return 0
  fi
  base="${url%/v1}"
  scope="$(vllm_row_scope "$url")"

  # The SAME row scope the reconcile used, so the two can never disagree about
  # which row is ours. The `rows` sentinel is what separates "the table is there
  # and empty" from "psql never ran" — both are otherwise an empty string.
  raw="$(kc -n "$NAMESPACE" exec -i "deploy/$pg" -- \
           sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" psql -tAq -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -f -' 2>/dev/null <<SQL
SELECT CASE WHEN to_regclass('"public"."AIProvider"') IS NULL THEN 'off' ELSE 'on' END AS have_ai \gset
\if :have_ai
\echo rows
SELECT DISTINCT 'k=' || coalesce(config->>'apiKey', '')
  FROM "public"."AIProvider"
 WHERE $scope;
\else
\echo no-table
\endif
SQL
  )" || raw=""

  if [[ -z "$raw" ]]; then
    warn "could not read the stored provider key out of deploy/$pg — NOT verified."
    return 0
  fi
  if [[ "$raw" == "no-table" ]]; then
    warn "no AIProvider table yet (the app's migrations have not run) — nothing to verify."
    VLLM_DB_VERIFIED=notable
    return 0
  fi
  # Every row comes back as `k=<key>`, so a row whose config carries NO apiKey
  # is an EMPTY key rather than an absent line — otherwise it would be
  # indistinguishable from "no row at all" and a stale box would pass as fresh.
  mapfile -t klist < <(awk '/^k=/ {print substr($0, 3)}' <<<"$raw")
  if (( ${#klist[@]} == 0 )); then
    warn "no vLLM provider row on this box yet — nothing to verify."
    warn "  The app seeds it ONCE, at the first organization creation. Until"
    warn "  then there is nothing that can be stale."
    VLLM_DB_VERIFIED=norow
    return 0
  fi
  if (( ${#klist[@]} > 1 )); then
    warn "${#klist[@]} DIFFERENT stored keys across the vLLM rows — realignment did not converge."
    VLLM_DB_VERIFIED=stale
    return 0
  fi
  dbkey="${klist[0]}"
  if [[ -z "$dbkey" ]]; then
    warn "the stored vLLM provider row carries NO apiKey field at all."
    warn "  The app omits it when its own env var is empty (vllm-provider.ts:42-44)."
    VLLM_DB_VERIFIED=stale
    return 0
  fi

  if [[ "$deep" == "1" ]]; then
    tries=6
  fi
  verdict=down
  for (( i = 0; i < tries; i++ )); do
    code="$(vllm_http_code "$base/v1/models" "$dbkey" 5)"
    verdict="$(vllm_verdict "$code")"
    if [[ "$verdict" != "down" ]]; then
      break
    fi
    sleep 10
  done
  if [[ "$verdict" == "denied" ]]; then
    warn "the key STORED IN POSTGRES is REJECTED by vLLM (HTTP $code on /v1/models)."
    VLLM_DB_VERIFIED=stale
    return 0
  fi
  if [[ "$verdict" == "down" ]]; then
    warn "vLLM did not answer /v1/models (HTTP $code) — stored key NOT verified."
    warn "  This is NOT a failure: the models can still be loading."
    warn "  Watch: docker logs -f suite366-vllm-llm"
    return 0
  fi
  info "  stored key accepted on /v1/models (HTTP $code)."
  VLLM_DB_VERIFIED=ok
  if [[ "$deep" != "1" ]]; then
    return 0
  fi

  # /v1/embeddings is the ONLY call that proves the embed container holds the
  # same key: lib/vllm.sh:66-73 recreates the stack only when llm/.env changed,
  # so a partial restart really can leave one container on the old key.
  if [[ -n "${LLM_MODEL:-}" ]]; then
    case "$(vllm_verdict "$(vllm_http_code "$base/v1/chat/completions" "$dbkey" 60 \
              "{\"model\":\"$LLM_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}")")" in
      denied) bad=1; warn "  /v1/chat/completions REJECTED the stored key." ;;
      down)   warn "  /v1/chat/completions did not answer — not verified (models loading?)." ;;
      *)      info "  stored key accepted on /v1/chat/completions." ;;
    esac
  fi
  if [[ -n "${EMBED_MODEL:-}" ]]; then
    case "$(vllm_verdict "$(vllm_http_code "$base/v1/embeddings" "$dbkey" 30 \
              "{\"model\":\"$EMBED_MODEL\",\"input\":\"ping\"}")")" in
      denied) bad=1; warn "  /v1/embeddings REJECTED the stored key (the embed container is on another key)." ;;
      down)   warn "  /v1/embeddings did not answer — not verified (models loading?)." ;;
      *)      info "  stored key accepted on /v1/embeddings." ;;
    esac
  fi
  if (( bad )); then
    VLLM_DB_VERIFIED=stale
  fi
  :
}

# Derive the key, the unified-proxy URL and the model names from the box itself,
# for the two standalone scripts that know none of them. llm/.env comes FIRST on
# purpose: it is the file the vLLM containers read at start, so it holds the key
# that will actually be ACCEPTED. values.yaml is only what the app was TOLD.
# Read line by line rather than sourced — llm/.env also carries HF_TOKEN, and
# these scripts have no business holding it even briefly.
# Returns NON-ZERO when no key can be found, so callers must use `if`.
vllm_local_env() {
  VLLM_KEY=""; VLLM_URL=""
  local envf="$DATA_DIR/llm/.env" vals="$DATA_DIR/values.yaml" ip="" port="" vkey=""
  if [[ -f "$envf" ]]; then
    VLLM_KEY="$(sed -n 's/^VLLM_API_KEY=//p' "$envf" | head -1)"
    ip="$(sed -n 's/^BIND_IP=//p' "$envf" | head -1)"
    port="$(sed -n 's/^PROXY_PORT=//p' "$envf" | head -1)"
    LLM_MODEL="${LLM_MODEL:-$(sed -n 's/^LLM_MODEL=//p' "$envf" | head -1)}"
    EMBED_MODEL="${EMBED_MODEL:-$(sed -n 's/^EMBED_MODEL=//p' "$envf" | head -1)}"
    if [[ -n "$ip" && -n "$port" ]]; then
      VLLM_URL="http://$ip:$port/v1"
    fi
  fi
  # A SKIP_VLLM box has no llm/.env at all; values.yaml always exists — it is
  # what lib/preflight.sh:466-467 itself reads back on a re-run.
  if [[ -z "$VLLM_KEY" && -f "$vals" ]]; then
    VLLM_KEY="$(sed -n 's/.*VLLM_API_KEY: *"\(sk-[^"]*\)".*/\1/p' "$vals" | head -1)"
  fi
  if [[ -z "$VLLM_URL" && -f "$vals" ]]; then
    VLLM_URL="$(sed -n 's|.*VLLM_BASE_URL: *"\(http://[^"]*\)".*|\1|p' "$vals" | head -1)"
  fi
  # The divergence nobody checks today: if these two disagree, the app's own env
  # and the running containers hold DIFFERENT keys, and realigning the database
  # to either one still leaves the other path 401ing. Only a re-render plus a
  # helm upgrade fixes that, so say it instead of silently picking a winner.
  if [[ -f "$envf" && -f "$vals" ]]; then
    vkey="$(sed -n 's/.*VLLM_API_KEY: *"\(sk-[^"]*\)".*/\1/p' "$vals" | head -1)"
    if [[ -n "$vkey" && -n "$VLLM_KEY" && "$vkey" != "$VLLM_KEY" ]]; then
      warn "values.yaml and llm/.env carry DIFFERENT vLLM keys — the app's own env is"
      warn "  wrong whatever the database says. Re-run: sudo $DATA_DIR/install.sh"
    fi
  fi
  [[ -n "$VLLM_KEY" && -n "$VLLM_URL" ]]
}

# One line per call site in the standalone scripts. DEEP=1 after something that
# re-pushed the Secret or reloaded the database; DEEP=0 for the daily check,
# which must not POST to the LLM every night.
reconcile_and_check_vllm_db() { # reconcile_and_check_vllm_db DEEP(0|1)
  local deep="${1:-0}"
  if ! vllm_local_env; then
    warn "vLLM provider key: no key in $DATA_DIR/llm/.env nor values.yaml — DB row left alone."
    return 0
  fi
  reconcile_vllm_db_key "$VLLM_KEY" "$VLLM_URL"
  verify_vllm_db_key "$VLLM_URL" "$deep"
  if [[ "${VLLM_DB_VERIFIED:-unknown}" == "stale" ]]; then
    warn "The vLLM key stored in Postgres is REJECTED by vLLM — every LLM call in"
    warn "  the app will 401. Re-run: sudo $DATA_DIR/install.sh"
  fi
  :
}

# <<< END SHARED vllm-db BLOCK <<<

# --- install-only wrappers ---------------------------------------------------
# install.sh already knows the key, the IP and the ports, so it passes them
# straight in rather than re-deriving them from disk.
reconcile_vllm_provider_row() {
  log "Realigning the vLLM key the app actually uses (Postgres)"
  reconcile_vllm_db_key "$VLLM_API_KEY" "http://$SUITE_IP:$PROXY_PORT/v1"
}

verify_vllm_provider_row() {
  if [[ "${SKIP_VLLM:-0}" == "1" ]]; then
    VLLM_DB_VERIFIED=skipped
    warn "Stored vLLM provider key NOT verified (SKIP_VLLM — there is no proxy to ask)."
    return 0
  fi
  log "Verifying that key by asking vLLM with it (read back from Postgres)"
  verify_vllm_db_key "http://$SUITE_IP:$PROXY_PORT/v1" 1
}

# Separated from the verification for one reason: dying before lib/summary.sh
# runs would cost the operator the URLs, the CA path and the backup-key
# fingerprint — a real price for a failure that is not urgent to the second. So
# the verification records a verdict, summary renders it, and THEN we fail.
vllm_db_gate() {
  if [[ "${VLLM_DB_VERIFIED:-unknown}" == "stale" ]]; then
    die "The vLLM API key STORED IN POSTGRES is not the key vLLM accepts.
    Every LLM call in the app will return 401 while 'docker ps' says
    Up (healthy) and every pod is Running (see 'Key stored in Postgres' in the
    summary above). The installer already tried to realign it, so the row the
    app reads is not the row the UPDATE matched — list them with:
      sudo k3s kubectl -n $NAMESPACE get deploy -o name | sed -n 's|.*/||p'
      sudo k3s kubectl -n $NAMESPACE exec deploy/<the -postgres one> -- \\
        psql -U suite366 -d suite366 -c 'table \"AIProvider\"'"
  fi
  :
}
