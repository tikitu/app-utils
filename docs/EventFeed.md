# EventFeed

An app's events, published as an append-only SQLite file that another app
reads. Raw sqlite3, CryptoKit and Foundation only; no package
dependencies; Swift 6, macOS 14 / iOS 17.

The feeding app projects its own store into *events in effect* and hands
them to a `FeedWriter`, which appends what the file lacks. A reader (Time
Tracker, say) opens the file read-only, reads all of it, and folds the
retractions. Nothing in the file is ever updated or deleted, and every
row's id is derived from its content, so the same source state written on
two devices is the same bytes.

## What it gives you

| | |
|---|---|
| `FeedEvent` | one row: `kind`, `subject`, `occurredAt`, `recordedAt`, `zone`, `payload`, or a retraction's `retracts`; its id derived (Identity) |
| `FeedWriter` | opens or creates `<base>/Feeds/<bundle>.sqlite`; `add(inEffect:)`, `retract(removed:recordedAt:zone:)`, `restore(_:recordedAt:zone:)`, `replace(removed:with:recordedAt:zone:)`, `name(subject:name:since:)`, `post()`, `differences(inEffect:)` |
| `FeedReader` | opens a feed read-only: `meta`, `events()`, `subjects()`; refuses a newer schema |
| `Retractions.retracted(_:)` | the fold: the ids no longer in effect |
| `FeedConventions` | the directory (`Feeds`), the file name, `files(in:)`, the notification `org.logophile.feed.changed` and `post()` |
| `stableIdentifier(from:)` | SHA-256 of a key to a v4-shaped UUID, as Time Tracker's |

```swift
let writer = try FeedWriter(base: groupContainer, source: "whenDidYouLast",
                            bundle: Bundle.main.bundleIdentifier!)
try writer.add(inEffect: store.eventsInEffect.map(\.feedEvent))
try writer.name(subject: activity.id, name: activity.name, since: activity.editedAt)
writer.post()

// A retime, before the store's write: retract the old row, add the new one
// (and restore it, if an earlier edit had retracted it).
try writer.replace(removed: old.feedEvent.id, with: new.feedEvent, recordedAt: now, zone: nil)

// A delete, and its undo.
try writer.retract(removed: event.feedEvent.id, recordedAt: now, zone: nil)
try writer.restore(event.feedEvent.id, recordedAt: now, zone: nil)
```

`base` is any directory: an App Group container
(`FileManager.containerURL(forSecurityApplicationGroupIdentifier:)`) for a
real feed, the scratch directory for a scratch run.

## What it never does

- **It never retracts by set difference.** There is no API that compares
  the feed with the source and retracts what is missing: a source that is
  empty (a reinstall) or partial (a bug) would become a mass retraction.
  A retraction is appended only for an id the caller's own write path
  reports as removed. A projection bug can therefore fail to add, never
  remove.
- **`differences(inEffect:)` reports, and changes nothing.** It counts
  feed rows in effect with no supplied event (`onlyInFeed`: a removal
  whose retraction never ran), supplied events with no row
  (`onlySupplied`) and supplied events whose row is retracted
  (`suppliedButRetracted`), for a diagnostic the app shows. Retracting
  any of them is the owner's explicit act.
- **No row is ever updated or deleted**, and `feed_meta` is written once,
  when the file is created. There is no API that edits, replaces or
  removes a row. A changed source row is a new feed row and a retraction
  of the old.
- **No column carries import-specific, device-specific or
  time-of-noticing data.** Every column of an event is a value the
  source stored and froze. `recordedAt` is the source's own; for a
  removal the source does not record, it is the moment of the removal on
  the one device that made it.
- **It never opens a newer schema, or another source's file, to replace
  it.** Only damage is replaced (Opening).
- **The reader never writes.** It opens with `SQLITE_OPEN_READONLY`.

## Identity

An event's id is `stableIdentifier(from:)` over its key, a JSON array in
this fixed order and encoding:

```
[source, table, source row id, kind, subject, occurred_at, recorded_at, zone, payload]
["testSource","events","A","thing.done","subject-1","2026-10-31 17:05:52.123",
 "2026-10-31 17:06:52.123","Europe/Amsterdam",{"k":"v"}]
→ 6C428802-35C6-43EB-A6A5-A3D760806B11
```

The design's `<source>/<table>/<row id>/<frozen columns>`, written as
JSON so that no value containing a `/` can make two keys equal. The JSON
is the library's own canonical form, not `JSONEncoder`'s: no whitespace,
object keys in UTF-8 byte order, only `"`, `\` and control characters
escaped (`\u00XX`), `null` for an absent subject or zone, timestamps in
the feed's text. Changing any frozen column, including a payload value or
the zone, changes the id. The test pins the id above, checked outside
Swift, so a change to the encoding fails a test instead of silently
re-identifying every feed.

- A retraction's id is `stableIdentifier("<source>/retracts/<retracted
  feed id>")`, whatever its `recordedAt`. So every id has one *chain*:
  its retraction, that retraction's retraction, and so on, and it is in
  effect exactly when the feed holds an even number of links. A source
  name has no `/` (the writer checks).
- A name version's id is the same over `[source, "subject", subject,
  since, name]`.

**Only frozen values go in.** A column the source edits in place is
either part of identity (an edit is then a retraction plus a new row) or
not in the feed at all.

## Time

Timestamps are text, `YYYY-MM-DD HH:MM:SS.SSS`, UTC, milliseconds: the
text SQLiteData writes for a `Date`. The library makes it from whole
milliseconds, **rounded to the nearest**, with integer arithmetic.
Foundation's ISO-8601 format style, which SQLiteData uses, truncates the
binary fraction instead, and so re-encodes 496 of the 1000 millisecond
values one lower when a date read back from its own text is written again
(`…02.999` becomes `…02.998`). Rounding makes a date read back from a
store's text encode to exactly that text.

So **pass dates as the source stores them**: read back from the store,
not an in-memory `Date()` with sub-millisecond precision that the store
truncated on its way in. An in-memory value can round to the millisecond
above the stored one, derive a different id, and the next projection from
the store would then add a second row. `FeedEvent` holds its dates at the
stored millisecond.

`zone` is a `TimeZone.identifier`, or `nil` when the source stores none;
it is never invented.

## The file

`<base>/Feeds/<bundle id>.sqlite`, one per feeding app, named by the
writer's bundle id so two installs under different bundle ids never share
one. WAL, so the writer appends while a reader reads. Schema 1:

```sql
CREATE TABLE feed_events (
  id          TEXT PRIMARY KEY NOT NULL,  -- uppercase uuidString (Identity)
  kind        TEXT NOT NULL,              -- the source's vocabulary, or 'retraction'
  subject     TEXT,                       -- the source's stable id of the thing
  occurred_at TEXT,                       -- Time; NULL exactly on a retraction
  recorded_at TEXT NOT NULL,              -- when the source wrote it down
  zone        TEXT,                       -- TimeZone.identifier, or NULL
  retracts    TEXT,                       -- on a retraction, the feed id it retracts
  payload     TEXT NOT NULL DEFAULT '{}', -- flat JSON object of strings, canonical form
  CHECK ((retracts IS NULL) = (kind != 'retraction')),
  CHECK ((retracts IS NULL) = (occurred_at IS NOT NULL))
) STRICT;

CREATE TABLE feed_subjects (            -- append-only name versions
  id      TEXT PRIMARY KEY NOT NULL,
  subject TEXT NOT NULL,
  name    TEXT NOT NULL,
  since   TEXT NOT NULL                 -- the source's own edit time
) STRICT;

CREATE TABLE feed_meta (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) STRICT;
-- schema = '1', source, bundle, writer = 'app-utils EventFeed 0.6.0'
```

The latest name of a subject is the version with the newest `since`, ties
broken by `id`. The implicit `rowid` is append order: a hint for a reader,
never a watermark. Read the whole feed each time and insert with
`ON CONFLICT DO NOTHING`. `FeedConventions.writer` names the library
version and is bumped with the tag.

**Every change to the DDL bumps `schema`**, even one that only adds an
index, and so does a change of any statement's text. A writer compares
the schema verbatim, and to an older writer a file with anything else in
it is damage, to be deleted and recreated (Opening). An older reader then
refuses the file by its number instead of misreading it.

### Opening

`FeedWriter` creates the file, the `Feeds` directory, the tables and
`feed_meta` in one transaction. On an existing file it runs
`PRAGMA quick_check` and compares the schema with the above, verbatim.

- A file that is not a database, fails the check, or has any other schema
  is **deleted and created again** (`recreated` says so): the feed is a
  projection, and the next `add(inEffect:)` rebuilds it. What a rebuild
  cannot bring back is a retraction the source does not record (a hard
  delete); the reader still has it.
- A file whose `schema` is newer throws `newerSchema(found:known:)`, and
  one made for another `source` or `bundle` throws `belongsToAnother`.
  Neither is touched.
- A file that cannot be opened *now* throws and is left alone:
  `SQLITE_BUSY` (another process writing for more than five seconds),
  `SQLITE_CANTOPEN` or a failed open (permissions, or data protection on
  a locked device). None of these is damage, and deleting would lose the
  retractions in a healthy feed.

`FeedReader` reads `feed_meta` first and throws `newerSchema` naming both
numbers ("feed schema 2 is newer than this library knows (1)"). Opening a
WAL file read-only needs its `-shm` to exist or the directory to be
writable, which a group container is.

## Retracting and restoring

Every correction is the caller's report of its own write. The writer
appends at the end of the id's chain (Identity), so each call does what
it says however often the id has gone back and forth:

| Source write | Call | Appends |
|---|---|---|
| delete, or the old row of an edit | `retract(removed:…)` | the next link if the event is in effect; nothing if it is already retracted |
| undo of a delete (same row, same content, so the same feed id) | `restore(_:…)` | the next link if the event is retracted; nothing if it is in effect or was never retracted |
| edit of a frozen column (a retime) | `replace(removed:with:…)` | retracts the old, adds the new, restores the new if an earlier edit retracted it; one transaction |

Delete, undo, delete is three rows and leaves the event retracted; a
retime A → B → A leaves A in effect. `add(inEffect:)` never restores: a
row the feed has, in effect or not, is left as it is, so a stale source
cannot bring back what was removed. The diagnostic's remedies are these
same calls: `retract` an `onlyInFeed` id, `restore` a
`suppliedButRetracted` one, each only when the owner says so.

**One limit.** `restore` sees only this feed. A delete made on another
device wrote its retraction into that device's feed; undoing it here finds
no retraction, appends nothing, and the reader still folds the other
device's retraction. The undo has to happen on the device that deleted.

## The fold

`Retractions.retracted(_:)` is the event-log pattern's and Tree Care's
function: a row is in effect unless a retraction in effect names it. It
needs no order, so a retraction that arrives before its target (sync
order is not append order) hides the target from the start. A retraction
of a retraction restores; a third level retracts again. An overload
takes `FeedEvent`s.

## Trying it

`scripts/event-feed-demo.sh` writes a feed (an add, a retime there
and back with `replace`, a name), prints what `FeedReader` reads, then reads
the file with `sqlite3 -readonly`, not the library.
