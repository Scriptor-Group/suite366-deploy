# shellcheck shell=bash
# =============================================================================
# lib/cert-manager.sh — cert-manager + the self-signed local CA ClusterIssuer,
# and export of the CA cert for client-side trust.
# =============================================================================

# --- 3. cert-manager + local CA ---------------------------------------------
install_cert_manager() {
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
