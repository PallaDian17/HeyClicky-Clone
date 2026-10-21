import { Hono } from "hono";
import { z } from "zod";
import { chatJSON, OpenAIError, type ChatMessage } from "../openai.js";
import type { AuthedUser } from "../auth.js";

/**
 * Morning suggestions: given what the user's Clickys are for and what they
 * did recently, propose up to three concrete tasks worth doing today. No
 * integrations yet, so the signal is the agents' own history.
 */
const SuggestionsRequest = z.object({
  agents: z.array(z.object({
    slug: z.string().max(60),
    name: z.string().max(60),
    purpose: z.string().max(400),
    recent: z.array(z.string().max(300)).max(8).default([]),
    routines: z.array(z.string().max(200)).max(10).default([]),
  })).max(30),
  localDate: z.string().max(40).optional(),
});

export type SuggestionCard = { title: string; task: string; agent_slug: string; every_minutes: number | null };

const schema = {
  type: "object",
  additionalProperties: false,
  properties: {
    cards: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        properties: {
          title: { type: "string" },
          task: { type: "string" },
          agent_slug: { type: "string" },
          every_minutes: { type: ["integer", "null"] },
        },
        required: ["title", "task", "agent_slug", "every_minutes"],
      },
    },
  },
  required: ["cards"],
};

const SYSTEM = `You suggest what the person's Clickys (named helpers on their Mac) could usefully do today. You see each Clicky's purpose, its recent requests, and its existing routines.
- Return 1 to 3 cards. Each is one concrete, bounded task a Clicky can do without asking questions, grounded in what it has done before; no vague "organize your life" items.
- title: at most 6 words. task: the exact request, as the person would type it. agent_slug: the best Clicky for it. every_minutes: a cadence only if the task clearly repeats (morning check = 1440); else null.
- Never repeat an existing routine. If nothing is worth suggesting, return an empty list.`;

export const suggestionsRoute = new Hono<{ Variables: { user: AuthedUser } }>();

suggestionsRoute.post("/", async (c) => {
  const parsed = SuggestionsRequest.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: "bad request", issues: parsed.error.issues }, 400);
  const req = parsed.data;
  const lines = req.agents.map((a) =>
    `- ${a.name} (${a.slug}): ${a.purpose}\n  recent: ${a.recent.length ? a.recent.map((r) => JSON.stringify(r)).join("; ") : "none"}\n  routines: ${a.routines.length ? a.routines.join("; ") : "none"}`,
  );
  const messages: ChatMessage[] = [
    { role: "system", content: SYSTEM },
    { role: "user", content: [{ type: "text", text: `${req.localDate ? `Today: ${req.localDate}\n` : ""}Clickys:\n${lines.join("\n")}` }] },
  ];
  try {
    const { value } = await chatJSON<{ cards: SuggestionCard[] }>(messages, "morning_suggestions", schema);
    const slugs = new Set(req.agents.map((a) => a.slug));
    const cards = value.cards.filter((card) => slugs.has(card.agent_slug)).slice(0, 3);
    console.log(`[suggestions] user=${c.var.user.id} agents=${req.agents.length} cards=${cards.length}`);
    return c.json({ cards });
  } catch (err) {
    const status = err instanceof OpenAIError ? 502 : 500;
    console.error("[suggestions] failed:", err);
    return c.json({ error: "suggestions failed", detail: String(err) }, status);
  }
});
