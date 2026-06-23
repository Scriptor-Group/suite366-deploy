<div align="center">

# Suite 366 (Self-Hosting)

**IA-native document management, on your own infrastructure.**

Run the official Suite 366 container on any compatible machine with Docker. A laptop, a
server, or a sovereign AI appliance (NVIDIA DGX Spark, AMD Ryzen AI Max).

</div>

---

## Quick start

One command. Requires [Docker](https://docs.docker.com/engine/install/) with the
Compose v2 plugin.

```bash
curl -fsSL https://get.devana.ai/366 | sh
```

This downloads `docker-compose.yml`, generates fresh secrets into a local
`.env`, pulls the image, and starts the stack. When it finishes, open
**http://localhost:3000**.

> Prefer to see what runs before running it? Use the [manual setup](#manual-setup)
> below — same result, every step explicit.

---

## What gets deployed

| Service    | Image                              | Role                                   |
| ---------- | ---------------------------------- | -------------------------------------- |
| `app`      | `ghcr.io/scriptor-group/suite-366` | Suite 366 (Next.js, Server Actions)    |
| `postgres` | `pgvector/pgvector:pg16`           | Database + vector search (pgvector)    |
| `redis`    | `redis:7`                          | Cache, queues, pub/sub                 |
| `minio`    | `minio/minio`                      | S3-compatible object storage for files |

Everything runs locally; your documents never leave the host. See
[`docs/architecture.md`](docs/architecture.md) for the data flow.

---

## Requirements

- **Docker Engine 24+** with the **Compose v2** plugin (`docker compose version`)
- **4 GB RAM** minimum (8 GB+ recommended — OCR and embeddings are memory-hungry)
- **10 GB+ disk** for the image, database, and stored files
- A **license key** from Devana to unlock the product — see [Licensing](#licensing)

---

## Manual setup

```bash
# 1. Get the deployment files
git clone https://github.com/Scriptor-Group/suite366-deploy.git
cd suite366-deploy

# 2. Create your configuration
cp .env.example .env
#    → edit .env: set strong secrets, your domain, LICENSE_PUBLIC_KEY, OPENAI_API_KEY

# 3. Launch
docker compose pull
docker compose up -d

# 4. Follow the boot (migrations run automatically on first start)
docker compose logs -f app
```

Full variable reference: [`docs/configuration.md`](docs/configuration.md).

---

## Common operations

```bash
docker compose logs -f app        # tail application logs
docker compose ps                 # service status
docker compose down               # stop (data is kept in volumes)
docker compose down -v            # stop AND delete all data (irreversible)
```

Upgrading to a new release: [`docs/upgrade.md`](docs/upgrade.md).

---

## On-host GPU inference (optional)

On an NVIDIA GPU appliance (DGX Spark / GB10), run the LLM **on the machine
itself** — no external API. The `docker-compose.gpu.yml` overlay adds vLLM
serving **Gemma 4 26B-A4B (NVFP4)** for chat/vision and **Qwen3-VL 8B** for
embeddings, mirroring the Devana Spark configuration.

```bash
echo "HF_TOKEN=hf_xxx" >> .env
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up -d
```

Requires an NVFP4-capable GPU (Blackwell / GB10) and the NVIDIA Container
Toolkit. Full guide: [`docs/gpu-inference.md`](docs/gpu-inference.md).

---

## Single instance vs. multiple replicas

The default deployment is **single-instance** and works with zero extra config:
the container generates an ephemeral Server Actions encryption key at startup.

To run **multiple replicas** behind a load balancer, all replicas must share the
same key — set `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` to one value across them.
Details in [`docs/configuration.md`](docs/configuration.md#multi-replica).

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
Devana) and enter your key in the app. To obtain one:
**https://366.devana.ai** · **[contact](https://devana.ai/contact?interest=366)**.

---

## Links

- Product & pricing — https://366.devana.ai
- Deployment options (Cloud / Box / self-host) — https://devana.ai/deploy
- Support — https://devana.ai/contact?interest=366
