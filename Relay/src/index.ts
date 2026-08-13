import { DurableObject } from "cloudflare:workers";

interface Env {
  ROOK_RELAY: DurableObjectNamespace<RookRelayRoom>;
  ROOK_RELAY_ACCESS_KEY: string;
}

type RelayRole = "host" | "phone";

interface RelayAttachment {
  role: RelayRole;
  windowStartedAt: number;
  messagesInWindow: number;
  bytesInWindow: number;
}

const CHANNEL_HEADER = "X-Rook-Relay-Channel";
const ROLE_HEADER = "X-Rook-Relay-Role";
const VERSION_HEADER = "X-Rook-Relay-Version";
const ACCESS_HEADER = "X-Rook-Relay-Access";
const RELAY_VERSION = "1";
const MAX_MESSAGE_BYTES = 1_048_576;
const MAX_MESSAGES_PER_MINUTE = 180;
const MAX_BYTES_PER_MINUTE = 64 * 1_048_576;

const noStoreHeaders = {
  "Cache-Control": "no-store",
  "Content-Type": "application/json; charset=utf-8",
  "Referrer-Policy": "no-referrer",
  "X-Content-Type-Options": "nosniff",
};

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), { status, headers: noStoreHeaders });
}

function validChannel(value: string | null): value is string {
  return value !== null && /^[A-Za-z0-9_-]{43}$/.test(value);
}

function roleFrom(request: Request): RelayRole | null {
  const role = request.headers.get(ROLE_HEADER);
  return role === "host" || role === "phone" ? role : null;
}

function opposite(role: RelayRole): RelayRole {
  return role === "host" ? "phone" : "host";
}

async function constantTimeEqual(left: string, right: string): Promise<boolean> {
  const encoder = new TextEncoder();
  const [leftDigest, rightDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(left)),
    crypto.subtle.digest("SHA-256", encoder.encode(right)),
  ]);
  return crypto.subtle.timingSafeEqual(leftDigest, rightDigest);
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/health") {
      return json(200, { ok: true, service: "rook-mobile-relay", version: 1 });
    }
    if (url.pathname !== "/v1/connect") {
      return json(404, { error: "not_found" });
    }
    if (request.method !== "GET" || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") {
      return json(426, { error: "websocket_required" });
    }
    if (request.headers.get(VERSION_HEADER) !== RELAY_VERSION) {
      return json(400, { error: "unsupported_version" });
    }
    const access = request.headers.get(ACCESS_HEADER);
    if (
      typeof env.ROOK_RELAY_ACCESS_KEY !== "string" ||
      env.ROOK_RELAY_ACCESS_KEY.length < 32 ||
      access === null ||
      !(await constantTimeEqual(access, env.ROOK_RELAY_ACCESS_KEY))
    ) {
      return json(401, { error: "unauthorized" });
    }
    const channel = request.headers.get(CHANNEL_HEADER);
    const role = roleFrom(request);
    if (!validChannel(channel) || role === null) {
      return json(400, { error: "invalid_handshake" });
    }

    const room = env.ROOK_RELAY.get(env.ROOK_RELAY.idFromName(channel));
    return room.fetch(request);
  },
} satisfies ExportedHandler<Env>;

export class RookRelayRoom extends DurableObject<Env> {
  async fetch(request: Request): Promise<Response> {
    const role = roleFrom(request);
    if (role === null) {
      return json(400, { error: "invalid_role" });
    }

    for (const stale of this.ctx.getWebSockets(role)) {
      this.closeIfOpen(stale, 4001, "Replaced by a newer Rook connection");
    }

    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);
    this.ctx.acceptWebSocket(server, [role]);
    server.serializeAttachment({
      role,
      windowStartedAt: Date.now(),
      messagesInWindow: 0,
      bytesInWindow: 0,
    } satisfies RelayAttachment);
    server.send(JSON.stringify({ type: "ready" }));
    this.broadcastPeerState();

    return new Response(null, {
      status: 101,
      webSocket: client,
      headers: {
        "Cache-Control": "no-store",
        "Referrer-Policy": "no-referrer",
      },
    });
  }

  webSocketMessage(socket: WebSocket, message: ArrayBuffer | string): void {
    if (typeof message === "string") {
      socket.close(4002, "Binary frames only");
      return;
    }
    if (message.byteLength === 0 || message.byteLength > MAX_MESSAGE_BYTES) {
      socket.close(4003, "Frame size rejected");
      return;
    }

    const attachment = socket.deserializeAttachment() as RelayAttachment | null;
    if (attachment === null || (attachment.role !== "host" && attachment.role !== "phone")) {
      socket.close(4004, "Missing relay role");
      return;
    }
    if (!this.withinRateLimit(socket, attachment, message.byteLength)) {
      socket.close(4008, "Rate limit exceeded");
      return;
    }

    for (const peer of this.openWebSockets(opposite(attachment.role))) {
      this.sendIfOpen(peer, message);
    }
  }

  webSocketClose(_socket: WebSocket, _code: number, _reason: string, _wasClean: boolean): void {
    this.broadcastPeerState();
  }

  webSocketError(socket: WebSocket): void {
    this.closeIfOpen(socket, 1011, "Relay connection failed");
    this.broadcastPeerState();
  }

  private withinRateLimit(socket: WebSocket, attachment: RelayAttachment, bytes: number): boolean {
    const now = Date.now();
    if (now - attachment.windowStartedAt >= 60_000) {
      attachment.windowStartedAt = now;
      attachment.messagesInWindow = 0;
      attachment.bytesInWindow = 0;
    }
    attachment.messagesInWindow += 1;
    attachment.bytesInWindow += bytes;
    socket.serializeAttachment(attachment);
    return (
      attachment.messagesInWindow <= MAX_MESSAGES_PER_MINUTE &&
      attachment.bytesInWindow <= MAX_BYTES_PER_MINUTE
    );
  }

  private broadcastPeerState(): void {
    const hosts = this.openWebSockets("host");
    const phones = this.openWebSockets("phone");
    const connected = hosts.length > 0 && phones.length > 0;
    for (const host of hosts) {
      this.sendIfOpen(host, JSON.stringify({ type: "peer", connected }));
    }
    for (const phone of phones) {
      this.sendIfOpen(phone, JSON.stringify({ type: "peer", connected }));
    }
  }

  private openWebSockets(role: RelayRole): WebSocket[] {
    return this.ctx.getWebSockets(role).filter((socket) => socket.readyState === WebSocket.OPEN);
  }

  private sendIfOpen(socket: WebSocket, message: ArrayBuffer | string): boolean {
    if (socket.readyState !== WebSocket.OPEN) return false;
    try {
      socket.send(message);
      return true;
    } catch {
      return false;
    }
  }

  private closeIfOpen(socket: WebSocket, code: number, reason: string): void {
    if (socket.readyState !== WebSocket.OPEN) return;
    try {
      socket.close(code, reason);
    } catch {
      // The runtime may advance the socket to closing between readyState and close().
    }
  }
}
