#!/usr/bin/env node
// Firebase Realtime Database REST API'sinin oda için kullanılan alt kümesi: GET/PUT/PATCH/POST/DELETE,
// {".sv":"timestamp"} ve text/event-stream canlı akışı. Kimlik doğrulaması yok; yalnızca yerel geliştirme.
//
//   node scripts/dev-room-server.mjs [port]      (varsayılan 9000)
//   KD_ROOM_SERVER=http://127.0.0.1:9000 open dist/KDPlayer.app
import http from "node:http";

const port = Number(process.argv[2] ?? 9000);
let root = {};
const listeners = new Set();
let pushCounter = 0;

const split = (p) => p.split("/").filter(Boolean);
const clone = (v) => (v === undefined ? null : JSON.parse(JSON.stringify(v)));

function resolve(value, now) {
  if (value && typeof value === "object") {
    if (value[".sv"] === "timestamp") return now;
    const out = Array.isArray(value) ? [] : {};
    for (const [k, v] of Object.entries(value)) out[k] = resolve(v, now);
    return out;
  }
  return value;
}

function getAt(keys) {
  let node = root;
  for (const k of keys) {
    if (node === null || typeof node !== "object" || !(k in node)) return null;
    node = node[k];
  }
  return node ?? null;
}

function prune(node) {
  if (node && typeof node === "object") {
    for (const k of Object.keys(node)) {
      node[k] = prune(node[k]);
      if (node[k] === null || (typeof node[k] === "object" && Object.keys(node[k]).length === 0)) delete node[k];
    }
  }
  return node;
}

function setAt(keys, value) {
  if (keys.length === 0) { root = value && typeof value === "object" ? value : {}; prune(root); return; }
  let node = root;
  for (const k of keys.slice(0, -1)) {
    if (node[k] === null || typeof node[k] !== "object") node[k] = {};
    node = node[k];
  }
  const last = keys[keys.length - 1];
  if (value === null || value === undefined) delete node[last]; else node[last] = value;
  prune(root);
}

function notify(writeKeys, kind, payload) {
  for (const l of listeners) {
    const lk = l.keys;
    const inside = lk.every((k, i) => writeKeys[i] === k) && writeKeys.length >= lk.length;
    const above = writeKeys.every((k, i) => lk[i] === k) && lk.length > writeKeys.length;
    if (inside) {
      const rel = "/" + writeKeys.slice(lk.length).join("/");
      send(l.res, kind, rel, kind === "patch" ? payload : clone(getAt(writeKeys)));
    } else if (above) {
      send(l.res, "put", "/", clone(getAt(lk)));
    }
  }
}

function send(res, event, path, data) {
  res.write(`event: ${event}\ndata: ${JSON.stringify({ path, data })}\n\n`);
}

function pushID(now) {
  return now.toString(36).padStart(9, "0") + (pushCounter++).toString(36).padStart(4, "0");
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, "http://localhost");
  const keys = split(url.pathname.replace(/\.json$/, ""));
  const now = Date.now();
  if (req.method === "GET" && (req.headers.accept ?? "").includes("text/event-stream")) {
    res.writeHead(200, { "Content-Type": "text/event-stream", "Cache-Control": "no-cache", Connection: "keep-alive" });
    const listener = { keys, res };
    listeners.add(listener);
    send(res, "put", "/", clone(getAt(keys)));
    const keepAlive = setInterval(() => res.write("event: keep-alive\ndata: null\n\n"), 30000);
    req.on("close", () => { clearInterval(keepAlive); listeners.delete(listener); });
    return;
  }
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    const json = body ? JSON.parse(body) : null;
    let result = null;
    switch (req.method) {
      case "GET": result = getAt(keys); break;
      case "PUT": result = resolve(json, now); setAt(keys, clone(result)); notify(keys, "put"); break;
      case "PATCH": {
        result = resolve(json, now);
        for (const [k, v] of Object.entries(result)) setAt([...keys, ...split(k)], clone(v));
        notify(keys, "patch", result);
        break;
      }
      case "POST": {
        const name = pushID(now);
        const value = resolve(json, now);
        setAt([...keys, name], value);
        notify([...keys, name], "put");
        result = { name };
        break;
      }
      case "DELETE": setAt(keys, null); notify(keys, "put"); break;
      default: res.writeHead(405); res.end(); return;
    }
    res.writeHead(200, { "Content-Type": "application/json" });
    res.end(JSON.stringify(result ?? null));
    console.log(new Date(now).toISOString().slice(11, 23), req.method, url.pathname, body.length > 120 ? body.slice(0, 120) + "…" : body);
  });
});

server.listen(port, "127.0.0.1", () => console.log(`KD Player oda geliştirme sunucusu: http://127.0.0.1:${port}`));
