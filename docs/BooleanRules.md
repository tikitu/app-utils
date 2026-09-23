# BooleanRules

Boolean filters over terms you define — *and*, *or*, *not*, nested — with a
text syntax for people who type and a rule editor for people who do not. No
dependencies; Swift 6, macOS 14 / iOS 17.

Written for Say Out Loud's voice filter, but nothing here knows what a voice
is.

Two products: `BooleanRules` (expressions and syntax, no UI) and
`BooleanRulesUI` (the SwiftUI editor, which needs the first).

## What it gives you

| | |
|---|---|
| `BooleanExpression<Term>` | `.term`, `.not`, `.all`, `.any`; `evaluate`, `map`, `normalized` |
| `BooleanTerm` | conform your term type: `read(field:value:)` and `written` |
| `BooleanExpression.parse(_:)`, `.description` | the text syntax, both ways |
| `RuleSchema` | describe your fields for the editor: titles, comparisons, value menus or text, row ↔ term |
| `RuleTree` | the editor's model: groups (all / any / none / not all) of rules (is / is not), nested; pure, testable |
| `RuleEditor` (BooleanRulesUI) | the SwiftUI editor, bound to a `BooleanExpression` |

## The syntax

```
filter  := term ( ("and"? term)* | ("or" term)* )
term    := ("not" | "!" | "-") term | "(" filter ")" | field ":" value | value
value   := word | "quoted string"          (\" and \\ escape)
```

- Terms side by side are *and*: `colour:red size:big`.
- **No precedence.** `a b or c` is an error asking for parentheses. One level
  holds *and*s or *or*s, never both, so nothing is ever guessed.
- `not` takes the one term or group after it. Keywords ignore case.
- Errors carry a message and a character offset. Your term reader's errors
  (`TermError("There is no field “size”")`) get the offset added.
- Parsing normalises: `(a b) c` is `a b c`, `not not a` is `a`. Printing gives
  the canonical text, and reads back to the same expression.

## The editor

"Match **all / any / none / not all** of the following", then rows of field,
*is / is not* (your words: "contains", "starts with"), value, with round − and
+; "Add Rule" and "Add Group" on each group. Every expression has a rules
form, so the editor and a text field can edit the same value side by side.

It binds to the expression and follows it when it changes from outside. It
keeps its own `RuleTree` so rows keep their identity while edited; a rule not
yet filled in (your schema's `term(for:)` returns `nil`) and grouping the
expression would flatten away both survive, because the tree's expression is
compared with yours *normalised*.

## Using it

```swift
// Package.swift
.product(name: "BooleanRules", package: "app-utils"),
.product(name: "BooleanRulesUI", package: "app-utils"),   // if you want the editor
```

```swift
enum Term: Equatable, BooleanTerm {
    case word(String), colour(String)
    static func read(field: String?, value: String) throws(TermError) -> Term { … }
    var written: String { … BooleanSyntax.written(field: "colour", value: v) … }
}

let filter = try BooleanExpression<Term>.parse("colour:red or not big")
filter.evaluate { term in … }                 // your meaning of a term

struct Schema: RuleSchema { … }               // fields, titles, values, row ↔ term
RuleEditor(expression: $filter, schema: Schema())
```

`Tests/BooleanRulesTests` is a complete worked example with a toy term type.

## Not (yet) here

- Localisation: the keywords (`and`, `or`, `not`) and the editor's words
  ("Match", "of the following", "Add Rule") are English.
- Keyboard navigation of the editor beyond what SwiftUI controls give.
- Drag to reorder rules or move them between groups.
