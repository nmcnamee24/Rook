#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
RELAY_DIR="$PROJECT_DIR/Relay"
DEPLOY_LOG="$(/usr/bin/mktemp -t rook-relay-deploy)"
trap '/bin/rm -f "$DEPLOY_LOG"' EXIT

cd "$RELAY_DIR"
npm ci

WHOAMI="$(npm exec wrangler -- whoami 2>&1)"
if [[ "$WHOAMI" == *"not authenticated"* ]]; then
  print -u2 "Cloudflare authorization is required before Rook can create its private relay."
  print -u2 "Run: cd \"$RELAY_DIR\" && npx wrangler login"
  exit 2
fi

npm run check
npm test
npm exec wrangler -- deploy | tee "$DEPLOY_LOG"

RELAY_HTTP_URL="${ROOK_RELAY_HTTP_URL:-}"
if [[ -z "$RELAY_HTTP_URL" ]]; then
  RELAY_HTTP_URL="$(/usr/bin/grep -Eo 'https://[A-Za-z0-9._-]+\.workers\.dev' "$DEPLOY_LOG" | /usr/bin/tail -1)"
fi
if [[ -z "$RELAY_HTTP_URL" || "$RELAY_HTTP_URL" != https://* ]]; then
  print -u2 "The Worker deployed, but its HTTPS address could not be detected."
  print -u2 "Set ROOK_RELAY_HTTP_URL to the deployed https:// address and run this script again."
  exit 1
fi

RELAY_ENDPOINT="wss://${RELAY_HTTP_URL#https://}/v1/connect"
"$SCRIPT_DIR/build-app.sh" >/dev/null
CONFIGURE_BINARY="$PROJECT_DIR/.artifacts.noindex/Rook.app/Contents/MacOS/Rook"
REMOTE_SECRETS="$(npm exec wrangler -- secret list 2>/dev/null)"
ROTATE_ACCESS="${ROOK_ROTATE_RELAY_ACCESS:-0}"

if [[ "$ROTATE_ACCESS" != "1" ]] \
  && "$CONFIGURE_BINARY" --mobile-relay-token-status >/dev/null 2>&1 \
  && [[ "$REMOTE_SECRETS" == *'"name": "ROOK_RELAY_ACCESS_KEY"'* ]]; then
  "$CONFIGURE_BINARY" --configure-mobile-relay-endpoint "$RELAY_ENDPOINT" >/dev/null
  PAIRING_REQUIRED=0
else
  ACCESS_TOKEN="$(/usr/bin/openssl rand -base64 48 | /usr/bin/tr -d '\n')"
  print -rn -- "$ACCESS_TOKEN" | npm exec wrangler -- secret put ROOK_RELAY_ACCESS_KEY
  print -rn -- "$ACCESS_TOKEN" | "$CONFIGURE_BINARY" --configure-mobile-relay "$RELAY_ENDPOINT" >/dev/null
  ACCESS_TOKEN=""
  PAIRING_REQUIRED=1
fi

/usr/bin/curl --fail --silent --show-error "$RELAY_HTTP_URL/health" >/dev/null
print "Rook's private relay is live at $RELAY_ENDPOINT"
if [[ "$PAIRING_REQUIRED" == "1" ]]; then
  print "Restart Rook, then pair the iPhone again while both devices are on the same Wi-Fi network."
else
  print "Restart Rook. Existing paired phones keep their relay access."
fi
