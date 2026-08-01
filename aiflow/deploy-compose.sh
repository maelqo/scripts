#!/usr/bin/env bash
# Pulls the pre-built images and brings them up via Docker Compose. 
#
# Usage (env vars):
#   GEMINI_API_KEY=... AIFLOW_ADMIN_EMAIL=owner@client.com \
#     curl -fsSL https://raw.githubusercontent.com/maelqo/scripts/main/aiflow/deploy-compose.sh | bash
#
# Usage (flags):
#   curl -fsSL https://raw.githubusercontent.com/maelqo/scripts/main/aiflow/deploy-compose.sh \
#     | bash -s -- --domain client.com --gemini-api-key ... --admin-email owner@client.com
set -euo pipefail
trap 'err "failed at line $LINENO (exit $?)"' ERR

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
  --domain ROOT               derives api.ROOT / admin.ROOT

Optional:
  --api-domain ...                        API_DOMAIN
  --admin-domain ...                      ADMIN_DOMAIN
  --admin-password PASS                   AIFLOW_ADMIN_PASSWORD   (auto-generated if omitted)
  --secret-key KEY                        SECRET_KEY              (auto-generated if omitted)
  --twilio-account-sid ...                TWILIO_ACCOUNT_SID
  --twilio-auth-token ...                 TWILIO_AUTH_TOKEN
  --twilio-api-key-sid ...                TWILIO_API_KEY_SID
  --twilio-api-key-secret ...             TWILIO_API_KEY_SECRET
  --resend-api-key ...                    RESEND_API_KEY 
  --resend-from-address ...               RESEND_FROM_ADDRESS
  --ghcr-username USER                    GHCR_USERNAME     (AiFlow's GHCR account)
  --ghcr-token TOKEN                      GHCR_TOKEN        (the read-only PAT issued for this client)
  --version TAG                           AIFLOW_VERSION    (default: 2)
  --outbound-call-max-retries N           OUTBOUND_CALL_MAX_RETRIES      (default: 0, no retry)
  --sentry-dsn DSN                        SENTRY_DSN                     (default: unset, error tracking off)
  --widget-session-rate-limit N/period    WIDGET_SESSION_RATE_LIMIT (default: 30/minute)
  --event-ingestion-rate-limit N/period   EVENT_INGESTION_RATE_LIMIT (default: 120/minute)
  --call-transcript-retention-days N      CALL_TRANSCRIPT_RETENTION_DAYS (default: unset, keep forever)
  --event-log-retention-days N            EVENT_LOG_RETENTION_DAYS      (default: unset, keep forever)
  --outbound-message-retention-days N     OUTBOUND_MESSAGE_RETENTION_DAYS (default: unset, keep forever)
  --orchestrators-enabled                 ORCHESTRATORS_ENABLED       (default: false)
  --anthropic-api-key ...                 ANTHROPIC_API_KEY           (only for an Orchestrator using anthropic/...)
  --openai-api-key ...                    OPENAI_API_KEY              (only for an Orchestrator using openai/...)
  --orchestrator-max-steps N              ORCHESTRATOR_MAX_STEPS              (default: 25)
  --orchestrator-task-timeout-seconds N   ORCHESTRATOR_TASK_TIMEOUT_SECONDS   (default: 60)
  --postgres                              Use the bundled Postgres container instead of SQLite
  --postgres-user USER                    POSTGRES_USER      (default: aiflow)
  --postgres-password PASS                POSTGRES_PASSWORD  (default: aiflow, change it for anything real)
  --postgres-db NAME                      POSTGRES_DB        (default: aiflow)
  --database-url URL                      DATABASE_URL       (raw escape hatch: point at a database)
  --install-docker                        Install Docker via get.docker.com if missing
  --dir PATH                              Deployment directory (default: ./aiflow)
  --repo-ref REF                          Git ref to fetch companion files from (default: main)
  --force                                 Overwrite an existing .env instead of leaving it alone
  -y, --yes                               Assume yes on confirmations
  -h, --help                              Show this help
EOF
}

GEMINI_API_KEY="${GEMINI_API_KEY:-}"
ADMIN_EMAIL="${AIFLOW_ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${AIFLOW_ADMIN_PASSWORD:-}"
DOMAIN=""
API_DOMAIN="${AIFLOW_API_DOMAIN:-}"
ADMIN_DOMAIN="${AIFLOW_ADMIN_DOMAIN:-}"
PUBLIC_BASE_URL="${PUBLIC_BASE_URL:-}"
SECRET_KEY="${SECRET_KEY:-}"
TWILIO_ACCOUNT_SID="${TWILIO_ACCOUNT_SID:-}"
TWILIO_AUTH_TOKEN="${TWILIO_AUTH_TOKEN:-}"
TWILIO_API_KEY_SID="${TWILIO_API_KEY_SID:-}"
TWILIO_API_KEY_SECRET="${TWILIO_API_KEY_SECRET:-}"
RESEND_API_KEY="${RESEND_API_KEY:-}"
RESEND_FROM_ADDRESS="${RESEND_FROM_ADDRESS:-}"
GHCR_USERNAME="${GHCR_USERNAME:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
VERSION="${AIFLOW_VERSION:-2}"
OUTBOUND_CALL_MAX_RETRIES="${OUTBOUND_CALL_MAX_RETRIES:-0}"
SENTRY_DSN="${SENTRY_DSN:-}"
WIDGET_SESSION_RATE_LIMIT="${WIDGET_SESSION_RATE_LIMIT:-30/minute}"
EVENT_INGESTION_RATE_LIMIT="${EVENT_INGESTION_RATE_LIMIT:-120/minute}"
CALL_TRANSCRIPT_RETENTION_DAYS="${CALL_TRANSCRIPT_RETENTION_DAYS:-}"
EVENT_LOG_RETENTION_DAYS="${EVENT_LOG_RETENTION_DAYS:-}"
OUTBOUND_MESSAGE_RETENTION_DAYS="${OUTBOUND_MESSAGE_RETENTION_DAYS:-}"
ORCHESTRATORS_ENABLED="${ORCHESTRATORS_ENABLED:-false}"
ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
OPENAI_API_KEY="${OPENAI_API_KEY:-}"
ORCHESTRATOR_MAX_STEPS="${ORCHESTRATOR_MAX_STEPS:-25}"
ORCHESTRATOR_TASK_TIMEOUT_SECONDS="${ORCHESTRATOR_TASK_TIMEOUT_SECONDS:-60}"
POSTGRES=0
POSTGRES_USER="${POSTGRES_USER:-}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
POSTGRES_DB="${POSTGRES_DB:-}"
DATABASE_URL="${DATABASE_URL:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --gemini-api-key) GEMINI_API_KEY="$2"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --api-domain) API_DOMAIN="$2"; shift 2 ;;
    --admin-domain) ADMIN_DOMAIN="$2"; shift 2 ;;
    --public-base-url) PUBLIC_BASE_URL="$2"; shift 2 ;;
    --secret-key) SECRET_KEY="$2"; shift 2 ;;
    --twilio-account-sid) TWILIO_ACCOUNT_SID="$2"; shift 2 ;;
    --twilio-auth-token) TWILIO_AUTH_TOKEN="$2"; shift 2 ;;
    --twilio-api-key-sid) TWILIO_API_KEY_SID="$2"; shift 2 ;;
    --twilio-api-key-secret) TWILIO_API_KEY_SECRET="$2"; shift 2 ;;
    --resend-api-key) RESEND_API_KEY="$2"; shift 2 ;;
    --resend-from-address) RESEND_FROM_ADDRESS="$2"; shift 2 ;;
    --ghcr-username) GHCR_USERNAME="$2"; shift 2 ;;
    --ghcr-token) GHCR_TOKEN="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --outbound-call-max-retries) OUTBOUND_CALL_MAX_RETRIES="$2"; shift 2 ;;
    --sentry-dsn) SENTRY_DSN="$2"; shift 2 ;;
    --widget-session-rate-limit) WIDGET_SESSION_RATE_LIMIT="$2"; shift 2 ;;
    --event-ingestion-rate-limit) EVENT_INGESTION_RATE_LIMIT="$2"; shift 2 ;;
    --call-transcript-retention-days) CALL_TRANSCRIPT_RETENTION_DAYS="$2"; shift 2 ;;
    --event-log-retention-days) EVENT_LOG_RETENTION_DAYS="$2"; shift 2 ;;
    --outbound-message-retention-days) OUTBOUND_MESSAGE_RETENTION_DAYS="$2"; shift 2 ;;
    --orchestrators-enabled) ORCHESTRATORS_ENABLED="true"; shift ;;
    --anthropic-api-key) ANTHROPIC_API_KEY="$2"; shift 2 ;;
    --openai-api-key) OPENAI_API_KEY="$2"; shift 2 ;;
    --orchestrator-max-steps) ORCHESTRATOR_MAX_STEPS="$2"; shift 2 ;;
    --orchestrator-task-timeout-seconds) ORCHESTRATOR_TASK_TIMEOUT_SECONDS="$2"; shift 2 ;;
    --postgres) POSTGRES=1; shift ;;
    --postgres-user) POSTGRES_USER="$2"; POSTGRES=1; shift 2 ;;
    --postgres-password) POSTGRES_PASSWORD="$2"; POSTGRES=1; shift 2 ;;
    --postgres-db) POSTGRES_DB="$2"; POSTGRES=1; shift 2 ;;
    --database-url) DATABASE_URL="$2"; shift 2 ;;
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
    curl -fsSL --connect-timeout 10 --max-time 60 "$REPO_RAW_BASE/$REPO_REF/aiflow/config/$rel" -o "$dest" \
      || die "Failed to download $rel from $REPO_RAW_BASE/$REPO_REF/aiflow/config/$rel (timed out or network error). Check this host can reach raw.githubusercontent.com over HTTPS (outbound firewall/proxy), then re-run."
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
  docker_ping_out=""
  if ! docker_ping_out="$(docker info 2>&1 1>/dev/null)"; then
    if printf '%s' "$docker_ping_out" | grep -qiE 'permission denied'; then
      die "Current user can't access the Docker socket (permission denied on /var/run/docker.sock). This is a local permissions issue, unrelated to GHCR/GitHub credentials. Fix: sudo usermod -aG docker \$USER && newgrp docker, then re-run without sudo; or run the whole script as root, e.g. curl ... | sudo bash -s -- ... (sudo must wrap bash, not curl: 'sudo curl ... | bash' only elevates curl, bash still runs unprivileged)."
    fi
  fi
}

# Resolve required inputs: flag/env value wins; otherwise prompt on a real
# tty (works even under curl | bash if one is attached). A failed /dev/tty
# open (no controlling terminal) is swallowed rather than aborting the
# script under set -e; the die() below catches anything still unresolved.
[ -n "$GEMINI_API_KEY" ] || read -r -p "Gemini API key: " GEMINI_API_KEY 2>/dev/null </dev/tty || true
[ -n "$GEMINI_API_KEY" ] || die "Missing --gemini-api-key (or GEMINI_API_KEY)."

[ -n "$ADMIN_EMAIL" ] || read -r -p "Admin email: " ADMIN_EMAIL 2>/dev/null </dev/tty || true
[ -n "$ADMIN_EMAIL" ] || die "Missing --admin-email (or AIFLOW_ADMIN_EMAIL)."

if [ -z "$API_DOMAIN" ] && [ -n "$DOMAIN" ]; then API_DOMAIN="api.$DOMAIN"; fi
if [ -z "$ADMIN_DOMAIN" ] && [ -n "$DOMAIN" ]; then ADMIN_DOMAIN="admin.$DOMAIN"; fi

[ -n "$PUBLIC_BASE_URL" ] || [ -z "$API_DOMAIN" ] || PUBLIC_BASE_URL="https://$API_DOMAIN"
if [ -z "$PUBLIC_BASE_URL" ]; then
  read -r -p "Root domain (e.g. client.com): " DOMAIN 2>/dev/null </dev/tty || true
  if [ -n "$DOMAIN" ]; then
    [ -z "$API_DOMAIN" ] && API_DOMAIN="api.$DOMAIN"
    [ -z "$ADMIN_DOMAIN" ] && ADMIN_DOMAIN="admin.$DOMAIN"
    PUBLIC_BASE_URL="https://$API_DOMAIN"
  fi
fi
[ -n "$PUBLIC_BASE_URL" ] || die "Missing --domain (or --api-domain/--public-base-url)."

if [ -n "$DATABASE_URL" ] && [ "$POSTGRES" -eq 1 ]; then
  warn "--database-url was given alongside --postgres/--postgres-*; using --database-url as-is and skipping the bundled Postgres container."
fi
if [ "$POSTGRES" -eq 1 ] && [ -z "$DATABASE_URL" ]; then
  POSTGRES_USER="${POSTGRES_USER:-aiflow}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-aiflow}"
  POSTGRES_DB="${POSTGRES_DB:-aiflow}"
fi

ADMIN_PASSWORD_GENERATED=0
if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD="$(gen_password)"
  ADMIN_PASSWORD_GENERATED=1
fi

check_docker

mkdir -p "$DIR"
cd "$DIR"
COMPOSE_FILE="docker-compose.prod.yml"
COMPOSE_ARGS=(-f "$COMPOSE_FILE")

fetch_file "docker-compose.prod.yml" "$COMPOSE_FILE"

if [ "$POSTGRES" -eq 1 ] && [ -z "$DATABASE_URL" ]; then
  fetch_file "docker-compose.postgres.yml" "docker-compose.postgres.yml"
  COMPOSE_ARGS+=(-f "docker-compose.postgres.yml")
fi

if [ -n "$DATABASE_URL" ]; then
  RESOLVED_DATABASE_URL="$DATABASE_URL"
elif [ "$POSTGRES" -eq 1 ]; then
  RESOLVED_DATABASE_URL="postgresql+asyncpg://$POSTGRES_USER:$POSTGRES_PASSWORD@postgres:5432/$POSTGRES_DB"
else
  RESOLVED_DATABASE_URL="sqlite+aiosqlite:///./data/aiflow.db"
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
  # Narrows the admin API's CORS policy to the actual admin subdomain
  # instead of also inheriting the widget's deliberately permissive
  # wildcard; blank (no --admin-domain/--domain given) falls back to that
  # wildcard, same as leaving ADMIN_CORS_ORIGINS unset always does.
  ADMIN_CORS_ORIGINS_VALUE=""
  [ -n "$ADMIN_DOMAIN" ] && ADMIN_CORS_ORIGINS_VALUE="[\"https://$ADMIN_DOMAIN\"]"
  cat >"$ENV_FILE" <<EOF
SECRET_KEY=$SECRET_KEY
DATABASE_URL=$RESOLVED_DATABASE_URL
POSTGRES_USER=$POSTGRES_USER
POSTGRES_PASSWORD=$POSTGRES_PASSWORD
POSTGRES_DB=$POSTGRES_DB
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
RESEND_API_KEY=$RESEND_API_KEY
RESEND_FROM_ADDRESS=$RESEND_FROM_ADDRESS
WIDGET_CORS_ORIGINS=["*"]
ADMIN_CORS_ORIGINS=$ADMIN_CORS_ORIGINS_VALUE
MAX_CONCURRENT_OUTBOUND_CALLS=5
OUTBOUND_CALL_MAX_RETRIES=$OUTBOUND_CALL_MAX_RETRIES
SENTRY_DSN=$SENTRY_DSN
WIDGET_SESSION_RATE_LIMIT=$WIDGET_SESSION_RATE_LIMIT
EVENT_INGESTION_RATE_LIMIT=$EVENT_INGESTION_RATE_LIMIT
CALL_TRANSCRIPT_RETENTION_DAYS=$CALL_TRANSCRIPT_RETENTION_DAYS
EVENT_LOG_RETENTION_DAYS=$EVENT_LOG_RETENTION_DAYS
OUTBOUND_MESSAGE_RETENTION_DAYS=$OUTBOUND_MESSAGE_RETENTION_DAYS
ORCHESTRATORS_ENABLED=$ORCHESTRATORS_ENABLED
ANTHROPIC_API_KEY=$ANTHROPIC_API_KEY
OPENAI_API_KEY=$OPENAI_API_KEY
ORCHESTRATOR_MAX_STEPS=$ORCHESTRATOR_MAX_STEPS
ORCHESTRATOR_TASK_TIMEOUT_SECONDS=$ORCHESTRATOR_TASK_TIMEOUT_SECONDS
EOF
  log "Wrote $ENV_FILE"
fi
[ -n "$SECRET_KEY" ] || die "$ENV_FILE has no SECRET_KEY; pass --force to regenerate."

# Always applied, even against an existing .env left untouched above, so
# --version takes effect on every run: read by docker-compose.prod.yml's
# ${AIFLOW_VERSION:-2} image tag interpolation, not by the application itself.
grep -v '^AIFLOW_VERSION=' "$ENV_FILE" > "$ENV_FILE.tmp" || true
printf 'AIFLOW_VERSION=%s\n' "$VERSION" >> "$ENV_FILE.tmp"
mv "$ENV_FILE.tmp" "$ENV_FILE"

if [ -n "$GHCR_TOKEN" ]; then
  [ -n "$GHCR_USERNAME" ] || die "--ghcr-token given without --ghcr-username."
  log "Logging in to ghcr.io as $GHCR_USERNAME"
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
fi

log "Pulling images..."
if ! pull_out="$(docker compose "${COMPOSE_ARGS[@]}" pull 2>&1)"; then
  printf '%s\n' "$pull_out" >&2
  if printf '%s' "$pull_out" | grep -qiE 'permission denied' \
    && printf '%s' "$pull_out" | grep -qiE 'docker\.sock|daemon socket|connect to the docker'; then
    die "Docker socket permission denied (not a GHCR/registry issue). Fix: sudo usermod -aG docker \$USER && newgrp docker, then re-run without sudo; or run the whole script as root, e.g. curl ... | sudo bash -s -- ... (sudo must wrap bash, not curl: 'sudo curl ... | bash' only elevates curl, bash still runs unprivileged)."
  fi
  if printf '%s' "$pull_out" | grep -qiE 'unauthorized|denied'; then
    die "GHCR pull was denied. If the images are private, pass --ghcr-username/--ghcr-token."
  fi
  if printf '%s' "$pull_out" | grep -qiE 'cannot connect to the docker daemon|daemon is not running|dockerDesktopLinuxEngine'; then
    die "The Docker daemon isn't running. Start Docker (or Docker Desktop) and re-run."
  fi
  die "docker compose pull failed."
fi

log "Starting containers..."
if ! up_out="$(docker compose "${COMPOSE_ARGS[@]}" up -d 2>&1)"; then
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
  docker compose "${COMPOSE_ARGS[@]}" logs --tail=50 backend || true
  die "Deployment failed health check."
fi
log "Backend is healthy."

log "Creating admin user $ADMIN_EMAIL..."
if ! admin_out="$(docker compose "${COMPOSE_ARGS[@]}" exec -T backend python -m scripts.create_admin "$ADMIN_EMAIL" "$ADMIN_PASSWORD" < /dev/null 2>&1)"; then
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
echo "  Backend public URL:  $PUBLIC_BASE_URL"
if [ -n "$ADMIN_DOMAIN" ]; then
  echo "  Admin public URL:    https://$ADMIN_DOMAIN  (point your reverse proxy here too)"
else
  echo "  Admin public URL:    <not set, pass --domain or --admin-domain to have this printed>"
fi
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
