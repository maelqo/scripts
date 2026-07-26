#!/usr/bin/env bash
# A fresh VPS, Docker Compose, and Caddy
# in front issuing/renewing Let's Encrypt certificates automatically. 
#
# Usage (env vars):
#   GEMINI_API_KEY=... AIFLOW_ADMIN_EMAIL=owner@client.com \
#     curl -fsSL https://raw.githubusercontent.com/maelqo/scripts/main/aiflow/deploy-caddy.sh | bash
#
# Usage (flags):
#   curl -fsSL https://raw.githubusercontent.com/maelqo/scripts/main/aiflow/deploy-caddy.sh \
#     | bash -s -- --domain client.com --gemini-api-key ... --admin-email owner@client.com
set -euo pipefail
trap 'err "failed at line $LINENO (exit $?)"' ERR


REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/maelqo/scripts}"
REPO_REF="main"
DIR="./aiflow"
ASSUME_YES=0
FORCE=0
INSTALL_DOCKER=0
SKIP_DNS_CHECK=0
WAIT_FOR_DNS=0
STAGING_TLS=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: deploy-caddy.sh [options]

Deploys AiFlow behind Caddy on a fresh VPS, with automatic Let's Encrypt TLS.
One root domain, two subdomains.

Required (flag or env var):
  --gemini-api-key KEY        GEMINI_API_KEY
  --admin-email EMAIL         AIFLOW_ADMIN_EMAIL
  --domain ROOT               derives api.ROOT / admin.ROOT
                              (or explicitly: --api-domain / AIFLOW_API_DOMAIN
                              --admin-domain / AIFLOW_ADMIN_DOMAIN)

Optional:
  --admin-password PASS        AIFLOW_ADMIN_PASSWORD   (auto-generated if omitted)
  --secret-key KEY             SECRET_KEY              (auto-generated if omitted)
  --twilio-account-sid ...     TWILIO_ACCOUNT_SID
  --twilio-auth-token ...      TWILIO_AUTH_TOKEN
  --twilio-api-key-sid ...     TWILIO_API_KEY_SID
  --twilio-api-key-secret ...  TWILIO_API_KEY_SECRET
  --resend-api-key ...         RESEND_API_KEY    (only needed for the send_email tool /
                                                  email triggers)
  --resend-from-address ...    RESEND_FROM_ADDRESS
  --ghcr-username USER         GHCR_USERNAME     (AiFlow's own GHCR account, for private
                                                  images; not the client's)
  --ghcr-token TOKEN           GHCR_TOKEN        (the read-only PAT issued for this client)
  --version TAG                AIFLOW_VERSION    (default: 2, tracks all 2.x releases;
                                                  use "latest" or an exact "2.0.0" to opt out of that)
  --outbound-call-max-retries N     OUTBOUND_CALL_MAX_RETRIES      (default: 0, no retry)
  --sentry-dsn DSN                  SENTRY_DSN                     (default: unset, error tracking off)
  --widget-session-rate-limit N/period   WIDGET_SESSION_RATE_LIMIT (default: 30/minute)
  --event-ingestion-rate-limit N/period  EVENT_INGESTION_RATE_LIMIT (default: 120/minute)
  --call-transcript-retention-days N     CALL_TRANSCRIPT_RETENTION_DAYS (default: unset, keep forever)
  --event-log-retention-days N           EVENT_LOG_RETENTION_DAYS      (default: unset, keep forever)
  --outbound-message-retention-days N    OUTBOUND_MESSAGE_RETENTION_DAYS (default: unset, keep forever)
  --email ADDR                 CADDY_ACME_EMAIL        (Let's Encrypt contact)
  --skip-dns-check             Don't verify DNS resolves to this host first
  --wait-for-dns               Poll (up to ~10 min) until DNS resolves before continuing
  --staging-tls                Use Let's Encrypt's staging CA (for repeat testing)
  --install-docker             Install Docker via get.docker.com if missing
  --dir PATH                   Deployment directory (default: ./aiflow)
  --repo-ref REF               Git ref to fetch companion files from (default: main)
  --force                      Overwrite existing .env/Caddyfile instead of leaving them alone
  -y, --yes                    Assume yes on confirmations
  -h, --help                   Show this help
EOF
}

GEMINI_API_KEY="${GEMINI_API_KEY:-}"
ADMIN_EMAIL="${AIFLOW_ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${AIFLOW_ADMIN_PASSWORD:-}"
DOMAIN=""
API_DOMAIN="${AIFLOW_API_DOMAIN:-}"
ADMIN_DOMAIN="${AIFLOW_ADMIN_DOMAIN:-}"
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
ACME_EMAIL="${CADDY_ACME_EMAIL:-}"
OUTBOUND_CALL_MAX_RETRIES="${OUTBOUND_CALL_MAX_RETRIES:-0}"
SENTRY_DSN="${SENTRY_DSN:-}"
WIDGET_SESSION_RATE_LIMIT="${WIDGET_SESSION_RATE_LIMIT:-30/minute}"
EVENT_INGESTION_RATE_LIMIT="${EVENT_INGESTION_RATE_LIMIT:-120/minute}"
CALL_TRANSCRIPT_RETENTION_DAYS="${CALL_TRANSCRIPT_RETENTION_DAYS:-}"
EVENT_LOG_RETENTION_DAYS="${EVENT_LOG_RETENTION_DAYS:-}"
OUTBOUND_MESSAGE_RETENTION_DAYS="${OUTBOUND_MESSAGE_RETENTION_DAYS:-}"

while [ $# -gt 0 ]; do
  case "$1" in
    --gemini-api-key) GEMINI_API_KEY="$2"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --api-domain) API_DOMAIN="$2"; shift 2 ;;
    --admin-domain) ADMIN_DOMAIN="$2"; shift 2 ;;
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
    --email) ACME_EMAIL="$2"; shift 2 ;;
    --skip-dns-check) SKIP_DNS_CHECK=1; shift ;;
    --wait-for-dns) WAIT_FOR_DNS=1; shift ;;
    --staging-tls) STAGING_TLS=1; shift ;;
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

resolve_host() {
  local host="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short "$host" A | tail -n1
  elif command -v getent >/dev/null 2>&1; then
    getent hosts "$host" | awk '{print $1}' | tail -n1
  elif command -v host >/dev/null 2>&1; then
    host "$host" 2>/dev/null | awk '/has address/ {print $NF; exit}'
  fi
}

server_ip() {
  curl -fsS https://api.ipify.org 2>/dev/null || true
}

check_dns() {
  local host="$1" expected="$2" resolved
  resolved="$(resolve_host "$host" || true)"
  [ "$resolved" = "$expected" ]
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
if [ -z "$API_DOMAIN" ] || [ -z "$ADMIN_DOMAIN" ]; then
  if [ -z "$DOMAIN" ]; then
    read -r -p "Root domain (e.g. client.com): " DOMAIN 2>/dev/null </dev/tty || true
  fi
  [ -z "$API_DOMAIN" ] && [ -n "$DOMAIN" ] && API_DOMAIN="api.$DOMAIN"
  [ -z "$ADMIN_DOMAIN" ] && [ -n "$DOMAIN" ] && ADMIN_DOMAIN="admin.$DOMAIN"
fi
[ -n "$API_DOMAIN" ] && [ -n "$ADMIN_DOMAIN" ] \
  || die "Missing --domain (or --api-domain/--admin-domain)."

PUBLIC_BASE_URL="https://$API_DOMAIN"

ADMIN_PASSWORD_GENERATED=0
if [ -z "$ADMIN_PASSWORD" ]; then
  ADMIN_PASSWORD="$(gen_password)"
  ADMIN_PASSWORD_GENERATED=1
fi

check_docker

if [ "$SKIP_DNS_CHECK" -ne 1 ]; then
  log "Checking DNS for $API_DOMAIN and $ADMIN_DOMAIN..."
  ip="$(server_ip)"
  if [ -z "$ip" ]; then
    warn "Could not determine this server's public IP, skipping DNS check."
  else
    attempts=1
    [ "$WAIT_FOR_DNS" -eq 1 ] && attempts=60
    ok=0
    for _ in $(seq 1 "$attempts"); do
      if check_dns "$API_DOMAIN" "$ip" && check_dns "$ADMIN_DOMAIN" "$ip"; then
        ok=1
        break
      fi
      [ "$WAIT_FOR_DNS" -eq 1 ] && sleep 10
    done
    if [ "$ok" -ne 1 ]; then
      warn "$API_DOMAIN / $ADMIN_DOMAIN do not both resolve to this host's IP ($ip) yet."
      warn "Caddy will fail to issue certificates until DNS propagates. Point their A/AAAA records here, or pass --wait-for-dns / --skip-dns-check."
      if [ "$ASSUME_YES" -ne 1 ]; then
        # Only abort if we get an actual "no" from a real terminal; with no
        # controlling terminal attached (the common curl | bash case) fall
        # through and proceed with the warning already printed above.
        dns_reply=""
        read -r -p "Continue anyway? [y/N] " dns_reply 2>/dev/null </dev/tty || dns_reply="__no-tty__"
        if [ "$dns_reply" != "__no-tty__" ]; then
          case "$dns_reply" in [yY]|[yY][eE][sS]) : ;; *) die "Aborted, fix DNS and re-run." ;; esac
        fi
      fi
    else
      log "DNS looks correct."
    fi
  fi
fi

mkdir -p "$DIR"
cd "$DIR"
COMPOSE_FILE="docker-compose.caddy.yml"

fetch_file "docker-compose.caddy.yml" "$COMPOSE_FILE"
fetch_file "Caddyfile.example" "Caddyfile.example"

CADDYFILE="Caddyfile"
if [ -f "$CADDYFILE" ] && [ "$FORCE" -ne 1 ]; then
  log "$CADDYFILE already exists, leaving it untouched (pass --force to regenerate it)."
else
  if [ -f "$CADDYFILE" ]; then
    confirm "Overwrite existing $CADDYFILE?" || die "Aborted, existing Caddyfile left untouched."
    cp "$CADDYFILE" "$CADDYFILE.bak.$(date +%s)"
  fi
  sed \
    -e "s/api.client-domain.com/$API_DOMAIN/" \
    -e "s/admin.client-domain.com/$ADMIN_DOMAIN/" \
    Caddyfile.example >"$CADDYFILE"
  if [ -n "$ACME_EMAIL" ] || [ "$STAGING_TLS" -eq 1 ]; then
    {
      echo "{"
      [ -n "$ACME_EMAIL" ] && echo "    email $ACME_EMAIL"
      [ "$STAGING_TLS" -eq 1 ] && echo "    acme_ca https://acme-staging-v02.api.letsencrypt.org/directory"
      echo "}"
      cat "$CADDYFILE"
    } >"$CADDYFILE.new"
    mv "$CADDYFILE.new" "$CADDYFILE"
  fi
  log "Wrote $CADDYFILE"
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
RESEND_API_KEY=$RESEND_API_KEY
RESEND_FROM_ADDRESS=$RESEND_FROM_ADDRESS
WIDGET_CORS_ORIGINS=["*"]
MAX_CONCURRENT_OUTBOUND_CALLS=5
OUTBOUND_CALL_MAX_RETRIES=$OUTBOUND_CALL_MAX_RETRIES
SENTRY_DSN=$SENTRY_DSN
WIDGET_SESSION_RATE_LIMIT=$WIDGET_SESSION_RATE_LIMIT
EVENT_INGESTION_RATE_LIMIT=$EVENT_INGESTION_RATE_LIMIT
CALL_TRANSCRIPT_RETENTION_DAYS=$CALL_TRANSCRIPT_RETENTION_DAYS
EVENT_LOG_RETENTION_DAYS=$EVENT_LOG_RETENTION_DAYS
OUTBOUND_MESSAGE_RETENTION_DAYS=$OUTBOUND_MESSAGE_RETENTION_DAYS
EOF
  log "Wrote $ENV_FILE"
fi
[ -n "$SECRET_KEY" ] || die "$ENV_FILE has no SECRET_KEY; pass --force to regenerate."

# Always applied, even against an existing .env left untouched above, so
# --version takes effect on every run: read by docker-compose.caddy.yml's
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

log "Starting containers (backend, admin, caddy)..."
if ! up_out="$(docker compose -f "$COMPOSE_FILE" up -d 2>&1)"; then
  printf '%s\n' "$up_out" >&2
  if printf '%s' "$up_out" | grep -qiE 'port is already allocated|address already in use'; then
    die "Port 80 or 443 is already in use on this host, probably by another web server. Stop it, or deploy behind that proxy with deploy-compose.sh instead."
  fi
  die "docker compose up failed."
fi

log "Waiting for https://$API_DOMAIN/health (Caddy issues certificates on first request, this can take a minute)..."
healthy=0
for _ in $(seq 1 90); do
  if curl -fsS "https://$API_DOMAIN/health" >/dev/null 2>&1; then
    healthy=1
    break
  fi
  sleep 2
done
if [ "$healthy" -ne 1 ]; then
  err "$API_DOMAIN did not become healthy over HTTPS in time."
  docker compose -f "$COMPOSE_FILE" logs --tail=30 caddy || true
  docker compose -f "$COMPOSE_FILE" logs --tail=30 backend || true
  die "Deployment failed health check. Common causes: DNS not yet propagated, or the cloud firewall/security group is blocking inbound 80/443."
fi
log "Backend is healthy over HTTPS."

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
echo "  Backend:              https://$API_DOMAIN"
echo "  Admin dashboard:      https://$ADMIN_DOMAIN"
if [ "$admin_already_existed" -eq 1 ]; then
  echo "  Admin user:            $ADMIN_EMAIL (already existed, password unchanged)"
elif [ "$ADMIN_PASSWORD_GENERATED" -eq 1 ]; then
  echo "  Admin user:            $ADMIN_EMAIL"
  echo "  Admin password:        $ADMIN_PASSWORD  (generated, shown once, save it now)"
else
  echo "  Admin user:            $ADMIN_EMAIL"
fi
if [ "$SECRET_KEY_GENERATED" -eq 1 ]; then
  echo "  SECRET_KEY was generated and written to $DIR/$ENV_FILE (shown once, back it up)."
fi
echo
echo "  Widget embed snippet:"
echo "    <script src=\"https://$API_DOMAIN/widget/aiflow-widget.js\" data-agent=\"YOUR-AGENT-SLUG\" data-api-base=\"https://$API_DOMAIN\"></script>"
echo
echo "  Twilio webhook URLs (only needed for phone features):"
echo "    Voice webhook:    https://$API_DOMAIN/api/v1/twilio/inbound"
echo
warn "Make sure this server's cloud firewall/security group allows inbound 80 and 443 (this script cannot check that remotely)."
