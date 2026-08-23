#!/usr/bin/env bash
# Installs self-hosted Coolify and stages everything needed to finish the
# deploy from its dashboard. Coolify's first-run root-user setup only
# happens in the browser, with nothing scriptable to hook into, so this
# script installs Coolify and hands off with exact next steps instead of
# pretending it can automate that part too.
#
# Usage:
#   curl -fsSL \
#     https://raw.githubusercontent.com/maelqo/scripts/main/aiflow/deploy-coolify.sh \
#     | sudo bash

set -euo pipefail
trap 'err "failed at line $LINENO (exit $?)"' ERR


REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/maelqo/scripts}"
REPO_REF="main"
DIR="./aiflow"
SKIP_INSTALL=0
FORCE_REINSTALL=0
FORCE=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: deploy-coolify.sh [options]

Installs self-hosted Coolify and prints the exact
manual dashboard steps to finish deploying AiFlow on it.

All application configuration is staged locally in aiflow/coolify.env,
not passed as flags. If that file doesn't already exist, this script
prompts you to paste one in (Ctrl+D to finish); write it yourself
beforehand for non-interactive use. This file is only ever read by
this script; Coolify itself never sees it directly.

Options:
  --skip-install          Already have Coolify, just print the reference block and steps
  --force-reinstall       Re-run the installer even if Coolify looks present
  --gemini-api-key KEY    GEMINI_API_KEY
  --admin-email EMAIL     AIFLOW_ADMIN_EMAIL (pre-fills the printed create_admin command)
  --license-tier TIER     demo|trial|basic|pro|enterprise (default: demo, needs no key)
  --license-key KEY       AIFLOW_LICENSE_KEY (required for any tier but demo)
  --domain ROOT           derives api.ROOT and admin.ROOT
  --api-domain ...        AIFLOW_API_DOMAIN (instead of --domain)
  --admin-domain ...      AIFLOW_ADMIN_DOMAIN (instead of --domain)
  --ghcr-username USER    GHCR_USERNAME (AiFlow's GHCR account)
  --ghcr-token TOKEN      GHCR_TOKEN (the read-only PAT issued for this client)
  --dir PATH              Where to save the local docker-compose.coolify.yml and
                          coolify.env copies (default: ./aiflow)
  --repo-ref REF          Git ref to fetch companion files from (default: main)
  --force                 Overwrite an existing coolify.env instead of leaving it alone
  --env-help              Print every .env variable (with defaults and notes) and exit;
                          doesn't install or deploy anything
  -h, --help              Show this help
EOF
}

GEMINI_API_KEY_FLAG="${GEMINI_API_KEY:-}"
ADMIN_EMAIL="${AIFLOW_ADMIN_EMAIL:-}"
LICENSE_TIER="${AIFLOW_LICENSE_TIER:-demo}"
LICENSE_KEY="${AIFLOW_LICENSE_KEY:-}"
DOMAIN=""
API_DOMAIN="${AIFLOW_API_DOMAIN:-}"
ADMIN_DOMAIN="${AIFLOW_ADMIN_DOMAIN:-}"
GHCR_USERNAME="${GHCR_USERNAME:-}"
GHCR_TOKEN="${GHCR_TOKEN:-}"
ENV_HELP=0

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-install) SKIP_INSTALL=1; shift ;;
    --force-reinstall) FORCE_REINSTALL=1; shift ;;
    --gemini-api-key) GEMINI_API_KEY_FLAG="$2"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --license-tier) LICENSE_TIER="$2"; shift 2 ;;
    --license-key) LICENSE_KEY="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --api-domain) API_DOMAIN="$2"; shift 2 ;;
    --admin-domain) ADMIN_DOMAIN="$2"; shift 2 ;;
    --ghcr-username) GHCR_USERNAME="$2"; shift 2 ;;
    --ghcr-token) GHCR_TOKEN="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --repo-ref) REPO_REF="$2"; shift 2 ;;
    --force) FORCE=1; shift ;;
    --env-help) ENV_HELP=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

# Users sometimes paste a full URL where a bare domain is expected. Left
# unstripped, `PUBLIC_BASE_URL` further down would end up doubled, as
# `https://https://...`, broken with nothing around to flag it.
normalize_domain() {
  local original="$1" value="$1"
  value="${value#http://}"
  value="${value#https://}"
  value="${value%%/*}"
  if [ "$value" != "$original" ] && [ -n "$original" ]; then
    warn "Using bare domain '$value' (stripped the protocol and path from '$original'); "\
"--domain, --api-domain, and --admin-domain expect a bare domain, not a full URL."
  fi
  printf '%s' "$value"
}
DOMAIN="$(normalize_domain "$DOMAIN")"
API_DOMAIN="$(normalize_domain "$API_DOMAIN")"
ADMIN_DOMAIN="$(normalize_domain "$ADMIN_DOMAIN")"

case "$LICENSE_TIER" in
  demo|trial|basic|pro|enterprise) : ;;
  *) die "--license-tier must be one of: demo, trial, basic, pro, enterprise "\
"(got '$LICENSE_TIER')." ;;
esac
if [ "$LICENSE_TIER" != "demo" ] && [ -z "$LICENSE_KEY" ]; then
  die "--license-tier $LICENSE_TIER requires --license-key "\
"(copy it from your MeridFlow dashboard)."
fi

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

# Fills in KEY only when the env file doesn't already set it, so anything
# the user pasted in by hand always beats a `--flag` convenience default.
inject_env_var_if_blank() {
  local key="$1" value="$2" file="$3"
  [ -n "$value" ] || return 0
  [ -z "$(env_value "$key" "$file")" ] || return 0
  inject_env_var "$key" "$value" "$file"
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
    cp "$SCRIPT_DIR/config/$rel" "$dest"
  elif [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/../$rel" ]; then
    cp "$SCRIPT_DIR/../$rel" "$dest"
  else
    curl -fsSL "$REPO_RAW_BASE/$REPO_REF/aiflow/config/$rel" -o "$dest"
  fi
}

# `--env-help` just prints `.env.example`, the canonical list of variables
# the backend reads, then exits without installing or deploying anything.
# This runs before the root and Linux checks further down, since printing
# that list needs neither.
if [ "$ENV_HELP" -eq 1 ]; then
  ENV_EXAMPLE_TMP="$(mktemp)"
  fetch_file ".env.example" "$ENV_EXAMPLE_TMP"
  echo "Every variable AiFlow's backend reads, with defaults and notes."
  echo "Coolify has no .env file of its own; these get pasted into its dashboard UI"
  echo "instead, see step 3 of this script's normal output."
  echo
  cat "$ENV_EXAMPLE_TMP"
  rm -f "$ENV_EXAMPLE_TMP"
  exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
  die "This script must run as root (Coolify's own installer requires it). "\
"Re-run with sudo."
fi
if [ "$(uname -s)" != "Linux" ]; then
  die "Coolify only supports Linux hosts."
fi

arch="$(uname -m)"
case "$arch" in
  x86_64|aarch64|arm64) : ;;
  *) warn "Unrecognized architecture ($arch), Coolify officially supports "\
"amd64/arm64. Continuing anyway." ;;
esac

mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_gb=$((mem_kb / 1024 / 1024))
disk_gb="$(df -Pk / | awk 'NR==2 {print int($4/1024/1024)}')"
cpus="$(nproc 2>/dev/null || echo 1)"
if [ "$mem_gb" -lt 2 ] || [ "$disk_gb" -lt 30 ] || [ "$cpus" -lt 2 ]; then
  warn "This host looks below Coolify's documented minimum "\
"(2 vCPU / 2GB RAM / 30GB free disk)."
  warn "Detected: ${cpus} vCPU, ${mem_gb}GB RAM, ${disk_gb}GB free disk. "\
"Continuing anyway, but expect it to struggle."
fi

already_installed=0
if command -v coolify >/dev/null 2>&1 \
  || docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^coolify'; then
  already_installed=1
fi

if [ "$SKIP_INSTALL" -eq 1 ]; then
  log "Skipping install (--skip-install)."
elif [ "$already_installed" -eq 1 ] && [ "$FORCE_REINSTALL" -ne 1 ]; then
  log "Coolify already looks installed, skipping (pass --force-reinstall "\
"to re-run the installer anyway)."
else
  log "Installing Coolify (this runs Coolify's own official installer)..."
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
fi

log "Waiting for the Coolify dashboard to come up (image pulls can take a "\
"few minutes)..."
up=0
for _ in $(seq 1 60); do
  if curl -fsS "http://localhost:8000" >/dev/null 2>&1; then
    up=1
    break
  fi
  sleep 5
done
if [ "$up" -ne 1 ]; then
  warn "Coolify's dashboard isn't responding on :8000 yet. Check 'docker "\
"ps' and the installer's own output; it may just need more time."
fi

mkdir -p "$DIR"
fetch_file "docker-compose.coolify.yml" "$DIR/docker-compose.coolify.yml" \
  || warn "Could not fetch docker-compose.coolify.yml, paste it from this repo manually."
fetch_file ".env.example" "$DIR/.env.example" \
  || warn "Could not fetch .env.example, see this repo's copy manually."

if [ -n "$GHCR_TOKEN" ]; then
  [ -n "$GHCR_USERNAME" ] || die "--ghcr-token given without --ghcr-username."
  log "Logging in to ghcr.io as $GHCR_USERNAME (on this host, so Coolify's "\
"own deployments can reuse it)..."
  printf '%s' "$GHCR_TOKEN" | docker login ghcr.io -u "$GHCR_USERNAME" --password-stdin
  log "Coolify mounts this host's docker credential store into its "\
"deployment containers, so no separate registry step is needed in its UI "\
"for this image."
fi

if [ -z "$API_DOMAIN" ] && [ -n "$DOMAIN" ]; then API_DOMAIN="api.$DOMAIN"; fi
if [ -z "$ADMIN_DOMAIN" ] && [ -n "$DOMAIN" ]; then ADMIN_DOMAIN="admin.$DOMAIN"; fi

ENV_FILE="$DIR/coolify.env"
if [ -f "$ENV_FILE" ] && [ "$FORCE" -ne 1 ]; then
  log "$ENV_FILE already exists, leaving it untouched (pass --force to replace it)."
else
  if [ -f "$ENV_FILE" ]; then
    cp "$ENV_FILE" "$ENV_FILE.bak.$(date +%s)"
    log "Replacing $ENV_FILE (backed up first)."
  else
    log "No $ENV_FILE yet."
  fi
  echo "See $DIR/.env.example for the full list of variables. This file is a"
  echo "local staging copy only, step 3 below prints it back for you to paste"
  echo "into Coolify's own dashboard, Coolify never reads this file directly."
  echo "Paste your intended env contents below, then press Ctrl+D when done:"
  echo
  # Write to a temp file first and move it into place only once that
  # succeeds. A bare `cat >"$ENV_FILE" </dev/tty` truncates `$ENV_FILE`
  # through its `>` redirection before `</dev/tty` even gets a chance to
  # fail, which would wipe out an existing file on a failed or no-tty
  # attempt.
  ENV_FILE_TMP="$ENV_FILE.paste.tmp.$$"
  if ! cat >"$ENV_FILE_TMP" </dev/tty; then
    rm -f "$ENV_FILE_TMP"
    die "Could not read from a terminal to paste into. If running "\
"non-interactively, write $ENV_FILE yourself before running this script."
  fi
  mv "$ENV_FILE_TMP" "$ENV_FILE"
  echo
  log "Saved $ENV_FILE."
fi

inject_env_var_if_blank GEMINI_API_KEY "$GEMINI_API_KEY_FLAG" "$ENV_FILE"
[ -n "$API_DOMAIN" ] \
  && inject_env_var_if_blank PUBLIC_BASE_URL "https://$API_DOMAIN" "$ENV_FILE"

# `--license-tier demo`, the default, needs no key because AiFlow already
# defaults to demo mode. Any other tier already forced a real key further
# up, so pre-fill both here. A value already pasted into `coolify.env`
# still takes priority.
if [ -n "$LICENSE_KEY" ]; then
  inject_env_var_if_blank AIFLOW_MODE "live" "$ENV_FILE"
  inject_env_var_if_blank AIFLOW_LICENSE_KEY "$LICENSE_KEY" "$ENV_FILE"
fi

SECRET_KEY="$(env_value SECRET_KEY "$ENV_FILE")"
if [ -z "$SECRET_KEY" ] \
  || [ "$SECRET_KEY" = "change-me-to-a-random-32-byte-string" ]; then
  inject_env_var SECRET_KEY "$(gen_secret)" "$ENV_FILE"
fi

SUGGESTED_PASSWORD="$(gen_password)"
server_ip="$(curl -fsS https://api.ipify.org 2>/dev/null || echo '<server-ip>')"
db_url_hint="DATABASE_URL=postgresql+asyncpg://"\
"\$POSTGRES_USER:\$POSTGRES_PASSWORD@postgres:5432/\$POSTGRES_DB"

echo
log "Coolify install step done. The rest happens in its dashboard."
echo
echo "Next steps:"
echo "  1. Visit http://${server_ip}:8000 and complete the one-time root user setup."
echo "  2. New Resource -> Docker Compose -> paste the contents of"
echo "     $DIR/docker-compose.coolify.yml"
echo "  3. Set these environment variables in Coolify's UI (not as a local .env file),"
echo "     from $ENV_FILE:"
echo
grep -v '^[[:space:]]*#' "$ENV_FILE" | grep -v '^[[:space:]]*$' | sed 's/^/       /'
echo
echo "     (DATABASE_URL defaults to SQLite if left unset; to use Postgres"
echo "      instead, either point it at a Postgres instance you already run, or"
echo "      paste docker-compose.postgres.yml's own 'postgres:' service block"
echo "      into this same Compose resource and set"
echo "      $db_url_hint"
echo "      plus POSTGRES_USER, POSTGRES_PASSWORD, and POSTGRES_DB, to opt into"
echo "      the bundled container)"
echo "  4. Under each service's Domains and Ports tab, attach:"
if [ -n "${API_DOMAIN:-}" ] && [ -n "${ADMIN_DOMAIN:-}" ]; then
  echo "       backend -> $API_DOMAIN  (routes to the container's internal port 8000)"
  echo "       admin   -> $ADMIN_DOMAIN  (routes to the container's internal port 8080)"
else
  echo "       backend -> your api subdomain (e.g. api.client-domain.com),"
  echo "       internal port 8000"
  echo "       admin   -> your admin subdomain (e.g. admin.client-domain.com),"
  echo "       internal port 8080"
fi
echo "     Coolify provisions and renews Let's Encrypt certificates"
echo "     automatically, no separate proxy step."
echo "  5. Deploy."
echo "  6. Create the first admin user via the backend service's 'Execute"
echo "     Command' action in Coolify:"
echo "       python -m scripts.create_admin" \
  "${ADMIN_EMAIL:-owner@client-domain.com} '$SUGGESTED_PASSWORD'"
echo "     (that suggested password is just a random default, not written"
echo "     anywhere; use your own if you prefer)"
echo
