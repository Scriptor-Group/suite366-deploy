# Configuration

There are two layers of configuration:

1. **Installer variables** — environment variables read by `install.sh` (domain,
   GPU mode, chart reference, …).
2. **Helm values** — `values.yaml`, applied to the `drive` chart. The installer
   substitutes the `@DOMAIN@` / `@HOST_IP@` tokens and writes the rendered file
   to `/opt/suite366/values.yaml`.

## Installer variables

| Variable                        | Default                                   | Role                                                              |
| ------------------------------- | ----------------------------------------- | ---------------------------------------------------------------- |
| `DOMAIN`                        | `suite366.local`                          | Base domain; hosts are `drive.`, `office.`, `livekit.`, `turn.`  |
| `ADMIN_EMAIL`                   | `admin@<DOMAIN>`                          | Admin email                                                      |
| `WITH_GPU`                      | `auto`                                    | `auto` (deploy vLLM iff a GPU is found), `1` (force), `0` (never) |
| `CHART_REF`                     | `oci://ghcr.io/scriptor-group/charts/drive` | Public OCI Helm chart reference                                |
| `CHART_VERSION`                 | `0.5.0`                                    | Chart version to install                                         |
| `HF_TOKEN`                      | empty                                     | HuggingFace token (GPU path, gated models)                       |
| `LLM_MODEL` / `EMBED_MODEL`     | see `install.sh`                          | Models served by vLLM (GPU path)                                 |
| `VLLM_IMAGE`                    | NGC arm64/Blackwell build                 | vLLM image — must match your GPU arch (see gpu-inference.md)      |
| `ASSUME_YES`                    | `0`                                       | Accept defaults, no prompts                                      |
| `HOST_IP`                       | auto-detected                             | LAN IP the services bind/advertise                               |

The GPU-only tuning variables (`LLM_GPU_MEM_UTIL`, `EMBED_GPU_MEM_UTIL`,
`LLM_MAX_NUM_SEQS`, `LLM_MAX_MODEL_LEN`) are documented in
[`gpu-inference.md`](gpu-inference.md).

## Helm values (`values.yaml`)

The chart generates and persists all secrets by default (`generateSecrets`):
`AUTH_SECRET`, `CRON_SECRET`, `POSTGRES_PASSWORD`, `DATABASE_URL`, MinIO keys,
`ONLYOFFICE_JWT_SECRET`, `LIVEKIT_*`. You normally only touch:

| Key                              | Description                                                            |
| -------------------------------- | --------------------------------------------------------------------- |
| `image.repository` / `image.tag` | App image (default `ghcr.io/scriptor-group/suite-366:latest`).        |
| `config.APP_URL` / `AUTH_URL` / `WS_URL` | Public URLs the app advertises (templated from `@DOMAIN@`).    |
| `config.LICENSE_PUBLIC_KEY`      | Verification key from Devana — **required to run in production**.      |
| `config.LITELLM_BASE_URL`        | Optional single AI endpoint (chat); embeddings are wired in-app.      |
| `config.SMTP_*`                  | Optional outbound e-mail.                                              |
| `ingress.hosts` / `ingress.tls`  | Ingress hostnames and TLS secrets.                                     |
| `postgres` / `redis` / `minio` / `onlyoffice` / `livekit` | Per-service enable + persistence sizes.      |

Apply changes by editing `/opt/suite366/values.yaml` and running:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
helm upgrade drive oci://ghcr.io/scriptor-group/charts/drive \
  --version 0.5.0 -n suite366 -f /opt/suite366/values.yaml
```

## <a id="real-domain"></a>Running on a real public domain

The defaults target a LAN appliance (`*.suite366.local`, mDNS, self-signed CA).
For a real domain reachable from the internet:

1. Set `DOMAIN=your-domain.tld` (and skip the Avahi step — mDNS is for `.local`).
2. Point DNS A/AAAA records for `drive.`, `office.`, `livekit.`, `turn.` at the host.
3. Replace the local CA issuer with a **Let's Encrypt** `ClusterIssuer` and change
   the ingress annotation `cert-manager.io/cluster-issuer` in `values.yaml`
   accordingly. (You can adapt `tls/local-ca-issuer.yaml` into an ACME issuer.)

## Storage & backups

State lives in the `local-path` PVCs of `postgres` (database), `minio` (files)
and `redis` (transient — safe to lose). Back up at least the first two:

```bash
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml

# Database
k3s kubectl -n suite366 exec deploy/drive-postgres -- \
  pg_dump -U suite366 suite366 > backup.sql

# Files: snapshot the MinIO PVC, or use `mc mirror` against the MinIO endpoint.
```

## Single instance vs. multiple replicas

The default is single-replica. To scale horizontally, every replica must share
the same Server Actions encryption key — set `config.NEXT_SERVER_ACTIONS_ENCRYPTION_KEY`
to one fixed value in `values.yaml` and bump `replicas`. Keep that value stable
across upgrades so browser sessions survive a redeploy.
