# Sibling deps are GitHub refs pinned to commits
- Date: 2026-10-15
- Status: accepted

## Context
rho, mob_secure_store and mob_bezalel are developed alongside Bezalel and are
not on Hex (mob_bezalel never will be). Path deps made the public repo
unbuildable from a fresh clone.

## Decision
`sibling/3` in mix.exs: `github:` + full commit SHA by default;
`BEZALEL_LOCAL_DEPS=1` switches to the sibling checkouts for development.
Bump the SHA once a sibling change is pushed.

## Consequences
A fresh clone builds. A sibling change lands in two steps (push the sibling,
bump the pin). rho and mob_secure_store move to Hex versions when released.
