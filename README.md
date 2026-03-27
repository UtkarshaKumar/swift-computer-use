# Semantic Display Daemon

> macOS OS extension for real-time semantic computer use by AI agents

**Created:** 2026-03-28
**Status:** Active

## Overview

AI agents doing computer use today are stuck in a slow loop: take screenshot → send to LLM → get coordinates → click → repeat. This is 2-5 seconds per action, coordinate-based (imprecise), and stateless (no memory between calls).

The Semantic Display Daemon (SDD) replaces this with a continuous semantic layer — a thin macOS daemon that exposes a live structured world model of the screen and accepts deterministic element-based actions. Agents subscribe to the world model stream and execute actions via accessibility API handles, not pixel coordinates.

Architecture follows a two-brain model:
- **Fast brain** (local, <50ms): handles navigation, clicks, typing, standard UI patterns
- **Slow brain** (cloud LLM, 500ms-2s): handles reasoning, content decisions, ambiguous state

## Goals

- <50ms action latency on the fast path
- Element-based execution (zero coordinate guessing)
- Continuous world model with diff-based updates (no full-screen reprocessing)
- System-wide coverage: browser + native apps + file dialogs + Finder
- MCP-compatible control interface (works with Claude Code and any MCP-compatible agent)
- Intelligence baked in (Option A) — users bring API key, SDD routes to slow brain

## Documents

| File | Contents |
|------|----------|
| `01-problem-solution.md` | Full problem definition and solution space |
| `02-architecture.md` | System architecture, component specs, ADRs |
| `03-monetization.md` | Business model, pricing, go-to-market |
| `04-use-cases-evals.md` | Use cases + EVAL suite with performance targets |

## Notes

Built entirely on public macOS APIs — no private frameworks, no special entitlements beyond standard Accessibility access (same as screen readers).
