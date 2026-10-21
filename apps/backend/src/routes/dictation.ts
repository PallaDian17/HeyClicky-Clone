import { Hono } from "hono";
import { z } from "zod";
import { chatJSON, OpenAIError, type ChatMessage } from "../openai.js";
import type { AuthedUser } from "../auth.js";

/**
 * Dictation support:
 *  - POST /token   mints a short-lived Deepgram key when DEEPGRAM_API_KEY and
 *                  DEEPGRAM_PROJECT_ID are set; otherwise tells the app to use
 *                  on-device Apple Speech.
 *  - POST /cleanup turns a raw transcript into clean text for the focused field,
 *                  applying the user's dictionary.
 */
export const dictationRoute = new Hono<{ Variables: { user: AuthedUser } }>();

dictationRoute.post("/token", async (c) => {
  const key = process.env.DEEPGRAM_API_KEY;
  const project = process.env.DEEPGRAM_PROJECT_ID;
  if (!key || !project) return c.json({ provider: "apple" });
  try {
    const res = await fetch(`https://api.deepgram.com/v1/projects/${project}/keys`, {
      method: "POST",
      headers: { authorization: `Token ${key}`, "content-type": "application/json" },
      body: JSON.stringify({ comment: "heyclickyclone dictation", scopes: ["usage:write"], time_to_live_in_seconds: 600 }),
    });
    if (!res.ok) throw new Error(`deepgram ${res.status}: ${(await res.text()).slice(0, 200)}`);
    const data = (await res.json()) as { key: string; expiration_date?: string };
    return c.json({
      provider: "deepgram",
      key: data.key,
      expiresAt: data.expiration_date ?? null,
      url: `wss://api.deepgram.com/v1/listen?model=${encodeURIComponent(process.env.DEEPGRAM_MODEL ?? "nova-3")}&smart_format=true&interim_results=true&encoding=linear16&sample_rate=16000&channels=1`,
    });
  } catch (err) {
    console.error("[dictation] token mint failed, falling back to apple:", err);
    return c.json({ provider: "apple", detail: String(err) });
  }
});

const CleanupRequest = z.object({
  transcript: z.string().min(1).max(8000),
  /** What the user is typing into: app name, field role/title, a little surrounding text. */
  context: z.object({
    appName: z.string().max(120).optional(),
    fieldRole: z.string().max(60).optional(),
    fieldTitle: z.string().max(200).optional(),
    before: z.string().max(400).optional(),
  }).default({}),
  dictionary: z.array(z.string().max(80)).max(300).default([]),
});

const schema = {
  type: "object",
  additionalProperties: false,
  properties: { text: { type: "string" } },
  required: ["text"],
};

const SYSTEM = `You clean up dictated speech into exactly what the person meant to type. Rules:
- Fix punctuation, casing and obvious speech-to-text errors. Spoken commands become symbols: "new line" → a line break, "comma" → ",", "period"/"full stop" → ".", "question mark" → "?", "open quote"/"close quote" → quotes, "all caps X" → X uppercased.
- Keep the person's words and order; never add, summarize, answer, or reply. Output only the cleaned text, nothing else.
- Match the field: a chat message or search box stays one line; an email or document keeps paragraphs; a code or URL field gets no trailing period.
- The dictionary lists names and terms the person uses; prefer them over similar-sounding words.`;

dictationRoute.post("/cleanup", async (c) => {
  const parsed = CleanupRequest.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: "bad request", issues: parsed.error.issues }, 400);
  const req = parsed.data;
  const ctx: string[] = [];
  if (req.context.appName) ctx.push(`App: ${req.context.appName}`);
  if (req.context.fieldRole || req.context.fieldTitle) ctx.push(`Field: ${[req.context.fieldRole, req.context.fieldTitle].filter(Boolean).join(" ")}`);
  if (req.context.before) ctx.push(`Text just before the cursor: "${req.context.before}"`);
  const messages: ChatMessage[] = [
    { role: "system", content: SYSTEM },
    { role: "user", content: [{ type: "text", text: `${ctx.length ? ctx.join("\n") + "\n" : ""}${req.dictionary.length ? `Dictionary: ${req.dictionary.join(", ")}\n` : ""}Transcript: ${req.transcript}` }] },
  ];
  try {
    const { value } = await chatJSON<{ text: string }>(messages, "dictation_cleanup", schema);
    console.log(`[dictation] cleanup user=${c.var.user.id} in=${req.transcript.length} out=${value.text.length}`);
    return c.json({ text: value.text });
  } catch (err) {
    const status = err instanceof OpenAIError ? 502 : 500;
    console.error("[dictation] cleanup failed:", err);
    return c.json({ error: "cleanup failed", detail: String(err) }, status);
  }
});
