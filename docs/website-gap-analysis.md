# heyclicky.com vs. Hi Dicky (2026-10-27)

Source: the homepage, the full changelog (every release, v1.0 Apr 6 → v1.1.1
Oct 23, 2026), the trust page and the download page, read on 2026-10-27.
Compared against `docs/feature-audit.md`, `docs/recording-gap-analysis.md` and
what is built as of commit d094b93. Excluded on purpose (decisions on record):
billing, plans, student discount, referral / invite & earn, teams, Windows,
70+ talk languages (English pinned by request), PostHog analytics.

Legend: ❌ not built · 🟡 partial · ✅ have it · ⏸ paused upstream too

## What the site promises that we do not have

| # | HeyClicky (where) | Hi Dicky today | Status |
|---|---|---|---|
| 1 | **Walkthroughs**: step-by-step teaching up to 15 steps; detects when you click where it told you and advances; keeps a log of done steps; waits for slow pages (1.0.26, 1.0.48, 1.0.53). This is the homepage's core promise ("draws on your screen and teaches you"). | **Built 2026-10-27** (spec §3.14): one step per fresh look at the screen, log of done steps, ring on the target, click-to-advance, Next / "continue" for manual steps, up to 15 | ✅ |
| 2 | **Draws in 2D and 3D**: circles, points and sketches while talking; explanation cards with real photos; a draggable **3D model** for real things (engine, molecule, building), click a part to ask (1.1.1). | Markers, underlines, rings; no photo cards, no 3D | ❌ |
| 3 | **One brain / memory**: remembers earlier screens in the conversation and conversations day to day; PROFILE.md (habits) + VOLATILE.md (current project) injected into voice and agents (1.0.33, 1.1.1). | **Built 2026-10-27** (spec §3.15): PROFILE.md + VOLATILE.md learned from talk and Clicky turns, in Setup → Memory, injected into chat, voice and every turn | ✅ |
| 4 | **Whole-document understanding**: a PDF, file or web page is read entirely, not just what is on screen (1.0.47). | **Built 2026-10-27** (spec §3.16): the named file (PDF pages, text, RTF, Word), else the window's whole accessibility text, else a public fetch of the page; ≤40k chars in the chat request | ✅ |
| 5 | **HeyClicky drive**: from talk, with your yes, it moves the mouse and types while you watch; move the mouse, talk or press Escape to take back control (1.1.1). Earlier: realtime computer use by voice ("open my Stripe dashboard"). | Computer use only inside agent turns, behind a Setup toggle; no live hand-back | 🟡 |
| 6 | **Chrome extension**: agents work in your own signed-in Chrome in their own tab group; "Install for me" (1.1.1). | cua-driver drives a separate browser window | ❌ |
| 7 | **Captions** at the bottom of the screen while it talks; typed questions that get a drawing answer as captions (1.1.1). | Words only in the notch thread | ❌ |
| 8 | **Routines by voice**: "every Tuesday and Thursday at 5, check my inbox" sets one up; change / pause / delete the same way (1.1.1). | Routines only via a Clicky's `<ROUTINE>` tag; no talk path | 🟡 |
| 9 | **Screen-aware dictation**: "type a reply to this person in the box here" → screenshot, understands the email, drafts in your voice (1.0.37). | **Built 2026-10-27** (spec §3.17): the chat model's `insert` text is typed into the focused field, in your voice from memory, grounded in the screen and document | ✅ |
| 10 | **Dictation extras**: hands-free mode (double-tap), Fn+Control default, auto language detection (50+), ~450 ms streaming, 10-min sessions with local backup, keeps text through a mic change (1.0.34–1.0.47). | Hands-free by double-tap built 2026-10-27 (spec §3.17); auto language detection, Fn+Control default, long-session backup still open | 🟡 |
| 11 | **Shortcuts you record**: any held combo or double-tap for talk, text and dictation (1.0.11, 1.0.48). | **Built 2026-10-27** (spec §3.17): Setup → Hotkey records modifier combos for Talk, Text box and Dictation | ✅ |
| 12 | **Quiet when busy**: no spoken updates, cursor text, chimes or morning hello on a call, while screen sharing, in Focus or DND; separate switches for voice and cursor text (1.0.51). | Sounds + notifications toggles only; no call / share / Focus detection | ❌ |
| 13 | **Voice settings**: speech speed 0.5–1.5×, microphone selection, kid-friendly voices (1.0.45, 1.0.16). | Voice picker + preview only | 🟡 |
| 14 | **Audio resilience**: mic failover to built-in, Bluetooth profile handling, lid-closed mic switch, muted-speaker answer copied to clipboard with a volume fix, reconnect on a dropped voice connection (1.0.48, 1.0.53). | Nothing of this | ❌ |
| 15 | **Always-on mode**: Control ×3, headphones only, barge in mid-sentence (1.0.22, 1.0.26). | — | ❌ |
| 16 | **Agent windows from the notch**: each handed-off job hangs from the notch as a little window with its plan while working and its result when done; follow up on the top-right card by holding the voice keys; the card shows the files it made (1.1.1, 1.0.52). | Corkboard card + Clicky page; push-to-talk into a Clicky page exists; no per-job window with a plan | 🟡 |
| 17 | **Talk routes to Clickys from anywhere**: "what's running right now?", "tell Scout I like this too", "make me a Clicky that cleans my desktop", "make me three Clickys: …" (1.0.49, 1.0.51). | Hand-off with an agent hint; no status query, no create-by-voice, no multi-create | 🟡 |
| 18 | **Clicky list niceties**: pin, Mark as Unread / Read, archive with Unarchive from search, unread count badge on the resting notch (1.0.49–1.0.51). | Unread dots, archive of threads | 🟡 |
| 19 | **Home resizable from the notch** (drag edges, remembered), pop-out remembered across restarts, drafts kept per chat (1.0.50, 1.0.51). | Fixed-size notch pages; Home window | 🟡 |
| 20 | **Drag files into the notch** to talk about them; paste images with ⌘V into a Clicky chat (1.0.23, 1.0.49). | Attachments in the Home window only | 🟡 |
| 21 | **Links open directly** from a voice answer (YouTube, Maps, searches) (1.0.23). | Read aloud only | ❌ |
| 22 | **Realtime voice tools**: Google Calendar read/create and Spotify playback from talk (1.0.21, 1.0.22). | — | ❌ |
| 23 | **Multi-account connectors** (work + personal Gmail, labels, "add this to my work calendar"), reconnect per expired account (1.0.53, 1.1.1). | Composio catalog is wired but has no key; one account | ❌ (blocked on a Composio key) |
| 24 | **Suggestions from connected apps**: one researcher per app + the web over 72 h, an editor picks, "do it / next / adjust", sources travel with the task, resting after three unopened mornings (1.0.49–1.0.52). | Suggestions from the Clickys' own history | 🟡 ⏸ (paused upstream in 1.1.1) |
| 25 | **App skills for 89 apps** with browser-site matching, so guidance inside a tool is sharper (1.0.28); community skills library (⏸ since 1.0.49). | Bundled skills per Clicky; the site-awareness catalog covers 15 sites | 🟡 |
| 26 | **Computer-use consent per conversation**: Allow once / Always allow / Not now in the chat and the card, answerable by voice; self-healing driver (1.0.49, 1.0.53). | Global Setup toggle | 🟡 |
| 27 | **Routine resilience**: pause after three failed runs with the reason, catch up once after sleep, wait for internet, no start announcement (1.0.49, 1.0.50). | Scheduler runs while open; no failure pause / offline wait | 🟡 |
| 28 | **Smarter routing**: quick questions to a fast model, deep ones to a frontier model, chosen per question (1.0.45, 1.0.47). | One model; "Tell me more" hands to Scout | 🟡 |
| 29 | **"See what's new" card** in the notch after an update + changelog link in Settings (1.0.48). | Build stamp in Setup | ❌ |
| 30 | **Launch at login**, Show in Dock toggle, Report a bug with logs, Replay the welcome tour, permanent account deletion (various). | Replay tour: no; the rest: no | ❌ |
| 31 | **Notch stays put across display changes**; voice works on an external display (1.0.42, 1.0.49). | Untested on a second display | 🟡 |
| 32 | **Hand-drawn (Excalidraw-style) shapes** (1.0.40); highlights fade after 2 s, drawings clear when speech ends (1.0.31). | Sketch underlines and rings exist; markers stay until Clear (as recorded in 1.1.1) | ✅ |

## What we have that the site lists (for the record)
Notch as the only home; hold-to-talk thread with chips; circle-to-ask; the
Clicky roster with names, faces, memory folders and first messages; new Clicky
interview; archive threads; routines; morning suggestions; dictation with a
learned dictionary; voice picker with previews; character editor; Sparkle
updates with an "Update app" pill; crash reports; custom MCP connectors;
Keychain for tokens; privacy guard (ours goes further: withheld screens,
redaction).

## Recommended order (value for a personal build)
1. ~~**Walkthrough mode** (#1)~~ — built 2026-10-27.
2. ~~**Memory of you** (#3)~~ — built 2026-10-27.
3. ~~**Whole-document reading** (#4)~~ — built 2026-10-27.
4. ~~**Screen-aware dictation** (#9) + hands-free dictation + a shortcut recorder
   (#10, #11)~~ — built 2026-10-27.
5. **Drive from talk** (#5): voice-triggered computer use with the live
   hand-back rule (mouse moves, talk or Escape stops it).
6. **Captions** (#7), **quiet on calls** (#12), **voice speed + mic selection**
   (#13), **audio failover** (#14).
7. **Clicky conveniences** (#16–#20): per-job windows from the notch, status
   queries by voice, pin / mark unread / unarchive, resting-notch badge, files
   dropped on the notch.
8. **Photo cards and 3D** (#2): the showiest item and the most work; needs
   image search and a 3D asset source.
