#!/usr/bin/env bash
# Pulls AiFlow's pre-built images and brings them up with Docker Compose.
#
# Usage:
#   curl -fsSL \
#     https://raw.githubusercontent.com/maelqo/scripts/main/aiflow/deploy-compose.sh \
#     | bash
#
# Flags:
#   curl -fsSL \
#     https://raw.githubusercontent.com/maelqo/scripts/main/aiflow/deploy-compose.sh \
#     | bash -s -- --admin-email owner@client.com -y
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
This script doesn't set up a reverse proxy or TLS.

All application configuration lives in .env, not in flags. If
./aiflow/.env does not exist, this script asks you to paste one in and
finish with Ctrl+D. Write it yourself first to run this unattended.

Options:
  --admin-email EMAIL     AIFLOW_ADMIN_EMAIL (required; the first admin user's login)
  --admin-password PASS   AIFLOW_ADMIN_PASSWORD (auto-generated if omitted)
  --license-tier TIER     demo|trial|basic|pro|enterprise (default: demo, needs no key)
  --license-key KEY       AIFLOW_LICENSE_KEY (required for any tier but demo)
  --ghcr-username USER    GHCR_USERNAME (AiFlow's GHCR account)
  --ghcr-token TOKEN      GHCR_TOKEN (the read-only PAT issued for this client)
  --version TAG           AIFLOW_VERSION (default: 8)
  --postgres              Also start the bundled Postgres container. Override its
                          defaults with POSTGRES_USER, POSTGRES_PASSWORD, and
                          POSTGRES_DB in .env. To use a database you already run,
                          leave this flag off and set DATABASE_URL instead
  --install-docker        Install Docker via get.docker.com if missing
  --dir PATH              Deployment directory (default: ./aiflow)
  --repo-ref REF          Git ref to fetch companion files from (default: main)
  --force                 Overwrite an existing .env instead of leaving it alone
  --env-help              Print every .env variable, with defaults and notes,
                          then exit without deploying
  -y, --yes               Assume yes on confirmations
  -h, --help              Show this help
EOF
}

ADMIN_EMAIL="${AIFLOW_ADMIN_EMAIL:-}"
ADMIN_PASSWORD="${AIFLOW_ADMIN_PASSWORD:-}"
LICENSE_TIER="${AIFLOW_LICENSE_TIER:-demo}"
LICENSE_KEY="${AIFLOW_LICENSE_KEY:-}"
GHCR_USERNAME="${GHCR_USERNAME:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
VERSION="${AIFLOW_VERSION:-8}"
POSTGRES=0
ENV_HELP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --admin-password) ADMIN_PASSWORD="$2"; shift 2 ;;
    --license-tier) LICENSE_TIER="$2"; shift 2 ;;
    --license-key) LICENSE_KEY="$2"; shift 2 ;;
    --ghcr-username) GHCR_USERNAME="$2"; shift 2 ;;
    --ghcr-token) GHCR_TOKEN="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --postgres) POSTGRES=1; shift ;;
    --install-docker) INSTALL_DOCKER=1; shift ;;
    --dir) DIR="$2"; shift 2 ;;
    --repo-ref) REPO_REF="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --env-help) ENV_HELP=1; shift ;;
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
  # Opening `/dev/tty` can fail when there's no controlling terminal
  # attached. That must not abort the script under `set -e`, so treat a
  # failed open as a plain `no` and move on.
  read -r -p "$1 [y/N] " reply 2>/dev/null </dev/tty || true
  case "$reply" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# Looks up a `KEY=value` line in an env file and prints the value. Errors
# are swallowed so a missing key comes back as an empty string instead of
# tripping `set -e`, letting callers just check for blank.
env_value() {
  grep -m1 "^${1}=" "$2" 2>/dev/null | cut -d= -f2- || true
}

# Sets `KEY=VALUE` in an env file, replacing any line already using that
# key.
inject_env_var() {
  local key="$1" value="$2" file="$3"
  grep -v "^${key}=" "$file" >"$file.tmp" 2>/dev/null || true
  printf '%s=%s\n' "$key" "$value" >>"$file.tmp"
  mv "$file.tmp" "$file"
}

# Resolve this before any `cd` call. `BASH_SOURCE` is relative to the
# directory the script was invoked from, so it stops resolving correctly
# once we change directories.
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
    curl -fsSL --connect-timeout 10 --max-time 60 \
      "$REPO_RAW_BASE/$REPO_REF/aiflow/config/$rel" -o "$dest" \
      || die "Failed to download $rel (timed out or network error). "\
"Check this host can reach raw.githubusercontent.com over HTTPS "\
"(an outbound firewall or proxy), then re-run."
  fi
}

check_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    if [ "$INSTALL_DOCKER" -eq 1 ]; then
      log "Docker not found, installing via get.docker.com..."
      curl -fsSL https://get.docker.com | sh
    else
      die "Docker is not installed. Install it with 'curl -fsSL "\
"https://get.docker.com | sh', or re-run this script with --install-docker."
    fi
  fi
  docker compose version >/dev/null 2>&1 \
    || die "docker compose (the v2 plugin) is required; legacy docker-compose "\
"is not supported."
  docker_ping_out=""
  if ! docker_ping_out="$(docker info 2>&1 1>/dev/null)"; then
    if printf '%s' "$docker_ping_out" | grep -qiE 'permission denied'; then
      die "This user cannot reach the Docker socket. Either run "\
"'sudo usermod -aG docker \$USER && newgrp docker' and start again without "\
"sudo, or run the whole script as root."
    fi
  fi
}

# `--env-help` just prints `.env.example`, the canonical list of variables
# the backend reads, then exits without touching anything else.
if [ "$ENV_HELP" -eq 1 ]; then
  ENV_EXAMPLE_TMP="$(mktemp)"
  fetch_file ".env.example" "$ENV_EXAMPLE_TMP"
  echo "Every variable AiFlow's backend reads, with defaults and notes:"
  echo
  cat "$ENV_EXAMPLE_TMP"
  rm -f "$ENV_EXAMPLE_TMP"
  exit 0
fi

# A flag or env var value wins if set. Otherwise we prompt on a real tty,
# which still works under `curl | bash` when one is attached. A failed
# `/dev/tty` open is swallowed here instead of aborting under `set -e`.
# The `die` call further down catches anything still missing.
[ -n "$ADMIN_EMAIL" ] \
  || read -r -p "Admin email: " ADMIN_EMAIL 2>/dev/null </dev/tty || true
[ -n "$ADMIN_EMAIL" ] || die "Missing --admin-email (or AIFLOW_ADMIN_EMAIL)."

case "$LICENSE_TIER" in
  demo|trial|basic|pro|enterprise) : ;;
  *) die "--license-tier must be one of: demo, trial, basic, pro, enterprise "\
"(got '$LICENSE_TIER')." ;;
esac
if [ "$LICENSE_TIER" != "demo" ] && [ -z "$LICENSE_KEY" ]; then
  die "--license-tier $LICENSE_TIER also needs --license-key. Copy the key "\
"from your MeridFlow dashboard."
fi

# Pulls `max_ver` out of a licence key's payload without checking its
# signature: plain bash has no practical way to verify an Ed25519
# signature, and the real check happens at boot anyway. This is only a
# best-effort, install-time sanity check, so a `--version` that doesn't
# match the licence gets caught immediately with a clear message instead
# of surfacing later. A forged key would still fail signature verification
# at boot no matter what it claims here.
license_max_version() {
  local key="$1" payload_b64 payload_std padded json
  payload_b64="$(printf '%s' "$key" | cut -d. -f3)"
  [ -n "$payload_b64" ] || return 1
  payload_std="$(printf '%s' "$payload_b64" | tr '_-' '/+')"
  case $((${#payload_std} % 4)) in
    2) padded="${payload_std}==" ;;
    3) padded="${payload_std}=" ;;
    *) padded="$payload_std" ;;
  esac
  json="$(printf '%s' "$padded" | base64 -d 2>/dev/null)" || return 1
  printf '%s' "$json" | grep -o '"max_ver":[0-9]*' | grep -o '[0-9]*$'
}

if [ -n "$LICENSE_KEY" ]; then
  REQUESTED_MAJOR="$VERSION"
  case "$VERSION" in
    *.*) REQUESTED_MAJOR="${VERSION%%.*}" ;;
  esac
  if ! printf '%s' "$REQUESTED_MAJOR" | grep -qE '^[0-9]+$'; then
    REQUESTED_MAJOR=""
  fi
  if [ -n "$REQUESTED_MAJOR" ]; then
    MAX_VER="$(license_max_version "$LICENSE_KEY" || true)"
    if [ -n "$MAX_VER" ] && [ "$REQUESTED_MAJOR" -gt "$MAX_VER" ]; then
      die "--version $VERSION is major $REQUESTED_MAJOR, but this licence "\
"only activates up to major $MAX_VER. Pass an older --version, or upgrade "\
"the licence. As it stands, AiFlow would start in demo mode."
    fi
  else
    warn "Could not check --version $VERSION against the licence, because "\
"it is not a plain X or X.Y.Z tag. If it turns out to be a newer major "\
"than the licence allows, AiFlow will start in demo mode."
  fi
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
fetch_file ".env.example" ".env.example"

if [ "$POSTGRES" -eq 1 ]; then
  fetch_file "docker-compose.postgres.yml" "docker-compose.postgres.yml"
  COMPOSE_ARGS+=(-f "docker-compose.postgres.yml")
fi

ENV_FILE=".env"
ENV_FILE_IS_FRESH=1
if [ -f "$ENV_FILE" ] && [ "$FORCE" -ne 1 ]; then
  log "$ENV_FILE already exists, leaving it untouched (pass --force to replace it)."
  ENV_FILE_IS_FRESH=0
else
  if [ -f "$ENV_FILE" ]; then
    confirm "Overwrite existing $ENV_FILE?" \
      || die "Aborted, existing $ENV_FILE left untouched."
    cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)"
    log "Replacing $ENV_FILE (backed up first)."
  else
    log "No $ENV_FILE yet."
  fi
  echo "See $DIR/.env.example for the full list of variables."
  echo "Paste your .env contents below, then press Ctrl+D when done:"
  echo
  # Write to a temp file first and move it into place only once that
  # succeeds. A bare `cat >"$ENV_FILE" </dev/tty` truncates `$ENV_FILE`
  # through its `>` redirection before `</dev/tty` even gets a chance to
  # fail, which would wipe out an existing file on a failed or no-tty
  # attempt.
  ENV_FILE_TMP="$ENV_FILE.paste.tmp.$$"
  if ! cat >"$ENV_FILE_TMP" </dev/tty; then
    rm -f "$ENV_FILE_TMP"
    die "There is no terminal to paste into. Write $DIR/$ENV_FILE yourself "\
"before running this script unattended."
  fi
  mv "$ENV_FILE_TMP" "$ENV_FILE"
  echo
  log "Saved $ENV_FILE."
fi

GEMINI_API_KEY="$(env_value GEMINI_API_KEY "$ENV_FILE")"
[ -n "$GEMINI_API_KEY" ] \
  || die "GEMINI_API_KEY is missing or blank in $DIR/$ENV_FILE. Add it and "\
"re-run."

PUBLIC_BASE_URL="$(env_value PUBLIC_BASE_URL "$ENV_FILE")"
[ -n "$PUBLIC_BASE_URL" ] \
  || die "PUBLIC_BASE_URL is missing or blank in $DIR/$ENV_FILE. Add it "\
"(your backend's real public HTTPS URL) and re-run."

SECRET_KEY_GENERATED=0
SECRET_KEY="$(env_value SECRET_KEY "$ENV_FILE")"
if [ -z "$SECRET_KEY" ] \
  || [ "$SECRET_KEY" = "change-me-to-a-random-32-byte-string" ]; then
  if [ "$ENV_FILE_IS_FRESH" -eq 1 ]; then
    SECRET_KEY="$(gen_secret)"
    inject_env_var SECRET_KEY "$SECRET_KEY" "$ENV_FILE"
    SECRET_KEY_GENERATED=1
  else
    die "$ENV_FILE has no SECRET_KEY. Pass --force to replace the file. You "\
"will be asked to paste a new one."
  fi
fi

# Written even into an existing `.env` left untouched above, so `--version`
# takes effect on every run. This only picks the image tag to pull. The
# application itself never reads it.
inject_env_var AIFLOW_VERSION "$VERSION" "$ENV_FILE"

# The licence gets the same treatment: `--license-tier demo`, the default,
# needs no key because AiFlow already defaults to demo mode. Any other
# tier already forced a real key further up, so write both values here.
if [ -n "$LICENSE_KEY" ]; then
  inject_env_var AIFLOW_MODE "live" "$ENV_FILE"
  inject_env_var AIFLOW_LICENSE_KEY "$LICENSE_KEY" "$ENV_FILE"
fi

if [ -n "$GHCR_TOKEN" ]; then
  [ -n "$GHCR_USERNAME" ] || die "--ghcr-token given without --ghcr-username."
  log "Logging in to ghcr.io as $GHCR_USERNAME"
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
fi

log "Pulling images..."
if ! pull_out="$(docker compose "${COMPOSE_ARGS[@]}" pull 2>&1)"; then
  printf '%s\n' "$pull_out" >&2
  if printf '%s' "$pull_out" | grep -qiE 'permission denied' \
    && printf '%s' "$pull_out" \
      | grep -qiE 'docker\.sock|daemon socket|connect to the docker'; then
    die "Docker refused the socket, so this is not a registry problem. "\
"Either run 'sudo usermod -aG docker \$USER && newgrp docker' and start "\
"again without sudo, or run the whole script as root."
  fi
  if printf '%s' "$pull_out" | grep -qiE 'unauthorized|denied'; then
    die "The registry refused the pull. If the images are private, pass "\
"both --ghcr-username and --ghcr-token."
  fi
  if printf '%s' "$pull_out" | grep -qiE \
    -e 'cannot connect to the docker daemon' \
    -e 'daemon is not running' \
    -e 'dockerDesktopLinuxEngine'; then
    die "The Docker daemon is not running. Start Docker, then run this again."
  fi
  die "docker compose pull failed."
fi

log "Starting containers..."
if ! up_out="$(docker compose "${COMPOSE_ARGS[@]}" up -d 2>&1)"; then
  printf '%s\n' "$up_out" >&2
  if printf '%s' "$up_out" \
    | grep -qiE 'port is already allocated|address already in use'; then
    die "Port 8000 or 5173 is already taken on this host. Free it, then run "\
"this again."
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
  err "The backend did not answer in time."
  docker compose "${COMPOSE_ARGS[@]}" logs --tail=50 backend || true
  die "The deployment failed its health check. The backend log above "\
"should say why."
fi
log "Backend is healthy."

log "Creating admin user $ADMIN_EMAIL..."
if ! admin_out="$(docker compose "${COMPOSE_ARGS[@]}" exec -T backend \
  python -m scripts.create_admin "$ADMIN_EMAIL" "$ADMIN_PASSWORD" < /dev/null 2>&1)"; then
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
echo "  Admin public URL:    proxy your admin subdomain to this host's"
echo "                       localhost:5173"
if [ "$admin_already_existed" -eq 1 ]; then
  echo "  Admin user:           $ADMIN_EMAIL (already existed, password unchanged)"
elif [ "$ADMIN_PASSWORD_GENERATED" -eq 1 ]; then
  echo "  Admin user:           $ADMIN_EMAIL"
  echo "  Admin password:       $ADMIN_PASSWORD  (generated, shown once, save it now)"
else
  echo "  Admin user:           $ADMIN_EMAIL"
fi
if [ "$SECRET_KEY_GENERATED" -eq 1 ]; then
  echo "  A SECRET_KEY was generated and written to $DIR/$ENV_FILE."
  echo "  Back that file up; the key is not shown again."
fi
echo
echo "  Metrics stay off until you set METRICS_TOKEN in $DIR/$ENV_FILE."
echo "  Generate a token, then have your scraper send it as a bearer token:"
echo "      openssl rand -base64 32"
echo
warn "These ports serve plain HTTP and are not behind TLS yet."
warn "Put a reverse proxy in front, or run deploy-caddy.sh instead."
