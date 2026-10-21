#!/usr/bin/env node
// A tiny custom connector for testing: an OAuth 2.1 authorization server that
// auto-approves (metadata, dynamic registration, PKCE, refresh) in front of a
// Streamable-HTTP MCP server with two tools. Every MCP call is appended to
// MOCK_LOG so a test can prove an agent reached it with a valid token.
//
//   node scripts/mock-connector.mjs            # http://localhost:8891/mcp
//   PORT=8891 MOCK_LOG=/tmp/mock.log node scripts/mock-connector.mjs

import { createServer } from "node:http";
import { createHash, randomBytes } from "node:crypto";
import { appendFileSync } from "node:fs";

const port = Number(process.env.PORT ?? 8891);
const origin = `http://localhost:${port}`;
const logFile = process.env.MOCK_LOG;
const clients = new Map();   // client_id -> registration
const codes = new Map();     // code -> {challenge, client_id, redirect_uri}
const tokens = new Map();    // access_token -> expiresAt
const refreshTokens = new Set();
const notes = [];

function log(line) {
  const text = `${new Date().toISOString()} ${line}`;
  console.log(text);
  if (logFile) appendFileSync(logFile, text + "\n");
}
function json(res, status, body, headers = {}) {
  res.writeHead(status, { "content-type": "application/json", ...headers });
  res.end(JSON.stringify(body));
}
async function readBody(req) {
  const chunks = [];
  for await (const c of req) chunks.push(c);
  return Buffer.concat(chunks).toString("utf8");
}
function issueTokens() {
  const access = "at_" + randomBytes(16).toString("hex");
  const refresh = "rt_" + randomBytes(16).toString("hex");
  tokens.set(access, Date.now() + 3600_000);
  refreshTokens.add(refresh);
  return { access_token: access, token_type: "Bearer", expires_in: 3600, refresh_token: refresh };
}

const tools = [
  { name: "get_weather", description: "Current weather for a city (mock).", inputSchema: { type: "object", properties: { city: { type: "string" } }, required: ["city"] } },
  { name: "add_note", description: "Append a note to the mock notebook.", inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } },
  { name: "delete_note", description: "Delete every note in the mock notebook.", inputSchema: { type: "object", properties: {} } },
];

function mcp(msg) {
  const { id, method, params } = msg;
  switch (method) {
    case "initialize":
      return { jsonrpc: "2.0", id, result: { protocolVersion: "2025-06-18", capabilities: { tools: {} }, serverInfo: { name: "mock-connector", version: "0.1.0" } } };
    case "ping":
      return { jsonrpc: "2.0", id, result: {} };
    case "tools/list":
      return { jsonrpc: "2.0", id, result: { tools } };
    case "tools/call": {
      const { name, arguments: args = {} } = params ?? {};
      log(`tools/call ${name} ${JSON.stringify(args)}`);
      if (name === "get_weather") return { jsonrpc: "2.0", id, result: { content: [{ type: "text", text: `Weather in ${args.city}: 24°C, light breeze, mock-clear skies.` }] } };
      if (name === "add_note") { notes.push(args.text); return { jsonrpc: "2.0", id, result: { content: [{ type: "text", text: `Saved note #${notes.length}.` }] } }; }
      if (name === "delete_note") { notes.length = 0; return { jsonrpc: "2.0", id, result: { content: [{ type: "text", text: "All notes deleted." }] } }; }
      return { jsonrpc: "2.0", id, error: { code: -32602, message: `unknown tool ${name}` } };
    }
    default:
      if (id === undefined) return null; // notification
      return { jsonrpc: "2.0", id, error: { code: -32601, message: `unknown method ${method}` } };
  }
}

const server = createServer(async (req, res) => {
  const url = new URL(req.url, origin);
  const path = url.pathname;

  if (path.startsWith("/.well-known/oauth-protected-resource")) {
    return json(res, 200, { resource: `${origin}/mcp`, authorization_servers: [origin], bearer_methods_supported: ["header"] });
  }
  if (path === "/.well-known/oauth-authorization-server" || path === "/.well-known/openid-configuration") {
    return json(res, 200, {
      issuer: origin, authorization_endpoint: `${origin}/authorize`, token_endpoint: `${origin}/token`,
      registration_endpoint: `${origin}/register`, response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"], code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"], scopes_supported: ["notes:read", "notes:write"],
    });
  }
  if (path === "/register" && req.method === "POST") {
    const body = JSON.parse(await readBody(req) || "{}");
    const client_id = "client_" + randomBytes(6).toString("hex");
    clients.set(client_id, body);
    log(`register ${client_id} ${body.client_name ?? ""} redirect=${(body.redirect_uris ?? []).join(",")}`);
    return json(res, 201, { client_id, client_name: body.client_name, redirect_uris: body.redirect_uris, token_endpoint_auth_method: "none" });
  }
  if (path === "/authorize") {
    const p = url.searchParams;
    const client = clients.get(p.get("client_id"));
    if (!client || !(client.redirect_uris ?? []).includes(p.get("redirect_uri"))) return json(res, 400, { error: "invalid_client" });
    if (p.get("code_challenge_method") !== "S256") return json(res, 400, { error: "invalid_request", error_description: "PKCE S256 required" });
    const code = "code_" + randomBytes(8).toString("hex");
    codes.set(code, { challenge: p.get("code_challenge"), client_id: p.get("client_id"), redirect_uri: p.get("redirect_uri") });
    const target = new URL(p.get("redirect_uri"));
    target.searchParams.set("code", code);
    target.searchParams.set("state", p.get("state") ?? "");
    log(`authorize auto-approved for ${p.get("client_id")} scope=${p.get("scope") ?? "-"}`);
    res.writeHead(302, { location: target.toString() });
    return res.end();
  }
  if (path === "/token" && req.method === "POST") {
    const form = new URLSearchParams(await readBody(req));
    const grant = form.get("grant_type");
    if (grant === "authorization_code") {
      const entry = codes.get(form.get("code"));
      codes.delete(form.get("code"));
      if (!entry) return json(res, 400, { error: "invalid_grant" });
      const expected = createHash("sha256").update(form.get("code_verifier") ?? "").digest("base64url");
      if (expected !== entry.challenge) return json(res, 400, { error: "invalid_grant", error_description: "PKCE verifier mismatch" });
      log("token issued (authorization_code)");
      return json(res, 200, issueTokens());
    }
    if (grant === "refresh_token") {
      if (!refreshTokens.delete(form.get("refresh_token"))) return json(res, 400, { error: "invalid_grant" });
      log("token issued (refresh_token)");
      return json(res, 200, issueTokens());
    }
    return json(res, 400, { error: "unsupported_grant_type" });
  }
  if (path === "/mcp") {
    const auth = req.headers.authorization ?? "";
    const token = auth.startsWith("Bearer ") ? auth.slice(7) : "";
    const exp = tokens.get(token);
    if (!exp || exp < Date.now()) {
      log(`mcp ${req.method} rejected: ${token ? "bad/expired token" : "no token"}`);
      res.writeHead(401, { "www-authenticate": `Bearer resource_metadata="${origin}/.well-known/oauth-protected-resource"` });
      return res.end();
    }
    if (req.method === "GET") { res.writeHead(405); return res.end(); }
    if (req.method === "DELETE") { res.writeHead(200); return res.end(); }
    const body = await readBody(req);
    let msg;
    try { msg = JSON.parse(body); } catch { return json(res, 400, { error: "bad json" }); }
    const messages = Array.isArray(msg) ? msg : [msg];
    const replies = messages.map(mcp).filter(Boolean);
    for (const m of messages) if (m.method !== "tools/call") log(`mcp ${m.method}`);
    if (replies.length === 0) { res.writeHead(202); return res.end(); }
    return json(res, 200, Array.isArray(msg) ? replies : replies[0], { "mcp-session-id": "mock-session" });
  }
  res.writeHead(404);
  res.end();
});

server.listen(port, () => log(`mock connector listening on ${origin}/mcp (auto-approving OAuth)`));
