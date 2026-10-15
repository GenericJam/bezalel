# A conversation's messages are remembered per process, keyed by the file's stat
- Date: 2026-10-15
- Status: accepted

## Context
Every store or delete read and decoded the whole session file two or three
times (`Library.messages`, `touch`, `recount`), then the chat's reload read
it again. On a long conversation with pictures that is slow on the phone.
Passing the parsed entries from the write to the reload doesn't work alone:
the screen reloads through `Library.messages/1` in places that don't hold
them, and the live agent's loop writes the file from another process
without telling Bezalel.

## Decision
`Bezalel.Library` keeps one memo per process (the screen's): the last
session's messages (not its entries, so pictures' base64 isn't held), keyed
by the path and the file's size, mtime and inode taken before the read. A
session only grows, so any write, the loop's included, changes the size and
the next read decodes the file again. Bezalel's own writes compute the new
branch from the one they read plus what they appended, and remember its
messages: a store or a delete reads the file once, the reload not at all.
Undo goes back to a branch it didn't read, and a write after a torn last line
can't know what reads back; both read the file again. A test counts
`Rho.Session.open/2` calls.

The one-time migration names each session `legacy-<conversation id>.jsonl`,
so a run after a failed one writes over the files it left instead of
leaving orphans.

## Consequences
One process's memo holds one conversation's messages. Writing a session
without appending (rewriting it in place at the same size) would go unseen;
nothing does that (pi's format is append-only).
