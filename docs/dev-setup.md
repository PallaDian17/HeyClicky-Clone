# Developer setup (macOS app)

Requirements: macOS 14.2+, Xcode Command Line Tools with Swift 6 (full Xcode
is not needed), `git`.

```bash
cp .env.example .env            # fill in SUPABASE_URL / SUPABASE_ANON_KEY
scripts/run-app.sh              # swift build + assemble build/HeyClickyClone.app + launch
scripts/logs.sh                 # follow the app's unified log
```

`scripts/build-app.sh [debug|release]` only builds and assembles.

## Keep macOS permissions across rebuilds

macOS ties Accessibility / Screen Recording / Microphone grants to the app's
code signature. The default ad-hoc signature changes on every build, so each
rebuild is a "new" app and the grants are lost (the TCC log says "Failed to
match existing code requirement"). One-time fix, run it yourself because it
writes to your login keychain and shows one password dialog:

```bash
scripts/make-dev-cert.sh
```

It creates a self-signed code-signing certificate named "HeyClickyClone Dev",
trusts it for code signing, and sets `CODESIGN_IDENTITY` in `.env`. Rebuild,
grant the permissions once more, and they persist from then on. If the script
reports the identity is not yet valid, open Keychain Access → the certificate
→ Trust → Code Signing: Always Trust.

Stale entries from ad-hoc builds can linger in System Settings; clearing them
is harmless: `tccutil reset Accessibility com.ashish.heyclickyclone` and
`tccutil reset ScreenCapture com.ashish.heyclickyclone`.

## Debug URL hooks (debug builds)

The app registers the `heyclickyclone://` scheme. Besides the auth callback
it accepts a few developer routes, handy from a terminal or a script:

```bash
open "heyclickyclone://hud/listening"        # idle | listening | thinking | prompt | reply | agent | notice
open "heyclickyclone://hud/reply?text=Hello"
open "heyclickyclone://hud/snapshot?path=/tmp/hud.png"       # renders the HUD content to PNG
open "heyclickyclone://snapshot?window=permissions&path=/tmp/p.png"   # home | permissions | signin
open "heyclickyclone://home"
open "heyclickyclone://permissions"
```

```bash
open "heyclickyclone://talk?text=What%20is%20this%3F"   # full typed talk turn: capture -> /v1/chat -> HUD + pointer + voice
```

## Backend

`apps/backend` is a standalone pnpm package (Hono on Node 22, no database yet).
Copy `.env.example` to `.env` there; `DEV_BYPASS_AUTH=1` accepts unauthenticated
calls for local work. `pnpm smoke <image.png> "<question>"` hits a running server
with a real screenshot (one paid chat call plus one Realtime mint).

If `pnpm dev` refuses to start over an "ignored build scripts: esbuild" error,
run `pnpm approve-builds` once in `apps/backend` (the repo ships a
`pnpm-workspace.yaml` that allows it, but some pnpm versions still ask).

## Agents (Claude Code runtime)

Agents run on Claude through the user's own Claude login. Each turn, the app
spawns `claude -p --output-format stream-json --input-format stream-json
--permission-prompts host --setting-sources project` with the agent's folder as
the working directory, `--resume <session>` for continuity, and a clean
environment (HOME, USER, PATH only). Permission prompts come back as
`control_request` events and are answered by `PermissionPolicy`: anything
inside the agent folder is allowed, writes elsewhere and a short list of
destructive shell patterns are denied. `--setting-sources project` keeps the
user's personal Claude Code hooks, plugins and `apiKeyHelper` out of the agents.

Requirements: Claude Code installed (`~/.local/bin/claude`, Homebrew or
`/usr/local/bin`) and a live login (`claude auth login`). If `claude auth status`
reports `authMethod: api_key_helper`, a helper in `~/.claude/settings.json` is
shadowing the login for your own terminal use; the app ignores it, but a dead
key there breaks plain `claude` runs.

Each Clicky lives at `~/Library/Application Support/HeyClickyClone/agents/<slug>/`
with `CLAUDE.md` (persona + dated notes, loaded by Claude Code from cwd),
`output/`, `tmp/` and a `transcript.json` mirror of the chat.

```bash
open "heyclickyclone://agent/new?name=Scout&purpose=tidies%20notes"
open "heyclickyclone://agent/send?slug=scout&text=Create%20output%2Fhi.txt"
```

## Computer use (cua-driver)

`vendor/fetch-cua-driver.sh` downloads the pinned trycua `cua-driver` (MIT)
universal binary, its SDK dylib and cursor theme, plus the agent skill docs,
checksummed, into `vendor/cua/` (binaries gitignored, skill docs committed).
The build script bundles them under `Contents/Helpers/cua/` and
`Contents/Resources/cua-skill/`.

Off by default. Setup → Computer use (or `open "heyclickyclone://computer-use/on"`)
starts `cua-driver serve --embedded --socket <tmp>/heyclickyclone-cua.sock` as a
direct child of the app, so it inherits the app's Accessibility and Screen
Recording grants (trycua's embedding contract; launching it any other way
would give it its own TCC identity). Every agent turn then gets
`--mcp-config` with a `cua` server (Claude Code drops one named `computer-use`) that runs `cua-driver mcp
--embedded --socket …`, a thin stdio proxy to that daemon, and the cua-driver
skill is installed into the agent's `.claude/skills/`.

`ComputerUsePolicy` answers the `mcp__cua__*` permission prompts:
denied while consent is off; otherwise allowed except launching System
Settings, Terminal, Keychain Access, Disk Utility or Passwords, shortcuts that
delete, send or quit (⌘⇧⌫, ⌘⌫, ⌘⏎, ⌘Q…), and controls whose label is on the
never-press list (Empty Trash, Delete, Send, Pay, Purchase, Erase). The HUD
shows every step and Stop interrupts the turn.

## Talk mode on this machine

Talk mode degrades by permission: without Screen Recording the backend gets no
screenshot, without Accessibility it gets no element list, and without the
Microphone the hold gesture shows a notice instead of listening. The typed
prompt box (double-tap Control) and the `talk` URL work with none of them.

## Hotkey gestures

Default modifier is Control. Double-tap opens the prompt box in the HUD;
double-tap and hold starts listening; release stops. Escape collapses the HUD.
The gesture needs Accessibility (the Permissions window opens on first launch
until it is granted).

## Supabase

Add `heyclickyclone://auth/callback` to Authentication → URL Configuration →
Redirect URLs in your Supabase project. Enable the Google provider for the
"Continue with Google" button; email/password works out of the box.
