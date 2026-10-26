import { Hono } from "hono";
import { z } from "zod";
import { chatJSON, OpenAIError, type ChatMessage } from "../openai.js";
import type { AuthedUser } from "../auth.js";

// Memory of the user: two short notes the app keeps on disk (PROFILE.md for
// durable habits and preferences, VOLATILE.md for the current project) and
// injects into the voice prompt, the chat and every Clicky. This route
// rewrites them from a batch of recent exchanges.

export const MemoryExtractRequest = z.object({
  profile: z.string().max(4000).default(""),
  volatile: z.string().max(3000).default(""),
  exchanges: z
    .array(z.object({ source: z.string().max(60), user: z.string().max(1500), assistant: z.string().max(1500) }))
    .min(1)
    .max(12),
});
export type MemoryExtractRequest = z.infer<typeof MemoryExtractRequest>;

export type MemoryExtractResponse = { profile: string; volatile: string; changed: boolean };

const schema = {
  type: "object",
  additionalProperties: false,
  properties: {
    profile: { type: "string" },
    volatile: { type: "string" },
    changed: { type: "boolean" },
  },
  required: ["profile", "volatile", "changed"],
};

export const MEMORY_SYSTEM_PROMPT = `You maintain two short notes that Clicky, a Mac assistant, keeps about its user. You get the current notes and a few recent exchanges (what the user said to Clicky or to one of their helper agents, and the reply). Rewrite the notes.

PROFILE.md — durable things about the user: name, what they do, the tools and apps they use, how they like answers (length, tone, format), naming and formatting habits, language, standing instructions ("don't announce yourself", "call me Ash"). Only what the user stated or clearly implied about themselves. Stable across weeks. At most 15 lines.
VOLATILE.md — what they are working on right now: the current project, the thing they were stuck on, what they asked for today. Replace items that are clearly stale; keep it to the last few days. At most 8 lines.

Rules:
- Markdown bullet lines ("- …"), third person ("Prefers short answers"), concrete and short. Keep existing lines unless they are contradicted or stale; merge, do not duplicate.
- NEVER store passwords, verification codes, OTPs, card or account numbers, API keys, tokens, street addresses, phone numbers, or health or financial specifics, even if the user said them. Skip them silently.
- Do not record what Clicky or an agent said, only what it reveals about the user. Do not record one-off trivia.
- If nothing worth remembering is new, return both notes unchanged and changed=false.`;

export function buildMemoryMessages(req: MemoryExtractRequest): ChatMessage[] {
  const exchanges = req.exchanges
    .map((e, i) => `${i + 1}. [${e.source}] User: ${e.user}\n   Reply: ${e.assistant}`)
    .join("\n\n");
  const text = `Current PROFILE.md:\n${req.profile.trim() || "(empty)"}\n\nCurrent VOLATILE.md:\n${req.volatile.trim() || "(empty)"}\n\nRecent exchanges:\n${exchanges}\n\nRewrite both notes.`;
  return [
    { role: "system", content: MEMORY_SYSTEM_PROMPT },
    { role: "user", content: [{ type: "text", text }] },
  ];
}

export const memoryRoute = new Hono<{ Variables: { user: AuthedUser } }>();

memoryRoute.post("/extract", async (c) => {
  const parsed = MemoryExtractRequest.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: "bad request", issues: parsed.error.issues }, 400);
  const req = parsed.data;
  const started = Date.now();
  try {
    const { value } = await chatJSON<MemoryExtractResponse>(buildMemoryMessages(req), "clicky_memory", schema);
    const clamp = (s: string, lines: number, chars: number) => s.trim().split("\n").slice(0, lines).join("\n").slice(0, chars);
    const profile = clamp(value.profile, 15, 2000);
    const volatile = clamp(value.volatile, 8, 1200);
    const changed = Boolean(value.changed) && (profile !== req.profile.trim() || volatile !== req.volatile.trim());
    console.log(`[memory] user=${c.var.user.id} ${Date.now() - started}ms exchanges=${req.exchanges.length} changed=${changed} profile=${profile.length}c volatile=${volatile.length}c`);
    return c.json({ profile, volatile, changed });
  } catch (err) {
    const status = err instanceof OpenAIError ? 502 : 500;
    console.error("[memory] failed:", err);
    return c.json({ error: "memory failed", detail: String(err) }, status);
  }
});
