# pattern-imports changelog

## v0.1.0 (2026-10-05)

Agent instructions live in `AGENTS.md` only. A project that has a
`CLAUDE.md` moves its content into `AGENTS.md` and deletes it (`apply.md`,
step 5), since Claude Code reads `AGENTS.md` only when there is no
`CLAUDE.md`.

First version: `peru.yaml` pins app-tooling at one commit and imports each
pattern's files and docs; `mk/app-tooling.mk` provides `app-tooling-update`
and `app-tooling-check`. The update refuses while an imported file has been
changed in the project; the README says what to do instead (build on the
file without changing it; else change app-tooling; taking the file over is
the last resort), and there is deliberately no merge. Tried on a scratch clone of an existing iOS app,
including a tag moved upstream, a local edit to an imported file, a fresh
clone, and reading unpushed commits from a local checkout.
