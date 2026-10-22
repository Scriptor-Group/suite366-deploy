#!/usr/bin/env bash
# =============================================================================
# Self-test of the tunnel's public Traefik entrypoint — no cluster, no root.
#
# What it guards:
#   • update.sh carries the very block lib/ingress.sh defines (it is fetched
#     and run standalone, so it holds a verbatim copy);
#   • the manifests: two header middlewares (set / delete), and a
#     HelmChartConfig that adds `suite366-public` on Service port 8443 with
#     TLS, references the middlewares in the <ns>-<name>@kubernetescrd form,
#     strips the header on web + websecure, and uses only value keys the
#     Traefik chart k3s ships (40.1.0) knows;
#   • the convergence, against a stubbed kubectl: middlewares strictly before
#     the HelmChartConfig, PUBLIC_INGRESS_PORT published only once live,
#     idempotent (second pass: nothing rewritten), an operator's own
#     HelmChartConfig left alone, a failed apply publishing nothing, a stale
#     line withdrawn only on positive evidence;
#   • `check` only READS (public_ingress_missing -> ingress_diff, so the UI
#     offers Apply) and never converges: converging restarts Traefik;
#   • the wiring: install.sh, lib/updater.sh and update.sh (apply + its own
#     mode) call it.
#
# What it CANNOT show (needs a real box): Traefik actually setting/stripping
# the header, ServiceLB answering on 127.0.0.1:8443, the certificate served
# there.
# =============================================================================
set -uo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASS=0; FAIL=0
ok()      { printf '  \033[32mok\033[0m   %s\n' "$1"; PASS=$((PASS+1)); }
ko()      { printf '  \033[31mKO\033[0m   %s\n' "$1"; FAIL=$((FAIL+1)); }
check()   { if [[ "$2" == "$3" ]]; then ok "$1"; else ko "$1 (expected '$3', got '$2')"; fi; }
contains(){ case "$2" in *"$3"*) ok "$1" ;; *) ko "$1 (missing: $3)" ;; esac; }
absent()  { case "$2" in *"$3"*) ko "$1 (present, should not be: $3)" ;; *) ok "$1" ;; esac; }
head_()   { printf '\n== %s ==\n' "$1"; }
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT

BEGIN='# >>> SHARED public-ingress BLOCK >>>'
END='# <<< END SHARED public-ingress BLOCK <<<'
block_of() { sed -n "/^$BEGIN/,/^$END/p" "$1"; }

# --- 1. one block, two copies ----------------------------------------------------
head_ "shared block"
B_LIB="$(block_of "$REPO/lib/ingress.sh")"; B_UPD="$(block_of "$REPO/update.sh")"
[[ -n "$B_LIB" ]] && ok "lib/ingress.sh carries the block" || ko "lib/ingress.sh carries the block"
check "update.sh carries it verbatim" "$B_UPD" "$B_LIB"

# --- 2. the manifests --------------------------------------------------------------
head_ "manifests"
# shellcheck disable=SC1090
eval "$B_UPD"
public_ingress_middlewares     > "$WORK/mw.yaml"
public_ingress_helmchartconfig > "$WORK/hcc.yaml"
check "PUBLIC_INGRESS_PORT is 8443 (frpc's localPort)" "$PUBLIC_INGRESS_PORT" "8443"
if python3 -c "import yaml" 2>/dev/null; then
  # The value keys a ports.<name> entry may carry in chart traefik 40.1.0
  # (values.schema.json, additionalProperties: false), as k3s v1.36.2+k3s1
  # ships it. A typo here would be rejected by helm-controller on the box.
  if out="$(python3 - "$WORK/mw.yaml" "$WORK/hcc.yaml" <<'PY' 2>&1
import re, sys, yaml
mws = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
hcc = yaml.safe_load(open(sys.argv[2]))
by = {m["metadata"]["name"]: m for m in mws}
assert all(m["apiVersion"] == "traefik.io/v1alpha1" and m["kind"] == "Middleware" and m["metadata"]["namespace"] == "kube-system" for m in mws), "middlewares: traefik.io/v1alpha1 in kube-system"
assert by["suite366-ingress-public"]["spec"]["headers"]["customRequestHeaders"] == {"X-Suite366-Ingress": "public"}, "public sets the header"
assert by["suite366-ingress-strip"]["spec"]["headers"]["customRequestHeaders"] == {"X-Suite366-Ingress": ""}, "strip deletes it (empty value)"
assert hcc["apiVersion"] == "helm.cattle.io/v1" and hcc["kind"] == "HelmChartConfig", "HelmChartConfig"
assert hcc["metadata"] == {"name": "traefik", "namespace": "kube-system", "labels": {"app.kubernetes.io/managed-by": "suite366-deploy"}}, "names k3s's traefik chart, labelled ours"
v = yaml.safe_load(hcc["spec"]["valuesContent"])
assert v["providers"]["kubernetesCRD"]["enabled"] is True, "CRD provider on"
ref = lambda n: "kube-system-%s@kubernetescrd" % n
for ep in ("web", "websecure"):
    assert v["ports"][ep] == {"http": {"middlewares": [ref("suite366-ingress-strip")]}}, ep + " strips, and only adds that"
p = v["ports"]["suite366-public"]
allowed = {"allowACMEByPass","appProtocol","asDefault","containerPort","expose","exposedPort","forwardedHeaders","hostIP","hostPort","http","http3","nodePort","observability","port","protocol","proxyProtocol","targetPort","transport","uplink"}
assert set(p) <= allowed, "unknown port keys: %s" % (set(p) - allowed)
assert set(p["http"]) <= {"encodedCharacters","maxHeaderBytes","middlewares","redirections","sanitizePath","tls"}, "unknown http keys"
assert p["exposedPort"] == 8443 and p["expose"] == {"default": True} and p["protocol"] == "TCP", "exposed on the Service at 8443"
# chart 40: web 8000, websecure 8443, traefik 8080, metrics 9100 in the container
assert p["port"] not in (8000, 8443, 8080, 9100), "container port clashes with a stock entrypoint"
assert p["http"]["tls"] == {"enabled": True}, "TLS like websecure"
assert p["http"]["middlewares"] == [ref("suite366-ingress-public")], "public entrypoint sets the header"
name = "suite366-public"
assert len(name) <= 15 and re.match(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$", name), "a valid k8s port name"
assert "asDefault" not in p, "Ingress routers must keep attaching to every entrypoint"
for m in by:
    assert ref(m) in hcc["spec"]["valuesContent"], m + " is referenced"
print("ok")
PY
)"; then ok "manifests: header set/strip, 8443 + TLS, refs <ns>-<name>@kubernetescrd, chart-40 keys only"; else ko "manifests: $out"; fi
else
  ok "(PyYAML missing — structural check skipped)"
fi

# --- 3. convergence against a stubbed kubectl --------------------------------------
head_ "convergence (stubbed kubectl)"
# State of the fake cluster lives in files under $S:
#   crd        Traefik's CRDs are installed       mw   middlewares exist
#   hcc        a HelmChartConfig exists           owner  its managed-by label
#   ports      the Traefik Service's ports         fail-hcc  apply of the HCC fails
#   no-roll    helm-controller never rolls        api-down  the API does not answer
#   apply.log  one line per applied kind, in order
# A cluster-WRITING call during a read-only probe shows up in apply.log.
run() { # run STATE_DIR ENV_FILE [FN] -> rc ; output in $OUT (FN: what to call, default converge_public_ingress_env)
  OUT="$(S="$1" FN="${3:-converge_public_ingress_env}" bash -c '
    set -euo pipefail
    info() { printf "    %s\n" "$*"; }; warn() { printf "!!  %s\n" "$*"; }
    sleep() { :; }
    kc() {
      [[ -f "$S/api-down" ]] && return 1
      local a="$*" in
      case "$a" in
        "get crd middlewares.traefik.io"|"wait --for=condition=Established crd/middlewares.traefik.io --timeout=60s")
          [[ -f "$S/crd" ]] ;;
        "-n kube-system get helmchartconfig traefik") [[ -f "$S/hcc" ]] ;;
        "-n kube-system get helmchartconfig traefik -o jsonpath="*) [[ -f "$S/hcc" ]] && cat "$S/owner" 2>/dev/null ;;
        "-n kube-system get middlewares.traefik.io suite366-ingress-public suite366-ingress-strip") [[ -f "$S/mw" ]] ;;
        "-n kube-system get svc traefik -o jsonpath="*) cat "$S/ports" ;;
        "-n kube-system rollout status deploy/traefik --timeout=180s") return 0 ;;
        "apply -f -")
          in="$(cat)"
          if [[ "$in" == *"kind: HelmChartConfig"* ]]; then
            echo HelmChartConfig >> "$S/apply.log"
            [[ -f "$S/fail-hcc" ]] && { echo "error: boom"; return 1; }
            if [[ -f "$S/hcc.yaml" && "$(cat "$S/hcc.yaml")" == "$in" ]]; then echo "helmchartconfig.helm.cattle.io/traefik unchanged"; return 0; fi
            printf "%s" "$in" > "$S/hcc.yaml"; touch "$S/hcc"; echo suite366-deploy > "$S/owner"
            [[ -f "$S/no-roll" ]] || { grep -qx 8443 "$S/ports" || echo 8443 >> "$S/ports"; }
            echo "helmchartconfig.helm.cattle.io/traefik configured"
          else
            echo Middleware >> "$S/apply.log"; touch "$S/mw"
            echo "middleware.traefik.io/suite366-ingress-public configured"
          fi ;;
        *) echo "unexpected kc $a" >&2; return 99 ;;
      esac
    }
    eval "$(sed -n "/^# >>> SHARED public-ingress BLOCK/,/^# <<< END SHARED public-ingress BLOCK/p" "$1")"
    eval "$(sed -n "/^converge_public_ingress_env() {/,/^}/p" "$1")"
    PUBLIC_INGRESS_WAIT=3 DATA_DIR="$2" "$FN"
  ' _ "$REPO/update.sh" "$2" 2>&1)"
}
newbox() { # newbox NAME -> a state dir with CRDs + stock Service, and a data dir with update.env
  local d="$WORK/$1"; mkdir -p "$d/state" "$d/data"
  touch "$d/state/crd"; printf '80\n443\n' > "$d/state/ports"
  printf 'MANIFEST_URL=https://example.invalid/channel.json\nNAMESPACE=suite366\n' > "$d/data/update.env"
  printf '%s' "$d"
}

B="$(newbox fresh)"
run "$B/state" "$B/data"; rc=$?
check "fresh box: converges (rc 0)" "$rc" "0"
check "fresh box: middlewares applied BEFORE the HelmChartConfig" "$(tr '\n' ' ' < "$B/state/apply.log")" "Middleware HelmChartConfig "
check "fresh box: PUBLIC_INGRESS_PORT published once" "$(grep -c '^PUBLIC_INGRESS_PORT=8443$' "$B/data/update.env")" "1"
contains "fresh box: the other keys are kept" "$(cat "$B/data/update.env")" "NAMESPACE=suite366"
check "fresh box: update.env stays 0600" "$(stat -c %a "$B/data/update.env")" "600"
e1="$(cat "$B/data/update.env")"; m1="$(stat -c %i "$B/data/update.env")"
run "$B/state" "$B/data"; rc=$?
check "second pass: rc 0" "$rc" "0"
absent  "second pass: no 'applied — k3s rolls Traefik' line" "$OUT" "k3s rolls Traefik"
check "second pass: update.env byte-identical" "$(cat "$B/data/update.env")" "$e1"
check "second pass: update.env not even rewritten (same inode)" "$(stat -c %i "$B/data/update.env")" "$m1"
check "second pass: still one PUBLIC_INGRESS_PORT line" "$(grep -c '^PUBLIC_INGRESS_PORT=' "$B/data/update.env")" "1"

B="$(newbox foreign)"; touch "$B/state/hcc"; echo someone-else > "$B/state/owner"
run "$B/state" "$B/data"; rc=$?
check "operator's own HelmChartConfig: rc 0 (never fatal)" "$rc" "0"
contains "operator's own HelmChartConfig: said so" "$OUT" "was not written by suite366-deploy"
check "operator's own HelmChartConfig: nothing applied" "$(cat "$B/state/apply.log" 2>/dev/null)" ""
absent "operator's own HelmChartConfig: nothing published" "$(cat "$B/data/update.env")" "PUBLIC_INGRESS_PORT"

B="$(newbox failhcc)"; touch "$B/state/fail-hcc"
run "$B/state" "$B/data"; rc=$?
check "failed HelmChartConfig apply: rc 0" "$rc" "0"
contains "failed HelmChartConfig apply: said so" "$OUT" "HelmChartConfig not applied"
absent "failed HelmChartConfig apply: nothing published" "$(cat "$B/data/update.env")" "PUBLIC_INGRESS_PORT"

B="$(newbox noroll)"; touch "$B/state/no-roll"
run "$B/state" "$B/data"; rc=$?
contains "Traefik never exposes the port: said so" "$OUT" "does not expose :8443"
absent "Traefik never exposes the port: nothing published" "$(cat "$B/data/update.env")" "PUBLIC_INGRESS_PORT"

B="$(newbox nocrd)"; rm -f "$B/state/crd"
run "$B/state" "$B/data"; rc=$?
check "no Traefik CRDs: rc 0" "$rc" "0"
contains "no Traefik CRDs: said so" "$OUT" "Middleware CRD is not there"
check "no Traefik CRDs: nothing applied" "$(cat "$B/state/apply.log" 2>/dev/null)" ""

# A stale line: withdrawn when the API positively says the port is gone, kept
# when the API simply does not answer (no flapping of the tunnel).
B="$(newbox stale)"; echo PUBLIC_INGRESS_PORT=8443 >> "$B/data/update.env"; touch "$B/state/no-roll" "$B/state/fail-hcc"
run "$B/state" "$B/data"
absent "stale line, port really gone: withdrawn" "$(cat "$B/data/update.env")" "PUBLIC_INGRESS_PORT"
contains "stale line, port really gone: kept the rest" "$(cat "$B/data/update.env")" "MANIFEST_URL="
B="$(newbox apidown)"; echo PUBLIC_INGRESS_PORT=8443 >> "$B/data/update.env"; touch "$B/state/api-down"
run "$B/state" "$B/data"; rc=$?
check "API down: rc 0" "$rc" "0"
contains "API down: the published line is kept" "$(cat "$B/data/update.env")" "PUBLIC_INGRESS_PORT=8443"

# --- 3b. `check` only READS: public_ingress_missing ------------------------------
head_ "check: read-only probe (public_ingress_missing)"
B="$(newbox probe)"
run "$B/state" "$B/data" public_ingress_missing; rc=$?
check "stock box: reported missing (rc 0)" "$rc" "0"
check "stock box: the probe applied NOTHING" "$(cat "$B/state/apply.log" 2>/dev/null)" ""
check "stock box: the probe published nothing" "$(grep -c PUBLIC_INGRESS_PORT "$B/data/update.env")" "0"
run "$B/state" "$B/data"
run "$B/state" "$B/data" public_ingress_missing; rc=$?
check "after apply's converge: no longer missing (rc 1)" "$rc" "1"
B="$(newbox probe-foreign)"; touch "$B/state/hcc"; echo someone-else > "$B/state/owner"
run "$B/state" "$B/data" public_ingress_missing; rc=$?
check "foreign HelmChartConfig: not offered (apply would refuse) (rc 1)" "$rc" "1"
B="$(newbox probe-down)"; touch "$B/state/api-down"
run "$B/state" "$B/data" public_ingress_missing; rc=$?
check "API down: not reported missing (rc 1)" "$rc" "1"
B="$(newbox probe-nosvc)"; rm -f "$B/state/ports"
run "$B/state" "$B/data" public_ingress_missing; rc=$?
check "no Traefik Service: not reported missing (rc 1)" "$rc" "1"
B="$(newbox probe-diffs)"
# compute_diffs, as `check` runs it: an otherwise current box shows an update.
OUT="$(S="$B/state" bash -c '
  set -uo pipefail
  info() { printf "    %s\n" "$*"; }; warn() { :; }
  kc() { case "$*" in "-n kube-system get svc traefik -o jsonpath="*) cat "$S/ports" ;; *) return 1 ;; esac; }
  eval "$(sed -n "/^# >>> SHARED public-ingress BLOCK/,/^# <<< END SHARED public-ingress BLOCK/p" "$1")"
  for f in ver_gt compute_diffs up_to_date; do eval "$(sed -n "/^$f() {/,/^}/p" "$1")"; done
  UPDATE_SOURCE=online cur_chart=0.10.3 want_chart=0.10.3 cur_app=1.23.0 want_app=1.23.0 cur_vllm=v want_vllm=v
  compute_diffs >/dev/null
  if up_to_date; then u=up-to-date; else u=update; fi
  printf "%s|%s|%s" "$ingress_diff" "$u" "$summary_line"
' _ "$REPO/update.sh" 2>&1)"
check "compute_diffs: ingress_diff=1, not up to date, said in the summary" "$OUT" "1|update|public ingress entrypoint (:8443)"
check "compute_diffs: still applied nothing" "$(cat "$B/state/apply.log" 2>/dev/null)" ""

# --- 4. wiring ------------------------------------------------------------------------
head_ "wiring"
contains "install.sh loads lib/ingress.sh"            "$(grep '^MODULES=' "$REPO/install.sh")" " ingress "
check "install.sh: setup_public_ingress right after deploy_suite, before the update timer" \
  "$(sed -n '/^main() {/,/^}/p' "$REPO/install.sh" | grep -oE '^  (deploy_suite|setup_public_ingress|setup_update_timer)$' | tr -d ' ' | tr '\n' ' ')" \
  "deploy_suite setup_public_ingress setup_update_timer "
contains "lib/updater.sh records the port after writing update.env" \
  "$(sed -n '/^setup_update_timer() {/,/^}/p' "$REPO/lib/updater.sh")" 'record_public_ingress_port "$DATA_DIR/update.env" "${PUBLIC_INGRESS_LIVE:-0}"'
check "update.sh converges it on both apply paths and its own mode — 3 calls" \
  "$(grep -c '^ *converge_public_ingress_env$' "$REPO/update.sh")" "3"
absent "update.sh: the notify-only check NEVER converges it (it restarts Traefik)" \
  "$(sed -n '/^case "\$MODE" in/,/^esac/p' "$REPO/update.sh" | sed -n '/^  check)/,/^    ;;/p')" "converge_public_ingress"
contains "update.sh: up_to_date counts the missing entrypoint" \
  "$(sed -n '/^up_to_date() {/p' "$REPO/update.sh")" 'ingress_diff'
contains "update.sh: public-ingress mode" "$(sed -n '/^case "\$MODE" in/,/^esac/p' "$REPO/update.sh")" "public-ingress)"

printf '\n%d ok, %d KO\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
