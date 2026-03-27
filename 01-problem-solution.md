# Problem & Solution Space

> Canonical definition of what we're building and why. Update this before changing architecture.

---

## The Core Problem

AI agents doing computer use today collapse three distinct cognitive layers into one slow loop:

```
CURRENT:  screenshot → [500ms-2s LLM call] → coordinate → click → repeat

NEEDED:   continuous perception → world model → [fast brain | slow brain] → action → verify
```

This forces the most expensive component (LLM inference) to do the cheapest work (recognizing a button). The result is a 10-25x latency gap from what's needed for fluid UI automation.

---

## Problem Decomposition

### P1: Perception is Episodic, Not Continuous

Humans maintain a live model of what's on screen and only process what changed. Current agents rebuild their entire understanding from scratch on every call. There is no state between actions.

### P2: Actions Are Coordinate-Based, Not Element-Based

Clicking at (x=847, y=312) is a guess. If the page reflows, shifts, or animates, it misses. Element-based clicking via AXUIElement is deterministic — find the element by role/label, call `AXPress`. No coordinates involved. Current agents don't use this.

### P3: No World Model Persistence

Between calls, the agent knows nothing. It cannot track "the modal I opened two actions ago is still open" without re-deriving it from a screenshot. Every action is stateless.

### P4: The Browser/OS/Custom-Rendered Divide

| Surface | Access Method | Status in Current Agents |
|---------|--------------|--------------------------|
| Browser DOM | CDP / Playwright | Partially solved (BrowserUse, Stagehand) |
| Native macOS UI | AXUIElement | Mostly ignored |
| File dialogs | AXUIElement on native dialog | Not handled |
| Finder | AXUIElement | Not handled |
| Canvas/WebGL/Electron custom render | Vision only | Blind without screenshot |

No single agent framework bridges all four. Each requires a different tool.

### P5: File Operations Are Blind

A browser `<input type="file">` opens a native macOS dialog. Playwright cannot control it. AXUIElement can. No agent framework wires this bridge today.

### P6: No Tight Verification Loop

After clicking, the agent doesn't know if the action succeeded until the next screenshot (500ms-2s later). A synchronous verify signal (<50ms) would let the fast brain retry or escalate to slow brain immediately. Without it, errors compound silently.

### P7: Vision Models Are Trained on Natural Images, Not UIs

Current vision encoders (CLIP, ViT) are trained on faces, objects, scenes. UIs have fundamentally different structure — dense text at small sizes, grid layouts, state conveyed by subtle visual cues (focused, disabled, selected). There is no production-grade fast UI-specific encoder.

---

## The Two-Brain Model

Rooted in Kahneman's System 1 / System 2, and directly analogous to self-driving car architecture (strategic loop / tactical loop / reactive loop at different latencies).

| Dimension | Fast Brain | Slow Brain |
|-----------|-----------|------------|
| Latency target | <50ms | 500ms–2s |
| Lives where | Local process (CoreML / rule engine) | Cloud LLM endpoint |
| Invoked for | Navigation, clicks, typing, scroll, standard patterns | Content reasoning, ambiguous state, multi-step planning |
| Trigger | World model state change | Fast brain uncertainty signal OR explicit escalation |
| Failure mode | Misses edge cases, escalates | Slow, expensive |
| Examples | "Text field focused, type X" / "Submit button visible, press it" | "Is this the right file?" / "What should I enter for city?" |

Fast brain handles mechanics. Slow brain handles judgement. Slow brain should be invoked ~10-20% of the time.

---

## Solution: The Semantic Display Daemon (SDD)

A thin macOS LaunchDaemon — always running, low footprint — that acts as a **semantic display server**: instead of exposing a pixel framebuffer, it exposes a structured scene graph and accepts semantic action commands.

Analogy: X11 display server mediates between hardware and client apps. SDD mediates between the OS and agent clients.

### What It Is NOT

- Not an LLM
- Not a general automation framework
- Not a replacement for Playwright (it bridges to it)
- Not a screenshot tool
- Not an app — it's a daemon/service

### What It Does

1. **Continuous screen capture** via ScreenCaptureKit (hardware-accelerated, 30fps, change-detection filtered)
2. **AX tree subscription** via AXObserver (event-driven, not polling) — structural element data
3. **Fusion** — merges visual bounds, AX roles/labels, focus state, scroll position into one semantic scene graph
4. **World model** — persistent in-memory graph, emits diffs (not full state) on every meaningful change
5. **Action execution** — AXPress/AXSetValue/CGEvent, returns synchronous verify signal
6. **Slow brain routing** — when fast brain signals uncertainty, routes to configured LLM endpoint with world model context summary
7. **Control API** — gRPC + WebSocket on localhost, MCP server wrapper for agent integration

### What It Explicitly Does NOT Build (Deferrals)

- Cross-platform (Windows, Linux) — macOS only, Phase 1
- Custom UI encoder training — use Apple Vision framework initially
- Voice input/output
- Multi-monitor orchestration (Phase 2+)
- Remote (non-localhost) control API
- Agent loop logic — the SDD is infrastructure; agents are consumers

---

## Key Architectural Decisions (Summary)

**Option A vs B — Intelligence location:**
Intelligence (slow brain LLM routing) lives INSIDE the daemon. Users configure an API key; the daemon routes to the slow brain when needed. This is the right product decision — users get a complete solution, not components to assemble. See `03-monetization.md` for why this enables the business model.

**Why NOT coordinate-based actions:**
Coordinates are fragile. AXUIElement element handles are stable across reflows, redraws, and resolution changes. The AX API is what VoiceOver uses — it's production-hardened and Apple-supported. Coordinates are only used as last resort for custom-rendered surfaces.

**Why NOT polling AXUIElement:**
Polling is CPU-intensive and introduces latency. AXObserver provides event-driven notifications for element changes, focus shifts, window creation/destruction. This is the correct API for low-latency continuous monitoring.

---

## Competitive Landscape

| Solution | Approach | Gap |
|----------|----------|-----|
| Anthropic Computer Use | Screenshot + coordinates | Episodic, slow, imprecise |
| Google Project Mariner | Video stream + LLM | No element handles, still coordinate-based execution |
| BrowserUse | Browser DOM + LLM loop | Browser only, no system UI |
| Playwright MCP | Browser automation | Browser only |
| Skyvern | Visual + DOM | Browser only |
| OSWorld / ACI | Research framework | Not productized |
| Apple visionOS | OS-level semantic scene | macOS not exposed to 3rd parties |

**Gap:** No solution combines continuous video-stream context + accessibility-tree-based execution + fast/slow brain routing + system-wide coverage (browser + native + files) in one productized daemon.

---

*Last updated: 2026-03-28*
