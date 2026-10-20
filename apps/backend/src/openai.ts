import { env } from "./env.js";

const BASE = "https://api.openai.com/v1";

export class OpenAIError extends Error {
  constructor(public status: number, message: string) {
    super(message);
  }
}

async function post<T>(path: string, body: unknown): Promise<T> {
  const res = await fetch(`${BASE}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json", authorization: `Bearer ${env.openaiApiKey}` },
    body: JSON.stringify(body),
  });
  const text = await res.text();
  if (!res.ok) throw new OpenAIError(res.status, `${path} -> ${res.status}: ${text.slice(0, 500)}`);
  return JSON.parse(text) as T;
}

export type ChatMessage =
  | { role: "system" | "assistant"; content: string }
  | { role: "user"; content: Array<{ type: "text"; text: string } | { type: "image_url"; image_url: { url: string; detail?: "low" | "high" | "auto" } }> };

/** Chat Completions with a strict JSON schema response. */
export async function chatJSON<T>(messages: ChatMessage[], schemaName: string, schema: object): Promise<{ value: T; usage?: unknown }> {
  const res = await post<{ choices: Array<{ message: { content: string | null; refusal?: string | null } }>; usage?: unknown }>(
    "/chat/completions",
    {
      model: env.chatModel,
      messages,
      response_format: { type: "json_schema", json_schema: { name: schemaName, strict: true, schema } },
    },
  );
  const msg = res.choices[0]?.message;
  if (!msg?.content) throw new OpenAIError(502, msg?.refusal ? `model refused: ${msg.refusal}` : "empty completion");
  return { value: JSON.parse(msg.content) as T, usage: res.usage };
}

export type RealtimeGrant = { value: string; expires_at: number; session: { model?: string } };

/** Mints a short-lived client secret the Mac app uses to open the Realtime WebSocket. */
export async function mintRealtimeSecret(instructions: string): Promise<RealtimeGrant> {
  return post<RealtimeGrant>("/realtime/client_secrets", {
    expires_after: { anchor: "created_at", seconds: 600 },
    session: {
      type: "realtime",
      model: env.realtimeModel,
      instructions,
      output_modalities: ["audio"],
      audio: {
        input: {
          format: { type: "audio/pcm", rate: 24000 },
          transcription: { model: env.transcriptionModel },
          turn_detection: null,
        },
        output: { format: { type: "audio/pcm", rate: 24000 }, voice: env.realtimeVoice },
      },
    },
  });
}
