# shellcheck shell=bash
# =============================================================================
# lib/backup.sh — install the backup layer: a pinned restic, the repository
# encryption key, backup.sh, and its nightly timer.
#
# The mechanism is installed on EVERY appliance; the destination is not. A
# customer who has not chosen one yet gets an armed-but-idle timer that reports
# "unconfigured" instead of a nightly failure — and turning it on later is one
# file plus one command, no reinstall.
# =============================================================================

setup_backup() {
  if [[ "$SKIP_BACKUP" == "1" ]]; then
    warn "Backup layer not installed (SKIP_BACKUP=1)."
    return 0
  fi
  log "Backup (restic $RESTIC_VERSION)"

  mkdir -p "$BACKUP_DIR"
  # root:1001 0770 — lot C mounts this into drive-app so the UI can read
  # state.json; k8s does not fsGroup-chown a hostPath, so the gid is set here.
  chown root:1001 "$BACKUP_DIR" 2>/dev/null || true
  chmod 0770 "$BACKUP_DIR"

  install_restic || { warn "backup layer incomplete — restic is missing."; return 0; }
  provision_backup_key
  write_backup_env

  fetch "backup.sh" > "$DATA_DIR/backup.sh"
  chmod 0700 "$DATA_DIR/backup.sh"

  # shellcheck disable=SC2097,SC2098  # DATA_DIR is already set; the prefix only re-exports it into the child
  DATA_DIR="$DATA_DIR" BACKUP_DIR="$BACKUP_DIR" \
    "$DATA_DIR/backup.sh" install-units \
    || warn "could not arm the backup timer."

  if [[ -n "$BACKUP_REPO" ]]; then
    # Exercise the real path NOW rather than discovering at 02:40 that the
    # bucket name has a typo: this initialises the repository and takes a first
    # (nearly empty) backup, which touches pg_dump, PVC discovery, the secrets
    # and the S3 write in one go. Non-fatal — a wrong credential must not abort
    # an otherwise complete appliance install, but it must be loud.
    info "Taking a first backup to validate the destination…"
    # shellcheck disable=SC2097,SC2098  # as above
    if DATA_DIR="$DATA_DIR" "$DATA_DIR/backup.sh" run; then
      info "First backup succeeded."
    else
      warn "FIRST BACKUP FAILED — the appliance is installed but NOT backed up."
      warn "  Fix $BACKUP_DIR/backup.env, then: sudo $DATA_DIR/backup.sh run"
    fi
  else
    # shellcheck disable=SC2097,SC2098  # as above
    DATA_DIR="$DATA_DIR" "$DATA_DIR/backup.sh" run >/dev/null 2>&1 || true
    info "No destination set — timer armed and idle."
    info "  Configure: $BACKUP_DIR/backup.env, then sudo $DATA_DIR/backup.sh init"
  fi
}

# Pinned version, verified checksum, unpacked next to the other appliance
# binaries. Idempotent: an already-correct binary is left alone, which is what
# makes a re-run offline-safe.
install_restic() {
  if [[ -x "$RESTIC_BIN" ]] && "$RESTIC_BIN" version 2>/dev/null | grep -q "restic $RESTIC_VERSION"; then
    info "restic $RESTIC_VERSION already installed."
    return 0
  fi
  local arch sha
  case "$(uname -m)" in
    aarch64) arch=arm64; sha="$RESTIC_SHA256_ARM64" ;;
    x86_64)  arch=amd64; sha="$RESTIC_SHA256_AMD64" ;;
    *) warn "no pinned restic for $(uname -m) — install one at $RESTIC_BIN by hand."; return 1 ;;
  esac
  have bunzip2 || {
    apt-get install -y bzip2 >/dev/null 2>&1 || {
      warn "bzip2 missing and could not be installed — cannot unpack restic."; return 1; }
  }
  local url="$RESTIC_URL_BASE/v$RESTIC_VERSION/restic_${RESTIC_VERSION}_linux_${arch}.bz2"
  local tmp; tmp="$(mktemp)"
  info "Fetching restic $RESTIC_VERSION ($arch)…"
  if ! curl -fsSL -m 120 "$url" -o "$tmp"; then
    rm -f "$tmp"
    warn "could not download restic from $url (offline?)."
    warn "  The offline update package ships it; or drop a binary at $RESTIC_BIN."
    return 1
  fi
  local got; got="$(sha256sum "$tmp" | awk '{print $1}')"
  if [[ "$got" != "$sha" ]]; then
    rm -f "$tmp"
    # Fail closed: this binary runs as root, nightly, with credentials.
    warn "REFUSING restic — checksum mismatch."
    warn "  expected $sha"
    warn "  got      $got"
    return 1
  fi
  mkdir -p "$(dirname "$RESTIC_BIN")"; chmod 0700 "$(dirname "$RESTIC_BIN")"
  bunzip2 -c "$tmp" > "$RESTIC_BIN" || { rm -f "$tmp"; warn "could not unpack restic."; return 1; }
  rm -f "$tmp"
  chmod 0700 "$RESTIC_BIN"
  "$RESTIC_BIN" version >/dev/null 2>&1 || { warn "the restic binary does not run on this host."; return 1; }
  info "restic installed: $RESTIC_BIN ($("$RESTIC_BIN" version 2>/dev/null | head -1))"
}

# Generate the repository key, or keep the one a previous run created. Reusing
# it is load-bearing: a new key on a re-install makes every existing snapshot
# in the destination unreadable.
provision_backup_key() {
  local pass_file="$BACKUP_DIR/repo.pass"
  if [[ -s "$pass_file" ]]; then
    info "Repository key already present (fingerprint $(sha256sum "$pass_file" | cut -c1-12))."
    BACKUP_KEY_IS_NEW=0
    return 0
  fi
  if [[ -z "$BACKUP_PASSWORD" ]]; then
    BACKUP_PASSWORD="$(openssl rand -base64 32 2>/dev/null || head -c 32 /dev/urandom | base64)"
  fi
  ( umask 077; printf '%s\n' "$BACKUP_PASSWORD" > "$pass_file" )
  chmod 0600 "$pass_file"
  BACKUP_KEY_IS_NEW=1

  # Shown ONCE, at the moment it is created, in the same spirit as the LUKS
  # recovery key in suite366-fleet: an operator who scrolls past it has to be
  # told, not left to find out during a restore.
  cat <<EOF

$(printf "${c_y}────────────────────────────────────────────────────────────────────${c_0}")
$(printf "${c_b} BACKUP ENCRYPTION KEY — shown once, stored only on this machine${c_0}")
$(printf "${c_y}────────────────────────────────────────────────────────────────────${c_0}")

    $BACKUP_PASSWORD

 Without this key the backups CANNOT be read. Not by us, not by anyone.
 It lives at $pass_file (0600, root-only) and nowhere else.

   • sold appliance  : print it on the card that ships inside the crate
   • rented appliance: suite366-fleet escrows it — record the vault reference
                       in the machine's inventory file

$(printf "${c_y}────────────────────────────────────────────────────────────────────${c_0}")
EOF
  if [[ "$ASSUME_YES" == "1" ]] || ! tty_usable; then
    warn "ASSUME_YES / no TTY — the key above was NOT confirmed as stored."
    warn "  Capture it from this output before the terminal scrolls away."
  else
    local ack=""
    read -r -p " Type STORED once the key is safe: " ack </dev/tty || true
    [[ "$ack" == "STORED" ]] || warn "Key not confirmed as stored — do it now; it is not shown again."
  fi
}

write_backup_env() {
  # 0600: carries the destination's S3 credentials. Not merged into update.env
  # on purpose — that file is non-secret config an operator edits freely, and
  # keeping the two apart keeps the blast radius of a stray `cat` small.
  ( umask 077
    cat > "$BACKUP_DIR/backup.env" <<EOF
# Suite 366 backup destination + retention. Written by install.sh; edit by hand
# (or, from lot C, from the app UI). 0600 — carries credentials.
#
# Any restic backend works; S3 is the intended one:
#   BACKUP_REPO=s3:s3.fr-par.scw.cloud/<bucket>/<machine-id>
# Leave BACKUP_REPO empty to keep the timer armed but idle.
BACKUP_REPO=$BACKUP_REPO
BACKUP_S3_ACCESS_KEY=$BACKUP_S3_ACCESS_KEY
BACKUP_S3_SECRET_KEY=$BACKUP_S3_SECRET_KEY
BACKUP_S3_REGION=$BACKUP_S3_REGION
BACKUP_KEEP_DAILY=$BACKUP_KEEP_DAILY
BACKUP_KEEP_WEEKLY=$BACKUP_KEEP_WEEKLY
BACKUP_KEEP_MONTHLY=$BACKUP_KEEP_MONTHLY
BACKUP_SCHEDULE=$BACKUP_SCHEDULE
NAMESPACE=$NAMESPACE
KUBECONFIG_PATH=$KUBECONFIG_PATH
RESTIC_BIN=$RESTIC_BIN
EOF
  )
  chmod 0600 "$BACKUP_DIR/backup.env"
}
