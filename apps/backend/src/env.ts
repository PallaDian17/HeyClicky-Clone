import { readFileSync } from "node:fs";
import { resolve } from "node:path";

// Minimal .env loader so the server has no dotenv dependency. Real env wins.
function loadDotEnv(): void {
  for (const candidate of [resolve(process.cwd(), ".env"), resolve(import.meta.dirname, "../.env")]) {
    try {
      const text = readFileSync(candidate, "utf8");
      for (const line of text.split("\n")) {
        const m = /^\s*([A-Z0-9_]+)\s*=\s*(.*?)\s*$/.exec(line);
        if (!m || m[1] in process.env) continue;
        process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
      }
      return;
    } catch {
      // try the next location
    }
  }
}
loadDotEnv();

function required(name: string): string {
  const v = process.env[name];
  if (!v) throw new Error(`Missing required env var ${name}`);
  return v;
}

export const env = {
  port: Number(process.env.PORT ?? 8787),
  openaiApiKey: required("OPENAI_API_KEY"),
  chatModel: process.env.OPENAI_CHAT_MODEL ?? "gpt-5.6-sol",
  realtimeModel: process.env.OPENAI_REALTIME_MODEL ?? "gpt-realtime",
  realtimeVoice: process.env.REALTIME_VOICE ?? "marin",
  transcriptionModel: process.env.REALTIME_TRANSCRIPTION_MODEL ?? "gpt-4o-mini-transcribe",
  supabaseUrl: process.env.SUPABASE_URL,
  supabaseJwtSecret: process.env.SUPABASE_JWT_SECRET,
  devBypassAuth: process.env.DEV_BYPASS_AUTH === "1",
};
