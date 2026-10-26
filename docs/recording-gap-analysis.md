# What the recordings show vs. Hi Dicky (2026-10-26)

Source: two screen recordings of HeyClicky 1.1.1 (66) on this Mac, 25 Oct 2026
(63 s and 312 s, no audio). Frames were extracted at 1 fps and read; times
below are seconds into each recording. This supersedes the static
reverse-engineering report wherever they disagree: the binary gave names, the
recordings give behaviour.

## Why Hi Dicky feels broken most of the time

Before the feature gaps: Hi Dicky depends on a backend process on
`localhost:8787` for talk, circle-to-ask, dictation cleanup, voice previews
and suggestions. That process has only ever run as a dev server started by
hand (or by Claude during a session) and it dies when that terminal or
session ends. The app then answers every talk with "Can't reach the backend"
or just stays on Thinking. Nothing in the app starts, watches or restarts it,
and Setup does not say it is down. The original has no such dependency on the
user's machine (its backend is hosted). **Fix first:** the app must own the
backend: start it at launch from the repo (or a bundled build), restart it
when it exits, show its state in Setup, and surface "backend down" in the
notch instead of a generic error. Also: stale `cua-driver serve` daemons from
earlier builds were found still running; the app should kill its orphans at
launch.

## The surfaces, as actually built

### 1. The notch panel is the whole app (rec2 0–30 s, 160–200 s)
A dark panel drops from the menu-bar centre (~520 pt wide). Its states:

- **Home / greeting**: "Afternoon, Ashish. · Hold Control + Option and tell me
  what to take off your plate." Below it a **corkboard**: the selected
  Clicky's card in the middle (white, dotted paper, red dot + "Needs you"
  badge, name, status line such as "Nothing running. Hold the voice keys and
  give it something to do.", a "Full report" button; finished ones show
  "Done — the one-page brief is ready in output/brief.pdf" with "Open PDF" +
  "Full report"), and the other Clickys as **sticky notes** (yellow, pink)
  tossed around it at slight angles with "Done"/"Needs you" tags. Footer:
  "Invite & earn" · "Apps +". Header: logo + chat icon left, "Upgrade" +
  gear right.
- **Talk conversation**: the same panel shows the talk as a thread of
  bubbles (assistant left, user right with "Read"), a big blue pill
  "🎤 Hold Control + Option to talk" and an "Ask HeyClicky…" text field.
  After a circled region with no words the assistant *asks*: "What would you
  like me to do with the highlighted section? I can explain what it is, or
  point out specific controls" and offers a chip "Explain what it is."
- **Settings**: inside the same panel with a sidebar — Account, General,
  Invite & Earn · HEYCLICKY: Voice, Microphone, Dictation, Shortcuts, Cursor ·
  WORK: Integrations, Agents, Routines · version footer. Integrations page:
  BROWSER → Chrome ("Let HeyClicky work in the sites you're already signed
  into", **Install for me** / I'll install it, "Works with Chrome, Brave, Edge
  and Arc"), search, **Add custom connector**, then Notion, Linear, GitHub,
  Google Docs, Google Calendar, LinkedIn with one-line capability text and
  Connect.

Hi Dicky: the notch is a small state pill; Home is a separate 920×620 window
with sidebar + transcript + output column; Setup is a page in that window.
**Gap: the notch-anchored panel with greeting, corkboard, conversation and
settings does not exist.** The Home window should become that panel (or the
panel should be the primary surface and the window a pop-out).

### 2. Talk mode behaviour (rec1 0–15 s; rec2 20–30 s, 240–312 s)
- Hotkey is **hold Control + Option** (the panel says so everywhere). Notch
  shows "Listening" → "Thinking" → "Speaking" with a waveform.
- **Lasso while listening**: a soft, translucent blue freehand stroke drawn
  over the page during the hold (rec2 247 s). No action bar: the region
  simply goes with the question. If nothing was said, the assistant asks what
  to do (see above).
- **Annotated, spoken explanation**: while speaking, the page gets
  **numbered circled markers ① ② ③ ④ beside the headings and blue underlines
  under the exact phrases** being discussed (rec2 262–307 s), revealed as the
  explanation proceeds; they persist after speech with a "✕ Clear" chip in
  the notch. The blue **triangle** cursor companion moves with the pointer.
- **Follow-up chips** after an answer, floating near the content:
  "Am I ready for this?" · "What should I build?" (rec2 307 s): suggested next
  questions, one click to ask.

Hi Dicky: Control double-tap/hold; lasso + a three-button bar; one pointer
box; a ring companion; no follow-ups; no clarify step. **Gaps: hotkey
mismatch, bar instead of silent attach, single target instead of numbered
multi-target underlines, no Clear, no follow-up chips, no "what would you
like me to do" step, triangle vs ring.**

### 3. Clickys (rec1 37–45 s, 58 s; rec2 0–10 s, 100–130 s)
- **Menu-bar popover**: list of Clickys with avatar, last message, day
  ("Tuesday"), unread dot; "Apps +", "Invite & Earn", an expand button;
  "Update app" pill at the top when an update is available.
- **Expanded panel** (rec1 39 s): left list with search and "+"; right pane
  = the Clicky's chat: its opening message, "Suggested: send one and I'll get
  started" with three **coloured suggestion cards** (yellow / pink / blue),
  each with a send arrow; bottom = the mascot peeking over a ledge, a blue
  **"Speaking ‖‖ · Release to send"** pill (push-to-talk straight into this
  Clicky) and a "Type…" field; pop-out and close buttons; account row
  ("Ashish · Free", info, gear).
- Clickys report through the corkboard cards and sticky notes (Done, Needs
  you) rather than a transcript-first window.
- No floating mascots on the desktop appear anywhere in either recording.

Hi Dicky: Home window with transcript, first-message cards, output column;
desktop dock with mascots; talk → hand-off. **Gaps: push-to-talk into the
selected Clicky ("Release to send"), coloured suggestion cards styling, the
menu-bar list popover, "Needs you"/"Done" status cards, "Full report" /
"Open PDF" actions.** The desktop dock is an invention; keep it optional.

### 4. Site awareness (rec2 125–130 s)
On linkedin.com a small bar appears top-centre: "**Connect LinkedIn to
HeyClicky?** Use HeyClicky to: [Find company profile details] [Summarize
recent post metrics] [Prepare comments to re…] · No · Not now · Yes". So the
app notices the site you are on, offers the matching integration, and shows
three things it could do there as chips.

Hi Dicky: nothing. **Gap.** Feasible without an extension: the accessibility
harvest already yields the frontmost browser URL; a small notch notice can
offer the connector and chips that start a Clicky turn with the page URL.

### 5. Smaller things seen
- Greeting by time of day and first name.
- "Update app" pill in the popover and panel header when a Sparkle update is
  available.
- Chrome integration ("Install for me") is how agents reach signed-in sites;
  we rely on cua-driver + the agent's own browsing.
- Talk replies are sentences; the annotated walk-through is the showcase.

## What was wrong in the audit
- `BlueCursorView`: a triangle marker beside the pointer, not a ring.
- `HandoffRegionSelectOverlay`: no action bar during talk; the region attaches
  silently and the assistant asks what to do.
- The notch is not a status pill but the app's main surface; Home is inside it.
- "Hover-dwell ring" is the cursor marker, not a notch effect.

## Status (2026-10-26)
Items 1–3 are built and verified live: the app owns the backend
(start/restart/status/orphan cleanup); talk mode uses the Control + Option
chord, the silent lasso, the clarify step with chips, numbered multi-target
annotations revealed with speech, Clear, follow-up chips and the triangle
marker; and the notch panel is the main surface — menu-bar click opens the
greeting + corkboard (selected Clicky's card with Needs you / Done / Working,
Open <file> / Full report, sticky notes for the others), the chat icon opens
the talk thread, the gear opens Setup inside the panel with a section
sidebar, and an "Update app" pill shows in the header when Sparkle finds one
(`HUD/HomePanel.swift`, spec §3.1a). Item 4 is built too: the menu-bar click
shows the popover list of Clickys (avatar, last message, day, unread dot,
Apps + / New Clicky), a row opens that Clicky's chat in the panel (list +
search on the left, thread with the three coloured suggestion cards and send
arrows, the mascot over the ledge, Type… field) and, with that page open,
the talk chord is push-to-talk straight into it — the pill shows the words
and "Release to send", release sends the turn (`HUD/ClickyPanel.swift`,
`Talk/ClickyPushToTalk.swift`, spec §3.3c). Item 5 is built as well: with a
known site open in the frontmost browser the bar drops under the notch —
"Connect GitHub to Hi Dicky? Use Hi Dicky to: [three chips] · No · Not now ·
Yes"; a chip sends the task plus the page URL to a Clicky and opens its page,
Yes goes to Setup → Integrations, and the privacy guard vetoes the bar on
withheld pages (`Site/SiteAwareness.swift`, spec §3.13). **All five items are
done.**

## Recommended order
1. **Backend supervised by the app** (start, restart, status, orphan cleanup).
2. **Talk, as recorded**: Control+Option hold; silent lasso attach; clarify
   step with "Explain what it is." chip; numbered multi-target markers +
   underlines revealed with speech; "Clear"; follow-up chips; triangle marker.
3. **Notch panel as the main surface**: greeting, corkboard cards with
   Needs you / Done / Full report / Open PDF, talk thread with the hold pill
   and Ask field, settings inside.
4. **Push-to-talk into a Clicky** from its panel, coloured suggestion cards,
   menu-bar popover list.
5. **Site awareness bar** from the harvested URL.
