# Working agreements

* **One package, many small libraries.** Each library is its own product (or
  a few: a core and a UI), its own targets under `Sources/` and `Tests/`, and
  one document, `docs/<Library>.md`. `README.md` is the index: add a row for
  each library.

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
  Tests use Swift Testing. Point-Free style.

* Run `make fmt` after writing Swift and `make lint` before finishing: the
  formatter owns line breaks (`respectsExistingLineBreaks: false`).

## Conventions from app-tooling

Some of this project's tooling is imported from app-tooling by peru:
`peru.yaml` says what, and at which commit. **Never edit an imported file
in place**; the change belongs in app-tooling. How to apply a new pattern,
update, or work against a local checkout is in
`docs/app-tooling/pattern-imports/README.md`. `app-tooling.toml` records
this project's parameters, deliberate deviations and declined patterns;
read it before changing anything a pattern covers.
