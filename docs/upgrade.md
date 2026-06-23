# Upgrading

Suite 366 images apply database migrations automatically on startup, so an
upgrade is usually two commands.

```bash
cd suite366            # your install directory

# Optional but recommended: back up first (see docs/configuration.md)
docker compose exec postgres pg_dump -U suite366 suite366 > backup-$(date +%F).sql

docker compose pull    # fetch the new image
docker compose up -d   # recreate the app; migrations run on boot
docker compose logs -f app
```

## Pinning a version

`docker-compose.yml` defaults to the `:latest` tag. For reproducible
deployments, pin an explicit version via `.env`:

```env
SUITE366_IMAGE=ghcr.io/scriptor-group/suite-366:v1.4.0
```

Then `docker compose up -d`. Upgrading later is just bumping that tag.

## Rolling back

Set `SUITE366_IMAGE` back to the previous tag and `docker compose up -d`.

> ⚠️ Migrations are forward-only. If a release applied schema changes, rolling
> the image back may not be enough on its own — restore your pre-upgrade
> database backup if you need to fully revert.

## Before upgrading multiple replicas

Make sure `NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` is set to a fixed shared value
(see [configuration](configuration.md#multi-replica)). Otherwise each recreated
replica gets a new key and active sessions break.
