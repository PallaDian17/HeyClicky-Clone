# Feature audit: Hi Dicky vs. HeyClicky (2026-10-23)

Every feature the reverse-engineering report observed in HeyClicky
(`docs/reverse-engineering-report.md` §3), what Hi Dicky does, and how it was
tested. "Tested" means exercised live on this Mac in this pass, through the
debug URL routes, synthetic keyboard/mouse events, real window captures, the
unified log, agent transcripts and the backend log. Decisions on record (§0 of
the spec) exclude billing, paywall and referral on purpose.

Legend: ✅ matches · 🟡 partial · ❌ not built · ⛔ excluded by decision

## 3.1 Notch HUD

| HeyClicky | Hi Dicky | Status | Tested |
|---|---|---|---|
| Persistent notch panel, morphs between states | `NotchPanel` + `NotchViewModel` states idle / listening / thinking / prompt / reply / agent / notice / dictating / dictated / suggestions | ✅ | all states rendered via `hud/<state>` + `hud/snapshot` |
| Idle eye | User's own character (rig shared with Home and the dock) | ✅ | hover pill captured |
| Hover-dwell ring, corner glow | Hover expands the pill; the cursor tracker's ring covers the dwell ring (no corner glow art) | 🟡 | hover stability verified with a parked pointer (3 captures, no flicker) |
| Text input surface | Prompt box, keyboard focus in a non-activating panel | ✅ | typed "What time is it…" with synthetic keys → `/v1/chat` 200 → reply card |
| Text response with gallery strip | Reply card, text only | 🟡 | reply card captured |
| Agent surface + peek (file pile with drag-out) | Agent state in the notch; file pile lives in Home's output column (Quick Look + drag-out) | 🟡 | output column verified in phase 5 |
| Dictation clipboard + learned-dictionary surfaces | `dictating`, `dictated`, "Learned: …" notice; clipboard fallback notice | ✅ | synthetic dictation into TextEdit (paste + AX fallback) |
| Handoff surface | Talk → Clicky handoff with screenshot into tmp/handoffs | ✅ | phase 5 live handoff |
| Microphone-trouble surface | Notice when mic/speech permission is missing | ✅ | shown before Microphone was granted |
| Morning suggestions surface | `suggestions` state with Yes/No cards | ✅ | live `/v1/suggestions` cards captured |
| Meeting countdown, document access, app-updated surfaces | Not built (needs calendar access; Sparkle shows its own update UI) | ❌ | — |
| Keyboard-focus release panel | Prompt box releases focus on collapse/Esc | ✅ | Esc path exercised |
| "Cat mode" red atlas variant | Not built (vendor art) | ❌ | — |

## 3.2 Talk mode

| HeyClicky | Hi Dicky | Status | Tested |
|---|---|---|---|
| Push-to-talk: modifier double-tap / hold | Hold Control + Option = talk (as recorded); Control double-tap = prompt; CGEvent tap | ✅ | tap running; gesture handler covered by `talk/hold` route (real mic, Realtime session) |
| Hotkey configuration + recorder | Fixed gestures (Control / Option) | 🟡 | — |
| Screenshot (SCK, excludes own windows) | `ScreenCapture` with SCK, own windows excluded | ✅ | screenshots reached the backend (`screenshot=yes`) |
| Reads the whole document under view | Accessibility harvest of the frontmost window (elements, URLs, secure fields) | 🟡 | `privacy/status` shows element counts |
| Realtime voice answer | OpenAI Realtime (`gpt-realtime`), voice chosen in onboarding/Setup | ✅ | `talk/hold`: session minted, connected, mic capture at 48 kHz; 4 s of silence produced an empty transcript (expected) |
| Blue cursor / sketch stroke pointing, `[TARGET]` | Pointing overlay from `element_id` / `box` in the chat reply | ✅ | phase 2 |
| Blue cursor companion + cursor message bubble (follows the mouse) | Cursor tracker: ring beside the pointer with waveform / spinner / answer bubble / mic dot, mirrors the notch | ✅ | rendered in every state; window followed three pointer moves; a real hold showed the listening ring |
| Region select during talk (drag a region, post-drag action bar, hand-off or copy) | Circle-to-ask: stroke overlay, Ask / Hand to / Copy bar, region + crop sent to the model; Ask explains what/does/how; Tell me more hands it to Scout | ✅ | synthetic circle drag during a real hold → Ask → reply + pointer; copy → PNG; hand-off → Scout |
| Numbered markers + underlines revealed while speaking, Clear, follow-up chips, clarify step | Built 2026-10-26 (`targets`, `follow_ups`, `clarify`; notch conversation) | ✅ | lasso with no words → clarify + chips; chip → 3 annotated targets |
| Click-to-advance turns | Not built | ❌ | — |
| Response card with photo gallery, Place/Stock widgets, image + web search | Not built (needs `/places`, `/web-search`, image search backends) | ❌ | — |
| Privacy of secrets on screen | Privacy guard: withholds the screen on password fields, protected apps, payment/sign-in/OTP pages; redacts codes and cards | ✅ (beyond original) | `privacy-checks` 21/21; live withheld case in phase 4b |

## 3.3 Agents ("Clickys")

| HeyClicky | Hi Dicky | Status | Tested |
|---|---|---|---|
| Runtime: Codex app-server | Claude Code headless (`claude -p`, stream-json), per-agent resumed session, Claude subscription | ✅ (by decision) | every agent turn in this pass |
| turn/start, delta streaming | Streaming text + tool steps into Home, HUD and the dock | ✅ | transcript shows tool rows + streamed reply |
| turn/steer | Sending while a turn runs steers it (stdin user message) | ✅ | Scout counting 1–40 was told to stop mid-turn; stopped at 10 |
| turn/interrupt, Esc stops the agent | Stop button, ⌘., Esc in Home, Esc hotkey (`stopAll`), `agent/stop` | ✅ | Desk's 60 s task interrupted after 10 s; process gone |
| Approvals | Permission policy on stdin: folder-scoped writes, destructive shell denylist, scheduler and launchd blocks, data-folder fence, computer-use gate, integration send/delete gate | ✅ | denials observed in phases 4–7 |
| Per-agent HUD with inline text entry | Desktop dock: mascot per Clicky, click opens an ask box, typing works without activating the app | ✅ | real mouse click + synthetic typing → turn started → reply bubble |
| Artifact pile, follow-up voice plate | Not in the dock (files in Home's output column) | 🟡 | — |
| Launch flight overlay | Bobbing mascot + "Pop" sound | 🟡 | — |
| Roster, per-agent folder, persona + notes | `AgentStore`, `CLAUDE.md` persona with dated notes | ✅ | phases 3–5 |
| Organize history, thread list, archive/rename/move | New conversation (archives to `history/`), history menu, Rename | 🟡 (no cross-agent move, no LLM organizer) | Desk: thread archived, transcript cleared, session reset |
| New Clicky interview, starter cast | Interview page + starters Scout/Desk | ✅ | phase 5 |
| Early-stop refund, turn leases, cost ledger | Not applicable (no metering) | ⛔ | — |
| Extra-effort approval | Not built | ❌ | — |
| Computer-use gate / consent | Setup toggle + policy | ✅ | phase 4 Calculator task |
| Permissions inspector | Blocked actions appear as status rows in the transcript | 🟡 | denial rows observed |
| Notifications | macOS notifications when a turn ends and Home is not in front (first use asks permission) | ✅ built | code path exercised; delivery depends on the system prompt the user answers |
| Commentary stream | Dock bubble shows the current step; notch shows agent state | ✅ | dock bubble captured |
| Sounds (launch / done / needs-you / close) | System sounds Pop / Glass / Funk, toggle in Setup | 🟡 (no custom wavs) | — |
| Model catalog + developer settings | Setup → Developer: Claude model picker; reasoning effort not exposed by the CLI | 🟡 | picker captured |

## 3.4 Home Space

| HeyClicky | Hi Dicky | Status | Tested |
|---|---|---|---|
| Sidebar rail with usage ring | Sidebar with avatars, running indicator; no usage ring (no metering) | 🟡 | captured |
| Conversation + cowork transcript (commands, markdown, tables, diffs) | Markdown + command rows with output; no diff/table blocks | 🟡 | captured |
| Composer: voice pill, attachments, drop zone | Attachments + drop zone; no voice pill (talk mode covers voice) | 🟡 | phase 5 |
| Output preview column (PDF, Quick Look, markdown, file watching) | Output column with Quick Look + watcher + drag-out | ✅ | phase 5 |
| Swipe-to-archive, context menu | Context menu: Rename, New conversation, Ask from the desktop, Finder, Delete | 🟡 | — |
| Suggestions page | Suggestions page (today's cards, Yes/No, Ask again, earlier today) | ✅ | captured |
| Settings: account, dictation (language, dictionary), developer, integrations (multi-account, custom connectors, shortcut recorder) | Setup: Account, Permissions, Hotkey, Character, Updates, Crash reports, Dictation (dictionary + language), Developer, Routines, Integrations (Composio + custom connectors), Computer use, Privacy guard, Clickys on the desktop | 🟡 (no multi-account, no shortcut recorder) | captured |
| Skills library + create | Skills page: bundled power-ups switchable per Clicky; own skills by folder | 🟡 (no create flow) | captured |
| Referral, account deletion | — | ⛔ | — |

## 3.5 Dictation

| HeyClicky | Hi Dicky | Status | Tested |
|---|---|---|---|
| Deepgram streaming with backend token | Deepgram path gated on a key; Apple Speech on-device otherwise | ✅ (Apple live, Deepgram untested: no key) | `dictate/begin`/`end` with the real mic: on-device recognizer started |
| Cleanup pass, dictionary, field-aware formatting | `/v1/dictation/cleanup` + learned dictionary | ✅ | TextEdit insertions in phase 6 |
| Paste + verify, AX fallback | ✅ | ✅ | both outcomes observed |
| Language setting | Setup → Dictation → Language | ✅ | — |

## 3.6 Routines and suggestions

| HeyClicky | Hi Dicky | Status | Tested |
|---|---|---|---|
| Cron registry + MCP, `<ROUTINE>` tag | Local registry, scheduler, `<ROUTINE>` tag; CLI schedulers blocked | ✅ | phase 6 live runs |
| Proactive sweep from connected apps | Suggestions from the Clickys' own history (no integrations data yet) | 🟡 | live cards |

## 3.7–3.10 Other

| HeyClicky | Hi Dicky | Status |
|---|---|---|
| jev-use fast computer-use lane | Not built (optional lane) | ❌ |
| Onboarding: voice picker, skills, intro video, tutorial, permission guide, mic check, squad | All but the videos | ✅ |
| Character editor (cloud rig, colorways, hair, randomize) | Own blob rig: body, eyes, hat, colourways, blush, randomize | ✅ (original art) |
| Sparkle updates | ✅, verified against a local signed feed | ✅ |
| Sentry / PLCrashReporter / MetricKit / PostHog | Local crash reports + optional Sentry; no analytics by decision | 🟡 |
| Launch at login | Not built | ❌ |
| Call-presence detector, meeting join bar, Spotify/Calendar realtime tools, team sharing | Not built | ❌ |

## Fixed in this pass

- Desktop Clickys: the ask box could not take typing (borderless panel never
  became key) and hover-driven expansion fought the pointer. Now click opens
  the box in a key-capable non-activating panel, Return sends or steers, Esc
  closes, the panel frame is fixed so nothing moves under the pointer.
- Notifications only fire when the Home window is not the active window.

## Still open (ranked by value)

1. Talk reply cards: places, images, stock quotes, web search (needs new backend routes).
2. Click-to-advance guided turns (circle-to-ask is done).
3. Thread list per Clicky in the UI (archives exist on disk), move thread between Clickys.
4. Diff and table blocks in the transcript.
5. Launch at login; hotkey recorder; meeting bar.
