import { Hono } from "hono";
import { env } from "../env.js";
import { mintRealtimeSecret, OpenAIError } from "../openai.js";
import { REALTIME_INSTRUCTIONS, LANGUAGE_NAMES } from "../prompt.js";
import type { AuthedUser } from "../auth.js";
import { VOICES } from "./voice.js";

export const realtimeRoute = new Hono<{ Variables: { user: AuthedUser } }>();

/** Mints an ephemeral client secret; the app connects to the WebSocket itself. */
realtimeRoute.post("/session", async (c) => {
  const body = (await c.req.json().catch(() => ({}))) as { voice?: string; language?: string };
  const voice = (VOICES as readonly string[]).includes(body.voice ?? "") ? (body.voice as string) : env.realtimeVoice;
  const language = body.language && LANGUAGE_NAMES[body.language] ? body.language : env.realtimeLanguage;
  try {
    const grant = await mintRealtimeSecret(REALTIME_INSTRUCTIONS(language), voice, language);
    console.log(`[realtime] session minted for user=${c.var.user.id} model=${env.realtimeModel} voice=${voice} language=${language}`);
    return c.json({
      clientSecret: grant.value,
      expiresAt: grant.expires_at,
      model: env.realtimeModel,
      voice,
      language,
      url: `wss://api.openai.com/v1/realtime?model=${encodeURIComponent(env.realtimeModel)}`,
    });
  } catch (err) {
    const status = err instanceof OpenAIError ? 502 : 500;
    console.error("[realtime] mint failed:", err);
    return c.json({ error: "could not mint realtime session", detail: String(err) }, status);
  }
});
