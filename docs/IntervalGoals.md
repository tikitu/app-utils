# IntervalGoals

The arithmetic of "how long since I last did it, and is that too long?":
an ideal interval on the calendar, how the gap since the last time stands
against it, what a history of gaps says is usual, and when to send the
three reminders of a gap. Plain values and pure functions, Foundation only;
Swift 6, macOS 14 / iOS 17.

There is no storage, no clock and no time zone in here. The consumer keeps
its own records, passes the dates in, and passes the `Calendar` (and so
the time zone) the user lives in. The notifications themselves are
[ReminderScheduling](ReminderScheduling.md).

## What it gives you

| | |
|---|---|
| `Cadence` | a length on the calendar: years, months, weeks, days, hours, minutes. `isValid`, `isLongerThanADay`, `dateComponents`, `length(from:calendar:)` |
| `GoalProgress` | the gap as a ratio of a reference, against a target band: `ratio`, `target`, `position`, `pressure` |
| `GapHistory` | from past events: the `usual` gap (median of the last 10, once there are 3) and the `longest` |
| `ReminderSchedule` | `reminders(every:preferring:since:calendar:)`: a gap's three reminders |
| `Reminder`, `Reminder.Stage` | one reminder: its stage (95%, 100%, 105%), when that is reached and when to send it |
| `ReminderTime`, `ReminderTimes` | the convenient times (8:30, 12:30, 18:30) and which of them are preferred |

## The model

A **gap** is the time since something was last done. Every goal reads it
the same way: the gap as a **ratio** of a **reference** gap, against a
**target band**, where the goal wants that ratio to be when it is next
done. Only the reference and the band differ.

```swift
import IntervalGoals

// "Water the trees every 10 days", last done on the 1st.
let progress = GoalProgress(
    since: lastWatered, at: now, reference: Cadence(days: 10), calendar: calendar,
    target: GoalProgress.aroundReference)
progress?.ratio     // 0.3 on the 4th
progress?.position  // .short, .onTarget or .long
```

The reference is either a `Cadence`, added on the calendar from the last
time, or a measured duration such as `GapHistory.usual`. Three bands are
provided; any `ClosedRange<Double>` works:

| Band | Range | Reads as |
|---|---|---|
| `aroundReference` | 0.9…1.1 | on time, give or take: early and late are both off |
| `withinReference` | 0…1 | no later than the reference; early is never wrong |
| `beyondReference` | 1…∞ | no sooner than the reference |

So an app's goals map onto pairs: an ideal interval is a cadence with
`aroundReference`; "check at least every 2 days" a cadence with
`withinReference`; "more often than I usually do" the usual gap with
`withinReference`, and "less often" the usual gap with `beyondReference`.
The app keeps its own goal type and chooses the pair.

`pressure` ranks what needs attention: the ratio over the band's far end,
so 1 at the end and above 1 past it, and 0 for a band with no far end,
which asks nothing however long the gap.

`GapHistory(occurrences:)` takes event dates in any order. `usual` is the
median of the most recent 10 gaps, `nil` until there are 3: a median so
one odd gap does not move it, the recent ones so old habits fade. It
follows habits, so a slow drift becomes the new usual. `longest` is over
all completed gaps; the open one is not in it.

## Reminders

`ReminderSchedule.reminders(every:preferring:since:calendar:)` gives three
reminders per gap, as it reaches 95% (`approaching`), 100% (`due`) and
105% (`overdue`) of the cadence. They are measured from `since`, so an
event starts a fresh set: an event at 102% means 105% is never reached,
and the new set does not contain it. Nothing special does that; schedule
from the new last time and reconcile (ReminderScheduling).

A cadence of a day or less is reminded at the exact moments. A longer one
(`isLongerThanADay`) moves each reminder to a convenient time,
`ReminderTime`: 8:30, 12:30 or 18:30, local to the calendar.

- **due** goes to the preferred time nearest the moment 100% is reached;
- **approaching** to the nearest time *before* that, **overdue** to the
  nearest *after* it: among the preferred times while the stages are a
  day or more apart (5% of the cadence ≥ 24 h, cadences of about 20 days
  and up), and among all three once they are closer. A weekly reminder
  preferring mornings is approaching Sunday 18:30, due Monday 8:30,
  overdue Tuesday 8:30, rather than three mornings in a row.
- A moment exactly halfway between two times goes to the earlier one:
  with all three preferred, 01:30, 10:30 and 15:30 are the switch points;
  with only one, the time twelve hours from it.

The three are always in stage order and at distinct instants (tested
every hour of the day, across both clock changes). Moving to a
convenient time can move a reminder by up to half a day, more for a lone
preference. `reached` keeps the exact moment, for display.

`ReminderTimes` holds which times are preferred; `all` means "whichever is
nearest", and an empty set is read as `all`. It is a flag per time so
storage can keep a column each.

## Calendar arithmetic

Why a `Cadence` and not `DateComponents`, and the traps either way. Tested
with `Calendar.date(byAdding:to:)`:

| Components | Added | Problem |
|---|---|---|
| `weekday: 2` | +48 h | read as "2 days"; it means "Monday" |
| `quarter: 1` | +0 h | ignored |
| empty | +0 h | zero length |
| `month: 1, day: -31` | −72 h | ends before it starts |

A valid `Cadence` (nothing negative, something positive) always adds to a
positive interval, which keeps the ratio defined. The rest is how the
calendar is:

- **Months differ in length.** Jan 31 + 1 month is Feb 28, so Feb 28 is
  exactly on time.
- **Month addition is not additive.** Jan 31 + 2 months is Mar 31, not
  Mar 28. Always add the whole cadence to the last time; never step.
- **A day is not 24 hours.** `days: 1` across a clock change is 23 or
  25 hours; `hours: 24` is 24. A daily cadence stays at the same time of
  day. `isLongerThanADay` is a property of the fields, so `days: 1` is
  never longer than a day and `hours: 25` always is.
- **Compute in Swift.** SQLite's date arithmetic disagrees with
  Foundation's (Jan 31 `+1 months` is Mar 3 there).
- **The calendar is the user's.** The same instants give different
  reminder times in another time zone; pass the calendar in, and
  reschedule when it changes.

"Every Monday" is a fixed calendar schedule, not a cadence; this library
does not model it.

## Mapping storage onto the values

The library's types have no storage of their own. Keep columns in your
own record and convert at the edge:

```swift
// One column per field: an absent cadence is all of them NULL.
struct CadenceColumns {
    var years, months, weeks, days, hours, minutes: Int

    var cadence: Cadence {
        Cadence(years: years, months: months, weeks: weeks, days: days,
                hours: hours, minutes: minutes)
    }
}
```

- Give the columns no defaults, so a missing cadence cannot decode as a
  zero one, and refuse invalid ones (`CHECK`) with the same rule as
  `isValid`.
- Store `ReminderTimes` as three booleans, and refuse all three false.
- `GapHistory` is computed from the event dates; compute it where the
  events are fetched rather than in a view.
- `Reminder.Stage`'s raw values are stable; they make good identifier
  parts (ReminderScheduling's `stage(_:in:)`).
