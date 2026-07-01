#!/usr/bin/env bash
# Migration 003 — bring private.Caddyfile up to canonical "config v3".
#
# Why: the preview `handle_errors` block (served when the band port has no listener)
# responded with a "Starting server…" spinner that auto-refreshed every 2s. But Caddy
# can't tell "the dev server is still booting" from "nothing is running at all" — both
# are just a failed proxy — so navigating to a preview subdomain with NO server showed a
# permanent, misleading "Starting server…" spinner. v3 swaps it for a neutral tomato
# holding page ("No preview running") that still quietly auto-refreshes, so it upgrades
# to the live preview the moment a server does start. This is the ONLY change from v2 —
# the forward_auth gate and the v2 cookie-strip widening (termato_auth[A-Za-z0-9_]*=)
# are carried forward verbatim.
#
# Safety (see migrations/README.md): idempotent (skips if already v3), recovers the
# per-install values that aren't in .env.local (animal list + Caddy port) by PARSING the
# existing file, VALIDATES the new config before swapping, backs up the old one, and
# RESTORES it if the reload fails — never leaves a broken config live (Caddy fronts the
# whole app). If anything is uncertain it skips cleanly (exit 0) rather than risk it.
#
# Keep the generated body in sync with install.sh's Caddy block. Bump the version +
# add a new migration (004-…) when those rules change.

set -uo pipefail

CADDY_CONFIG_VERSION=3
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CADDYFILE="$INSTALL_DIR/private.Caddyfile"
MARKER="# termato-caddy-config-version: ${CADDY_CONFIG_VERSION}"

skip() { echo "003-caddy: $1 — skipping (no change)"; exit 0; }
fail() { echo "003-caddy: $1" >&2; exit 1; }

# Tunnel/animal installs only — a plain port-pattern (legacy) or non-tunnel box has no
# animal preview blocks here. .env.local carries the authoritative per-install config.
[ -f "$CADDYFILE" ]   || skip "no private.Caddyfile (not a tunnel install or custom proxy)"
[ -f "$INSTALL_DIR/.env.local" ] || skip "no .env.local"
set -a; . "$INSTALL_DIR/.env.local"; set +a

APP_HOST="${TERMATO_APP_HOST:-}"
DOMAIN="${TERMATO_COOKIE_DOMAIN:-${TERMATO_PREVIEW_DOMAIN:-}}"
USERNAME="${TERMATO_USERNAME:-}"
PORT_BASE="${TERMATO_PORT_BASE:-}"
APP_PORT="${PORT:-3002}"
[ -n "$APP_HOST" ] && [ -n "$DOMAIN" ] && [ -n "$USERNAME" ] && [ -n "$PORT_BASE" ] \
  || skip "missing APP_HOST/DOMAIN/USERNAME/PORT_BASE in .env.local"

# Already at this version? (filename-tracking already guarantees once-only; this is a
# second guard so a manual re-run is a no-op too.)
if head -1 "$CADDYFILE" | grep -qF "$MARKER"; then skip "already at config v$CADDY_CONFIG_VERSION"; fi

# Need the caddy binary to validate — without it we won't risk a swap.
CADDY_BIN="$INSTALL_DIR/bin/caddy"; [ -x "$CADDY_BIN" ] || CADDY_BIN="$(command -v caddy || true)"
[ -n "$CADDY_BIN" ] && [ -x "$CADDY_BIN" ] || skip "no caddy binary to validate with"
command -v pm2 >/dev/null 2>&1 || skip "pm2 not found (can't reload caddy)"

# Recover values NOT in .env.local from the existing file.
APP_HOST_RE="${APP_HOST//./\\.}"; USERNAME_RE="${USERNAME//./\\.}"; DOMAIN_RE="${DOMAIN//./\\.}"
CADDY_PORT="$(sed -nE "s#^http://${APP_HOST_RE}:([0-9]+) \{.*#\1#p" "$CADDYFILE" | head -1)"
[ -n "$CADDY_PORT" ] || skip "could not recover Caddy port from existing config"
# Animal list, in band order (= the order of preview blocks in the file).
mapfile -t ANIMALS < <(sed -nE "s#^http://([a-z0-9]+)-${USERNAME_RE}\.${DOMAIN_RE}:[0-9]+ \{.*#\1#p" "$CADDYFILE")
[ "${#ANIMALS[@]}" -gt 0 ] || skip "no preview blocks found to recover animal list"
# Sanity: env PORT_BASE must match the file's first preview port (i=0 → PORT_BASE).
grep -qE "reverse_proxy 127\.0\.0\.1:${PORT_BASE} \{" "$CADDYFILE" \
  || skip "PORT_BASE ($PORT_BASE) doesn't match existing config — config drifted, not touching it"

# Holding page served by handle_errors when the band port has no listener. Neutral tomato
# page (NOT a "starting server" claim — Caddy can't know one is starting) that quietly
# auto-refreshes, so it upgrades to the live preview as soon as a server starts. Kept in
# sync with install.sh's HOLD_HTML. (No apostrophes/backticks: bash single-quote + Caddy
# backtick-delimited body.)
HOLD_HTML='<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta http-equiv="refresh" content="3"><title>Termato preview</title><style>html,body{height:100%;margin:0}body{display:flex;flex-direction:column;gap:16px;align-items:center;justify-content:center;font-family:system-ui,-apple-system,sans-serif;background:#0b0b0c;color:#8a8f98;font-size:14px;text-align:center;padding:24px;box-sizing:border-box}.t{font-size:72px;line-height:1;filter:drop-shadow(0 6px 16px rgba(229,57,53,.4))}.h{color:#e8eaed;font-size:17px;font-weight:600}.s{max-width:320px;line-height:1.5;opacity:.85}</style></head><body><div class="t">🍅</div><div class="h">No preview running</div><div class="s">There is nothing to display here yet. This page will update by itself as soon as a preview server starts.</div></body></html>'

TMP="$(mktemp)" || fail "mktemp failed"
trap 'rm -f "$TMP"' EXIT
{
  printf '%s\n\n' "$MARKER"
  printf '{\n\tadmin off\n\tauto_https off\n}\n\n'
  printf 'http://%s:%s {\n\tbind 127.0.0.1\n\treverse_proxy 127.0.0.1:%s\n}\n\n' "$APP_HOST" "$CADDY_PORT" "$APP_PORT"
  for i in "${!ANIMALS[@]}"; do
    host="${ANIMALS[$i]}-${USERNAME}.${DOMAIN}"
    pport=$((PORT_BASE + i))
    printf 'http://%s:%s {\n' "$host" "$CADDY_PORT"
    printf '\tbind 127.0.0.1\n'
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
} > "$TMP"

# Validate BEFORE touching the live config.
"$CADDY_BIN" validate --config "$TMP" --adapter caddyfile >/dev/null 2>&1 \
  || fail "generated config failed caddy validate — aborting (live config untouched)"

BACKUP="$CADDYFILE.bak.$(date +%s)"
cp "$CADDYFILE" "$BACKUP" || fail "could not back up existing config"
cp "$TMP" "$CADDYFILE"    || fail "could not write new config"

# Reload (admin API is off, so restart the managed caddy process). Restore on failure.
if pm2 restart termato-caddy --update-env >/dev/null 2>&1; then
  echo "003-caddy: regenerated to config v$CADDY_CONFIG_VERSION (${#ANIMALS[@]} preview hosts); backup at $BACKUP"
  exit 0
else
  cp "$BACKUP" "$CADDYFILE"
  pm2 restart termato-caddy --update-env >/dev/null 2>&1 || true
  fail "caddy reload failed — restored previous config from $BACKUP"
fi
