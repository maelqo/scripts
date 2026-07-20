#!/usr/bin/env bash
# Pulls the pre-built images and brings them up via Docker Compose. 
# Does NOT set up a reverse proxy or TLS, put
# one in front yourself or use
# deploy-caddy.sh / Coolify instead if you don't have one already.
#
# Usage (env vars):
#   GEMINI_API_KEY=... AIFLOW_ADMIN_EMAIL=owner@client.com \
#     curl -fsSL https://raw.githubusercontent.com/maelqo/scripts/main/aiflow/deploy-compose.sh | bash
#
# Usage (flags -- note the "bash -s --", plain flags after "| bash" are
# silently swallowed since bash reads the script itself from stdin):
#   curl -fsSL https://raw.githubusercontent.com/maelqo/scripts/main/aiflow/deploy-compose.sh \
#     | bash -s -- --domain client.com --gemini-api-key ... --admin-email owner@client.com
set -euo pipefail
trap 'err "failed at line $LINENO (exit $?)"' ERR

# This same file lives in two places, unchanged: here (scripts/, companion
# files one directory up at this repo's root) and mirrored verbatim to the
# public maelqo/scripts repo (aiflow/, companion files alongside it under
# aiflow/config/), synced by .github/workflows/sync-scripts.yml. The
# mirror exists because AiFlow itself is private, so raw.githubusercontent.com
# can't serve a client anything from it without per-client auth, see
# docs/DEPLOYMENTS.md §4. fetch_file() below tries both layouts so this
# one file works correctly in either home with no per-copy editing.
REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/maelqo/scripts}"
REPO_REF="main"
DIR="./aiflow"
ASSUME_YES=0
FORCE=0
INSTALL_DOCKER=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: deploy-compose.sh [options]

Deploys AiFlow's pre-built images via Docker Compose.
No reverse proxy/TLS is set up by this script.

Required (flag or env var):
  --gemini-api-key KEY       GEMINI_API_KEY
  --admin-email EMAIL        AIFLOW_ADMIN_EMAIL
  --domain ROOT              becomes PUBLIC_BASE_URL=https://api.ROOT
                             (or the raw escape hatch: --public-base-url / PUBLIC_BASE_URL)

  Note: this only sets the *backend's* public URL. This script sets up no
  reverse proxy, so the admin dashboard's hostname isn't handled here at
  all, point whatever proxy or PaaS you're using at it separately.

Optional:
  --admin-password PASS      AIFLOW_ADMIN_PASSWORD   (auto-generated if omitted)
  --secret-key KEY           SECRET_KEY              (auto-generated if omitted)
  --twilio-account-sid ...   TWILIO_ACCOUNT_SID
  --twilio-auth-token ...    TWILIO_AUTH_TOKEN
  --twilio-api-key-sid ...   TWILIO_API_KEY_SID
  --twilio-api-key-secret ...TWILIO_API_KEY_SECRET
  --ghcr-username USER       GHCR_USERNAME     (AiFlow's own GHCR account, for private
                                                images; not the client's, see docs/DEPLOYMENTS.md §1.1)
  --ghcr-token TOKEN         GHCR_TOKEN        (the read-only PAT issued for this client)
  --version TAG              AIFLOW_VERSION    (default: 1, tracks all 1.x releases;
                                                use "latest" or an exact "1.4.2" to opt out of that)
  --install-docker           Install Docker via get.docker.com if missing
  --dir PATH                 Deployment directory (default: ./aiflow)
  --repo-ref REF             Git ref to fetch companion files from (default: main)
  --force                    Overwrite an existing .env instead of leaving it alone
  -y, --yes                  Assume yes on confirmations
  -h, --help                 Show this help
EOF
}

GEMINI_API_KEY="${GEMINI_API_KEY:-}"
ADMIN_EMAIL="${AIFLOW_ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${AIFLOW_ADMIN_PASSWORD:-}"
DOMAIN=""
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"
SECRET_KEY="${SECRET_KEY:-}"
TWILIO_ACCOUNT_SID="${TWILIO_ACCOUNT_SID:-}"
TWILIO_AUTH_TOKEN="${TWILIO_AUTH_TOKEN:-}"
TWILIO_API_KEY_SID="${TWILIO_API_KEY_SID:-}"
TWILIO_API_KEY_SECRET="${TWILIO_API_KEY_SECRET:-}"
GHCR_USERNAME="${GHCR_USERNAME:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
VERSION="${AIFLOW_VERSION:-1}"

while [ $# -gt 0 ]; do
  case "$1" in
    --gemini-api-key) GEMINI_API_KEY="$2"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --public-base-url) PUBLIC_BASE_URL="$2"; shift 2 ;;
    --secret-key) SECRET_KEY="$2"; shift 2 ;;
    --twilio-account-sid) TWILIO_ACCOUNT_SID="$2"; shift 2 ;;
    --twilio-auth-token) TWILIO_AUTH_TOKEN="$2"; shift 2 ;;
    --twilio-api-key-sid) TWILIO_API_KEY_SID="$2"; shift 2 ;;
    --twilio-api-key-secret) TWILIO_API_KEY_SECRET="$2"; shift 2 ;;
    --ghcr-username) GHCR_USERNAME="$2"; shift 2 ;;
    --ghcr-token) GHCR_TOKEN="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --install-docker) INSTALL_DOCKER=1; shift ;;
    --dir) DIR="$2"; shift 2 ;;
    --repo-ref) REPO_REF="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

gen_secret() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    od -An -tx1 -N32 /dev/urandom | tr -d ' \n'
  fi
}

gen_password() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 18 | tr -d '/+=\n'
  else
    od -An -tx1 -N16 /dev/urandom | tr -d ' \n'
  fi
}

confirm() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  local reply=""
  # A "readable" /dev/tty can still fail to open (no controlling terminal,
  # e.g. under some sandboxed/non-interactive shells); never let that abort
  # the script under set -e, just fall through to the safe "no" default.
  read -r -p "$1 [y/N] " reply 2>/dev/null </dev/tty || true
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# Resolved once, before any `cd`, since BASH_SOURCE is a path relative to
# the invocation directory and stops resolving correctly once we move.
SCRIPT_DIR=""
case "${BASH_SOURCE[0]:-}" in
  */*) SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)" ;;
esac

fetch_file() {
  local rel="$1" dest="$2"
  if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/config/$rel" ]; then
    log "Using local $rel"
    cp "$SCRIPT_DIR/config/$rel" "$dest"
  elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/../$rel" ]; then
    log "Using local $rel"
    cp "$SCRIPT_DIR/../$rel" "$dest"
  else
    log "Fetching $rel from ref $REPO_REF"
    curl -fsSL "$REPO_RAW_BASE/$REPO_REF/aiflow/config/$rel" -o "$dest"
  fi
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if [ "$INSTALL_DOCKER" -eq 1 ]; then
      log "Docker not found, installing via get.docker.com..."
      curl -fsSL https://get.docker.com | sh
    else
      die "Docker is not installed. Install it (curl -fsSL https://get.docker.com | sh) or re-run with --install-docker."
    fi
  fi
  docker compose version >/dev/null 2>&1 \
    || die "docker compose (the v2 plugin) is required; legacy docker-compose is not supported."
}

# Resolve required inputs: flag/env value wins; otherwise prompt on a real
# tty (works even under curl | bash if one is attached). A failed /dev/tty
# open (no controlling terminal) is swallowed rather than aborting the
# script under set -e; the die() below catches anything still unresolved.
[ -n "$GEMINI_API_KEY" ] || read -r -p "Gemini API key: " GEMINI_API_KEY 2>/dev/null </dev/tty || true
[ -n "$GEMINI_API_KEY" ] || die "Missing --gemini-api-key (or GEMINI_API_KEY)."

[ -n "$ADMIN_EMAIL" ] || read -r -p "Admin email: " ADMIN_EMAIL 2>/dev/null </dev/tty || true
[ -n "$ADMIN_EMAIL" ] || die "Missing --admin-email (or AIFLOW_ADMIN_EMAIL)."

[ -n "$PUBLIC_BASE_URL" ] || [ -z "$DOMAIN" ] || PUBLIC_BASE_URL="https://api.$DOMAIN"
if [ -z "$PUBLIC_BASE_URL" ]; then
  read -r -p "Root domain (e.g. client.com): " DOMAIN 2>/dev/null </dev/tty || true
  [ -n "$DOMAIN" ] && PUBLIC_BASE_URL="https://api.$DOMAIN"
fi
[ -n "$PUBLIC_BASE_URL" ] || die "Missing --domain or --public-base-url (or PUBLIC_BASE_URL)."

ADMIN_PASSWORD_GENERATED=0
if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD="$(gen_password)"
  ADMIN_PASSWORD_GENERATED=1
fi

check_docker

mkdir -p "$DIR"
cd "$DIR"
COMPOSE_FILE="docker-compose.prod.yml"

fetch_file "docker-compose.prod.yml" "$COMPOSE_FILE"

if [ "$VERSION" != "1" ]; then
  sed -i.bak \
    -e "s#ghcr.io/maelqo/aiflow-backend:1#ghcr.io/maelqo/aiflow-backend:${VERSION}#" \
    -e "s#ghcr.io/maelqo/aiflow-admin:1#ghcr.io/maelqo/aiflow-admin:${VERSION}#" \
    "$COMPOSE_FILE"
  rm -f "$COMPOSE_FILE.bak"
fi

ENV_FILE=".env"
SECRET_KEY_GENERATED=0
if [ -f "$ENV_FILE" ] && [ "$FORCE" -ne 1 ]; then
  log "$ENV_FILE already exists, leaving it untouched (pass --force to regenerate it)."
  SECRET_KEY="$(grep -m1 '^SECRET_KEY=' "$ENV_FILE" | cut -d= -f2- || true)"
else
  if [ -f "$ENV_FILE" ]; then
    confirm "Overwrite existing $ENV_FILE?" || die "Aborted, existing .env left untouched."
    cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)"
  fi
  if [ -z "$SECRET_KEY" ]; then
    SECRET_KEY="$(gen_secret)"
    SECRET_KEY_GENERATED=1
  fi
  cat >"$ENV_FILE" <<EOF
SECRET_KEY=$SECRET_KEY
DATABASE_URL=sqlite+aiosqlite:///./data/aiflow.db
PUBLIC_BASE_URL=$PUBLIC_BASE_URL
GEMINI_API_KEY=$GEMINI_API_KEY
GEMINI_LIVE_MODEL=gemini-3.1-flash-live-preview
GOOGLE_GENAI_USE_ENTERPRISE=false
GOOGLE_CLOUD_PROJECT=
GOOGLE_CLOUD_LOCATION=
TWILIO_ACCOUNT_SID=$TWILIO_ACCOUNT_SID
TWILIO_API_KEY_SID=$TWILIO_API_KEY_SID
TWILIO_API_KEY_SECRET=$TWILIO_API_KEY_SECRET
TWILIO_AUTH_TOKEN=$TWILIO_AUTH_TOKEN
WIDGET_CORS_ORIGINS=["*"]
MAX_CONCURRENT_OUTBOUND_CALLS=5
EOF
  log "Wrote $ENV_FILE"
fi
[ -n "$SECRET_KEY" ] || die "$ENV_FILE has no SECRET_KEY; pass --force to regenerate."

if [ -n "$GHCR_TOKEN" ]; then
  [ -n "$GHCR_USERNAME" ] || die "--ghcr-token given without --ghcr-username."
  log "Logging in to ghcr.io as $GHCR_USERNAME"
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
fi

log "Pulling images..."
if ! pull_out="$(docker compose -f "$COMPOSE_FILE" pull 2>&1)"; then
  printf '%s\n' "$pull_out" >&2
  if printf '%s' "$pull_out" | grep -qiE 'unauthorized|denied'; then
    die "GHCR pull was denied. If the images are private, pass --ghcr-username/--ghcr-token."
  fi
  if printf '%s' "$pull_out" | grep -qiE 'cannot connect to the docker daemon|daemon is not running|dockerDesktopLinuxEngine'; then
    die "The Docker daemon isn't running. Start Docker (or Docker Desktop) and re-run."
  fi
  die "docker compose pull failed."
fi

log "Starting containers..."
if ! up_out="$(docker compose -f "$COMPOSE_FILE" up -d 2>&1)"; then
  printf '%s\n' "$up_out" >&2
  if printf '%s' "$up_out" | grep -qiE 'port is already allocated|address already in use'; then
    die "A required port (8000 or 5173) is already in use on this host."
  fi
  die "docker compose up failed."
fi

log "Waiting for the backend to become healthy..."
healthy=0
for _ in $(seq 1 45); do
  if curl -fsS "http://localhost:8000/health" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done
if [ "$healthy" -ne 1 ]; then
  err "Backend did not become healthy in time."
  docker compose -f "$COMPOSE_FILE" logs --tail=50 backend || true
  die "Deployment failed health check."
fi
log "Backend is healthy."

log "Creating admin user $ADMIN_EMAIL..."
if ! admin_out="$(docker compose -f "$COMPOSE_FILE" exec -T backend python -m scripts.create_admin "$ADMIN_EMAIL" "$ADMIN_PASSWORD" 2>&1)"; then
  printf '%s\n' "$admin_out" >&2
  die "create_admin failed."
fi
printf '%s\n' "$admin_out"
admin_already_existed=0
printf '%s' "$admin_out" | grep -q "already exists" && admin_already_existed=1

echo
log "Deployment complete."
echo "  Backend (internal):  http://localhost:8000"
echo "  Admin (internal):    http://localhost:5173"
echo "  Public base URL:     $PUBLIC_BASE_URL"
if [ "$admin_already_existed" -eq 1 ]; then
  echo "  Admin user:           $ADMIN_EMAIL (already existed, password unchanged)"
elif [ "$ADMIN_PASSWORD_GENERATED" -eq 1 ]; then
  echo "  Admin user:           $ADMIN_EMAIL"
  echo "  Admin password:       $ADMIN_PASSWORD  (generated, shown once, save it now)"
else
  echo "  Admin user:           $ADMIN_EMAIL"
fi
if [ "$SECRET_KEY_GENERATED" -eq 1 ]; then
  echo "  SECRET_KEY was generated and written to $DIR/$ENV_FILE (shown once, back it up)."
fi
echo
warn "These ports are plain HTTP and not publicly reachable behind TLS yet."
warn "Put a reverse proxy in front, or re-run with scripts/deploy-caddy.sh instead."
