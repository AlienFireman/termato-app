#!/usr/bin/env bash
#
# Termato installer — turnkey on a home machine behind NAT.
#
#   Two-line install (provisioning is handled for you, online):
#     git clone https://github.com/AlienFireman/termato-app.git ~/.termato
#     bash ~/.termato/install.sh
#
# It prompts interactively for everything it needs (just a machine nickname); nothing
# else to configure. By default it requests your subdomains + tunnel from the
# hosted endpoint (provision.termato.com) — just pick a machine nickname. (Override:
# TERMATO_PROVISION_BUNDLE=<file> for a pre-minted bundle, or TERMATO_PROVISION_URL
# for a different endpoint.)
#
# What it does (the default "tunnel" install):
#   • gets your bundle (machine nickname, tunnel id + credentials, animal preview words)
#   • auto-picks free local ports (no port prompts, no clashing with other services)
#   • builds Termato, writes a PRIVATE Caddy config (its own pm2 process, high localhost
#     port — never touches the system Caddy/nginx or ports 80/443)
#   • runs a Cloudflare Tunnel so the box is reachable from anywhere (incl. phones)
#     with no port-forwarding, then enables start-on-boot.
#
# It is deliberately NON-INVASIVE on a shared box: it reuses an existing Node ≥20
# (never replaces it), never edits system web-server config, and appends to pm2.
#
# Non-interactive: set TERMATO_NICKNAME (legacy: TERMATO_USERNAME) to skip all prompts. Termato is password-free —
# instead, each CLIENT (a browser session you sign in from, e.g. on your phone or
# computer) is authorised individually after install with `termato clients add`.
# Start-on-boot defaults to enabled; set TERMATO_ENABLE_BOOT=0 to skip it (interactively you're asked).
#
# (Advanced/legacy: TERMATO_INSTALL_TYPE=server runs the old public-host + system-Caddy
#  flow with its own domain/port prompts. Not offered interactively.)

set -euo pipefail

INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INSTALL_DIR"

c() { printf '\033[1;36m[termato]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[termato] WARN:\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[termato] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
ask() { # ask VARNAME "prompt" [default]
  local _n="$1" _p="$2" _d="${3:-}" _v; _v="$(eval "printf '%s' \"\${$_n:-}\"")"
  if [ -z "$_v" ]; then
    if [ -n "$_d" ]; then read -rp "$_p [$_d]: " _v; _v="${_v:-$_d}"; else read -rp "$_p: " _v; fi
  fi
  printf -v "$_n" '%s' "$_v"
}

# Termato is PASSWORD-FREE. Each client (a browser session that signs in to this
# server) is authorised individually via `termato clients add` — a 6-digit code shown
# at the server console plus an operator confirmation — so no login password is chosen
# at install time. See app/lib/clients.cjs.

# Quiet install: noisy sub-command output goes to $LOG; we print only clean
# [termato] step lines and dump the log tail if a step fails. Env vars below silence
# the usual offenders (apt/needrestart prompts, npm notices, Next telemetry).
LOG="$(mktemp "${TMPDIR:-/tmp}/termato-install.XXXXXX" 2>/dev/null || mktemp)"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a NEEDRESTART_SUSPEND=1
export NEXT_TELEMETRY_DISABLED=1
export NPM_CONFIG_FUND=false NPM_CONFIG_AUDIT=false NPM_CONFIG_UPDATE_NOTIFIER=false
logfail() { warn "$1 — last lines of $LOG:"; tail -n 25 "$LOG" >&2; exit 1; }

OS="$(uname -s)"
if [ "$(id -u)" -eq 0 ]; then SUDO=""; else have sudo || die "Run as root or install sudo first."; SUDO="sudo"; fi

APT=0; BREW=0
if [ "$OS" = "Linux" ] && have apt-get; then APT=1; fi
if [ "$OS" = "Darwin" ]; then have brew || die "Homebrew is required on macOS — https://brew.sh"; BREW=1; fi

apt_updated=0
apt_install() {
  [ "$apt_updated" = 1 ] || { c "Updating package lists…"; $SUDO apt-get update -y >>"$LOG" 2>&1; apt_updated=1; }
  $SUDO apt-get install -y "$@" >>"$LOG" 2>&1
}

arch_tag() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) echo "" ;;
  esac
}

# Free-port checks reuse Node (always present once deps are installed) so they're
# portable across Linux/macOS without ss/lsof differences.
port_free() {
  node -e 'const n=require("net").createServer();n.once("error",()=>process.exit(1));n.once("listening",()=>n.close(()=>process.exit(0)));n.listen(parseInt(process.argv[1],10),"127.0.0.1")' "$1" 2>/dev/null
}
pick_port() { # preferred -> first free port at/after preferred
  local p="$1"; while ! port_free "$p"; do p=$((p+1)); done; echo "$p"
}
pick_range() { # base count -> base of a free contiguous run of `count` ports
  local base="$1" count="$2" attempt try i ok
  for attempt in $(seq 0 80); do
    try=$((base + attempt*100)); ok=1
    for ((i=0; i<count; i++)); do port_free $((try+i)) || { ok=0; break; }; done
    [ "$ok" = 1 ] && { echo "$try"; return 0; }
  done
  return 1
}

INSTALL_TYPE="${TERMATO_INSTALL_TYPE:-tunnel}"

# ── 0. Gather config ─────────────────────────────────────────────────────────
if [ "$INSTALL_TYPE" = "tunnel" ]; then
  have jq || { [ "$APT" = 1 ] && apt_install jq || { [ "$BREW" = 1 ] && brew install jq >/dev/null || die "jq is required (install it and re-run)."; }; }

  # Provision bundle. By DEFAULT we fetch it live from the hosted provisioning
  # endpoint (provision.termato.com) — the user just picks a machine nickname. Override with
  # TERMATO_PROVISION_BUNDLE=<file> to use a pre-minted bundle, or TERMATO_PROVISION_URL
  # to point at a different endpoint.
  : "${TERMATO_PROVISION_URL:=https://provision.termato.com}"
  TMP_BUNDLE=""
  if [ -n "${TERMATO_PROVISION_BUNDLE:-}" ]; then
    BUNDLE="$TERMATO_PROVISION_BUNDLE"
  else
    # The nickname identifies this Termato installation: it becomes your subdomain
    # ({nickname}.termato.com) and must be unique across all Termato users. Accept the
    # legacy TERMATO_USERNAME override for backward compat.
    : "${TERMATO_NICKNAME:=${TERMATO_USERNAME:-}}"
    c "Pick a nickname for this Termato installation."
    c "$(printf "  • It becomes your subdomain — you'll reach this machine at \033[1;32m{nickname}.termato.com\033[0m")"
    c "  • It must be unique across all Termato users."
    c "  • One nickname per installation. Planning to run Termato on more than one machine?"
    c "    Use a machine-specific name (e.g. 'dan-laptop'). Just the one machine? Your name or"
    c "    any nickname is fine."
    TMP_BUNDLE="$(mktemp)"; chmod 600 "$TMP_BUNDLE"; BUNDLE="$TMP_BUNDLE"
    # Loop so a taken/invalid nickname re-prompts in place instead of aborting the install.
    # When TERMATO_NICKNAME is preset (non-interactive), we don't loop — a clash just dies.
    while :; do
      _preset_nick="${TERMATO_NICKNAME:-}"
      ask TERMATO_NICKNAME "$(printf '\033[1;36m[termato]\033[0m Nickname (lowercase letters, digits, hyphens)')"
      if ! [[ "$TERMATO_NICKNAME" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]]; then
        [ -n "$_preset_nick" ] && die "Invalid machine nickname (must be a DNS label: lowercase letters, digits, hyphens)."
        c "$(printf '\033[1;31m[termato]\033[0m That is not a valid nickname (lowercase letters, digits, hyphens only). Try again.')"
        TERMATO_NICKNAME=""; continue
      fi
      c "Checking that '${TERMATO_NICKNAME}' is available…"
      code="$(curl -sS -X POST -H 'Content-Type: application/json' \
        ${TERMATO_PROVISION_KEY:+-H "X-Provision-Key: ${TERMATO_PROVISION_KEY}"} \
        --data "{\"username\":\"${TERMATO_NICKNAME}\"}" \
        -o "$BUNDLE" -w '%{http_code}' "${TERMATO_PROVISION_URL%/}/provision")" \
        || die "Couldn't reach the provisioning service at ${TERMATO_PROVISION_URL}. Check your connection and try again."
      if [ "$code" = "200" ]; then
        c "Nickname '${TERMATO_NICKNAME}' is available — reserving it and preparing your secure tunnel…"
        break
      fi
      # Strip ANSI colour codes from any server detail so the message reads cleanly.
      detail="$(jq -r '.detail // .error // empty' "$BUNDLE" 2>/dev/null | sed $'s/\033\\[[0-9;]*m//g' | tr '\n' ' ')"
      case "$code" in
        503) die "Provisioning is currently turned off. Ask the operator to enable it, then re-run." ;;
        401) die "Provisioning needs an access key. Set TERMATO_PROVISION_KEY and re-run." ;;
        429) die "Too many attempts — wait a few minutes and re-run." ;;
        409)
          # Nickname already taken. Re-prompt for a different one (unless it was preset).
          [ -n "$_preset_nick" ] && die "The machine nickname '${TERMATO_NICKNAME}' is already taken. Pick a different one and re-run."
          c "$(printf "\033[1;31m[termato]\033[0m The nickname '%s' is already taken. Pick a different one." "${TERMATO_NICKNAME}")"
          TERMATO_NICKNAME=""; continue ;;
        *)   die "Provisioning failed (the server couldn't set up your account).${detail:+ Details: $detail}" ;;
      esac
    done
  fi
  [ -f "$BUNDLE" ] || die "Bundle not found: $BUNDLE"
  jq -e . "$BUNDLE" >/dev/null 2>&1 || die "Bundle is not valid JSON: $BUNDLE"

  USERNAME="$(jq -r '.username' "$BUNDLE")"
  DOMAIN="$(jq -r '.domain' "$BUNDLE")"
  APP_HOST="$(jq -r '.appHost' "$BUNDLE")"
  TUNNEL_ID="$(jq -r '.tunnelId' "$BUNDLE")"
  SLOTS="$(jq -r '.slots' "$BUNDLE")"
  # (read loop, not mapfile — macOS ships Bash 3.2 which has no mapfile/readarray)
  ANIMALS=()
  while IFS= read -r _a; do [ -n "$_a" ] && ANIMALS+=("$_a"); done < <(jq -r '.animals[]' "$BUNDLE")
  [ -n "$USERNAME" ] && [ -n "$TUNNEL_ID" ] && [ "${#ANIMALS[@]}" -eq "$SLOTS" ] || die "Bundle is missing fields."
else
  # ── legacy public-server path (not offered interactively) ──
  ask TERMATO_APP_HOST        "App host (where you load Termato), e.g. termato.example.com"
  ask TERMATO_PREVIEW_PATTERN "Preview hostname pattern (must contain {port}), e.g. {port}.example.com"
  ask TERMATO_PORT_START      "Lowest preview port" 4000
  ask TERMATO_PORT_END        "Highest preview port" 4050
  [ -n "$TERMATO_APP_HOST" ] || die "App host is required."
  case "$TERMATO_PREVIEW_PATTERN" in *"{port}"*) ;; *) die "Preview pattern must contain {port}." ;; esac
  APP_HOST="$TERMATO_APP_HOST"
  DOMAIN="$(printf '%s' "$APP_HOST" | awk -F. '{ if (NF>=2) print $(NF-1)"."$NF; else print $0 }')"
fi

[ -n "$SUDO" ] && { c "Requesting sudo (only for any missing system packages)…"; sudo -v; }

# ── 1. Base packages ─────────────────────────────────────────────────────────
c "Checking system dependencies…"
if [ "$APT" = 1 ]; then
  NEED=()
  for p in curl ca-certificates; do dpkg -s "$p" >/dev/null 2>&1 || NEED+=("$p"); done
  [ "${#NEED[@]}" -gt 0 ] && { c "Installing: ${NEED[*]}"; apt_install "${NEED[@]}"; }
elif [ "$BREW" = 0 ]; then
  have curl || die "curl is required (auto-install supports apt/brew only)."
fi

# ── 2. Node.js — always use a pinned, bundled LTS inside the install dir ─────
# Every install builds AND runs on the SAME Node, independent of the user's system
# Node (or lack of one). Next's webpack build is fussy about the Node version — it
# fails on non-LTS releases like 23 — so we never depend on whatever's on PATH.
NODE_DIR="$INSTALL_DIR/.node"
NODE_BIN="$NODE_DIR/bin/node"
# Latest Node 22 LTS, resolved live; pinned fallback if the dist index is unreachable.
NODE_VER="$(curl -fsSL https://nodejs.org/dist/index.json 2>/dev/null | jq -r 'map(select(.version|test("^v22\\.")))[0].version // empty' 2>/dev/null | sed 's/^v//')"
[ -n "${NODE_VER:-}" ] || NODE_VER="22.11.0"
case "$OS" in Linux) NPLAT=linux;; Darwin) NPLAT=darwin;; *) die "No prebuilt Node for OS '$OS' — install Node 22 LTS manually and re-run.";; esac
case "$(uname -m)" in x86_64|amd64) NARCH=x64;; aarch64|arm64) NARCH=arm64;; *) die "No prebuilt Node for CPU '$(uname -m)' — install Node 22 LTS manually and re-run.";; esac
if [ "$("$NODE_BIN" -v 2>/dev/null)" != "v$NODE_VER" ]; then
  c "Setting up a private Node ${NODE_VER} runtime (${NPLAT}-${NARCH})…"
  rm -rf "$NODE_DIR"; mkdir -p "$NODE_DIR"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VER}/node-v${NODE_VER}-${NPLAT}-${NARCH}.tar.gz" \
    | tar -xz -C "$NODE_DIR" --strip-components=1 >>"$LOG" 2>&1 \
    || die "Couldn't download/extract Node ${NODE_VER} (${NPLAT}-${NARCH})."
fi
# Put the bundled runtime first on PATH so npm/npx/build all use it, and tell the
# pm2 ecosystem to run the app under it too.
export PATH="$NODE_DIR/bin:$PATH"
export TERMATO_NODE_BIN="$NODE_BIN"
have node || die "Bundled Node runtime is not usable."
c "Using bundled Node $(node -v), npm $(npm -v)."
c "Using Node $(node -v), npm $(npm -v)."

# Termato runs (and spawns preview builds + the Claude agent) under NODE_ENV=production,
# which makes `npm install` omit devDependencies. That silently breaks any project whose
# build tools (vite, typescript, webpack, etc.) live in devDependencies: the build fails
# and the preview shows an error in the browser. Force npm to always include dev deps for
# this user so project installs are complete regardless of NODE_ENV. Idempotent.
if ! npm config get include --location=user 2>/dev/null | grep -qx dev; then
  npm config set include dev --location=user >/dev/null 2>&1 \
    && c "Configured npm to keep devDependencies (NODE_ENV=production safe)." \
    || warn "Could not set npm include=dev; projects with devDependencies may fail to build."
fi

# ── 3. pm2 ───────────────────────────────────────────────────────────────────
if ! have pm2; then
  c "Installing pm2…"
  npm install -g pm2 >/dev/null 2>&1 || $SUDO npm install -g pm2 >/dev/null
fi
have pm2 || die "pm2 install failed."

# Put the `termato` CLI on PATH (start/stop/restart + client authorisation). Symlink
# to the install copy so updates are picked up automatically. Try a system dir, then
# fall back to ~/.local/bin (added to PATH below if used).
chmod +x "$INSTALL_DIR/bin/termato.js" 2>/dev/null || true
if ln -sf "$INSTALL_DIR/bin/termato.js" /usr/local/bin/termato 2>/dev/null \
   || $SUDO ln -sf "$INSTALL_DIR/bin/termato.js" /usr/local/bin/termato 2>/dev/null; then
  c "Installed the 'termato' command (/usr/local/bin/termato)."
else
  mkdir -p "$HOME/.local/bin"
  ln -sf "$INSTALL_DIR/bin/termato.js" "$HOME/.local/bin/termato"
  case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *)
    for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
      [ -f "$rc" ] && ! grep -q '.local/bin' "$rc" && echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$rc"
    done ;;
  esac
  c "Installed the 'termato' command (~/.local/bin/termato — open a new shell to use it)."
fi

# ── 4. Pick ports (auto, verified free) ──────────────────────────────────────
APP_PORT="$(pick_port "${PORT:-3002}")"
if [ "$INSTALL_TYPE" = "tunnel" ]; then
  CADDY_PORT="$(pick_port 48080)"
  PORT_BASE="$(pick_range 47000 "$SLOTS")" || die "Could not find $SLOTS free preview ports."
  PORT_START="$PORT_BASE"; PORT_END=$((PORT_BASE + SLOTS - 1))
  c "Ports — app: $APP_PORT, proxy: $CADDY_PORT, previews: $PORT_START-$PORT_END."
else
  PORT_START="$TERMATO_PORT_START"; PORT_END="$TERMATO_PORT_END"
fi

# ── 5. .env.local (git-ignored; Next loads it for build + runtime) ───────────
# Termato is password-free. Mint one independent random key used to SIGN per-client
# session cookies — each authorised client gets its own cookie (app/lib/clients.cjs).
TERMATO_SESSION_SECRET="$(node -e 'process.stdout.write(require("crypto").randomBytes(32).toString("hex"))')" \
  || die "Failed to generate session secret."

c "Writing .env.local…"
umask 077
if [ "$INSTALL_TYPE" = "tunnel" ]; then
  cat > .env.local <<EOF
TERMATO_SESSION_SECRET=${TERMATO_SESSION_SECRET}
PORT=${APP_PORT}
TERMATO_APP_HOST=${APP_HOST}
TERMATO_COOKIE_DOMAIN=${DOMAIN}
TERMATO_USERNAME=${USERNAME}
TERMATO_PREVIEW_DOMAIN=${DOMAIN}
TERMATO_PROVISION_URL=${TERMATO_PROVISION_URL}
NEXT_PUBLIC_TERMATO_USERNAME=${USERNAME}
NEXT_PUBLIC_TERMATO_PREVIEW_DOMAIN=${DOMAIN}
TERMATO_PORT_BASE=${PORT_BASE}
NEXT_PUBLIC_TERMATO_PORT_BASE=${PORT_BASE}
TERMATO_PREVIEW_SLOTS=${SLOTS}
NEXT_PUBLIC_TERMATO_PREVIEW_SLOTS=${SLOTS}
EOF
else
  cat > .env.local <<EOF
TERMATO_SESSION_SECRET=${TERMATO_SESSION_SECRET}
PORT=${APP_PORT}
TERMATO_APP_HOST=${APP_HOST}
TERMATO_COOKIE_DOMAIN=${DOMAIN}
TERMATO_PREVIEW_DOMAIN=${DOMAIN}
TERMATO_PREVIEW_PATTERN=${TERMATO_PREVIEW_PATTERN}
NEXT_PUBLIC_TERMATO_PREVIEW_DOMAIN=${DOMAIN}
NEXT_PUBLIC_TERMATO_PREVIEW_PATTERN=${TERMATO_PREVIEW_PATTERN}
EOF
fi

# Pin the claude CLI so the app finds it even under pm2's minimal PATH — this is
# the usual "chat doesn't respond" cause (claude lives in ~/.local/bin, which pm2
# doesn't have on PATH). If it's missing now, the app self-heals once claude is
# installed; we just warn.
CLAUDE_PATH="$(command -v claude 2>/dev/null || true)"
for _p in "$HOME/.local/bin/claude" /usr/local/bin/claude /opt/homebrew/bin/claude /usr/bin/claude "$HOME/.npm-global/bin/claude"; do
  [ -n "$CLAUDE_PATH" ] && break
  [ -x "$_p" ] && CLAUDE_PATH="$_p"
done
if [ -n "$CLAUDE_PATH" ]; then
  echo "TERMATO_CLAUDE_BIN=${CLAUDE_PATH}" >> .env.local
  c "Pinned claude CLI: ${CLAUDE_PATH}"
else
  warn "The 'claude' CLI was not found. Termato needs it for chat — install Claude Code and the app will pick it up automatically (or run: pm2 restart termato --update-env)."
fi
umask 022

# ── 6. Dependencies + build ──────────────────────────────────────────────────
# A packaged distribution ships a pre-built .next and a BUILD_INFO.json marker, so
# we only install runtime deps and skip the build. A source checkout (no marker)
# installs everything and builds.
if [ -f "$INSTALL_DIR/BUILD_INFO.json" ]; then
  c "Installing dependencies…"
  npm ci --omit=dev >>"$LOG" 2>&1 || logfail "Dependency install failed"
  c "Using pre-built distribution (skipping build)."
else
  c "Installing dependencies…"
  npm ci >>"$LOG" 2>&1 || logfail "Dependency install failed"
  c "Building Termato…"
  npm run build >>"$LOG" 2>&1 || logfail "Build failed"
fi

# Frameable holding page served by handle_errors when the band port has no listener.
# Caddy can't tell "server still booting" from "nothing running at all" (both are just a
# failed proxy), so this must NOT claim a server is starting — it is a neutral tomato
# holding page that quietly auto-refreshes, so it transparently upgrades to the live
# preview the moment a server does start. (No apostrophes/backticks: bash single-quote +
# Caddy backtick-delimited body.)
HOLD_HTML='<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="3"><title>Termato preview</title><style>html,body{height:100%;margin:0}body{display:flex;flex-direction:column;gap:16px;align-items:center;justify-content:center;font-family:system-ui,-apple-system,sans-serif;background:#0b0b0c;color:#8a8f98;font-size:14px;text-align:center;padding:24px;box-sizing:border-box}.t{font-size:72px;line-height:1;filter:drop-shadow(0 6px 16px rgba(229,57,53,.4))}.h{color:#e8eaed;font-size:17px;font-weight:600}.s{max-width:320px;line-height:1.5;opacity:.85}</style></head><body><div class="t">🍅</div><div class="h">No preview running</div><div class="s">There is nothing to display here yet. This page will update by itself as soon as a preview server starts.</div></body></html>'

if [ "$INSTALL_TYPE" = "tunnel" ]; then
  # ── 7t. Private Caddy (own pm2 process, high localhost port — never system Caddy) ──
  # Both fetch prebuilt binaries straight into ./bin (no Homebrew, no system
  # service, no compiling) — fast and identical on Linux and macOS.
  ensure_caddy() {
    if have caddy; then CADDY_BIN="caddy"; return; fi
    local arch os; arch="$(arch_tag)"; [ -n "$arch" ] || die "Unsupported CPU architecture for the reverse proxy."
    case "$OS" in Linux) os=linux;; Darwin) os=darwin;; *) die "Unsupported OS for the reverse proxy.";; esac
    c "Setting up the local reverse proxy…"
    mkdir -p "$INSTALL_DIR/bin"
    curl -fsSL "https://caddyserver.com/api/download?os=$os&arch=$arch" -o "$INSTALL_DIR/bin/caddy" \
      || die "Couldn't download the reverse proxy."
    chmod +x "$INSTALL_DIR/bin/caddy"; CADDY_BIN="$INSTALL_DIR/bin/caddy"
  }
  ensure_cloudflared() {
    if have cloudflared; then CFD_BIN="cloudflared"; return; fi
    local arch; arch="$(arch_tag)"; [ -n "$arch" ] || die "Unsupported CPU architecture for the secure tunnel."
    c "Setting up the secure tunnel…"
    mkdir -p "$INSTALL_DIR/bin"
    if [ "$OS" = "Darwin" ]; then
      # macOS ships cloudflared as a .tgz containing the binary.
      curl -fsSL -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-$arch.tgz" \
        | tar -xz -C "$INSTALL_DIR/bin" cloudflared >>"$LOG" 2>&1 || die "Couldn't download the secure tunnel."
    else
      curl -fsSL -L "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$arch" \
        -o "$INSTALL_DIR/bin/cloudflared" || die "Couldn't download the secure tunnel."
    fi
    chmod +x "$INSTALL_DIR/bin/cloudflared"; CFD_BIN="$INSTALL_DIR/bin/cloudflared"
  }
  ensure_caddy
  ensure_cloudflared

  c "Configuring the local reverse proxy…"
  CADDYFILE="$INSTALL_DIR/private.Caddyfile"
  {
    # Config version marker — kept in sync with migrations/001-caddy-config-v1.sh so the
    # updater's migration can tell whether an existing install needs regenerating.
    printf '# termato-caddy-config-version: 1\n\n'
    # admin off: don't fight an existing Caddy for the :2019 admin API.
    printf '{\n\tadmin off\n\tauto_https off\n}\n\n'
    printf 'http://%s:%s {\n\tbind 127.0.0.1\n\treverse_proxy 127.0.0.1:%s\n}\n\n' "$APP_HOST" "$CADDY_PORT" "$APP_PORT"
    for i in "${!ANIMALS[@]}"; do
      host="${ANIMALS[$i]}-${USERNAME}.${DOMAIN}"
      pport=$((PORT_BASE + i))
      printf 'http://%s:%s {\n' "$host" "$CADDY_PORT"
      printf '\tbind 127.0.0.1\n'
      # Gate the preview behind the Termato session: forward_auth asks the app to
      # validate the termato_auth cookie (2xx → proxy the preview; otherwise the
      # app 302s to /login and Caddy relays that). The reverse_proxy then strips
      # termato_auth so the previewed project never receives your session token.
      printf '\troute {\n'
      printf '\t\tforward_auth 127.0.0.1:%s {\n' "$APP_PORT"
      printf '\t\t\turi /api/auth/preview\n'
      printf '\t\t}\n'
      printf '\t\treverse_proxy 127.0.0.1:%s {\n' "$pport"
      printf '\t\t\theader_up Host "localhost:%s"\n' "$pport"
      printf '\t\t\theader_up -Origin\n'
      printf '\t\t\theader_up Cookie "termato_auth[A-Za-z0-9_]*=[^;]*" "termato_auth=removed"\n'
      printf '\t\t\theader_down Content-Security-Policy "frame-ancestors https://%s"\n' "$APP_HOST"
      printf '\t\t\theader_down -X-Frame-Options\n'
      printf '\t\t\theader_down -Cache-Control\n'
      printf '\t\t\theader_down +Cache-Control "no-store, no-cache, max-age=0, must-revalidate"\n'
      printf '\t\t}\n'
      printf '\t}\n'
      printf '\thandle_errors {\n'
      printf '\t\theader Content-Type "text/html; charset=utf-8"\n'
      printf '\t\theader Content-Security-Policy "frame-ancestors https://%s"\n' "$APP_HOST"
      printf '\t\theader -X-Frame-Options\n'
      printf '\t\theader Cache-Control "no-store, no-cache, must-revalidate"\n'
      printf '\t\trespond 200 {\n\t\t\tbody `%s`\n\t\t}\n' "$HOLD_HTML"
      printf '\t}\n}\n\n'
    done
  } > "$CADDYFILE"
  "$CADDY_BIN" validate --config "$CADDYFILE" --adapter caddyfile >>"$LOG" 2>&1 || die "The reverse-proxy config failed validation."

  c "Configuring the secure tunnel…"
  CFD_DIR="$INSTALL_DIR/.cloudflared"
  mkdir -p "$CFD_DIR"; chmod 700 "$CFD_DIR"
  jq -c '.credentials' "$BUNDLE" > "$CFD_DIR/${TUNNEL_ID}.json"
  chmod 600 "$CFD_DIR/${TUNNEL_ID}.json"
  cat > "$CFD_DIR/config.yml" <<EOF
tunnel: ${TUNNEL_ID}
credentials-file: ${CFD_DIR}/${TUNNEL_ID}.json
ingress:
  - hostname: "*.${DOMAIN}"
    service: http://localhost:${CADDY_PORT}
  - service: http_status:404
EOF

  # ── 8t. Start everything under pm2 (additive) ──
  c "Starting Termato (app, reverse proxy, secure tunnel)…"
  pm2 delete termato-caddy  >/dev/null 2>&1 || true
  pm2 delete termato-tunnel >/dev/null 2>&1 || true
  if pm2 describe termato >/dev/null 2>&1; then PORT="$APP_PORT" pm2 restart termato --update-env >>"$LOG" 2>&1; else PORT="$APP_PORT" pm2 start ecosystem.config.js --update-env >>"$LOG" 2>&1; fi
  pm2 start "$CADDY_BIN" --name termato-caddy  -- run --config "$CADDYFILE" --adapter caddyfile >>"$LOG" 2>&1
  pm2 start "$CFD_BIN"   --name termato-tunnel -- tunnel --config "$CFD_DIR/config.yml" run >>"$LOG" 2>&1

else
  # ── 7s. Legacy system-Caddy path (public server) ──
  PAT_RE="${TERMATO_PREVIEW_PATTERN//./\\.}"; PAT_RE="${PAT_RE/\{port\}/(\\d+)}"
  HOSTS=""
  for p in $(seq "$PORT_START" "$PORT_END"); do HOSTS="${HOSTS}${TERMATO_PREVIEW_PATTERN/\{port\}/$p}, "; done
  HOSTS="${HOSTS%, }"
  if ! have caddy; then
    if [ "$APT" = 1 ]; then
      apt_install debian-keyring debian-archive-keyring apt-transport-https curl gnupg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | $SUDO gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
      curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | $SUDO tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
      apt_updated=0; apt_install caddy
    elif [ "$BREW" = 1 ]; then brew install caddy >/dev/null
    else die "Couldn't set up the reverse proxy automatically on this system — install it and re-run."; fi
  fi
  SNIPPET="$(cat <<EOF
# ─── Managed by Termato install.sh — edits may be overwritten ───
${APP_HOST} {
	reverse_proxy 127.0.0.1:${APP_PORT}
}

${HOSTS} {
	@portmatch header_regexp pm Host "^${PAT_RE}\$"
	route @portmatch {
		# Gate the preview behind the Termato session (see private.Caddyfile notes):
		# forward_auth validates the termato_auth cookie, then the preview backend
		# gets the request with termato_auth stripped out.
		forward_auth 127.0.0.1:${APP_PORT} {
			uri /api/auth/preview
		}
		reverse_proxy 127.0.0.1:{http.regexp.pm.1} {
			header_up Host "localhost:{http.regexp.pm.1}"
			header_up -Origin
			header_up Cookie "termato_auth[A-Za-z0-9_]*=[^;]*" "termato_auth=removed"
			header_down Content-Security-Policy "frame-ancestors https://${APP_HOST}"
			header_down -X-Frame-Options
			header_down -Cache-Control
			header_down +Cache-Control "no-store, no-cache, max-age=0, must-revalidate"
		}
	}
	handle_errors {
		header Content-Type "text/html; charset=utf-8"
		header Content-Security-Policy "frame-ancestors https://${APP_HOST}"
		header -X-Frame-Options
		header Cache-Control "no-store, no-cache, must-revalidate"
		respond 200 {
			body \`${HOLD_HTML}\`
		}
	}
}
EOF
)"
  if [ "$BREW" = 1 ]; then
    CADDY_ETC="$(brew --prefix)/etc"; MAIN_CADDYFILE="${CADDY_ETC}/Caddyfile"; SNIPPET_PATH="${CADDY_ETC}/termato.caddy"
    mkdir -p "$CADDY_ETC"; touch "$MAIN_CADDYFILE"
    printf '%s\n' "$SNIPPET" > "$SNIPPET_PATH"
    grep -qxF "import ${SNIPPET_PATH}" "$MAIN_CADDYFILE" || printf '\nimport %s\n' "$SNIPPET_PATH" >> "$MAIN_CADDYFILE"
    caddy validate --config "$MAIN_CADDYFILE" --adapter caddyfile >>"$LOG" 2>&1
    caddy reload --config "$MAIN_CADDYFILE" --adapter caddyfile >>"$LOG" 2>&1 || brew services restart caddy >>"$LOG" 2>&1
  else
    MAIN_CADDYFILE="/etc/caddy/Caddyfile"; SNIPPET_PATH="/etc/caddy/termato.caddy"
    printf '%s\n' "$SNIPPET" | $SUDO tee "$SNIPPET_PATH" >/dev/null
    $SUDO touch "$MAIN_CADDYFILE"
    $SUDO grep -qxF "import ${SNIPPET_PATH}" "$MAIN_CADDYFILE" || printf '\nimport %s\n' "$SNIPPET_PATH" | $SUDO tee -a "$MAIN_CADDYFILE" >/dev/null
    $SUDO caddy validate --config "$MAIN_CADDYFILE" --adapter caddyfile >>"$LOG" 2>&1
    $SUDO systemctl reload caddy >>"$LOG" 2>&1 || $SUDO systemctl restart caddy >>"$LOG" 2>&1
  fi
  c "Starting Termato…"
  if pm2 describe termato >/dev/null 2>&1; then PORT="$APP_PORT" pm2 restart termato --update-env >>"$LOG" 2>&1; else PORT="$APP_PORT" pm2 start ecosystem.config.js --update-env >>"$LOG" 2>&1; fi
fi

# ── 9. Enable start-on-boot (optional, additive) ─────────────────────────────
# Default yes. Interactive: ask. Non-interactive: enable unless TERMATO_ENABLE_BOOT=0.
_enable_boot=1
if [ "${TERMATO_ENABLE_BOOT:-}" = "0" ]; then
  _enable_boot=0
elif [ -z "${TERMATO_ENABLE_BOOT:-}" ] && [ -t 0 ]; then
  printf '\033[1;36m[termato]\033[0m Start Termato automatically on boot? [Y/n] '
  read -r _boot || _boot=""
  case "$_boot" in [Nn]*) _enable_boot=0 ;; esac
fi

if [ "$_enable_boot" = "1" ]; then
  c "Enabling start-on-boot…"
  pm2 save >>"$LOG" 2>&1 || true
  if [ "$OS" = "Darwin" ]; then
    # macOS: a per-USER LaunchAgent that runs `pm2 resurrect` at login. This needs
    # NO sudo (unlike `pm2 startup`, which registers a system LaunchDaemon and so
    # prompts for a password the piped `curl | bash` install can't supply → the
    # "Boot-start step failed" warning). Runs at login under the user's own pm2.
    PM2_BIN="$(command -v pm2 || true)"
    LA_DIR="$HOME/Library/LaunchAgents"
    PLIST="$LA_DIR/com.termato.pm2.plist"
    mkdir -p "$LA_DIR"
    cat > "$PLIST" <<PLIST_EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.termato.pm2</string>
  <key>ProgramArguments</key>
  <array>
    <string>${NODE_BIN}</string>
    <string>${PM2_BIN}</string>
    <string>resurrect</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>${NODE_DIR}/bin:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    <key>PM2_HOME</key><string>${HOME}/.pm2</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>${HOME}/.pm2/launchagent.log</string>
  <key>StandardErrorPath</key><string>${HOME}/.pm2/launchagent.log</string>
</dict>
</plist>
PLIST_EOF
    # Re-register cleanly (ignore "not loaded" on first run); user-domain → no sudo.
    launchctl unload "$PLIST" >>"$LOG" 2>&1 || true
    if launchctl load -w "$PLIST" >>"$LOG" 2>&1; then c "Start-on-boot enabled (login)."; else warn "Couldn't register the boot LaunchAgent; enable it later with: launchctl load -w $PLIST"; fi
  else
    STARTUP_CMD="$(pm2 startup 2>>"$LOG" | grep -m1 'env PATH=' || true)"
    if [ -n "$STARTUP_CMD" ]; then
      [ -n "$SUDO" ] && [ -t 0 ] && $SUDO -v 2>>"$LOG" || true   # refresh sudo (timestamp may have lapsed during the build)
      if eval "$STARTUP_CMD" >>"$LOG" 2>&1; then c "Start-on-boot enabled."; else warn "Boot-start step failed; enable it later with: pm2 startup"; fi
    else
      warn "Couldn't set up start-on-boot automatically. Run 'pm2 startup' later and follow its instructions."
    fi
  fi
else
  c "Skipped start-on-boot. Enable it anytime with: pm2 startup && pm2 save"
fi

# Don't leave a fetched bundle (contains tunnel credentials) lying in /tmp.
[ -n "${TMP_BUNDLE:-}" ] && rm -f "$TMP_BUNDLE" || true

rm -f "$LOG" 2>/dev/null || true
echo
c "✓ Termato is installed and running."
printf '\033[1;36m[termato]\033[0m   Access this machine from your phone or computer at: \033[1;32mhttps://%s\033[0m\n' "${APP_HOST}"

# Termato is password-free: a client (a browser session you sign in from, e.g. on your
# phone or computer) can only get in after it's authorised here at the server. Offer to
# authorise the first one right now; otherwise it can be done anytime with
# `termato clients add`.
TERMATO_CLI="$INSTALL_DIR/bin/termato.js"
echo
c "  A 'client' is a browser session that signs in to this server (phone or computer)."
c "  Each one is authorised here at the server with a 6-digit code."
if [ -t 0 ] && [ "${TERMATO_CONNECT_CLIENT:-}" != "0" ]; then
  printf '\033[1;36m[termato]\033[0m Authorise your first client now? [Y/n] '
  read -r _connect || _connect=""
  case "$_connect" in
    [Nn]*) c "Skipped. Authorise a client anytime with:  termato clients add" ;;
    *)     "$NODE_BIN" "$TERMATO_CLI" clients add || warn "Client authorisation didn't complete — run 'termato clients add' to retry." ;;
  esac
else
  c "Authorise your first client with:  termato clients add"
fi
