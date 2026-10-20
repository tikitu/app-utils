# CloudKitSyncConfiguration

Two guards for an app that syncs through CloudKit, both checked before
anything touches CloudKit or the sync state on disk. No dependencies;
Swift 6, macOS 14 / iOS 17.

Written for apps that sync with SQLiteData's `SyncEngine`, but only
`CloudKitEnvironment.Check` knows that: it deletes SQLiteData's metadatabase,
by SQLiteData's name for it. The build side (which entitlements a build gets,
and setting the `Info.plist` keys from them) is app-tooling's
`sync-configuration` pattern:
<https://github.com/tikitu/app-tooling/tree/main/patterns/sync-configuration>.

## What it gives you

| | |
|---|---|
| `SyncConfiguration(infoPlistKey:)` | `isEnabled`: the build declares sync (`<App>SyncEnabled` is `true`) and is not a simulator |
| `CloudKitEnvironment` | `.development`, `.production`, spelled as the entitlement spells them |
| `CloudKitEnvironment.Check` | `prepare(databaseURL:sync:)`: does the sync state on disk belong to this build's environment? Resets it for the move from Development to Production; otherwise refuses |

## SyncConfiguration

`CKContainer(identifier:)` **traps** for a container the app is not entitled
to: a crash, not an error, so no `catch` helps. Whatever gives a build the
iCloud entitlement also sets `<App>SyncEnabled` in its `Info.plist`, and the
app asks `isEnabled` before making anything CloudKit. A missing key is
`false`. A simulator is always `false`, though its `Info.plist` says `true`:
no profile grants a simulator build the container.

```swift
let sync = SyncConfiguration(infoPlistKey: "MyAppSyncEnabled")
guard sync.isEnabled else { return .unavailable }
let engine = try SyncEngine(for: database, tables: …, containerIdentifier: …)
```

Gate **every** CloudKit call on it, not only the sync engine: a
`CKContainer` made for diagnostics traps just the same.

## CloudKitEnvironment.Check

SQLiteData keeps the sync state in a metadatabase beside the database, named
for the container but not the environment. A build that moves from
Development to Production restores Development's state, counts every table as
already seen, and never uploads the rows that exist: Production fills only
with later edits, and nothing says so.

So a marker file beside the metadatabase names the environment its state
belongs to. Before opening the database:

```swift
let environment = CloudKitEnvironment.Check(
    infoPlistKey: "MyAppCloudKitEnvironment",
    containerIdentifier: "iCloud.com.example.MyApp",
    unmarkedMetadatabase: .development,
    loggerSubsystem: "com.example.MyApp")
let refusal = environment.prepare(databaseURL: databaseURL, sync: sync)
// open the database; start the sync engine only if `refusal` is nil
```

| State on disk | Build | Result |
|---|---|---|
| no metadatabase, no marker | either | marker written |
| marker equals build | either | nothing |
| Development | Production | **metadatabase deleted**, Production marker written: every row uploads |
| Production | Development | refused, nothing deleted |
| unknown marker, or the build declares no environment | either | refused |
| metadatabase, no marker | either | as if the marker said `unmarkedMetadatabase` |

**`unmarkedMetadatabase` is the app's history**, and there is no default.
An app that synced only against Development before it had the marker says
`.development`, so its move to Production re-uploads every row. An app that
already synced against Production says `.production`, so its state is kept.
Wrong towards Development, a Production build re-uploads everything into a
database that has it; wrong towards Production, it keeps Development's state
and uploads only later edits.

The database itself is never touched. The metadatabase is deleted before the
marker is written, so a move interrupted between the two looks like a fresh
start next time. A build whose `sync.isEnabled` is false reads, writes and
deletes nothing. `prepare` never throws: a failure refuses sync, and the
database still opens.

`<App>CloudKitEnvironment` is set from the entitlement by the build (app-tooling's
`stamp-sync-configuration.sh`), never typed a second time.

The metadatabase's name is SQLiteData's (`.<database>.metadata-<container>.sqlite`,
plus `-wal` and `-shm`), checked against sqlite-data 164bb5f. SQLiteData
does not make it public; a test pins it here, and if SQLiteData renames it
the reset deletes nothing.
