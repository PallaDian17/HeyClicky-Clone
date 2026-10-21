# HeyClicky Clone

Our own version of a "talk to your Mac" AI buddy: a menubar app with a notch
HUD, push-to-talk screen-aware voice chat that can draw on the screen, named
agents that run tasks on the Mac through a bundled Codex runtime and a
computer-use driver, dictation, and scheduled routines.

Status: **phase 5 — the Home Space fills out.** Two starter Clickys (Scout and
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
