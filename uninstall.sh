#!/usr/bin/env bash
# =============================================================================
# Suite 366 — clean uninstaller for the DGX Spark appliance.
#
#   curl -fsSL https://get.suite366.ai/uninstall.sh | sudo bash
#   # or, from a checkout:  sudo ./uninstall.sh
#
# Reverses everything install.sh created, in the opposite order:
#   • systemd units (net / vLLM / mDNS / update timer + trigger .path units)
#     and the two generated /usr/local/bin helper scripts;
#   • the vLLM ×2 + nginx Docker stack (containers; images are LEFT — see below);
#   • the single-node k3s cluster (via k3s-uninstall.sh — takes the whole app,
#     cert-manager, sandbox, containerd images and /etc/rancher with it);
#   • the stable-IP dummy interface (default suite0);
#   • the world-readable CA copy under /usr/local/share;
#   • $DATA_DIR (/opt/suite366) — INCLUDING the downloaded models.
#
# It deliberately does NOT touch shared/system-level things install.sh may have
# used but that other software relies on: Docker, the NVIDIA container toolkit,
# /etc/cdi/nvidia.yaml, the avahi-daemon package, and the Helm client binary.
# The final summary lists how to remove those by hand if you really want to.
#
# Idempotent + best-effort: every teardown step tolerates the resource already
# being gone, so a re-run (or an uninstall of a partial install) is safe.
#
# Options (environment variables, like install.sh):
#   ASSUME_YES=1    don't prompt for confirmation (required for curl|bash)
#   KEEP_DATA=1     leave $DATA_DIR entirely untouched (models + config + certs)
#   KEEP_MODELS=1   remove $DATA_DIR but PRESERVE the model cache ($MODELS_DIR),
#                   so a later re-install doesn't re-download 15+ GiB
#   KEEP_K3S=1      leave k3s + Helm installed; only remove the Suite 366
#                   workloads (helm release, namespaces, cert-manager) and the
#                   host-level bits. Use if the cluster hosts anything else.
#   PRUNE_IMAGES=1  also remove the vLLM + nginx Docker images (several GiB)
#
#   DATA_DIR, NAMESPACE, RELEASE, DOMAIN, SUITE_IFACE, …  override the install
#   defaults if you installed with non-default values (see lib/config.sh).
# =============================================================================
# NOTE: no `set -e` here (unlike install.sh/update.sh). An uninstaller must
# power through — a resource that is already absent must not abort the teardown.
# We keep -u/-o pipefail and guard every removal with `|| true` / existence
# checks, and `die` explicitly on the couple of hard preconditions.
set -uo pipefail

# --- Output helpers (same palette as install.sh) ----------------------------
c_b="\033[1m"; c_g="\033[32m"; c_y="\033[33m"; c_r="\033[31m"; c_0="\033[0m"
log()  { printf "${c_g}==>${c_0} ${c_b}%s${c_0}\n" "$*"; }
info() { printf "    %s\n" "$*"; }
warn() { printf "${c_y}!!  %s${c_0}\n" "$*"; }
die()  { printf "${c_r}xx  %s${c_0}\n" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
tty_usable() { (exec </dev/tty) >/dev/null 2>&1; }

[[ "$(id -u)" == "0" ]] || die "Run as root (sudo)."

# --- Configuration -----------------------------------------------------------
# Defaults mirror lib/config.sh; every value is overridable via the environment.
# We locate $DATA_DIR first, then pull the install-time identity it recorded in
# update.env (NAMESPACE / RELEASE / KUBECONFIG_PATH) — without clobbering any
# value explicitly set in the invocation environment.
DATA_DIR="${DATA_DIR:-/opt/suite366}"
if [[ -f "$DATA_DIR/update.env" ]]; then
  while IFS='=' read -r _k _v; do
    [[ "$_k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue   # skip blanks/comments
    [[ -n "${!_k:-}" ]] && continue                  # explicit env wins
    printf -v "$_k" '%s' "$_v"
  done < "$DATA_DIR/update.env"
fi

NAMESPACE="${NAMESPACE:-suite366}"
SANDBOX_NAMESPACE="${SANDBOX_NAMESPACE:-sandbox}"
RELEASE="${RELEASE:-drive}"
DOMAIN="${DOMAIN:-suite366.local}"
MODELS_DIR="${MODELS_DIR:-$DATA_DIR/models}"
SUITE_IFACE="${SUITE_IFACE:-suite0}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-/etc/rancher/k3s/k3s.yaml}"

ASSUME_YES="${ASSUME_YES:-0}"
KEEP_DATA="${KEEP_DATA:-0}"
KEEP_MODELS="${KEEP_MODELS:-0}"
KEEP_K3S="${KEEP_K3S:-0}"
PRUNE_IMAGES="${PRUNE_IMAGES:-0}"

# --- Confirmation ------------------------------------------------------------
confirm() {
  log "Suite 366 — uninstall"
  cat <<EOF
    This will remove the Suite 366 appliance from this host:
      • systemd units: suite366-net, suite366-vllm, suite366-avahi-aliases,
        suite366-update(.timer/.service) + the app-trigger .path units
      • the vLLM Docker stack (containers$( [[ "$PRUNE_IMAGES" == "1" ]] && echo " + images"))
      • $( [[ "$KEEP_K3S" == "1" ]] \
             && echo "the Suite 366 workloads + cert-manager (k3s itself is KEPT)" \
             || echo "the ENTIRE k3s cluster (app, cert-manager, sandbox, all data)")
      • the $SUITE_IFACE interface, the CA copy, and generated helper scripts
      • $( if [[ "$KEEP_DATA" == "1" ]]; then echo "$DATA_DIR — KEPT (KEEP_DATA=1)";
           elif [[ "$KEEP_MODELS" == "1" ]]; then echo "$DATA_DIR — removed, but models KEPT ($MODELS_DIR)";
           else echo "$DATA_DIR — removed, INCLUDING the downloaded models"; fi)

EOF
  if [[ "$ASSUME_YES" == "1" ]]; then
    warn "ASSUME_YES=1 — proceeding without confirmation."
    return 0
  fi
  tty_usable || die "No TTY for confirmation. Re-run with ASSUME_YES=1 to proceed non-interactively."
  local ans=""
  read -r -p "    Type 'yes' to proceed: " ans </dev/tty || true
  [[ "$ans" == "yes" ]] || die "Aborted — nothing was changed."
}

# --- 1. systemd units --------------------------------------------------------
# Stop + disable + remove. Order: timers/paths first (so nothing re-triggers a
# service mid-teardown), then the services. Stopping suite366-vllm.service runs
# its ExecStop (`docker compose down`) while the compose file still exists.
remove_systemd_units() {
  log "systemd units"
  local units=(
    suite366-update.timer
    suite366-update-apply.path
    suite366-update-check.path
    suite366-update-apply.service
    suite366-update.service
    suite366-avahi-aliases.service
    suite366-vllm.service
    suite366-net.service
  )
  local u
  for u in "${units[@]}"; do
    # install.sh always writes these under /etc/systemd/system — that file is
    # the authoritative "is it installed?" check (skip silently otherwise).
    [[ -f "/etc/systemd/system/$u" ]] || continue
    systemctl disable --now "$u" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$u"
    info "removed $u"
  done
  systemctl daemon-reload
  systemctl reset-failed 2>/dev/null || true
}

# --- 2. vLLM Docker stack ----------------------------------------------------
# Stopping suite366-vllm.service already ran `docker compose down`; this is the
# belt-and-braces path (unit missing, or containers left behind for any reason).
remove_vllm_stack() {
  have docker || { info "Docker not present — skipping vLLM teardown."; return 0; }
  log "vLLM Docker stack"
  local compose="$DATA_DIR/llm/docker-compose.yml"
  if [[ -f "$compose" ]]; then
    ( cd "$DATA_DIR/llm" && docker compose down --remove-orphans >/dev/null 2>&1 ) \
      && info "docker compose down" || true
  fi
  # Hard fallback by container name (idempotent — silent if already gone).
  docker rm -f suite366-vllm-llm suite366-vllm-embed suite366-vllm-proxy >/dev/null 2>&1 || true

  if [[ "$PRUNE_IMAGES" == "1" ]]; then
    # Only the images referenced by our compose .env, so we never yank an image
    # another workload might share out from under it.
    local env_file="$DATA_DIR/llm/.env" vllm_img proxy_img
    if [[ -f "$env_file" ]]; then
      vllm_img="$(sed -n 's/^VLLM_IMAGE=//p'  "$env_file" | head -1)"
      proxy_img="$(sed -n 's/^PROXY_IMAGE=//p' "$env_file" | head -1)"
      local i
      for i in "$vllm_img" "$proxy_img"; do
        [[ -n "$i" ]] || continue
        docker rmi "$i" >/dev/null 2>&1 && info "removed image $i" || true
      done
    else
      warn "PRUNE_IMAGES=1 but $env_file is gone — cannot identify images to remove."
    fi
  fi
}

# --- 3a. k3s: full teardown --------------------------------------------------
remove_k3s_full() {
  log "k3s cluster (full uninstall)"
  if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    # k3s-uninstall.sh runs k3s-killall.sh, deletes /var/lib/rancher/k3s,
    # /etc/rancher/k3s, the CNI/flannel state, the systemd unit and the binary.
    /usr/local/bin/k3s-uninstall.sh >/dev/null 2>&1 \
      && info "k3s removed." || warn "k3s-uninstall.sh reported errors (continuing)."
  elif have k3s; then
    warn "k3s present but /usr/local/bin/k3s-uninstall.sh missing — trying killall."
    [[ -x /usr/local/bin/k3s-killall.sh ]] && /usr/local/bin/k3s-killall.sh >/dev/null 2>&1 || true
    rm -rf /etc/rancher/k3s /var/lib/rancher/k3s 2>/dev/null || true
  else
    info "k3s not installed — nothing to remove."
  fi
}

# --- 3b. k3s: keep the cluster, remove only the Suite 366 workloads ----------
remove_suite_workloads() {
  log "Suite 366 workloads (k3s KEPT)"
  export KUBECONFIG="$KUBECONFIG_PATH"
  have k3s || { warn "k3s not found — cannot remove workloads (KEEP_K3S)."; return 0; }
  if have helm; then
    helm uninstall "$RELEASE" -n "$NAMESPACE" >/dev/null 2>&1 && info "helm uninstall $RELEASE" || true
    helm uninstall cert-manager -n cert-manager >/dev/null 2>&1 && info "helm uninstall cert-manager" || true
  else
    warn "helm not found — deleting namespaces directly (may orphan CRDs)."
  fi
  local ns
  for ns in "$NAMESPACE" "$SANDBOX_NAMESPACE" cert-manager; do
    k3s kubectl delete namespace "$ns" --ignore-not-found --timeout=120s >/dev/null 2>&1 \
      && info "deleted namespace $ns" || true
  done
  revert_coredns
}

# Best-effort: strip the *.$DOMAIN lines install.sh appended to CoreDNS'
# NodeHosts (only meaningful when the cluster is kept; a full uninstall takes
# CoreDNS with it). Leaving them is harmless (they point at a deleted ClusterIP)
# but tidy is better.
revert_coredns() {
  have k3s || return 0
  local nh corefile new_nh
  nh="$(k3s kubectl -n kube-system get cm coredns -o jsonpath='{.data.NodeHosts}' 2>/dev/null)" || return 0
  [[ -n "$nh" ]] || return 0
  grep -q "\b\(drive\|office\|livekit\|turn\)\.$DOMAIN\b\|[[:space:]]$DOMAIN\$" <<<"$nh" || return 0
  corefile="$(k3s kubectl -n kube-system get cm coredns -o jsonpath='{.data.Corefile}' 2>/dev/null)"
  new_nh="$(grep -v -E "[[:space:]](drive\.|office\.|livekit\.|turn\.)?${DOMAIN//./\\.}\$" <<<"$nh")"
  printf '%s' "$new_nh" > /tmp/_corefile_nodehosts
  k3s kubectl -n kube-system create cm coredns \
    --from-file=NodeHosts=/tmp/_corefile_nodehosts \
    --from-literal=Corefile="$corefile" \
    --dry-run=client -o yaml | k3s kubectl apply -f - >/dev/null 2>&1 \
    && k3s kubectl -n kube-system rollout restart deploy/coredns >/dev/null 2>&1 \
    && info "reverted CoreDNS *.$DOMAIN entries" || true
  rm -f /tmp/_corefile_nodehosts
}

# --- 4. Stable-IP dummy interface --------------------------------------------
remove_stable_iface() {
  log "Stable-IP interface ($SUITE_IFACE)"
  if ip link show "$SUITE_IFACE" >/dev/null 2>&1; then
    ip link set "$SUITE_IFACE" down 2>/dev/null || true
    ip link del "$SUITE_IFACE" 2>/dev/null && info "removed $SUITE_IFACE" \
      || warn "could not delete $SUITE_IFACE (gone after reboot anyway)."
  else
    info "$SUITE_IFACE not present."
  fi
}

# --- 5. Host files: helper scripts, CA copy, dispatcher hooks, runtime state -
remove_host_files() {
  log "Generated host files"
  local f
  for f in \
    /usr/local/bin/suite366-net-up.sh \
    /usr/local/bin/suite366-avahi-aliases.sh \
    /usr/local/share/suite366-local-ca.crt \
    /etc/NetworkManager/dispatcher.d/90-suite366-mdns \
    /etc/networkd-dispatcher/routable.d/90-suite366-mdns \
    /run/suite366-mdns.ip
  do
    [[ -e "$f" ]] && { rm -f "$f" && info "removed $f"; }
  done
}

# --- 6. Data directory -------------------------------------------------------
remove_data_dir() {
  log "Data directory ($DATA_DIR)"
  [[ -d "$DATA_DIR" ]] || { info "$DATA_DIR not present."; return 0; }

  if [[ "$KEEP_DATA" == "1" ]]; then
    info "KEEP_DATA=1 — leaving $DATA_DIR untouched."
    return 0
  fi

  # KEEP_MODELS only makes sense when the model cache lives inside $DATA_DIR
  # (the default). A models dir set outside $DATA_DIR is never touched here.
  local models_inside=0
  case "$MODELS_DIR/" in "$DATA_DIR"/*) models_inside=1 ;; esac

  if [[ "$KEEP_MODELS" == "1" && "$models_inside" == "1" && -d "$MODELS_DIR" ]]; then
    info "KEEP_MODELS=1 — preserving $MODELS_DIR, removing everything else in $DATA_DIR."
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 ! -path "$MODELS_DIR" -exec rm -rf {} + 2>/dev/null || true
    info "kept models at $MODELS_DIR"
  else
    [[ "$KEEP_MODELS" == "1" && "$models_inside" == "0" ]] && \
      info "MODELS_DIR is outside $DATA_DIR — leaving it in place, removing $DATA_DIR."
    rm -rf "$DATA_DIR" && info "removed $DATA_DIR"
  fi
}

# --- Summary -----------------------------------------------------------------
summary() {
  # Build the "left in place" bullet list programmatically — chaining several
  # $(...) conditionals inside a heredoc collapses their lines (command
  # substitution strips trailing newlines).
  local kept=(
    "Docker + the NVIDIA container toolkit + /etc/cdi/nvidia.yaml"
    "the avahi-daemon package (only our alias service was removed)"
    "the Helm client ($(have helm && command -v helm || echo 'not installed'))"
  )
  [[ "$KEEP_K3S" == "1" ]]     && kept+=("k3s (kept: KEEP_K3S=1)")
  [[ "$PRUNE_IMAGES" != "1" ]] && kept+=("the vLLM + nginx Docker images (remove: docker rmi <image>)")
  [[ "$KEEP_DATA" == "1" ]]    && kept+=("$DATA_DIR (kept: KEEP_DATA=1)")
  [[ "$KEEP_MODELS" == "1" && "$KEEP_DATA" != "1" ]] && kept+=("$MODELS_DIR (kept: KEEP_MODELS=1)")
  local kept_lines="" k
  for k in "${kept[@]}"; do kept_lines+="   • $k"$'\n'; done

  cat <<EOF

$(printf "${c_g}========================================================================${c_0}")
$(printf "${c_b} Suite 366 uninstalled${c_0}")
$(printf "${c_g}========================================================================${c_0}")

 Left in place on purpose (shared / system-level — remove by hand if desired):
$kept_lines
 If you had installed the local CA into a client's trust store, remove it there
 too (it was only ever exported for convenience, never system-trusted here).

$(printf "${c_g}========================================================================${c_0}")
EOF
}

main() {
  confirm
  remove_systemd_units
  remove_vllm_stack
  if [[ "$KEEP_K3S" == "1" ]]; then remove_suite_workloads; else remove_k3s_full; fi
  remove_stable_iface
  remove_host_files
  remove_data_dir
  summary
}
main "$@"
