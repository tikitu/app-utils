# Working agreements

* **One package, many small libraries.** Each library is its own product (or
  a few: a core and a UI), its own targets under `Sources/` and `Tests/`, and
  one document, `docs/<Library>.md`. `README.md` is the index: add a row for
  each library.

* **No dependencies outside this package.** A package dependency is resolved
  by every consumer of every library here. If a library needs one, it needs a
  repo of its own.

* **Libraries do not know about the apps they came from**, nor about each
  other unless it is declared as a target dependency. Give anything new a
  general shape.

* **Versions are shared.** One tag set covers every library; a breaking
  change to any bumps the version for all (minor before 1.0, major after).
  Tag `X.Y.Z`, no `v`: SwiftPM reads the tags.

* Keep each library's document in step with its behaviour, in the same
  commit. Commit messages say *why*, and what was verified. Commit directly
  to `main`.

* Swift: Swift 6 mode, default isolation nonisolated; mark `@MainActor`
  where needed. Filenames with spaces are the style (`Rule tree.swift`).
  Tests use Swift Testing. Point-Free style — but no Point-Free libraries,
  per the no-dependencies rule.

* Run `make fmt` after writing Swift and `make lint` before finishing: the
  formatter owns line breaks (`respectsExistingLineBreaks: false`).
