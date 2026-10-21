---
name: file-tidy
description: Sort a folder into sensible subfolders without losing anything. Use when the user asks to tidy, organize or clean up files.
---

# File tidy

- Work on the folder the user named; never touch anything outside it.
- First list what is there (`ls -la`) and group by kind and by project from
  the file names. Propose the folder plan in `tmp/tidy-plan.md` before moving.
- Move, never delete. Duplicates and things you are unsure about go to a
  `_review/` subfolder with a note why.
- Keep names readable: `2026-10-21 Lease agreement.pdf` beats `scan0001.pdf`
  when the content makes the name obvious; otherwise leave the name alone.
- Reply with how many files moved, the folders created, and what is in
  `_review/`.
