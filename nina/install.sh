#!/usr/bin/env bash
# Nina v2 host installer (deploy package).
#
#   curl -fsSL https://motirolabs.com/nina/install.sh | bash
#
# Optional:
#   NINA_BASE_URL=https://motirolabs.com/nina
#   NINA_INSTALL_DIR=/opt/nina
#   NINA_DATA_ROOT=/opt/ninabot
#   INSTALL_START=1          # run 'nina up' after install
#   NINA_SKIP_SYMLINK=1      # do not link /usr/local/bin/nina
set -euo pipefail

NINA_BASE_URL="${NINA_BASE_URL:-https://motirolabs.com/nina}"
NINA_INSTALL_DIR="${NINA_INSTALL_DIR:-/opt/nina}"
NINA_DATA_ROOT="${NINA_DATA_ROOT:-/opt/ninabot}"
INSTALL_START="${INSTALL_START:-0}"
NINA_SKIP_SYMLINK="${NINA_SKIP_SYMLINK:-0}"

fail() {
  echo "nina-install: $*" >&2
  exit 1
}

info() {
  echo "nina-install: $*"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "$1 not found — install it and re-run"
}

download() {
  local url="$1"
  local dest="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$url" -o "$dest"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$dest" "$url"
  else
    fail "need curl or wget"
  fi
}

ensure_dir() {
  local d="$1"
  if [[ -d "$d" ]]; then
    return
  fi
  if mkdir -p "$d" 2>/dev/null; then
    return
  fi
  command -v sudo >/dev/null 2>&1 || fail "cannot create $d (need sudo)"
  info "creating $d (sudo)…"
  sudo mkdir -p "$d"
  sudo chown "$(id -u):$(id -g)" "$d"
}

ensure_writable_dir() {
  local d="$1"
  ensure_dir "$d"
  if [[ -w "$d" ]]; then
    return
  fi
  command -v sudo >/dev/null 2>&1 || fail "$d is not writable"
  info "fixing ownership of $d (sudo)…"
  sudo chown "$(id -u):$(id -g)" "$d"
}

need_cmd docker
docker compose version >/dev/null 2>&1 || fail "docker compose not available"

ensure_writable_dir "$NINA_INSTALL_DIR"
for sub in postgres nats google google/tokens google/credentials; do
  ensure_dir "$NINA_DATA_ROOT/$sub"
done
if [[ ! -w "$NINA_DATA_ROOT" ]]; then
  if command -v sudo >/dev/null 2>&1; then
    sudo chown "$(id -u):$(id -g)" "$NINA_DATA_ROOT" \
      "$NINA_DATA_ROOT/postgres" "$NINA_DATA_ROOT/nats" \
      "$NINA_DATA_ROOT/google" "$NINA_DATA_ROOT/google/tokens" \
      "$NINA_DATA_ROOT/google/credentials" 2>/dev/null || true
  fi
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

info "downloading package from $NINA_BASE_URL …"
download "$NINA_BASE_URL/docker-compose.yml" "$TMP/docker-compose.yml"
# Pages does not serve dotfiles — published as env.example, installed as .env.example.
download "$NINA_BASE_URL/env.example" "$TMP/.env.example"
download "$NINA_BASE_URL/nina" "$TMP/nina"

install -m 0644 "$TMP/docker-compose.yml" "$NINA_INSTALL_DIR/docker-compose.yml"
install -m 0644 "$TMP/.env.example" "$NINA_INSTALL_DIR/.env.example"
install -m 0755 "$TMP/nina" "$NINA_INSTALL_DIR/nina"

ensure_env_key() {
  local file="$1" key="$2" value="$3"
  if grep -qE "^[[:space:]]*${key}=" "$file"; then
    sed -i "s|^[[:space:]]*${key}=.*|${key}=${value}|" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

if [[ ! -f "$NINA_INSTALL_DIR/.env" ]]; then
  cp "$NINA_INSTALL_DIR/.env.example" "$NINA_INSTALL_DIR/.env"
  info "created $NINA_INSTALL_DIR/.env — edit secrets before starting"
else
  info ".env already exists, not overwriting secrets"
fi
# Always pin image coordinates for host install (never leave TAG=local from a bad copy).
ensure_env_key "$NINA_INSTALL_DIR/.env" NINA_IMAGE_PREFIX carlosrabelo/nina
ensure_env_key "$NINA_INSTALL_DIR/.env" NINA_IMAGE_TAG latest
ensure_env_key "$NINA_INSTALL_DIR/.env" NINA_DATA_ROOT "$NINA_DATA_ROOT"

if [[ "$NINA_SKIP_SYMLINK" != "1" ]]; then
  link_target="/usr/local/bin/nina"
  if [[ -L "$link_target" ]] || [[ ! -e "$link_target" ]]; then
    if ln -sfn "$NINA_INSTALL_DIR/nina" "$link_target" 2>/dev/null; then
      info "linked $link_target → $NINA_INSTALL_DIR/nina"
    elif command -v sudo >/dev/null 2>&1; then
      sudo ln -sfn "$NINA_INSTALL_DIR/nina" "$link_target"
      info "linked $link_target → $NINA_INSTALL_DIR/nina (sudo)"
    else
      info "skip symlink (no write to /usr/local/bin) — use $NINA_INSTALL_DIR/nina"
    fi
  else
    info "skip symlink: $link_target already exists and is not a symlink"
  fi
fi

cat <<EOF

nina-install: ready

  Install dir:  $NINA_INSTALL_DIR
  Data root:    $NINA_DATA_ROOT
  Images:       carlosrabelo/nina-telegram:latest

Next:
  1. Edit $NINA_INSTALL_DIR/.env  (TELEGRAM_BOT_TOKEN, TELEGRAM_OWNER_ID / allow-list, POSTGRES_PASSWORD)
  2. Start:  nina up
     (or:    $NINA_INSTALL_DIR/nina up)

EOF

if [[ "$INSTALL_START" == "1" ]]; then
  info "INSTALL_START=1 → running nina up"
  "$NINA_INSTALL_DIR/nina" up
fi
