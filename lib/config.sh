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
#          The cost of `proxy`, stated once here and again at install time:
#          the app has ONE canonical origin, so the public name becomes the
#          name for EVERYONE, LAN users included. Without an internal DNS
#          record answering it with the LAN address, traffic between two
#          machines in the same room transits our proxy — and a WAN outage
#          takes the appliance down for people standing next to it.
HOST_MODE="${HOST_MODE:-mdns}"
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
# Fixed Secret names: `provided` mode must know exactly what to create, and the
# chart must never silently fall back to its own default names.
APP_TLS_SECRET="${APP_TLS_SECRET:-drive-tls}"
OFFICE_TLS_SECRET="${OFFICE_TLS_SECRET:-drive-onlyoffice-tls}"
LIVEKIT_TLS_SECRET="${LIVEKIT_TLS_SECRET:-drive-livekit-tls}"
TURN_TLS_SECRET="${TURN_TLS_SECRET:-drive-turn-tls}"
# Filled by check_dns_records() (HOST_MODE=dns): names that do not resolve to
# this host yet. Surfaced again by the final summary so it cannot be missed.
DNS_TODO=()
# Suite 366 drive chart + container images both live on GHCR under the
# Scriptor-Group org. Public, no login required. Override CHART_REF if you
# mirror it.
CHART_REF="${CHART_REF:-oci://ghcr.io/scriptor-group/chart/drive}"
# 0.9.0 : support workbench (namespace/RBAC/quota + env des deux côtés)
CHART_VERSION="${CHART_VERSION:-0.9.0}"
# Channel manifest polled daily by the update timer (see setup_update_timer).
# Publishing a new chart_version/vllm_image here rolls the fleet forward;
# appliances NOTIFY only (no auto-apply). Override to pin a box to a private
# channel. UPDATE_WEBHOOK (optional) gets a JSON POST when an update is found.
MANIFEST_URL="${MANIFEST_URL:-https://raw.githubusercontent.com/Scriptor-Group/suite366-deploy/main/channel.json}"
UPDATE_WEBHOOK="${UPDATE_WEBHOOK:-}"
NAMESPACE="${NAMESPACE:-suite366}"
SANDBOX_NAMESPACE="${SANDBOX_NAMESPACE:-sandbox}"
RELEASE="${RELEASE:-drive}"

LLM_MODEL="${LLM_MODEL:-nvidia/Gemma-4-26B-A4B-NVFP4}"
EMBED_MODEL="${EMBED_MODEL:-Qwen/Qwen3-VL-Embedding-8B}"
# vLLM image: MUST be arm64 + validated for Blackwell GB10/sm_121. Default is
# the official Docker Hub image `vllm/vllm-openai:cu130-nightly` (cu13 + arm64
# multi-arch, validated on DGX Spark — no `docker login` required). Alternative
# if you want the NGC NVIDIA build, override with
# VLLM_IMAGE=nvcr.io/nvidia/vllm:25.11-py3 (requires `docker login nvcr.io`).
VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:cu130-nightly}"
# Tiny URL-path proxy unifying the two vLLM instances behind a single
# OpenAI-compatible endpoint — matches the Suite 366 PR #325 contract
# (one VLLM_BASE_URL, per-role VLLM_MODEL_*). We use nginx:alpine (~50 MB,
# no Python, no startup overhead) over heavier alternatives like LiteLLM.
PROXY_IMAGE="${PROXY_IMAGE:-nginx:1.31-alpine}"
LLM_PORT="${LLM_PORT:-8001}"
EMBED_PORT="${EMBED_PORT:-8002}"
PROXY_PORT="${PROXY_PORT:-8000}"
# Embedding dimension served by the local embed model — exposed to the app
# via VLLM_EMBEDDING_DIMENSIONS so pgvector indexes the right shape.
VLLM_EMBEDDING_DIMENSIONS="${VLLM_EMBEDDING_DIMENSIONS:-4096}"
# Max context window (tokens) the app advertises for the local model — exposed
# via VLLM_MAX_CONTEXT_WINDOW so prompt assembly / truncation sizes correctly.
VLLM_MAX_CONTEXT_WINDOW="${VLLM_MAX_CONTEXT_WINDOW:-200000}"

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
# Values validated on Spark (fresh install test):
#   LLM 0.55 -> KV cache = 402,416 tokens (fp8) -> fits max_model_len=262144 ×
#     max_num_seqs=2 without preemption (measured, 0% swap).
#   EMBED 0.30 -> effective KV cache ~4 GiB for Qwen3-VL-Embedding-8B (8192
#     max model len), once the pool is shared with a warm LLM. 0.25 fails in
#     practice: vLLM sees the LLM's memory as "workspace" on the unified pool
#     -> KV cache computed at 0.41 GiB, not enough. 0.20 -> negative KV.
#   Sum 0.85 -> ~18 GiB of OS headroom on 121 GiB. Measured workable but
#     tight: `free -h` shows ~110/121 GiB used at idle.
#   max_num_seqs=2: above that, chunked_prefill collapses gen throughput
#     (the bottleneck is GB10's prefill compute, not memory). 4 = no
#     measurable improvement, just more OS pressure.
LLM_GPU_MEM_UTIL="${LLM_GPU_MEM_UTIL:-0.55}"
EMBED_GPU_MEM_UTIL="${EMBED_GPU_MEM_UTIL:-0.30}"
LLM_MAX_NUM_SEQS="${LLM_MAX_NUM_SEQS:-2}"
LLM_MAX_MODEL_LEN="${LLM_MAX_MODEL_LEN:-262144}"
EMBED_MAX_MODEL_LEN="${EMBED_MAX_MODEL_LEN:-8192}"

DATA_DIR="${DATA_DIR:-/opt/suite366}"

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
