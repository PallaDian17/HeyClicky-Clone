# HeyClicky Clone

Our own version of a "talk to your Mac" AI buddy: a menubar app with a notch
HUD, push-to-talk screen-aware voice chat that can draw on the screen, named
agents that run tasks on the Mac through a bundled Codex runtime and a
computer-use driver, dictation, and scheduled routines.

Status: **research complete, no code yet.**

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
