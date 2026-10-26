# HeyClicky Clone — rebuild spec

This is the plan for building our own version of the product described in
[reverse-engineering-report.md](reverse-engineering-report.md). It separates
what the original **does** (observed) from what **we choose** (design). Nothing
here copies the vendor's code, prompts, art, or keys.

## 0. Decisions on record

- **2026-10-21 — personal use, no billing.** This clone is for one person on
  their own Mac. Stripe, plans, quotas, the paywall HUD and the referral
  program are **out of scope** (the lease hook in the model proxy stays as a
  no-op). Supabase sign-in stays optional: the backend's dev bypass is the
  normal mode for a single user.
- **2026-10-21 — match the original's UI.** The goal is a faithful duplicate
  of HeyClicky's surfaces (notch HUD, Home Space, agent HUD, pointer,
  onboarding feel). Original-looking mascot art is still required (no copied
  assets), but layout, flow and behaviour should track the original.
- **2026-10-21 — no agent limit.** The original's free plan allowed two
  Clickys; this clone has no cap on the number of agents or on turns. Starter
  agents are a convenience, not a ceiling.
- **2026-10-21 — agents run on Claude, through the user's subscription.** The
  agent runtime is Claude Code in headless streaming mode (the same process
  the Claude Agent SDK drives), launched per agent by the Mac app with the
  agent's folder as its working directory. It authenticates with the user's
  existing Claude login, so no Anthropic or OpenAI key is involved and the
  backend's model proxy is not used for agents. The vendored Codex runtime
  from phase 3 is retired (one path wins); talk mode keeps its backend route.

- **2026-10-21 — privacy guard is a hard requirement.** With screen and voice
  access, the app must never capture, store, forward or let an agent read
  transaction pages, one-time codes, or passwords for Google or any other
  account. This is enforced in code, before any capture leaves the Mac, not by
  prompt wording. See 3.11.

- **Product name: Hi Dicky** (2026-10-21). User-facing strings, the bundle's
  display name and the .app filename say Hi Dicky; the executable, bundle id
  `com.ashish.heyclickyclone`, URL scheme, Application Support folder and the
  GitHub repo keep their names so TCC grants, Keychain items and data survive.
  The helpers are still "Clickys".

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
- Hover: an exit reported while the pill is resizing under the pointer is
  ignored until the pointer is really outside the panel (`setHovering`), which
  ended the expand/collapse flicker seen in a recording on 2026-10-21.
- States: idle (mascot eye), listening (waveform + partial transcript),
  thinking, speaking (caption), agent-running (name, step, elapsed, "needs
  you" badge), text-reply (markdown + image strip), dictation-result (preview +
  copy), morning-suggestions (cards with yes/no), update-available.
- Auto-dismiss with a visible countdown; hover-dwell to pin.
- Keyboard focus is released back to the previous app when the HUD closes.

### 3.1a The notch panel as the main surface — built 2026-10-26
Recording item 3 (`docs/recording-gap-analysis.md` §1): the panel that drops
from the menu bar IS the app. `HUD/HomePanel.swift`.
- **Opening it**: left-click the menu-bar item (`StatusBarController` keeps
  its menu detached and attaches it only for a right-click, so a left click
  reaches `toggleNotchHome`), click the hovered idle pill, or the debug routes
  `hud/home` / `hud/settings`. `NotchState.home` (560×≈450) and `.settings`
  (820×≈590); `wantsKeyboard` makes the panel key for home, settings, the
  thread and the prompt, so their fields take typing.
- **Header** on every page (`PanelHeader`): mascot → home, chat bubble → the
  talk thread (the last `ConversationModel` is remembered, else a hint
  message), an orange **Update app** pill when `UpdateController.lastResult`
  says one is available, pop-out → the Home window, gear → settings.
- **Home**: greeting by time of day + first name from `NSFullUserName()`, the
  recorded line under it, then the **corkboard** (`CorkboardView`): the selected
  Clicky as a white dotted-paper card (`AgentCard`: red/green/grey dot, tag,
  name, status line, **Open <EXT>** for the newest `output/` file written
  within 20 min of the Clicky's last activity, **Full report** → Home window
  with that Clicky selected, **Stop** while working); the other Clickys as
  rotated pastel **sticky notes** (`StickyNote`) that click to the centre.
  Footer: **New Clicky** and **Apps** (both open the Home window).
- **Card status** is derived, not stored (`AgentRuntime.card(for:)`): running →
  *Working* + its live activity line; last transcript entry an error or an
  assistant message ending in "?" → *Needs you*; an assistant message → *Done —
  …*; nothing → *Idle* with the recorded "Nothing running. Hold the voice keys
  and give it something to do."
- **Settings**: the Setup page (`HomeView`) inside the panel with a sidebar of
  jump links (Backend · Talk · Permissions · Character · Dictation · Routines ·
  Integrations · Computer use · Privacy guard · Updates · Developer) that
  scroll to the section (`.setupScrollTo`), version in the sidebar footer.
- The Home window remains as the pop-out (full transcript, output column,
  Skills/Suggestions pages).

### 3.3c Clickys in the panel: list, chat, push-to-talk — built 2026-10-26
Recording item 4 (`docs/recording-gap-analysis.md` §3). `HUD/ClickyPanel.swift`,
`Talk/ClickyPushToTalk.swift`.
- **Menu-bar popover** (`NotchState.clickys`, `ClickyListView`): the menu-bar
  click now opens this (a second click closes whichever page is open). One row
  per Clicky: avatar, name, last message (or the live activity line while it
  works, or its purpose when the thread is empty), the day ("Friday" /
  "Yesterday" / a time today), a blue unread dot when the last assistant entry
  is newer than the last look at that thread (`NotchViewModel.seenAt`). Footer:
  **Apps +** and **New Clicky**. Header as everywhere (home · thread · Update app
  · pop-out · gear).
- **A Clicky's chat** (`NotchState.clicky(id)`, `ClickyChatView`, 780×≈510):
  left list with search and "+", the account row (first name · gear); right
  pane = the thread (user bubbles right in blue, Clicky left, errors red, last
  8), its opening line when empty ("Hi, I'm Desk. …") and **"Suggested: send
  one and I'll get started"** with the three starters as **coloured cards**
  (yellow / pink / blue, `SuggestionCard`) each with a send arrow; the live
  activity line with a spinner while it works. Bottom ledge: the Clicky's
  mascot peeking over a blue pill **"Hold ⌃ Control + ⌥ Option to talk to
  Desk"**, a **Type…** field (Return sends), and Stop while running.
- **Push-to-talk into the Clicky** (`ClickyPushToTalk`): while a Clicky's page
  is open the talk chord no longer starts general talk. It records with the
  on-device Apple recogniser (same locale as dictation), the pill turns green
  and shows the words so far + **"· Release to send"**, and the release sends
  the redacted transcript (`PrivacyGuard.redact`) to that Clicky as a turn.
  Nothing heard → "Didn't catch that" and back to the page. Esc cancels.
- The runtime's own notch updates (`.agent` steps, the finishing `.reply` /
  `.notice`) go through `AgentRuntime.hud(_:_:)`, which skips them while that
  Clicky's page, the list or the corkboard is open, so the page is not torn
  down mid-conversation — the thread shows the progress inline instead.
- Debug: `hud/clickys`, `hud/clicky?slug=`, `clicky/partial?text=` (held-pill
  look without a microphone), `clicky/talk?text=&slug=` (synthetic release →
  real turn).

### 3.13 Site awareness — built 2026-10-27
Recording item 5 (`docs/recording-gap-analysis.md` §4). `Site/SiteAwareness.swift`.
- **What it notices**: the page URL of the frontmost browser window, read over
  accessibility (`BrowserURLProbe`: Safari's window `AXDocument`, Chromium's
  `AXWebArea` `AXURL`; Safari, Chrome, Brave, Edge, Arc, Firefox, Vivaldi,
  Opera). Polled every 3 s only while a browser is frontmost
  (`SiteAwarenessMonitor`, driven by app-activation notifications); the host is
  logged, never the full URL.
- **When the bar shows** (`NotchState.site(SiteOffer)`, `SiteBarView`, 720 pt):
  the host matches the catalog, the notch is idle, the host was not answered
  "No" (persisted in `SiteOffersDeclined`), not "Not now"/"Yes" in the last 24 h,
  not shown in the last 6 h, and the **privacy guard allows the page** — a
  withheld URL (banking, checkout, sign-in, a protected app) never gets a bar.
  Auto-dismisses after 25 s.
- **What it says**: "Connect LinkedIn to Hi Dicky?" (or "Use Hi Dicky on
  LinkedIn" when the Composio toolkit is already connected, with no Yes/No
  row), "Use Hi Dicky to:" and the catalog's three chips, then **No · Not now ·
  Yes**. A chip sends "<task>. The page open in <browser> is <url> (<site>)."
  to the selected (else first) Clicky and opens its page in the panel. Yes
  opens Setup → Integrations. The catalog (`SiteCatalog`) covers LinkedIn,
  GitHub, Notion, Linear, Google Docs/Calendar, Gmail, Slack, YouTube, X,
  Figma, Jira, HubSpot, Shopify and Stripe, each with a Composio toolkit slug.
- Setup → Integrations has the on/off toggle (`SiteAwarenessEnabled`, default
  on). Debug: `site/show?url=…` forces the bar, `site/reset` forgets answers.

### 3.2d Hotkey event tap: Input Monitoring is required — found 2026-10-27
The talk chord "did nothing" for a real hand while synthetic events worked
minutes earlier. Diagnosis from the log: the keyboard tap was created fine
(Accessibility granted, `trusted=true`) and then macOS kept disabling it
(`tapDisabledByUserInput`, re-enabled by a watchdog, disabled again within
2 s, same for a freshly created tap) — because **Input Monitoring was not
granted** (`CGPreflightListenEventAccess() == false`; the Permissions window's
"4 of 5"). On this macOS a keyboard tap without Input Monitoring lives for a
few events, then dies, so the gesture works right after a relaunch and never
again. What changed:
- `HotkeyMonitor` runs a 2 s watchdog: re-enables a disabled tap, recreates it
  when re-enabling does not stick, logs each step, and calls `onTapKeptDying`.
- The app then checks the preflight and, once per session, shows a notch
  notice ("turn on Input Monitoring for Hi Dicky") and opens Permissions. The
  Permissions row no longer calls Input Monitoring a "fallback".
- `hotkey/status` logs running / enabled / Accessibility / Input Monitoring /
  secure input; `hotkey/restart` recreates the tap;
  `hotkey/request-input-monitoring` asks the system (adds the app to the list).
- The lasso also follows a drag that began before the overlay was armed
  (global mouse monitor in `RegionSelectOverlayManager`), and accepts right /
  other mouse buttons. A real hand presses the mouse within a fraction of a
  second of the chord; a synthetic test waited 1.5 s, which is why it never
  showed.

### 3.14 Walkthrough mode — built 2026-10-27
Website gap #1 (`docs/website-gap-analysis.md`): step-by-step teaching with
click-to-advance. `Talk/WalkthroughCoordinator.swift`,
`apps/backend/src/routes/walkthrough.ts`.
- **Starting one**: the chat model decides. A "how do I…" / "walk me through…"
  / "show me how to…" question that takes several actions in the app on screen
  comes back with `walkthrough.goal` (and one spoken sentence, no steps); the
  app starts the walkthrough with that goal. A single-action question still
  gets a normal answer with a target. Debug: `walk/start?goal=…`.
- **One step at a time**: every step is a fresh look — screenshot + element
  list (privacy guard applies) + the **log of completed steps** (instruction +
  outcome) + an optional note — sent to `POST /v1/walkthrough/step`, which
  returns ONE step: `say` (spoken), `instruction` (≤8 words, shown in the
  notch), `target` (element_id or normalized box), `done_when` (`click` or
  `manual`), `done` + `summary`. The prompt forbids repeating a completed step
  or sending the user back to a page they already left. **Up to 15 steps**
  (the backend forces `done` past the cap; the app also caps model calls at 40).
- **Click-to-advance**: the target is ringed on screen (`PointingOverlayManager`)
  and spoken; a global mouse monitor watches the next click. Inside the target
  (+10 pt) → logged as "clicked <label>", the app waits 1.2 s for the page to
  settle, then asks for the next step. Elsewhere → "That wasn't the spot. Let me
  look again…" and a re-plan from the current screen with a note saying where
  the click landed, so a step done another way is not repeated. `manual` steps
  (typing, reading, another app) wait for **Next** or a spoken "continue".
- **Voice while it runs**: the talk chord and the Ask field go to the
  walkthrough first (`TalkCoordinator.transcriptHook`): "continue / next / done /
  okay" advances, "stop / cancel" ends it, anything else is a question that
  re-plans with the note "the user said: …". Esc stops. Steps are spoken through
  the talk voice (`TalkCoordinator.say`); the voice's done callback no longer
  flips the notch back to the thread while a walkthrough is up.
- **Notch** (`NotchState.walkthrough`): "Walkthrough · step 3 of 15", the goal,
  the instruction in bold, a status line, Next (manual steps) and Stop; the
  cursor companion shows the instruction beside the pointer. The done state
  shows the summary and closes after 15 s.
- Verified live in TextEdit ("Save this document as a PDF"): step 1 was
  "Press Command–Tab once" because this window was in front (manual), then
  "Click File in the menu bar" → real click → "Click Export as PDF…" → real
  click → "Click Save", each ringed on screen and advanced by the click.
  One step request retries once (the model endpoint 503'd on the first try).

### 3.15 Memory of you — built 2026-10-27
Website gap #3 (`docs/website-gap-analysis.md`). `Memory/MemoryStore.swift`,
`apps/backend/src/routes/memory.ts`.
- **Two notes on disk**, App Support/`memory/PROFILE.md` (durable: name, what
  they do, tools, how they like answers, standing instructions; ≤15 lines) and
  `VOLATILE.md` (what they are working on right now; ≤8 lines). Shown and
  editable in Setup → Memory (Edit / Save, Learn now, Forget everything, on/off
  toggle `ClickyMemoryEnabled`).
- **Learning** is batched: every finished talk exchange (user + reply, not the
  clarify step) and every finished Clicky turn (last user message + result,
  not routines) is redacted and queued; 20 s after the last one, up to 12 go to
  `POST /v1/memory/extract`, which rewrites both notes (merge, no duplicates,
  drop stale) and says whether anything changed. The prompt refuses passwords,
  codes, OTPs, card/account numbers, keys, addresses, phone numbers and
  health/financial specifics — a decoy OTP in the first test was dropped.
- **Injection**: `MemoryStore.promptBlock` (redacted again on the way out)
  goes into the chat request (`memory` field → system prompt via
  `memoryBlock()`), the Realtime session instructions at mint time (so a
  running voice session picks up changes on its next connect), and every
  Clicky turn. **Caveat found here**: Claude Code ignores
  `--append-system-prompt` on `--resume` (a session keeps the system prompt it
  was born with; verified with a marker: resumed → "Unknown", fresh →
  "Pineapple"), so for a resumed session the block also rides inside the
  turn's prompt in an `<app-context>` block. The same limitation means the
  computer-use / integrations lines of the preamble are frozen for an existing
  session — a "New conversation" picks up the current ones.
- Debug: `memory/show`, `memory/learn?text=&reply=`, `memory/flush`,
  `memory/forget`.

### 3.16 Whole-document reading — built 2026-10-27
Website gap #4 (`docs/website-gap-analysis.md`). `Capture/DocumentReader.swift`.
- **What is read**, in order, during the talk context capture (in parallel with
  the screenshot, own 2 s time budget, off the main thread):
  1. **The file the window names** (`AXDocument`): PDFs page by page through
     PDFKit ("--- page 4 of 5 ---" markers), text-like files raw, RTF / Word /
     HTML through `NSAttributedString`.
  2. **Everything the window's accessibility tree exposes** (`walkText`):
     static text, text areas (the whole buffer, not the viewport), headings,
     links, cells; deduplicated; secure fields skipped. Safari, editors and
     most apps expose their full text this way.
  3. **A public fetch of the page** for a Chromium browser whose tree shows no
     web content (Chrome exposes the page only once an assistive client has
     asked; it did after a probe set `AXEnhancedUserInterface`, and not
     before). No cookies go with the request, so a signed-in page comes back as
     its public face or not at all. `htmlToText` is a small dependency-free
     stripper.
- Caps: 40,000 characters (head ¾ + tail ¼ when longer, flagged `truncated`),
  nothing under 300. The text is redacted and travels in the chat request's
  `document` field; the backend adds it as a `<document>` block with the title
  and kind and tells the model to say which part it drew on when it is not on
  screen (targets stay on-screen only). The thread shows "Read the whole PDF ·
  184 words". Setup → Talk has the toggle (`ClickyReadWholeDocument`, on).
- Privacy: Chromium gives its URL on the window (`AXDocument`), not in the
  tree, so the page URL from `BrowserURLProbe` now joins the privacy guard's
  URL check; a withheld screen sends no document either.
- Verified: a 5-page PDF open on page 1 in Preview — "Who runs the stall …?"
  answered "On page 4, Mrs Okonkwo runs stall 17 …" (`docs/demo/harbor-lights.pdf`);
  the repo page in Chrome — the last heading of the README named without
  scrolling (1,773 words read).

### 3.17 Screen-aware dictation, hands-free dictation, shortcut recorder — built 2026-10-27
Website gaps #9, #10 (part), #11 (`docs/website-gap-analysis.md`).
- **Screen-aware dictation** ("type a reply to this person in the box here"):
  the chat model gets an `insert` field. When the user asks it to type, write,
  draft or put something into a text box on screen, it writes the full text in
  `insert.text` — first person, the user's tone and sign-off from memory,
  grounded in the screenshot and the whole-document text — and a one-sentence
  spoken confirmation in `text`. The app (`TalkCoordinator.insertDraft`)
  types it into the field that had focus when the chord was pressed
  (`FocusedField.current()` at `beginHold`), through the dictation insertion
  path (paste + verify, AX fallback). Refuses password fields and secure input;
  a privacy-withheld app, no focused field, or a failed insertion falls back to
  the clipboard with the draft shown in the thread. The thread notes "Typed 16
  words into TextEdit". Verified: an email-shaped note in TextEdit got "Hi
  Sam, Tuesday at 3pm works for me, and yes, I got the deck. Best, Ashish" —
  the sign-off came from memory.
- **Hands-free dictation**: a quick double-tap of the dictation modifier
  (`HotkeyMonitor` `.dictationToggle`: two taps under 0.3 s each within the
  double-tap window, neither long enough to start the hold) starts dictation
  that keeps listening until the next double-tap, Esc or the normal end; the
  notch says "Hands-free · double-tap ⌥ again to stop".
- **Shortcut recorder** (Setup → Hotkey, `Home/ShortcutRecorder.swift`): three
  rows — Talk (hold), Text box (double-tap), Dictation (hold / double-tap) —
  each with Record: press the modifier combination, let go, and it is saved
  (`ClickyShortcut*` as raw `CGEventFlags`, modifier bits only) and applied
  live (`HotkeyMonitor.applySaved`). Reset to defaults. A warning shows when
  the talk keys equal another gesture's (the talk hold wins). Every hint in the
  app reads the saved keys (`HotkeyMonitor.talkLabel` etc.).

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

### 3.2 Talk mode — rebuilt to the recordings 2026-10-26
See `docs/recording-gap-analysis.md` for the evidence. What changed:
- **Gesture**: hold ⌃ Control + ⌥ Option (`HotkeyMonitor.talkChord`, 0.2 s);
  releasing either key ends the hold. Double-tap ⌃ still opens the prompt box;
  ⌥ alone still dictates; entering the chord cancels both.
- **Silent lasso**: while holding, a soft translucent blue stroke is drawn and
  simply attaches to the question; no action bar. The stroke stays on screen
  through the answer. With no words the request carries `(no words)` and the
  model answers with `clarify=true`: "What would you like me to do with the
  highlighted section…" plus two chips ("Explain what it is." / "Point out
  the controls."). A recent lasso (≤90 s) is reused by chips and typed
  follow-ups.
- **Thread in the notch**: `NotchState.conversation(ConversationModel)` — the
  last bubbles (user right, assistant left), a status line while thinking or
  speaking, chips (follow-ups from the model, or the clarify options), a
  "✕ Clear" chip while annotations are up, the blue "Hold ⌃ Control + ⌥
  Option to talk" pill and an "Ask Dicky…" field. Collapses 25 s after the
  voice finishes; Esc collapses and clears.
- **Annotations**: the reply's `targets` (≤6, in speaking order; element id or
  normalized box; kind marker / underline / box; label) are drawn by
  `PointingOverlayManager.showTargets` as numbered badges with sketched
  underlines or rings, revealed one by one over ≈ words ÷ 2.6 s, and kept
  until Clear, Esc or the next hold. The single `element_id`/`box` pointer
  remains the fallback.
- **Cursor marker** is the recorded blue triangle; the answer text no longer
  rides with the pointer (it is in the notch).
- Debug: `talk/chip?n=|text=`, `talk/clear`, `hud/conversation`,
  `hud/annotations`, `hud/annotations-snapshot?text=<path>`, `backend/restart|status`.
  Scratch tool `chord <s>` holds the real modifier chord through the HID tap.

### 3.0 Backend owned by the app — 2026-10-26
`App/BackendSupervisor.swift`: at launch the app probes `/healthz`; if
nothing answers and the backend source sits in the repo next to the bundle,
it starts `apps/backend` with the vendored `tsx` (no watch), logs to
Application Support/HeyClickyClone/backend.log, confirms health, and restarts
it with backoff (≤5 starts / 2 min) when it exits. A backend started by hand
is detected and left alone ("Running (started outside the app)"). Health is
re-checked every 20 s. Setup → Backend shows the state with Open log /
Restart; talk errors now say "The backend isn't running. Setup → Backend."
instead of a generic failure. Orphan `cua-driver serve` daemons from earlier
app instances are killed at launch. Verified: launched with the port dead →
started pid; killed by pid → "exited status=143; restarting" → new pid.

### 3.2a Talk language — fixed 2026-10-23
A reply was once read aloud in Spanish: nothing pinned the language, so the
Realtime model guessed from the room audio. Now English is pinned in three
places that must agree: the session instructions ("always speak English,
never translate or switch"), the input transcription `language` hint, and
every `response.create` ("Speak in English only"). Setup → Talk → Language
(`ClickyTalkLanguage`, default `en`) changes all three on the next talk;
the backend default is `REALTIME_LANGUAGE`.

### 3.2c Cursor tracker — built 2026-10-23
`Overlay/CursorCompanion.swift`: the blue ring that rides beside the mouse
(click-through panel at screen-saver level, repositioned at 60 Hz from
`NSEvent.mouseLocation`, clamped to the screen). It mirrors the notch state,
so there is one source of truth: waveform in the ring while listening (with a
3.5 s hint "Talk, or circle anything to ask about it"), a spinner while
thinking, the answer in a bubble next to the ring while speaking, a purple
mic dot with the live transcript while dictating. Setup → Talk → Cursor
tracker: always (default since 2026-10-27 — the user expects to see the
triangle at all times; an idle marker, agent steps and notices in the bubble),
while talking or dictating, or off. The original's
`BlueCursorView` / `CursorMessageBubbleView` were first read as the
point-at-target overlay only; this is the mouse-following half.
Debug: `cursor/demo?state=listening|thinking|speaking|dictating|idle|hidden&text=`,
`cursor/snapshot?path=`, `cursor/mode?value=talk|always|off`.

### 3.8c Build provenance — built 2026-10-23
`build-app.sh` stamps `GitCommit` (short SHA, `+local` when the tree was
dirty), `BuildDate` and `BuildConfiguration` into Info.plist; Setup → Updates
shows "This build: v… build … · commit · config · built …", then compares
with the repo next to the bundle (`git fetch` + rev-list) and says whether
the repo or origin/main is ahead. "Update from main" runs
`scripts/update.sh` (pull --rebase --autostash, build, quit, relaunch),
logging to Application Support/update.log; the script also works from a
terminal (`--no-pull` to just rebuild). Sparkle stays the path for a
distributed build.

### 3.2b Circle-to-ask — built 2026-10-23
`Talk/RegionSelectOverlay.swift`. While the talk key is held a transparent
full-screen panel takes the mouse: drag or circle something and the stroke
is drawn (purple, glowing); on release the bounding box becomes the
selection (dimmed outside, dashed box) and a bar appears beside it: **Ask**,
**Hand to ▾** (one entry per Clicky), **Copy**, ✕. Releasing the key with no
stroke just removes the overlay. Words and choice can arrive in either order:
the choice waits for the transcript, the transcript waits for the choice;
no words → "What is this?".
- Ask → `/v1/chat` with `region` (0..1 box of the screenshot) + `regionCrop`
  (the box re-encoded at high detail); the prompt tells the model to answer
  about the box and to keep any returned box in full-screenshot coordinates,
  so the pointing overlay still lands. Verified: synthetic loop drag during a
  real hold → bar → click Ask → key up with silence → reply "This is the top
  navigation bar…" and a pointer over the circled area.
- Hand to → the crop lands in the Clicky's tmp/handoffs and the turn starts
  (Scout read a crop and described it). Copy → PNG on the clipboard.
- Ask explains a circled control the way a colleague would (what it is, what
  it does in this app, how to use it, what to watch for; up to four spoken
  sentences, nothing the screen does not show). The reply card then offers
  **Tell me more**, which hands the same crop, the question and Clicky's
  answer to Scout for a researched, written walkthrough in output/.
- Privacy guard applies: a withheld screen refuses all three.
- Debug: `talk/region?x&y&w&h[&text][&action=ask|copy|handoff][&slug]`,
  `talk/arm`, `talk/bar` (logs the bar's frame), `talk/more`.

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

### 3.3a Turn controls — built 2026-10-23
Steer: sending while a Clicky is mid-turn writes another user message to the
running `claude` process (stream-json stdin), which folds it into the turn;
Home's composer, the dock's ask box and `agent/send` all do this. Interrupt:
Stop button, ⌘., Esc in Home, the global Esc hotkey (`AgentRuntime.stopAll`),
`agent/stop?slug=`. Threads: "New conversation" archives the transcript to
`history/<timestamp>.json` and forgets the Claude session (`agent/thread`).
Rename: roster + persona heading (`agent/rename`). Finish: system sound
(Pop/Glass/Funk, toggle) and a macOS notification when Home is not the active
window (first use asks for notification permission). Setup → Developer:
Claude model picker (`ClickyAgentModel`, next turn), sounds and notifications
toggles. See `docs/feature-audit.md` for the full comparison with the original.

### 3.3b Clickys on the desktop — built 2026-10-21, reworked 2026-10-23
`Dock/AgentDockPanel.swift`: a non-activating floating panel pinned to the
bottom-right of the main screen (follows screen changes, joins all Spaces),
one mascot per Clicky. Idle ones blink; a working one bobs and shows its
current tool step in a bubble (`AgentRuntime.activity`); a finished one
shows its reply for 25 s. Click a mascot to open its ask box (the panel is a
key-capable non-activating `DockPanelWindow`, so typing works while another
app stays frontmost); Return sends or steers; Esc closes; click the name to
open Home. The panel frame is fixed per Clicky count so nothing moves under
the pointer (the hover-driven first version fought the cursor). Verified
with a real mouse click + synthetic typing → turn → reply bubble. Toggle in Setup ("Clickys on the desktop",
`ClickyDockEnabled`, default on). Debug: `heyclickyclone://dock/on|off|snapshot?path=`.
The original's per-agent HUD also had an artifact pile and a follow-up voice
plate; those are still open.

### 3.4a Skills and Suggestions pages — built 2026-10-23
Sidebar rows under the Clickys. Skills: the bundled power-ups with a switch
per Clicky (installs/removes `.claude/skills/<name>`), Open to read the
SKILL.md. Suggestions: today's cards with Yes/No, "Ask again", earlier
answers (`MorningSuggestions` is observable; cards fetched with
`present: false` go only to the page). Routes `home/skills`, `home/suggestions`.
Setup → Dictation gained a language picker (`ClickyDictationLocale`).

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

### 3.5 Dictation — built 2026-10-21
- Hold **⌥ Option** alone (≥0.45 s; any other key cancels). The event tap
  reports `dictationBegan`/`dictationEnded` next to the talk gesture.
- Before listening: read the focused element over AX. A secure field, secure
  event input, or a privacy-guard "withhold" verdict for the frontmost app
  refuses with a notice; no audio is captured. Microphone + Speech permission
  must be granted (both still "Not asked yet" on this Mac).
- Transcriber: the backend's `POST /v1/dictation/token` mints a 10-minute
  Deepgram key when `DEEPGRAM_API_KEY` + `DEEPGRAM_PROJECT_ID` are set
  (`nova-3`, linear16 @16 kHz over the listen WebSocket); otherwise it answers
  `{provider:"apple"}` and the app uses `SFSpeechRecognizer`, on-device where
  supported. No key exists today, so Apple Speech is the live path.
- On release: `PrivacyGuard.redact` → `POST /v1/dictation/cleanup` (gpt-5.6-sol,
  strict schema: spoken punctuation, casing, field-aware formatting, the
  dictionary) → redact again → insert. Cleanup failure inserts the raw text.
- Insert = pasteboard + synthetic ⌘V (HID event source), polled up to 0.8 s
  for the field value to contain the text, then the previous clipboard is
  restored; if the paste did not land, AX `kAXValue` is set directly; with no
  readable value (web views, terminals) the paste is assumed. Failure copies
  the text to the clipboard and says so. Verified: both `pasted` and
  `setDirectly` outcomes into a TextEdit document via `heyclickyclone://dictate?text=`.
- Learned dictionary: 8 s after an insertion the field is re-read; new
  capitalised or ≥4-letter tokens the user typed in become dictionary words
  (`ClickyDictationDictionary`), announced in the notch and editable in Setup.
- Notch states `dictating(text)` (live transcript) and `dictated(text)`.

### 3.6 Routines and proactive suggestions — built 2026-10-21
- Registry: `~/Library/Application Support/HeyClickyClone/routines.json`
  (`Routine {id, agentID, title, task, everyMinutes, paused, lastRun, nextRun,
  lastSummary, runCount}`), local only — no backend row.
- Scheduler: a 30 s timer plus a catch-up on wake; a routine is due when
  `nextRun` has passed and it is not paused. Held (and re-queued in 60 s) when
  its agent is mid-turn; held while `NWPathMonitor` says offline. `nextRun`
  advances from the schedule, not from when the run finished. A failed run
  retries in 15 min.
- A run is an ordinary agent turn whose preamble says it is the routine, where
  to keep its dated note (`tmp/routine-<id>.md`), to report only what changed,
  and to answer exactly `Nothing new.` otherwise — a quiet result collapses the
  notch; news shows as a reply card.
- Agents create routines by ending a reply with
  `<ROUTINE>{"title","task","every_minutes"}</ROUTINE>`; the runtime strips
  the tag from the transcript and registers it. Three things had to be closed
  for this to hold: the CLI's own schedulers (`CronCreate`, `ScheduleWakeup`,
  the `schedule`/`loop` skills) are passed as `--disallowedTools` and denied
  again by the permission policy; `launchctl load/bootstrap`, `crontab`,
  `LaunchAgents` and sleep loops are denied shell patterns (one test turn
  installed a launchd job before this existed); and `routines.json`,
  `roster.json` and other Clickys' folders are off limits to the shell.
- Setup shows the registry with Run now / Pause / Delete; debug routes
  `heyclickyclone://routine/create|list|run|pause|resume|delete|tick`.
- Morning suggestions: once a day (first launch or wake between 05:00 and
  12:00, `ClickySuggestionsShownOn`), `POST /v1/suggestions` gets each
  Clicky's purpose, last six asks and existing routines and returns ≤3 cards
  grounded in that history (no integrations yet). The notch `suggestions`
  state shows Yes/No per card: Yes with `every_minutes` makes a routine and
  runs it; Yes without sends a one-off task; esc dismisses.
  `heyclickyclone://suggestions/show` forces a live fetch, `/demo` shows
  static cards.

### 3.7 Fast computer-use lane (optional, phase 3)
- A loopback MCP tool `suggest_action(goal, window)` that sends a projected
  accessibility tree to a small classifier and returns the next element to
  press/type with confidence. Falls back to the full model under 0.5
  confidence. We can start with a cheap LLM call instead of a trained head.

### 3.8 Onboarding — built 2026-10-21
`Onboarding/OnboardingWindow.swift`, shown on first launch (`ClickyOnboarded`
unset) and from the menu as "Welcome tour…". Nine steps: welcome → character
editor → voice (ten Realtime voices, previewed through `POST /v1/voice/preview`
= OpenAI `gpt-4o-mini-tts` MP3; the pick is `ClickyVoice` and rides on
`/v1/realtime/session {voice}`) → power-ups (the bundled skills in
`apps/mac/Bundle/skills/`: web-brief, file-tidy, meeting-notes, daily-digest,
installed into each starter's `.claude/skills/` on finish) → permissions (the
five kinds with Allow buttons) → mic check (RMS meter, "Heard you") → three
gestures with "Show me" HUD demos → starter squad → done. No intro video and
no Hermes catalog: those were the original's assets, not behaviour.
Debug: `heyclickyclone://onboarding[/reset|/step?n=N]`, `snapshot?window=onboarding`.

### 3.8b Character, updates, crashes — built 2026-10-21
- **Mascot** (`Character/`): an original vector blob creature, not the
  original's cloud. `ClickyCharacter {body: blob|cloud|bean|square, eyes:
  round|tall|sleepy|sparkle, hat: none|tuft|antenna|beanie|halo, colorway ×8,
  blush}`; one rig (`ClickyCharacterView`) renders the user's character in the
  notch hover pill and reply header, the Home header, onboarding, and every
  Clicky's avatar (`Agent.character`, else `derived(from: slug)` so each Clicky
  looks different without being edited). Editor in onboarding and Setup →
  Character; "Surprise me" randomises.
- **Updates**: Sparkle 2.10 via SwiftPM (`Sparkle.framework` copied into
  Contents/Frameworks and signed by `build-app.sh`). `SUFeedURL` defaults to
  `releases/appcast.xml` on main via raw.githubusercontent.com — the repo is
  private, so that URL serves nothing until the repo (or a releases repo) is
  public; `SUPublicEDKey` is the EdDSA key from `generate_keys --account
  HeyClickyClone` (private half in the login Keychain). Daily automatic
  checks; "Check for Updates…" in the menu and Setup. `scripts/release.sh`
  = release build → zip → `generate_appcast`. Verified against a local feed.
- **Crash reporting**: `CrashReporter` writes uncaught exceptions and fatal
  signals to `Application Support/HeyClickyClone/crashes/`, shows a notch
  notice on the next launch, and lists them in Setup → Crash reports. Sentry
  (sentry-cocoa 9.30, static) starts only when `SentryDSN` is set at build
  time and strips message/breadcrumbs before send. `heyclickyclone://crash/test?kind=exception|signal`.

### 3.9 Billing
Dropped (see decision 0). Keep the original's behaviour in mind only where it
shapes UI we are duplicating: the usage ring on the Home rail becomes a plain
"turns today" counter, and the paywall HUD state is not built.

### 3.11 Privacy guard (sensitive screens, codes and secrets)
One gate, `PrivacyGuard`, consulted by every path that observes the screen or
the user: talk-mode screenshots and accessibility harvests, computer-use
window reads and screenshots, clipboard reads, dictation and voice
transcripts, and logging.

- **Secure input.** While macOS reports secure keyboard entry (a password
  field is focused anywhere), no screenshot is taken and no element list is
  built. Any `AXSecureTextField` in a harvested tree is dropped along with its
  window's text values.
- **Protected apps.** Password managers, Keychain Access, Passwords, banking
  and payment apps, and authenticator apps are never captured, never read by
  the driver, and never the target of an agent action. Fixed list plus a
  user-editable one in Setup.
- **Protected pages.** Browser windows whose URL or title matches payment,
  checkout, banking, login, 2FA/OTP or account-security patterns are treated
  like protected apps. Detected from the accessibility tree (URL field, title),
  so it works without reading page content.
- **Codes in text.** Transcripts, dictation output, clipboard reads and agent
  tool results are scanned for one-time codes (4–8 digit sequences near words
  like code/OTP/verify, SMS-style code messages) and card numbers (Luhn-valid
  13–19 digit runs); matches are replaced with `[redacted]` before anything
  is sent to a model or written to disk.
- **Clipboard.** Agents never get `clipboard_read`; clipboard writes are
  allowed.
- **Logs.** No capture bytes, transcripts or tool outputs are ever logged;
  only sizes and timings.
- **Visible state.** When the guard blocks a capture, the HUD says so
  ("not looking: password field / protected app"), and the model receives
  a plain statement that the screen was withheld, never a blank image.

### 3.10 Starter agents ("the same two Clickys")
- On first launch, found the user's two agents automatically from a bundled
  definition file (`apps/mac/Resources/starter-agents.json`: name, purpose,
  persona notes, first-message suggestions), instead of an empty roster.
- Their names, purposes and the exact persona wording come from the user's
  own HeyClicky setup (to be supplied), reproduced in our persona template.
- Each starts with the three tappable first messages the original shows under
  a founded Clicky, and the HUD's agent state uses their names and initials.
- The New Clicky interview (3.3) stays, for agents beyond the starter two.

### 3.12 Integrations — built 2026-10-21
Two kinds, both delivered to a turn as extra `--mcp-config` HTTP servers next
to `cua`, so a Clicky sees them as `mcp__<server>__<tool>`.

- **Composio toolkits** (Gmail, Google Calendar, Google Drive, Notion, Slack,
  GitHub, Linear). Backend `/v1/integrations/{catalog,connect,disconnect,session}`
  over `@composio/core`, gated on `COMPOSIO_API_KEY` (no key on this machine,
  so the live app shows the "not configured" line). `connect` ensures one
  Composio-managed auth config per toolkit and returns a hosted Connect Link
  whose callback is `heyclickyclone://integrations/composio`; `session`
  creates a per-user session (`sessions.create(uid, {toolkits, mcp: true})`)
  and hands back `mcp.url` + `mcp.headers`, cached in the app for 20 min.
  The headers carry the project key, so they ride in the agent process's
  arguments — acceptable for personal use, not for distribution.
- **Custom connectors** (`Integrations/`): any remote Streamable-HTTP MCP
  server, stored in `connectors.json`; tokens in the Keychain (service
  `com.ashish.heyclickyclone.connectors`, account = connector id). Auth modes
  none / access token / OAuth. OAuth = RFC 9728 protected-resource metadata
  → RFC 8414 / OpenID metadata → RFC 7591 dynamic registration (public
  client, redirect `heyclickyclone://integrations/oauth`) → PKCE S256 code
  flow in the user's browser → exchange, refresh ahead of each turn when
  within 2 min of expiry. `MCPProbe` lists the server's tools for the Setup
  row. Verified end to end against `scripts/mock-connector.mjs` (an
  auto-approving OAuth server + MCP server): registration, authorize, token,
  probe (3 tools), then a real Scout turn where Claude Code reported
  `c-mock-notes=connected` and the mock logged `get_weather` and `add_note`
  calls carrying the bearer token.
- **Sensitive-action gate** (`IntegrationPolicy`): tools whose name contains
  send / reply / delete / remove / trash / pay / purchase / transfer / archive
  / cancel / publish are denied per server until the user flips "Allow send
  & delete" for that connector (or the Composio toggle). The preamble tells
  the Clicky to prepare everything else and say what it would have sent.
- Setup → Integrations lists toolkits with Connect/Disconnect and connectors
  with Sign in / Sign out / Test / On / Allow send & delete / remove, plus an
  add form. Debug routes: `integrations/add?name&url&auth[&token]`,
  `signin?id[&headless=1]`, `test?id`, `signout?id`, `remove?id`,
  `sensitive?id&on=1`, `list`, `composio/refresh|connect|disconnect`.
- Not built: HeyClicky's multi-account per toolkit and its connector
  capability editor; both are additive.

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

Done (2026-10-20, each verified live):

1. **Skeleton:** menubar app, notch HUD with states, hotkey tap, permissions
   flow, Supabase sign-in, backend with `/v1/config` and `/v1/chat`.
2. **Talk:** ScreenCaptureKit capture, Realtime voice, reply card, pointing
   overlay. (Place/image/stock reply cards deferred to phase 5.)
3. **Agents:** vendored Codex (app-server + code-mode host), app-server client,
   agent folders + personas, HUD streaming, Home Space transcript, model proxy.

Remaining, re-cut on 2026-10-21 for personal use and UI fidelity:

4. **Computer use:** embed cua-driver as the `computer-use` MCP server, one-time
   consent gate, destructive-label denylist, the MIT skill docs in context.
   This is what lets the two agents act in native apps like the original.
4b. **Privacy guard — done 2026-10-21:** the gate in 3.11 across talk mode,
   computer use, clipboard and logs (dictation joins when phase 6 builds it),
   21 rule checks in `swift run privacy-checks`, and live verification on a
   focused password field, a plain page and an agent read of a sign-in window.
5. **Home Space and agents — mostly done 2026-10-21:** starter Clickys (Scout,
   Desk) founded on first launch with first asks; New Clicky interview page
   (backend `/v1/interview`, brief → founded agent); Markdown transcript;
   output column with Quick Look and drag-out; file drop into the Clicky's
   folder; talk-to-agent handoff (chat returns `handoff`, the app drops the
   screenshot into tmp/handoffs and starts the turn). Still open from the
   original: cowork diff/table blocks, suggestions page, agent HUD artifact
   pile and follow-up voice plate, place/image/stock reply cards.
6. **Dictation and routines — done 2026-10-21:** hold-⌥ dictation (Apple
   Speech now, Deepgram when a key is configured), cleanup route, paste-and-
   verify with AX fallback, learned dictionary with Setup editor; routine
   registry + scheduler + agent `<ROUTINE>` tag; morning suggestions notch.
   Not yet exercised with a real microphone (permission not granted).
   Talk mode and the backend were rebuilt to the recordings on 2026-10-26
   (§3.0, §3.2).
7. **Integrations — done 2026-10-21:** Composio session MCP (gated on a
   key that is not configured here) plus custom OAuth/token connectors with
   discovery, registration, PKCE, refresh, a tool probe, and the per-server
   send/delete gate; verified against the bundled mock connector and a real
   agent turn.
8. **Polish, personal edition — done 2026-10-21:** onboarding tour (voice
   picker with previews, power-up picker, permission guide, mic check,
   gesture tutorial, starter squad), original mascot + character editor on
   one rig, Sparkle updates with a release script, local crash reports with
   optional Sentry. No Stripe, paywall or referral, by decision.

## 6. Open decisions

- **The two agents to duplicate:** their names, what each does, and any
  standing notes, as they exist in the user's HeyClicky today (a screenshot of
  the Home Space sidebar plus each agent's purpose line is enough).
- Mascot and brand (must be original).
- Whether talk mode uses OpenAI Realtime for both STT+TTS (simplest, matches
  original) or a separate STT → LLM → TTS chain (cheaper, more control).
- Whether to ship an x86_64 slice at all.
- Name of the product and bundle id.
