import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { spawn } from "node:child_process";
import WebSocket from "ws";

const relayHTTP = "http://127.0.0.1:8787";
const relayWebSocket = "ws://127.0.0.1:8787/v1/connect";
const channel = "A".repeat(43);
let worker;

before(async () => {
  worker = spawn("npm", [
    "exec",
    "wrangler",
    "--",
    "dev",
    "--local",
    "--port",
    "8787",
    "--var",
    "ROOK_RELAY_ACCESS_KEY:development-only-rook-relay-access-key",
  ], {
    cwd: new URL("..", import.meta.url),
    stdio: ["ignore", "pipe", "pipe"],
  });
  const deadline = Date.now() + 20_000;
  while (Date.now() < deadline) {
    try {
      const response = await fetch(`${relayHTTP}/health`);
      if (response.ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 200));
  }
  throw new Error("Local Rook relay did not become ready");
});

after(() => {
  worker?.kill("SIGTERM");
});

function connect(role) {
  const socket = new WebSocket(relayWebSocket, {
    headers: {
      "X-Rook-Relay-Channel": channel,
      "X-Rook-Relay-Role": role,
      "X-Rook-Relay-Version": "1",
      "X-Rook-Relay-Access": "development-only-rook-relay-access-key",
    },
  });
  const messages = [];
  const waiters = [];
  socket.on("message", (data, isBinary) => {
    const value = isBinary ? Buffer.from(data) : JSON.parse(data.toString());
    const index = waiters.findIndex((waiter) => waiter.predicate(value));
    if (index >= 0) {
      const [waiter] = waiters.splice(index, 1);
      waiter.resolve(value);
    } else {
      messages.push(value);
    }
  });
  return new Promise((resolve, reject) => {
    socket.once("open", () => {
      resolve({
        socket,
        next(predicate, timeout = 5_000) {
          const existing = messages.findIndex(predicate);
          if (existing >= 0) return Promise.resolve(messages.splice(existing, 1)[0]);
          return new Promise((nextResolve, nextReject) => {
            const waiter = { predicate, resolve: nextResolve };
            waiters.push(waiter);
            setTimeout(() => {
              const index = waiters.indexOf(waiter);
              if (index >= 0) waiters.splice(index, 1);
              nextReject(new Error("Timed out waiting for relay message"));
            }, timeout).unref();
          });
        },
      });
    });
    socket.once("error", reject);
  });
}

test("forwards opaque binary frames only between paired roles", async () => {
  const host = await connect("host");
  await host.next((message) => message.type === "ready");

  const phone = await connect("phone");
  await phone.next((message) => message.type === "ready");
  await host.next((message) => message.type === "peer" && message.connected === true);
  await phone.next((message) => message.type === "peer" && message.connected === true);

  const commandFrame = Buffer.from([0, 4, 8, 15, 16, 23, 42]);
  phone.socket.send(commandFrame);
  assert.deepEqual(await host.next(Buffer.isBuffer), commandFrame);

  const responseFrame = Buffer.from([42, 23, 16, 15, 8, 4, 0]);
  host.socket.send(responseFrame);
  assert.deepEqual(await phone.next(Buffer.isBuffer), responseFrame);

  phone.socket.terminate();
  await host.next((message) => message.type === "peer" && message.connected === false);
  host.socket.close();
});

test("replaces an existing phone without rejecting the new WebSocket", async () => {
  const host = await connect("host");
  await host.next((message) => message.type === "ready");

  const firstPhone = await connect("phone");
  await firstPhone.next((message) => message.type === "ready");
  await host.next((message) => message.type === "peer" && message.connected === true);
  await firstPhone.next((message) => message.type === "peer" && message.connected === true);

  const firstPhoneClosed = new Promise((resolve) => firstPhone.socket.once("close", resolve));
  const replacementPhone = await connect("phone");
  await replacementPhone.next((message) => message.type === "ready");
  await replacementPhone.next(
    (message) => message.type === "peer" && message.connected === true,
  );
  await firstPhoneClosed;

  const replacementFrame = Buffer.from([82, 111, 111, 107]);
  replacementPhone.socket.send(replacementFrame);
  assert.deepEqual(await host.next(Buffer.isBuffer), replacementFrame);

  replacementPhone.socket.close();
  host.socket.close();
});

test("rejects a WebSocket without the deployment access key", async () => {
  const status = await new Promise((resolve, reject) => {
    const socket = new WebSocket(relayWebSocket, {
      headers: {
        "X-Rook-Relay-Channel": channel,
        "X-Rook-Relay-Role": "phone",
        "X-Rook-Relay-Version": "1",
        "X-Rook-Relay-Access": "invalid-development-access-token",
      },
    });
    socket.once("open", () => reject(new Error("Unauthorized relay connection opened")));
    socket.once("unexpected-response", (_request, response) => {
      response.resume();
      resolve(response.statusCode);
    });
    socket.once("error", () => {});
  });
  assert.equal(status, 401);
});
