# Configuration

All configuration lives in the `.env` file next to `docker-compose.yml`.
Restart the stack after changing it: `docker compose up -d`.

## Variable reference

| Variable                             | Required | Description                                                                 |
| ------------------------------------ | :------: | --------------------------------------------------------------------------- |
| `APP_URL`                            |   yes    | Public URL users reach the app at (e.g. `https://suite366.example.com`).    |
| `AUTH_URL`                           |   yes    | Auth.js base URL — set to the same value as `APP_URL`.                       |
| `APP_PORT`                           |    no    | Host port mapped to the app (default `3000`).                               |
| `AUTH_SECRET`                        |   yes    | Random 32-byte base64 secret. `openssl rand -base64 32`.                     |
| `POSTGRES_DB` / `POSTGRES_USER`      |    no    | Database name / user (defaults `suite366`).                                 |
| `POSTGRES_PASSWORD`                  |   yes    | Database password — **must match** the one inside `DATABASE_URL`.           |
| `DATABASE_URL`                       |   yes    | Full Postgres connection string used by the app.                            |
| `REDIS_HOST`                         |   yes    | Redis hostname (`redis` with the bundled service).                          |
| `MINIO_ENDPOINT`                     |   yes    | Internal MinIO/S3 endpoint (`http://minio:9000`).                           |
| `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` | yes   | Object storage credentials.                                                 |
| `MINIO_BUCKET`                       |   yes    | Bucket for stored files (default `suite-366`, created on first use).        |
| `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` | see [below](#multi-replica) | Server Actions key. Empty = auto-generated per instance.   |
| `LICENSE_PUBLIC_KEY`                 |   yes    | Verification key from Devana — required to run in production.                |
| `OPENAI_API_KEY`                     |    no    | Enables embeddings, semantic search (RAG) and chat.                          |
| `ONLYOFFICE_URL` / `ONLYOFFICE_JWT_SECRET` | no | Only if you enable the OnlyOffice service for document editing.            |

## Putting it behind a domain (HTTPS)

Run a reverse proxy (Caddy, Nginx, Traefik) in front of the `app` service and
terminate TLS there. Then point `APP_URL` and `AUTH_URL` at your HTTPS domain.
Minimal Caddy example:

```caddyfile
suite366.example.com {
    reverse_proxy localhost:3000
}
```

## <a id="multi-replica"></a>Single instance vs. multiple replicas

The Server Actions encryption key protects the arguments bound into server
actions. By default it is **left empty**, and each container generates its own
ephemeral key at startup — perfect for a single instance, with nothing to
manage.

If you run **more than one replica** (horizontal scaling / HA), every replica
**must use the same key**, or users hit `Failed to find Server Action` errors
when their request lands on a different replica. Generate one value and set it
identically everywhere:

```bash
openssl rand -base64 32
```

```env
NEXT_SERVER_ACTIONS_ENCRYPTION_KEY=<the value above>
```

Keep this value stable across upgrades too, so browser sessions loaded before a
deploy keep working afterwards.

## Storage & backups

State lives in three Docker volumes: `pgdata` (database), `miniodata` (files),
`redisdata` (transient — safe to lose). Back up at least the first two:

```bash
# Database
docker compose exec postgres pg_dump -U suite366 suite366 > backup.sql

# Files (MinIO data volume)
docker run --rm -v suite366_miniodata:/data -v "$PWD":/backup alpine \
  tar czf /backup/minio-backup.tgz -C /data .
```

## Optional services

- **OnlyOffice** — in-app editing of Office documents. Uncomment the service in
  `docker-compose.yml` and set the `ONLYOFFICE_*` variables.
- **LiveKit** (meetings) and the **code sandbox** are part of the full Suite 366
  platform but are not bundled in this minimal self-host stack. Contact Devana
  if you need them on-premise.
