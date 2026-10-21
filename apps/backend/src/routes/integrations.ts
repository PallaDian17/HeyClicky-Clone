import { Hono } from "hono";
import { z } from "zod";
import { Composio } from "@composio/core";
import type { AuthedUser } from "../auth.js";

/**
 * Composio-backed integrations. Everything here is gated on COMPOSIO_API_KEY:
 * without it the catalog answers `configured: false` and the app shows only
 * custom connectors.
 *
 *   GET  /catalog     toolkits we offer + whether this user has connected each
 *   POST /connect     { toolkit } → hosted Composio connect link to open
 *   POST /disconnect  { connectedAccountId }
 *   POST /session     → { url, headers } of a per-user MCP endpoint scoped to
 *                      the toolkits the user connected
 */
export const integrationsRoute = new Hono<{ Variables: { user: AuthedUser } }>();

/** Toolkits offered in Setup. Slugs are Composio toolkit slugs. */
const CATALOG: { slug: string; name: string }[] = [
  { slug: "gmail", name: "Gmail" },
  { slug: "googlecalendar", name: "Google Calendar" },
  { slug: "googledrive", name: "Google Drive" },
  { slug: "notion", name: "Notion" },
  { slug: "slack", name: "Slack" },
  { slug: "github", name: "GitHub" },
  { slug: "linear", name: "Linear" },
];

let client: Composio | null = null;
function composio(): Composio | null {
  const key = process.env.COMPOSIO_API_KEY;
  if (!key) return null;
  client ??= new Composio({ apiKey: key });
  return client;
}

/** Composio user ids are our user ids; one namespace per backend deployment. */
function userId(u: AuthedUser): string {
  return u.dev ? "dev-local" : u.id;
}

type Connected = { slug: string; connectedAccountId: string; status: string };

async function connectedAccounts(c: Composio, uid: string): Promise<Connected[]> {
  const res = await c.connectedAccounts.list({ userIds: [uid] });
  return res.items
    .filter((a) => a.status === "ACTIVE" || a.status === "INITIATED")
    .map((a) => ({ slug: a.toolkit.slug, connectedAccountId: a.id, status: a.status }));
}

integrationsRoute.get("/catalog", async (c) => {
  const cx = composio();
  if (!cx) return c.json({ configured: false, toolkits: [] });
  try {
    const connected = await connectedAccounts(cx, userId(c.var.user));
    const toolkits = CATALOG.map((t) => {
      const match = connected.find((a) => a.slug === t.slug && a.status === "ACTIVE");
      return { ...t, connected: Boolean(match), connectedAccountId: match?.connectedAccountId ?? null };
    });
    return c.json({ configured: true, toolkits });
  } catch (err) {
    console.error("[integrations] catalog failed:", err);
    return c.json({ configured: true, toolkits: CATALOG.map((t) => ({ ...t, connected: false, connectedAccountId: null })), error: String(err) });
  }
});

const ConnectRequest = z.object({ toolkit: z.string().min(1).max(60), callbackUrl: z.string().url().optional() });

integrationsRoute.post("/connect", async (c) => {
  const cx = composio();
  if (!cx) return c.json({ error: "Composio is not configured (COMPOSIO_API_KEY)" }, 503);
  const parsed = ConnectRequest.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: "bad request", issues: parsed.error.issues }, 400);
  const { toolkit, callbackUrl } = parsed.data;
  if (!CATALOG.some((t) => t.slug === toolkit)) return c.json({ error: "unknown toolkit" }, 400);
  try {
    // One Composio-managed auth config per toolkit; create it on first use.
    const existing = await cx.authConfigs.list({ toolkit, isComposioManaged: true });
    let authConfigId = existing.items[0]?.id;
    if (!authConfigId) {
      const created = await cx.authConfigs.create(toolkit, { type: "use_composio_managed_auth", name: `Hi Dicky ${toolkit}` });
      authConfigId = created.id;
    }
    const request = await cx.connectedAccounts.link(userId(c.var.user), authConfigId, {
      callbackUrl: callbackUrl ?? "heyclickyclone://integrations/composio",
      allowMultiple: false,
    });
    console.log(`[integrations] connect ${toolkit} user=${userId(c.var.user)} request=${request.id}`);
    return c.json({ redirectUrl: request.redirectUrl, connectionRequestId: request.id });
  } catch (err) {
    console.error("[integrations] connect failed:", err);
    return c.json({ error: "connect failed", detail: String(err) }, 502);
  }
});

const DisconnectRequest = z.object({ connectedAccountId: z.string().min(1).max(120) });

integrationsRoute.post("/disconnect", async (c) => {
  const cx = composio();
  if (!cx) return c.json({ error: "Composio is not configured (COMPOSIO_API_KEY)" }, 503);
  const parsed = DisconnectRequest.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: "bad request", issues: parsed.error.issues }, 400);
  try {
    // Only this user's own accounts may be removed.
    const mine = await connectedAccounts(cx, userId(c.var.user));
    if (!mine.some((a) => a.connectedAccountId === parsed.data.connectedAccountId)) return c.json({ error: "not your account" }, 404);
    await cx.connectedAccounts.delete(parsed.data.connectedAccountId);
    return c.json({ ok: true });
  } catch (err) {
    console.error("[integrations] disconnect failed:", err);
    return c.json({ error: "disconnect failed", detail: String(err) }, 502);
  }
});

integrationsRoute.post("/session", async (c) => {
  const cx = composio();
  if (!cx) return c.json({ error: "Composio is not configured (COMPOSIO_API_KEY)" }, 503);
  try {
    const uid = userId(c.var.user);
    const toolkits = (await connectedAccounts(cx, uid)).filter((a) => a.status === "ACTIVE").map((a) => a.slug);
    if (toolkits.length === 0) return c.json({ url: null, headers: {}, toolkits: [] });
    const session = await cx.sessions.create(uid, { toolkits, mcp: true });
    console.log(`[integrations] session user=${uid} toolkits=${toolkits.join(",")}`);
    return c.json({ url: session.mcp.url, headers: session.mcp.headers, toolkits });
  } catch (err) {
    console.error("[integrations] session failed:", err);
    return c.json({ error: "session failed", detail: String(err) }, 502);
  }
});
