#!/bin/sh
# =============================================================================
# Suite 366 — Docker installer
#
#   curl -fsSL https://get.devana.ai/366 | sh
#
# Optional environment variables:
#   SUITE366_DIR=/opt/suite366            install directory (default ./suite366)
#   SUITE366_IMAGE=ghcr.io/...:tag        override the image/tag to deploy
#   SUITE366_RAW_BASE=https://...         where to fetch compose/.env templates
#   DEVICE=dgx-spark|ryzen-ai-max         hardware profile (appliance installs;
#                                         ignored for a plain Docker host)
# =============================================================================
set -eu

RAW_BASE="${SUITE366_RAW_BASE:-https://raw.githubusercontent.com/Scriptor-Group/suite366-deploy/main}"
DIR="${SUITE366_DIR:-./suite366}"
IMAGE="${SUITE366_IMAGE:-ghcr.io/scriptor-group/suite-366:latest}"

say()  { printf '\033[36m▸\033[0m %s\n' "$1"; }
warn() { printf '\033[33m! %s\033[0m\n' "$1"; }
err()  { printf '\033[31m✗ %s\033[0m\n' "$1" >&2; exit 1; }

# --- 1. Requirements --------------------------------------------------------
command -v docker >/dev/null 2>&1 || \
  err "Docker is required. Install it: https://docs.docker.com/engine/install/"

if docker compose version >/dev/null 2>&1; then
  COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  COMPOSE="docker-compose"
else
  err "Docker Compose v2 is required (the 'docker compose' plugin)."
fi

[ "${DEVICE:-}" = "" ] || say "Hardware profile: $DEVICE"

# Random base64 secret, stripped of URL-unsafe characters so it can sit in a
# connection string without escaping.
gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '/+=\n'
  else
    docker run --rm "$IMAGE" \
      node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))'
  fi
}

# --- 2. Layout --------------------------------------------------------------
say "Installing into $DIR"
mkdir -p "$DIR"
cd "$DIR"

# --- 3. Fetch compose file --------------------------------------------------
say "Downloading docker-compose.yml"
curl -fsSL "$RAW_BASE/docker-compose.yml" -o docker-compose.yml

# --- 4. Generate .env on first run only -------------------------------------
if [ -f .env ]; then
  say ".env already exists — keeping your configuration"
else
  say "Generating .env with fresh secrets"
  curl -fsSL "$RAW_BASE/.env.example" -o .env

  PG_PWD="$(gen_secret)"
  AUTH="$(openssl rand -base64 32 2>/dev/null || gen_secret)"
  MINIO_SECRET="$(gen_secret)"

  # Portable in-place edit (works with both GNU and BSD/macOS sed).
  sed -i.bak \
    -e "s|^AUTH_SECRET=.*|AUTH_SECRET=${AUTH}|" \
    -e "s|^POSTGRES_PASSWORD=.*|POSTGRES_PASSWORD=${PG_PWD}|" \
    -e "s|^DATABASE_URL=.*|DATABASE_URL=postgresql://suite366:${PG_PWD}@postgres:5432/suite366?schema=public|" \
    -e "s|^MINIO_ACCESS_KEY=.*|MINIO_ACCESS_KEY=suite366|" \
    -e "s|^MINIO_SECRET_KEY=.*|MINIO_SECRET_KEY=${MINIO_SECRET}|" \
    .env
  rm -f .env.bak

  warn "Edit $DIR/.env before going to production:"
  warn "  • set APP_URL / AUTH_URL to your real HTTPS domain"
  warn "  • set LICENSE_PUBLIC_KEY (from Devana) to activate the product"
  warn "  • set OPENAI_API_KEY to enable AI features (optional)"
fi

# --- 5. Pull + start --------------------------------------------------------
say "Pulling image: $IMAGE"
$COMPOSE pull

say "Starting Suite 366"
$COMPOSE up -d

cat <<EOF

  \033[32m✓ Suite 366 is starting.\033[0m

  Open      http://localhost:3000
  Logs      (cd $DIR && $COMPOSE logs -f app)
  Stop      (cd $DIR && $COMPOSE down)

  First boot runs database migrations — give it a minute.
EOF
