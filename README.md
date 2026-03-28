# Semantic Display Daemon

> macOS OS extension for real-time semantic computer use by AI agents

**Created:** 2026-03-28
**Status:** Active

## Overview

AI agents doing computer use today are stuck in a slow loop: take screenshot → send to LLM → get coordinates → click → repeat. This is 2-5 seconds per action, coordinate-based (imprecise), and stateless (no memory between calls).

The Semantic Display Daemon (SDD) replaces this with a high-speed VNC + ShowUI-2B control loop backed by a semantic AX layer:

```
VNC Framebuffer        ShowUI-2B             Quartz + Input
(continuous ~16ms)     (local ~150ms)        (precise exec)

macOS Screen ──────► ShowUI-2B ──────► normalize coords
via VNC RFB           2B VLM             via Quartz Display
                                         → CGEvent / VNC inject

Claude Haiku (text-only planning, no screenshot — cheap + fast)
"What element to interact with next?" → element description
```

Architecture follows a two-brain model:
- **Fast brain** (local, <50ms): pattern-matches AX snapshot against learned rules; zero LLM calls
- **Slow brain** (cloud LLM + ShowUI, ~1-2s): Claude Haiku plans (text-only), ShowUI-2B grounds coordinates locally

Per-step latency: **1.5–3s** (vs 3–7s for screenshot-based computer use).

## Goals

- <50ms action latency on the fast path
- Element-based execution via AX for native apps; ShowUI-2B grounding for web/canvas
- System-wide coverage: browser + native apps + file dialogs + Finder
- MCP-compatible control interface (works with Claude Code and Claude Desktop)
- Feedback loop: monitor + intervene in running tasks via `sdd status` / `sdd override`
- Learning: `sdd record` watches demonstrations and replays them without LLM

## Architecture

```
sdd-mcp (MCP server, stdio JSON-RPC 2.0)
    │ 12 tools: sdd_run, sdd_status, sdd_override, sdd_intervene, sdd_screenshot, ...
    ▼
~/.sdd/ state files (run-state.json, override.json, intervene.json)
    ▼
TaskOrchestrator (Swift actor)
    ├── FastBrain      — AX rule lookup, O(1) via SQLite index
    ├── SlowBrain      — Claude Haiku text-only + ShowUI-2B grounding
    ├── VNCClient      — RFB 3.8 framebuffer capture + input injection
    ├── ShowUIClient   — HTTP client → local ShowUI-2B inference server
    ├── WorkflowLibrary — deterministic pre-built workflows (open URL, file upload, ...)
    └── LearnedRulesStore — SQLite: learned rules + sequential workflows
```

## Setup

### 1. Anthropic API Key

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

### 2. Enable macOS Screen Sharing (VNC)

System Settings → General → Sharing → Screen Sharing → enable

Or via terminal:
```bash
sudo /System/Library/CoreServices/RemoteManagement/ARDAgent.app/Contents/Resources/kickstart \
    -activate -configure -access -on -privs -all -restart -agent -menu
```

VNC server runs on `127.0.0.1:5900`.

### 3. ShowUI-2B Inference Server

Requires Python 3.10+ and ~10GB disk (model weights).

```bash
cd /path/to/Semantic\ Display\ Daemon
pip install -r showui_requirements.txt
python showui_server.py
```

Server runs on `http://127.0.0.1:7080`. Health check: `curl http://127.0.0.1:7080/health`

SDD degrades gracefully if ShowUI is unavailable — falls back to Claude vision.

### 4. Accessibility Permission

System Settings → Privacy & Security → Accessibility → enable for `sdd` (or your terminal app).

### 5. Build

```bash
swift build -c release
```

Executables in `.build/release/`:
- `sdd` — CLI: `sdd run`, `sdd record`, `sdd status`, `sdd override`, `sdd stop`
- `sdd-daemon` — world model daemon (AX observer)
- `sdd-mcp` — MCP server for Claude integration
- `sdd-grpc` — gRPC control API (port 7800)

## Usage

### Run a task

```bash
sdd run "apply for this job on LinkedIn"
```

### Monitor and intervene while running

```bash
# In a second terminal:
sdd status
# Step 7/30 | last: click 'Easy Apply' (850,400) | elements: 52 | stuck: no

sdd override "you're clicking the URL bar, scroll down to find the Easy Apply button"

sdd stop
```

### Teach a workflow by demonstration

```bash
sdd record "fill out job application"
# Physically demonstrate the workflow — click, type, submit
# Press Ctrl+C when done — SDD saves the sequence to SQLite
```

### Connect Claude to SDD via MCP

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

Once connected, Claude can call `sdd_run`, `sdd_screenshot`, `sdd_override`, and 9 other tools directly.

## Documents

| File | Contents |
|------|----------|
| `01-problem-solution.md` | Full problem definition and solution space |
| `02-architecture.md` | System architecture, component specs, ADRs |
| `03-monetization.md` | Business model, pricing, go-to-market |
| `04-use-cases-evals.md` | Use cases + EVAL suite with performance targets |

## Acknowledgments

The MCP server architecture in SDD and the approach of exposing computer-use capabilities as directly callable tools were inspired by [GhostOS](https://github.com/ghostwright/ghost-os). SDD addresses GhostOS's known limitation with file upload and multi-step cross-app flows by retaining the native macOS AX layer specifically for navigating OS-level dialogs (Open, Save, Print) that VNC-only systems cannot reliably control.

## Notes

Built entirely on public macOS APIs — no private frameworks, no special entitlements beyond standard Accessibility access (same as screen readers).
