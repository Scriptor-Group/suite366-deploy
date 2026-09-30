#!/usr/bin/env bash
# =============================================================================
# Self-test: provisioning the INSTANCE licence (several organisations on one
# box, seats pooled) without ever letting it become a hole.
#
# What is guarded, and why:
#
#  • THE GATE. A LICENSE_KEY on an app older than the release that ties
#    organisation creation to it means "unlimited organisations with OPEN
#    sign-up on the LAN". Both entry points — the install re-run
#    (lib/preflight.sh) and `update.sh license set` — must refuse a token on
#    such an app, and refuse an ORGANISATION licence (scope absent) anywhere.
#  • IDEMPOTENCE. A re-run of the installer reads the token back out of
#    values.yaml, never un-licenses a box, and never matches LICENSE_PUBLIC_KEY
#    or a comment by mistake.
#  • THE WRITE. `license set` puts the token under `secrets:`, replaces it in
#    place on a second run (one line, not two), keeps the file 0600, and reads
#    it from STDIN so it never reaches argv, ps, or shell history — the helm
#    stub's argv log is checked for it.
#
# No cluster: helm and k3s are stubbed, the release roll and the cluster state
# readers are overridden after the functions under test are extracted.
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

# --- forged tokens (shape only: nothing here verifies a signature) -------------
b64url() { printf '%s' "$1" | base64 -w0 | tr '+/' '-_' | tr -d '='; }
HDR="$(b64url '{"alg":"EdDSA","typ":"JWT"}')"
INSTANCE="$HDR.$(b64url '{"iss":"devana","sub":"instance","scope":"instance","jti":"L-1","exp":4102444800,"type":"custom","licensee":"Acme","limits":{"includedSeats":40,"maxOrganizations":3}}').c2ln"
ORG="$HDR.$(b64url '{"iss":"devana","sub":"org_1","jti":"L-2","exp":4102444800,"type":"standard","licensee":"Acme","limits":{"includedSeats":10}}').c2ln"

# --- stubs -------------------------------------------------------------------
mkdir -p "$WORK/bin" "$WORK/data"
cat > "$WORK/bin/helm" <<'EOF'
#!/usr/bin/env bash
printf 'helm %s\n' "$*" >> "$WORK/helm.log"
exit 0
EOF
cat > "$WORK/bin/k3s" <<'EOF'
#!/usr/bin/env bash
shift
printf 'k3s %s\n' "$*" >> "$WORK/k3s.log"
case "$*" in
  *"get deploy"*) printf 'drive-app ghcr.io/scriptor-group/suite-366:%s\ndrive-postgres postgres:16\n' "$(cat "$WORK/cur_app")" ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/helm" "$WORK/bin/k3s"

# --- harness -----------------------------------------------------------------
# The functions are EXTRACTED from update.sh / lib/preflight.sh, never copied:
# a change there is a change here. Everything they call that needs a cluster is
# overridden AFTER the extraction, so the override wins.
{
  cat <<'H'
c_g=""; c_b=""; c_y=""; c_r=""; c_0=""
log()  { printf 'LOG %s\n' "$*"; }
info() { printf 'INFO %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; }
die()  { printf 'DIE %s\n' "$*"; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
kc()   { k3s kubectl "$@"; }
NAMESPACE=suite366; RELEASE=drive; CHART_REF=oci://example/chart
H
  printf 'DATA_DIR=%s\n' "$WORK/data"
  sed -n '/^LICENSE_MIN_APP=/p' "$REPO/update.sh"
  for f in license_key_sane jwt_payload jwt_field license_key_from_values license_describe \
           license_write_values do_license ver_gt read_current_state require_cluster_tools; do
    sed -n "/^$f() {/,/^}/p" "$REPO/update.sh"
  done
  # Overrides: the state comes from the fixture, the roll is logged.
  cat <<'H'
read_current_state() { cur_app="$(cat "$WORK/cur_app")"; cur_chart="$(cat "$WORK/cur_chart" 2>/dev/null || true)"; }
roll_release() { printf 'roll_release %s\n' "$*" >> "$WORK/roll.log"; }
H
} > "$WORK/prelude.sh"

run() { # run [stdin-file] CODE -> output ; RC = exit status
  local stdin=/dev/null
  if [[ $# -eq 2 ]]; then stdin="$1"; shift; fi
  local out rc
  # shellcheck disable=SC2097,SC2098
  out="$(PATH="$WORK/bin:$ORIG_PATH" WORK="$WORK" \
           bash -c "set -euo pipefail; . '$WORK/prelude.sh'; $1" < "$stdin" 2>&1)"
  rc=$?
  printf '%s\n' "$out"
  # A command substitution runs us in a subshell: the caller reads $? into RC.
  return "$rc"
}

reset_box() { # reset_box APP_VERSION [with-licence]
  rm -f "$WORK/helm.log" "$WORK/k3s.log" "$WORK/roll.log"
  printf '%s\n' "$1" > "$WORK/cur_app"; printf '0.10.2\n' > "$WORK/cur_chart"
  {
    printf 'image:\n  tag: "%s"\nsecrets:\n  VLLM_API_KEY: "sk-x"\n' "$1"
    [[ "${2:-}" == "with-licence" ]] && printf '  LICENSE_KEY: "%s"\n' "$INSTANCE"
    printf 'config:\n  NODE_ENV: "production"\n  # a comment mentioning LICENSE_KEY on purpose\n  LICENSE_PUBLIC_KEY: "-----BEGIN PUBLIC KEY-----\\nAAA\\n-----END PUBLIC KEY-----\\n"\n'
  } > "$WORK/data/values.yaml"
  chmod 0600 "$WORK/data/values.yaml"
}

echo "== decoding =="
out="$(run "license_key_sane '$INSTANCE' && echo sane")"; RC=$?;  check "a JWT is sane" "$out" "sane"
out="$(run "license_key_sane 'not a token' || echo insane")"; RC=$?; check "free text is not" "$out" "insane"
out="$(run "jwt_field '$INSTANCE' scope")"; RC=$?;            check "scope is read" "$out" "instance"
out="$(run "jwt_field '$INSTANCE' maxOrganizations")"; RC=$?; check "a nested numeric claim is read" "$out" "3"
out="$(run "jwt_field '$INSTANCE' jti")"; RC=$?;              check "jti is read" "$out" "L-1"
out="$(run "jwt_field '$ORG' scope")"; RC=$?;                 check "an organisation licence has no scope" "$out" ""

echo "== reading the token back out of values.yaml =="
reset_box 1.12.0 with-licence
out="$(run "license_key_from_values '$WORK/data/values.yaml'")"; RC=$?
check "the installed token is found" "$out" "$INSTANCE"
reset_box 1.12.0
out="$(run "license_key_from_values '$WORK/data/values.yaml'")"; RC=$?
check "neither LICENSE_PUBLIC_KEY nor the comment is mistaken for it" "$out" ""

echo "== update.sh license show =="
reset_box 1.12.0
out="$(run "do_license show")"; RC=$?; contains "no licence: says so, exit 0" "$out" "single organisation only"; check "…and exits 0" "$RC" "0"
reset_box 1.12.0 with-licence
out="$(run "do_license show")"; RC=$?
contains "describes the licensee" "$out" "Acme"
contains "describes the cap and the pool" "$out" "organisations : 3   seats pooled across the box: 40"
contains "describes the jti" "$out" "jti L-1"

echo "== update.sh license set — refusals =="
reset_box 1.12.0
out="$(run "do_license set 'garbage'")"; RC=$?;  contains "refuses a non-JWT" "$out" "not a licence token"; check "…exit 1" "$RC" "1"
out="$(run "do_license set '$ORG'")"; RC=$?;     contains "refuses an organisation licence" "$out" "not an instance licence"; check "…exit 1" "$RC" "1"
absent "nothing rolled on a refusal" "$(cat "$WORK/roll.log" 2>/dev/null || true)" "roll_release"
absent "values.yaml untouched on a refusal" "$(cat "$WORK/data/values.yaml")" "LICENSE_KEY: \"$ORG"
reset_box 1.11.10
out="$(run "do_license set '$INSTANCE'")"; RC=$?
contains "refuses a valid token on an app below LICENSE_MIN_APP" "$out" "apply the update first"; check "…exit 1" "$RC" "1"
absent "values.yaml untouched on an old app" "$(cat "$WORK/data/values.yaml")" "  LICENSE_KEY: \""
absent "nothing rolled on an old app" "$(cat "$WORK/roll.log" 2>/dev/null || true)" "roll_release"

echo "== update.sh license set — the write =="
reset_box 1.12.0
printf '%s\n' "$INSTANCE" > "$WORK/stdin"
out="$(run "$WORK/stdin" "do_license set -")"; RC=$?
check "exit 0" "$RC" "0"
check "the token lands under secrets:, once" "$(grep -c "^  LICENSE_KEY: \"$INSTANCE\"$" "$WORK/data/values.yaml")" "1"
check "…right after VLLM_API_KEY" "$(grep -A1 'VLLM_API_KEY' "$WORK/data/values.yaml" | tail -1)" "  LICENSE_KEY: \"$INSTANCE\""
check "the file stays 0600" "$(stat -c '%a' "$WORK/data/values.yaml")" "600"
contains "the release is rolled on the installed chart" "$(cat "$WORK/roll.log")" "roll_release 0.10.2"
contains "the app deployment is restarted on the new Secret" "$(cat "$WORK/k3s.log")" "rollout restart deploy/drive-app"
absent "the token never appears in a helm argv" "$(cat "$WORK/helm.log" 2>/dev/null || true)" "$INSTANCE"
absent "the token never appears in a kubectl argv" "$(cat "$WORK/k3s.log")" "$INSTANCE"
contains "the summary describes what was installed" "$out" "organisations : 3"
# Rotation: a second token replaces the line, it does not add one.
ROTATED="$HDR.$(b64url '{"scope":"instance","jti":"L-9","exp":4102444800,"licensee":"Acme","limits":{"includedSeats":80,"maxOrganizations":-1}}').c2ln"
out="$(run "do_license set '$ROTATED'")"; RC=$?
check "rotation: exit 0" "$RC" "0"
check "rotation: still exactly one LICENSE_KEY line" "$(grep -c '^  LICENSE_KEY:' "$WORK/data/values.yaml")" "1"
check "rotation: the new token replaced the old one" "$(grep -c "^  LICENSE_KEY: \"$ROTATED\"$" "$WORK/data/values.yaml")" "1"
contains "rotation: -1 reads as unlimited" "$out" "organisations : unlimited"
if python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); assert d['secrets']['LICENSE_KEY'].startswith('eyJ') and d['secrets']['VLLM_API_KEY']=='sk-x' and 'LICENSE_PUBLIC_KEY' in d['config']" "$WORK/data/values.yaml" 2>/dev/null; then ok "valid YAML after two writes"; else ko "valid YAML after two writes"; fi
# A values.yaml from before `secrets:` existed at all: the block is created.
printf 'image:\n  tag: "1.12.0"\nconfig:\n  NODE_ENV: "production"\n' > "$WORK/data/values.yaml"
out="$(run "do_license set '$INSTANCE'")"; RC=$?
check "no secrets: block yet — created, exit 0" "$RC" "0"
check "…with the token in it" "$(grep -A1 '^secrets:' "$WORK/data/values.yaml" | tail -1)" "  LICENSE_KEY: \"$INSTANCE\""

echo "== the installer re-run keeps and checks the licence (lib/preflight.sh) =="
# Only the licence part of gather_inputs is exercised: everything before it is
# stubbed, and `fetch values.yaml` serves the template pin under test.
preflight_run() { # preflight_run TEMPLATE_TAG [LICENSE_KEY_ENV]
  local tag="$1" key="${2-}"
  # shellcheck disable=SC2097,SC2098
  PATH="$WORK/bin:$ORIG_PATH" WORK="$WORK" REPO="$REPO" LICENSE_KEY="$key" TAG="$tag" bash -c '
    set -euo pipefail
    log() { :; }; info() { :; }; warn() { printf "WARN %s\n" "$*"; }; die() { printf "DIE %s\n" "$*"; exit 1; }
    ask() { :; }; ask_secret() { :; }; gather_hosts() { :; }
    fetch() { printf "image:\n  tag: \"%s\"\n" "$TAG"; }
    DATA_DIR="$WORK/data"; DOMAIN=x; SKIP_VLLM=1; VLLM_IMAGE=v; LLM_MODEL=m; EMBED_MODEL=e
    LICENSE_MIN_APP=1.12.0
    eval "$(sed -n "/^license_key_sane() {/,/^}/p;/^jwt_payload() {/,/^}/p;/^jwt_field() {/,/^}/p" "$REPO/lib/common.sh")"
    eval "$(sed -n "/^license_key_from_values() {/,/^}/p;/^gather_inputs() {/,/^}/p" "$REPO/lib/preflight.sh")"
    gather_inputs
    printf "LICENSE_KEY=%s\n" "$LICENSE_KEY"
  ' 2>&1
}
reset_box 1.12.0 with-licence
out="$(preflight_run 1.12.0)"; RC=$?
contains "re-run without env: the installed token is kept" "$out" "LICENSE_KEY=$INSTANCE"; check "…exit 0" "$RC" "0"
out="$(preflight_run 1.12.0 "$ROTATED")"; RC=$?
contains "re-run with env: the env wins" "$out" "LICENSE_KEY=$ROTATED"
out="$(preflight_run 1.12.0 "$ORG")"; RC=$?
contains "an organisation licence is refused" "$out" "not an instance licence"; check "…exit 1" "$RC" "1"
out="$(preflight_run 1.11.10 "$INSTANCE")"; RC=$?
contains "a token with a template that pins an older app is refused" "$out" "needs app >= 1.12.0"; check "…exit 1" "$RC" "1"
reset_box 1.12.0
out="$(preflight_run 1.12.0)"; RC=$?
contains "no licence anywhere: nothing set, nothing refused" "$out" "LICENSE_KEY="$'\n'; check "…exit 0" "$RC" "0"

echo
printf 'passed: %d  failed: %d\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
