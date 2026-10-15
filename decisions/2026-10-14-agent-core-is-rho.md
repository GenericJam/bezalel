# The agent core is rho, extracted from Operator; no Rust, no MCP
- Date: 2026-10-14
- Status: accepted

## Context
Bezalel needed a real agent loop (sessions, tools, compaction, sign-in) on the
phone. Operator already ran a pi-agent-core port in Elixir on device. omp's
Rust core and the studybible-mcp server (Python, MCP) were the alternatives.

## Decision
Extract Operator's core into rho (GenericJam/rho), used by Operator and
Bezalel. Port studybible-mcp's query layer to Elixir and call the tools as rho
tool modules: no MCP layer, no Python on the phone. No Rust: the loop waits on
the network, and a Rust core would need a precompiled NIF per platform.

## Consequences
One loop implementation for both apps. studybible-mcp's data build runs on the
Mac (data/build.sh); the phone only reads SQLite packs. See PLAN.md and
docs/study_tools.md.
