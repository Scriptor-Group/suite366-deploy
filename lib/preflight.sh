# shellcheck shell=bash
# =============================================================================
# lib/preflight.sh — environment checks, NVIDIA toolkit setup, and interactive
# parameter gathering. Runs before anything is deployed.
# =============================================================================

# --- 0. Preflight ------------------------------------------------------------
preflight() {
  log "Preflight"
  [[ "$(id -u)" == "0" ]] || die "Run as root (sudo)."
  # used by cert-manager (CA) and the chart (values). Locked root-only to
  # keep VLLM_API_KEY (values.yaml), chart secrets render, and
  # other generated tokens out of reach of non-root local users.
  mkdir -p "$DATA_DIR" && chmod 0700 "$DATA_DIR"
  [[ "$SKIP_VLLM" == "1" || "$SKIP_GPU" == "1" || "$SKIP_ARCH_CHECK" == "1" ]] && \
    warn "TEST MODE (SKIP_ARCH_CHECK=$SKIP_ARCH_CHECK SKIP_GPU=$SKIP_GPU SKIP_VLLM=$SKIP_VLLM)."
  # aarch64 is the reference target (DGX Spark / GB10). x86_64 is also
  # supported: the Suite 366 images + vLLM image are multi-arch, so the k3s +
  # app layer runs on amd64 too (with or without a GPU). Any other arch has no
  # published image — refuse unless explicitly forced.
  case "$(uname -m)" in
    aarch64) ;;
    x86_64)  info "Architecture x86_64 (amd64) — supported (images are multi-arch)." ;;
    *) [[ "$SKIP_ARCH_CHECK" == "1" ]] || die "Architecture $(uname -m) unsupported (expected aarch64 or x86_64; set SKIP_ARCH_CHECK=1 to force)."
       warn "Architecture $(uname -m) — unsupported, forced via SKIP_ARCH_CHECK." ;;
  esac
  if have lsb_release; then
    local rel; rel="$(lsb_release -rs 2>/dev/null || echo '?')"
    [[ "$rel" == "22.04" ]] || warn "Ubuntu $rel detected (expected 22.04) — continuing."
  fi
  have curl || die "curl required."

  if [[ "$SKIP_GPU" == "1" ]]; then
    warn "GPU/vLLM checks skipped (SKIP_GPU)."
  else
    have nvidia-smi || die "nvidia-smi not found: NVIDIA driver missing? (SKIP_GPU=1 to test without GPU)"
    nvidia-smi -L >/dev/null 2>&1 || die "nvidia-smi failed: GPU not available."
    info "GPU: $(nvidia-smi --query-gpu=name --format=csv,noheader | head -1)"
    have docker || die "Docker required (preinstalled on DGX OS)."
    # DGX OS often ships with the `nvidia-container-toolkit` package BUT
    # without having run `nvidia-ctk runtime configure --runtime=docker`:
    # Docker then doesn't see the runtime, and `runtime: nvidia` in the
    # compose file crashes. We decouple toolkit install from runtime
    # registration. (The modern compose uses `gpus: all`, which works via
    # CDI without this step, but registration is still useful for other
    # tools.)
    if ! docker info 2>/dev/null | grep -qiE 'Runtimes:.*nvidia'; then
      if ! have nvidia-ctk; then
        warn "nvidia-container-toolkit missing — installing."
        install_nvidia_toolkit
      else
        warn "nvidia-container-toolkit present but Docker runtime not registered — running nvidia-ctk runtime configure."
        nvidia-ctk runtime configure --runtime=docker && systemctl restart docker
      fi
    fi
    # Persistent CDI specs. The compose uses `gpus: all`, which resolves via
    # CDI device "nvidia.com/gpu=all". DGX OS does NOT ship a persistent spec
    # under /etc/cdi/ ; the toolkit auto-generates one in /var/run/cdi/ (tmpfs)
    # at first container start. After a reboot, /var/run is wiped, the spec
    # is gone, and the next `docker compose up` fails with
    #   "CDI device injection failed: unresolvable CDI devices nvidia.com/gpu=all"
    # which crash-loops every container that requests GPU. Generate the spec
    # ONCE into /etc/cdi/ so it survives reboots.
    if ! [[ -s /etc/cdi/nvidia.yaml ]]; then
      info "Generating persistent CDI spec at /etc/cdi/nvidia.yaml…"
      mkdir -p /etc/cdi
      nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml >/dev/null 2>&1 \
        || warn "nvidia-ctk cdi generate failed — gpus:all may not resolve after reboot."
    fi
  fi

  HOST_IP="${HOST_IP:-$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')}"
  [[ -n "${HOST_IP:-}" ]] || die "LAN IP not found — export HOST_IP=<ip>."
  info "LAN IP: $HOST_IP"

  local avail_g; avail_g=$(df -BG --output=avail "$(dirname "$DATA_DIR")" 2>/dev/null | tail -1 | tr -dc '0-9' || echo 0)
  [[ "${avail_g:-0}" -ge 200 ]] || warn "Disk space ~${avail_g}GB (<200GB recommended: models + images + PVCs)."

  check_connectivity
}

# Fail LOUDLY if any required endpoint is unreachable (otherwise `curl | sh` /
# image pulls die silently under `set -o pipefail`).
check_connectivity() {
  [[ "${SKIP_NET_CHECK:-0}" == "1" ]] && { warn "Connectivity check skipped (SKIP_NET_CHECK)."; return 0; }
  info "Checking outbound connectivity…"
  local endpoints=(
    "https://get.k3s.io"
    "https://get.helm.sh"
    "https://ghcr.io/v2/"
    "https://registry-1.docker.io/v2/"
    "https://huggingface.co"
  )
  # cert-manager is only fetched in local-ca mode. A box whose customer brings
  # their own certificate has no reason to need charts.jetstack.io — but note
  # this reads TLS_MODE from the ENVIRONMENT: preflight runs before the prompts,
  # so an interactively chosen mode cannot relax the check.
  [[ "$TLS_MODE" == "local-ca" ]] && endpoints+=("https://charts.jetstack.io")
  # NGC only if we actually pull the vLLM image from nvcr.io
  [[ "${VLLM_IMAGE:-}" == nvcr.io/* ]] && endpoints+=("https://nvcr.io/v2/")
  local u code fails=()
  for u in "${endpoints[@]}"; do
    code="$(curl -s -o /dev/null -m 10 -w '%{http_code}' "$u" 2>/dev/null || true)"
    if [[ -z "$code" || "$code" == "000" ]]; then fails+=("$u"); info "  ✗ $u (unreachable)"
    else info "  ✓ $u (HTTP $code)"; fi
  done
  if (( ${#fails[@]} )); then
    die "No outbound access to: ${fails[*]}
      The installer downloads k3s/Helm/cert-manager and pulls container images.
      Give the machine outbound access (or set http_proxy/https_proxy),
      then re-run. (SKIP_NET_CHECK=1 to force through.)"
  fi
}

install_nvidia_toolkit() {
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg
  curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
    | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
    > /etc/apt/sources.list.d/nvidia-container-toolkit.list
  apt-get update -y && apt-get install -y nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker && systemctl restart docker
}

# --- Public hostnames + TLS --------------------------------------------------
# Settled FIRST, because everything downstream is rendered from it: values.yaml
# (app URLs + ingress hosts), the certificates, mDNS, the CoreDNS override and
# the final summary.
gather_hosts() {
  ask HOST_MODE "Hostname mode — mdns (*.local, published on the LAN) or dns (your own DNS)" "$HOST_MODE"
  case "$HOST_MODE" in
    mdns|dns) ;;
    *) die "HOST_MODE='$HOST_MODE' is invalid (expected: mdns or dns)." ;;
  esac

  ask DOMAIN "Base domain" "$DOMAIN"
  DOMAIN="${DOMAIN,,}"

  # Derived AFTER the prompt so a typed domain propagates; a host pinned in the
  # environment is left exactly as given.
  APP_HOST="${APP_HOST:-drive.$DOMAIN}"
  OFFICE_HOST="${OFFICE_HOST:-office.$DOMAIN}"
  LIVEKIT_HOST="${LIVEKIT_HOST:-livekit.$DOMAIN}"
  TURN_HOST="${TURN_HOST:-turn.$DOMAIN}"

  # Four distinct names are required (see README "Custom hostnames"): OnlyOffice
  # and LiveKit each own an Ingress with its own host, and TURN needs its own
  # certificate CN. Only in `dns` mode is it worth asking one by one — under
  # mDNS they must all sit in the same `.local` domain anyway.
  if [[ "$HOST_MODE" == "dns" ]]; then
    echo
    info "Four DNS names are needed. A single wildcard record (*.$DOMAIN -> $HOST_IP)"
    info "covers all of them; otherwise create one A record per name."
    ask APP_HOST     "  Application host" "$APP_HOST"
    ask OFFICE_HOST  "  OnlyOffice host"  "$OFFICE_HOST"
    ask LIVEKIT_HOST "  LiveKit host"     "$LIVEKIT_HOST"
    ask TURN_HOST    "  TURN host"        "$TURN_HOST"
  fi
  APP_HOST="${APP_HOST,,}"; OFFICE_HOST="${OFFICE_HOST,,}"
  LIVEKIT_HOST="${LIVEKIT_HOST,,}"; TURN_HOST="${TURN_HOST,,}"

  local h
  for h in "$APP_HOST" "$OFFICE_HOST" "$LIVEKIT_HOST" "$TURN_HOST"; do
    [[ "$h" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ ]] \
      || die "'$h' is not a valid FQDN (letters, digits, '-', at least one dot)."
  done
  # Distinct names, or Traefik routes two services to one backend by host.
  local uniq
  uniq="$(printf '%s\n' "$APP_HOST" "$OFFICE_HOST" "$LIVEKIT_HOST" "$TURN_HOST" | sort -u | wc -l)"
  [[ "$uniq" == "4" ]] || die "The four hostnames must be distinct (app/office/livekit/turn)."

  check_host_mode
  # TLS before the DNS survey: check_tls_inputs can DIE, and dying right after
  # printing four "this name does not resolve" warnings sends the operator
  # chasing DNS for a certificate problem.
  check_tls_inputs
  if [[ "$HOST_MODE" == "dns" ]]; then check_dns_records; fi
  info "Hostnames: $APP_HOST (app), $OFFICE_HOST (office), $LIVEKIT_HOST (livekit), $TURN_HOST (turn)"
}

# mDNS and `.local` are ONE decision, not two. Avahi happily publishes
# `drive.acme.internal` and every client ignores it: nss-mdns only routes
# `.local` to mDNS. That produced an install that succeeded and resolved
# nowhere, with no error in any log — so both directions are a hard stop.
check_host_mode() {
  local h any_local=0 any_other=0
  for h in "$APP_HOST" "$OFFICE_HOST" "$LIVEKIT_HOST" "$TURN_HOST"; do
    if [[ "$h" == *.local ]]; then any_local=1; else any_other=1; fi
  done
  if [[ "$HOST_MODE" == "mdns" && "$any_other" == 1 ]]; then
    die "HOST_MODE=mdns requires every hostname to end in .local.
      mDNS is only consulted for the .local domain (nss-mdns), so these names
      would be published on the LAN and resolved by no client at all.
      For a routable domain use HOST_MODE=dns and create the DNS records."
  fi
  if [[ "$HOST_MODE" == "dns" && "$any_local" == 1 ]]; then
    die "HOST_MODE=dns with a .local hostname.
      .local is reserved for mDNS; unicast DNS servers are not meant to be
      authoritative for it, and clients query it over multicast regardless.
      Use HOST_MODE=mdns for .local, or pick a real domain (e.g. .internal)."
  fi
  :
}

# Non-fatal on purpose: the DNS records are very often created AFTER the box is
# installed (or by a different team). We report precisely what is missing, keep
# going, and repeat it in the final summary so it cannot be lost in scrollback.
check_dns_records() {
  DNS_TODO=()
  info "Checking DNS for the four names…"
  local h got w=0
  for h in "$APP_HOST" "$OFFICE_HOST" "$LIVEKIT_HOST" "$TURN_HOST"; do
    (( ${#h} > w )) && w=${#h}
  done
  for h in "$APP_HOST" "$OFFICE_HOST" "$LIVEKIT_HOST" "$TURN_HOST"; do
    got="$(getent ahostsv4 "$h" 2>/dev/null | awk '{print $1; exit}' || true)"
    # Padded here rather than at every call site: these strings are printed
    # again verbatim by the final summary.
    if [[ -z "$got" ]]; then
      DNS_TODO+=("$(printf '%-*s' "$w" "$h")  A  $HOST_IP   (does not resolve)")
      info "  x $h — does not resolve"
    elif [[ "$got" != "$HOST_IP" ]]; then
      DNS_TODO+=("$(printf '%-*s' "$w" "$h")  A  $HOST_IP   (currently $got)")
      info "  ! $h -> $got (expected $HOST_IP)"
    else
      info "  v $h -> $got"
    fi
  done
  if (( ${#DNS_TODO[@]} )); then
    warn "${#DNS_TODO[@]} of 4 names do not point at this host yet."
    warn "  The install continues, but the appliance is unreachable until these exist:"
    for h in "${DNS_TODO[@]}"; do warn "    $h"; done
  fi
}

check_tls_inputs() {
  case "$TLS_MODE" in
    local-ca)
      info "TLS: self-signed local CA (cert-manager) — install the CA on each client."
      ;;
    provided)
      # No cert-manager at all in this mode, so nothing must reference an issuer.
      CLUSTER_ISSUER=""
      local svc
      for svc in APP OFFICE LIVEKIT TURN; do resolve_tls_pair "$svc"; done
      if [[ -n "$TLS_CA_FILE" ]]; then
        [[ -s "$TLS_CA_FILE" ]] || die "TLS_CA_FILE not found: $TLS_CA_FILE"
        info "TLS: customer-provided certificates (+ CA bundle $TLS_CA_FILE)."
      else
        warn "TLS: customer-provided certificates, but TLS_CA_FILE is unset."
        warn "  If the issuing CA is not already in the container trust store,"
        warn "  drive-app will reject OnlyOffice's certificate on its server-side"
        warn "  callback and saving a document fails (UNABLE_TO_VERIFY_LEAF_SIGNATURE)."
      fi
      ;;
    acme)
      die "TLS_MODE=acme is not implemented.
      An appliance on a customer LAN cannot usually satisfy either ACME
      challenge: HTTP-01 needs inbound :80 from the internet to this box, and
      DNS-01 needs credentials for the customer's DNS provider, which this
      installer has no generic way to ask for. Use TLS_MODE=provided with a
      certificate issued by whoever controls the domain, or the default
      TLS_MODE=local-ca."
      ;;
    *) die "TLS_MODE='$TLS_MODE' is invalid (expected: local-ca or provided)." ;;
  esac
}

# Resolve one service's cert/key pair (falling back to the shared pair), then
# prove three things before ANYTHING is deployed: the files exist, the key
# actually matches the certificate, and the certificate covers the hostname we
# are about to serve with it. All three are trivial to fix now and painful
# later — a box shipped with a cert that omits the OnlyOffice name looks
# perfectly healthy until the first document is opened.
resolve_tls_pair() { # resolve_tls_pair APP|OFFICE|LIVEKIT|TURN
  local svc="$1" cvar="${1}_TLS_CERT_FILE" kvar="${1}_TLS_KEY_FILE" hvar
  case "$svc" in
    APP)     hvar=APP_HOST ;;
    OFFICE)  hvar=OFFICE_HOST ;;
    LIVEKIT) hvar=LIVEKIT_HOST ;;
    TURN)    hvar=TURN_HOST ;;
    *) die "resolve_tls_pair: unknown service '$svc'." ;;
  esac
  local cert="${!cvar:-}" key="${!kvar:-}" host="${!hvar}"
  cert="${cert:-$TLS_CERT_FILE}"; key="${key:-$TLS_KEY_FILE}"
  [[ -n "$cert" && -n "$key" ]] \
    || die "TLS_MODE=provided needs TLS_CERT_FILE + TLS_KEY_FILE (or $cvar + $kvar for $host)."
  [[ -s "$cert" ]] || die "certificate file not found or empty: $cert"
  [[ -s "$key"  ]] || die "private key file not found or empty: $key"
  have openssl || die "openssl is required to validate a provided certificate."
  local cpub kpub
  cpub="$(openssl x509 -in "$cert" -noout -pubkey 2>/dev/null | openssl md5 2>/dev/null || true)"
  kpub="$(openssl pkey -in "$key" -pubout 2>/dev/null | openssl md5 2>/dev/null || true)"
  [[ -n "$cpub" ]] || die "$cert is not a readable PEM certificate."
  [[ "$cpub" == "$kpub" ]] || die "$key does not match $cert (different public keys)."
  cert_covers_host "$cert" "$host" \
    || die "$cert does not cover '$host'.
      Its subjectAltName lists: $(cert_sans "$cert" | tr '\n' ' ')
      Reissue it with that name, or point $cvar/$kvar at a certificate that has it."
  printf -v "$cvar" '%s' "$cert"
  printf -v "$kvar" '%s' "$key"
}

cert_sans() { # cert_sans CERT -> one lowercase DNS name per line
  openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null \
    | tr ',' '\n' | sed -n 's/.*DNS:\([^ ]*\).*/\1/p' | tr 'A-Z' 'a-z'
}

cert_covers_host() { # cert_covers_host CERT HOST
  local cert="$1" host="$2" n sans
  sans="$(cert_sans "$cert")"
  [[ -n "$sans" ]] || return 1
  while read -r n; do
    [[ -z "$n" ]] && continue
    [[ "$n" == "$host" ]] && return 0
    # A wildcard matches exactly ONE label — *.acme.fr covers drive.acme.fr but
    # not a.b.acme.fr. Same rule browsers apply, so same rule here.
    if [[ "$n" == '*.'* && "$host" == *.* && "${host#*.}" == "${n#*.}" ]]; then
      return 0
    fi
  done <<<"$sans"
  return 1
}

# --- Gather parameters -------------------------------------------------------
gather_inputs() {
  log "Configuration"
  gather_hosts
  ask ADMIN_EMAIL  "Admin email"  "admin@$DOMAIN"
  echo
  # Model ids are still written into values.yaml (the app advertises them, even
  # when the local vLLM backend isn't deployed), so we ask for them regardless.
  ask LLM_MODEL   "Generative model (HF id)" "$LLM_MODEL"
  ask EMBED_MODEL "Embeddings model (HF id)" "$EMBED_MODEL"

  # The HF token (gates model downloads) and the vLLM image are used ONLY by the
  # vLLM stack. When it isn't deployed (SKIP_VLLM / SKIP_GPU), skip these prompts
  # entirely — they'd have no effect.
  if [[ "$SKIP_VLLM" == "1" ]]; then
    info "vLLM stack skipped — not asking for HF token / vLLM image."
  else
    echo
    info "HuggingFace token (optional) — needed for 'gated' models."
    ask_secret HF_TOKEN "  HF token (leave empty if not required)"
    echo
    ask VLLM_IMAGE  "vLLM image (arm64/Blackwell)" "$VLLM_IMAGE"
  fi

  # Reuse the key provisioned on a previous run so re-installs stay idempotent.
  # Without this, each run draws a fresh key: helm hands the app the new one
  # while the already-running vLLM containers keep the old one -> 401s. values.yaml
  # is the source of truth (always written, even under SKIP_VLLM where llm/.env
  # doesn't exist). An explicit VLLM_API_KEY in the env still wins.
  if [[ -z "${VLLM_API_KEY:-}" && -f "$DATA_DIR/values.yaml" ]]; then
    VLLM_API_KEY="$(sed -n 's/.*VLLM_API_KEY: *"\(sk-[^"]*\)".*/\1/p' "$DATA_DIR/values.yaml" | head -1)"
  fi
  VLLM_API_KEY="${VLLM_API_KEY:-sk-$(head -c24 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c32)}"
  # Bash `set -e` + `[[ test ]] && cmd` as the last statement of a function
  # propagates the exit code of `[[ test ]]`: if false, the function returns 1
  # and the script dies silently. We use `if/fi` (plus a final `:`).
  if [[ "$SKIP_VLLM" != "1" && "$VLLM_IMAGE" == "vllm/vllm-openai:latest" ]]; then
    warn "vllm/vllm-openai:latest is NOT validated arm64/Blackwell. Prefer vllm/vllm-openai:cu130-nightly (default)."
  fi
  :
}
