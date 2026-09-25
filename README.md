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
- [Custom hostnames and TLS](#custom-hostnames-and-tls)
- [Running without a GPU](#running-without-a-gpu-test--non-spark-hosts)
- [Measured GB10 realities](#measured-gb10-realities-read-before-tuning)
- [Wiring the AI](#wiring-the-ai-automatic)
- [Repository layout](#repository-layout)
- [Operations](#operations)
- [Backups](#backups)
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
| **Workbench** (`workbench` namespace) | per-user persistent dev sandbox (terminal + opencode + Firefox desktop): one pod + one PVC + one NetworkPolicy per user, driven by `sandbox-api`; `/wb-desktop/` and `/dav/` routed to the ws port |
| **TLS** | self-signed local CA (cert-manager) by default, or **your own certificates** (`TLS_MODE=provided`) |
| **Backups** | nightly `restic` to an S3 destination, encrypted with a key held only on the box |
| **DNS** | mDNS/Avahi by default (`*.suite366.local`, no client config), **your own DNS** (`HOST_MODE=dns`), or a public name through Scriptor's proxy *alongside* the LAN ones (`HOST_MODE=proxy`) |

Total fresh-install time: **~15–30 min** depending on HuggingFace bandwidth
(weights for the two vLLM models are ~33 GiB combined).

## Prerequisites

- DGX Spark running DGX OS (NVIDIA driver + Docker preinstalled). The installer:
  - installs `nvidia-container-toolkit` if missing;
  - runs `nvidia-ctk runtime configure --runtime=docker` if the package is
    present but Docker doesn't see the runtime (common DGX OS case - the
    compose uses `gpus: all` and works either way, but the runtime
    registration is useful for other tools);
  - refreshes a **persistent** CDI spec at `/etc/cdi/nvidia.yaml` on every run
    so `gpus: all` survives reboots (see *Survival across reboots* below).
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
| `HOST_MODE` | `mdns` | `mdns` (names published on the LAN, `.local` only), `dns` (your own DNS answers) or `proxy` (published by Scriptor, LAN names kept) — see below |
| `LOCAL_DOMAIN` | `suite366.local` | `HOST_MODE=proxy` only: the LAN domain kept beside the public names. `""` to publish the public names only |
| `DOMAIN` | `suite366.local` | base domain the four names derive from |
| `APP_HOST` | `drive.<DOMAIN>` | application hostname |
| `OFFICE_HOST` | `office.<DOMAIN>` | OnlyOffice hostname |
| `LIVEKIT_HOST` | `livekit.<DOMAIN>` | LiveKit signalling hostname |
| `TURN_HOST` | `turn.<DOMAIN>` | TURN/TLS hostname |
| `TLS_MODE` | `local-ca` | `local-ca` (self-signed, cert-manager) or `provided` (you supply the certificates) |
| `TLS_CERT_FILE` / `TLS_KEY_FILE` | empty | `provided`: PEM pair covering all four names |
| `TLS_CA_FILE` | empty | `provided`: the issuing CA, mounted into drive-app |
| `ADMIN_EMAIL` | `admin@<DOMAIN>` | admin email |
| `LLM_PROFILE` | `qwen27b` | generative model: `qwen27b`, `orcasaq`, `flash-next` or `gemma` (cf. § Choosing a model) |
| `LLM_MODEL` | *from the profile* | override the HF id the profile names |
| `EMBED_MODEL` | `Qwen/Qwen3-VL-Embedding-8B` | embeddings model (HF id) |
| `VLLM_IMAGE` | `vllm/vllm-openai:v0.29.0` | base image: the embed runs it, Flash-Next and OrcaSAQ are built on it (the `gemma` profile pins its own) |
| `PROXY_IMAGE` | `nginx:alpine` | unified vLLM proxy image |
| `LLM_GPU_MEM_UTIL` | *from the profile* | share of the unified pool for the generative (0.45 / 0.71 / 0.55) |
| `EMBED_GPU_MEM_UTIL` | `0.20` | share of the unified pool for embeddings |
| `LLM_MAX_NUM_SEQS` | `2` | max concurrent streams on the generative (cf. § GB10 realities) |
| `LLM_MAX_MODEL_LEN` | *from the profile* | max context length (262144 / 131072 / 262144) |
| `EMBED_MAX_MODEL_LEN` | `8192` | max length for embeddings (enough for RAG chunks) |
| `VLLM_EMBEDDING_DIMENSIONS` | `4096` | embedding vector dimension (Qwen3-VL-Embedding-8B) |
| `ASSUME_YES` | `0` | accept defaults without prompting |

## Custom hostnames and TLS

By default the appliance serves `drive.suite366.local` and three sibling names,
published over mDNS and secured by a self-signed CA. Both halves of that are
replaceable, and they are **two separate decisions**: how clients *resolve* the
box (`HOST_MODE`), and who *signs* its certificates (`TLS_MODE`).

### Four names, not one

The suite needs four DNS names, because OnlyOffice and LiveKit each own an
ingress with its own host and TURN needs its own certificate name:

| Name | Default | Used by |
|---|---|---|
| `APP_HOST` | `drive.<DOMAIN>` | the app itself (`AUTH_URL`, `APP_URL`, `WS_URL`) |
| `OFFICE_HOST` | `office.<DOMAIN>` | the browser loading the OnlyOffice editor |
| `LIVEKIT_HOST` | `livekit.<DOMAIN>` | WebRTC signalling (`wss://`) |
| `TURN_HOST` | `turn.<DOMAIN>` | TURN/TLS relay on 5349 |

A single wildcard record covers all four. There is no single-hostname mode:
collapsing them onto one name means path-based routing for OnlyOffice and
LiveKit, which is a chart change, not an installer flag.

### `HOST_MODE=mdns` (default) — `.local` only

Names are published by a host watcher (`suite366-avahi-aliases`) on the current
LAN IP, and re-published when that IP changes. This **only works inside
`.local`**: `nss-mdns` routes only the `.local` domain to mDNS, so a name like
`drive.acme.internal` would be advertised on the wire and asked for by nobody.
The installer therefore refuses a non-`.local` name in this mode instead of
producing an appliance that installs cleanly and resolves nowhere.

### `HOST_MODE=dns` — your own DNS

No Avahi is installed at all. Create the four records (or one wildcard) pointing
at the host's LAN IP; the installer checks them and prints the ones still
missing — as a warning, not an error, since DNS is often set up after the box.

```bash
curl -fsSL https://get.suite366.ai/install.sh | sudo env \
  HOST_MODE=dns DOMAIN=suite366.acme.fr bash
```

### `HOST_MODE=proxy` — published on the internet by Scriptor

Only for **rented fleet appliances** (`suite366-fleet`). The box is reachable
from outside the customer's office at four flat names under `box.diwy.ai`,
through a proxy Scriptor runs. The appliance dials out; nothing dials in.

```
acme.box.diwy.ai            acme-office.box.diwy.ai
acme-livekit.box.diwy.ai    acme-turn.box.diwy.ai
```

Flat, not nested, because a wildcard certificate covers exactly one label —
`*.box.diwy.ai` matches `acme.box.diwy.ai` and not `office.acme.box.diwy.ai`.
The names are allocated on the proxy (`proxy/tools/proxy-register.sh`) and
derived here from `REMOTE_NAME`, so the appliance and the proxy registry cannot
disagree about what the box is called.

The proxy does **not** terminate TLS: it routes on SNI and pipes the raw
stream, so the certificate the browser validates is this appliance's own and
Scriptor cannot read the traffic. That is checked, not asserted —
`suite366-fleet/proxy/tests/test-passthrough.sh`.

**The LAN names are kept.** A published box answers to both sets at once: the
public names above, and the usual `*.suite366.local` names published over mDNS
with a local-CA certificate — the same arrangement an unpublished box has
always had. Nothing on the customer side changes, and nobody has to configure
split-horizon DNS: LAN traffic never leaves the building, and the box stays
reachable from the room it is standing in when the WAN is down.

Browser-facing URLs follow the name the request arrived on. The app is handed
`APPLIANCE_ORIGINS` (a JSON map, `serveur/src/lib/appliance-origins.ts`) and a
client on `drive.suite366.local` is told to load OnlyOffice and the LiveKit
socket from the LAN names, so the document editor and meetings keep working
offline too.

Set `LOCAL_DOMAIN=""` to publish only the public names.

⚠️ **What the two names do not share is a session.** Cookies are host-only, and
the *canonical* origin — `AUTH_URL`/`APP_URL`, e-mail links, OAuth callbacks,
the OnlyOffice callback — stays the public name, because it has to be stable
and resolvable from outside. Someone signed in on the LAN name who follows an
e-mailed link lands on the public one and signs in again.

**LiveKit works on the LAN name.** Signalling has its own Ingress host and its
own certificate (`wss://livekit.suite366.local`), and media goes straight to
the box: LiveKit runs with `hostNetwork` and `rtc.dynamicNodeIp`, so it
advertises the current LAN address as its ICE candidate and a LAN browser
sends UDP directly to it. That is the normal path, and the one that survives a
WAN outage.

What is not duplicated is **TURN**, the relay used only when direct UDP is
impossible. It stays on `<name>-turn.box.diwy.ai`, and deliberately so: a WAN
client receives that same LAN address as a candidate, cannot reach it, and
*must* fall back to the relay. TURN is the WAN's path; the LAN does not need
it. (LiveKit reads one `cert_file` for one `domain`, so it could not answer to
both names anyway.)

A LAN client can still use TURN normally while the WAN is up — the public name
resolves, goes out to the proxy and comes back through the tunnel. The single
degraded case is a client **on the LAN, with UDP blocked on that LAN, while
the WAN is down**.

### `TLS_MODE=local-ca` (default)

cert-manager issues everything from a CA generated on the box. Install
`/usr/local/share/suite366-local-ca.crt` on each client to silence the browser
warning.

### `TLS_MODE=provided` — bring your own certificates

The usual answer for a corporate LAN: the customer's PKI issues a certificate,
and cert-manager is not deployed at all. Before anything is installed, the
installer verifies that each file is readable, that the **key matches the
certificate**, and that the certificate's SAN **covers the hostname** it will
serve — a box shipped with a cert missing the OnlyOffice name looks perfectly
healthy until the first document is opened.

```bash
curl -fsSL https://get.suite366.ai/install.sh | sudo env \
  HOST_MODE=dns DOMAIN=suite366.acme.fr TLS_MODE=provided \
  TLS_CERT_FILE=/root/tls/fullchain.pem \
  TLS_KEY_FILE=/root/tls/privkey.pem \
  TLS_CA_FILE=/root/tls/acme-root-ca.pem bash
```

`TLS_CA_FILE` matters more than it looks: drive-app calls OnlyOffice
server-to-server over HTTPS, so the issuing CA has to be inside the container's
trust store or saving a document fails with `UNABLE_TO_VERIFY_LEAF_SIGNATURE`.
Passing it wires the chart's `customCA` (and `NODE_EXTRA_CA_CERTS`).

Renewal in this mode is **yours**: replace `tls.crt`/`tls.key` in the four
Secrets (`drive-tls`, `drive-onlyoffice-tls`, `drive-livekit-tls`,
`drive-turn-tls`) in the `suite366` namespace and restart livekit for TURN.
Nothing on the box watches their expiry.

A PKI that only issues single-name certificates can supply one pair per
service instead: `APP_TLS_CERT_FILE` / `APP_TLS_KEY_FILE`, and the same for
`OFFICE_`, `LIVEKIT_`, `TURN_`.

### `TLS_MODE=pushed` — the proxy issues, the appliance pulls

`HOST_MODE=proxy` only. The certificate for the four public names is issued on
the proxy over DNS-01 and pulled by `remote.sh`, which owns the four TLS Secrets
from then on. The DNS credential never leaves the proxy, and no appliance holds
a fleet-wide wildcard — a stolen box must not be able to impersonate another
customer.

`install.sh` writes a **self-signed bootstrap certificate** covering the same
four names, because the box is not on the tailnet yet and the chart needs
Secrets to reference. It is replaced on the first pull. cert-manager is not
deployed in this mode: two owners for one Secret means the automated one
silently overwrites the working certificate.

### `TLS_MODE=acme` is refused

Deliberately, rather than half-working: HTTP-01 needs inbound `:80` from the
internet to a box sitting on a customer LAN, and DNS-01 needs credentials for
their DNS provider that this installer has no generic way to ask for. Use
`provided` with a certificate from whoever controls the domain.

### Changing the hostname after installation

Not supported as a one-liner yet. It is a `helm upgrade` plus new certificates,
new CoreDNS entries and an mDNS change — and, on the app side, everyone is
signed out (cookies are bound to the domain) and links in already-sent emails
stop working. Plan it as a maintenance window rather than a live edit.

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

## Choosing a model

The appliance serves ONE generative model at a time, out of four that were each
measured end to end on the test Spark. `LLM_PROFILE` picks it at install time,
`switch-model.sh` changes it afterwards without a reinstall.

| | `qwen27b` *(default)* | `orcasaq` | `flash-next` | `gemma` |
|---|---|---|---|---|
| Model | Qwen3.8-27B-NVFP4 | OrcaSAQ-2-27B | Qwen3.8-Flash-Next-NVFP4 | Gemma-4-26B-A4B-NVFP4 |
| Shape | dense 27B hybrid | the same 27B, 3.2-bit trellis | MoE 176B, 6B active | MoE 26B, 4B active |
| On disk | 21.9 GB | 12.3 GB | 123.5 GB | 18 GB |
| Resident | 20.8 GiB | 11.5 GiB | 77.1 GiB | 18.0 GiB |
| Context served | 262,144 | 262,144 | 131,072 | 262,144 |
| Decode, French prose | 19-20 t/s | 38.1 t/s | 26.7 t/s | 28-30 t/s |
| Decode, code | ~30 t/s | 45.0 t/s | 34.9 t/s | not measured |
| Prefill | 69k in 49 s (1,400 tok/s) | 23k in 22.5 s (1,014 tok/s) | 69k in 33 s | 62k in 65 s |
| Swap in use, idle | 0 | 0 | 7-10 GiB | 3 GiB (with transcription) |
| vLLM | official v0.29.0 | v0.29.0 + `llm/exl3/` | v0.29.0 + `llm/flash-next/` | pinned `cu130-nightly` (0.19) |
| Vision | yes | no (text-only checkpoint) | yes | yes |
| Transcription | Qwen3-ASR-1.7B (+10 GiB resident) | Qwen3-ASR-1.7B | none (no room) | Qwen3-ASR-1.7B (share lowered to 0.45) |

**`qwen27b` is the default** because it leaves the box real headroom without
building anything: 20.8 GiB of weights, a KV cache of 818,650 fp8 tokens (3.1x a
full 262k request) and zero swap at idle. It is also the slowest of the four to
decode, which is physics: 20.8 GiB over the GB10's 273 GB/s is 12 t/s, and the
in-checkpoint MTP head recovers it to 19-20.

**`orcasaq` is the same Qwen3.8-27B at 3.2 bits per weight.** `orcarouter`
quantised it with a sensitivity-searched mixed-precision trellis code (the EXL3 /
QTIP family: 3.21 bits on the decoder, 6-bit `lm_head`, int8 embedding, 4-bit
MTP head) and reports it within 0.02 % of BF16 perplexity on WikiText-2. vLLM
cannot read the format by itself, so the profile builds its own image on the box
(`llm/exl3/`: exllamav3's kernels compiled for sm_121 plus the plugin that
registers the format, ~4 min) and the checkpoint is text-only — the app's vision
role points at it too, and images simply are not understood. Measured on the
test Spark on 2026-09-25: 11.5 GiB resident, loaded in 56 s and serving 110 s
after the container start with the compile cache warm; at the same 0.45 share as
`qwen27b` the KV cache seats 771,787 fp8 tokens (2.9x a full 262k request), and
with the embed and the transcription engine up the box sits at 97/121 GiB, like
`qwen27b`. Decode is the point: 38 t/s on French prose and 45 on code against
19-20 and ~30 for the NVFP4 build, because 12 GiB cross the same 273 GB/s twice
as fast — with the checkpoint's 4-bit MTP head at k=3; without it the trellis
kernel decodes at 15.7 t/s. Prefill is the price: 1,014 tok/s against ~1,400,
because above 144 rows every projection is rebuilt to BF16 in a scratch buffer
before its GEMM, so a 69k-token document takes ~68 s to read instead of 49.
Tool calling (`qwen3_xml`) and the reasoning parser work as on `qwen27b`. The
quantiser is not public and the checkpoint was a day old when this was
measured; its quality claims are the card's, not ours.

**`flash-next` is the strongest and the fastest, and it runs at the wall.** The
checkpoint is 123.5 GiB for 121.6 GiB of RAM; it only fits because the 47.7 GiB
n-gram table is served from the NVMe by `mmap` instead of being loaded (a token
reads 16 rows of it), which is a community patch set vendored and documented in
`llm/flash-next/README.md`. Once up, `free` shows 117/121 GiB used and 7-10 GiB
of swap in use, and `vmstat` reads 0.3-0.8 MB/s back from swap during every
generation. It works; it has no margin. On one Spark, next to the 8B embedding
model, treat it as a demo rather than a service — an embed of 5 GiB or less, or
a second Spark, is what would make it comfortable.

**`gemma` is what the appliance shipped with**, kept so a box can go back. Note
its vLLM pin: the `cu130-nightly` tag stopped moving on 2026-04-23 (vLLM 0.19,
Marlin weight-only FP4) and Gemma 4 has never been exercised under v0.29.0 here,
so the profile ships the combination that was measured rather than an untested
one. That is also why it decodes faster than the dense 27B while being a weaker
model: 4B active parameters against 27B.

### Switching

```bash
sudo /opt/suite366/switch-model.sh list            # the four, and which is active
sudo /opt/suite366/switch-model.sh status          # what this box runs right now
sudo /opt/suite366/switch-model.sh qwen27b --dry-run
sudo /opt/suite366/switch-model.sh qwen27b
```

A model id lives in **three** places that have to agree, and the script moves all
three: `llm/.env` (what vLLM serves), `values.yaml` → the ConfigMap the app reads,
and the `AIModel` / `Agent` rows in Postgres that every LLM call actually
resolves. Miss the third and every call 404s while `docker ps` says healthy and
every pod is `Running` — the same silent shape as the API-key drift in
`lib/vllm-db.sh`.

### Transcription

A profile that leaves the memory for it also serves a **speech-to-text model**,
in a third vLLM container (`suite366-vllm-stt`) behind the same proxy: the app's
dictation, voice reports and meeting notes already speak the OpenAI
`/v1/audio/transcriptions` route and only need a model to be named. Today that
is `qwen27b`, `orcasaq` and `gemma` with **Qwen3-ASR-1.7B**: 4.4 GiB of weights, 30 languages detected
automatically, 4.75 % WER on FLEURS French against 6.31 for Whisper-large-v3,
and it takes the vocabulary hint the app sends with every window. Audio longer
than 30 s is split by vLLM at the quietest point of each window, so a 5 min
dictation is ten requests, not one. Measured on the test Spark: weights loaded
in 43 s, about 10 GiB resident in all (the box goes from 86 to 97 GiB used),
35 s of read French transcribed in 2.9 s through the proxy — WAV or webm/opus
alike — and 5 s in 0.5 s.

Two things to know about it. The container runs a **locally built image**
(`suite366/vllm-stt:<base>-r<rev>`, `llm/stt/Dockerfile`): the arm64 vLLM image
ships without `soundfile` and `PyAV` and decodes no audio at all, so one ~100 MB
layer adds them — bump `LLM_STT_IMAGE_REV` in `llm/profiles.sh` whenever the
Dockerfile changes. And the service sits behind a **compose profile**
(`COMPOSE_PROFILES=stt` in `llm/.env`), so `switch-model.sh` can take it down
before the new generative model starts — always, even when the target serves
one too: on unified memory vLLM sizes its KV cache as its share minus whatever
else is resident when it profiles, and Gemma measured 222k tokens of KV with the
transcription engine up during its start against ~300k without — and bring it
back once the new engine is healthy; the nginx route resolves it per request and
simply answers 502 while it is absent. In the app the model is an `AIModel` row with `supportsTranscription`
and the organisation's default; a switch to a profile without one disables the
row and clears the default, so the UI says "no transcription model configured"
instead of failing on a route nothing serves. `LLM_STT_MODEL=` (empty) at
install turns it off for a box that needs the memory elsewhere.

The new engine must report healthy before the chart or the database are touched.
If it does not come up, `.env` is restored, the previous engine is brought back,
and nothing else moved: the box ends the run where it started.

Switching to `flash-next` builds its patched image on the box if it is missing
(~3 min) and lowers `vm.swappiness` to 10; switching away removes that drop-in.
Switching to `orcasaq` builds its image the same way (`llm/exl3/`, ~4 min: it
compiles exllamav3 for the GB10). **A build stops the running engines first**
and the model page says so: compiling next to a resident Flash-Next (117/121 GiB
before the first `nvcc`) drove a Spark into 16 GiB of swap and a load of 74 and
took the app down with it. The previous engine is about to be replaced anyway;
if the build fails it is brought back and nothing else has moved.
The first start on a model whose checkpoint is not on disk downloads it
(~133 GB for Flash-Next, 25 min at 85 MB/s).

## Measured GB10 realities (read before tuning)

**Unified memory is one pool.** `gpu_memory_utilization` is NOT pre-allocated in
VRAM — there is no VRAM on a GB10. vLLM uses it to compute the KV cache size
after weights are loaded, out of a pool shared with the OS, the page cache and
the container runtime. Two consequences bit us:

- The profiler charges the process for whatever the rest of the machine
  allocates while it runs. Raising Flash-Next from 0.70 to 0.73 (+3.6 GiB)
  returned only +0.6 GiB of KV cache, and 0.73 passed one day and failed vLLM's
  start-up free-memory check the next.
- A fraction is the wrong tool for the embedding model. At 0.30 vLLM turned the
  whole share into KV cache (18.75 GiB, 136k tokens, 16 concurrent 8k requests)
  to embed chunks of a few hundred tokens. `--kv-cache-memory-bytes 4GiB` skips
  the profiler entirely: the container drops from ~36 GiB to ~20 GiB, and the
  fraction only has to clear the start-up check. Without that cap Flash-Next did
  not fit at all. This applies to all three profiles and is why `EMBED_GPU_MEM_UTIL`
  is 0.20 and not 0.30.

**Kernels.** On sm_121, vLLM v0.29.0 selects the native W4A4 NVFP4 path
(`FlashInferCutlassNvFp4LinearKernel`), FP8 FlashInfer for the attention
projections and the `FLASHINFER` attention backend. The `cu130-nightly` tag the
appliance used to run is vLLM 0.19, which only knew the Marlin weight-only path:
it dequantised FP4 to FP16 and never touched the FP4 tensor cores. That is the
single biggest reason the two Qwen profiles pin a release rather than a nightly.

**Start-up.** `--load-format fastsafetensors` loads the 27B's weights in 12 s
instead of 114. It is NOT used for Flash-Next: the mmap patch hooks the default
loader, and that model's 9 min 15 of loading cannot be cached. What IS cached
for all three is the JIT state under `$CACHE_DIR` (torch.compile artifacts, the
FlashInfer autotune sweep, Triton kernels): a restart on an unchanged config is
96-106 s instead of 257. Change a flag that alters the compiled graph and the
next start is cold again.

**Concurrency.** `max_num_seqs=2` on every profile. Above that, chunked prefill
collapses generation throughput on the 27B (the bottleneck is the GB10's prefill
compute, not memory), and on Flash-Next more slots only grow the CUDA graphs —
measured, 4 slots cost 3 GiB of KV cache the model does not have.

## Wiring the AI (automatic)

Suite 366 ships `chooseDefaultModel` + offline vLLM support, so the local stack
is **wired automatically** through the chart values:

```yaml
config:
  VLLM_BASE_URL:            http://<HOST_IP>:8000/v1   # nginx proxy
  VLLM_MODEL_HIGH:          nvidia/Qwen3.8-Flash-Next-NVFP4
  VLLM_MODEL_LIGHT:         nvidia/Qwen3.8-Flash-Next-NVFP4
  VLLM_MODEL_VISION:        nvidia/Qwen3.8-Flash-Next-NVFP4
  VLLM_MODEL_EMBEDDING:     Qwen/Qwen3-VL-Embedding-8B
  VLLM_EMBEDDING_DIMENSIONS: "4096"
  VLLM_MAX_CONTEXT_WINDOW:   "131072"
secrets:
  VLLM_API_KEY:             <random, generated by install.sh>
```

When `VLLM_BASE_URL` is set, `chooseDefaultModel(role)` picks the local vLLM
over Anthropic/OpenAI for every role (precedence `vllm → anthropic → openai`).
Embedding and vision skip Anthropic; vision uses `VLLM_MODEL_VISION`
(Qwen3.8-Flash-Next is a native vision-language model; the NVFP4 build keeps
its vision tower in BF16).

The app seeds the model ids into Postgres when an organisation is created
(`AIProvider` + `AIModel` rows) and agents store the id again in `Agent.model`.
Changing `LLM_MODEL` on an installed box therefore also means updating those
rows — the env vars only drive new organisations and the env fallback.

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
| Chat / vision (direct) | `http://<HOST_IP>:8001/v1` | `nvidia/Qwen3.8-Flash-Next-NVFP4` | vLLM key shown |
| Embeddings (direct) | `http://<HOST_IP>:8002/v1` | `Qwen/Qwen3-VL-Embedding-8B` | vLLM key shown |
| Unified (nginx)      | `http://<HOST_IP>:8000/v1` | either of the above | vLLM key shown |

### The five copies of `VLLM_API_KEY`

The key exists five times on an appliance, and only the last one decides whether
an LLM call works:

| # | Copy | Written by | Read by |
|---|---|---|---|
| 1 | `/opt/suite366/llm/.env` | `deploy_vllm` | the vLLM containers, **at start only** |
| 2 | the containers' environment | docker compose | vLLM — this is the copy that **validates** a request |
| 3 | `/opt/suite366/values.yaml` | `deploy_suite` | helm |
| 4 | the chart's Secret -> the app's env | the chart | the app, **at seed time only** |
| 5 | Postgres `"AIProvider".config->>'apiKey'` | the app, at the first organization creation | **every LLM call** |

The app seeds (5) out of (4) once, when the first organization is created, and
never re-reads its environment; its resolver then prefers that row over the
environment fallback. So a key that changes anywhere in 1-4 leaves (5) stale and
**every LLM call returns 401 while `docker ps` says `Up (healthy)`, every pod is
`Running`, and the app's own provider health check says HEALTHY** — it writes
that verdict without making a request. That state ran for four days on a real
box before anyone could name it.

`lib/vllm-db.sh` closes it: it realigns (5) and then proves the result by asking
vLLM **with the key read back out of Postgres**, on install, on `update.sh apply`,
on the daily `update.sh check`, and after `backup.sh restore --in-place` (whose
dump carries the key that was current when it was taken). The install fails when
that key is rejected; it only warns when there is no row yet, or when vLLM has
not answered yet — a model that is still loading is not a bad key.

Rows an admin aimed at *another* vLLM are neither realigned nor blamed: the scope
is the app's own seed (`name = 'vLLM Local'`), a seed with no base URL, or a row
already pointing at this box.

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
lib/vllm-db.sh                        realigns + verifies "AIProvider".config->>'apiKey' in Postgres — the fifth, and only authoritative, copy of VLLM_API_KEY
lib/mdns.sh                           Avahi/mDNS publishing of *.DOMAIN (or *.LOCAL_DOMAIN in proxy mode)
lib/updater.sh                        install update.sh + daily notify-only timer
lib/summary.sh                        final post-install summary
backup.sh                             backup agent (run | test | status | snapshots | prune | restore | install-units); run by suite366-backup.timer
lib/backup.sh                         installs the pinned restic, the repository key, backup.sh and its timer
tools/test-backup.sh                  self-test: stubbed restic + cluster, plus a real restic round trip when one is on PATH
tools/test-update-diffs.sh            self-test: an update is a roll FORWARD; a lagging channel is reported, never offered
tools/test-dual-names.sh              self-test: values.yaml renders one name set, or two, and never a mix
tools/test-local-certs.sh             self-test: the LAN certs name a real issuer, and a re-run never replaces a working certificate
tools/test-vllm-db.sh                 self-test: a key change reaches the database row, a stale row fails the install, a loading model does not
tools/test-llm-profiles.sh            self-test: the four profiles resolve to what was measured, and a switch moves all three copies of the model id
update.sh                             update checker/applier (check | apply | scan-usb | install-units); run by the daily timer + app triggers
tools/build-offline-package.sh        build a SIGNED offline update package for an air-gapped appliance
tools/sign-channel.sh                 pin updater_sha256 + sign channel.json (run on every channel bump)
tools/gen-package-key.sh              generate the Ed25519 keypair that signs packages AND channels
tools/sync-vllm-db-block.sh           copy the shared vllm-db block from lib/ into update.sh and backup.sh (they cannot source lib/)
tools/test-package-verify.sh          self-test: real signatures, real tampering, no hardware
uninstall.sh                          clean uninstaller — reverses install.sh (systemd units, vLLM stack, k3s, DATA_DIR, …)
channel.json                          fleet release manifest (chart_version / app_version / vllm_image / updater_sha256) polled by update.sh
channel.json.sig                      Ed25519 signature over channel.json — required by any appliance holding the public key
values.yaml                           Helm values (@DOMAIN@/@HOST_IP@/etc. tokens substituted at run-time)
switch-model.sh                       switch the generative model on a running box (list | status | <profile> [--dry-run] | converge) — .env, chart values and the database
host-layer.sh                         GENERATED (tools/bundle-host-layer.sh): switch-model.sh + llm/ in one file, pinned in channel.json as host_layer_sha256, laid down by install.sh and update.sh
llm/docker-compose.yml                vllm-llm + vllm-embed + vllm-proxy (host Docker) — profile-agnostic
llm/profiles.sh                       the four models and their measured budgets, and the transcription model each allows; the ONE table install.sh and switch-model.sh share
llm/stt/Dockerfile                    the audio extras the arm64 vLLM image ships without; built on the box as suite366/vllm-stt
tools/bundle-host-layer.sh            regenerates host-layer.sh (deterministic; tools/test-host-layer.sh fails on a stale copy)
llm/serve-llm.sh                      container entrypoint: the vLLM flags each profile needs
llm/tool_chat_template_gemma4.jinja   chat template required by the gemma profile's --tool-call-parser
llm/flash-next/                       the vLLM patch set that makes Qwen3.8-Flash-Next fit on one Spark (built on the box)
llm/exl3/                             the vLLM image that reads EXL3 trellis checkpoints (OrcaSAQ-2-27B): exllamav3 compiled for the GB10 + the orcasaq2 plugin (built on the box)
llm/nginx.conf                        URL-path router unifying both vLLM behind a single endpoint
tls/local-ca-issuer.yaml              local self-signed CA (cert-manager)
dns/avahi-aliases.service             systemd unit publishing mDNS names
```

## Operations

```bash
sudo k3s kubectl -n suite366 get pods          # kubeconfig is 0600 (root only)
sudo /opt/suite366/backup.sh status            # last backup, snapshots, key fingerprint
docker logs -f suite366-vllm-llm               # generative model logs
systemctl status suite366-vllm                 # vLLM stack
systemctl status suite366-avahi-aliases        # mDNS aliases
```

## Backups

The appliance ships with the backup **mechanism** installed and a nightly timer
armed. It does **not** ship with a destination: where a customer's data is
copied is their decision, so `BACKUP_REPO` is empty by default and a run reports
`unconfigured` and exits 0 rather than failing every night until someone reads
the journal.

```bash
sudo /opt/suite366/backup.sh status      # state.json: last run, snapshots, key fingerprint
sudo /opt/suite366/backup.sh run         # now, instead of waiting for 02:40
sudo /opt/suite366/backup.sh snapshots   # what is in the repository
sudo /opt/suite366/backup.sh test        # destination reachable + key correct?
systemctl list-timers suite366-backup.timer
```

### Restoring

`docs/restore.md` is the runbook — read §0 first, it is the part that decides
whether a restore is possible at all. Two entry points:

```bash
# safe: extract somewhere and look at it. Changes nothing on the appliance.
sudo /opt/suite366/backup.sh restore --snapshot latest --target /var/tmp/restore

# destructive: rebuild THIS appliance from a snapshot, in the required order
sudo /opt/suite366/backup.sh restore --in-place --dry-run   # the plan
sudo /opt/suite366/backup.sh restore --in-place             # asks for RESTORE
```

The in-place path takes a `pre-restore` snapshot of the current state before it
touches anything, refuses a snapshot that cannot carry `AUTH_SECRET`, and
refuses a database that already has tables unless you pass `--force`. Its
ordering guarantees are covered by `tools/test-backup.sh`; the live cluster
interactions are **not yet exercised on real hardware**, because doing so means
destroying a running appliance. Prefer `--target` if you have never run it.

Turn it on **from the admin UI** — *Settings → Organisation → Backups* — which
is the intended route: it sets the destination, tests it immediately, and shows
the last run, the snapshots and the key fingerprint without anyone opening a
shell. The page can ask for a destination but can never read the stored
credentials back: `backup.env` is 0600 and owned by root, so an empty secret
field means "keep the one already saved".

Or at install time, or later by editing
`/opt/suite366/backup/backup.env` (0600) and running `backup.sh init`:

```bash
curl -fsSL https://get.suite366.ai/install.sh | sudo env \
  BACKUP_REPO=s3:s3.fr-par.scw.cloud/suite366-backups/spark-01 \
  BACKUP_S3_ACCESS_KEY=… BACKUP_S3_SECRET_KEY=… BACKUP_S3_REGION=fr-par bash
```

Any restic backend works (S3, SFTP, a local path on a USB disk — useful on an
air-gapped site). The agent itself travels with the signed channel: `channel.json`
pins `backup_sha256` beside `updater_sha256`, so an appliance that rolls its
updater forward rolls the backup agent forward with it — and an offline package
carries both the agent and the pinned `restic` binary, which an air-gapped box
has no other way to obtain. Retention defaults to 7 daily / 4 weekly / 6 monthly and is
applied with `restic forget --prune` at the end of every run.

### What is in a snapshot

| Tag | Content | Why |
|---|---|---|
| `postgres` | `pg_dump -Fc` streamed into restic | a *logical* dump, so it restores into a fresh Postgres whose password differs — the normal case after a reinstall |
| `minio` | the MinIO PVC directory, **`.minio.sys` excluded** | objects are whole files; MinIO's own IAM is not, and restoring one install's `.minio.sys` over another's root credentials locks you out of the data you just restored |
| `config` | `/opt/suite366` minus `models/` | `values.yaml`, `llm/.env`, `update.env`, the local CA. The 33+ GiB of model weights re-download |
| `secrets` | `secret-<app>` and the cert-manager CA secret | see below — this is what decides whether a restore works at all |

Not backed up, deliberately: Redis (sessions and queues), the OnlyOffice PVC
(cache), workbench PVCs (per-user scratch, potentially hundreds of GiB).

The database dump is checked on **both** sides of the pipe. A `pg_dump` that
dies mid-stream still hands restic a perfectly storable *truncated* dump — the
worst outcome available, because it looks like a successful backup until the day
someone restores it. Such a run is reported as `partial`, not success.

### The one secret that matters: `AUTH_SECRET`

The app derives its at-rest encryption key from `AUTH_SECRET`
(`serveur/src/lib/encryption.ts`), and the chart **regenerates** any secret it
cannot find. A restore that does not carry `AUTH_SECRET` over therefore produces
a database that starts up perfectly and whose stored provider keys and OAuth
tokens are permanently unreadable — with no error anywhere.

Everything else in that secret (Postgres, MinIO, OnlyOffice JWT, LiveKit) is
infrastructure credentials that regenerate harmlessly, and carrying *those* over
actively conflicts with a fresh install (Postgres bakes its password into the
data directory at init). So: one secret to preserve, the rest to let go.

### Encryption key

`restic` encrypts the repository with a key generated at install, stored
**only** at `/opt/suite366/backup/repo.pass` (0600) and printed **once** while
it is created. Lose it and the snapshots are unreadable — by anyone, including
us. That is the property being bought, and it means the key must leave the
machine by some deliberate route:

- **sold** appliance: printed on the card that ships inside the crate;
- **rented** appliance: escrowed by `suite366-fleet`, with the vault reference
  recorded in the machine's inventory file.

`backup.sh status` and the state file publish only a 12-character fingerprint of
the key, never the key. `uninstall.sh` warns before deleting it, because the
snapshots in the remote repository survive the uninstall and would outlive the
only copy of their key.

### Restore

`backup.sh restore --target <empty dir>` **extracts** a snapshot and changes
nothing on the appliance. The in-place sequence is manual and order-dependent
(patch `AUTH_SECRET` first, then the database, then the objects with MinIO
stopped) and is deliberately not automated yet: it has to be exercised on a real
box before a recovery is allowed to become a second outage.

Verify a restore **positively** — open a document (the objects and the database
agree), make one LLM call (the stored provider key is realigned automatically in
step 6/8, so a 401 there means something else), *and* exercise one `enc:`-prefixed
secret: an SSO sign-in, a bot integration or an agent connector. That last one is
what proves `AUTH_SECRET` came over — `"AIProvider".config` is stored in clear,
so an LLM call never proved anything about it. A box that merely boots proves
nothing about the step above.

### Updates

**What an update carries.** The app image and the chart, the vLLM base image,
`update.sh` and `backup.sh` themselves — and, since the host layer became one
artefact, everything the vLLM stack needs on the **host**: `switch-model.sh`, the
model profiles, the compose, the nginx proxy config, the container entrypoint and
the three image build contexts (`host-layer.sh`, pinned as `host_layer_sha256`).
A box whose bundle differs from the channel's sees "host layer" in the update it
is offered; applying it lays the bundle down, adds every app ↔ host bridge its
`values.yaml` lacks (model page, backups, remote access), rolls the release, and
runs `switch-model.sh converge`: fills `llm/.env` from the profile the box already
runs (a pre-profile box is recognised by its model id — Gemma stays on its pinned
`cu130-nightly` while the base image moves), recreates only the containers whose
definition changed, reloads the proxy, rewrites the systemd units, publishes
`state.json`. Nobody re-runs `install.sh` for a host-side feature any more.

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

The installer therefore writes a **persistent** CDI spec at
`/etc/cdi/nvidia.yaml` during preflight (`nvidia-ctk cdi generate`).

Persistent is not the same as correct, though. The spec pins the device-node
**majors**, and `/dev/nvidia-uvm`'s major is allocated dynamically at each boot
(497, 498, …). A spec written on an earlier boot keeps the old number, and every
GPU container is then handed a device node on the wrong char device. That one is
nasty to diagnose, because it hides where you look first:

- `nvidia-smi` works — on the host **and inside the container**, because NVML
  goes through `/dev/nvidiactl` (major 195, fixed);
- the driver, the kernel modules and `/dev/nvidia*` are all healthy;
- the only symptom is `torch.cuda.init()` raising `CUDA unknown error - this may
  be due to an incorrectly set up environment`, which names neither CDI nor the
  driver — with vLLM crash-looping behind it.

So the spec is refreshed in two places, and both are needed:

- **every installer run** (preflight), which fixes a box you are already working
  on;
- **every start of `suite366-vllm.service`**, via an `ExecStartPre` that runs
  `nvidia-ctk cdi generate` before Compose creates the containers — devices are
  injected at container *creation*, so a later refresh would be too late. It is
  best-effort (`-` prefix): it can never hold the stack down when the spec is
  already good.

NVIDIA ships `nvidia-cdi-refresh.service` for this, but it cannot be relied on
here: it is disabled by default, it writes to `/var/run/cdi/` (leaving the stale
`/etc/cdi/nvidia.yaml` in place beside it), and it is ordered
`After=multi-user.target` — so it runs *after* the LLM stack, and on a box where
`plymouth-quit-wait.service` hangs (DGX OS boots with `quiet splash`) the target
is never reached and the unit never runs at all. Worth knowing beyond CDI: check
`systemctl list-jobs` before trusting anything ordered after that target.

To check a box by hand, compare the live major against the one in the spec:

```bash
grep -i nvidia /proc/devices | grep uvm                     # e.g. 498 nvidia-uvm
grep -A1 'path: /dev/nvidia-uvm' /etc/cdi/nvidia.yaml       # must match
```

If they differ:

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
  add entries to the clients' `/etc/hosts` (`<IP> drive.suite366.local …`), or
  switch to `HOST_MODE=dns` (see *[Custom hostnames and
  TLS](#custom-hostnames-and-tls)*).
- The `.local` TLD is the standard mDNS space (intentional), and mDNS is only
  ever consulted for it. On a routed multi-subnet network, use `HOST_MODE=dns`
  with a real internal domain.
- **Very long context workloads (>200k tokens)**: prefill takes ~10 min on
  GB10 (cf. § GB10 realities). If your traffic exceeds 14% of >200k calls,
  consider RAG / app-side chunking to keep prompts under 100k.

## License

See [LICENSE](LICENSE).
