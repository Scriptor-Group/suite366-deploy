# shellcheck shell=bash
# =============================================================================
# lib/updater.sh — installs update.sh + a daily systemd timer that polls the
# channel manifest and NOTIFIES on a new release (never auto-applies).
# =============================================================================

# --- 5b. Update checker (daily systemd timer, notify-only) ------------------
# Installs update.sh + a daily timer that polls the channel manifest and
# NOTIFIES when a newer chart/vLLM image is published (it never auto-applies —
# `update.sh apply` is the manual trigger). The manifest lives in the repo, so
# rolling the fleet forward is a single commit on your side.
setup_update_timer() {
  log "Update checker (daily timer, notify-only)"
  fetch "update.sh" > "$DATA_DIR/update.sh"
  chmod 0700 "$DATA_DIR/update.sh"

  # Config consumed by update.sh both on manual runs (sourced) and via the
  # systemd unit (EnvironmentFile). 0600 — it just carries non-secret config,
  # but lives in the root-only $DATA_DIR anyway.
  ( umask 077
    cat > "$DATA_DIR/update.env" <<EOF
MANIFEST_URL=$MANIFEST_URL
CHART_REF=$CHART_REF
NAMESPACE=$NAMESPACE
RELEASE=$RELEASE
DATA_DIR=$DATA_DIR
KUBECONFIG_PATH=$KUBECONFIG_PATH
UPDATE_WEBHOOK=$UPDATE_WEBHOOK
EOF
  )

  # Units generated inline (not fetched) so the $DATA_DIR path is baked in,
  # matching how suite366-vllm.service is created.
  cat > /etc/systemd/system/suite366-update.service <<EOF
[Unit]
Description=Suite 366 — update check (notify-only)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=$DATA_DIR/update.env
ExecStart=$DATA_DIR/update.sh check
EOF

  cat > /etc/systemd/system/suite366-update.timer <<EOF
[Unit]
Description=Suite 366 — daily update check

[Timer]
# Once a day, with up to 1h of jitter so a fleet doesn't hit the manifest in
# lockstep. Persistent: runs on next boot if a scheduled tick was missed.
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now suite366-update.timer
  info "Timer armed. Check now: sudo $DATA_DIR/update.sh check ; apply: … apply"
}
