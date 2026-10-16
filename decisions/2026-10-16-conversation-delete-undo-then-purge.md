# A deleted conversation is marked, then purged when its Undo is gone
- Date: 2026-10-16
- Status: accepted

## Context
Kevin asked for a way to delete a conversation from the Conversations tab.
Study's message delete offers Undo for four seconds in a toast, so a
conversation's delete should too, and Undo should put it back exactly: its
place on the shelf, its messages, its pictures. A conversation owns more
than its row: its rho session file, and per session id the picture cache
(`<data dir>/images/<session id>/`), rho's spilled tool output
(`<data dir>/artifacts/<session id>/`) and its todo list
(`<data dir>/todos/<session id>.json`).

Three ways to keep Undo possible:
1. Keep the deletion in the screen and only delete when the toast ends. If
   the app is killed meanwhile the conversation comes back: the user's
   delete is lost.
2. Move the files to a trash directory and delete the row, putting both
   back on Undo. More moving parts, and the row's id and timestamps must
   be re-inserted as they were.
3. Mark the row deleted, leave the files where they are, purge when the
   Undo is gone.

## Decision
Option 3. `conversations.deleted_at` (migration `ConversationDeletedAt`)
marks a deleted conversation; every read of the shelf
(`Library.list_conversations`, `get_conversation`, `latest_conversation`,
`conversation_count`) and the message count's update skip it, so writes to
it (a scripted reply landing late) do nothing. `session_path_by_id` (the
picture decoder's lookup) still finds it until the purge, so a picture
being made when it was deleted isn't cached as unreadable for its Undo.
`Library.undelete/1` clears the mark; the delete didn't touch
`updated_at`, so the row is back in its place. `Library.purge/1` removes the
session file, the per-session files above, then the row (files first: a
purge cut short leaves the row, and the next start finishes it).

The screen purges when the Undo window ends: a `{:purge, deleted}` message
sent `Helpers.toast_ms/0` after the delete, independent of the toast (a
later toast replacing it, or switching conversations, ends the Undo
early; the data waits the full four seconds anyway). The purge also takes
the toast down if it's still up, so an Undo can never land after its
purge. `deleted_at` is the delete's token: a purge or Undo for an earlier
delete of the same conversation (deleted, put back, deleted again) does
nothing. `AppScreen.mount` purges whatever is still marked
(`Library.purge_deleted/0`): an Undo offered when the app closed is gone,
so the delete stands.

Edge cases:
- **A reply streaming in it** is stopped, not refused: the user asked to
  delete it, and making them find the stop button in another tab first is
  friction for nothing. `Study.let_go/2` does what Stop does: stops the
  loop (`Agent.stop`; while the model streams it writes what streamed
  before it answers; while tools run it answers at once and writes their
  results when they finish, so their `agent_end` is waited for, up to two
  seconds, before the loop is shut), recounts the shelf row, adds the
  messages sent meanwhile that the loop hadn't taken in as questions,
  releases the loop, drops the stream, and makes the message deletes and
  undos that were waiting for that reply. Undo then brings the
  conversation back as the chat showed it. The loop must be gone before
  the purge removes its session, or its next append would write the file
  again. A tool slower than the wait is cut off; the session's next resume
  closes its open tool call.
- **The open conversation**: Study opens the latest one left; with none
  left, a new empty study (not the Exodus 31 seed again, which would
  re-appear right after deleting it). The user stays on Conversations.
  Undo opens the restored one again if what replaced it is still open, and
  removes the new study made in its place if nothing was written to it, so
  the shelf is as it was.
- **A built tool from it**: `tools.conversation_id` is nilified by its
  foreign key at the purge; a tool saved after the purge (a build started
  from the conversation) is saved without it (`Library.create_tool/1`).
- **A Workshop panel** can't be open while the Conversations tab is shown
  (switching tabs closes it); an Undo tapped from a panel reopens the
  conversation and the panel.

## Consequences
- The per-session paths under rho's data dir are rho's layout, read here
  rather than through a rho API (rho has no "forget a session" call yet).
  Only session ids made of letters, digits, `-` and `_` (rho's UUIDs) are
  turned into paths; rho keeps those as they are. Bead `bezalel-sa6` asks
  rho for the call.
- A picture the screen was still decoding for the conversation when it was
  deleted can land in the cache after the purge (the decode runs in a
  task). Small and rare; not swept.
- A tool task the stopped loop had started (rho's tool runner doesn't link
  them) that writes rho's todo list after the purge would leave that file.
  Bezalel's study tools only read.
- While tools run, the delete waits for the loop's end on the screen
  process (up to two seconds): the screen doesn't repaint meanwhile. The
  loop events it skips past are dropped, except the messages the loop took
  in, which are taken off the unsent ones so they aren't added twice.
