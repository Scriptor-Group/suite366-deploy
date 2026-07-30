# Suite 366 - DGX Spark appliance

[Suite 366](https://www.suite366.ai/) is a sovereign, AI-native work suite
(documents, collaborative editing, chat, realtime voice/video, and built-in AI
agents). This repo is the **DGX Spark appliance installer**: a fully self-hosted,
on-device deployment where your data never leaves the box.

One-liner installer that turns a **single NVIDIA DGX Spark** (Ubuntu 22.04 /
DGX OS, **ARM64 GB10 Grace-Blackwell**) into a fully self-hosted Suite 366
appliance: app + database + object storage + collaborative editor + realtime
voice/video + on-device generative & embedding models, all behind HTTPS on a
local mDNS domain.

```bash
curl -fsSL https://get.suite366.ai/install.sh | sudo bash
```

> **What this is for.** The DGX Spark is a 121 GiB unified-memory ARM64 box
> with a Blackwell GB10 GPU. It's well-suited to a single-machine private
> deployment of Suite 366 - your documents and prompts never leave the host.
> This installer is the appliance flavor: opinionated, idempotent, designed
> to boot and stay up across reboots without manual care.

## Contents

- [What gets installed](#what-gets-installed)
- [Prerequisites](#prerequisites)
- [Parameters](#parameters-env-vars-or-interactive-prompts)
- [Running without a GPU](#running-without-a-gpu-test--non-spark-hosts)
- [Measured GB10 realities](#measured-gb10-realities-read-before-tuning)
- [Wiring the AI](#wiring-the-ai-automatic)
- [Repository layout](#repository-layout)
- [Operations](#operations)
- [Survival across reboots](#survival-across-reboots)
- [Security posture](#security-posture)
- [TLS / browser trust](#tls--browser-trust)
- [Known limitations](#known-limitations)
- [License](#license)

## What gets installed

| Layer | Detail |
|---|---|
| **k3s** single-node | Traefik (ingress) + local-path (storage) + CoreDNS (k3s defaults) |
| **vLLM ×2** (Docker host) | generative on `:8001`, embeddings on `:8002`, Blackwell GPU |
| **nginx proxy** (Docker host) | unifies both vLLM behind `:8000` (single OpenAI-compatible endpoint), wired automatically into the Suite 366 chart |
| **Suite 366** (`drive` chart 0.7.1) | drive-app + Postgres (pgvector) + Redis + MinIO + OnlyOffice + LiveKit/TURN, all in-cluster |
| **Sandbox** (`sandbox` namespace) | code-exec stack (`sandbox-api` + on-demand `sandbox-runner` pods, PSS restricted), wired to drive-app via `SANDBOX_API_URL` and a shared `SANDBOX_API_KEY` |
| **TLS** | self-signed local CA (cert-manager), `*.suite366.local` certificates automatic |
| **DNS** | mDNS/Avahi: `*.suite366.local` resolved on the LAN without client-side config |

Total fresh-install time: **~15–30 min** depending on HuggingFace bandwidth
(weights for the two vLLM models are ~33 GiB combined).

## Prerequisites

- DGX Spark running DGX OS (NVIDIA driver + Docker preinstalled). The installer:
  - installs `nvidia-container-toolkit` if missing;
  - runs `nvidia-ctk runtime configure --runtime=docker` if the package is
    present but Docker doesn't see the runtime (common DGX OS case - the
    compose uses `gpus: all` and works either way, but the runtime
    registration is useful for other tools);
  - generates a **persistent** CDI spec at `/etc/cdi/nvidia.yaml` so
    `gpus: all` survives reboots (see *Survival across reboots* below).
- **Helm chart + container images**: all hosted anonymously on GHCR under
  the Scriptor-Group org. No login required.
  - Chart: `oci://ghcr.io/scriptor-group/chart/drive` (v `0.7.1`)
  - Images: `ghcr.io/scriptor-group/suite-366`, `…-sandbox-api`,
    `…-sandbox-runner` (referenced by the chart, no override needed)
  - Override `CHART_REF=` if you mirror the chart somewhere else.
- **Multi-arch images**: the Suite 366 container images on GHCR are published
  multi-arch (`linux/amd64 + linux/arm64`). The appliance targets the DGX Spark
  (arm64/GB10), but the k3s + app layer runs on amd64 too - handy for testing
  the installer on a plain Ubuntu box (see *[Running without a
  GPU](#running-without-a-gpu-test--non-spark-hosts)* below).
- **Outbound network** to `get.k3s.io`, `get.helm.sh`, `ghcr.io`,
  `registry-1.docker.io`, `huggingface.co`, `charts.jetstack.io`. The
  preflight fails loudly if any of these is unreachable.

## Parameters (env vars or interactive prompts)

The script is interactive (reads `/dev/tty`, so it works through
`curl | bash`). Everything can be passed as env vars for a non-interactive run:

| Variable | Default | Purpose |
|---|---|---|
| `HF_TOKEN` | empty | HuggingFace token (for *gated* models) |
| `DOMAIN` | `suite366.local` | local domain (mDNS) |
| `ADMIN_EMAIL` | `admin@<DOMAIN>` | admin email |
| `LLM_MODEL` | `nvidia/Gemma-4-26B-A4B-NVFP4` | generative model (HF id) |
| `EMBED_MODEL` | `Qwen/Qwen3-VL-Embedding-8B` | embeddings model (HF id) |
| `VLLM_IMAGE` | `vllm/vllm-openai:cu130-nightly` | vLLM image arm64/sm_121 (Docker Hub, no NGC login) |
| `PROXY_IMAGE` | `nginx:alpine` | unified vLLM proxy image |
| `LLM_GPU_MEM_UTIL` | `0.55` | share of the unified pool for the generative |
| `EMBED_GPU_MEM_UTIL` | `0.30` | share of the unified pool for embeddings |
| `LLM_MAX_NUM_SEQS` | `2` | max concurrent streams on the generative (cf. § GB10 realities) |
| `LLM_MAX_MODEL_LEN` | `262144` | max context length (generative) |
| `EMBED_MAX_MODEL_LEN` | `8192` | max length for embeddings (enough for RAG chunks) |
| `VLLM_EMBEDDING_DIMENSIONS` | `4096` | embedding vector dimension (Qwen3-VL-Embedding-8B) |
| `ASSUME_YES` | `0` | accept defaults without prompting |

### Running without a GPU (test / non-Spark hosts)

The installer targets the DGX Spark, but the k3s + Suite 366 layer runs on any
Ubuntu amd64/arm64 box. Four env vars relax the hardware checks so you can try
the installer (infra + app, **no local models**) on an ordinary machine:

| Variable | Default | Effect |
|---|---|---|
| `SKIP_GPU` | `0` | skip the NVIDIA driver / toolkit / CDI checks. **Implies `SKIP_VLLM=1`** |
| `SKIP_VLLM` | `0` | don't deploy the vLLM stack (k3s + app only) |
| `SKIP_ARCH_CHECK` | `0` | allow arches other than `aarch64`/`x86_64` (both are supported natively) |
| `SKIP_NET_CHECK` | `0` | skip the outbound-connectivity preflight |

`aarch64` (DGX Spark) and `x86_64` (amd64) are both accepted natively, so an
ordinary Ubuntu box needs no arch flag. Typical run on a plain amd64 machine
with no GPU (pass the flag to `sudo` so it survives the privilege change):

```bash
curl -fsSL https://get.suite366.ai/install.sh | sudo SKIP_GPU=1 bash
```

`SKIP_GPU=1` alone already turns off vLLM (it sets `SKIP_VLLM=1`), so the suite
comes up wired to a `VLLM_BASE_URL` that has no backend: the app installs and
runs, but local-AI calls fail until a real vLLM - or a CUSTOM provider in the
admin UI - is pointed at it. This mode validates the k3s / chart / TLS / mDNS
plumbing, not the AI path.

## Measured GB10 realities (read before tuning)

Validated on Spark `aarch64 / GB10 / DGX OS 6.17 / 121 GiB unified`,
Gemma-4-26B-A4B-NVFP4 under `vllm/vllm-openai:cu130-nightly` (vLLM 0.19.2rc1):

**Unified memory budget.** `gpu_memory_utilization` is NOT pre-allocated in
VRAM (there is no VRAM on GB10) - vLLM uses it to compute the KV cache size
after weights are loaded. With the defaults:
- LLM `0.55` → weights 17.97 GiB + workspace + cudagraphs + **KV cache = 402,416 tokens** (fp8).
- EMBED `0.30` → ~36 GiB raw budget, but ~14 GiB perceived as "workspace" (the
  shared unified pool makes vLLM see the LLM's memory as workspace) →
  effective KV cache ~4 GiB for `max_model_len=8192`. **0.25 fails cold**, 0.20
  yields negative KV cache.
- Sum `0.85` → ~18 GiB of OS headroom on 121 GiB (`free -h` ≈ 110/121 used idle).

**Prefill rate (the real GB10 bottleneck).** ~Quadratic scaling on long contexts:

| Input tokens | Cold prefill |
|---|---|
| 8.7k | 3.3s (2656 t/s) |
| 26k | 13s |
| 53k | 34s |
| 106k | 124s |
| 200k | **565s (≈9m30)** |

This curve is due to the combination of Marlin weight-only FP4 (the only
functional NVFP4 backend on sm_121 in vLLM 0.19) + the `TRITON_ATTN` attention
backend (forced by Gemma 4's heterogeneous heads: `head_dim=256/512`). Native
FP4 paths and `FLASH_ATTN` are not available today for this model on this
platform.

**Concurrency and preemption.** At `max_num_seqs=2 + max_model_len=262144`,
worst-case KV demand (`2×262144 = 524,288`) exceeds budget (`402,416`), but on
2 cold concurrent 200k prompts measured: `Running: 2, Waiting: 0`, **no
preemption**, KV usage < 6%. The practical bottleneck is prefill compute, not
memory - `max_num_seqs > 2` brings nothing (the 2nd request slows down the 1st
via chunked_prefill).

**Critical prefix caching.** Observed hit rate 44-56% even on synthetic prompts
with different seeds (shared French vocab). In production with a stable system
prompt + RAG over fixed docs, expect 80%+. By far the best acceleration lever
on this hardware.

**First vLLM boot.** ~5 min cold (Inductor compile + cudagraph capture), ~3
min on subsequent boots (compile cache at `~/.cache/vllm/torch_compile_cache`).
Qwen3-VL-Embedding-8B weights download (15.5 GiB BF16) adds ~5-10 min on a
fresh install.

## Wiring the AI (automatic)

Suite 366 ships `chooseDefaultModel` + offline vLLM support, so the local stack
is **wired automatically** through the chart values:

```yaml
config:
  VLLM_BASE_URL:            http://<HOST_IP>:8000/v1   # nginx proxy
  VLLM_MODEL_HIGH:          nvidia/Gemma-4-26B-A4B-NVFP4
  VLLM_MODEL_LIGHT:         nvidia/Gemma-4-26B-A4B-NVFP4
  VLLM_MODEL_VISION:        nvidia/Gemma-4-26B-A4B-NVFP4
  VLLM_MODEL_EMBEDDING:     Qwen/Qwen3-VL-Embedding-8B
  VLLM_EMBEDDING_DIMENSIONS: "4096"
  VLLM_MAX_CONTEXT_WINDOW:   "200000"
secrets:
  VLLM_API_KEY:             <random, generated by install.sh>
```

When `VLLM_BASE_URL` is set, `chooseDefaultModel(role)` picks the local vLLM
over Anthropic/OpenAI for every role (precedence `vllm → anthropic → openai`).
Embedding and vision skip Anthropic; vision uses `VLLM_MODEL_VISION` (Gemma 4
is multimodal).

### Why an nginx proxy

The Suite 366 wiring contract expects a **single** `VLLM_BASE_URL` with per-role
`VLLM_MODEL_*`, but we run two vLLM instances on different ports (one for
chat + vision, one for pooling/embed). The `suite366-vllm-proxy` container
(nginx:alpine, ~50 MB, ~10 lines of config) routes by URL path:

```
client -> http://<HOST_IP>:8000/v1/embeddings        -> vllm-embed:8000
client -> http://<HOST_IP>:8000/v1/chat/completions  -> vllm-llm:8000
client -> http://<HOST_IP>:8000/v1/models            -> vllm-llm:8000
client -> http://<HOST_IP>:8000/...                  -> vllm-llm:8000
```

We don't use LiteLLM because the GB10's unified memory is already tight
(~110/121 GiB at idle); a 1.5 GB Python proxy is overkill when URL-path
routing suffices.

### Direct vLLM endpoints (debug / manual override)

The two vLLM instances are still exposed on `:8001` (generative) and `:8002`
(embeddings) so you can curl them directly when troubleshooting. If you want
to register a per-organization provider in the admin UI:

| Provider (CUSTOM, OpenAI-compatible) | Base URL | Model | Key |
|---|---|---|---|
| Chat / vision (direct) | `http://<HOST_IP>:8001/v1` | `nvidia/Gemma-4-26B-A4B-NVFP4` | vLLM key shown |
| Embeddings (direct) | `http://<HOST_IP>:8002/v1` | `Qwen/Qwen3-VL-Embedding-8B` | vLLM key shown |
| Unified (nginx)      | `http://<HOST_IP>:8000/v1` | either of the above | vLLM key shown |

## Repository layout

```
install.sh                            thin bootstrap entry point (curl|bash); loads lib/*.sh, runs main()
lib/config.sh                         default settings (every overridable env var)
lib/common.sh                         shared helpers (ask, run_progress, wait_http, kc)
lib/preflight.sh                      env checks, NVIDIA toolkit setup, input gathering
lib/k3s.sh                            single-node k3s + Helm
lib/vllm.sh                           vLLM ×2 + nginx proxy (host Docker, systemd unit)
lib/cert-manager.sh                   cert-manager + local self-signed CA
lib/suite.sh                          Suite 366 drive Helm chart + CoreDNS patch
lib/mdns.sh                           Avahi/mDNS publishing of *.DOMAIN
lib/updater.sh                        install update.sh + daily notify-only timer
lib/summary.sh                        final post-install summary
update.sh                             update checker/applier (check | apply | scan-usb | install-units); run by the daily timer + app triggers
tools/build-offline-package.sh        build a SIGNED offline update package for an air-gapped appliance
tools/sign-channel.sh                 pin updater_sha256 + sign channel.json (run on every channel bump)
tools/gen-package-key.sh              generate the Ed25519 keypair that signs packages AND channels
tools/test-package-verify.sh          self-test: real signatures, real tampering, no hardware
uninstall.sh                          clean uninstaller — reverses install.sh (systemd units, vLLM stack, k3s, DATA_DIR, …)
channel.json                          fleet release manifest (chart_version / app_version / vllm_image / updater_sha256) polled by update.sh
channel.json.sig                      Ed25519 signature over channel.json — required by any appliance holding the public key
values.yaml                           Helm values (@DOMAIN@/@HOST_IP@/etc. tokens substituted at run-time)
llm/docker-compose.yml                vllm-llm + vllm-embed + vllm-proxy (host Docker)
llm/tool_chat_template_gemma4.jinja   chat template required by --tool-call-parser=gemma4
llm/nginx.conf                        URL-path router unifying both vLLM behind a single endpoint
tls/local-ca-issuer.yaml              local self-signed CA (cert-manager)
dns/avahi-aliases.service             systemd unit publishing mDNS names
```

## Operations

```bash
sudo k3s kubectl -n suite366 get pods          # kubeconfig is 0600 (root only)
docker logs -f suite366-vllm-llm               # generative model logs
systemctl status suite366-vllm                 # vLLM stack
systemctl status suite366-avahi-aliases        # mDNS aliases
```

### Updates

The installer arms a **daily systemd timer** (`suite366-update.timer`) that
polls a **channel manifest** ([`channel.json`](channel.json) in this repo) and
**notifies** when a newer chart, app release or vLLM image is published. It
never applies an upgrade on its own — an **org admin applies it from the app
UI** (Settings → Organization → System update), or over SSH:

```bash
sudo /opt/suite366/update.sh check    # what the timer runs: compare + notify
sudo /opt/suite366/update.sh apply    # actually upgrade (helm + app pins + vLLM image)
systemctl list-timers suite366-update.timer
journalctl -u suite366-update.service # past check results
cat /opt/suite366/update-available    # marker file, present only when one is pending
```

**App <-> host bridge**: `/opt/suite366/updates` is hostPath-mounted into the
drive-app pod (`/appliance-update`, wired by the `extraVolumes` block in
[`values.yaml`](values.yaml)). `update.sh check` publishes `state.json` there
(versions, diff, channel notes) and `update.sh apply` tracks progress in
`apply.json` — that's what the admin UI banner reads. The app requests a check
or an apply by dropping a `check-requested` / `apply-requested` trigger file,
picked up by systemd `.path` units (`suite366-update-check.path`,
`suite366-update-apply.path`, installed by `update.sh install-units`). The
apply reuses the box's install-time parameters (`values.yaml`, `llm/.env`,
`update.env`) — nothing is re-asked. After each apply, `update.sh` refreshes
itself from the repo and re-installs the trigger units, so the update mechanism
itself rolls forward with regular updates. That refresh is signature-verified on
any appliance holding the package public key (see *Signed channels* below);
disable it entirely with `SELF_UPDATE=0` in `update.env`.

**App version pinning**: the appliance pins the app + sandbox image tags in
`values.yaml` (offline safety), so a bare `helm upgrade` never moves the app.
`channel.json`'s `app_version` is what rolls the app forward: on apply,
`update.sh` rewrites the pins to the new tag before upgrading.

### Offline updates from a USB drive

A site with no outbound access updates from a **signed package** instead. The
online check is unchanged and still primary — USB is an *additional* source, and
the two coexist: `check` tries the network and never fails fatally when it is
unreachable, so a verified package still produces an "update available" prompt,
and a reachable network never invalidates a staged one. `state.json` carries both
sources plus the resolved best target (highest app version wins; online wins a tie
since it needs no image import).

Build one (needs docker + helm + the signing key):

```bash
tools/gen-package-key.sh ~/.secrets/package-release      # once, ever
PACKAGE_PRIVATE_KEY=~/.secrets/package-release.key \
  tools/build-offline-package.sh --arch arm64 --min-from 1.8.0
```

Copy the resulting `suite366-update-<version>/` directory to the **root** of a USB
drive, then on the appliance:

```bash
sudo /opt/suite366/update.sh scan-usb /media/usb   # verify + stage; applies nothing
```

The admin then confirms in the app exactly as if the box were online. Deploy the
**public** half of the key to each appliance as
`/opt/suite366/package-release.pub` (`PACKAGE_PUBLIC_KEY`); with no key installed
every package is refused, which is the right default.

Verification is **all-or-nothing**: one Ed25519 signature over a `SHA256SUMS` that
covers every file in the package, `manifest.json` included. One bad byte anywhere,
a foreign signature, a downgrade, or an unmet `min_from_version` and the whole
package is refused — and the refusal is shown in the admin UI, not just written to
the journal. A verified package is copied off the drive before use, so the key can
be unplugged and a mid-copy removal cannot truncate an image tar.

```bash
tools/test-package-verify.sh   # 18 assertions against real signatures + tampering
```

### Signed channels

TLS proves you reached the right host. It says nothing about who wrote the file —
and `channel.json` decides which chart version and which vLLM image every
appliance is told to run, while `update.sh` is fetched over the same channel and
then runs **as root** on the next apply.

So the channel is signed, and one signature covers both: `channel.json` carries
`updater_sha256`, which the signature protects, so verifying the manifest
transitively verifies the updater.

```bash
PACKAGE_PRIVATE_KEY=~/.secrets/package-release.key tools/sign-channel.sh
# -> recomputes updater_sha256 from update.sh, signs channel.json,
#    and verifies its own output the way an appliance will
git add channel.json channel.json.sig && git commit
```

Behaviour on the appliance is **graduated**, so the public one-command install is
unchanged:

| `package-release.pub` on the box | Channel manifest | `update.sh` refresh |
|---|---|---|
| present (fleet) | must be signed by our key, else **refused** | must match the signed `updater_sha256`, else **refused** |
| absent (default) | TLS-only, as before | TLS-only, as before |

Both strict paths **fail closed**: a bad signature makes the manifest unusable
rather than merely suspicious, and a verified USB package can still carry the box
forward. The practical consequence is that forgetting to re-sign does not break the
fleet, it *stops* it — every box keeps its current version silently. The
`channel-signature` workflow exists to catch that before it ships, and
`tools/test-package-verify.sh` covers the refusal paths (23 assertions: foreign
key, tampering after signing, missing signature, stale hash).

By default each box polls the `channel.json` shipped in this repo, so it tracks
the releases published here. Point a box at a manifest you control with
`MANIFEST_URL=…`, or get a push notification by setting `UPDATE_WEBHOOK=…`
(env vars honored at install time, persisted to `/opt/suite366/update.env`).

**Running your own fleet?** Host a `channel.json` anywhere reachable over HTTPS
(a fork's raw URL, an object store, an internal web server) and set
`MANIFEST_URL` to it on each box. Rolling everything forward is then a single
edit: bump `chart_version` (and/or `app_version` / `vllm_image`) in your manifest, and every
appliance picks it up within a day (no per-box changes). If you also mirror the
chart and images, point `CHART_REF` (and, at install time, `BASE_URL`) at your
own registry.

To update the **app config** (not the version): edit
`/opt/suite366/values.yaml` (via `sudo`, the directory is 0700) and run
`sudo /opt/suite366/update.sh apply`, or call `helm upgrade` directly:

```bash
sudo helm upgrade drive oci://ghcr.io/scriptor-group/chart/drive \
  --version 0.7.1 -n suite366 -f /opt/suite366/values.yaml
```

**Note on `nvidia-smi` on GB10**: with unified memory, the `memory.used/free`
fields return `N/A`. To monitor memory pressure, use `free -h` on the host.

### Uninstall

[`uninstall.sh`](uninstall.sh) reverses everything `install.sh` created, in the
opposite order: the systemd units, the two generated `/usr/local/bin` helper
scripts, the vLLM Docker stack, the k3s cluster (via `k3s-uninstall.sh` — which
takes the app, cert-manager, the sandbox namespace and all PVCs with it), the
`suite0` stable-IP interface, the CA copy, and `/opt/suite366` **including the
downloaded models**. It is idempotent and best-effort, so re-running it (or
running it on a partial install) is safe.

```bash
curl -fsSL https://get.suite366.ai/uninstall.sh | sudo ASSUME_YES=1 bash
# or, from a checkout:
sudo ./uninstall.sh          # prompts for confirmation (type 'yes')
```

Options (environment variables, like the installer):

| Var | Effect |
| --- | --- |
| `ASSUME_YES=1`  | skip the confirmation prompt (**required** for `curl \| bash`, which has no TTY) |
| `KEEP_MODELS=1` | remove `/opt/suite366` but keep the model cache (`…/models`), so a re-install doesn't re-download 15+ GiB |
| `KEEP_DATA=1`   | leave `/opt/suite366` entirely untouched (models + config + certs) |
| `KEEP_K3S=1`    | keep k3s + Helm; remove only the Suite 366 workloads (helm release, namespaces, cert-manager) |
| `PRUNE_IMAGES=1`| also remove the vLLM + nginx Docker images (several GiB) |

It deliberately leaves shared/system-level things alone (Docker, the NVIDIA
container toolkit, `/etc/cdi/nvidia.yaml`, the `avahi-daemon` package, the Helm
client); the run ends with a summary listing how to remove those by hand. If
you installed with non-default values (`DATA_DIR`, `NAMESPACE`, `SUITE_IFACE`,
…), pass the same overrides to `uninstall.sh` — it also reads the install-time
identity recorded in `/opt/suite366/update.env`.

## Survival across reboots

On DGX OS, the NVIDIA Container Toolkit auto-generates CDI device specs at
container start, but only under `/var/run/cdi/` (a tmpfs that is wiped at
every reboot). Compose services declared with `gpus: all` (which we use) then
fail to start with:

```
CDI device injection failed: unresolvable CDI devices nvidia.com/gpu=all
```

…and crash-loop forever (`vllm-llm` exits in <10s, `vllm-embed` and
`vllm-proxy` never get past their `depends_on: service_healthy` gate).

The installer therefore generates a **persistent** CDI spec at
`/etc/cdi/nvidia.yaml` during preflight (`nvidia-ctk cdi generate`). If you
add a GPU, swap drivers, or otherwise change the host's NVIDIA stack,
regenerate it:

```bash
sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
sudo systemctl restart suite366-vllm
```

The k3s service, mDNS unit, and the chart workload (Postgres/MinIO/etc. PVCs
on `local-path`) all survive reboots without manual intervention once CDI is
persistent.

## Security posture

- `/etc/rancher/k3s/k3s.yaml` is the k3s default **0600** (cluster-admin
  credentials - bypass RBAC). Any local user with read access becomes
  cluster-admin and can dump every secret rendered by the chart. Inspect
  via `sudo` only.
- `/opt/suite366/` is **0700 root:root**. Contains `values.yaml`
  (carries `VLLM_API_KEY` in clear), `llm/.env`, and the chart's rendered
  state. Do not loosen.
- `/opt/suite366/llm/.env` is **0600** (vLLM key, HF token).
- `/opt/suite366/values.yaml` is **0600** (vLLM key copy fed to Helm).
- `/usr/local/share/suite366-local-ca.crt` is **0644** - a *public* CA cert,
  safe to scp to client machines as-is (no `sudo cat` needed).
- The `curl|sudo bash` chain (k3s, Helm, this installer) relies on TLS +
  the integrity of `get.k3s.io`, `raw.githubusercontent.com`, and the host
  serving `install.sh`. If you need provenance, fork this repo and pin
  `BASE_URL` to your own raw GitHub URL.

## TLS / browser trust

The CA is published at two paths:
- `/usr/local/share/suite366-local-ca.crt` (0644) - ready to `scp` to client
  machines.
- `/opt/suite366/suite366-local-ca.crt` (0644 inside a 0700 directory, so
  root-only access from outside) - same bytes, kept next to the rest of the
  install state.

Install one of these on each client (system keychain / trusted authorities)
to suppress the HTTPS warning.

## Known limitations

- **mDNS** doesn't traverse VPNs or networks that block multicast → fallback:
  add entries to the clients' `/etc/hosts` (`<IP> drive.suite366.local …`).
- The `.local` TLD is the standard mDNS space (intentional). On a routed
  multi-subnet network, prefer a real internal DNS + a TLD like `.internal`.
- **Very long context workloads (>200k tokens)**: prefill takes ~10 min on
  GB10 (cf. § GB10 realities). If your traffic exceeds 14% of >200k calls,
  consider RAG / app-side chunking to keep prompts under 100k.

## License

See [LICENSE](LICENSE).
