<div align="center">

# Suite 366 (Self-Hosting)

**AI-native document management, on your own infrastructure.**

Deploy the full Suite 366 — app, database, storage, collaborative editing and
real-time — on a **single-node Kubernetes (k3s)** cluster. One command, on a
server, a workstation, or a sovereign AI appliance (NVIDIA DGX Spark).

</div>

---

## Quick start

One command. It installs **k3s**, then the full stack via the public Helm chart.
Run it on a fresh Linux host (Ubuntu 22.04+ recommended) with outbound internet.

```bash
curl -fsSL https://raw.githubusercontent.com/Scriptor-Group/suite366-deploy/main/install.sh | sudo bash
```

When it finishes you get HTTPS URLs on a local domain (resolved over mDNS):
**https://drive.suite366.local**.

> Prefer to read before you run? Use the [manual setup](#manual-setup) below —
> same result, every step explicit.

---

## What gets deployed

| Layer                     | Detail                                                                              |
| ------------------------- | ----------------------------------------------------------------------------------- |
| **k3s** (single node)     | Traefik (ingress) + local-path (storage) + CoreDNS                                  |
| **Suite 366** (`drive`)   | drive-app + Postgres (pgvector) + Redis + MinIO + OnlyOffice + LiveKit/TURN, in-cluster |
| **TLS**                   | self-signed local CA (cert-manager), automatic `*.suite366.local` certificates      |
| **DNS**                   | mDNS/Avahi: `*.suite366.local` resolved on the LAN with no client config            |
| **AI** (optional, GPU)    | vLLM ×2 on the host GPU — generative + embeddings — auto-enabled when a GPU is found |

The app image is the public `ghcr.io/scriptor-group/suite-366`; the Helm chart is
pulled from `oci://ghcr.io/scriptor-group/charts/drive`. Everything runs on your
host — your documents never leave it. See [`docs/architecture.md`](docs/architecture.md).

---

## Requirements

- A **Linux host** (Ubuntu 22.04+ recommended), `amd64` or `arm64`, run as **root**.
- **Outbound internet** to pull k3s, Helm, cert-manager and the container images.
- **~80 GB disk** (≈200 GB if you enable on-host GPU inference — models are large).
- **Docker** on the host **only** if you enable the GPU/vLLM path.
- A **license key** from Devana to unlock the product — see [Licensing](#licensing).

No external database, registry credentials or object store needed — the chart
brings its own, in-cluster.

---

## Manual setup

```bash
# 1. Get the deployment files
git clone https://github.com/Scriptor-Group/suite366-deploy.git
cd suite366-deploy

# 2. Review/adjust the Helm values and the installer variables
#    → values.yaml (domain, ingress, storage sizes)
#    → install.sh header (DOMAIN, WITH_GPU, chart ref, …)

# 3. Run the installer from the cloned directory (reads the local files)
sudo ./install.sh
```

The installer is **idempotent** and can be re-run. It is also fully
non-interactive via environment variables — e.g.:

```bash
sudo DOMAIN=suite366.local WITH_GPU=auto ASSUME_YES=1 ./install.sh
```

Full variable reference: [`docs/configuration.md`](docs/configuration.md).

---

## Common operations

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

k3s kubectl -n suite366 get pods           # service status
k3s kubectl -n suite366 logs -f deploy/drive-app   # tail application logs
helm -n suite366 list                      # release status
```

Upgrading to a new release: [`docs/upgrade.md`](docs/upgrade.md).

---

## On-host GPU inference (optional)

When an NVIDIA GPU is present, the installer also runs the LLM **on the machine
itself** — no external API. It deploys **vLLM ×2** as host Docker services
(generative on `:8001`, embeddings on `:8002`) and you wire them into Suite 366
as two `CUSTOM` providers.

It is auto-enabled when a GPU is detected. Control it with `WITH_GPU`:

```bash
sudo WITH_GPU=1 ./install.sh    # force the GPU path (fail if no GPU)
sudo WITH_GPU=0 ./install.sh    # never deploy vLLM (use an external provider)
```

The default `VLLM_IMAGE` targets the **DGX Spark** (arm64 / Blackwell GB10). On a
discrete x86 GPU, override it (e.g. `VLLM_IMAGE=vllm/vllm-openai:latest`). Full
guide: [`docs/gpu-inference.md`](docs/gpu-inference.md).

---

## Domain & TLS

The default is a **LAN-appliance** setup: the local domain `*.suite366.local` is
published over mDNS and certificates are issued by a self-signed local CA. Import
`/opt/suite366/suite366-local-ca.crt` on each client to remove the browser
warning.

To run on a **real public domain** instead, set `DOMAIN` to your domain, point
DNS at the host, and swap the cert-manager issuer for Let's Encrypt — see
[`docs/configuration.md`](docs/configuration.md#real-domain).

---

## Licensing

This image is distributed under the **Suite 366 Image License** (see
[`LICENSE`](LICENSE)) — a _source-available_ license, **not** open source.

In short:

- ✅ You may **use, host, and offer it commercially**, as received (verbatim).
- ❌ You may **not modify** the software or redistribute modified versions.
- ❌ The license key system may not be removed or circumvented.
- ❌ Certain entities are excluded — read the `LICENSE`.

The product is gated by a **license key**: install runs out of the box, then you
activate features with a key from Devana. Set `LICENSE_PUBLIC_KEY` (provided by
Devana) in the Helm values and enter your key in the app. To obtain one:
**https://www.suite366.ai** · **[contact](https://devana.ai/contact?interest=366)**.

---

## Links

- Product & pricing — https://www.suite366.ai
- Deployment options (Cloud / Box / self-host) — https://devana.ai/deploy
- Support — https://devana.ai/contact?interest=366
