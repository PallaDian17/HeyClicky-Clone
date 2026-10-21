import { Hono } from "hono";
import { z } from "zod";
import { chatJSON, OpenAIError, type ChatMessage } from "../openai.js";
import type { AuthedUser } from "../auth.js";

/**
 * The "New Clicky" interview: a short guided chat that turns a vague wish into
 * a founded agent. Stateless: the app sends the whole exchange each turn.
 */
const Turn = z.object({ role: z.enum(["user", "assistant"]), text: z.string().max(2000) });

export const InterviewRequest = z.object({
  turns: z.array(Turn).max(20).default([]),
  /** Names already taken, so the brief proposes a fresh one. */
  existingNames: z.array(z.string().max(60)).max(100).default([]),
});

export type InterviewBrief = {
  name: string;
  purpose: string;
  notes: string;
  first_messages: string[];
};

export type InterviewResponse = {
  reply: string;
  done: boolean;
  brief: InterviewBrief | null;
};

const SYSTEM = `You are HeyClicky Clone's founding interviewer. The user wants a new "Clicky": a named, persistent helper that lives on their Mac in its own folder, remembers across chats, can use files, the shell, the web, and (when allowed) click in apps.

Your job is to turn their wish into a brief, in as few questions as possible:
- Ask at most one question per turn, only when the answer changes the brief (what the job is, what good output looks like, where the material lives). Never ask about things you can decide yourself. Three questions is plenty; often one is enough.
- Be warm and brief, like a capable friend. No lists of options, no "great question".
- When you have enough, set done=true and fill the brief:
  - name: short, memorable, two words at most, not already in use (the app tells you the taken names).
  - purpose: one sentence, in the second person about the user ("keeps your inbox zero by …").
  - notes: 2–5 short lines of durable facts for the Clicky's own notes (preferences, sources, formats), each starting with "- ".
  - first_messages: exactly three short requests the user could tap to start, phrased as the user would say them, specific to this Clicky.
  Your reply in that turn introduces the Clicky in one sentence ("Made you Inbox Zero. It …"). Do not start any work.
- Until done, brief is null and reply is your next question or a short acknowledgement.`;

const schema = {
  type: "object",
  additionalProperties: false,
  properties: {
    reply: { type: "string" },
    done: { type: "boolean" },
    brief: {
      type: ["object", "null"],
      additionalProperties: false,
      properties: {
        name: { type: "string" },
        purpose: { type: "string" },
        notes: { type: "string" },
        first_messages: { type: "array", items: { type: "string" } },
      },
      required: ["name", "purpose", "notes", "first_messages"],
    },
  },
  required: ["reply", "done", "brief"],
};

export const interviewRoute = new Hono<{ Variables: { user: AuthedUser } }>();

interviewRoute.post("/", async (c) => {
  const parsed = InterviewRequest.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: "bad request", issues: parsed.error.issues }, 400);
  const req = parsed.data;

  const messages: ChatMessage[] = [{ role: "system", content: SYSTEM }];
  if (req.existingNames.length) {
    messages.push({ role: "system", content: `Names already taken: ${req.existingNames.join(", ")}.` });
  }
  if (req.turns.length === 0) {
    messages.push({ role: "user", content: [{ type: "text", text: "(The user just opened the New Clicky page and has not typed yet. Greet them in one sentence and ask what they want help with.)" }] });
  }
  for (const t of req.turns) {
    messages.push(t.role === "user" ? { role: "user", content: [{ type: "text", text: t.text }] } : { role: "assistant", content: t.text });
  }

  try {
    const { value } = await chatJSON<InterviewResponse>(messages, "clicky_interview", schema);
    if (value.brief && value.brief.first_messages.length !== 3) {
      value.brief.first_messages = value.brief.first_messages.slice(0, 3);
    }
    console.log(`[interview] user=${c.var.user.id} turns=${req.turns.length} done=${value.done}`);
    return c.json(value);
  } catch (err) {
    const status = err instanceof OpenAIError ? 502 : 500;
    console.error("[interview] failed:", err);
    return c.json({ error: "interview failed", detail: String(err) }, status);
  }
});
