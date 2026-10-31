# ReminderScheduling

Keeps the system's pending local notifications equal to the reminders an
app wants, and snoozes one. UserNotifications and Foundation only; Swift 6,
macOS 14 / iOS 17.

The app builds the requests: their text, category, actions, sound and
interruption level are its own. This library is the bookkeeping around
them: an identifier scheme that groups a gap's notifications into a
*cycle*, a reconcile that removes what is no longer wanted and adds what
is, within the system's 64 pending, and a snooze that survives
reconciling while its gap is open. The schedule itself (when each
reminder is due) can come from [IntervalGoals](IntervalGoals.md) or
anywhere else.

## What it gives you

| | |
|---|---|
| `ReminderIdentifiers` | the identifier scheme under one prefix: `cycle(_:since:)`, `stage(_:in:)`, `snoozed(_:)`, `isStale`, `isClosed`; and `reconcile` and `snooze` |
| `WantedNotification` | a request the app wants pending and its fire date; `init(identifier:content:fireDate:calendar:)` builds a one-off calendar trigger |
| `Reconciliation` | what a reconcile did: `scheduled`, `removedPending`, `removedDelivered`, `failures` |
| `ReminderNotificationCenter` | the center calls reconciling makes; `UNUserNotificationCenter` conforms, and a test fake can |

## Identifiers

```
<prefix><subject>/<start of the gap, epoch seconds>/<stage>
reminder/6F1C…/1790000000/due
reminder/6F1C…/1790000000/snoozed
```

The **subject** is what the reminder is about (an id); the **start** is
when the gap began, the last time it was done. Everything up to the last
`/` is the **cycle**: every notification about one gap shares it. A gap
that closes — the thing was done — leaves a cycle the app no longer
reports open, and its notifications go, pending and delivered, snoozes
included. Notifications without the prefix are never touched, so other
kinds of notification can live beside these. Two kinds in one app need
prefixes where neither starts the other (`soak/` and `check/`, not
`reminder/` and `reminder/check/`): reconciling under `reminder/` would
remove every `reminder/check/` notification as stale.

Stages are the app's strings (IntervalGoals' `Reminder.Stage.rawValue`
works, whatever its `ReminderStages` shares) and must not contain `/`. A snooze has `snoozed` in place of the
stage, so snoozing again replaces it.

## Reconciling

Run it on every change to what the app wants, with all of it, rather than
adding and cancelling at each write. What is pending then follows from
the app's state whoever changed it: an edit, an undo, a sync.

```swift
import ReminderScheduling
import UserNotifications

let identifiers = ReminderIdentifiers(prefix: "reminder/")

let wanted = items.flatMap { item in
    let cycle = identifiers.cycle(item.id.uuidString, since: item.lastDone)
    return item.reminders.map { reminder in
        WantedNotification(
            identifier: ReminderIdentifiers.stage(reminder.stage.rawValue, in: cycle),
            content: content(for: reminder, of: item),  // the app's text
            fireDate: reminder.sendAt, calendar: calendar)
    }
}
let open = Set(items.map { identifiers.cycle($0.id.uuidString, since: $0.lastDone) })
let result = await identifiers.reconcile(
    wanted, openCycles: open, in: UNUserNotificationCenter.current(), now: now)
logger.info("scheduled \(result.scheduled.count), removed \(result.removedPending.count)")
```

In order, it:

1. drops wanted notifications that fire at or before `now`: a past stage
   is not sent late;
2. keeps the soonest `limit` (default `pendingLimit`, 64, the system's
   cap; lower it to leave room for other notifications). The limit
   counts only what reconcile adds: open snoozes and other prefixes'
   notifications are pending on top of it;
3. removes pending notifications under the prefix that are not kept,
   except a snooze in an open cycle, which no schedule contains;
4. adds every kept one. Adding under an existing identifier replaces it,
   so changed text or time takes effect. A refused add is reported in
   `failures` and the rest still go;
5. removes delivered notifications under the prefix whose cycle is not
   open, so Notification Center does not keep "due" for something
   already done.

Pass every open cycle, including gaps with nothing wanted right now:
that is what keeps their snoozes and delivered notifications.

If reconciling follows a stream of changes, treat each change as a
signal to reconcile against the latest state, not as the state: with
`for await value in publisher.values`, changes published while a
reconcile is awaiting are dropped. An `AsyncStream` buffering the newest
signal does it.

## Snoozing

```swift
// In the delegate, for the Snooze action:
let content = response.notification.request.content.mutableCopy()
    as! UNMutableNotificationContent
content.body = "Snoozed — time to do it."
try await ReminderIdentifiers.snooze(
    response.notification.request, for: 5 * 60, content: content,
    in: UNUserNotificationCenter.current())
```

The same content again (or the content passed) under the cycle's snooze
identifier, with a time-interval trigger. Pass new content when the
original's body says when things happen relative to when it was sent
("due in 6 seconds"), which is wrong by the time the snooze arrives.

## Concurrency

`reconcile` and `snooze` are `nonisolated(nonsending)`: they run on the
caller's actor, so a `UNNotificationRequest`, which is not `Sendable`, can
come from a main-actor notification delegate without crossing an
isolation boundary. On iOS, answer a notification action in the
completion-handler form of `userNotificationCenter(_:didReceive:…)`, and
call the handler on the main actor: the `async` form has crashed after
the work was done, because the handler asserts the main thread.

## Testing

Conform a class to `ReminderNotificationCenter` that keeps pending
requests in a dictionary and delivered identifiers in an array; the
package's own tests do (`Tests/ReminderSchedulingTests`). The system
center needs an app bundle, so tests never touch it.
