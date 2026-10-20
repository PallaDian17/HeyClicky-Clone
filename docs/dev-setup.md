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
rebuild is a "new" app and the grants are lost. One-time fix: create a
self-signed code-signing certificate and sign with it.

1. Keychain Access → Certificate Assistant → Create a Certificate…
   Name `HeyClickyClone Dev`, Identity Type *Self Signed Root*,
   Certificate Type *Code Signing*.
2. In Keychain Access, open the certificate → Trust → Code Signing: *Always Trust*.
3. Export it for the build script:

```bash
echo 'CODESIGN_IDENTITY="HeyClickyClone Dev"' >> .env
```

The designated requirement now stays stable, so grants survive rebuilds.

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
