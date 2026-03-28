# Semantic Display Daemon — Agent Instructions

> Read this file before making any changes to this project.

## Project Summary

**What it is:** macOS OS extension for real-time semantic computer use by AI agents
**Status:** Active
**Created:** 2026-03-28

## Objective

Build a thin macOS daemon (Semantic Display Daemon / SDD) that gives AI agents continuous, structured understanding of the screen and deterministic action execution — replacing screenshot-based computer use with a real-time semantic layer.

Done looks like: a daemon that any agent can connect to via MCP or gRPC, subscribe to a world model stream, and execute precise UI actions system-wide with <50ms latency on the fast path.

## Key Files

```
Semantic Display Daemon/
├── claude.md                  ← this file
├── README.md                  ← project overview
├── 01-problem-solution.md     ← full problem + solution space definition
├── 02-architecture.md         ← system architecture + component specs
├── 03-monetization.md         ← business model + pricing strategy
├── 04-use-cases-evals.md      ← use cases + EVAL definitions with perf targets
└── (code/ when implementation begins)
```

## Workflow

1. Read `01-problem-solution.md` for context before any change
2. Design decisions go into `02-architecture.md`
3. Use cases and perf targets live in `04-use-cases-evals.md` — these are the EVALs
4. Never modify eval perf targets without explicit user confirmation

## Rules

- Enter plan mode before any implementation work
- EVALs in `04-use-cases-evals.md` are ground truth — do not soften targets
- Architecture decisions require ADR documentation in `02-architecture.md`
- Intelligence (slow brain) lives inside the daemon — not externalized (Option A decision)

## Common Mistakes to Avoid

- Do not conflate the SDD (dumb sensor/actuator) with the brain layer — SDD is infrastructure
- Do not use coordinate-based clicking for native macOS apps that have AX coverage — always AX element handles (ADR-004). Coordinate clicking is permitted only for canvas regions and vision-path web content (ADR-008)
- Do not poll AXUIElement — use AXObserver event subscriptions
- Do not use CGWindowListCreateImage or CGDisplayCreateImage — these APIs are removed in macOS 15. Use ScreenCaptureKit for all screen capture
- SlowBrain must try AX context first before falling back to vision — never skip AX analysis (ADR-008)
