# Rook Mobile Relay

Rook's built-in relay lets the paired iPhone reach the authoritative Mac over cellular or an unrelated Wi-Fi network. Both devices create outbound WebSocket connections, so the Mac does not expose a port or public IP and the phone does not need Tailscale, a VPN profile, or another networking app.

## What the relay can see

The relay sees a random channel identifier, the `host` or `phone` role, frame sizes, and connection timing. It forwards only binary frames and stores no messages. Commands, responses, Canvas data, Library summaries, Moves, device IDs, and session tokens remain inside ChaCha20-Poly1305 envelopes encrypted between the paired phone and Mac.

The Worker rejects unsupported protocol versions, invalid deployment access keys, malformed channel identifiers, text frames, empty or over-one-megabyte frames, and clients that exceed its message or byte limits. Only one current socket per role remains in a channel. Socket replacement excludes closing connections from broadcasts and contains synchronous send/close races so a stale connection cannot reject its replacement. Cloudflare Worker observability is disabled in the tracked configuration.

## Deploy once

Cloudflare account authorization is the only interactive account step:

```bash
cd Relay
npx wrangler login
cd ..
./scripts/deploy-mobile-relay.sh
```

The deployment script performs these operations without printing the secret:

1. Installs the locked relay dependencies and runs the dry-run plus integration tests.
2. Deploys the Worker and Durable Object.
3. Generates a random 48-byte deployment access key.
4. pipes the key directly into the Cloudflare Worker secret store.
5. pipes the same key over standard input into Rook's macOS Keychain configuration command.
6. Stores only the public `wss://.../v1/connect` endpoint in `~/.codex/rook/core/config.json`.

If the Worker uses a custom domain and its URL cannot be detected from Wrangler output, rerun with `ROOK_RELAY_HTTP_URL=https://relay.example.com`.

On first setup, restart Rook and pair the iPhone again. The new QR transfers the public endpoint and deployment key during the local five-minute pairing window; the phone then puts the key in its own Keychain. Routine redeploys preserve that key, so existing pairings continue to work after Rook restarts.

The relay is designed for Cloudflare's Workers Free plan: it uses a SQLite-class Durable Object, persists no application data, and uses the WebSocket Hibernation API so idle connections do not accrue active-duration usage. Cloudflare currently makes SQLite Durable Objects available on the free plan and applies hard daily free limits rather than automatic overage billing. Check [Cloudflare's current Durable Objects pricing](https://developers.cloudflare.com/durable-objects/platform/pricing/) before deployment because provider terms can change.

## Verify cellular access

1. Confirm a normal nearby connection after re-pairing.
2. Turn off Wi-Fi on the iPhone, leaving cellular enabled.
3. Keep Rook running on the online Mac and open Rook Mobile in the foreground.
4. Reconnect and submit a harmless typed question.
5. Confirm the answer appears, then approve or reject a test Move only if one already exists and is safe to decide.

The local transport is intentionally attempted first, so nearby use avoids the relay. The phone's relay session explicitly permits cellular, expensive, and constrained paths and automatically reconnects when the nearby link closes or the app returns to the foreground. Current iOS behavior is foreground-only; the relay does not provide push notifications or background wake.

## Rotate or disable

Rerunning the deployment script preserves the existing access key. To rotate it deliberately, run `ROOK_ROTATE_RELAY_ACCESS=1 ./scripts/deploy-mobile-relay.sh`, restart Rook, and pair every phone again afterward. Rotate if a pairing QR may have been photographed.

To disable remote access while preserving nearby Bonjour connections:

```bash
~/Applications/Rook.app/Contents/MacOS/Rook --disable-mobile-relay
```

Deleting the Cloudflare Worker is a separate destructive operation and is intentionally not part of the local disable command.
