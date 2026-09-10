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
  # DNS / TLS guidance depends on the two choices made in gather_hosts(); a
  # summary that told every box to install a local CA and wait for mDNS was
  # actively misleading on a box using the customer's DNS and certificates.
  local dns_block tls_block
  if [[ "$HOST_MODE" == "mdns" ]]; then
    dns_block=" DNS: these names are published via mDNS on the current LAN IP.
      LAN machines with mDNS (macOS, Windows 10+, Linux+nss-mdns) resolve them
      with no configuration. mDNS does not cross VPNs or multicast-blocking
      networks — fallback: add the names to those clients' /etc/hosts."
  else
    local w=0 h
    for h in "$APP_HOST" "$OFFICE_HOST" "$LIVEKIT_HOST" "$TURN_HOST"; do
      (( ${#h} > w )) && w=${#h}
    done
    dns_block=" DNS: resolved by YOUR DNS servers (no mDNS is installed).
      Required records, all pointing at this host:"
    for h in "$APP_HOST" "$OFFICE_HOST" "$LIVEKIT_HOST" "$TURN_HOST"; do
      dns_block+="
        $(printf '%-*s' "$w" "$h")  A  $HOST_IP"
    done
    dns_block+="
      A single wildcard (*.$DOMAIN A $HOST_IP) covers all four."
    if (( ${#DNS_TODO[@]} )); then
      dns_block+="
   !! ${#DNS_TODO[@]} of these do NOT resolve to $HOST_IP yet — the appliance
      is not reachable by name until they do:"
      local todo
      for todo in "${DNS_TODO[@]}"; do dns_block+="
        $todo"; done
    fi
  fi

  if [[ "$TLS_MODE" == "provided" ]]; then
    tls_block=" TLS: your own certificates are installed (TLS_MODE=provided).
      Nothing to deploy on client machines, as long as they already trust the
      issuing CA.$( [[ -f "$DATA_DIR/suite366-issuing-ca.crt" ]] && printf '
      A copy of the CA you supplied: /usr/local/share/suite366-issuing-ca.crt' )
      Renewal is YOUR process: replace the certificate in the Secrets
      $APP_TLS_SECRET / $OFFICE_TLS_SECRET / $LIVEKIT_TLS_SECRET /
      $TURN_TLS_SECRET (namespace $NAMESPACE), then restart livekit for TURN.
      Nothing on this box watches their expiry."
  else
    tls_block=" TLS trust: install the local CA on each client machine
      /usr/local/share/suite366-local-ca.crt   (world-readable, ready to scp)
      $DATA_DIR/suite366-local-ca.crt          (same file, root-only)"
  fi

  # The key itself was printed once, when it was generated (lib/backup.sh).
  # Only its fingerprint is repeated here: re-printing a secret at the end of
  # every re-install is how it ends up in a ticket.
  local backup_block
  if [[ "${SKIP_BACKUP:-0}" == "1" ]]; then
    backup_block=" Backups         : NOT installed (SKIP_BACKUP=1)."
  elif [[ -n "${BACKUP_REPO:-}" ]]; then
    backup_block=" Backups         : nightly at $BACKUP_SCHEDULE -> $BACKUP_REPO
                   keep ${BACKUP_KEEP_DAILY}d/${BACKUP_KEEP_WEEKLY}w/${BACKUP_KEEP_MONTHLY}m ; key fingerprint $(sha256sum "$BACKUP_DIR/repo.pass" 2>/dev/null | cut -c1-12)
                   Now      : sudo $DATA_DIR/backup.sh run
                   State    : sudo $DATA_DIR/backup.sh status
                   !! The encryption key exists ONLY on this box. Store it."
  else
    backup_block=" Backups         : mechanism installed, NO DESTINATION SET.
                   Nothing is being backed up. To turn it on:
                     sudo \$EDITOR $BACKUP_DIR/backup.env   (BACKUP_REPO=…)
                     sudo $DATA_DIR/backup.sh init && sudo $DATA_DIR/backup.sh run"
  fi

  cat <<EOF

$(printf "${c_g}========================================================================${c_0}")
$(printf "${c_b} Suite 366 installed on the DGX Spark${c_0}")
$(printf "${c_g}========================================================================${c_0}")

 Application :   https://$APP_HOST
 OnlyOffice  :   https://$OFFICE_HOST
 LiveKit     :   wss://$LIVEKIT_HOST
 TURN        :   $TURN_HOST:5349

$ai

$tls_block

$dns_block

 Network     : cluster pinned to $SUITE_IP on $SUITE_IFACE (stable, survives
                   LAN changes/offline). External access follows the current
                   LAN IP via Traefik$( [[ "$HOST_MODE" == "mdns" ]] && printf ' + dynamic mDNS' ).
 systemd services: suite366-net, suite366-vllm$( [[ "$HOST_MODE" == "mdns" ]] && printf ', suite366-avahi-aliases' ), k3s
$backup_block
 Updates         : checked daily (suite366-update.timer, notify-only).
                   Check now : sudo $DATA_DIR/update.sh check
                   Apply     : sudo $DATA_DIR/update.sh apply
                   A pending update drops a marker at $DATA_DIR/update-available.
 Diagnostics     : sudo k3s kubectl -n $NAMESPACE get pods
 Uninstall       : sudo $DATA_DIR/uninstall.sh   (KEEP_MODELS=1 to keep models)
 Security        : $DATA_DIR is 0700 (root-only); the kubeconfig at
                   $KUBECONFIG_PATH is 0600 — use sudo to inspect.

$(printf "${c_g}========================================================================${c_0}")
EOF
}
