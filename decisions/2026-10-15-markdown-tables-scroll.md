# Markdown tables scroll sideways; 120 native views

Status: accepted. Supersedes the table layout and the 200-view budget in
`2026-10-15-markdown-replies.md`.

## Context
Squeezed to the phone's width, a wide table (five wordy columns) broke its
cells into a few letters per line on iOS and into tall evenly split cells on
Android. Kevin asked for tables to scroll sideways instead. Separately,
review found the 200-view budget too high: mob gives a frame's new
component views their slots before the previous frame's leave theirs
(`Mob.Screen.Server` expands, then reconciles), so Expand all in a long
study could ask for the old and the new views at once and pass mob's 256
slots, leaving the newest blocks empty.

## Decision
mob_markdown (075ef61) cuts the text at its tables. Prose wraps to the
view's width; each table sits at its natural width (a column grows to its
widest cell up to 32 code columns, then wraps; on Android every column is
as wide as the widest, as Markwon splits evenly) in a horizontal scroller of
its own, at least the view's width on Android. A table narrower than the
view doesn't scroll. iOS tables are measured in points, so Hebrew cells line
up, with right-to-left cells in bidi isolates. The chat keeps at most 120
open blocks in native views, two frames' worth under 256.

## Consequences
Selection runs within one block of prose or one table, not across them
(Copy on the block still copies the whole Markdown source). Checked on the
Android emulator and the iOS simulator: horizontal swipes scroll a table,
vertical swipes starting on it scroll the chat, rotation re-lays out. The
'Formatting for a phone' prompt is unchanged.
