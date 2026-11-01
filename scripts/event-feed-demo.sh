#!/bin/sh
# Writes a demo feed with EventFeed (a retime: three rows), then reads it
# back read-only with the sqlite3 command line tool, not the library.
set -eu
dir=$(mktemp -d)
EVENT_FEED_DEMO_DIR="$dir" swift test --filter 'EventFeedTests.demoFeed' 2>&1 \
  | grep 'FeedReader' || { echo "demo test did not run" >&2; exit 1; }
feed="$dir/Feeds/org.example.Demo.sqlite"
test -s "$feed" || { echo "no feed at $feed" >&2; exit 1; }
for table in feed_meta feed_events feed_subjects; do
  echo "== $table"
  sqlite3 -readonly -header -column "$feed" "SELECT * FROM $table ORDER BY rowid"
done
echo "== journal_mode: $(sqlite3 -readonly "$feed" 'PRAGMA journal_mode')"
