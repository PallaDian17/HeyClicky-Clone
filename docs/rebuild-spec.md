# HeyClicky Clone — rebuild spec

This is the plan for building our own version of the product described in
[reverse-engineering-report.md](reverse-engineering-report.md). It separates
what the original **does** (observed) from what **we choose** (design). Nothing
here copies the vendor's code, prompts, art, or keys.

## 1. Product definition

A menubar macOS app, Sonoma 14.2+, that gives the user:

1. **Talk** — hold a hotkey, speak, the app captures the screen, answers out
   loud, and can point at on-screen elements by drawing on an overlay.
2. **Agents** — named, persistent helpers that run long tasks on the Mac
   (files, shell, browser, native apps, connected SaaS) and report back.
3. **Dictation** — hold a key, speak, cleaned text lands in the focused field.
4. **Routines** — an agent task re-run on a cadence while the Mac is awake.
5. **A notch HUD** — a single always-present surface for state and replies.

## 2. Architecture

```
┌──────────────────────────── macOS app (Swift / SwiftUI / AppKit) ────────────────────────────┐
│ NotchHUD  HomeSpace window  TalkOverlay (screenshot + annotations)  AgentHUD  Settings        │
│ CompanionController (state machine)   HotkeyMonitor (CGEvent tap)   PermissionFlow            │
│ RealtimeVoiceClient (OpenAI Realtime WS)   DictationClient (Deepgram WS / Apple Speech)        │
│ AgentRuntime: CodexProcess (app-server JSON-RPC over stdio, isolated CODEX_HOME per install)   │
│ ComputerUseDaemon: embedded cua-driver (unix socket) → exposed to Codex as MCP "computer-use" │
│ Auth (Supabase)  Billing (Stripe via backend)  Updates (Sparkle)  Crash/analytics (Sentry/PH)  │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
                                   │ HTTPS (bearer = Supabase JWT)
┌────────────────────────────── backend (TypeScript, Hono or Next.js API) ──────────────────────┐
│ /v1/chat (talk-mode model call, screenshot in, text + [TARGET] out)                           │
│ /v1/realtime/session (mints ephemeral Realtime key)   /v1/dictation/token (Deepgram key)      │
│ /v1/agent/openai (OpenAI-compatible proxy Codex points at; metering + model policy here)      │
│ /v1/agent/lease (per-turn lease: quota check, 402 on exhaustion)                              │
│ /v1/integrations (Composio connect/disconnect/session)   /v1/routines (cron registry)         │
│ /v1/skills (library, create)   /v1/billing (Stripe checkout/portal, webhook)   /v1/config     │
│ Postgres (Drizzle) · Supabase Auth · Stripe · Composio · OpenAI · Deepgram                     │
└──────────────────────────────────────────────────────────────────────────────────────────────┘
```

Design choices that differ from or simplify the original:

- **One proxy for all paid model calls.** Codex's `model_provider` points at
  our `/v1/agent/openai`; talk mode calls `/v1/chat`. No model key ever ships
  in the app. The original also embedded direct OpenAI/Anthropic URLs; we do
  not.
- **Metering is a lease.** Before each agent turn the app requests a lease;
  the backend checks the plan quota, records the turn, returns a lease id that
  the proxy requires. 402 opens the paywall. Early stop refunds the lease.
- **Codex is a vendored release artifact**, pinned by version + sha256 in a
  bundling script, same as the original. We do not fork Codex.
- **cua-driver is vendored unchanged** (MIT) and run in embedded mode with
  `permission-mode bounded`, inheriting the host app's TCC grants.
- **Routines live in the backend registry but execute on the Mac** (the agent
  needs local access), triggered by the app while awake; the model asks for a
  routine by emitting a fenced JSON block the app parses, the same mechanism the
  original uses, with our own tag name.

## 3. Feature specs

### 3.1 Notch HUD
- An `NSPanel` at `.statusBar` level, non-activating, spanning the notch
  width when idle and expanding to a card on hover/activity. On non-notch
  displays, anchor top-centre.
- States: idle (mascot eye), listening (waveform + partial transcript),
  thinking, speaking (caption), agent-running (name, step, elapsed, "needs
  you" badge), text-reply (markdown + image strip), dictation-result (preview +
  copy), morning-suggestions (cards with yes/no), update-available.
- Auto-dismiss with a visible countdown; hover-dwell to pin.
- Keyboard focus is released back to the previous app when the HUD closes.

### 3.2 Talk mode
- Trigger: global modifier double-tap (default: double-tap Control) or hold
  Fn; configurable with a shortcut recorder. Needs a CGEvent tap and
  Accessibility permission.
- On trigger: capture the active display with ScreenCaptureKit, excluding our
  own windows; harvest the frontmost window's accessibility tree (role, title,
  frame per element); read the focused document's full text when the app
  exposes it (AX) and the user has granted the folder.
- Open or reuse an OpenAI Realtime session (push-to-talk commit; optional
  always-on with barge-in). The screenshot and AX summary go to `/v1/chat`
  together with the transcript; the reply is streamed to the Realtime session
  for speech and to the HUD as text.
- Pointing protocol: the model may return `{"target": {"element_id": …}}` or a
  normalized `{x, y}` box. The app draws a blue cursor + stroke on a
  transparent overlay and, in "guided" mode, waits for the user's click before
  sending the next step ("click to advance").
- Reply cards: text, image gallery (web image search), place card (MapKit +
  photos), stock quote. Each is a backend tool call, not a client secret.
- Handoff: while in talk mode the user can drag a screen region or say
  "hand this to an agent"; the capture + instruction becomes the first turn of a
  new or existing agent.

### 3.3 Agents
- Each agent ("helper") is a folder under `~/Library/Application Support/<app>/agents/<slug>/`
  with `AGENTS.md` (persona + dated notes), `output/`, `tmp/`. Codex runs with
  `cwd` = that folder and an isolated `CODEX_HOME` holding our generated
  `config.toml`.
- Launch: app-server `thread/start` (or `thread/resume`), then `turn/start` with
  the user prompt plus a system preamble we write (identity, tool rules,
  approval rules, output location rules). Stream `item/*` events into the HUD
  and Home Space transcript. `turn/interrupt` on Esc.
- Approvals: Codex `approval_policy = "never"` plus our own gates in the MCP
  layer: computer use requires one-time consent, destructive actions are
  blocked by a label denylist in the driver, extra-effort (long) turns need a
  tap in the HUD.
- MCP servers written into `config.toml`: `computer-use` (stdio proxy to the
  embedded daemon), `integrations` (Composio session URL + token), `routines`
  (loopback), optional `fast-use` (see 3.7).
- Create-agent interview: a short guided chat (max ~5 questions) that produces a
  brief, then founds the agent and opens its chat with three tappable first
  messages. Starter agents are offered at onboarding.
- History: threads listed from the app-server; archive, rename, move a thread
  into a different agent; organize-history is a backend LLM call over titles.

### 3.4 Home Space window
- Left rail: agents (avatar + unread + usage ring), suggestions, skills,
  referral, settings. Main: transcript (chat bubbles + "cowork" blocks for
  commands, diffs, tables, markdown), composer with attachments, drop zone,
  voice button; right column: output preview (Quick Look, PDF, markdown viewer
  with file watching).
- Settings: account/plan, hotkeys, voice, dictation (language, dictionary),
  integrations (connect/disconnect, multi-account, custom connector editor with
  OAuth discovery), developer (model, reasoning effort, runtime diagnostics),
  about/updates.

### 3.5 Dictation
- Hold a second hotkey; stream mic audio to Deepgram (`nova-3`) with a
  short-lived token from the backend; Apple Speech as offline fallback.
- On release: backend cleanup pass (punctuation, personal dictionary,
  formatting for the focused field type), then insert via pasteboard + ⌘V with
  verification that the field changed; fall back to AX `set_value`.
- Learned corrections: when the user edits inserted text within a few seconds,
  record the diff as a dictionary candidate and show it in the notch.

### 3.6 Routines and proactive suggestions
- Routine = `{agent, title, task, every_minutes, paused}` in the backend; the
  app keeps a due-queue, holds runs while asleep/offline, and runs them as
  turns in the agent's chat with "report only what is new" context.
- Proactive sweep (opt-in): once a day the backend scans connected apps for
  actionable items and returns suggestion cards; approved cards become a
  routine or a one-off agent task.

### 3.7 Fast computer-use lane (optional, phase 3)
- A loopback MCP tool `suggest_action(goal, window)` that sends a projected
  accessibility tree to a small classifier and returns the next element to
  press/type with confidence. Falls back to the full model under 0.5
  confidence. We can start with a cheap LLM call instead of a trained head.

### 3.8 Onboarding
- Pre-sign-in: pick a voice (preview clips we generate with our own TTS), pick
  skills (Hermes catalog, MIT), watch a short intro. Sign in (Supabase email /
  Google). Permission guide: Accessibility, Screen Recording, Microphone,
  Speech, with a drag-the-app-into-the-list helper. Mic check. A 60-second
  tutorial with keycap hints. Starter agent squad.

### 3.9 Billing
- Plans: Free / Pro / Max with monthly agent-turn quotas and talk quotas;
  Stripe Checkout + Customer Portal through the backend; paywall HUD on 402
  with plan cards; referral codes with credit.

## 4. Repo layout (proposed)

```
HeyClicky-Clone/
  apps/mac/            Xcode project (SwiftUI + AppKit), Swift Package for shared models
  apps/backend/        TypeScript API (Hono on Node 22), Drizzle + Postgres
  packages/protocol/   shared JSON schemas (lease, chat, routines, suggestions)
  vendor/              scripts to fetch + pin codex, cua-driver, hermes skills (sha256)
  docs/                this spec, the report, ADRs
```

## 5. Phases

1. **Skeleton (week 1–2):** menubar app, notch HUD with states, hotkey tap,
   permissions flow, Supabase sign-in, backend with `/v1/config` and `/v1/chat`.
2. **Talk (week 3–4):** ScreenCaptureKit capture, Realtime voice, reply card,
   pointing overlay, place/image/stock tools.
3. **Agents (week 5–7):** bundle Codex, app-server client, agent folders +
   personas, HUD streaming, Home Space transcript, lease metering, Composio.
4. **Computer use (week 8):** embed cua-driver, consent gate, denylist, skill
   docs in context.
5. **Dictation + routines (week 9):** Deepgram, insertion with verification,
   dictionary, routine registry and scheduler.
6. **Polish + billing (week 10–11):** onboarding, character editor (our own
   mascot), Stripe, Sparkle, Sentry/PostHog, referral.

## 6. Open decisions

- Mascot and brand (must be original).
- Whether talk mode uses OpenAI Realtime for both STT+TTS (simplest, matches
  original) or a separate STT → LLM → TTS chain (cheaper, more control).
- Whether to ship an x86_64 slice at all.
- Name of the product and bundle id.
