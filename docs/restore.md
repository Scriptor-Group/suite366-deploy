# Restoring a Suite 366 appliance

Written for the day it is needed, by someone who will be under pressure and may
never have done this before. Read the first section even if you are in a hurry —
it is thirty seconds and it is where the irreversible mistake lives.

---

## 0. The thing that ruins a restore

**Without the repository encryption key, there is no restore.** Not a slow one,
not a partial one — none. restic encrypts the repository with a key that exists
only in two places:

| Appliance | Where the key is |
|---|---|
| Sold to the customer | `/opt/suite366/backup/repo.pass` on the box, and printed on the card that shipped in the crate |
| Rented (fleet) | The same file, plus an escrow entry in the vault — see `suite366-fleet`, `inventory/<machine-id>.yaml` → `backup.key_vault_ref` |

If the box is gone and the card is gone and there is no escrow entry, the
snapshots in S3 are ciphertext forever. Nobody at Scriptor can recover them.
That is a property of the design, not a gap in it.

**The second thing that ruins a restore is `AUTH_SECRET`**, and it is worse
because it fails *quietly*. The app derives its at-rest encryption key from
`AUTH_SECRET` (`serveur/src/lib/encryption.ts`: sha256 → AES-256-GCM). A restore
that loads the database without carrying `AUTH_SECRET` over produces an
appliance that starts perfectly, logs users in perfectly, and in which every
stored provider API key and OAuth token is permanently unreadable. There is no
error message. The only check that catches it is making one LLM call with a
stored key — which is why it is the last step of every procedure below.

---

## 1. What is in a snapshot, and what is not

Each nightly run writes up to five snapshots, tagged `suite366`:

| Tag | Content | Notes |
|---|---|---|
| `postgres` | `pg_dump -Fc` of the whole database | logical, so it restores into a fresh Postgres with a different password |
| `minio` | the MinIO PVC directory | **`.minio.sys` excluded** — see §4 |
| `config` | `/opt/suite366` minus `models/`, `bin/`, the restic cache and `repo.pass` | `values.yaml`, `llm/.env`, `update.env`, the local CA cert |
| `secrets` | `secret-<app>` as YAML | **this is what carries `AUTH_SECRET`** |
| `secrets` | `cert-manager/suite366-local-ca` as YAML | the local CA's *private key* |

Deliberately **not** backed up: Redis (sessions and queues — regenerated), the
OnlyOffice PVC (cache), workbench PVCs (per-user scratch, can be hundreds of
GiB), and `models/` (~33 GiB of public weights, re-downloadable).

Consequence to say out loud to a customer: **a restore loses in-flight sessions
and workbench scratch space.** Documents, users, organisations, chats and
provider configuration all come back.

---

## 2. Which procedure do I want?

```
Is the appliance still running and reachable?
├── No  → the box is dead / being rebuilt          → §5 (rebuild)
└── Yes
    ├── I want to look at the data first           → §3 (extract, changes nothing)
    └── I want this box to become the snapshot     → §4 (in-place)
```

When in doubt, **§3 first**. Extracting costs a few minutes and rules out the
case where the snapshot itself is bad — which you do not want to discover after
dropping the live database.

---

## 3. Extract only (safe, changes nothing)

```bash
sudo /opt/suite366/backup.sh snapshots          # pick one, or use 'latest'
sudo /opt/suite366/backup.sh restore \
     --snapshot latest --target /var/tmp/restore
```

Nothing on the appliance is modified. You now have the dump, the secret YAML and
the objects on disk. Useful checks:

```bash
# Is the dump intact, or was it truncated at backup time?
pg_restore --list /var/tmp/restore/**/postgres.dump | head
# ^ a healthy dump lists hundreds of TOC entries and many "TABLE DATA" lines.

# Which AUTH_SECRET does this snapshot carry?
sed -n 's/^  AUTH_SECRET: //p' /var/tmp/restore/**/app-secret.yaml | base64 -d
```

Delete the directory when you are done — it holds a plaintext copy of the
secrets: `rm -rf /var/tmp/restore`.

---

## 4. In-place restore (destructive, ordered)

> ⚠️ **Status: exercised against stubs and against a real restic repository, but
> not yet against a live appliance** — doing that means destroying a running
> customer box. The ordering guarantees below are covered by
> `tools/test-backup.sh`; the cluster interactions are not. If you have never
> run this, do §3 first and read the plan `--dry-run` prints.

```bash
sudo /opt/suite366/backup.sh restore --in-place --dry-run     # plan only
sudo /opt/suite366/backup.sh restore --in-place               # asks for RESTORE
```

It refuses, rather than proceeding, when:

- the snapshot has no `app-secret.yaml` (→ `AUTH_SECRET` could not be carried,
  so the data would be unreadable);
- the snapshot has no `postgres.dump`, or `pg_restore --list` cannot read it;
- the target database already has tables (this is not a fresh box) — override
  with `--force` only after taking your own copy;
- there is no TTY and no `--yes`.

What it does, in this order, because every other order breaks something:

1. **extract** everything (a bad snapshot stops the operation before anything is
   touched);
2. **snapshot the current state** into the repository, tagged `pre-restore` —
   this is what makes the operation reversible;
3. **scale the app to 0** (a running app writing into a database being reloaded
   produces a mixture of both);
4. **patch `AUTH_SECRET`** — plus `NEXTAUTH_SECRET` / `ENCRYPTION_KEY` when the
   source box had them, because `encryption.ts` still tries those on decrypt —
   **before** any data lands;
5. `pg_restore --clean --if-exists`;
6. **objects**, with MinIO stopped and `.minio.sys` left alone;
7. scale back up, wait for Ready.

Not restored on purpose, and why:

| Not restored | Reason |
|---|---|
| `POSTGRES_PASSWORD`, `DATABASE_URL` | the fresh install generated its own and the dump is logical — carrying the old ones over breaks a working stack |
| `MINIO_*` credentials | same, and `.minio.sys` on disk already matches the fresh ones |
| `values.yaml` | a rebuilt box may legitimately have different hostnames (`HOST_MODE`, TLS). Extracted for reference; copy back by hand if you want it |
| the local CA | restoring it keeps every already-trusted client working, but conflicts with certificates the fresh install has already issued. Deliberate choice — see §6 |

---

## 5. Rebuilding on new hardware

1. Install normally (`install.sh`). Let it generate its own secrets — you are
   going to overwrite exactly one of them.
2. Put the **old** repository key in place, or the repository cannot be opened:
   ```bash
   sudo install -m 0600 /dev/stdin /opt/suite366/backup/repo.pass <<< 'THE-OLD-KEY'
   ```
3. Point the new box at the same repository — same `BACKUP_REPO`, same
   credentials — in `/opt/suite366/backup/backup.env`, then:
   ```bash
   sudo /opt/suite366/backup.sh test        # proves the key and the destination
   sudo /opt/suite366/backup.sh restore --in-place
   ```
4. Verify as in §7.

⚠️ Until step 3 succeeds, **do not let the new box run a backup**: a fresh
install generates a *new* repository key, and initialising a second repository
under the same prefix with a different key is how a restore stops being
possible. `backup.sh test` failing with "wrong credentials, wrong key, or
unreachable" is the signal to stop and check the key, not to reinitialise.

---

## 6. The local CA (optional, deliberate)

If you restore `local-ca-secret.yaml` into `cert-manager`, every workstation that
already trusts `Suite 366 Local CA` keeps working after the rebuild — no
re-trusting by hand across the customer's office.

```bash
sudo k3s kubectl -n cert-manager delete secret suite366-local-ca
sudo k3s kubectl apply -f /var/tmp/restore/**/local-ca-secret.yaml
sudo k3s kubectl -n suite366 delete secret drive-tls drive-onlyoffice-tls \
     drive-livekit-tls drive-turn-tls        # forces reissue under the old CA
```

Do it **before** telling users the box is back, and only if the rebuild kept the
same hostnames — a certificate under the old CA for a new hostname helps nobody.

---

## 7. Verification — positive, not "it boots"

A restored appliance that boots, serves a login page and accepts a password
proves nothing about the part that fails silently. Do all three:

- [ ] **Open an existing document.** Proves the objects and the database agree
      (a database restored without its objects gives a file list and broken
      previews).
- [ ] **Make one LLM call that uses a STORED provider key** (not a key you just
      typed in). This is the *only* check that proves `AUTH_SECRET` was carried
      over. If it fails with a decryption or authentication error, stop: the
      secret is wrong, and the way back is the `pre-restore` snapshot.
- [ ] **Run a backup by hand** — `sudo /opt/suite366/backup.sh run` — and confirm
      it reports `success`. A restored box that cannot back itself up is one
      incident away from the same conversation.

---

## 8. Going back

The in-place restore stores what was there before, tagged `pre-restore`:

```bash
sudo /opt/suite366/backup.sh snapshots | grep pre-restore
sudo /opt/suite366/backup.sh restore --snapshot <id> --target /var/tmp/back
```

then reverse §4 by hand: patch the secret from
`pre-restore-app-secret.yaml`, `pg_restore` from `pre-restore-postgres.dump`.

---

## 9. Failure modes and what they look like

| Symptom | Cause | Action |
|---|---|---|
| `wrong credentials, wrong key, or unreachable` | usually the wrong `repo.pass` | check the key before touching the destination — a second `init` under the same prefix makes things worse |
| App up, documents listed, previews broken | objects not restored, or restored into the wrong PVC path | re-run §4, check the MinIO PVC resolved |
| App up, provider keys "invalid" | `AUTH_SECRET` not carried over | restore the secret from the snapshot and restart the app; the data is fine, the key is wrong |
| Login works, then immediate logout | `AUTH_URL`/`APP_URL` do not match the hostname the browser used | fix `values.yaml`, not the backup |
| `restic` locks the repository | a run was killed | `restic unlock` with the same env, then retry |
| Nightly job reports `partial` | one component failed — read `error` in `state.json` | a partial run is **not** a backup: fix it before relying on it |
