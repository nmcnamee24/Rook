# Security Policy

## Supported version

Rook is a private, single-user application. Only the current `main` branch and the latest installed build are supported.

## Reporting a vulnerability

Report suspected vulnerabilities privately to the repository owner. Do not include credentials, authentication artifacts, private transcripts, email content, Calendar details, or screenshots containing personal data in an issue or commit.

Include the affected component, reproduction conditions, expected boundary, observed behavior, and a minimal non-sensitive proof of concept. Revoke or rotate any exposed credential before further testing.

## Security boundaries

- Codex owns authentication; Rook must not read or copy ChatGPT credentials.
- Local state is private to the current macOS user.
- Gmail sends, Calendar commitments, publishing, purchasing, booking, applying, deletion, installation, credential entry, and access changes stop at their approval or user-handoff boundary.
- Task pawns and Librarian context workers are read-only and never operate applications.
- Remote Canvas images must be direct public HTTPS resources; local, authenticated, tracking, and insecure URLs are rejected.
- Screen captures require an explicit user request and macOS Screen Recording permission. They are stored with private local permissions and attached only to the authenticated central Codex request that triggered the capture; they are never delegated to pawns or copied into speech, Library records, queue metadata, or logs.
- The iPhone is a client of the authoritative Mac. It never receives Codex, connector, filesystem, or computer-control credentials and cannot broaden an approval.
- Mobile bridge payloads are end-to-end authenticated and encrypted with per-device Keychain secrets whether they travel directly over Bonjour or through the internet relay. Duplicate envelope IDs are rejected.
- The relay accepts only authenticated, bounded binary frames for one host and one phone role per derived channel. It stores no messages, has observability disabled, and cannot decrypt content. Relay access secrets belong only in Cloudflare's secret store and device Keychains, never tracked config or logs.
