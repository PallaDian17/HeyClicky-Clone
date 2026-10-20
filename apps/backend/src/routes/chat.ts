import { Hono } from "hono";
import { z } from "zod";
import { chatJSON, OpenAIError, type ChatMessage } from "../openai.js";
import { TALK_SYSTEM_PROMPT } from "../prompt.js";
import type { AuthedUser } from "../auth.js";

const Element = z.object({
  id: z.number().int(),
  role: z.string().max(64),
  title: z.string().max(200),
  // Frame in screen points, top-left origin; the app keeps the mapping back to the screen.
  frame: z.object({ x: z.number(), y: z.number(), w: z.number(), h: z.number() }),
});

export const ChatRequest = z.object({
  transcript: z.string().min(1).max(4000),
  /** JPEG, base64 without a data: prefix. Optional when Screen Recording isn't granted. */
  screenshot: z.string().max(6_000_000).optional(),
  appName: z.string().max(120).optional(),
  elements: z.array(Element).max(400).default([]),
  history: z
    .array(z.object({ role: z.enum(["user", "assistant"]), text: z.string().max(2000) }))
    .max(12)
    .default([]),
  /** Present when the app's privacy guard withheld the screen (password field, protected app/page). */
  screenWithheld: z.string().max(200).optional(),
});
export type ChatRequest = z.infer<typeof ChatRequest>;

export type ChatResponse = {
  text: string;
  element_id: number | null;
  box: { x: number; y: number; w: number; h: number } | null;
};

const responseSchema = {
  type: "object",
  additionalProperties: false,
  properties: {
    text: { type: "string" },
    element_id: { type: ["integer", "null"] },
    box: {
      type: ["object", "null"],
      additionalProperties: false,
      properties: { x: { type: "number" }, y: { type: "number" }, w: { type: "number" }, h: { type: "number" } },
      required: ["x", "y", "w", "h"],
    },
  },
  required: ["text", "element_id", "box"],
};

function describeElements(req: ChatRequest): string {
  if (req.elements.length === 0) return "No element list is available for this turn.";
  const lines = req.elements.map((e) => {
    const f = e.frame;
    return `${e.id}. ${e.role}${e.title ? ` "${e.title}"` : ""} @(${Math.round(f.x)},${Math.round(f.y)} ${Math.round(f.w)}x${Math.round(f.h)})`;
  });
  return `Interactive elements in the frontmost window${req.appName ? ` (${req.appName})` : ""}:\n${lines.join("\n")}`;
}

export function buildMessages(req: ChatRequest): ChatMessage[] {
  const messages: ChatMessage[] = [{ role: "system", content: TALK_SYSTEM_PROMPT }];
  for (const h of req.history) {
    messages.push(h.role === "user" ? { role: "user", content: [{ type: "text", text: h.text }] } : { role: "assistant", content: h.text });
  }
  const parts: Extract<ChatMessage, { role: "user" }>["content"] = [];
  if (req.screenWithheld) {
    parts.push({
      type: "text",
      text: `(The screen was deliberately not captured for privacy: ${req.screenWithheld}. Do not guess what is on it. Answer from the question alone, and say in one short clause that you did not look at the screen.)`,
    });
  } else if (req.screenshot) {
    parts.push({ type: "image_url", image_url: { url: `data:image/jpeg;base64,${req.screenshot}`, detail: "high" } });
  } else {
    parts.push({ type: "text", text: "(No screenshot is available for this turn.)" });
  }
  parts.push({ type: "text", text: describeElements(req) });
  parts.push({ type: "text", text: `The user said: "${req.transcript}"` });
  messages.push({ role: "user", content: parts });
  return messages;
}

export const chatRoute = new Hono<{ Variables: { user: AuthedUser } }>();

chatRoute.post("/", async (c) => {
  const parsed = ChatRequest.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: "bad request", issues: parsed.error.issues }, 400);
  const req = parsed.data;
  const started = Date.now();
  try {
    const { value, usage } = await chatJSON<ChatResponse>(buildMessages(req), "clicky_answer", responseSchema);
    const valid = new Set(req.elements.map((e) => e.id));
    const element_id = value.element_id !== null && valid.has(value.element_id) ? value.element_id : null;
    const box = value.box && [value.box.x, value.box.y, value.box.w, value.box.h].every((n) => n >= 0 && n <= 1) ? value.box : null;
    console.log(`[chat] user=${c.var.user.id} ${Date.now() - started}ms elements=${req.elements.length} screenshot=${req.screenshot ? "yes" : "no"} withheld=${req.screenWithheld ? "yes" : "no"} target=${element_id ?? (box ? "box" : "none")}`);
    return c.json({ text: value.text, element_id, box, usage });
  } catch (err) {
    const status = err instanceof OpenAIError ? 502 : 500;
    console.error("[chat] failed:", err);
    return c.json({ error: "chat failed", detail: String(err) }, status);
  }
});
