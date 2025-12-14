#!/usr/bin/env bash
set -Eeuo pipefail

############################################
# Tailscale inside container (userspace) - SAFE DEFAULTS
# - No tags by default (avoids ACL tagOwners errors)
# - No SSH by default (avoids missing host keys in containers)
# - Runs tailscaled in userspace and keeps the process alive
############################################

# ---------- Logging ----------
ts() { date +'%Y-%m-%d %H:%M:%S'; }
log()  { printf '[%s] %s\n' "$(ts)" "$*"; }
warn() { printf '[%s] [WARN] %s\n' "$(ts)" "$*" >&2; }
err()  { printf '[%s] [ERROR] %s\n' "$(ts)" "$*" >&2; }

die() { err "$*"; exit 1; }

# ---------- Config ----------
WORKDIR="${WORKDIR:-/home/container}"
TS_VERSION="${TS_VERSION:-1.82.5}"

# REQUIRED: must be Auth Key (tskey-auth-....)
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"

# Optional
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-ptero-ts}"
TAILSCALE_STATE_FILE="${TAILSCALE_STATE_FILE:-tailscaled.state}"
TAILSCALE_SOCKET_FILE="${TAILSCALE_SOCKET_FILE:-tailscaled.sock}"
TAILSCALE_SOCKS5_ADDR="${TAILSCALE_SOCKS5_ADDR:-127.0.0.1:1055}"

# SAFE DEFAULTS (change only if you know what you're doing)
TAILSCALE_ENABLE_SSH="${TAILSCALE_ENABLE_SSH:-false}"          # true/false
TAILSCALE_EXIT_NODE="${TAILSCALE_EXIT_NODE:-false}"            # true/false
TAILSCALE_ADVERTISE_TAGS="${TAILSCALE_ADVERTISE_TAGS:-}"       # EMPTY by default to avoid tag errors

# ---------- Working directory ----------
cd "$WORKDIR" || die "Cannot cd to $WORKDIR"

# ---------- Graceful shutdown ----------
TAILSCALED_PID=""

shutdown() {
  local code=$?
  warn "Shutting down (code=$code)..."

  # Stop tailscaled
  if [[ -n "${TAILSCALED_PID:-}" ]] && kill -0 "$TAILSCALED_PID" 2>/dev/null; then
    warn "Stopping tailscaled (pid=$TAILSCALED_PID)..."
    kill "$TAILSCALED_PID" 2>/dev/null || true
    wait "$TAILSCALED_PID" 2>/dev/null || true
  fi

  exit "$code"
}
trap shutdown SIGINT SIGTERM EXIT

# ---------- Validate auth key ----------
if [[ -z "$TAILSCALE_AUTH_KEY" ]]; then
  die "TAILSCALE_AUTH_KEY is not set. Use an Auth Key (starts with: tskey-auth-...), not an API key."
fi

# ---------- Detect architecture ----------
detect_arch() {
  case "$(uname -m)" in
    x86_64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    armv7l|armv6l|armv5l|arm) echo "arm" ;;
    i386|i686) echo "386" ;;
    *) warn "Unknown arch '$(uname -m)', defaulting to amd64"; echo "amd64" ;;
  esac
}
ARCH="$(detect_arch)"

# ---------- Download / Extract ----------
TARBALL="tailscale_${TS_VERSION}_${ARCH}.tgz"
TS_DIR="tailscale_${TS_VERSION}_${ARCH}"
TS_URL="https://pkgs.tailscale.com/stable/${TARBALL}"

download_tailscale() {
  log "Downloading Tailscale v${TS_VERSION} for ${ARCH}..."
  command -v curl >/dev/null 2>&1 || die "curl is required but not found."

  curl -fsSL "$TS_URL" -o "$TARBALL" || die "Failed to download $TS_URL"

  rm -rf "$TS_DIR"
  mkdir -p "$TS_DIR"
  tar -xzf "$TARBALL" -C "$TS_DIR" --strip-components=1 || die "Failed to extract $TARBALL"

  chmod +x "$TS_DIR/tailscale" "$TS_DIR/tailscaled" || true
  log "Extracted into: $WORKDIR/$TS_DIR"
}

if [[ ! -x "$TS_DIR/tailscale" || ! -x "$TS_DIR/tailscaled" ]]; then
  download_tailscale
else
  log "Using existing Tailscale dir: $WORKDIR/$TS_DIR"
fi

cd "$TS_DIR" || die "Cannot cd to $WORKDIR/$TS_DIR"

# ---------- Start tailscaled ----------
log "Starting tailscaled (userspace networking)..."
./tailscaled \
  --tun=userspace-networking \
  --state="$TAILSCALE_STATE_FILE" \
  --socket="$TAILSCALE_SOCKET_FILE" \
  --socks5-server="$TAILSCALE_SOCKS5_ADDR" &

TAILSCALED_PID="$!"

# Wait for socket to appear (up to ~10s)
for _ in {1..20}; do
  [[ -S "$TAILSCALE_SOCKET_FILE" ]] && break
  sleep 0.5
done

if [[ ! -S "$TAILSCALE_SOCKET_FILE" ]]; then
  die "tailscaled socket not found: $TAILSCALE_SOCKET_FILE"
fi

# ---------- Build tailscale up args ----------
UP_ARGS=( "--socket=$TAILSCALE_SOCKET_FILE" "up" "--auth-key=$TAILSCALE_AUTH_KEY" "--hostname=$TAILSCALE_HOSTNAME" )

# SSH (disabled by default)
if [[ "$TAILSCALE_ENABLE_SSH" == "true" ]]; then
  UP_ARGS+=( "--ssh" )
fi

# Tags (empty by default to avoid ACL errors)
if [[ -n "$TAILSCALE_ADVERTISE_TAGS" ]]; then
  UP_ARGS+=( "--advertise-tags=$TAILSCALE_ADVERTISE_TAGS" )
fi

# Exit node (off by default)
if [[ "$TAILSCALE_EXIT_NODE" == "true" ]]; then
  UP_ARGS+=( "--advertise-exit-node" )
fi

log "Running tailscale up (hostname=$TAILSCALE_HOSTNAME, ssh=$TAILSCALE_ENABLE_SSH, tags='${TAILSCALE_ADVERTISE_TAGS}', exitnode=$TAILSCALE_EXIT_NODE)..."
if ! ./tailscale "${UP_ARGS[@]}"; then
  err "tailscale up failed."
  err "If you enabled tags: make sure tagOwners allows them, or keep TAILSCALE_ADVERTISE_TAGS empty."
  exit 1
fi

log "Tailscale connected. Status:"
./tailscale --socket="$TAILSCALE_SOCKET_FILE" status || true

# ---------- Keep container alive + periodic health ----------
log "Entering keep-alive loop..."
while true; do
  if ! kill -0 "$TAILSCALED_PID" 2>/dev/null; then
    die "tailscaled process died unexpectedly."
  fi

  # Lightweight health check (doesn't fail the container)
  ./tailscale --socket="$TAILSCALE_SOCKET_FILE" ping --c 1 100.100.100.100 >/dev/null 2>&1 || true
  sleep 30
done
