# shellcheck shell=bash
# =============================================================================
# lib/k3s.sh — single-node k3s install + Helm bootstrap.
# =============================================================================

# --- 1. k3s ------------------------------------------------------------------
install_k3s() {
  log "k3s (single-node)"
  if have k3s; then info "k3s already installed."; else
    info "Downloading + installing k3s (get.k3s.io)…"
    # k3s default kubeconfig mode is 0600 (root-only) — we keep that to avoid
    # giving cluster-admin to any local user (the kubeconfig contains client
    # certs that bypass RBAC). Diagnostics on the host go via `sudo k3s
    # kubectl ...` (k3s embeds kubectl + reads /etc/rancher/k3s/k3s.yaml as
    # root automatically).
    curl -sfL https://get.k3s.io | sh - \
      || die "k3s install failed (network? see above)."
    info "k3s installed."
  fi
  export KUBECONFIG="$KUBECONFIG_PATH"
  log "Waiting for k3s API + node Ready"
  local i
  for i in $(seq 1 60); do          # the node isn't registered immediately at start
    [[ -n "$(k3s kubectl get nodes -o name 2>/dev/null)" ]] && break
    sleep 5
  done
  k3s kubectl wait --for=condition=Ready node --all --timeout=300s \
    || die "k3s node did not become Ready (see: journalctl -u k3s)."
  info "Node Ready."

  if ! have helm; then
    log "Installing Helm"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi
}
