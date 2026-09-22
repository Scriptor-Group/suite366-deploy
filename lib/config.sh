# shellcheck shell=bash
# =============================================================================
# lib/config.sh — default settings (all overridable via environment variables).
# Sourced first by install.sh. See the install.sh header for documentation of
# every variable below.
# =============================================================================

# --- Default settings --------------------------------------------------------
DOMAIN="${DOMAIN:-suite366.local}"

# --- Public identity: hostnames + TLS ----------------------------------------
# HOST_MODE decides how LAN clients RESOLVE the appliance. It is not cosmetic:
#   mdns : the names are published over mDNS/Avahi by a host watcher
#          (lib/mdns.sh). This ONLY works inside `.local` — nss-mdns routes
#          only `.local` to mDNS, so `drive.acme.internal` would be published
#          and resolved by nobody. Hence the hard check in gather_hosts().
#   dns  : the customer's own DNS answers for the names. Avahi is not installed
#          at all; the installer verifies the names already point at this host
#          and tells the operator exactly which records to create if not.
#   proxy: the box is PUBLISHED on the internet through Scriptor's proxy
#          (suite366-fleet), at four flat names under REMOTE_DOMAIN. Those
#          names are allocated on the proxy, not chosen here, so the appliance
#          and the proxy registry cannot disagree about what this box is
#          called.
#
#          `proxy` keeps the LAN name as well, by default. The box answers to
#          BOTH: the public names through the proxy, and the usual
#          *.LOCAL_DOMAIN names published over mDNS exactly as in `mdns` mode.
#          A browser gets the URLs matching the name it arrived on — so a LAN
#          client loads the document editor and the meeting socket from the
#          box beside it, not from Paris, and keeps working when the WAN is
#          down.
#
#          What it cannot do is share a SESSION between the two names: cookies
#          are host-only, and the app's canonical origin (used for e-mail
#          links, OAuth callbacks and bot endpoints, which must be stable and
#          externally resolvable) is the PUBLIC name. Someone browsing on the
#          LAN name who follows an e-mailed link lands on the public one and
#          signs in again. Set LOCAL_DOMAIN="" to publish the public names
#          only.
HOST_MODE="${HOST_MODE:-mdns}"
# The LAN-side domain kept alongside the public names in `proxy` mode. Served
# over mDNS with certificates from a local CA generated here — the same
# arrangement `mdns` mode has always had, which is why a customer that already
# trusts that CA needs to do nothing at all.
LOCAL_DOMAIN="${LOCAL_DOMAIN:-suite366.local}"
LOCAL_APP_HOST="${LOCAL_APP_HOST:-}"
LOCAL_OFFICE_HOST="${LOCAL_OFFICE_HOST:-}"
LOCAL_LIVEKIT_HOST="${LOCAL_LIVEKIT_HOST:-}"
LOCAL_TURN_HOST="${LOCAL_TURN_HOST:-}"
# Set by suite366-fleet when HOST_MODE=proxy; the four names derive from them.
REMOTE_NAME="${REMOTE_NAME:-}"
REMOTE_DOMAIN="${REMOTE_DOMAIN:-box.diwy.ai}"
# The four public names. EMPTY here on purpose: they are derived from DOMAIN in
# gather_hosts(), i.e. AFTER the interactive prompt, so a domain typed at the
# prompt propagates into them. Setting one in the environment pins that name
# and the derivation leaves it alone.
APP_HOST="${APP_HOST:-}"
OFFICE_HOST="${OFFICE_HOST:-}"
LIVEKIT_HOST="${LIVEKIT_HOST:-}"
TURN_HOST="${TURN_HOST:-}"

# TLS_MODE:
#   local-ca : self-signed CA created in-cluster by cert-manager (default,
#              unchanged behaviour). Browsers need the CA installed once per
#              client machine.
#   provided : the customer hands us a certificate + key (their internal PKI,
#              or a real public cert). cert-manager is NOT deployed; we create
#              the TLS Secrets ourselves. Set TLS_CA_FILE to the issuing CA so
#              drive-app trusts OnlyOffice server-side — without it, saving a
#              document fails with UNABLE_TO_VERIFY_LEAF_SIGNATURE (see the
#              customCA wiring in lib/suite.sh).
#   pushed   : HOST_MODE=proxy only. The certificate is issued by the Scriptor
#              proxy over DNS-01 and PULLED by suite366-fleet's remote.sh,
#              which owns the four Secrets from then on. install.sh writes a
#              self-signed bootstrap certificate so the chart has something to
#              reference before the box is on the tailnet. cert-manager is not
#              deployed: two owners for one Secret means the automated one
#              silently overwrites the working certificate.
#   acme     : NOT implemented, and refused loudly rather than half-done — see
#              check_tls_inputs() in lib/preflight.sh for the reasoning.
TLS_MODE="${TLS_MODE:-local-ca}"
# Default pair, expected to cover all four names (one multi-SAN certificate, or
# a wildcard). The per-service overrides exist for a PKI that only issues
# single-name certs; each falls back to the pair above.
TLS_CERT_FILE="${TLS_CERT_FILE:-}"
TLS_KEY_FILE="${TLS_KEY_FILE:-}"
TLS_CA_FILE="${TLS_CA_FILE:-}"
APP_TLS_CERT_FILE="${APP_TLS_CERT_FILE:-}"
APP_TLS_KEY_FILE="${APP_TLS_KEY_FILE:-}"
OFFICE_TLS_CERT_FILE="${OFFICE_TLS_CERT_FILE:-}"
OFFICE_TLS_KEY_FILE="${OFFICE_TLS_KEY_FILE:-}"
LIVEKIT_TLS_CERT_FILE="${LIVEKIT_TLS_CERT_FILE:-}"
LIVEKIT_TLS_KEY_FILE="${LIVEKIT_TLS_KEY_FILE:-}"
TURN_TLS_CERT_FILE="${TURN_TLS_CERT_FILE:-}"
TURN_TLS_KEY_FILE="${TURN_TLS_KEY_FILE:-}"
# ClusterIssuer the chart annotates its ingresses with. DERIVED, not an
# override point: the name appears three times in tls/local-ca-issuer.yaml
# (the CA Certificate, its Secret and the ClusterIssuer itself), so honouring an
# environment override here would only annotate the ingresses with an issuer
# that does not exist. check_tls_inputs() empties it in `provided` mode, which
# is how the chart learns to drop the cert-manager annotations entirely.
CLUSTER_ISSUER="suite366-local-ca"
# The SAME issuer, under a name that is never emptied. CLUSTER_ISSUER carries a
# second meaning — "annotate the chart's Ingresses with this" — and preflight
# clears it in `provided` and `pushed` mode to switch those annotations off.
# The LAN certificates in proxy mode still need the issuer OBJECT by name, and
# reusing the cleared variable produced a Certificate with an empty issuerRef:
#   The Certificate "drive-local-tls" is invalid: spec.issuerRef.name: Required value
# found on the first run against real hardware.
LOCAL_CLUSTER_ISSUER="suite366-local-ca"
# Fixed Secret names: `provided` mode must know exactly what to create, and the
# chart must never silently fall back to its own default names.
APP_TLS_SECRET="${APP_TLS_SECRET:-drive-tls}"
OFFICE_TLS_SECRET="${OFFICE_TLS_SECRET:-drive-onlyoffice-tls}"
LIVEKIT_TLS_SECRET="${LIVEKIT_TLS_SECRET:-drive-livekit-tls}"
TURN_TLS_SECRET="${TURN_TLS_SECRET:-drive-turn-tls}"
# The LAN counterparts, used only in `proxy` mode with LOCAL_DOMAIN set. They
# are SEPARATE Secrets on purpose: the public ones are owned by remote.sh
# (which overwrites them wholesale on every pull from the proxy), these ones by
# cert-manager. One Secret with two owners is one working certificate away from
# being silently replaced by the other owner's idea of it.
LOCAL_APP_TLS_SECRET="${LOCAL_APP_TLS_SECRET:-drive-local-tls}"
LOCAL_OFFICE_TLS_SECRET="${LOCAL_OFFICE_TLS_SECRET:-drive-onlyoffice-local-tls}"
LOCAL_LIVEKIT_TLS_SECRET="${LOCAL_LIVEKIT_TLS_SECRET:-drive-livekit-local-tls}"
# Filled by check_dns_records() (HOST_MODE=dns): names that do not resolve to
# this host yet. Surfaced again by the final summary so it cannot be missed.
DNS_TODO=()
# Suite 366 drive chart + container images both live on GHCR under the
# Scriptor-Group org. Public, no login required. Override CHART_REF if you
# mirror it.
CHART_REF="${CHART_REF:-oci://ghcr.io/scriptor-group/chart/drive}"
# 0.10.0 : onlyoffice/livekit ingress `extraHosts` (un 2e nom + son propre
#          Secret TLS sur le meme Ingress), requis par HOST_MODE=proxy qui
#          garde les noms du LAN a cote des noms publics.
CHART_VERSION="${CHART_VERSION:-0.10.0}"
# Channel manifest polled daily by the update timer (see setup_update_timer).
# Publishing a new chart_version/vllm_image here rolls the fleet forward;
# appliances NOTIFY only (no auto-apply). Override to pin a box to a private
# channel. UPDATE_WEBHOOK (optional) gets a JSON POST when an update is found.
MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/Scriptor-Group/suite366-deploy/main/channel.json}"
UPDATE_WEBHOOK="${UPDATE_WEBHOOK:-}"
NAMESPACE="${NAMESPACE:-suite366}"
SANDBOX_NAMESPACE="${SANDBOX_NAMESPACE:-sandbox}"
RELEASE="${RELEASE:-drive}"

# --- Generative model: one of three measured profiles ------------------------
# The appliance can serve three models and switch between them without a
# reinstall. LLM_PROFILE picks one; llm/profiles.sh holds the whole recipe
# (model id, image, memory budgets, context window) and llm/serve-llm.sh the
# vLLM flags. `switch-model.sh` changes it on a running box.
#
#   qwen27b     dense 27B NVFP4 — 262k context, ~20 t/s, real headroom
#   flash-next  MoE 176B-A6B    — 131k context, ~30 t/s, runs at the memory wall
#   gemma       MoE 26B-A4B     — 262k context, ~29 t/s, what the appliance shipped with
#
# Default qwen27b: the only one of the three that leaves the box headroom.
# Flash-Next is faster and stronger but sits at 117/121 GiB with 7-10 GiB of
# swap in use; Gemma is pinned to a vLLM that stopped moving in April. Both
# remain one `switch-model.sh` away — see README "Choosing a model".
LLM_PROFILE="${LLM_PROFILE:-qwen27b}"
EMBED_MODEL="${EMBED_MODEL:-Qwen/Qwen3-VL-Embedding-8B}"
# vLLM image: MUST be arm64 + validated for Blackwell GB10/sm_121. Default is
# the official Docker Hub RELEASE `vllm/vllm-openai:v0.29.0` (CUDA 13.0.2,
# multi-arch, no `docker login`). A tagged release rather than a nightly: the
# old `cu130-nightly` tag silently stopped moving on 2026-04-23 (vLLM 0.19,
# Marlin weight-only FP4), while v0.29.0 selects the native W4A4 CUTLASS
# NVFP4 kernel on sm_121 and carries the Gated-DeltaNet speculative fixes
# (vllm#51812, #51674) the Qwen3.8 MTP head needs. This is the EMBED's image
# and the base of the Flash-Next build; the gemma profile pins its own.
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:v0.29.0}"
# Flash-Next runs VLLM_IMAGE plus the patch set in llm/flash-next/ (vendored
# from blazux/qwen3.8-Flash-DGX at the commit below). lib/vllm.sh builds it on
# the box — no registry holds it — under a tag that names both inputs, so a new
# base image or a refreshed patch set rebuilds.
FLASH_NEXT_PATCHES_COMMIT="${FLASH_NEXT_PATCHES_COMMIT:-b002c8a}"
FLASH_NEXT_IMAGE="suite366/vllm-flash-next:${VLLM_IMAGE##*:}-$FLASH_NEXT_PATCHES_COMMIT"

# llm/profiles.sh is DATA, not a lib/ module: switch-model.sh has to read the
# same table on a running box, where lib/ was never installed. Load it the way
# install.sh's load_module() does — through a temp file, never process
# substitution, so a failed download is an error rather than an empty table
# silently accepted under `set -o pipefail`.
load_llm_profiles() {
  local rel="llm/profiles.sh" tmp
  if [[ -n "${SCRIPT_DIR:-}" && -f "$SCRIPT_DIR/$rel" ]]; then
    # shellcheck disable=SC1090
    source "$SCRIPT_DIR/$rel"; return 0
  fi
  tmp="$(mktemp)"
  curl -fsSL "${BASE_URL:?BASE_URL unset}/$rel" -o "$tmp" \
    || die "Failed to download $rel from $BASE_URL (network? wrong BASE_URL?)."
  # shellcheck disable=SC1090
  source "$tmp"; rm -f "$tmp"
}
load_llm_profiles
llm_profile_known "$LLM_PROFILE" \
  || die "Unknown LLM_PROFILE '$LLM_PROFILE'. Known profiles: $LLM_PROFILES."
llm_profile_apply "$LLM_PROFILE" "$VLLM_IMAGE" "$FLASH_NEXT_IMAGE"

# The profile supplies the defaults; an explicit override still wins, which is
# how a box runs a model at settings we never measured — on purpose, and at the
# operator's risk.
LLM_MODEL="${LLM_MODEL:-$LLM_P_MODEL}"
VLLM_LLM_IMAGE="${VLLM_LLM_IMAGE:-$LLM_P_IMAGE}"
# Transcription: a third vLLM, for the profiles that leave room for it. The
# profile decides (llm/profiles.sh LLM_P_STT_MODEL); `LLM_STT_MODEL=` explicitly
# empty turns it off on a box that needs the memory for something else — `-`
# not `:-`, so that empty is an answer, as for LLM_MTP_TOKENS below.
LLM_STT_MODEL="${LLM_STT_MODEL-$LLM_P_STT_MODEL}"
VLLM_STT_IMAGE="${VLLM_STT_IMAGE:-$(llm_stt_image "$VLLM_IMAGE")}"
# Tiny URL-path proxy unifying the two vLLM instances behind a single
# OpenAI-compatible endpoint — matches the Suite 366 PR #325 contract
# (one VLLM_BASE_URL, per-role VLLM_MODEL_*). We use nginx:alpine (~50 MB,
# no Python, no startup overhead) over heavier alternatives like LiteLLM.
PROXY_IMAGE="${PROXY_IMAGE:-nginx:1.31-alpine}"
LLM_PORT="${LLM_PORT:-8001}"
EMBED_PORT="${EMBED_PORT:-8002}"
STT_PORT="${STT_PORT:-8003}"
PROXY_PORT="${PROXY_PORT:-8000}"
# Embedding dimension served by the local embed model — exposed to the app
# via VLLM_EMBEDDING_DIMENSIONS so pgvector indexes the right shape.
VLLM_EMBEDDING_DIMENSIONS="${VLLM_EMBEDDING_DIMENSIONS:-4096}"
# Max context window (tokens) the app advertises for the local model — exposed
# via VLLM_MAX_CONTEXT_WINDOW so prompt assembly / truncation sizes correctly.
# Profile-driven: 200k for the two 262k-capable models, 131k for Flash-Next.
VLLM_MAX_CONTEXT_WINDOW="${VLLM_MAX_CONTEXT_WINDOW:-$LLM_P_CONTEXT_WINDOW}"

# Verdict of the post-install check on the vLLM key stored in Postgres — the
# fifth and only authoritative copy of it (see lib/vllm-db.sh). Defaulted here
# so lib/summary.sh can render it under `set -u` even if the module never ran.
VLLM_DB_VERIFIED="${VLLM_DB_VERIFIED:-unknown}"
# Postgres deployment override, mirroring backup.sh — discovery derives the name
# from the chart's appName and never hardcodes `drive-postgres`.
PG_DEPLOY="${PG_DEPLOY:-}"

# --- Licensing ---------------------------------------------------------------
# Ed25519 (EdDSA) PUBLIC key shipped to the app to VERIFY signed license
# tokens. Public/verification-only -> safe to ship with the appliance; it
# cannot sign or forge licenses (the private key stays with Devana). Stored
# single-line with literal `\n`; YAML turns them into real PEM newlines when
# the chart renders the value. Override per-deployment via the env var.
_DEFAULT_LICENSE_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAk84/ONPJm9WFpnlQAf7IpRTfdcwwH4Ua3f7NAZtf6/4=\n-----END PUBLIC KEY-----\n'
LICENSE_PUBLIC_KEY="${LICENSE_PUBLIC_KEY:-$_DEFAULT_LICENSE_PUBLIC_KEY}"

# --- vLLM tuning for the GB10 UNIFIED memory (one shared pool ~121 GiB) -------
# Both vLLM instances share this pool (along with the OS, runtime, and KV
# cache): we bound each one (sum < 1.0, headroom kept). The generative is
# prioritized; embeddings get a smaller share.
#
# The GENERATIVE side is profile-driven (llm/profiles.sh carries each model's
# measured fraction, context and slot count, with the reasoning next to it).
# Only the embed is fixed here, because it runs unchanged under all three.
#
#   EMBED 0.20 + an explicit 4 GiB KV budget in the compose
#     (--kv-cache-memory-bytes): ~20 GiB. The fraction alone was the wrong tool:
#     at 0.30 vLLM filled the whole share with KV cache (18.75 GiB, 136k tokens)
#     for a workload that embeds chunks of a few hundred tokens, and lower
#     fractions were fragile because the profiler's result depends on whatever
#     else sits in the unified pool at start-up. With the byte budget the
#     profiler is skipped and the fraction only has to clear the start-up
#     free-memory check. Without this cap Flash-Next did not fit at all.
LLM_GPU_MEM_UTIL="${LLM_GPU_MEM_UTIL:-$LLM_P_GPU_MEM_UTIL}"
LLM_MAX_NUM_SEQS="${LLM_MAX_NUM_SEQS:-$LLM_P_MAX_NUM_SEQS}"
LLM_MAX_MODEL_LEN="${LLM_MAX_MODEL_LEN:-$LLM_P_MAX_MODEL_LEN}"
LLM_MTP_TOKENS="${LLM_MTP_TOKENS-$LLM_P_MTP_TOKENS}"
EMBED_GPU_MEM_UTIL="${EMBED_GPU_MEM_UTIL:-0.20}"
EMBED_MAX_MODEL_LEN="${EMBED_MAX_MODEL_LEN:-8192}"

DATA_DIR="${DATA_DIR:-/opt/suite366}"

# Where the persistent CDI spec is written. Both the preflight refresh and the
# ExecStartPre baked into suite366-vllm.service read this one value, so the two
# cannot drift onto different files.
CDI_SPEC="${CDI_SPEC:-/etc/cdi/nvidia.yaml}"

# --- Backup (restic) ---------------------------------------------------------
# The destination is a CUSTOMER decision, so it is empty by default and the
# appliance ships with the mechanism armed but idle: `backup.sh run` then
# reports "unconfigured" and exits 0 rather than failing nightly. Set
# BACKUP_REPO (any restic backend; S3 is the intended one) at install time, or
# later in $DATA_DIR/backup/backup.env.
#   BACKUP_REPO=s3:s3.fr-par.scw.cloud/<bucket>/<machine-id>
BACKUP_DIR="${BACKUP_DIR:-$DATA_DIR/backup}"
BACKUP_REPO="${BACKUP_REPO:-}"
BACKUP_S3_ACCESS_KEY="${BACKUP_S3_ACCESS_KEY:-}"
BACKUP_S3_SECRET_KEY="${BACKUP_S3_SECRET_KEY:-}"
BACKUP_S3_REGION="${BACKUP_S3_REGION:-}"
# Repository encryption key. Generated when empty; kept 0600 in
# $BACKUP_DIR/repo.pass and printed ONCE at the end of the install. There is no
# recovery path if it is lost — that is the property being bought, and the
# reason a rented box escrows it (suite366-fleet) and a sold one ships it on a
# card inside the crate.
BACKUP_PASSWORD="${BACKUP_PASSWORD:-}"
BACKUP_KEEP_DAILY="${BACKUP_KEEP_DAILY:-7}"
BACKUP_KEEP_WEEKLY="${BACKUP_KEEP_WEEKLY:-4}"
BACKUP_KEEP_MONTHLY="${BACKUP_KEEP_MONTHLY:-6}"
# HH:MM local. Off the hour on purpose: a fleet that all wakes at 02:00 hits
# the same bucket in lockstep (the timer adds up to 15 min of jitter on top).
BACKUP_SCHEDULE="${BACKUP_SCHEDULE:-02:40}"
# Pinned restic + its published checksums (github.com/restic/restic releases).
# Ubuntu 22.04 ships 0.12, which is too old for this repository layout; and a
# root-run binary fetched over TLS alone is exactly the kind of thing the
# package-signing work exists to distrust, hence the hash.
RESTIC_VERSION="${RESTIC_VERSION:-0.19.1}"
RESTIC_SHA256_ARM64="${RESTIC_SHA256_ARM64:-a5f64aaab53d51e311fa3829124c5b703f2d14cf187d8640b6be3b2b49376465}"
RESTIC_SHA256_AMD64="${RESTIC_SHA256_AMD64:-f415415624dcc452f2a02b8c33641791a8c6d6d3b65bbb3543fcf9a25151585c}"
RESTIC_URL_BASE="${RESTIC_URL_BASE:-https://github.com/restic/restic/releases/download}"
RESTIC_BIN="${RESTIC_BIN:-$DATA_DIR/bin/restic}"
# 1 = do not install the backup layer at all.
SKIP_BACKUP="${SKIP_BACKUP:-0}"
MODELS_DIR="${MODELS_DIR:-$DATA_DIR/models}"
# JIT caches mounted into the vLLM containers (torch.compile, FlashInfer,
# Triton) — see llm/docker-compose.yml. Disposable; rebuilt in ~3 min if lost.
CACHE_DIR="${CACHE_DIR:-$DATA_DIR/cache}"
# Ed25519 PUBLIC key that signs OFFLINE update packages (built by
# tools/build-offline-package.sh). Path to a PEM file — when the file is
# ABSENT, `update.sh scan-usb` refuses every package, which is the correct
# default for a box with no offline-update entitlement. Deployments that want
# USB updates drop the key there (suite366-fleet does it at install time).
# Separate keypair from the LICENSE key: different lifecycle, different blast
# radius, and a license key must never acquire code-execution meaning.
PACKAGE_PUBLIC_KEY="${PACKAGE_PUBLIC_KEY:-$DATA_DIR/package-release.pub}"
ASSUME_YES="${ASSUME_YES:-0}"
CERT_MANAGER_VERSION="${CERT_MANAGER_VERSION:-v1.16.2}"

# --- Test mode (VM/box without DGX): relax hardware checks ------------------
#   SKIP_ARCH_CHECK=1  allow arches other than aarch64/x86_64 (both native now)
#   SKIP_GPU=1         don't require an NVIDIA GPU (implies SKIP_VLLM=1)
#   SKIP_VLLM=1        don't deploy the vLLM stack (infra + app only)
SKIP_ARCH_CHECK="${SKIP_ARCH_CHECK:-0}"
SKIP_GPU="${SKIP_GPU:-0}"
SKIP_VLLM="${SKIP_VLLM:-0}"
[[ "$SKIP_GPU" == "1" ]] && SKIP_VLLM=1

KUBECONFIG_PATH=/etc/rancher/k3s/k3s.yaml

# --- Stable internal identity (network-independent) --------------------------
# The whole cluster is pinned to a FIXED private IP carried by an always-up
# `dummy` interface, NOT the LAN IP. This decouples k3s + vLLM + the app's
# internal wiring from whatever the physical network does: a DHCP lease change,
# a WiFi<->Ethernet switch, or going fully offline no longer breaks anything
# (the LAN IP used to be baked into k3s node-ip, the vLLM port bind, and
# VLLM_BASE_URL). External reachability (browsers) still follows the current
# LAN IP via Traefik/ServiceLB (0.0.0.0) + dynamic mDNS — see lib/mdns.sh.
# 10.99.0.0/16 is outside k3s' pod CIDR (10.42/16) and service CIDR (10.43/16).
SUITE_IP="${SUITE_IP:-10.99.0.1}"
SUITE_IFACE="${SUITE_IFACE:-suite0}"
