# Rook connections

Rook includes native OAuth for Google and Spotify plus direct Spotify account commands. Open **Rook → Allies**, choose **Set up** or **Connect**, and paste the public client ID from the provider's developer dashboard. Rook never asks for or stores a client secret.

## Security model

- Authorization uses the system browser, Authorization Code + PKCE (S256), a random CSRF `state`, and a five-minute loopback listener bound to `127.0.0.1`.
- OAuth access and refresh tokens are encoded into one provider credential and stored in macOS Keychain with `AfterFirstUnlockThisDeviceOnly` accessibility.
- Public client IDs are stored mode `600` in `~/.codex/rook/core/connections.json`.
- Tokens, authorization codes, callback URLs, and account details never enter the Library, pawn prompts, Codex prompts, logs, queue items, or speech.
- Disconnect removes Rook's local Keychain credential. It does not delete the provider account.

## Google: Gmail + Calendar

One Google OAuth client powers both cards.

1. Open [Google Cloud credentials](https://console.cloud.google.com/apis/credentials).
2. Create or select a project and enable the **Gmail API** and **Google Calendar API**.
3. Configure the OAuth consent screen. While the app is in testing, add your Google account as a test user.
4. Create an OAuth Client ID with application type **Desktop app**.
5. Copy the client ID ending in `.apps.googleusercontent.com` into Rook's Google setup sheet.
6. Choose **Save and connect**, then approve access in the browser.

Rook requests `openid`, `email`, `gmail.readonly`, and `calendar.events`. Gmail's read scope is classified by Google as restricted. A private testing app can authorize listed test users, while public distribution may require Google verification. `calendar.events` is the narrow event-editing scope available from Google; Rook's own policy still blocks deletion, RSVP, attendee, recurrence, and secondary-calendar mutations outside their approval boundary. Direct Gmail OAuth intentionally omits Gmail send and full-mailbox scopes.

## Spotify

1. Open the [Spotify Developer Dashboard](https://developer.spotify.com/dashboard) and create an app.
2. Add `http://127.0.0.1:8888/oauth/callback` to the app's Redirect URIs. The explicit loopback address is local to this Mac; Spotify permits HTTP for loopback IP literals.
3. Copy the app's Client ID into Rook's Spotify setup sheet.
4. Choose **Save and connect**, then approve access in the browser.

Rook requests profile, private-playlist, recently-played, playback-state, playback-control, and top-item scopes. It does not request playlist modification scopes. Spotify's current Development Mode is intended for personal testing, requires the app owner to have Premium, and limits authorized users.

When connected, exact commands use Spotify directly without Codex or pawns. Supported paths include named playlist or catalog playback, semantic study/work/focus playlist recommendations, playlist summaries, recently played tracks, top tracks and artists, now-playing state, available devices, and playback transfer. Rook checks the user's own playlists before catalog search, ranks purpose requests from the library's titles and Spotify descriptions, limits recommendations to five likely matches, limits current catalog search pages to Spotify's 2026 maximum of ten results, caches playlist metadata for five minutes, and keeps source attribution in the Spotify Canvas panel. Basic play, pause, next, and previous controls continue through the local Mac bridge even if OAuth is unavailable.

## Current milestone boundary

This release completes sign-in, secure persistence, refresh support, account verification, and the native Spotify search/device/playback client. Existing Gmail and Calendar work continues through Codex-managed connections. Their next milestone is guarded native incremental Gmail sync and Calendar reads/writes under Rook's existing action policy.
