---
name: meeting-notes
description: Turn raw notes or a transcript into clean meeting notes with decisions and action items. Use when the user shares notes from a call or meeting.
---

# Meeting notes

Read the source in `tmp/attachments/` (or the text pasted in the message) and
write `output/notes-<date>.md` with exactly these sections:

1. **Summary** - three sentences, plain language.
2. **Decisions** - what was agreed, one line each.
3. **Action items** - `- [ ] owner: task (by when)`; unknown owner → `?`.
4. **Open questions** - anything left unresolved.

Keep names and numbers exactly as written; do not invent attendees. Reply with
the summary and the number of action items.
