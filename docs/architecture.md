# Architecture

Suite 366 is a single application container backed by three stateful services.
Everything runs on your host — documents and their extracted content never leave
your infrastructure.

```
                         ┌──────────────────────────────┐
        HTTPS            │            app               │
  user ───────► proxy ──►│  Next.js 15 · Server Actions │
                         │  (auth, UI, API, workers)    │
                         └───┬──────────┬──────────┬─────┘
                             │          │          │
                   ┌─────────▼──┐  ┌────▼────┐  ┌──▼─────────┐
                   │  postgres  │  │  redis  │  │   minio    │
                   │  pgvector  │  │ cache / │  │  files /   │
                   │  DB+vectors│  │ queues  │  │  objects   │
                   └────────────┘  └─────────┘  └────────────┘
```

## Components

- **app** — the Suite 366 image. Serves the UI and API, runs Server Actions, and
  hosts background workers (OCR dispatch, embeddings). On startup it applies
  database migrations automatically, then starts the server.
- **postgres (pgvector)** — primary datastore. pgvector stores the embeddings
  used for semantic search.
- **redis** — caching, background job queues, and pub/sub.
- **minio** — S3-compatible object storage for uploaded files and their
  generated artifacts. Any external S3 endpoint can be used instead.

## Document flow (high level)

1. A file is uploaded and stored in MinIO.
2. The app extracts text/structure (OCR for scans and images).
3. Extracted content is chunked and embedded; vectors are written to pgvector.
4. Search and chat query those vectors to ground answers in your documents.

## Data residency

All four services run locally and talk to each other over the internal Docker
network. The only outbound calls are the ones you opt into — e.g. setting
`OPENAI_API_KEY` sends text to OpenAI for embeddings. Leave it unset to keep
everything on-host (subject to the AI backend you configure).
