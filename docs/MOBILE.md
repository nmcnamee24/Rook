# Rook Mobile Companion

Rook Mobile is a native SwiftUI iPhone companion. It keeps the existing Mac app as the private execution host instead of copying ChatGPT credentials, Gmail or Calendar connector state, local files, or computer-control authority onto the phone.

## Implemented connection

- Native iOS 26 target in `RookMobile.xcodeproj`.
- A four-surface iPhone companion: Rook, Activity, Library, and Moves.
- Rook centers the latest answer and one adaptive typed/voice composer; live work, Canvas, and pending decisions appear only when they are relevant.
- Activity uses a native grouped list for live and recent task crews with attributable pawn status, without hidden reasoning or raw pawn messages.
- Searchable Library outcomes and a pending/recorded Moves queue use standard iOS navigation, lists, forms, badges, and controls.
- Semantic system colors, materials, SF Symbols, Dynamic Type, and light/dark appearance let iOS provide native contrast and visual hierarchy.
- Settings shows the encrypted Mac link and sanitized Gmail, Calendar, and Spotify Ally availability; account management and credentials stay on the Mac.
- Shared `RookResponse`, Canvas, pawn, and queue-label contracts.
- Foreground push-to-talk using Apple's on-device `SpeechAnalyzer` and `SpeechTranscriber` path.
- Typed commands and live progress over the same encrypted bridge on a nearby network or through Rook's private internet relay.
- Face ID or device-passcode confirmation before approval messages leave the phone.
- Session tokens stored with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` in Keychain.
- Versioned one-megabyte-bounded wire messages with five-minute timestamp validation.
- Host policy that rejects commands before authentication and rejects response or snapshot spoofing from the phone.
- Address-free Bonjour discovery: the phone finds the exact paired Mac automatically on the same local network.
- QR pairing from **Rook menu → Pair iPhone…** with a five-minute one-time cryptographic secret.
- A built-in outbound WebSocket relay fallback for cellular and unrelated Wi-Fi networks; no VPN, port forwarding, public Mac address, or second networking app is required.
- ChaCha20-Poly1305 authenticated encryption for every bridge message, including messages forwarded by the relay.
- Duplicate-envelope rejection in addition to the five-minute timestamp window.
- Mac pairing store with six-digit confirmation codes, five-minute expiry, cryptographically random session tokens, token hashes in private files, raw tokens in each device's Keychain, and revocation support.
- Central-Rook command routing, sanitized Library/Moves snapshots, and exact queue decisions revalidated on the Mac.

## Connect an iPhone

1. Install and open Rook on the Mac.
2. Build and run `RookMobile.xcodeproj` on the iPhone from Xcode once.
3. Keep the Mac and iPhone on the same Wi-Fi network.
4. On the Mac, choose **Rook menu → Pair iPhone…**.
5. On the iPhone, open the pairing sheet, tap **Scan the QR code**, and scan the Mac.
6. Allow Camera and Local Network access when iOS asks.

After the first scan, Rook keeps only the stable Mac service identity and relay address in app preferences. The private session and relay access secrets stay in Keychain. Reopening the phone app first tries the nearby Bonjour path, then falls back to the internet relay without asking for an address or another app. If the nearby link closes because the phone moves from Wi-Fi to cellular, Rook reconnects automatically through the relay; bringing the app back to the foreground also restarts the connection.

The initial pairing deliberately remains local: the Mac and phone must be on the same Wi-Fi network when the QR code is scanned. Once paired with a relay-enabled Mac, the phone can reconnect over cellular or another Wi-Fi network whenever Rook is running and the Mac is online. Re-pairing the same phone rotates its session and immediately replaces the Mac's old relay channel.

## Trust boundary

The Mac remains authoritative. The phone may request work and make an exact decision about one current move. It may not impersonate a Rook response, create queue state, broaden an approval, execute a pawn, or access Codex authentication.

Face ID is a local user-experience gate rather than proof by itself. The Mac must still authenticate the paired session and revalidate the exact move against current queue state before recording or executing a decision.

Bonjour advertises a random stable service identity only on the local network. For remote connections, both devices make outbound TLS WebSocket connections to a role-separated relay room derived from the paired session token. The relay forwards opaque binary frames, keeps no message store, exposes no Mac port, and cannot decrypt Rook content. The QR contains no Codex, Gmail, Calendar, OAuth, or filesystem credential.

The deployment access key protects the private relay from arbitrary clients, but end-to-end security comes from the per-device session token and ChaCha20-Poly1305 envelope. The shared deployment key appears only in the short-lived local pairing QR and is then stored in both Keychains. If a pairing QR may have been photographed, rotate the relay key and pair devices again.

## Build

```bash
xcodebuild \
  -project RookMobile.xcodeproj \
  -scheme RookMobile \
  -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Run the shared protocol and pairing tests with:

```bash
swift test --filter RookMobile
```

Validate the relay with:

```bash
cd Relay
npm ci
npm run check
npm test
```

Permanent relay deployment requires one Cloudflare authorization. After `npx wrangler login`, run `./scripts/deploy-mobile-relay.sh`. The script validates the Worker, deploys it, creates a random access key on first setup, writes that key directly to Cloudflare's secret store and the signed Mac app's Keychain item, and stores only the public `wss://` endpoint in Rook's private config. Later deploys preserve the existing key so paired phones keep working. Set `ROOK_ROTATE_RELAY_ACCESS=1` only when intentionally rotating the deployment key, then pair each phone again. See [Relay deployment](RELAY.md).

The app accepts `--ui-preview` when launched from Simulator to render deterministic nonprivate sample data. Add `--ui-preview-tab=home`, `activity`, `library`, or `moves` to select a surface, or `--ui-preview-settings` to inspect Settings. Preview mode never connects to Rook or writes live private state.

Simulator builds verify compilation and rendering, but the QR camera, initial same-Wi-Fi pairing, and cellular fallback must be exercised on a physical iPhone. Rook Mobile currently maintains the link while the app is in the foreground; this phase does not claim background wake or push delivery.
