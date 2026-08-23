#!/usr/bin/env bash
# One command, three deployment topologies. This script is the commercial
# front door for AiFlow installs, hosted at
# https://meridflow.com/downloads/install-aiflow.sh.
#
# Usage:
#   curl -fsSL https://meridflow.com/downloads/install-aiflow.sh | sudo bash -s -- \
#     --option compose|caddy|coolify \
#     --admin-email you@example.com \
#     --license-tier pro --license-key AIFLOW1.K1.... \
#     --api-domain api.client.com --admin-domain admin.client.com \
#     --install-docker
#
set -euo pipefail
trap 'err "failed at line $LINENO (exit $?)"' ERR

REPO_RAW_BASE="${REPO_RAW_BASE:-https://raw.githubusercontent.com/maelqo/scripts}"
REPO_REF="main"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mwarning:\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: install-aiflow.sh --option <compose|caddy|coolify> [options...]

--option picks the deployment topology; every other flag passes straight
through, unmodified, to that topology's own script (deploy-compose.sh,
deploy-caddy.sh, or deploy-coolify.sh). Each accepts its own flag set on
top of the common ones below (a plain Compose deployment doesn't need a
domain, and a Caddy one does), so see the exact, authoritative list for
the option you picked with:

    install-aiflow.sh --option caddy --help

Required:
  --option compose|caddy|coolify    Which deployment topology to run

Common flags every topology accepts:
  --admin-email EMAIL               The first admin user's login
  --license-tier TIER               demo|trial|basic|pro|enterprise (default: demo, needs
                                    no key)
  --license-key KEY                 From your MeridFlow dashboard; required for any tier
                                    but demo. The version you deploy is validated against
                                    this licence's highest activated major version; an
                                    incompatible --version is refused rather than silently
                                    falling back to demo at boot
  --version TAG                     Image tag to deploy. A real flag for --option
                                    compose or caddy; for --option coolify, Coolify is
                                    versioned from its own dashboard instead, so this
                                    prints a reminder rather than being forwarded as a
                                    script flag
  --install-docker                  Install Docker if missing (compose and caddy only;
                                    Coolify's own installer handles Docker itself)
  --env-help                        Print every .env variable (with defaults and notes)
                                    and exit; works with or without --option, doesn't
                                    deploy anything
  --repo-ref REF                    Git ref to fetch from (default: main)
  -h, --help                        Without --option, show this; with --option, forwards
                                    to that script's own --help instead

Options this script does NOT expose: --ghcr-username and --ghcr-token. AiFlow's
published images are public; a licence key is the only credential a
commercial install ever needs.
EOF
}

# Resolve this once, before any `cd`. This script's own code never
# changes directories, but the scripts it hands off to do, so resolving
# late would break. Same local-checkout-first, public-mirror-fallback
# pattern used below for a companion file, just applied here to a whole
# script.
SCRIPT_DIR=""
case "${BASH_SOURCE[0]:-}" in
  */*) SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd || true)" ;;
esac

fetch_companion_file() {
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

OPTION=""
VERSION=""
ENV_HELP=0
ARGS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --option) OPTION="$2"; shift 2 ;;
    --version) VERSION="$2"; ARGS+=("$1" "$2"); shift 2 ;;
    --repo-ref) REPO_REF="$2"; ARGS+=("$1" "$2"); shift 2 ;;
    --env-help) ENV_HELP=1; shift ;;
    -h|--help)
      if [ -z "$OPTION" ]; then usage; exit 0; fi
      ARGS+=("$1")
      shift
      ;;
    *) ARGS+=("$1"); shift ;;
  esac
done

# The answer here is identical no matter which `--option` you'd pick, one
# backend, one `.env`, so this can run before a topology is even chosen,
# unlike everything else in this script.
if [ "$ENV_HELP" -eq 1 ]; then
  ENV_EXAMPLE_TMP="$(mktemp)"
  fetch_companion_file ".env.example" "$ENV_EXAMPLE_TMP"
  echo "Every variable AiFlow's backend reads, with defaults and notes:"
  echo
  cat "$ENV_EXAMPLE_TMP"
  rm -f "$ENV_EXAMPLE_TMP"
  exit 0
fi

if [ -z "$OPTION" ]; then
  usage
  die "Missing required --option compose|caddy|coolify."
fi
case "$OPTION" in
  compose|caddy|coolify) : ;;
  *) die "--option must be one of: compose, caddy, coolify (got '$OPTION')." ;;
esac

# Coolify is versioned from its own dashboard, not through a script flag.
# Forwarding `--version` to it would just trigger an `Unknown option`
# failure there. Strip it out here and point the user at the right place
# instead.
if [ "$OPTION" = "coolify" ] && [ -n "$VERSION" ]; then
  FILTERED=()
  skip_next=0
  for arg in "${ARGS[@]}"; do
    if [ "$skip_next" -eq 1 ]; then
      skip_next=0
      continue
    fi
    if [ "$arg" = "--version" ]; then
      skip_next=1
      continue
    fi
    FILTERED+=("$arg")
  done
  ARGS=("${FILTERED[@]}")
  warn "--version isn't a deploy-coolify.sh flag; Coolify deployments are "\
"versioned from its own dashboard. After this script finishes, add "\
"AIFLOW_VERSION=$VERSION to the environment variables you paste into "\
"Coolify's UI in step 3 (or set it there directly)."
fi

SCRIPT_NAME="deploy-$OPTION.sh"

if [ -n "$SCRIPT_DIR" ] && [ -f "$SCRIPT_DIR/$SCRIPT_NAME" ]; then
  log "Using local $SCRIPT_NAME"
  TARGET="$SCRIPT_DIR/$SCRIPT_NAME"
else
  log "Fetching $SCRIPT_NAME from ref $REPO_REF"
  TARGET="$(mktemp)"
  curl -fsSL --connect-timeout 10 --max-time 60 \
    "$REPO_RAW_BASE/$REPO_REF/aiflow/$SCRIPT_NAME" -o "$TARGET" \
    || die "Failed to download $SCRIPT_NAME (timed out or network error). "\
"Check this host can reach raw.githubusercontent.com over HTTPS "\
"(an outbound firewall or proxy), then re-run."
fi

exec bash "$TARGET" "${ARGS[@]}"
