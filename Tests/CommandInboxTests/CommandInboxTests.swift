import Foundation
import Testing

@testable import CommandInbox

/// An app's commands, as an app declares them.
enum TestCommand: Equatable, InboxCommand {
    case add(title: String)
    case delete([String])
    case state
    case fail

    var name: String {
        switch self {
        case .add: "add"
        case .delete: "delete"
        case .state: "state"
        case .fail: "fail"
        }
    }

    private enum Name: String, CommandName {
        case add, delete, state, fail

        var fields: Set<String> {
            switch self {
            case .add: ["title"]
            case .delete: ["items"]
            case .state, .fail: []
            }
        }
    }

    private enum Field: String, CodingKey { case title, items }

    init(from decoder: any Decoder) throws {
        let command = try StrictCommand<Name>(from: decoder)
        let fields = try command.fields(keyedBy: Field.self)
        switch command.name {
        case .add:
            let title = try fields.decode(String.self, forKey: .title)
            guard !title.isEmpty else { throw command.error("add takes a title that is not empty") }
            self = .add(title: title)
        case .delete: self = .delete(try fields.decode([String].self, forKey: .items))
        case .state: self = .state
        case .fail: self = .fail
        }
    }
}

private func decode(_ json: String) throws -> CommandFile<TestCommand> {
    try JSONDecoder().decode(CommandFile<TestCommand>.self, from: Data(json.utf8))
}

// MARK: - Decoding

@Suite
struct StrictDecodingTests {
    @Test
    func `a file decodes to its commands, in order, with the inbox's own among them`() throws {
        let file = try decode(
            #"""
            {"id": "r1", "commands": [
              {"add": {"title": "Buy milk"}}, {"pause": {"seconds": 0.5}},
              {"delete": {"items": ["a", "b"]}}, {"snapshot": {}}, {"state": {}}
            ]}
            """#)
        #expect(file.id == "r1")
        #expect(
            file.commands == [
                .command(.add(title: "Buy milk")), .pause(seconds: 0.5),
                .command(.delete(["a", "b"])), .snapshot, .command(.state),
            ])
    }

    @Test(arguments: [
        #"{"commands":[{"ad":{"title":"x"}}]}"#,  // unknown command
        #"{"commands":[{"add":{"name":"x"}}]}"#,  // unknown field
        #"{"commands":[{"add":{"title":"x"},"state":{}}]}"#,  // two keys
        #"{"commands":[{}]}"#,  // no key
        #"{"commands":[{"state":null}]}"#,  // not an object
        #"{"commands":[{"add":{}}]}"#,  // missing field
        #"{"commands":[{"add":{"title":""}}]}"#,  // the app's own check
        #"{"commands":[{"pause":{}}]}"#, #"{"commands":[{"pause":{"seconds":-1}}]}"#,
        #"{"commands":[{"pause":{"seconds":1,"extra":2}}]}"#,
        #"{"commands":[{"snapshot":{"window":1}}]}"#,
    ])
    func `a typo is an error, not a command quietly not run`(json: String) {
        #expect(throws: DecodingError.self) { try decode(json) }
    }

    @Test
    func `an unknown command's error lists the known ones, the inbox's own included`() {
        let error = #expect(throws: DecodingError.self) { try decode(#"{"commands":[{"ad":{}}]}"#) }
        let description = "\(String(describing: error))"
        #expect(description.contains("add, delete, fail, state"))
        #expect(description.contains("pause, snapshot"))
    }
}

// MARK: - Running

@MainActor
private func inbox(
    directory: URL = FileManager.default.temporaryDirectory, readyTimeout: Duration = .seconds(30),
    isReady: @escaping @MainActor () throws -> Bool = { true },
    snapshot: (@MainActor () async throws -> [URL])? = nil,
    performed: @escaping @MainActor (TestCommand) -> Void = { _ in }
) -> CommandInbox<TestCommand> {
    CommandInbox(
        directory: directory, notificationName: "org.example.commandinboxtests",
        readyTimeout: readyTimeout, isReady: isReady, snapshot: snapshot
    ) { command in
        performed(command)
        switch command {
        case .add(let title): return CommandReply("added '\(title)'")
        case .delete(let items): return CommandReply("deleted \(items.count)")
        case .state: return CommandReply("state", state: ["items": ["Buy milk"]])
        case .fail: throw InboxError("no such item")
        }
    }
}

@MainActor
@Suite
struct RunTests {
    @Test
    func `commands run in order, stopping at the first failure`() async {
        var performed: [TestCommand] = []
        let result = await inbox(performed: { performed.append($0) }).run(
            Data(
                #"{"id":"r","commands":[{"add":{"title":"a"}},{"fail":{}},{"add":{"title":"b"}}]}"#
                    .utf8))
        #expect(performed == [.add(title: "a"), .fail])
        #expect(result.requestID == "r")
        #expect(result.completed.map(\.command) == ["add"])
        #expect(result.completed.map(\.message) == ["added 'a'"])
        #expect(result.error == "fail failed: no such item")
    }

    @Test
    func `a file that does not decode runs nothing, and says why`() async {
        var performed: [TestCommand] = []
        let result = await inbox(performed: { performed.append($0) }).run(
            Data(#"{"commands":[{"add":{"title":"a"}},{"nosuch":{}}]}"#.utf8))
        #expect(performed.isEmpty)
        #expect(result.error?.hasPrefix("could not read commands:") == true)
        #expect(result.error?.contains("unknown command 'nosuch'") == true)
    }

    @Test
    func `a command waits until the app is ready`() async {
        var checks = 0
        let result = await inbox(isReady: {
            checks += 1
            return checks >= 3
        }).run(Data(#"{"commands":[{"add":{"title":"a"}}]}"#.utf8))
        #expect(result.error == nil)
        #expect(checks == 3)
    }

    @Test
    func `a command fails when the app is not ready in time`() async {
        let result = await inbox(readyTimeout: .milliseconds(250), isReady: { false }).run(
            Data(#"{"commands":[{"add":{"title":"a"}}]}"#.utf8))
        #expect(result.error?.hasPrefix("add failed: the app was not ready after") == true)
    }

    @Test
    func `a readiness check that throws fails the command at once`() async {
        let result = await inbox(isReady: { throw InboxError("two windows are open") }).run(
            Data(#"{"commands":[{"add":{"title":"a"}}]}"#.utf8))
        #expect(result.error == "add failed: two windows are open")
    }

    @Test
    func `the inbox's own commands do not wait for the app`() async {
        let result = await inbox(isReady: { false }).run(
            Data(#"{"commands":[{"pause":{"seconds":0}}]}"#.utf8))
        #expect(result.error == nil)
        #expect(result.completed.map(\.message) == ["paused 0.0s"])
    }

    @Test
    func `snapshot fails without a way to draw, and reports the files with one`() async {
        let request = Data(#"{"commands":[{"snapshot":{}}]}"#.utf8)
        #expect(await inbox().run(request).error == "snapshot failed: this app takes no snapshots")
        #expect(
            await inbox(snapshot: { [] }).run(request).error
                == "snapshot failed: no window was drawn")
        let drawn = await inbox(snapshot: { [URL(filePath: "/tmp/a.png")] }).run(request)
        #expect(drawn.completed.map(\.message) == ["/tmp/a.png"])
    }

    @Test
    func `a reply's state is in the result, and only when there is one`() async throws {
        let result = await inbox().run(
            Data(#"{"commands":[{"add":{"title":"a"}},{"state":{}}]}"#.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let json = try #require(String(data: try encoder.encode(result), encoding: .utf8))
        #expect(
            json == #"{"completed":[{"command":"add","message":"added 'a'"},"#
                + #"{"command":"state","message":"state","state":{"items":["Buy milk"]}}]}"#)
    }
}

// MARK: - The files

@MainActor
@Suite
struct InboxFileTests {
    @Test
    func `the inbox is taken, run, and answered beside it`() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(
            path: "CommandInboxTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var performed: [TestCommand] = []
        let inbox = inbox(directory: directory, performed: { performed.append($0) })
        try Data(#"{"id":"f","commands":[{"add":{"title":"a"}}]}"#.utf8).write(to: inbox.inboxURL)

        await inbox.processInbox()

        #expect(performed == [.add(title: "a")])
        #expect(!FileManager.default.fileExists(atPath: inbox.inboxURL.path(percentEncoded: false)))
        let result = try String(contentsOf: inbox.resultURL, encoding: .utf8)
        #expect(result.contains(#""requestID" : "f""#))
        #expect(result.contains(#""message" : "added 'a'""#))

        // Nothing waiting: nothing runs, and the last result stays.
        await inbox.processInbox()
        #expect(performed.count == 1)
    }
}

// MARK: - Helpers

@Suite
struct InboxDirectoryTests {
    @Test
    func `the directory is the value after --commands`() {
        #expect(
            InboxDirectory.argument(in: ["MyApp", "--commands", "/tmp/My App/Commands", "--x"])
                == URL(filePath: "/tmp/My App/Commands", directoryHint: .isDirectory))
        #expect(InboxDirectory.argument(in: ["MyApp", "--scratch-database"]) == nil)
        #expect(InboxDirectory.argument(in: ["MyApp", "--commands"]) == nil)
    }
}

@Suite
struct CommandDocumentationTests {
    @Test
    func `requests are the json blocks that hold commands, not the results`() {
        let markdown = """
            # Commands

            ```json
            {"commands": [{"add": {"title": "Buy milk"}}]}
            ```

            The result:

            ```json
            {"completed": []}
            ```

            ```sh
            scripts/send-commands.sh '{"commands": []}'
            ```
            """
        #expect(
            CommandDocumentation.requests(in: markdown) == [
                "{\"commands\": [{\"add\": {\"title\": \"Buy milk\"}}]}\n"
            ])
    }
}
