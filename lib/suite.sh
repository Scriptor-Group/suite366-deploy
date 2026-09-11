# shellcheck shell=bash
# =============================================================================
# lib/suite.sh — deploy the Suite 366 `drive` Helm chart (app + Postgres +
# Redis + MinIO + OnlyOffice + LiveKit/TURN) and the CoreDNS workaround that
# resolves the appliance hostnames in-cluster.
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
  # TLS_MODE decides two things inside values.yaml that cannot be expressed as
  # a plain hostname: the ingress annotation line, and whether the chart asks
  # cert-manager for the TURN Certificate. In `provided` and `pushed` mode both
  # point nowhere — install.sh has already created the four Secrets itself, and
  # in `pushed` mode remote.sh replaces them with the real certificate. A
  # cert-manager annotation there would give the Secrets a second owner, and
  # the automated owner is the one that wins.
  #
  # The LAN names are the third: `proxy` mode keeps them alongside the public
  # ones, every other mode has none. Rather than a second template, the LAN
  # lines in values.yaml carry a `#@local` tag — stripped when they apply,
  # deleted line by line when they do not. Both states are valid YAML, so the
  # template can be read and diffed as the file that actually ships.
  local local_lines origins=""
  if [[ -n "${LOCAL_APP_HOST:-}" ]]; then
    local_lines='s|[[:space:]]*#@local$||'
    origins="$(appliance_origins_json)"
  else
    local_lines='/#@local$/d'
  fi
  local cert_annotation turn_cert_manager
  if [[ "$TLS_MODE" == "provided" || "$TLS_MODE" == "pushed" ]]; then
    cert_annotation="suite366.ai/tls-mode: \"$TLS_MODE\""
    turn_cert_manager=false
  else
    cert_annotation="cert-manager.io/cluster-issuer: \"$CLUSTER_ISSUER\""
    turn_cert_manager=true
  fi
  # values.yaml carries `secrets.VLLM_API_KEY` in clear and feeds it
  # to Helm — write it under a restrictive umask so the rendered file lands
  # at 0600 (root-only), and follow with an explicit chmod as belt-and-braces
  # in case umask was inherited from elsewhere.
  ( umask 077
    fetch "values.yaml" \
      | sed -e "$local_lines" \
            -e "s|@DOMAIN@|$DOMAIN|g" \
            -e "s|@APP_HOST@|$APP_HOST|g" \
            -e "s|@OFFICE_HOST@|$OFFICE_HOST|g" \
            -e "s|@LIVEKIT_HOST@|$LIVEKIT_HOST|g" \
            -e "s|@TURN_HOST@|$TURN_HOST|g" \
            -e "s|@APP_TLS_SECRET@|$APP_TLS_SECRET|g" \
            -e "s|@OFFICE_TLS_SECRET@|$OFFICE_TLS_SECRET|g" \
            -e "s|@LIVEKIT_TLS_SECRET@|$LIVEKIT_TLS_SECRET|g" \
            -e "s|@TURN_TLS_SECRET@|$TURN_TLS_SECRET|g" \
            -e "s|@LOCAL_APP_HOST@|$LOCAL_APP_HOST|g" \
            -e "s|@LOCAL_OFFICE_HOST@|$LOCAL_OFFICE_HOST|g" \
            -e "s|@LOCAL_LIVEKIT_HOST@|$LOCAL_LIVEKIT_HOST|g" \
            -e "s|@LOCAL_APP_TLS_SECRET@|$LOCAL_APP_TLS_SECRET|g" \
            -e "s|@LOCAL_OFFICE_TLS_SECRET@|$LOCAL_OFFICE_TLS_SECRET|g" \
            -e "s|@LOCAL_LIVEKIT_TLS_SECRET@|$LOCAL_LIVEKIT_TLS_SECRET|g" \
            -e "s|@APPLIANCE_ORIGINS@|$origins|g" \
            -e "s|@CLUSTER_ISSUER@|$CLUSTER_ISSUER|g" \
            -e "s|@INGRESS_CERT_ANNOTATION@|$cert_annotation|g" \
            -e "s|@TURN_CERT_MANAGER@|$turn_cert_manager|g" \
            -e "s|@HOST_IP@|$HOST_IP|g" \
            -e "s|@SUITE_IP@|$SUITE_IP|g" \
            -e "s|@PROXY_PORT@|$PROXY_PORT|g" \
            -e "s|@LLM_MODEL@|$LLM_MODEL|g" \
            -e "s|@EMBED_MODEL@|$EMBED_MODEL|g" \
            -e "s|@VLLM_API_KEY@|$VLLM_API_KEY|g" \
            -e "s|@VLLM_EMBEDDING_DIMENSIONS@|$VLLM_EMBEDDING_DIMENSIONS|g" \
            -e "s|@VLLM_MAX_CONTEXT_WINDOW@|$VLLM_MAX_CONTEXT_WINDOW|g" \
            -e "s|@LICENSE_PUBLIC_KEY@|$lpk_esc|g" \
            -e "s|@SANDBOX_NAMESPACE@|$SANDBOX_NAMESPACE|g" \
            -e "s|@DATA_DIR@|$DATA_DIR|g" \
        > "$vals" )
  chmod 0600 "$vals"

  # App <-> host bridge dirs, hostPath-mounted into drive-app (see the
  # extraVolumes block in values.yaml). Created BEFORE helm so kubelet's
  # DirectoryOrCreate doesn't make them root:root 0755 (the pod, uid/gid 1001,
  # must be able to drop trigger files — k8s does not fsGroup-chown hostPath).
  #
  # `support` and `remote` stay EMPTY here: both are fleet features
  # (suite366-fleet drops state.json in them). With no state.json the app hides
  # the feature, so a customer-run appliance is unaffected by the mounts.
  #
  # `backup` is created here too, for a different reason: lib/backup.sh runs
  # AFTER helm, so without this the mount would materialise as root:root 0755
  # and the app could never drop a trigger into it.
  local d
  for d in updates support backup remote; do
    mkdir -p "$DATA_DIR/$d"
    chown root:1001 "$DATA_DIR/$d"
    chmod 0770 "$DATA_DIR/$d"
  done

  patch_coredns_for_appliance_hosts
  # CA à monter dans drive-app via `customCA` (+ `NODE_EXTRA_CA_CERTS`). Sans
  # elle, drive-app rejette le cert OnlyOffice à
  # `https://$OFFICE_HOST/coauthoring/CommandService.ashx` avec
  # `UNABLE_TO_VERIFY_LEAF_SIGNATURE` -> sauvegarde des docs cassée.
  # local-ca : la CA auto-générée par cert-manager.
  # provided : la CA émettrice fournie par le client (TLS_CA_FILE) — même
  #            problème, même correctif, source différente.
  local ca_file=""
  case "$TLS_MODE" in
    provided) ca_file="${TLS_CA_FILE:-}" ;;
    # pushed: the certificate comes from a public ACME issuer, already trusted
    # inside the container image, so there is no private CA to inject. The
    # bootstrap certificate is self-signed but is replaced before anyone uses
    # the box for real, and injecting IT would leave a stale CA behind forever.
    pushed)   ca_file="" ;;
    *)        ca_file="$DATA_DIR/suite366-local-ca.crt" ;;
  esac
  write_custom_ca "$vals" "$ca_file"

  info "helm install $RELEASE (pulling chart + images, several minutes)…"
  KUBECONFIG="$KUBECONFIG_PATH" run_progress "Suite 366 deployment" \
    helm upgrade --install "$RELEASE" "$CHART_REF" \
      --version "$CHART_VERSION" --namespace "$NAMESPACE" \
      -f "$vals" --wait --timeout 15m
  prepull_images
}

# APPLIANCE_ORIGINS — the per-request browser-facing origins, as JSON.
#
# The app has ONE canonical origin (APP_URL/WS_URL/ONLYOFFICE_URL/
# LIVEKIT_PUBLIC_URL) and that is correct for everything that must be stable
# and externally resolvable: e-mail links, OAuth callbacks, the OnlyOffice
# callback. It is wrong for the URLs a browser is told to load, because those
# should come from the name the browser actually arrived on — otherwise a LAN
# client is sent across the internet and back to reach a container in the same
# room, and loses the editor and meetings entirely when the WAN is down.
#
# Both names are listed, not just the LAN one: an entry that merely restates
# the canonical origin costs nothing and makes the mapping readable on the box
# instead of implied by a fallback.
appliance_origins_json() {
  printf '[{"host":"%s","appUrl":"https://%s","wsUrl":"wss://%s","officeUrl":"https://%s","livekitUrl":"wss://%s"},' \
    "$LOCAL_APP_HOST" "$LOCAL_APP_HOST" "$LOCAL_APP_HOST" "$LOCAL_OFFICE_HOST" "$LOCAL_LIVEKIT_HOST"
  printf '{"host":"%s","appUrl":"https://%s","wsUrl":"wss://%s","officeUrl":"https://%s","livekitUrl":"wss://%s"}]' \
    "$APP_HOST" "$APP_HOST" "$APP_HOST" "$OFFICE_HOST" "$LIVEKIT_HOST"
}


# Write the CA INTO the generated values.yaml, replacing the template's
# `customCA: {enabled: false}` placeholder with `enabled: true` + the PEM.
#
# It used to be passed on the command line (`--set customCA.enabled=true
# --set-file customCA.caCert=…`), which worked exactly once: `update.sh apply`
# upgrades with `-f values.yaml` alone, and the file pins `enabled: false`, so
# the FIRST update silently dropped NODE_EXTRA_CA_CERTS from drive-app — and
# with it the trust of OnlyOffice's certificate, i.e. "Failed to save
# document" surfacing days after an unrelated version bump. Keeping the value
# in the file makes it survive every later `helm upgrade`.
write_custom_ca() { # write_custom_ca VALUES_FILE CA_FILE
  local vals="$1" ca="$2"
  if [[ -z "$ca" || ! -f "$ca" ]]; then
    if [[ "$TLS_MODE" == "pushed" ]]; then
      info "No custom CA needed: the proxy issues publicly-trusted certificates."
      return 0
    fi
    if [[ "$TLS_MODE" == "provided" ]]; then
      warn "No TLS_CA_FILE given — drive-app will only reach OnlyOffice if the"
      warn "  issuing CA is already trusted inside the container image."
    else
      warn "Local CA not found at ${ca:-<unset>} — drive-app may reject OnlyOffice's TLS cert."
    fi
    return 0
  fi
  local tmp="$vals.tmp"
  # awk over sed: this injects a multi-line PEM as a YAML block scalar, which
  # sed cannot do readably. Idempotent — the whole previous customCA mapping is
  # replaced, so re-running install.sh cannot stack two `caCert:` keys.
  ( umask 077
    awk -v cafile="$ca" '
      $0 == "customCA:" {
        print "customCA:"
        print "  enabled: true"
        print "  caCert: |"
        while ((getline line < cafile) > 0) print "    " line
        close(cafile)
        swallow = 1
        next
      }
      # Drop EVERY indented line that belonged to the old customCA mapping,
      # not just `enabled:` — on a re-run the block we injected last time is
      # still there, and keeping its `caCert:` would emit a duplicate YAML key.
      swallow {
        if ($0 ~ /^[ \t]+[^ \t]/) next
        swallow = 0
      }
      { print }
    ' "$vals" > "$tmp" ) || { warn "could not inject the CA into $vals."; rm -f "$tmp"; return 0; }
  mv -f "$tmp" "$vals"
  chmod 0600 "$vals"
  grep -q '^  caCert: |$' "$vals" || warn "customCA block not injected as expected — check $vals."
  info "customCA: $ca (persisted in values.yaml)"
}

# Pre-pull every referenced image into containerd so a later restart works
# OFFLINE (combined with imagePullPolicy: IfNotPresent). Images used on demand
# — the livekit initContainer (busybox) and the sandbox runner (spawned by
# sandbox-api, not by Helm) — are added explicitly since Helm won't fetch them.
# Best-effort: a failed pull only warns (the image may already be present).
prepull_images() {
  log "Pre-pulling images (offline resilience)"
  local imgs extra i
  imgs="$(kc get deploy,statefulset,daemonset,job -A \
    -o jsonpath='{range .items[*]}{range .spec.template.spec.containers[*]}{.image}{"\n"}{end}{range .spec.template.spec.initContainers[*]}{.image}{"\n"}{end}{end}' \
    2>/dev/null | sort -u)"
  # sandbox-runner is spawned on demand by sandbox-api, never by Helm, so it is
  # not in the list above and has to be named here. Its tag is READ BACK from
  # the values file rather than written twice: the pin lived here in full, one
  # screen away from the identical pin in values.yaml, and an app release that
  # updated one and not the other pre-pulled a version the box never runs —
  # which only shows up offline, months later, as a sandbox that cannot start.
  local runner
  # Matched on the image NAME, not on the key: values.yaml carries a second
  # `runnerImage:` for the workbench, and picking by position would silently
  # pre-pull the wrong one the day the two blocks are reordered.
  runner="$(sed -n 's|^[[:space:]]*runnerImage:[[:space:]]*\(.*suite-366-sandbox-runner:.*\)$|\1|p' \
              "$DATA_DIR/values.yaml" 2>/dev/null | head -1)"
  extra="busybox:1.37
${runner:-ghcr.io/scriptor-group/suite-366-sandbox-runner:1.11.3}
ghcr.io/scriptor-group/suite-366-workbench-runner:latest"
  for i in $imgs $extra; do
    [[ -z "$i" ]] && continue
    if k3s crictl pull "$i" >/dev/null 2>&1; then info "  ✓ $i"; else warn "  ✗ $i (pull failed — offline restart may miss it)"; fi
  done
}

# Workaround for server-to-server fetches between drive-app and OnlyOffice:
# drive-app currently uses ONLYOFFICE_URL (https://$OFFICE_HOST) for its
# forcesave callbacks. Under mDNS, k3s pods have no mDNS resolver at all
# (getaddrinfo() returns ENOTFOUND and saving the document fails with "Failed
# to save document"); under real DNS it would resolve, but only by leaving the
# node and hairpinning back in through the LAN IP.
#
# So we map the appliance hostnames to Traefik's ClusterIP in CoreDNS's
# NodeHosts ConfigMap. Traffic stays in-cluster, Traefik terminates TLS and
# routes by host.
#
# ⚠️ TEMPORARY: remove once suite-366 uses ONLYOFFICE_INTERNAL_URL (already
# provided by the chart) for its server-side fetches instead of ONLYOFFICE_URL.
# See /etc/cm/coredns in the cluster for the current state.
patch_coredns_for_appliance_hosts() {
  log "CoreDNS: appliance hostnames -> Traefik ClusterIP (in-cluster resolution)"
  local traefik_ip
  traefik_ip="$(kc -n kube-system get svc traefik -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true)"
  [[ -n "$traefik_ip" ]] || { warn "Traefik ClusterIP not found — skipping CoreDNS patch."; return 0; }
  info "Traefik ClusterIP: $traefik_ip"

  # The APEX domain is mapped only under mDNS. In `dns` mode the apex is the
  # customer's real zone (their intranet, their mail); pointing it at Traefik
  # for every pod in the cluster would break far more than it fixes.
  # In `proxy` mode this override matters MORE, not less: without it a pod
  # resolving the public OnlyOffice name would leave the building, cross the
  # internet to our proxy and come back through the tunnel to reach a container
  # running beside it — for every server-side document callback.
  local names=("$APP_HOST" "$OFFICE_HOST" "$LIVEKIT_HOST" "$TURN_HOST")
  [[ "$HOST_MODE" == "mdns" ]] && names+=("$DOMAIN")
  # And the LAN names, for the same reason: a pod resolving drive.suite366.local
  # over the cluster DNS gets NXDOMAIN (mDNS is a HOST-side resolver, pods never
  # see it), so any callback aimed at a LAN name would fail inside the cluster
  # while working perfectly from a browser.
  if [[ -n "${LOCAL_APP_HOST:-}" ]]; then
    names+=("$LOCAL_APP_HOST" "$LOCAL_OFFICE_HOST" "$LOCAL_LIVEKIT_HOST" "$LOCAL_TURN_HOST")
  fi

  local nh corefile
  nh="$(kc -n kube-system get cm coredns -o jsonpath='{.data.NodeHosts}')"
  corefile="$(kc -n kube-system get cm coredns -o jsonpath='{.data.Corefile}')"

  # REBUILD rather than append: drop every line that already maps one of our
  # names (whatever IP it carried), then add them back on the current
  # ClusterIP. Appending left stale entries behind whenever the ClusterIP or a
  # hostname changed, and a NodeHosts holding two IPs for one name resolves
  # unpredictably.
  local kept="$nh" n new_nh
  for n in "${names[@]}"; do
    kept="$(awk -v name="$n" '$2 != name' <<<"$kept")"
  done
  new_nh="$kept"
  for n in "${names[@]}"; do
    new_nh="$(printf '%s\n%s %s' "$new_nh" "$traefik_ip" "$n")"
  done

  if [[ "$new_nh" == "$nh" ]]; then
    info "NodeHosts already maps ${#names[@]} names to $traefik_ip — skipping."
    return 0
  fi
  printf '%s' "$new_nh" > /tmp/_corefile_nodehosts
  kc -n kube-system create cm coredns \
    --from-file=NodeHosts=/tmp/_corefile_nodehosts \
    --from-literal=Corefile="$corefile" \
    --dry-run=client -o yaml | kc apply -f - >/dev/null
  rm -f /tmp/_corefile_nodehosts
  kc -n kube-system rollout restart deploy/coredns >/dev/null
  kc -n kube-system rollout status deploy/coredns --timeout=60s >/dev/null || \
    warn "CoreDNS rollout incomplete — DNS may take ~30s to settle."
  info "CoreDNS NodeHosts updated (${#names[@]} names -> $traefik_ip)."
}
