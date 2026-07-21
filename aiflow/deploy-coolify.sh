#!/usr/bin/env bash
# Installs self-hosted Coolify (a free, open-source PaaS) 
# and prepares everything needed to finish the deploy in its dashboard. 
# Coolify's first-run root-user creation is browser-only
# with no scriptable equivalent, so this script installs and hands off
# with exact next steps rather than faking full end-to-end automation.
#
# Usage (env vars):
#   curl -fsSL https://raw.githubusercontent.com/maelqo/scripts/main/aiflow/deploy-coolify.sh | sudo bash
#
# Usage (flags):
#   curl -fsSL https://raw.githubusercontent.com/maelqo/scripts/main/aiflow/deploy-coolify.sh \
#     | sudo bash -s -- --domain client.com --gemini-api-key ... --admin-email owner@client.com
set -euo pipefail
trap 'err "failed at line $LINENO (exit $?)"' ERR


REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/maelqo/scripts}"
REPO_REF="main"
DIR="./aiflow"
SKIP_INSTALL=0
FORCE_REINSTALL=0

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: deploy-coolify.sh [options]

Installs self-hosted Coolify and prints the exact
manual dashboard steps to finish deploying AiFlow on it.

Optional:
  --skip-install               Already have Coolify, just print the reference block/steps
  --force-reinstall            Re-run the installer even if Coolify looks present
  --gemini-api-key KEY         GEMINI_API_KEY        (pre-fills the printed block)
  --admin-email EMAIL          AIFLOW_ADMIN_EMAIL    (pre-fills the printed block)
  --domain ROOT                Derives api.ROOT / admin.ROOT for the printed block
  --dir PATH                   Where to save a local docker-compose.prod.yml copy (default: ./aiflow)
  --repo-ref REF               Git ref to fetch companion files from (default: main)
  -h, --help                   Show this help
EOF
}

GEMINI_API_KEY="${GEMINI_API_KEY:-}"
ADMIN_EMAIL="${AIFLOW_ADMIN_EMAIL:-}"
DOMAIN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --skip-install) SKIP_INSTALL=1; shift ;;
    --force-reinstall) FORCE_REINSTALL=1; shift ;;
    --gemini-api-key) GEMINI_API_KEY="$2"; shift 2 ;;
    --admin-email) ADMIN_EMAIL="$2"; shift 2 ;;
    --domain) DOMAIN="$2"; shift 2 ;;
    --dir) DIR="$2"; shift 2 ;;
    --repo-ref) REPO_REF="$2"; shift 2 ;;
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

# Resolved once, before any `cd`, since BASH_SOURCE is a path relative to
# the invocation directory and stops resolving correctly once we move.
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

if [ "$(id -u)" -ne 0 ]; then
  die "This script must run as root (Coolify's own installer requires it). Re-run with sudo."
fi
if [ "$(uname -s)" != "Linux" ]; then
  die "Coolify only supports Linux hosts."
fi

arch="$(uname -m)"
case "$arch" in
  x86_64|aarch64|arm64) : ;;
  *) warn "Unrecognized architecture ($arch), Coolify officially supports amd64/arm64. Continuing anyway." ;;
esac

mem_kb="$(awk '/MemTotal/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
mem_gb=$((mem_kb / 1024 / 1024))
disk_gb="$(df -Pk / | awk 'NR==2 {print int($4/1024/1024)}')"
cpus="$(nproc 2>/dev/null || echo 1)"
if [ "$mem_gb" -lt 2 ] || [ "$disk_gb" -lt 30 ] || [ "$cpus" -lt 2 ]; then
  warn "This host looks below Coolify's documented minimum (2 vCPU / 2GB RAM / 30GB free disk)."
  warn "Detected: ${cpus} vCPU, ${mem_gb}GB RAM, ${disk_gb}GB free disk. Continuing anyway, but expect it to struggle."
fi

already_installed=0
if command -v coolify >/dev/null 2>&1 || docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^coolify'; then
  already_installed=1
fi

if [ "$SKIP_INSTALL" -eq 1 ]; then
  log "Skipping install (--skip-install)."
elif [ "$already_installed" -eq 1 ] && [ "$FORCE_REINSTALL" -ne 1 ]; then
  log "Coolify already looks installed, skipping (pass --force-reinstall to re-run the installer anyway)."
else
  log "Installing Coolify (this runs Coolify's own official installer)..."
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
fi

log "Waiting for the Coolify dashboard to come up (image pulls can take a few minutes)..."
up=0
for _ in $(seq 1 60); do
  if curl -fsS "http://localhost:8000" >/dev/null 2>&1; then
    up=1
    break
  fi
  sleep 5
done
if [ "$up" -ne 1 ]; then
  warn "Coolify's dashboard isn't responding on :8000 yet. Check 'docker ps' and the installer's own output; it may just need more time."
fi

mkdir -p "$DIR"
fetch_file "docker-compose.prod.yml" "$DIR/docker-compose.prod.yml" || warn "Could not fetch docker-compose.prod.yml, paste it from this repo manually."

SECRET_KEY="$(gen_secret)"
SUGGESTED_PASSWORD="$(gen_password)"
[ -n "$DOMAIN" ] && API_DOMAIN="api.$DOMAIN" && ADMIN_DOMAIN="admin.$DOMAIN"

server_ip="$(curl -fsS https://api.ipify.org 2>/dev/null || echo '<server-ip>')"

echo
log "Coolify install step done. The rest happens in its dashboard (browser-only, cannot be scripted)."
echo
echo "Next steps:"
echo "  1. Visit http://${server_ip}:8000 and complete the one-time root user setup."
echo "  2. New Resource -> Docker Compose -> paste the contents of $DIR/docker-compose.prod.yml"
echo "  3. Set these environment variables in Coolify's UI (not as a local .env file):"
echo "       GEMINI_API_KEY=${GEMINI_API_KEY:-<fill in>}"
echo "       SECRET_KEY=$SECRET_KEY"
if [ -n "${API_DOMAIN:-}" ]; then
  echo "       PUBLIC_BASE_URL=https://$API_DOMAIN"
else
  echo "       PUBLIC_BASE_URL=<fill in, the backend's public HTTPS URL>"
fi
echo "       (add TWILIO_ACCOUNT_SID / TWILIO_AUTH_TOKEN / TWILIO_API_KEY_SID / TWILIO_API_KEY_SECRET if phone features are in scope)"
echo "  4. Under Domains, attach:"
if [ -n "${API_DOMAIN:-}" ] && [ -n "${ADMIN_DOMAIN:-}" ]; then
  echo "       backend -> $API_DOMAIN"
  echo "       admin   -> $ADMIN_DOMAIN"
else
  echo "       backend -> your api subdomain (e.g. api.client-domain.com)"
  echo "       admin   -> your admin subdomain (e.g. admin.client-domain.com)"
fi
echo "     Coolify provisions and renews Let's Encrypt certificates automatically, no separate proxy step."
echo "  5. Deploy."
echo "  6. Create the first admin user via the backend service's 'Execute Command' action in Coolify:"
echo "       python -m scripts.create_admin ${ADMIN_EMAIL:-owner@client-domain.com} '$SUGGESTED_PASSWORD'"
echo "     (that suggested password is just a random default, not written anywhere; use your own if you prefer)"
echo
if [ "$already_installed" -eq 1 ] && [ "$SKIP_INSTALL" -ne 1 ] && [ "$FORCE_REINSTALL" -ne 1 ]; then
  warn "Note: if AiFlow's own backend is also deployed on this same box via deploy-compose.sh, it defaults to port 8000 too, same as Coolify's dashboard. Move one of them off :8000 if you colocate them."
fi
