# shellcheck shell=bash
# =============================================================================
# lib/suite.sh — deploy the Suite 366 `drive` Helm chart (app + Postgres +
# Redis + MinIO + OnlyOffice + LiveKit/TURN) and the CoreDNS workaround that
# resolves *.$DOMAIN in-cluster.
# =============================================================================

# --- 4. Deploy Suite 366 (drive chart) --------------------------------------
deploy_suite() {
  log "Suite 366 (drive chart) -> ns/$NAMESPACE (+ sandbox/$SANDBOX_NAMESPACE)"

  # Pre-create both namespaces. The sandbox one needs the chart's PSS labels
  # before helm rolls out anything inside it, and we set
  # `sandbox.createNamespace: false` so helm doesn't fight us over ownership.
  kc create namespace "$NAMESPACE" --dry-run=client -o yaml | kc apply -f -
  kc create namespace "$SANDBOX_NAMESPACE" --dry-run=client -o yaml | kc apply -f -
  kc label ns "$SANDBOX_NAMESPACE" \
    app=sandbox \
    pod-security.kubernetes.io/enforce=restricted \
    pod-security.kubernetes.io/audit=restricted \
    pod-security.kubernetes.io/warn=restricted \
    --overwrite >/dev/null

  local vals="$DATA_DIR/values.yaml"
  # The PEM public key carries `\`, which is special in a sed REPLACEMENT
  # (and `&`/`|` too) — escape it so the literal `\n` lands verbatim in the
  # YAML (where the double-quoted scalar then turns it into real newlines).
  # The other tokens are alphanumeric / paths and need no escaping.
  local lpk_esc
  lpk_esc="$(printf '%s' "$LICENSE_PUBLIC_KEY" | sed -e 's/[&|\\]/\\&/g')"
  # values.yaml carries `secrets.VLLM_API_KEY` in clear and feeds it
  # to Helm — write it under a restrictive umask so the rendered file lands
  # at 0600 (root-only), and follow with an explicit chmod as belt-and-braces
  # in case umask was inherited from elsewhere.
  ( umask 077
    fetch "values.yaml" \
      | sed -e "s|@DOMAIN@|$DOMAIN|g" \
            -e "s|@HOST_IP@|$HOST_IP|g" \
            -e "s|@PROXY_PORT@|$PROXY_PORT|g" \
            -e "s|@LLM_MODEL@|$LLM_MODEL|g" \
            -e "s|@EMBED_MODEL@|$EMBED_MODEL|g" \
            -e "s|@VLLM_API_KEY@|$VLLM_API_KEY|g" \
            -e "s|@VLLM_EMBEDDING_DIMENSIONS@|$VLLM_EMBEDDING_DIMENSIONS|g" \
            -e "s|@VLLM_MAX_CONTEXT_WINDOW@|$VLLM_MAX_CONTEXT_WINDOW|g" \
            -e "s|@LICENSE_PUBLIC_KEY@|$lpk_esc|g" \
            -e "s|@SANDBOX_NAMESPACE@|$SANDBOX_NAMESPACE|g" \
        > "$vals" )
  chmod 0600 "$vals"

  patch_coredns_for_local_domain
  # CA locale auto-générée par cert-manager : la passer au chart pour qu'il
  # la monte dans drive-app via `customCA` + propage `NODE_EXTRA_CA_CERTS`.
  # Sans ça, drive-app rejette le cert OnlyOffice à
  # `https://office.$DOMAIN/coauthoring/CommandService.ashx` avec
  # `UNABLE_TO_VERIFY_LEAF_SIGNATURE` -> sauvegarde des docs cassée.
  local ca_args=()
  if [[ -f "$DATA_DIR/suite366-local-ca.crt" ]]; then
    ca_args=(--set customCA.enabled=true \
             --set-file "customCA.caCert=$DATA_DIR/suite366-local-ca.crt")
  else
    warn "Local CA not found at $DATA_DIR/suite366-local-ca.crt — drive-app may reject OnlyOffice's TLS cert."
  fi
  info "helm install $RELEASE (pulling chart + images, several minutes)…"
  KUBECONFIG="$KUBECONFIG_PATH" run_progress "Suite 366 deployment" \
    helm upgrade --install "$RELEASE" "$CHART_REF" \
      --version "$CHART_VERSION" --namespace "$NAMESPACE" \
      -f "$vals" "${ca_args[@]}" --wait --timeout 15m
}

# Workaround for server-to-server fetches between drive-app and OnlyOffice:
# drive-app currently uses ONLYOFFICE_URL (https://office.$DOMAIN, mDNS) for
# its forcesave callbacks, but k3s pods have no mDNS resolver — getaddrinfo()
# returns ENOTFOUND and saving the document fails with
# "Failed to save document".
#
# So we inject the 5 *.$DOMAIN names into CoreDNS's NodeHosts ConfigMap so they
# resolve to Traefik's ClusterIP. Traffic stays in-cluster, Traefik terminates
# TLS and routes to the right service.
#
# ⚠️ TEMPORARY: remove once suite-366 uses ONLYOFFICE_INTERNAL_URL (already
# provided by the chart) for its server-side fetches instead of ONLYOFFICE_URL.
# See /etc/cm/coredns in the cluster for the current state.
patch_coredns_for_local_domain() {
  log "CoreDNS: *.$DOMAIN -> Traefik ClusterIP (in-cluster resolution)"
  local traefik_ip
  traefik_ip="$(kc -n kube-system get svc traefik -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  [[ -n "$traefik_ip" ]] || { warn "Traefik ClusterIP not found — skipping CoreDNS patch."; return 0; }
  info "Traefik ClusterIP: $traefik_ip"
  local nh corefile
  nh="$(kc -n kube-system get cm coredns -o jsonpath='{.data.NodeHosts}')"
  corefile="$(kc -n kube-system get cm coredns -o jsonpath='{.data.Corefile}')"
  if grep -q "${traefik_ip}.*drive\.${DOMAIN}" <<<"$nh"; then
    info "*.$DOMAIN entries already present — skipping."
    return 0
  fi
  # Append the 5 names to NodeHosts, then re-create the CM (kubectl create … --dry-run | apply)
  local new_nh
  new_nh="$(printf '%s\n%s drive.%s\n%s office.%s\n%s livekit.%s\n%s turn.%s\n%s %s\n' \
    "$nh" \
    "$traefik_ip" "$DOMAIN" \
    "$traefik_ip" "$DOMAIN" \
    "$traefik_ip" "$DOMAIN" \
    "$traefik_ip" "$DOMAIN" \
    "$traefik_ip" "$DOMAIN")"
  printf '%s' "$new_nh" > /tmp/_corefile_nodehosts
  kc -n kube-system create cm coredns \
    --from-file=NodeHosts=/tmp/_corefile_nodehosts \
    --from-literal=Corefile="$corefile" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  rm -f /tmp/_corefile_nodehosts
  kc -n kube-system rollout restart deploy/coredns >/dev/null
  kc -n kube-system rollout status deploy/coredns --timeout=60s >/dev/null || \
    warn "CoreDNS rollout incomplete — DNS may take ~30s to settle."
  info "CoreDNS NodeHosts updated."
}
