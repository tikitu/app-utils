# CommandInbox

Lets a script drive a running app through the app's own commands, with no
clicks and nothing coming to the front, and read back what each did. No
dependencies; Swift 6, macOS 14 / iOS 17.

The app keeps its own command enum and the method that performs one, the
same one its controls call. This library is the rest: it listens for a
Darwin notification, reads a JSON file of commands, decodes it strictly (a
typo is an error, never a command quietly not run), runs the commands in
order and writes what happened beside it. The sender script, the launch
arguments, the sandbox entitlement and the format a project's
`docs/commands.md` follows are app-tooling's `command-inbox` pattern:
<https://github.com/tikitu/app-tooling/tree/main/patterns/command-inbox>.

## What it gives you

| | |
|---|---|
| `CommandInbox<Command>` | `start()`: from then on, runs `inbox.json` in its directory whenever the notification is posted, and writes `result.json` |
| `StrictCommand<Name>` | decodes one command strictly; the app's command enum decodes itself on it |
| `CommandName` | the protocol for the enum of command names, with the fields each takes |
| `InboxCommand` | what the app's command type conforms to: `Decodable`, and a `name` |
| `CommandReply` | what `perform` returns: a message, and optionally structured `state` |
| `InboxError` | an error with a message, for the result |
| `InboxDirectory` | `argument(in:)`, the `--commands <dir>` launch argument; `applicationSupport`, for an iOS simulator |
| `CommandFile`, `InboxEntry`, `CommandResult` | the file's format and the result's, for tests |
| `CommandDocumentation` | `requests(in:)`: the request examples in a Markdown document, so a test can decode every one |

## The app's commands

```swift
import CommandInbox

enum AppCommand: InboxCommand {
    case add(title: String)
    case delete([String])

    var name: String {
        switch self {
        case .add: "add"
        case .delete: "delete"
        }
    }

    private enum Name: String, CommandName {
        case add, delete

        var fields: Set<String> {
            switch self {
            case .add: ["title"]
            case .delete: ["items"]
            }
        }
    }

    private enum Field: String, CodingKey { case title, items }

    init(from decoder: any Decoder) throws {
        let command = try StrictCommand<Name>(from: decoder)
        let fields = try command.fields(keyedBy: Field.self)
        switch command.name {
        case .add: self = .add(title: try fields.decode(String.self, forKey: .title))
        case .delete: self = .delete(try fields.decode([String].self, forKey: .items))
        }
    }
}
```

`StrictCommand` has already checked that the command is an object with one
key, a known name, holding only that command's fields. `command.error("…")`
makes the error for a check the field names cannot make ("takes exactly one
of index and taxon").

## Starting the inbox

Only where it cannot touch someone's real data: an app started on a scratch
database, or a simulator. Keep it for the app's lifetime.

```swift
@MainActor
static let inbox: CommandInbox<AppCommand>? = {
    guard isScratch, let directory = InboxDirectory.argument(in: CommandLine.arguments)
    else { return nil }
    return CommandInbox(directory: directory, notificationName: "com.example.MyApp.commands") {
        CommandReply(try await model.perform($0))
    }
}()
// …in main():
inbox?.start()
```

`start()` also runs an inbox already waiting, so a script can write one
before the app is up.

- `isReady:` — what the app's commands need before they run (data loaded, a
  window open). Each app command waits for it, up to `readyTimeout:` (30 s
  by default). Throw an `InboxError` from it for a state waiting will not
  fix.
- `snapshot:` — draws the app's windows to files and returns them, for the
  `snapshot` command. Without it, `snapshot` fails.
- `decoder:` — for the app's decoding strategies (dates, say).

## The inbox's own commands

`pause {"seconds": …}` and `snapshot {}` are in every file's vocabulary and
run without waiting for `isReady`. An app command of the same name is never
reached from a file.

## The result

```json
{
  "completed" : [
    { "command" : "add", "message" : "added 'Buy milk'" },
    { "command" : "state", "message" : "state", "state" : { "items" : [ "Buy milk" ] } }
  ],
  "requestID" : "the request's id, if it had one"
}
```

On the first failure the run stops, and `error` says which command failed
and why, or why the file could not be read.

## Testing the app's document

```swift
@Test(arguments: CommandDocumentation.requests(inFileAt: commandsDocumentURL))
func `every documented request decodes`(json: String) throws {
    _ = try JSONDecoder().decode(CommandFile<AppCommand>.self, from: Data(json.utf8))
}
```

`run(_:)` runs a file's commands without the files or the notification,
and returns the `CommandResult`, for tests of the app's `perform`.
