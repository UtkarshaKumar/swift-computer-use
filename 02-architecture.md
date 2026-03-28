# System Architecture

> All non-obvious architectural decisions require an ADR here. Reference this before any implementation.

---

## System Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        macOS HARDWARE                           │
│   GPU framebuffer │ AX Framework │ IOKit input │ WM events      │
└──────────┬────────────────┬──────────────────────┬─────────────┘
           │                │                      │
┌──────────▼────────────────▼──────────────────────▼─────────────┐
│                  SEMANTIC DISPLAY DAEMON (SDD)                  │
│  macOS LaunchDaemon — always on, low footprint                  │
│                                                                 │
│  ┌─────────────────┐  ┌──────────────┐  ┌───────────────────┐  │
│  │ CAPTURE LAYER   │  │   AX LAYER   │  │  INPUT LAYER      │  │
│  │ ScreenCaptureKit│  │ AXObserver   │  │  CGEvent tap      │  │
│  │ 30fps, hw accel │  │ event-driven │  │  monitor + inject │  │
│  │ change-detected │  │ not polling  │  │                   │  │
│  └────────┬────────┘  └──────┬───────┘  └────────┬──────────┘  │
│           │                  │                   │             │
│  ┌────────▼──────────────────▼───────────────────▼──────────┐  │
│  │                    FUSION LAYER                           │  │
│  │  CoreML/Vision fast encoder + AX tree merger              │  │
│  │  Produces: semantic scene graph (not pixels)              │  │
│  │  Flags canvas/custom-rendered regions for slow brain      │  │
│  └─────────────────────────┬─────────────────────────────── ┘  │
│                             │                                   │
│  ┌──────────────────────────▼──────────────────────────────┐   │
│  │                     WORLD MODEL                          │   │
│  │  Persistent in-memory graph                              │   │
│  │  Elements, state, focus, scroll, app context, history    │   │
│  │  Emits diffs only — not full state per change            │   │
│  └──────────┬──────────────────────────┬────────────────── ┘   │
│             │                          │                        │
│  ┌──────────▼──────────┐  ┌────────────▼────────────────────┐  │
│  │    FAST BRAIN       │  │         SLOW BRAIN ROUTER        │  │
│  │  Rule engine +      │  │  Serializes world model context  │  │
│  │  small local model  │  │  Routes to LLM endpoint          │  │
│  │  <50ms              │  │  Returns action plan to executor │  │
│  └──────────┬──────────┘  └────────────┬────────────────────┘  │
│             │                          │                        │
│  ┌──────────▼──────────────────────────▼────────────────────┐  │
│  │                   ACTION EXECUTOR                         │  │
│  │  AXPress / AXSetValue / CGEvent / Playwright bridge       │  │
│  │  Returns synchronous verify signal (<50ms)                │  │
│  └─────────────────────────┬─────────────────────────────── ┘  │
│                             │                                   │
│  ┌──────────────────────────▼──────────────────────────────┐   │
│  │                  CONTROL API SERVER                      │   │
│  │  gRPC + WebSocket on localhost:7800                      │   │
│  │  MCP server wrapper (port 7801)                          │   │
│  │  Streams world model diffs, accepts action commands      │   │
│  └─────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                              │
              ┌───────────────┴──────────────────┐
              │                                  │
┌─────────────▼──────────────┐    ┌──────────────▼─────────────┐
│   EXTERNAL AGENT (MCP)     │    │    EXTERNAL AGENT (gRPC)   │
│   Claude Code, any MCP     │    │    Custom agent loop,      │
│   compatible agent         │    │    LangChain, CrewAI, etc. │
└────────────────────────────┘    └────────────────────────────┘
```

---

## Component Specifications

### Capture Layer
- **Technology:** `ScreenCaptureKit` (macOS 12.3+)
- **Frame rate:** 30fps capture, change-detection filtered before forwarding
- **Change detection:** Perceptual hash diff of frame regions — only forward to fusion if delta exceeds threshold
- **Performance budget:** <5ms GPU→CPU frame delivery
- **Handles:** Full screen, specific window, specific region

### AX Layer
- **Technology:** `AXObserver`, `AXUIElement` (AppKit Accessibility)
- **Mode:** Event-driven via `AXObserver` notifications — never poll
- **Events subscribed:** `AXFocusedUIElementChanged`, `AXWindowCreated`, `AXWindowMiniaturized`, `AXUIElementDestroyed`, `AXValueChanged`, `AXSelectedTextChanged`
- **Element properties captured:** role, subrole, label, value, enabled, focused, frame (bounds), children
- **Performance budget:** <5ms from OS event to AX tree update

### Fusion Layer
- **Inputs:** Screen frame (or diff) + AX tree update
- **Output:** Semantic scene graph node update
- **Vision model (Phase 1):** Apple Vision framework (`VNRecognizeTextRequest`, `VNDetectRectanglesRequest`) — fast, on-device, no network
- **Vision model (Phase 2):** Fine-tuned CoreML UI encoder — handles canvas, custom renders
- **Canvas detection:** If a region has no AX children but has visual content, flag as `canvas_region` and attach screenshot for slow brain
- **Performance budget:** <10ms fusion per AX event

### World Model
- **Data structure:** In-memory directed graph (nodes = UI elements, edges = containment/focus/z-order)
- **Persistence:** In-memory only (no disk); rebuilt on daemon restart
- **Diff emission:** Structural diff of graph on each update — only changed nodes emitted
- **History:** Rolling 100-event history for context window injection into slow brain
- **App context:** Tracks foreground app, active window, focused element at all times

### Fast Brain
- **Phase 1:** Rule engine — pattern match on world model state against action templates
  - "text field focused + type_value in task context" → `AXSetValue`
  - "button with label matching task intent visible + focused" → `AXPress`
  - "scroll needed (element below fold)" → `AXScroll`
- **Phase 2:** Small local model (CoreML, <100MB) trained on common UI interaction patterns
- **Uncertainty signal:** Confidence score; escalate to slow brain if < threshold
- **Performance budget:** <50ms end-to-end (world model update → action executed)

### Slow Brain Router
- **Trigger:** Fast brain confidence < threshold OR explicit task context requires reasoning
- **Context serialization:** World model summary (current state, task history, last N events) → compact JSON → injected as system context
- **LLM interface:** Configurable endpoint (Claude API default, BYO supported in Enterprise)
- **Response format:** Structured action plan — list of `{action, element_selector, value, verify_condition}`
- **Performance budget:** <1,500ms (network + inference)

### Action Executor
- **Primary path:** `AXUIElement` actions — `AXPress`, `AXSetValue`, `AXSetFocused`
- **Secondary path:** `CGEvent` keyboard injection (for key combos, shortcuts)
- **Tertiary path (fallback):** CGEvent mouse event at element centroid (for canvas regions only)
- **Browser path:** Playwright/CDP bridge for browser-specific operations (cookie management, network intercept, download handling)
- **File dialog path:** AX-based navigation of native `NSOpenPanel`/`NSSavePanel`
- **Verify signal:** Synchronous — waits for world model update confirming state change, timeout <50ms

### Control API
- **Protocol:** gRPC (primary) + WebSocket JSON (secondary)
- **Port:** localhost:7800 (gRPC), localhost:7801 (MCP)
- **Authentication:** Local-only by default (no network binding); optional token for multi-process setups
- **Streaming:** gRPC server-streaming for world model diffs; WebSocket for MCP resource stream

---

## ADRs (Architecture Decision Records)

### ADR-001: Intelligence Inside the Daemon (Option A)
**Context:** Should the slow brain be internal (daemon routes to LLM) or external (consumers bring their own)?
**Decision:** Internal. The daemon accepts an LLM API key at configuration time and manages routing, context serialization, and model selection internally.
**Consequences:** Creates a complete product (not just SDK). Enables SaaS pricing. We own the routing quality as a moat. Trade-off: users with existing LLM infrastructure may want BYO — offer as Enterprise option.

### ADR-002: AXObserver Over Polling
**Context:** AXUIElement can be used via polling or via AXObserver event subscriptions.
**Decision:** AXObserver event-driven exclusively. Polling is never used.
**Consequences:** Lower CPU footprint. Lower latency (OS pushes events, we don't miss changes between polls). Harder to implement correctly (observer registration per-app, per-window). Polling is prohibited in the codebase.

### ADR-003: Change Detection Before Fusion
**Context:** Should every captured frame go through the fusion layer?
**Decision:** No. Perceptual hash diff runs first; fusion only triggered if meaningful visual change detected.
**Consequences:** Dramatically reduces CPU/GPU load on static screens. Introduces small risk of missing fast visual transitions — mitigated by AX events (which fire regardless of visual change).

### ADR-004: Coordinate Fallback is Last Resort
**Context:** Canvas regions, games, and some custom-rendered UIs have no AX tree coverage.
**Decision:** Coordinate-based actions permitted only for elements flagged as `canvas_region` by fusion layer. All other actions must use AX handles.
**Consequences:** >97% of actions are deterministic and reflow-safe. Canvas actions are flagged in action logs. Any coordinate action increments a counter tracked in EVAL-SYS-004.

### ADR-005: gRPC Primary + MCP Wrapper
**Context:** What control protocol does the daemon expose?
**Decision:** gRPC as the primary protocol (performance, typing, streaming). MCP server is a thin wrapper over gRPC for Claude Code / LLM agent ecosystem compatibility.
**Consequences:** Best of both worlds — high-performance native clients via gRPC, broad ecosystem compatibility via MCP. MCP wrapper adds ~1ms overhead (acceptable).

### ADR-006: Playwright Bridge for Browser
**Context:** Should the SDD implement its own browser DOM access or bridge to Playwright?
**Decision:** Bridge to Playwright/CDP. The SDD manages the Playwright process lifecycle and exposes browser operations through the same action executor API.
**Consequences:** Browser automation is mature and well-tested in Playwright. We avoid reimplementing CDP. Trade-off: dependency on Node.js process. Mitigated by bundling Playwright runtime.

### ADR-007: FastBrain Rule Evaluation Order
**Context:** FastBrain must select one action from multiple competing rules without ambiguity. What order should rules run in, and what happens when multiple rules could apply?
**Decision:** Fixed priority order: FocusedFieldRule → ButtonMatchRule → ScrollRule → NoMatchRule. First rule to produce a match wins; evaluation stops immediately. Ambiguity within ButtonMatchRule (multiple equal-confidence candidates) drops confidence to 0.60, which falls below the default threshold and forces slow brain escalation.
**Consequences:** Most deterministic outcomes are at the top of the stack (focused field is unambiguous; exact button labels are unambiguous). Ambiguous cases are explicitly detected and escalated rather than guessed. The fixed order also bounds evaluation time: worst case is O(n) per rule × 3 rules = O(3n), well under 1ms for typical element counts.

---

## Implementation Phases

### Phase 1: Thin Daemon Foundation
- macOS LaunchDaemon in Swift (Xcode project)
- ScreenCaptureKit integration
- AXObserver event subscription
- CGEvent tap (monitor + inject)
- Basic world model (flat graph, no ML)
- gRPC server on localhost
- CLI client for testing: `sdd click --label "Submit"`

### Phase 2: Fusion Layer
- Apple Vision framework integration (text recognition, rectangle detection)
- AX + visual bounds merge
- Diff engine
- Canvas region detection and flagging
- MCP server wrapper

### Phase 3: Fast Brain + Slow Brain
- Rule engine for common patterns
- Slow brain router (Claude API default)
- Context serializer
- Uncertainty escalation logic
- Playwright bridge

### Phase 4: File Operations + Polish
- Native dialog controller
- Finder navigation
- Upload/download intercept
- Action logging + replay
- EVAL suite runner

---

## macOS Permissions Required

| Permission | Why | System Settings Path |
|------------|-----|---------------------|
| Accessibility | AXUIElement read/write, CGEvent tap | Privacy & Security → Accessibility |
| Screen Recording | ScreenCaptureKit frame capture | Privacy & Security → Screen Recording |
| Input Monitoring | CGEvent keyboard/mouse monitoring | Privacy & Security → Input Monitoring |

No private APIs. No entitlements beyond what screen reader apps use. Notarizable.

---

*Last updated: 2026-03-28*
