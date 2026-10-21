import { serve } from "@hono/node-server";
import { Hono } from "hono";
import { logger } from "hono/logger";
import { env } from "./env.js";
import { requireUser, type AuthedUser } from "./auth.js";
import { chatRoute } from "./routes/chat.js";
import { realtimeRoute } from "./routes/realtime.js";
import { interviewRoute } from "./routes/interview.js";
import { dictationRoute } from "./routes/dictation.js";
import { suggestionsRoute } from "./routes/suggestions.js";
import { integrationsRoute } from "./routes/integrations.js";

const app = new Hono<{ Variables: { user: AuthedUser } }>();
app.use("*", logger());

app.get("/", (c) => c.json({ name: "heyclickyclone-backend", ok: true }));
app.get("/healthz", (c) => c.json({ ok: true }));

app.get("/v1/config", (c) =>
  c.json({
    chatModel: env.chatModel,
    realtimeModel: env.realtimeModel,
    voice: env.realtimeVoice,
    authRequired: !env.devBypassAuth,
  }),
);

app.use("/v1/chat/*", requireUser);
app.use("/v1/chat", requireUser);
app.use("/v1/realtime/*", requireUser);
app.use("/v1/interview", requireUser);
app.use("/v1/dictation/*", requireUser);
app.use("/v1/suggestions", requireUser);
app.use("/v1/integrations/*", requireUser);
app.route("/v1/chat", chatRoute);
app.route("/v1/realtime", realtimeRoute);
app.route("/v1/interview", interviewRoute);
app.route("/v1/dictation", dictationRoute);
app.route("/v1/suggestions", suggestionsRoute);
app.route("/v1/integrations", integrationsRoute);

app.onError((err, c) => {
  console.error(err);
  return c.json({ error: "internal", detail: String(err) }, 500);
});

serve({ fetch: app.fetch, port: env.port }, (info) => {
  console.log(`backend listening on http://localhost:${info.port} (chat=${env.chatModel}, realtime=${env.realtimeModel}, auth=${env.devBypassAuth ? "DEV BYPASS" : "supabase"})`);
});
