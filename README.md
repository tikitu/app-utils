# app-utils

> **Made with an AI coding agent.** This repository was written largely by an
> LLM coding agent (Claude, in Claude Code), working under my direction and
> review. I say so up front so that anyone who would rather not use work made
> this way can decide that for themselves.

Small Swift libraries that came out of my apps, too small for a repo each.
One Swift package, one product per library: depend on the package and name
only the products you want. SwiftPM compiles just those; the rest cost a
clone and nothing more. None has dependencies of its own.

| Library | Products | What it is |
|---|---|---|
| [BooleanRules](docs/BooleanRules.md) | `BooleanRules`, `BooleanRulesUI` | *and* / *or* / *not* filters over terms you define: a text syntax and a SwiftUI rule editor |

```swift
// Package.swift
.package(url: "https://github.com/tikitu/app-utils", from: "0.1.0"),
// …
.product(name: "BooleanRules", package: "app-utils"),
```

## Versions

One set of tags covers every library, so a breaking change to any of them
bumps the major version (or, before 1.0, the minor). Pin with your
`Package.resolved` and move the pin deliberately.

## Working here

`make test`, `make fmt`, `make lint`. See `CLAUDE.md` for the rules.

MIT licence.
