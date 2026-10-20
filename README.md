# HeyClicky Clone

Our own version of a "talk to your Mac" AI buddy: a menubar app with a notch
HUD, push-to-talk screen-aware voice chat that can draw on the screen, named
agents that run tasks on the Mac through a bundled Codex runtime and a
computer-use driver, dictation, and scheduled routines.

Status: **phase 2 — talk mode works end to end.** Hold the hotkey, speak, and
the app captures the screen and accessibility tree, transcribes through OpenAI
Realtime, asks the backend, shows the answer in the notch HUD, reads it aloud,
and draws a blue pointer around the element it is talking about. Phase 1 gave
it the menubar app, HUD states, hotkey gestures, permissions window, and
Supabase sign-in.

```bash
# backend (TypeScript, Hono, Node 22)
cp apps/backend/.env.example apps/backend/.env   # OPENAI_API_KEY, DEV_BYPASS_AUTH=1 for local
pnpm --dir apps/backend install && pnpm --dir apps/backend dev

# mac app
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
