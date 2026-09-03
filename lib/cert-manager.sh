# shellcheck shell=bash
# =============================================================================
# lib/cert-manager.sh — cert-manager + the self-signed local CA ClusterIssuer,
# and export of the CA cert for client-side trust.
# =============================================================================

# --- 3. TLS: local CA (cert-manager) or customer-provided certificates ------
install_cert_manager() {
  if [[ "$TLS_MODE" == "provided" ]]; then
    install_provided_certs
    return 0
  fi
  log "cert-manager + local CA"
  if ! kc -n cert-manager get deploy cert-manager >/dev/null 2>&1; then
    helm repo add jetstack https://charts.jetstack.io >/dev/null 2>&1 || true
    helm repo update >/dev/null
    info "Deploying cert-manager $CERT_MANAGER_VERSION…"
    NAMESPACE=cert-manager run_progress "cert-manager" \
      helm upgrade --install cert-manager jetstack/cert-manager \
        --namespace cert-manager --create-namespace \
        --version "$CERT_MANAGER_VERSION" --set crds.enabled=true --wait \
      || die "cert-manager deployment failed."
  fi
  fetch "tls/local-ca-issuer.yaml" | kc apply -f -
  log "Waiting for CA ClusterIssuer"
  kc wait --for=condition=Ready clusterissuer/suite366-local-ca --timeout=120s || \
    warn "ClusterIssuer suite366-local-ca not ready yet."
  # Export the CA to distribute to client machines. The CA is a *public*
  # certificate by design, so it's safe to also publish a world-readable
  # copy under /usr/local/share/ — useful because $DATA_DIR is locked 0700
  # and the cert otherwise needs `sudo cat` to extract.
  if kc -n cert-manager get secret suite366-local-ca -o jsonpath='{.data.ca\.crt}' \
       | base64 -d > "$DATA_DIR/suite366-local-ca.crt" 2>/dev/null
  then
    chmod 0644 "$DATA_DIR/suite366-local-ca.crt"
    install -m 0644 "$DATA_DIR/suite366-local-ca.crt" /usr/local/share/suite366-local-ca.crt
  fi
}


# TLS_MODE=provided — no cert-manager, no ClusterIssuer, no ACME. The four
# `kubernetes.io/tls` Secrets are created directly from the PEM files that
# preflight already validated (files readable, key matching the certificate,
# hostname present in the SAN), so the chart only has to reference them by
# name. Deploying cert-manager anyway would install CRDs and a controller that
# have nothing left to do on this box.
install_provided_certs() {
  log "TLS: customer-provided certificates (cert-manager not deployed)"
  # deploy_suite creates this namespace too, but it runs AFTER us and the
  # Secrets have to exist before the chart references them.
  kc create namespace "$NAMESPACE" --dry-run=client -o yaml | kc apply -f - >/dev/null

  local svc secret cert key
  for svc in APP OFFICE LIVEKIT TURN; do
    case "$svc" in
      APP)     secret="$APP_TLS_SECRET";     cert="$APP_TLS_CERT_FILE";     key="$APP_TLS_KEY_FILE" ;;
      OFFICE)  secret="$OFFICE_TLS_SECRET";  cert="$OFFICE_TLS_CERT_FILE";  key="$OFFICE_TLS_KEY_FILE" ;;
      LIVEKIT) secret="$LIVEKIT_TLS_SECRET"; cert="$LIVEKIT_TLS_CERT_FILE"; key="$LIVEKIT_TLS_KEY_FILE" ;;
      TURN)    secret="$TURN_TLS_SECRET";    cert="$TURN_TLS_CERT_FILE";    key="$TURN_TLS_KEY_FILE" ;;
    esac
    # resolve_tls_pair() filled these in during preflight; an empty one here
    # means the install order changed and we would create a broken Secret.
    [[ -n "$cert" && -n "$key" ]] || die "internal: TLS pair for $svc unresolved (preflight did not run?)."
    kc -n "$NAMESPACE" create secret tls "$secret" \
      --cert="$cert" --key="$key" \
      --dry-run=client -o yaml | kc apply -f - >/dev/null \
      || die "could not create TLS secret $secret in $NAMESPACE."
    info "  secret/$secret <- $(basename "$cert")"
  done

  # Publish the issuing CA the same way the local-CA path publishes its own, so
  # the summary, uninstall and any operator looking for "the CA on this box"
  # find one file in one place regardless of TLS mode. It is a public
  # certificate: 0644 is intentional.
  if [[ -n "${TLS_CA_FILE:-}" && -f "$TLS_CA_FILE" ]]; then
    install -m 0644 "$TLS_CA_FILE" "$DATA_DIR/suite366-issuing-ca.crt"
    install -m 0644 "$TLS_CA_FILE" /usr/local/share/suite366-issuing-ca.crt
    info "  issuing CA copied to /usr/local/share/suite366-issuing-ca.crt"
  fi
}
