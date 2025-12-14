#!/usr/bin/env bash
set -Eeuo pipefail

############################################
# Tailscale inside container (userspace)
# - Downloads static Tailscale binary if missing
# - Starts tailscaled (userspace networking)
# - Runs tailscale up using Auth Key
# - Graceful shutdown on SIGINT/SIGTERM
############################################

# --------- Logging helpers ----------
log()  { printf '%s %s\n' "[$(date +'%Y-%m-%d %H:%M:%S')]" "$*"; }
warn() { printf '%s %s\n' "[$(date +'%Y-%m-%d %H:%M:%S')] [WARN]" "$*" >&2; }
die()  { printf '%s %s\n' "[$(date +'%Y-%m-%d %H:%M:%S')] [ERROR]" "$*" >&2; exit 1; }

# --------- Config (env overrides) ----------
WORKDIR="${WORKDIR:-/home/container}"
TS_VERSION="${TS_VERSION:-1.82.5}"

# Required
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

# Optional (recommended to override from panel variables)
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-josh-bam}"
TAILSCALE_ENABLE_SSH="${TAILSCALE_ENABLE_SSH:-true}"          # true/false
TAILSCALE_EXIT_NODE="${TAILSCALE_EXIT_NODE:-false}"           # true/false
TAILSCALE_ADVERTISE_TAGS="${TAILSCALE_ADVERTISE_TAGS:-tag:container}"  # set "" to disable tags
TAILSCALE_SOCKS5_ADDR="${TAILSCALE_SOCKS5_ADDR:-127.0.0.1:1055}"

# Advanced
TAILSCALE_STATE_FILE="${TAILSCALE_STATE_FILE:-tailscaled.state}"
TAILSCALE_SOCKET_FILE="${TAILSCALE_SOCKET_FILE:-tailscaled.sock}"

# --------- Ensure working directory ----------
cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

# --------- Cleanup handler ----------
TAILSCALED_PID=""
cleanup() {
  local code=$?
  warn "Shutting down (exit code: $code)..."

  # Run stop hook if exists (optional)
  if [[ -x "$WORKDIR/stop.sh" ]]; then
    warn "Running stop.sh..."
    bash "$WORKDIR/stop.sh" || true
  fi

  # Stop tailscaled if running
  if [[ -n "${TAILSCALED_PID:-}" ]] && kill -0 "$TAILSCALED_PID" 2>/dev/null; then
    warn "Stopping tailscaled (pid=$TAILSCALED_PID)..."
    kill "$TAILSCALED_PID" 2>/dev/null || true
    wait "$TAILSCALED_PID" 2>/dev/null || true
  fi

  exit "$code"
}
trap cleanup SIGINT SIGTERM EXIT

# --------- Validate required vars ----------
[[ -n "$TAILSCALE_AUTH_KEY" ]] || die "TAILSCALE_AUTH_KEY is not set. Use an Auth Key (tskey-auth-...), not an API key."

# --------- Detect architecture ----------
detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv6l|armv5l|arm) echo "arm" ;;
    i386|i686) echo "386" ;;
    *)
      warn "Unknown arch '$m', defaulting to amd64"
      echo "amd64"
      ;;
  esac
}
ARCH="$(detect_arch)"

# --------- Download & extract Tailscale tarball ----------
TARBALL="tailscale_${TS_VERSION}_${ARCH}.tgz"
TS_DIR="tailscale_${TS_VERSION}_${ARCH}"
TS_URL="https://pkgs.tailscale.com/stable/${TARBALL}"

download_tailscale() {
  log "Downloading Tailscale ${TS_VERSION} for ${ARCH}..."
  command -v curl >/dev/null 2>&1 || die "curl is not installed."
  curl -fsSL "$TS_URL" -o "$TARBALL" || die "Failed to download: $TS_URL"

  rm -rf "$TS_DIR"
  mkdir -p "$TS_DIR"
  tar -xzf "$TARBALL" -C "$TS_DIR" --strip-components=1 || die "Failed to extract $TARBALL"
  log "Tailscale extracted to: $WORKDIR/$TS_DIR"
}

if [[ ! -d "$TS_DIR" ]] || [[ ! -x "$TS_DIR/tailscaled" ]] || [[ ! -x "$TS_DIR/tailscale" ]]; then
  download_tailscale
else
  log "Using existing Tailscale dir: $WORKDIR/$TS_DIR"
fi

cd "$TS_DIR" || die "Cannot cd to $WORKDIR/$TS_DIR"

# --------- Start tailscaled (userspace) ----------
log "Starting tailscaled (userspace networking)..."
./tailscaled \
  --tun=userspace-networking \
  --state="$TAILSCALE_STATE_FILE" \
  --socket="$TAILSCALE_SOCKET_FILE" \
  --socks5-server="$TAILSCALE_SOCKS5_ADDR" &

TAILSCALED_PID="$!"
sleep 2

# Basic check
if ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
  die "tailscaled failed to start."
fi

# --------- Build tailscale up args ----------
UP_ARGS=( "--socket=$TAILSCALE_SOCKET_FILE" "up" "--auth-key=$TAILSCALE_AUTH_KEY" "--hostname=$TAILSCALE_HOSTNAME" )

# Enable SSH
if [[ "$TAILSCALE_ENABLE_SSH" == "true" ]]; then
  UP_ARGS+=( "--ssh" )
fi

# Advertise tags (only if non-empty)
if [[ -n "${TAILSCALE_ADVERTISE_TAGS}" ]]; then
  UP_ARGS+=( "--advertise-tags=$TAILSCALE_ADVERTISE_TAGS" )
fi

# Exit node (only if true)
if [[ "$TAILSCALE_EXIT_NODE" == "true" ]]; then
  UP_ARGS+=( "--advertise-exit-node" )
fi

log "Running: tailscale up (hostname=$TAILSCALE_HOSTNAME, ssh=$TAILSCALE_ENABLE_SSH, tags='${TAILSCALE_ADVERTISE_TAGS}', exitnode=$TAILSCALE_EXIT_NODE)"
./tailscale "${UP_ARGS[@]}" || die "tailscale up failed. (If tags error: define tagOwners in ACL or set TAILSCALE_ADVERTISE_TAGS='')"

# --------- Show status ----------
log "Tailscale status:"
./tailscale --socket="$TAILSCALE_SOCKET_FILE" status || true

log "Tailscale is up. Tailscaled PID=$TAILSCALED_PID"
wait "$TAILSCALED_PID"
