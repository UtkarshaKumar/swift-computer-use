# swift-computer-use

> macOS computer use for AI agents — faster and more reliable than screenshot-based approaches.

**Status: Archived. No further maintenance planned.**

OpenAI and Google shipped native computer use while this was in development, which closed the window. I'm not going to maintain or extend this. The fast/slow brain architecture is the part worth taking — it's a general pattern for any agent that needs to act on a UI.

---

## Why I built it

Screenshot-based computer use is painfully slow. Every action is: take screenshot → send to LLM → wait 2–5 seconds → get coordinates → click. It's stateless, imprecise, and expensive — you're paying for a vision model call on every single step, even for things as simple as clicking a "Submit" button you've clicked a hundred times before.

I wanted agents to see the screen the way macOS sees it — as a semantic tree of interactive elements — and act on that directly. The AX (Accessibility) framework already knows every button, text field, and label on screen, with exact labels and roles. No vision model needed for the common case.

---

## The fast/slow brain architecture

This is the core idea. Everything else is plumbing.

Most agent systems call an LLM for every action. SDD has two execution paths — a fast one that uses no LLM at all, and a slow one that only fires when the fast path isn't confident enough.

### Fast Brain — <1ms, no LLM

The FastBrain is a rule engine that operates purely on the AX accessibility snapshot. It's synchronous, in-memory, and makes zero network calls.

When the agent needs to take an action, FastBrain evaluates a prioritized set of rules against the current snapshot and returns a **confidence score**:

| Rule | What it matches | Confidence |
|---|---|---|
| `FocusedFieldRule` | A text field is focused + intent is to type | 0.97 |
| `ButtonMatchRule` (exact) | Button label exactly matches target | 0.97 |
| `ButtonMatchRule` (case-insensitive) | Same, different case | 0.93 |
| `ButtonMatchRule` (substring) | Label contains or is contained by target | 0.88 |
| `ButtonMatchRule` (ambiguous) | Multiple equally-good matches | 0.60 |
| `ScrollRule` | Target element is below the fold | 0.95 |
| No match | Nothing in the AX tree matches | 0.0 |

If confidence ≥ 0.85 (configurable), FastBrain acts immediately. No LLM call. No screenshot. No network round-trip.

### Slow Brain — LLM-backed, only when needed

When FastBrain confidence falls below the threshold, SlowBrain takes over. It builds a full context packet — AX tree, screenshot, action history, stuck flag — and sends it to Claude Haiku (or GPT-4o-mini). The LLM returns an action plan with pixel coordinates.

Slow Brain uses a hybrid routing strategy: if the AX tree has ≥ 3 interactive elements, it uses a text-only prompt (no screenshot, cheaper, faster). If the AX tree is sparse (web canvas, custom drawing surfaces), it includes a screenshot.

### Learned rules — the feedback loop

After SlowBrain successfully executes an action, FastBrain learns from it. A `LearnedRule` is saved to SQLite: "when the app is Zoom and there's a button labelled 'Join Audio', pressing it with confidence 0.94 worked."

Next time that pattern appears, FastBrain handles it directly — no LLM call. The more tasks you run, the more FastBrain learns, the fewer LLM calls you need. Common workflows eventually become nearly free.

```
First run:  FastBrain miss → SlowBrain (LLM) → success → save rule
Second run: FastBrain hit  → act immediately (<1ms)
```

### Stuck detection

If the same action (same selector + same coordinates) repeats 3 times, or the system oscillates in an A→B→A→B loop, SDD sets a stuck flag in the next LLM prompt: *"You're stuck. The last 3 actions were identical and didn't change the screen. Try a different approach."* This handles the "click the URL bar 100 times" failure mode that plagues screenshot-based systems.

---

## Architecture

```
SDDCLI          — CLI: sdd run, sdd status, sdd override, sdd stop, sdd record
SDDMCP          — MCP server (stdio JSON-RPC 2.0) — connects to Claude Code / Claude Desktop
SDDGRPCServer   — gRPC control API on port 7800
SDDBrain        — FastBrain + SlowBrain + VNCClient + ShowUIClient + WorkflowLibrary
SDDCore         — Shared types: AX events, action log, learning, world model protocol
```

### TaskOrchestrator — the main loop

```
while stepCount < maxSteps:
    1. Check for abort / intervene signals from ~/.sdd/
    2. Inject override instruction into prompt if one is waiting
    3. Take screenshot + scan AX tree (via WorldModel)
    4. Ask SlowBrain for next action plan
    5. If plan has coordinates → vision-click directly
       Else → run FastBrain; if confident, act; else executeDirect
    6. Wait 500ms for screen to settle
    7. Rescan AX tree
    8. Write run-state.json (step, last action, element count, stuck flag)
    9. Extract LearnedRule if action succeeded
```

### Real-time feedback during a running task

```bash
sdd status
# Step 7/30 | last: click 'Easy Apply' (850,400) | elements: 52 | stuck: no

sdd override "you're in the wrong tab, close this and go back to the main page"

sdd stop
```

`sdd override` writes an instruction to `~/.sdd/override.json`. On the next step, the orchestrator injects it as highest-priority context into the LLM prompt, then deletes the file. You can course-correct a running task without stopping it.

---

## Setup

### Requirements

- macOS 14+
- Xcode Command Line Tools (`xcode-select --install`)
- Anthropic API key (Claude Haiku)
- Python 3.10+ and ~10GB disk for ShowUI-2B (optional — SDD falls back to Claude vision if unavailable)

### 1. Anthropic API key

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

### 2. Enable Screen Sharing (VNC)

System Settings → General → Sharing → Screen Sharing → enable

VNC server runs on `127.0.0.1:5900`. For localhost use, disable the VNC password.

### 3. ShowUI-2B inference server (optional)

```bash
pip install -r showui_requirements.txt
python showui_server.py
# Server starts on http://127.0.0.1:7080
```

SDD degrades gracefully if ShowUI is unavailable — falls back to Claude vision for coordinate grounding.

### 4. Accessibility permission

System Settings → Privacy & Security → Accessibility → enable for your terminal app.

### 5. Build

```bash
swift build -c release
```

Executables land in `.build/release/`:
- `sdd` — CLI
- `sdd-mcp` — MCP server for Claude integration
- `sdd-grpc` — gRPC control API

### 6. Connect Claude to SDD via MCP (optional)

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`):
```json
{
  "mcpServers": {
    "sdd": {
      "command": "/path/to/.build/release/sdd-mcp",
      "args": []
    }
  }
}
```

**Claude Code** (`.claude/settings.json`):
```json
{
  "mcpServers": {
    "sdd": {
      "command": "/path/to/.build/release/sdd-mcp",
      "type": "stdio"
    }
  }
}
```

---

## Usage

```bash
# Run a task
sdd run "apply for this job on LinkedIn"

# Monitor while it's running (second terminal)
sdd status

# Course-correct without stopping
sdd override "scroll down, the Submit button is below the fold"

# Stop
sdd stop

# Teach a workflow by demonstration
sdd record "fill out the weekly expense report"
# Demonstrate the workflow manually, then Ctrl+C
# SDD saves the sequence — replays it without LLM next time
```

---

## What's in this repo

| File | Contents |
|---|---|
| `02-architecture.md` | System architecture, component specs, architectural decision records (ADRs) |
| `04-use-cases-evals.md` | Use cases + EVAL suite with concrete performance targets |
| `INTERFACE_SPEC.md` | MCP tool definitions, gRPC API, and CLI interface specification |

---

## Acknowledgments

The MCP server architecture and approach of exposing computer-use as directly callable tools were inspired by [GhostOS](https://github.com/ghostwright/ghost-os). SDD extends this by retaining the native AX layer for OS-level dialogs (Open, Save, Print) that VNC-only systems can't reliably control.

---

## License

MIT — use it, fork it, take the fast/slow brain pattern into your own agents.
