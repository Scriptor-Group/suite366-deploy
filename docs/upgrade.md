# Upgrading

Suite 366 images apply database migrations automatically on startup, so an
upgrade is a single `helm upgrade`.

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Optional but recommended: back up first (see docs/configuration.md)
k3s kubectl -n suite366 exec deploy/drive-postgres -- \
  pg_dump -U suite366 suite366 > backup-$(date +%F).sql

helm upgrade drive oci://ghcr.io/scriptor-group/charts/drive \
  --version 0.5.0 -n suite366 -f /opt/suite366/values.yaml

k3s kubectl -n suite366 rollout status deploy/drive-app
```

## Pinning a version

Pin both the **chart** and the **app image** for reproducible deployments:

- Chart: pass `--version <chart-version>` (and/or set `CHART_VERSION` for the
  installer).
- App image: set `image.tag` in `values.yaml`, e.g.

  ```yaml
  image:
    repository: ghcr.io/scriptor-group/suite-366
    tag: v1.5.0
  ```

Upgrading later is bumping `--version` and/or `image.tag`, then `helm upgrade`.

## Rolling back

```bash
helm -n suite366 history drive          # list revisions
helm -n suite366 rollback drive <REV>   # roll back the release
```

> ⚠️ Migrations are forward-only. If a release applied schema changes, rolling
> the release back may not be enough on its own — restore your pre-upgrade
> database backup if you need to fully revert.

## Before upgrading multiple replicas

If you run more than one replica, make sure
`config.NEXT_SERVER_ACTIONS_ENCRYPTION_KEY` is set to a fixed shared value in
`values.yaml` (see [configuration](configuration.md#single-instance-vs-multiple-replicas)).
Otherwise each recreated replica gets a new key and active sessions break.

## Upgrading the vLLM stack (GPU path)

```bash
# Edit the image/model in /opt/suite366/llm/.env, then:
cd /opt/suite366/llm && docker compose pull && docker compose up -d
```
