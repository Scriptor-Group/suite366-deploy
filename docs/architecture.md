# Architecture

Suite 366 runs as a set of workloads on a **single-node k3s** cluster, deployed
through the `drive` Helm chart. Everything runs on your host — documents and
their extracted content never leave your infrastructure.

```
                              k3s (single node)
   ┌──────────────────────────────────────────────────────────────────┐
   │  Traefik ingress  ──►  drive-app (Next.js 15 · Server Actions)     │
   │   (TLS via local CA)        │        │         │         │         │
   │                       ┌─────▼──┐ ┌───▼───┐ ┌───▼───┐ ┌───▼──────┐  │
   │                       │postgres│ │ redis │ │ minio │ │onlyoffice│  │
   │                       │pgvector│ │cache /│ │files /│ │  (docs)  │  │
   │                       │DB+vec. │ │queues │ │objects│ └──────────┘  │
   │                       └────────┘ └───────┘ └───────┘               │
   │                       ┌──────────────┐                             │
   │                       │ livekit/TURN │  (real-time, hostNetwork)   │
   │                       └──────────────┘                             │
   └───────────────────────────────┬──────────────────────────────────┘
                                    │  (optional, host Docker — GPU)
                          ┌─────────▼──────────┐   ┌────────────────────┐
                          │ vLLM generative    │   │ vLLM embeddings    │
                          │ :8001  (chat/vision)│   │ :8002  (RAG)       │
                          └────────────────────┘   └────────────────────┘
```

## Components (in-cluster)

- **drive-app** — the Suite 366 image (`ghcr.io/scriptor-group/suite-366`). Serves
  the UI and API, runs Server Actions and background workers (OCR dispatch,
  embeddings). Applies database migrations automatically on first deploy.
- **postgres (pgvector)** — primary datastore; pgvector stores the embeddings
  used for semantic search.
- **redis** — caching, background job queues, pub/sub.
- **minio** — S3-compatible object storage for uploaded files and artifacts.
- **onlyoffice** — collaborative editing of Office documents.
- **livekit + TURN** — real-time audio/video (meetings). Uses `hostNetwork` for
  media UDP on a single node.

Storage is provided by the k3s `local-path` provisioner (one PVC per stateful
service). Ingress is Traefik; TLS certificates are issued by cert-manager from a
self-signed local CA (`suite366-local-ca`).

## On-host AI (optional, outside the cluster)

When a GPU is present, two **vLLM** instances run as host Docker services (not in
k3s): a generative model on `:8001` and an embedding model on `:8002`, each
exposing an OpenAI-compatible API. They are wired into Suite 366 **manually** as
two `CUSTOM` providers — see [`gpu-inference.md`](gpu-inference.md). Without a
GPU, configure an external provider (e.g. OpenAI) in the app instead.

## Document flow (high level)

1. A file is uploaded and stored in MinIO.
2. The app extracts text/structure (OCR for scans and images).
3. Extracted content is chunked and embedded; vectors are written to pgvector.
4. Search and chat query those vectors to ground answers in your documents.

## Data residency

All in-cluster services talk to each other over the cluster network. The only
outbound calls are the ones you opt into — e.g. configuring an external AI
provider sends text to that provider. Keep AI on-host (vLLM) to keep everything
on the machine.
