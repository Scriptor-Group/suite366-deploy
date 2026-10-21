# shellcheck shell=bash
# =============================================================================
# lib/ingress.sh — a second, PUBLIC Traefik entrypoint for the tunnel.
#
# Why: in proxy mode the tunnel (suite366-fleet's frpc, SNI passthrough) pipes
# raw TLS from the internet to 127.0.0.1:443 — the very entrypoint (websecure)
# LAN browsers use. Inside Traefik the two are indistinguishable, and the Host
# header proves nothing: an internet client can send any Host inside a TLS
# session whose SNI is the public name. So the tunnel gets its own door:
#
#   suite366-public   container :9443, Service/ServiceLB :8443 on the host,
#                     TLS like websecure (same certificates: Ingress routers
#                     attach to every entrypoint), and an entrypoint-level
#                     middleware that SETS `X-Suite366-Ingress: public`,
#                     overwriting whatever the client sent;
#   web, websecure    an entrypoint-level middleware that REMOVES that header,
#                     so a LAN client cannot claim to be public either way.
#
# The app reads the header (absent = LAN). frpc is pointed at the port the box
# publishes as PUBLIC_INGRESS_PORT in update.env — written only once the
# entrypoint is live, so the fleet layer never aims the tunnel at a closed
# port. A LAN client reaching :8443 only marks ITSELF public (stricter, never
# looser); the fleet layer does not open 8443 to the LAN anyway.
#
# Created on every box, used or not: an idle entrypoint costs nothing, and a
# box published later needs no cluster change. update.sh converges the same
# objects (check + apply), from the shared block below.
#
# Verified against k3s v1.36.2+k3s1 (lib/config.sh K3S_VERSION): its
# manifests/traefik.yaml installs chart traefik 40.1.0 (Traefik 3.7.4), whose
# values schema has ports.<name>.{port,expose.default,exposedPort,protocol,
# http.tls.enabled,http.middlewares} and providers.kubernetesCRD.enabled
# (default true). The container port is NOT 8443: chart 40 already gives that
# one to websecure.
# =============================================================================

# >>> SHARED public-ingress BLOCK >>> (lib/ingress.sh, copied verbatim into update.sh — tools/test-public-ingress.sh fails on drift)
# The contract with suite366-fleet (frpc's localPort) and the app (the header):
# constants, not settings.
PUBLIC_INGRESS_PORT=8443
PUBLIC_INGRESS_HEADER="X-Suite366-Ingress"
PUBLIC_INGRESS_WAIT="${PUBLIC_INGRESS_WAIT:-60}"   # x5 s for helm-controller to roll Traefik

# The two header middlewares. Applied BEFORE the HelmChartConfig, and checked:
# an entrypoint that names a middleware Traefik cannot find fails EVERY router
# on it — websecure included, i.e. the whole LAN.
public_ingress_middlewares() {
  cat <<EOF
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: suite366-ingress-public
  namespace: kube-system
  labels:
    app.kubernetes.io/managed-by: suite366-deploy
spec:
  headers:
    customRequestHeaders:
      $PUBLIC_INGRESS_HEADER: "public"
---
# An empty value DELETES the header (Traefik headers middleware).
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: suite366-ingress-strip
  namespace: kube-system
  labels:
    app.kubernetes.io/managed-by: suite366-deploy
spec:
  headers:
    customRequestHeaders:
      $PUBLIC_INGRESS_HEADER: ""
EOF
}

# Merged by k3s's helm-controller over its own traefik valuesContent (maps
# merge, lists replace — web/websecure have no middlewares of their own).
# Entrypoint-level references use the provider-qualified form
# <namespace>-<name>@kubernetescrd.
public_ingress_helmchartconfig() {
  cat <<EOF
apiVersion: helm.cattle.io/v1
kind: HelmChartConfig
metadata:
  name: traefik
  namespace: kube-system
  labels:
    app.kubernetes.io/managed-by: suite366-deploy
spec:
  valuesContent: |-
    providers:
      kubernetesCRD:
        enabled: true
    ports:
      web:
        http:
          middlewares:
            - kube-system-suite366-ingress-strip@kubernetescrd
      websecure:
        http:
          middlewares:
            - kube-system-suite366-ingress-strip@kubernetescrd
      suite366-public:
        port: 9443
        expose:
          default: true
        exposedPort: $PUBLIC_INGRESS_PORT
        protocol: TCP
        http:
          tls:
            enabled: true
          middlewares:
            - kube-system-suite366-ingress-public@kubernetescrd
EOF
}

public_ingress_svc_ports() { # -> the Traefik Service's ports, one per line (fails when the API does not answer)
  kc -n kube-system get svc traefik -o jsonpath='{range .spec.ports[*]}{.port}{"\n"}{end}' 2>/dev/null
}

public_ingress_live() { # -> 0 when the Service exposes the port AND both middlewares exist
  public_ingress_svc_ports | grep -qx "$PUBLIC_INGRESS_PORT" || return 1
  kc -n kube-system get middlewares.traefik.io suite366-ingress-public suite366-ingress-strip >/dev/null 2>&1
}

converge_public_ingress() { # -> 0 live, 1 not (nothing is published then)
  local i owner out
  # A fresh cluster may still be running k3s's traefik-crd install job.
  for i in $(seq 1 36); do
    kc get crd middlewares.traefik.io >/dev/null 2>&1 && break
    sleep 5
  done
  if ! kc wait --for=condition=Established crd/middlewares.traefik.io --timeout=60s >/dev/null 2>&1; then
    warn "public entrypoint: Traefik's Middleware CRD is not there (k3s Traefik disabled?) — not configured."
    return 1
  fi
  # One HelmChartConfig per chart: an operator's own would be clobbered.
  if kc -n kube-system get helmchartconfig traefik >/dev/null 2>&1; then
    owner="$(kc -n kube-system get helmchartconfig traefik -o jsonpath='{.metadata.labels.app\.kubernetes\.io/managed-by}' 2>/dev/null || true)"
    if [[ "$owner" != "suite366-deploy" ]]; then
      warn "public entrypoint: kube-system/traefik HelmChartConfig was not written by suite366-deploy — left alone, entrypoint NOT configured."
      warn "  Merge public_ingress_helmchartconfig (lib/ingress.sh) into it by hand, then re-run."
      return 1
    fi
  fi
  if ! out="$(public_ingress_middlewares | kc apply -f - 2>&1)"; then
    warn "public entrypoint: middlewares not applied: $out"; return 1
  fi
  if ! kc -n kube-system get middlewares.traefik.io suite366-ingress-public suite366-ingress-strip >/dev/null 2>&1; then
    warn "public entrypoint: middlewares not readable after apply — HelmChartConfig NOT applied."; return 1
  fi
  if ! out="$(public_ingress_helmchartconfig | kc apply -f - 2>&1)"; then
    warn "public entrypoint: HelmChartConfig not applied: $out"; return 1
  fi
  case "$out" in
    *unchanged*) ;;
    *) info "public entrypoint: HelmChartConfig applied — k3s rolls Traefik (a few seconds without ingress)." ;;
  esac
  for i in $(seq 1 "$PUBLIC_INGRESS_WAIT"); do
    public_ingress_live && break
    sleep 5
  done
  if ! public_ingress_live; then
    warn "public entrypoint: Traefik does not expose :$PUBLIC_INGRESS_PORT yet — check: sudo k3s kubectl -n kube-system get job,pod | grep traefik"
    return 1
  fi
  if ! kc -n kube-system rollout status deploy/traefik --timeout=180s >/dev/null 2>&1; then
    warn "public entrypoint: Traefik rollout incomplete — check: sudo k3s kubectl -n kube-system get pods"
    return 1
  fi
  info "public entrypoint: suite366-public live on :$PUBLIC_INGRESS_PORT (sets $PUBLIC_INGRESS_HEADER; web/websecure strip it)."
  return 0
}

# PUBLIC_INGRESS_PORT=… in update.env: present iff the entrypoint is live.
# Removed only on a POSITIVE observation (the API answers, the port is not
# there): a transient API failure must not swing the tunnel back and forth.
record_public_ingress_port() { # record_public_ingress_port FILE LIVE(0|1)
  local f="$1" live="$2" cur new
  [[ -f "$f" ]] || return 0
  cur="$(cat "$f")"
  if [[ "$live" != 1 ]]; then
    local ports
    ports="$(public_ingress_svc_ports)" || return 0
    if grep -qx "$PUBLIC_INGRESS_PORT" <<<"$ports"; then return 0; fi
  fi
  new="$(grep -v '^PUBLIC_INGRESS_PORT=' <<<"$cur" || true)"
  if [[ "$live" == 1 ]]; then
    new="${new:+$new
}PUBLIC_INGRESS_PORT=$PUBLIC_INGRESS_PORT"
  fi
  [[ "$new" == "$cur" ]] && return 0
  if ! { ( umask 077; printf '%s\n' "$new" > "$f.tmp" ) && mv -f "$f.tmp" "$f"; }; then
    warn "could not rewrite $f (PUBLIC_INGRESS_PORT)."; rm -f "$f.tmp"; return 0
  fi
  if [[ "$live" == 1 ]]; then info "update.env: PUBLIC_INGRESS_PORT=$PUBLIC_INGRESS_PORT published."
  else warn "update.env: PUBLIC_INGRESS_PORT withdrawn (Traefik does not expose it)."; fi
}
# <<< END SHARED public-ingress BLOCK <<<

# install.sh step. Never fatal: the LAN does not need this entrypoint, and a
# box whose Traefik config is someone else's must still install.
setup_public_ingress() {
  log "Traefik: public entrypoint for the tunnel (:$PUBLIC_INGRESS_PORT)"
  if converge_public_ingress; then
    PUBLIC_INGRESS_LIVE=1
  else
    PUBLIC_INGRESS_LIVE=0
    warn "public entrypoint not live — PUBLIC_INGRESS_PORT is NOT published; update.sh retries daily."
  fi
}
