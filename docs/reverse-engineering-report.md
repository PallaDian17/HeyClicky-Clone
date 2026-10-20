# HeyClicky 1.0.53 — reverse-engineering report

Static analysis of `HeyClicky.dmg` (SHA-256
`a83c69ee8ec486d2cf9e257aaa39b612539f6b5544d52a4ef2caa652284bd31c`), app build
1.0.53 (64), git short SHA `cfc4ee64`, performed 2026-10-20. Nothing was
executed. Every claim below is tagged:

- **Observed** — read directly from the bundle (Info.plist, linked libraries,
  Swift type metadata, string literals, resource files).
- **Inferred** — a conclusion drawn from observed names and strings that was
  not confirmed by running the app or decompiling the function.
- **Unknown** — not established.

Tooling: REA `inspect_artifact` on the DMG (evidence
`ev_08b8adea4037b5e4a8366fd179fbdd728b6343c9d3533061320c41f6bc24005f`, 308
entries, 0 integrity contradictions), then a read-only `hdiutil` mount and
`otool` / `strings` / `swift-demangle` / `assetutil` on the copied bundle. The
Hopper decompile pass timed out on the 85 MB universal binary and was not
retried; no function bodies were read.

## 1. What the product is

**Observed.** A menubar-only (`LSUIElement`) macOS app, bundle id
`com.humansongs.clicky`, minimum macOS 14.2, universal arm64 + x86_64, built
with Xcode 27 / SDK macOS 27. Not sandboxed. Entitlements: audio input, camera,
network client, and a mach-lookup exception for the ScreenCaptureKit picker.
Usage strings request Screen Recording, Microphone, Speech Recognition, and
Desktop/Documents/Downloads access.

**Observed (marketing site).** "An AI buddy that lives on your Mac." Press a
hotkey, it sees the screen, you talk to it, it answers out loud and draws on
the screen to point at things; say "heyclicky agent" and it runs a task for you.
Plans: Free (25 talk + 25 agent messages/month), Pro $20 (unlimited talk, 150
agent messages), Max $100 (1,000 agent messages). Student discount. Windows
waitlist.

## 2. Stack

| Layer | Finding | Tag |
|---|---|---|
| App | Swift + SwiftUI + AppKit, single `HeyClicky` module (~1,300 types, 169 source files recovered from path strings). Original project name was `leanring-buddy` (sic). | Observed |
| Agent runtime | **OpenAI Codex CLI 0.152.1** bundled under `Resources/CodexRuntime/` (per-arch `codex`, `codex-code-mode-host`, `rg`, `zsh`). Driven over the Codex **app-server** JSON-RPC protocol with an isolated `CODEX_HOME`. | Observed |
| Computer use | **`cua-driver` 0.28.2** (trycua/cua, MIT) as `Contents/Helpers/cua-driver`, run as an embedded daemon over a Unix socket, exposed to Codex as the `computer-use` MCP server. | Observed |
| Fast computer use | A second loopback MCP server `jev-use` offering `drive_until` / `suggest_action`: an accessibility-tree-only policy head ("TypeSafe Jev", ~250 ms/step) served by the backend at `/agent/jev/systemone`. | Observed strings; behaviour Inferred |
| Integrations | **Composio** MCP (`[mcp_servers.composio]`) for Gmail, Notion, Linear, etc., plus user-defined "custom connectors" with OAuth discovery (`/.well-known/oauth-authorization-server`). | Observed |
| Routines | `[mcp_servers.clicky-crons]` MCP + backend `/agent/cron/*`; model emits a `<ROUTINE>{json}</ROUTINE>` block that the app parses and registers. | Observed |
| Voice (talk) | **OpenAI Realtime** over `wss://api.openai.com/v1/realtime?model=` (`gpt-realtime`, `gpt-realtime-2.1`), session minted by the backend (`/agent/realtime/session`), push-to-talk and always-on modes, AEC topology checks. | Observed |
| Dictation | **Deepgram** streaming (`wss://api.deepgram.com/v1/listen`, `nova-3`) with a backend-issued token, Apple `SFSpeechRecognizer` fallback, backend cleanup pass (`/v2/dictation/cleanup`), text injection with paste verification, a learned personal dictionary. | Observed |
| Talk-mode LLM | Backend `/v2/chat` and `/chat-tool-call`; Info.plist also carries direct `api.anthropic.com/v1/messages` and `api.openai.com/v1/chat/completions` URLs. Strings reference a "Haiku launch-labels" call and Anthropic chat auth with a Supabase bearer. | Observed |
| Auth | **Supabase** (email/OAuth via `/auth/v1/*`), custom URL schemes `clicky://` and `heyclicky://` for the callback. | Observed |
| Billing | **Stripe** via backend `/billing/checkout` and `/billing/portal`; paywall HUD; referral program with payouts (`/me/referral/*`). | Observed |
| Backend | `https://api.heyclicky.com` (single `WorkerBaseURL`); remote config at `/app-config`; feature flags at `/flags`. | Observed |
| Updates | **Sparkle** 2, appcast on `farzaa.github.io/clicky-releases`, hourly checks, auto-update. 8 releases from 1.0.46 (1 Aug 2026) to 1.0.53 (1 Oct 2026). | Observed |
| Telemetry | **Sentry** (crash + session replay integrations present), **PostHog** (US host), **PLCrashReporter**, MetricKit. | Observed |
| Frameworks | ScreenCaptureKit, Speech, AVFoundation/AVFAudio, EventKit, Contacts, Photos, PDFKit, QuickLook, MapKit (SwiftUI), Charts, Network, CryptoKit, ServiceManagement (launch at login), Carbon (hotkeys). | Observed |

The Info.plist embeds the vendor's PostHog key, Supabase anon key, Sentry DSN
and Sparkle EdDSA public key. These are the vendor's; the clone must mint its
own and must not reuse them.

## 3. Feature map (from type names, source-file names, strings, assets)

### 3.1 Notch surface ("Dynamic Island" HUD)
**Observed types:** `NotchWindowManager`, `NotchPresenter`, `NotchRootView`,
`NotchActivitySurface`, `NotchAgentSurface`, `NotchAgentPeekSurface` (file pile
with drag-out of workspace files), `NotchTextInputSurface`,
`NotchTextResponseSurface` (with a gallery strip), `NotchDictationClipboardSurface`,
`NotchDictionaryLearnedSurface`, `NotchHandoffSurface`,
`NotchMicrophoneTroubleSurface`, `NotchMorningSuggestionsSurface`,
`NotchMeetingCountdownSurface`, `NotchDocumentAccessSurface`,
`NotchAppUpdatedSurface`, `NotchEyeView`, `NotchSystemOverlayCoordinator`,
`NotchKeyboardFocusReleasePanel`, hover-dwell ring, corner glow.
**Inferred:** a persistent panel anchored at the display notch that morphs
between states (idle eye, listening waveform, agent progress, text reply,
dictation result, morning suggestions, meeting countdown, update notice), with
a "cat mode" red atlas variant.

### 3.2 Talk mode (hotkey → screenshot → answer + on-screen pointing)
**Observed:** `GlobalPushToTalkShortcutMonitor` (CGEvent tap, modifier
double-tap and hold detection: "Double-tap of control", "Hold Command to open"),
`ClickyHotkeyConfiguration/Recorder`, `ScreenshotManager` (ScreenCaptureKit,
excludes its own windows), `ActiveDocumentReader` (reads the whole document
under view, hence the Desktop/Documents/Downloads prompts),
`ScreenAnnotationManager/Overlay/CanvasView`, `SketchStrokeGenerator`,
`BlueCursorView` (guided click target, annotation highlight, spinner,
waveform), `ElementLocationDetector`, `AnnotationAccessibilityHarvester`,
`ResponseCardOverlay/Panel/View` (floating answer card with photo gallery),
`CursorMessageBubbleView`, `PlaceWidget` / `PlaceDetailOverlay` (map + photos
via `/places` backend), `StockWidget`, `ImageSearchAPI`, `/web-search`.
Prompt strings mention a `[TARGET]` visual tag with "click-to-advance turns",
so the model marks the element to point at and the user advances by clicking.
**Inferred:** the model receives the screenshot plus the harvested
accessibility tree, replies with text that is spoken via the Realtime session,
and may emit a `[TARGET]` tag that the app resolves to a screen location and
draws a blue cursor / sketch stroke on.

### 3.3 Agents ("Clickys")
**Observed:** `CodexProcessManager` ("Started app-server with isolated
CODEX_HOME"), `CodexProtocolClient` (methods `thread/start`, `thread/resume`,
`turn/start`, `turn/steer`, `turn/interrupt`, `item/*/requestApproval`,
`item/agentMessage/delta`, `thread/tokenUsage/updated`, `skills/*`,
`mcpServer/oauth/login`, `config/mcpServer/reload`, `account/login/start`),
`CodexAgentSession`, `CodexHUDWindow/Panel` (per-agent HUD with inline text
entry, artifact pile, follow-up voice plate), `CodexLaunchFlightOverlay`
(launch animation), `ClickyRoster` (named persistent agents, each with its own
working folder and `AGENTS.md` persona + notes), `ClickyOrganizer`
(`/clickys/organize-history`), `HomeSpaceNewClickyPage` (an interview flow
that founds a new Clicky), `HomeSpaceStarterCast` / `OnboardingSquadPicker`
(starter agents), `CompanionManager+EscapeInterrupt` (Esc stops the agent),
`EarlyStopRefund` (`/refund-early-stop`), turn leases
(`/agent/turn-lease/*`: `CodexAgentTurnLeaseRequestBody`, continue, completion,
"agent_turn_lease_required", "agent_turn_limit_exceeded"),
`ClickyAgentTurnCostLedger`, extra-effort approval, `ClickyComputerUseGate` /
consent, `AgentPermissionsInspector`, notifications (`/agent/notifications/*`),
`AgentCommentaryStream`, sounds (`agent-launch/done/needs-you/close.wav`).
Codex config written by the app: `model_provider = "clicky"`,
`[model_providers.clicky]` (backend-proxied OpenAI at `/agent/openai/v1`),
`approval_policy = "never"`, `sandbox_mode = "danger-full-access"`, MCP servers
`computer-use`, `jev-use`, `composio`, `clicky-crons`.
Model catalog (`ClickyCodexModelCatalog.json`): 14 entries, GPT-5.2 through
GPT-6.1 variants, 272k context, with visible/hidden flags and per-model
instructions. Developer settings expose model + reasoning effort.
**Inferred:** metering happens server-side through the turn lease: the app
asks the backend for a lease before each turn, the backend proxies the model
call and counts "agent messages", and a 402 produces the paywall HUD.

### 3.4 Home Space (main window)
**Observed:** `HomeSpaceRootView`, icon rail with usage ring, conversation
transcript + "cowork" transcript (command blocks, markdown, tables, file
diffs), composer with voice pill, attachments and file drop, output preview
column (PDF, Quick Look, markdown viewer with table support and file
watching), artifact cards, swipe-to-archive, context menu, suggestions page
(`/me/discovery-channel`, suggestion feedback), settings (account, dictation,
developer, integrations with multi-account, custom connectors, shortcut
recorder), skills library (`/skills/library`, `/skills/create`, "power-ups"
written to disk as SKILL.md), referral page (balance, earnings estimator,
friend code, payouts), account deletion flow with reasons.

### 3.5 Dictation
**Observed:** `BuddyDictationManager`, `DictationDeepgramTranscriber`,
`AppleSpeechTranscriptionProvider`, `DictationFocusContext` (what field is
focused), `DictationInsertion` / `TextInjectionDelivery` (paste with
verification), `DictationCorrectionLearner` + learned dictionary surface,
`DictationAnnouncementWindow` (language + shortcut), word quota paywall (402).

### 3.6 Handoff
**Observed:** `HandoffRegionSelectOverlay` (drag a screen region),
`HandoffQueuedRegionScreenshot`, `HandoffPostDragActionBar`, `HandoffDelivery`
with strategies/targets, `HandoffVoiceStopWindow`, `BrowserHandoffAcknowledgement`,
`<REALTIME_AGENT_HANDOFF>` block. **Inferred:** the user selects a region (or
speaks) during a talk session and the capture plus instruction is handed to a
Codex agent ("higher-model agent handoff"), or to the clipboard.

### 3.7 Proactive agents and routines
**Observed:** `ProactiveAgentsClient` (`/proactive-agents`), morning notch with
suggestion cards ("Finds real tasks in your connected apps, then invites you
through the morning notch"), yes/no history, daily automatic sweep;
`ClickyRoutines` with keep-awake, network and full-wake observers, run markers,
results mirrored into the same chat; `/agent/cron/list`, `/run-now`.

### 3.8 Onboarding
**Observed:** pre-sign-in intro modal with a voice picker (orbit / wave /
step-slider / discovery-map variants and 13 + 10 voice preview clips), skill
picker fed by vendored Hermes skills (MIT), intro video (`onboarding-intro-v2.mp4`,
44 MB) and paywall video, hatch animation (`hatching.wav`, `IntroHatchFlightOverlay`),
tutorial window with looping videos, mic level check, keycap hints, permission
guide assistant with drag-source overlay (drags the app into System Settings
lists), starter plan (`/onboarding/starter-plan`), phantom agents overlay.

### 3.9 Character
**Observed:** `ClickyCharacterEditor`, cloud portrait rig (limbs, ledge hand,
arm curve), colorways, hair choices, packs, randomize, portrait thumbnails,
`ClickyCharacters` asset, mascot hand poses. **Inferred:** a vector cloud
mascot the user customizes; the same rig renders in the notch, HUD and home.

### 3.10 Misc
Mission Control monitor, system window picker yield, call-presence detector
(mutes behaviour during calls), meeting join button + upcoming calendar bar
(EventKit, `/me/calendar/upcoming`), realtime tools for Spotify and Google
Calendar, diagnostics document, remote-task report sheet, team sharing of
skills (`/share-to-team`), launch-at-login.

## 4. cua-driver helper
**Observed:** 66 MB universal binary, Swift modules `ScreenCaptureKitBridge`,
`DispatchBridge`, `CoreFoundationBridge`; uses private SkyLight calls
(`SLEventPostToPid`, `SLPSSetFrontProcessWithOptions`, `SLPSPostEventRecordTo`)
to deliver clicks and keys to background windows without raising them; flags
`--embedded`, `--socket`, `--expected-pid`, `--permission-mode`,
`--capability-manifest`, `--claude-code-computer-use-compat`; env
`CUA_DRIVER_EMBEDDED`, `CUA_DRIVER_HOST_BUNDLE_ID`, `CUA_DRIVER_PERMISSION_MODE`
(`bounded` | `unrestricted`), telemetry to EU PostHog (disableable). The skill
docs name the exposed MCP tools: `launch_app`, `list_windows`,
`get_window_state`, `get_app_state`, `click`, `right_click`, `set_value`,
`type_text`, `press_key`, `hotkey`, `scroll`, `page`, `check_permissions`,
`health_report`, with `delivery_mode: background | foreground` and
`element_token` + `snapshot_id` handles. This is the upstream open-source
driver; it can be reused as-is under MIT.

## 5. Backend surface (paths found in the binary)

Auth and account: `/auth/v1/*` (Supabase), `/me/account/delete`, `/me/plan`,
`/me/memory`, `/me/memory/save`, `/me/referral`, `/me/referral/code`,
`/me/referral/claim`, `/me/calendar/upcoming`, `/me/discovery-channel`.
Talk: `/v2/chat`, `/chat-tool-call`, `/web-search`, `/places` (search, photos),
stock quotes, image search.
Agents: `/codex-thread-launch`, `/codex-thread-title`, `/agent/turn-lease/*`,
`/agent/session-token`, `/agent/record-agent-launch`, `/agent-messages`,
`/agent/openai/v1` (model proxy), `/agent/composio/session`,
`/agent/integrations[/…]`, `/agent/cron/*`, `/agent/jev/systemone`,
`/agent/notifications/*`, `/refund-early-stop`, `/continue`,
`/continue-after-computer-use-consent`, `/clickys/organize-history`,
`/proactive-agents`, `/onboarding/starter-plan`, `/runtime/model-policy`,
`/runtime/tool-policy`.
Realtime: `/agent/realtime/session`, `/warmup`, `/turn`, `/spotify/search`,
`/google-calendar/events[/create]`.
Dictation: `/v2/dictation/transcribe`, `/cleanup`, `/deepgram-token`.
Skills: `/skills/library`, `/skills/create`, `/skills/creations`,
`/skills/activations/sync`, `/publish`, `/unpublish`, `/share-to-team`.
Billing: `/billing/checkout`, `/billing/portal`. Config: `/app-config`, `/flags`,
`/report-error`.

Request/response shapes are **unknown** (not decompiled).

## 6. Licensing boundary for a clone

Reusable as-is (open source, with attribution):
- OpenAI Codex CLI (Apache-2.0) as the agent runtime.
- trycua `cua-driver` (MIT) as the computer-use driver, and its skill docs.
- NousResearch Hermes agent skills (MIT) and the Blender skill (MIT).
- Sparkle (MIT), Sentry/PostHog SDKs.

Must be rebuilt, not copied: the Swift app and its UI, the prompt system
(persona instructions, turn prompts, interview flow), the backend, the mascot
art and animations, the voices and sound design, the videos, the brand, and
all API keys. This report describes behaviour so it can be re-implemented; it
does not reproduce the vendor's prompt text.

## 7. Unknowns worth a runtime pass later

- Exact JSON shapes of the backend routes and the turn-lease handshake.
- How `[TARGET]` is resolved to coordinates (accessibility tree vs vision).
- The Jev policy head's input projection and output schema.
- Which calls go direct to OpenAI/Anthropic from the client versus through the
  backend (both URLs are present).
- Realtime tool list and the always-on barge-in gating rules.
