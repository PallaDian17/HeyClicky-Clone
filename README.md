# Hi Dicky

Hi Dicky is our own version of a "talk to your Mac" AI buddy (built by studying HeyClicky): a menubar app with a notch
HUD, push-to-talk screen-aware voice chat that can draw on the screen, named
agents that run tasks on the Mac through Claude Code and a computer-use
driver, dictation, and scheduled routines.

Status: **the notch panel is the app (2026-10-26).** Click the menu-bar
icon and a list of your Clickys drops from the notch (last message, day,
unread dot); pick one and its chat opens in the panel with coloured starter
cards, a Type… field and push-to-talk: hold ⌃ Control + ⌥ Option while its
page is open, speak, release to send. The mascot button shows the corkboard
home: the selected Clicky's card (Needs you / Done / Working, Open <file>,
Full report) with the others as sticky notes; the chat icon shows the talk
thread, the gear shows settings inside the panel, and an "Update app" pill
appears when an update is found. Say "type a reply to this in the box here" and Dicky drafts it in your voice straight into the field; double-tap ⌥ Option for hands-free dictation; record your own keys in Setup → Hotkey. With a PDF, a document or a web page in front, Dicky reads all of it, not just the visible part. Dicky remembers you: two short notes (who you are and how you like things, and what you're working on now) learned from what you say, shown in Setup → Memory, never codes or passwords. Ask "how do I…" about something that takes a few steps and Dicky walks you
through it one step at a time, ringing each thing to click and moving on when
you click it (up to 15 steps, Esc stops). On a known site in your browser (LinkedIn,
GitHub, Notion, Google Docs…) a bar offers the connector and three things a
Clicky could do there, never on pages the privacy guard withholds. Hold ⌃ Control + ⌥ Option,
speak, lasso anything while you hold; the answer is read aloud, shown as a
thread with follow-up chips, and marked on screen with numbered badges and
underlines as it goes. A lasso with no words makes Dicky ask what you want.
The backend that talk depends on is started, watched and restarted by the
app. See `docs/recording-gap-analysis.md`.

Earlier: **cursor tracker + build provenance (2026-10-23).** A blue ring now
rides beside the mouse while you talk or dictate: waveform while listening,
spinner while thinking, the answer in a bubble next to the pointer. Setup →
Updates shows exactly which commit the running app was built from and offers
"Update from main"; `scripts/update.sh` does the same from a terminal.

Earlier: **circle-to-ask (2026-10-23).** Hold the talk key and circle
anything on screen: a bar offers Ask, Hand to a Clicky, or Copy. Ask sends
the circled region (plus whatever you said, or "what is this?") and the
answer comes back spoken and pointed at.

Earlier: **feature pass against the original done (2026-10-23).** Every
observed HeyClicky feature is listed with its Hi Dicky counterpart and how it
was tested in [`docs/feature-audit.md`](docs/feature-audit.md). New in that
pass: steer a running Clicky by just sending more, Esc/⌘. interrupt, New
conversation with archived threads, rename, finish sounds and notifications,
Skills and Suggestions pages in Home, a model picker and dictation language in
Setup, and a desktop dock you can click and type into.

Earlier: **phase 8 + desktop Clickys.** Your Clickys also live on the desktop:
a small strip in the bottom-right corner shows each one, bobbing with its
current step while it works and holding up its reply when done; click to open
it, hover to ask it something (Setup → Clickys on the desktop).

Phase 8 — the personal edition is complete. First launch runs a
welcome tour: make the mascot yours (body, eyes, hat, colour; the same rig
shows in the notch, Home and every Clicky's avatar), pick a voice with live
previews, choose power-up skills for the starter Clickys, grant permissions,
check the mic, learn the three gestures, meet the squad. Updates come through
Sparkle (`scripts/release.sh` cuts a signed appcast); crashes are written to
Application Support and shown in Setup, with Sentry optional. All eight
phases of the rebuild spec are built. Not ported on purpose: Stripe, the
paywall, referrals, and the original's video and skill-catalog assets.

Phase 7 — integrations. Setup → Integrations has two halves.
Composio toolkits (Gmail, Calendar, Drive, Notion, Slack, GitHub, Linear)
connect through the backend when `COMPOSIO_API_KEY` is set and reach the
Clickys as one per-user MCP server. Custom connectors take any remote MCP
server: the app discovers its OAuth metadata, registers itself, signs in with
PKCE in your browser, keeps the tokens in the Keychain and refreshes them, and
lists the server's tools. Each turn gets the connected servers as `mcp__…`
tools; tools that send, delete or pay stay blocked per server until you allow
them. Verified against a bundled mock connector (`scripts/mock-connector.mjs`)
with a real agent turn.

Phase 6 — dictation and routines. Hold ⌥ Option and speak: the
transcript (Apple Speech on-device, or Deepgram when a key is configured) is
cleaned up for the field you are in by the backend, pasted with ⌘V, verified
by re-reading the field (accessibility set-value as the fallback), and words
you correct right after are learned into a dictionary you can edit in Setup.
Never into password fields or protected apps. Routines are tasks a Clicky
repeats on a cadence: ask for "every morning…" and the Clicky ends its reply
with a `<ROUTINE>` tag the app registers; a scheduler runs due routines while
the Mac is awake and online, holding when the Clicky is busy, and a run that
finds nothing new stays quiet. Once a morning the notch offers up to three
cards of things the Clickys could do today, grounded in their own history;
Yes makes a routine or a one-off task.

Phase 5 — the Home Space fills out. Two starter Clickys (Scout and
Desk) are founded on first launch with tappable first asks; a New Clicky page
runs a short interview that ends in a founded agent with its own persona notes
and first asks; the transcript renders Markdown; an output column lists what
each Clicky produced with Quick Look and drag-out; files dropped on the
composer land in the Clicky's folder; and talk mode hands "do this for me"
requests to a Clicky along with a screenshot of what you were looking at.

Phase 4b — privacy guard is on. One gate in front of every screen
and voice path: nothing is captured while a password field is active, in
password managers, keychain, wallet, banking or payment apps, or on payment,
sign-in and verification pages; one-time codes, card numbers and spelled-out
passwords are redacted from anything sent, shown or stored; agents never read
the clipboard; logs carry sizes and reasons only. Verified live against a
focused password field, a plain page, and an agent trying to read a sign-in
window. Rules are checked by `swift run privacy-checks`.

Phase 4 — agents can use the computer. With computer use switched
on in Setup, each turn gets trycua's `cua-driver` as a `computer-use` MCP
server: an embedded daemon the app spawns so it inherits the app's
Accessibility and Screen Recording grants, clicking and typing in native apps
in the background without stealing focus, gated by an in-app policy that
blocks launching settings/terminal apps, delete/send/quit shortcuts, and
never-press controls. Phase 3 made agents ("Clickys") run real tasks on Claude:
each Clicky is a folder with a `CLAUDE.md` persona, `output/` and `tmp/`, and
every turn is a headless `claude` process resumed by session id on the user's
own Claude login. No API key, no model proxy, no agent limit.
Phase 2 gave it talk mode: hold the hotkey, speak, and it captures the screen
and accessibility tree, transcribes through OpenAI Realtime, answers in the
notch HUD, reads it aloud, and points at the element. Phase 1 gave it the
menubar app, HUD states, hotkey gestures, permissions window, and Supabase
sign-in.

```bash
# backend (TypeScript, Hono, Node 22)
cp apps/backend/.env.example apps/backend/.env   # OPENAI_API_KEY, DEV_BYPASS_AUTH=1 for local
pnpm --dir apps/backend install && pnpm --dir apps/backend dev

# mac app (agents need Claude Code installed and logged in: `claude auth login`)
vendor/fetch-cua-driver.sh   # pinned cua-driver + skill docs, sha256-verified (computer use)
cp .env.example .env    # Supabase URL + anon key, BACKEND_URL
scripts/run-app.sh      # build, assemble build/HeyClickyClone.app, launch
```

Backend routes: `POST /v1/chat` (transcript + JPEG screenshot + element list →
spoken answer + pointer target, strict JSON schema), `POST /v1/realtime/session`
(mints an ephemeral Realtime client secret), `GET /v1/config`. Requests carry
the Supabase access token; the server verifies it against the project's JWKS
or legacy JWT secret.

See [docs/dev-setup.md](docs/dev-setup.md) for the signing-identity trick
that keeps macOS permissions across rebuilds and the debug URL hooks.

- [docs/reverse-engineering-report.md](docs/reverse-engineering-report.md) —
  what the reference app (HeyClicky 1.0.53) is made of, tagged observed /
  inferred / unknown.
- [docs/rebuild-spec.md](docs/rebuild-spec.md) — architecture, feature specs,
  repo layout, and a phased build plan for this clone.
- [docs/reference-source-files.txt](docs/reference-source-files.txt) — the
  169 Swift file names recovered from the reference binary, useful as a
  checklist of surfaces to cover.

Open-source pieces we plan to vendor unchanged: OpenAI Codex CLI (Apache-2.0),
trycua `cua-driver` (MIT), NousResearch Hermes skills (MIT). Everything else
(app, prompts, backend, art, voices, keys) is written fresh.
