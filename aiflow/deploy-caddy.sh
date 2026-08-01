#!/usr/bin/env bash
# A fresh VPS, Docker Compose, and Caddy
# in front issuing/renewing Let's Encrypt certificates automatically.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/maelqo/scripts/main/aiflow/deploy-caddy.sh \
#     | bash -s -- --domain client.com --admin-email owner@client.com
#
# If ./aiflow/.env doesn't exist yet, this prompts you to paste one in (see
# .env.example for the full variable list; SECRET_KEY/GEMINI_API_KEY are the
# only ones that must be real values, PUBLIC_BASE_URL/ADMIN_CORS_ORIGINS are
# filled in automatically from --domain, everything else is optional). For
# non-interactive use, write ./aiflow/.env yourself before running, the
# prompt is skipped whenever a .env is already there.
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

All application configuration (GEMINI_API_KEY, SECRET_KEY, Twilio/Resend/
CRM/SSO/Orchestrator/etc. credentials, rate limits, retention windows, ...)
lives in .env, not in flags, see .env.example for the full list. If
./aiflow/.env doesn't already exist, this script prompts you to paste one
in (Ctrl+D to finish); write it yourself beforehand for non-interactive use.

Options (these control how the script runs and how Caddy/DNS/TLS behave,
not the deployed app's own configuration):
  --domain ROOT                            derives api.ROOT / admin.ROOT
  --api-domain ...                         AIFLOW_API_DOMAIN   (instead of --domain)
  --admin-domain ...                       AIFLOW_ADMIN_DOMAIN (instead of --domain)
  --admin-email EMAIL                      AIFLOW_ADMIN_EMAIL      (required; the first admin user's login)
  --admin-password PASS                    AIFLOW_ADMIN_PASSWORD   (auto-generated if omitted)
  --ghcr-username USER                     GHCR_USERNAME     (AiFlow's GHCR account)
  --ghcr-token TOKEN                       GHCR_TOKEN        (the read-only PAT issued for this client)
  --version TAG                            AIFLOW_VERSION    (default: 2)
  --postgres                               Also bring up the bundled Postgres container (docker-compose.postgres.yml);
                                             set POSTGRES_USER/PASSWORD/DB in .env to override its defaults,
                                             or set DATABASE_URL yourself in .env to point at a Postgres/other
                                             database you already run instead (leave this flag off in that case)
  --email ADDR                             CADDY_ACME_EMAIL        (Let's Encrypt contact)
  --skip-dns-check                         Don't verify DNS resolves to this host first
  --wait-for-dns                           Poll (up to ~10 min) until DNS resolves before continuing
  --staging-tls                            Use Let's Encrypt's staging CA (for repeat testing)
  --install-docker                         Install Docker via get.docker.com if missing
  --dir PATH                               Deployment directory (default: ./aiflow)
  --repo-ref REF                           Git ref to fetch companion files from (default: main)
  --force                                  Overwrite existing .env/Caddyfile instead of leaving them alone
  -y, --yes                                Assume yes on confirmations
  -h, --help                               Show this help
EOF
}

DOMAIN=""
API_DOMAIN="${AIFLOW_API_DOMAIN:-}"
ADMIN_DOMAIN="${AIFLOW_ADMIN_DOMAIN:-}"
ADMIN_EMAIL="${AIFLOW_ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${AIFLOW_ADMIN_PASSWORD:-}"
GHCR_USERNAME="${GHCR_USERNAME:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
VERSION="${AIFLOW_VERSION:-2}"
ACME_EMAIL="${CADDY_ACME_EMAIL:-}"
POSTGRES=0

while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --api-domain) API_DOMAIN="$2"; shift 2 ;;
    --admin-domain) ADMIN_DOMAIN="$2"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --ghcr-username) GHCR_USERNAME="$2"; shift 2 ;;
    --ghcr-token) GHCR_TOKEN="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --postgres) POSTGRES=1; shift ;;
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

# Reads the current value of KEY=... from an env file, empty string if
# absent. Used both to validate what a pasted/pre-staged .env contains and
# to decide whether inject_env_var below needs to act.
env_value() {
  grep -m1 "^${1}=" "$2" 2>/dev/null | cut -d= -f2- || true
}

# Unconditionally sets KEY=VALUE in FILE, replacing any existing line for
# that key. Callers decide when this is appropriate to call.
inject_env_var() {
  local key="$1" value="$2" file="$3"
  grep -v "^${key}=" "$file" >"$file.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >>"$file.tmp"
  mv "$file.tmp" "$file"
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
COMPOSE_ARGS=(-f "$COMPOSE_FILE")

fetch_file "docker-compose.caddy.yml" "$COMPOSE_FILE"
fetch_file "Caddyfile.example" "Caddyfile.example"
fetch_file ".env.example" ".env.example"

if [ "$POSTGRES" -eq 1 ]; then
  fetch_file "docker-compose.postgres.yml" "docker-compose.postgres.yml"
  COMPOSE_ARGS+=(-f "docker-compose.postgres.yml")
fi

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
ENV_FILE_IS_FRESH=1
if [ -f "$ENV_FILE" ] && [ "$FORCE" -ne 1 ]; then
  log "$ENV_FILE already exists, leaving it untouched (pass --force to replace it)."
  ENV_FILE_IS_FRESH=0
else
  if [ -f "$ENV_FILE" ]; then
    confirm "Overwrite existing $ENV_FILE?" || die "Aborted, existing $ENV_FILE left untouched."
    cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)"
    log "Replacing $ENV_FILE (backed up first)."
  else
    log "No $ENV_FILE yet."
  fi
  echo "See $DIR/.env.example for the full list of variables (SECRET_KEY and GEMINI_API_KEY"
  echo "must be set to real values; PUBLIC_BASE_URL/ADMIN_CORS_ORIGINS are filled in below"
  echo "from --domain if you don't set them yourself; everything else is optional)."
  echo "Paste your .env contents below, then press Ctrl+D when done:"
  echo
  # Written to a temp file first and moved into place only on success: a
  # bare `cat >"$ENV_FILE" </dev/tty` would truncate $ENV_FILE via its `>`
  # redirection before the `</dev/tty` open even gets a chance to fail,
  # zeroing out an existing file on a failed/no-tty attempt.
  ENV_FILE_TMP="$ENV_FILE.paste.tmp.$$"
  if ! cat >"$ENV_FILE_TMP" </dev/tty; then
    rm -f "$ENV_FILE_TMP"
    die "Could not read from a terminal to paste into. If running non-interactively, write $DIR/$ENV_FILE yourself before running this script."
  fi
  mv "$ENV_FILE_TMP" "$ENV_FILE"
  echo
  log "Saved $ENV_FILE."
fi

GEMINI_API_KEY="$(env_value GEMINI_API_KEY "$ENV_FILE")"
[ -n "$GEMINI_API_KEY" ] || die "GEMINI_API_KEY is missing/blank in $DIR/$ENV_FILE. Add it and re-run (see .env.example)."

EXISTING_PUBLIC_BASE_URL="$(env_value PUBLIC_BASE_URL "$ENV_FILE")"
if [ -z "$EXISTING_PUBLIC_BASE_URL" ]; then
  inject_env_var PUBLIC_BASE_URL "$PUBLIC_BASE_URL" "$ENV_FILE"
elif [ "$EXISTING_PUBLIC_BASE_URL" != "$PUBLIC_BASE_URL" ]; then
  warn "$ENV_FILE's PUBLIC_BASE_URL ($EXISTING_PUBLIC_BASE_URL) differs from https://$API_DOMAIN (derived from --domain/--api-domain); leaving your value in place, but Caddy is about to request a certificate for $API_DOMAIN specifically, make sure that's intentional."
  PUBLIC_BASE_URL="$EXISTING_PUBLIC_BASE_URL"
fi

# Narrows the admin API's CORS policy to the actual admin subdomain instead
# of also inheriting the widget's deliberately permissive wildcard; only
# injected when the pasted .env doesn't already set it.
if [ -z "$(env_value ADMIN_CORS_ORIGINS "$ENV_FILE")" ]; then
  inject_env_var ADMIN_CORS_ORIGINS "[\"https://$ADMIN_DOMAIN\"]" "$ENV_FILE"
fi

SECRET_KEY_GENERATED=0
SECRET_KEY="$(env_value SECRET_KEY "$ENV_FILE")"
if [ -z "$SECRET_KEY" ] || [ "$SECRET_KEY" = "change-me-to-a-random-32-byte-string" ]; then
  if [ "$ENV_FILE_IS_FRESH" -eq 1 ]; then
    SECRET_KEY="$(gen_secret)"
    inject_env_var SECRET_KEY "$SECRET_KEY" "$ENV_FILE"
    SECRET_KEY_GENERATED=1
  else
    die "$ENV_FILE has no SECRET_KEY; pass --force to replace it (you'll be prompted to paste a fresh one)."
  fi
fi

# Always applied, even against an existing .env left untouched above, so
# --version takes effect on every run: read by docker-compose.caddy.yml's
# ${AIFLOW_VERSION:-2} image tag interpolation, not by the application itself.
inject_env_var AIFLOW_VERSION "$VERSION" "$ENV_FILE"

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

log "Starting containers (backend, admin, caddy)..."
if ! up_out="$(docker compose "${COMPOSE_ARGS[@]}" up -d 2>&1)"; then
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
  docker compose "${COMPOSE_ARGS[@]}" logs --tail=30 caddy || true
  docker compose "${COMPOSE_ARGS[@]}" logs --tail=30 backend || true
  die "Deployment failed health check. Common causes: DNS not yet propagated, or the cloud firewall/security group is blocking inbound 80/443."
fi
log "Backend is healthy over HTTPS."

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
