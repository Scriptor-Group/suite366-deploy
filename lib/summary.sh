# shellcheck shell=bash
# =============================================================================
# lib/summary.sh — final post-install summary printed to the operator.
# =============================================================================

# --- 6. Summary --------------------------------------------------------------
summary() {
  local ai
  if [[ "$SKIP_VLLM" == "1" ]]; then
    ai=" Local AI (vLLM): NOT deployed (test mode)."
  else
    ai=$(cat <<AI
 Local AI (wired AUTOMATICALLY into Suite 366 via PR #325 env contract):
   • Unified endpoint (nginx)    : http://$SUITE_IP:$PROXY_PORT/v1
       /v1/embeddings -> vllm-embed ; everything else -> vllm-llm.
       ($SUITE_IP is the stable internal IP — reach it from the box; it is
        network-independent so the app keeps working across LAN changes/offline.)
   • Direct vLLM endpoints (debug, from the box):
       - Generative : http://$SUITE_IP:$LLM_PORT/v1   (model: $LLM_MODEL)
       - Embeddings : http://$SUITE_IP:$EMBED_PORT/v1 (model: $EMBED_MODEL)
   • API key (shared by vLLM + Suite 366): $VLLM_API_KEY
   -> The chart receives VLLM_BASE_URL + VLLM_MODEL_* + VLLM_API_KEY via
      values.yaml; chooseDefaultModel() picks vLLM by default.
   -> Org admins can still register additional "CUSTOM" providers for
      per-org overrides; the system defaults stay on local vLLM.
AI
)
  fi
  cat <<EOF

$(printf "${c_g}========================================================================${c_0}")
$(printf "${c_b} Suite 366 installed on the DGX Spark${c_0}")
$(printf "${c_g}========================================================================${c_0}")

 Application :   https://drive.$DOMAIN
 OnlyOffice  :   https://office.$DOMAIN
 LiveKit     :   wss://livekit.$DOMAIN

$ai

 TLS trust: install the CA on each client machine
   /usr/local/share/suite366-local-ca.crt   (world-readable, ready to scp)
   $DATA_DIR/suite366-local-ca.crt          (same file, root-only)

 DNS: *.{$DOMAIN} is published via mDNS. LAN machines with mDNS support
      (macOS, Windows 10+, Linux+nss-mdns) resolve it without config.

 Network     : cluster pinned to $SUITE_IP on $SUITE_IFACE (stable, survives
                   LAN changes/offline). External access follows the current
                   LAN IP via Traefik + dynamic mDNS.
 systemd services: suite366-net, suite366-vllm, suite366-avahi-aliases, k3s
 Updates         : checked daily (suite366-update.timer, notify-only).
                   Check now : sudo $DATA_DIR/update.sh check
                   Apply     : sudo $DATA_DIR/update.sh apply
                   A pending update drops a marker at $DATA_DIR/update-available.
 Diagnostics     : sudo k3s kubectl -n $NAMESPACE get pods
 Security        : $DATA_DIR is 0700 (root-only); the kubeconfig at
                   $KUBECONFIG_PATH is 0600 — use sudo to inspect.

$(printf "${c_g}========================================================================${c_0}")
EOF
}
