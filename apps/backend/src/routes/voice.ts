import { Hono } from "hono";
import { z } from "zod";
import { env } from "../env.js";
import type { AuthedUser } from "../auth.js";

/** Voices the Realtime model supports; the same names work for TTS previews. */
export const VOICES = ["marin", "cedar", "alloy", "ash", "ballad", "coral", "echo", "sage", "shimmer", "verse"] as const;

const PreviewRequest = z.object({
  voice: z.enum(VOICES),
  text: z.string().min(1).max(200).optional(),
});

export const voiceRoute = new Hono<{ Variables: { user: AuthedUser } }>();

/** POST /v1/voice/preview → audio/mpeg sample of the voice saying a short line. */
voiceRoute.post("/preview", async (c) => {
  const parsed = PreviewRequest.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: "bad request", issues: parsed.error.issues }, 400);
  const { voice, text } = parsed.data;
  const res = await fetch("https://api.openai.com/v1/audio/speech", {
    method: "POST",
    headers: { authorization: `Bearer ${env.openaiApiKey}`, "content-type": "application/json" },
    body: JSON.stringify({
      model: process.env.OPENAI_TTS_MODEL ?? "gpt-4o-mini-tts",
      voice,
      input: text ?? "Hi, I'm Clicky. Hold the key and tell me what you need.",
      response_format: "mp3",
    }),
  });
  if (!res.ok) {
    const detail = (await res.text()).slice(0, 300);
    console.error(`[voice] preview ${voice} failed ${res.status}: ${detail}`);
    return c.json({ error: "preview failed", detail }, 502);
  }
  const audio = await res.arrayBuffer();
  console.log(`[voice] preview ${voice} ${audio.byteLength} bytes user=${c.var.user.id}`);
  return new Response(audio, { headers: { "content-type": "audio/mpeg", "cache-control": "private, max-age=3600" } });
});
