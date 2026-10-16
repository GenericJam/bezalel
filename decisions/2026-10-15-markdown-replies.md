# Replies and tool results render as Markdown (mob_markdown)

Status: accepted

## Context
Model replies and tool results are Markdown but showed as raw text.
Operator already had native Markdown views (Markwon / Foundation).

## Decision
Extract them as the plugin mob_markdown (GenericJam/mob_markdown, pinned,
unsigned, acknowledged in mob.exs), registered by mob_dev's generated
bootstraps. The look is mob_bezalel's (`UI.markdown_style/1`, `UI.block/6`
taking a node body) because it is a style concern; mob_bezalel does not
depend on the plugin. Block headers stay plain Text (`Reply.header/1`);
`rest` is the Markdown source; a table or fence first, or a header that
would unbalance the rest, keeps the whole text under a cut header. Tool
results keep whole lines (six with words, 500 chars). At most 200 open
blocks get a native view (mob has 256 component slots); older ones show
text. Copy copies the source (`"text"`). Android tables wrap in evenly
split columns; iOS draws box-drawing text fitted to the width.

## Consequences
One atom per block shown (the view id). A native rebuild is needed for
plugin changes. iOS views send link taps via the props' component_handle
because mob_dev's iOS bootstrap drops `send`.
