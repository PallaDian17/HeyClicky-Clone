import { Hono } from "hono";
import { z } from "zod";
import { chatJSON, OpenAIError, type ChatMessage } from "../openai.js";
import type { AuthedUser } from "../auth.js";

// Walkthrough mode: one step at a time. The app sends a fresh screenshot and
// element list after every completed step plus the log of what is done, and
// gets back the next single step (or done). Up to 15 steps, kept by the app.

const Element = z.object({
  id: z.number().int(),
  role: z.string().max(64),
  title: z.string().max(200),
  frame: z.object({ x: z.number(), y: z.number(), w: z.number(), h: z.number() }),
});

export const WalkthroughStepRequest = z.object({
  goal: z.string().min(1).max(600),
  appName: z.string().max(120).optional(),
  screenshot: z.string().max(6_000_000).optional(),
  elements: z.array(Element).max(400).default([]),
  screenWithheld: z.string().max(200).optional(),
  /** Steps already done, oldest first. */
  log: z.array(z.object({ instruction: z.string().max(300), outcome: z.string().max(200) })).max(20).default([]),
  /** What just happened that was not a completed step (a click elsewhere, a question, "it didn't work"). */
  note: z.string().max(400).optional(),
  maxSteps: z.number().int().min(1).max(15).default(15),
});
export type WalkthroughStepRequest = z.infer<typeof WalkthroughStepRequest>;

export type WalkthroughStep = {
  /** Spoken, one or two sentences: what to do now and why, in the second person. */
  say: string;
  /** The short imperative shown in the notch ("Click File › Export"). */
  instruction: string;
  target: { element_id: number | null; box: { x: number; y: number; w: number; h: number } | null; label: string | null } | null;
  /** click: the app advances when the user clicks the target. manual: typing or reading; the user says "continue" or presses Next. */
  done_when: "click" | "manual";
  done: boolean;
  summary: string | null;
};

const schema = {
  type: "object",
  additionalProperties: false,
  properties: {
    say: { type: "string" },
    instruction: { type: "string" },
    target: {
      type: ["object", "null"],
      additionalProperties: false,
      properties: {
        element_id: { type: ["integer", "null"] },
        box: {
          type: ["object", "null"],
          additionalProperties: false,
          properties: { x: { type: "number" }, y: { type: "number" }, w: { type: "number" }, h: { type: "number" } },
          required: ["x", "y", "w", "h"],
        },
        label: { type: ["string", "null"] },
      },
      required: ["element_id", "box", "label"],
    },
    done_when: { type: "string", enum: ["click", "manual"] },
    done: { type: "boolean" },
    summary: { type: ["string", "null"] },
  },
  required: ["say", "instruction", "target", "done_when", "done", "summary"],
};

export const WALKTHROUGH_SYSTEM_PROMPT = `You are Clicky, a patient teacher who sits beside the user's Mac and walks them through a task one step at a time. You see a screenshot of their screen and a numbered list of the interactive elements in the frontmost window, the goal, and a log of the steps they have already completed. You answer with exactly ONE next step.

Rules:
- One action per step: a single click, a single thing to type or choose, or a single thing to read. Never bundle two actions.
- Look at the screen as it is NOW. The log tells you what is already done; never repeat a completed step, and never send the user back to a page they were already on unless the screen shows they left it by mistake.
- target: the one thing to click or look at, as an element_id from the list when one matches, otherwise a normalized box (0..1, top-left origin) in full-screenshot coordinates. Null only when there is nothing on screen to point at (for example a step that happens in another app).
- done_when: "click" when the step is a click or tap on the target; "manual" when the user has to type, drag, read, or do something outside this screen. The app advances a click step by itself when the user clicks the target; a manual step waits for the user to say "continue".
- say: one or two short spoken sentences, friendly and concrete, naming what to click or do and, when it helps, what will happen next. instruction: the same action in at most eight words, imperative ("Click Share in the top right").
- If the note says the user clicked somewhere else or that something did not work, look at the screen, decide where they actually are, and give the right next step from there. Do not scold.
- done: true with a one-sentence summary when the goal is reached or when nothing more can be done from here. Also finish when the log already holds the maximum number of steps.
- If the screen was withheld for privacy, give the most likely next step from the goal and the log alone and say that you cannot see the screen.`;

function describeElements(req: WalkthroughStepRequest): string {
  if (req.elements.length === 0) return "No element list is available.";
  const lines = req.elements.map((e) => {
    const f = e.frame;
    return `${e.id}. ${e.role}${e.title ? ` "${e.title}"` : ""} @(${Math.round(f.x)},${Math.round(f.y)} ${Math.round(f.w)}x${Math.round(f.h)})`;
  });
  return `Interactive elements in the frontmost window${req.appName ? ` (${req.appName})` : ""}:\n${lines.join("\n")}`;
}

export function buildWalkthroughMessages(req: WalkthroughStepRequest): ChatMessage[] {
  const parts: Extract<ChatMessage, { role: "user" }>["content"] = [];
  if (req.screenWithheld) {
    parts.push({ type: "text", text: `(The screen was deliberately not captured for privacy: ${req.screenWithheld}.)` });
  } else if (req.screenshot) {
    parts.push({ type: "image_url", image_url: { url: `data:image/jpeg;base64,${req.screenshot}`, detail: "high" } });
  } else {
    parts.push({ type: "text", text: "(No screenshot is available.)" });
  }
  parts.push({ type: "text", text: describeElements(req) });
  const log = req.log.length
    ? req.log.map((s, i) => `${i + 1}. ${s.instruction} — ${s.outcome}`).join("\n")
    : "(nothing yet — this is the first step)";
  parts.push({ type: "text", text: `Goal: ${req.goal}\n\nSteps completed so far (${req.log.length} of at most ${req.maxSteps}):\n${log}` });
  if (req.note) parts.push({ type: "text", text: `Just now: ${req.note}` });
  parts.push({ type: "text", text: "Give the next single step." });
  return [{ role: "system", content: WALKTHROUGH_SYSTEM_PROMPT }, { role: "user", content: parts }];
}

export const walkthroughRoute = new Hono<{ Variables: { user: AuthedUser } }>();

walkthroughRoute.post("/step", async (c) => {
  const parsed = WalkthroughStepRequest.safeParse(await c.req.json().catch(() => null));
  if (!parsed.success) return c.json({ error: "bad request", issues: parsed.error.issues }, 400);
  const req = parsed.data;
  const started = Date.now();
  try {
    const { value } = await chatJSON<WalkthroughStep>(buildWalkthroughMessages(req), "clicky_walkthrough_step", schema);
    const valid = new Set(req.elements.map((e) => e.id));
    const inBounds = (b: { x: number; y: number; w: number; h: number } | null) => b && [b.x, b.y, b.w, b.h].every((n) => n >= 0 && n <= 1) ? b : null;
    let target = value.target
      ? { element_id: value.target.element_id !== null && valid.has(value.target.element_id) ? value.target.element_id : null, box: inBounds(value.target.box), label: value.target.label }
      : null;
    if (target && target.element_id === null && target.box === null) target = null;
    const done = Boolean(value.done) || req.log.length >= req.maxSteps;
    console.log(`[walkthrough] user=${c.var.user.id} ${Date.now() - started}ms step=${req.log.length + 1} elements=${req.elements.length} target=${target?.element_id ?? (target?.box ? "box" : "none")} when=${value.done_when} done=${done}`);
    return c.json({ say: value.say, instruction: value.instruction, target, done_when: value.done_when, done, summary: value.summary });
  } catch (err) {
    const status = err instanceof OpenAIError ? 502 : 500;
    console.error("[walkthrough] failed:", err);
    return c.json({ error: "walkthrough failed", detail: String(err) }, status);
  }
});
