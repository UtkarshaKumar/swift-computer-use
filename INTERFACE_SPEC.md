# SDD Interface Specification

> **This document is the contract between the swift-computer-use and external agent consumers (Kimi, Gemini, Claude, custom agents).**
>
> Version: 0.1.0 · Last updated: 2026-03-28
>
> Implementing agents MUST conform to every type and protocol defined here.
> The SDD makes no compatibility guarantees for callers that deviate.

---

## Overview

The SDD exposes two transports:

| Transport | Port | Best for |
|-----------|------|----------|
| **gRPC** (primary) | `localhost:7800` | High-performance clients; typed streaming |
| **WebSocket/JSON** | `localhost:7801` | MCP-compatible agents; Claude Code integration |

Both transports expose the same logical API. This document defines the shared data model and the API contract for both.

---

## 1. Core Data Types

### 1.1 `UIElementID`

Stable opaque identifier for a UI element within a daemon session.

```swift
// Swift (SDDCore)
public struct UIElementID: Hashable, Sendable, Codable {
    public let rawValue: UInt64
}
```

```json
// JSON wire format
{ "rawValue": 12345678901234 }
```

**Constraints:**
- Stable within a daemon session (until `sdd` process restarts)
- NOT stable across restarts — agents must re-subscribe after a daemon restart
- Derived from `CFHash(AXUIElement)` — opaque, do not interpret

---

### 1.2 `UIElementRole`

```swift
public enum UIElementRole: String, Codable {
    case button, textField, staticText, checkBox, radioButton
    case popUpButton, comboBox, slider, progressIndicator
    case link, image, scrollArea, scrollBar
    case group, window, sheet, dialog
    case toolbar, menuBar, menu, menuItem
    case table, tableRow, tableColumn
    case outline, outlineRow
    case list, listItem
    case tabGroup, tab
    case splitGroup, splitter
    case webArea
    case unknown
}
```

**Wire format:** lowercase camelCase string matching the Swift enum raw value.

---

### 1.3 `UIElementState`

Bitmask of mutable flags. JSON consumers receive this as an integer bitmask OR as a string array — the SDD sends both; consume whichever is convenient.

```
Bit 0  (0x01): enabled
Bit 1  (0x02): focused
Bit 2  (0x04): selected
Bit 3  (0x08): expanded
Bit 4  (0x10): minimized
Bit 5  (0x20): visible
```

```json
{
  "stateBitmask": 35,
  "stateFlags": ["enabled", "focused", "selected"]
}
```

---

### 1.4 `UIElementFrame`

Screen-relative bounding rectangle in points. **Informational only.**

```json
{ "x": 100.0, "y": 200.0, "width": 80.0, "height": 24.0 }
```

> **WARNING:** Do NOT use frame coordinates for action targeting. All actions
> must use `UIElementID` or `ElementSelector`. See §3 (ActionRequest).

---

### 1.5 `UIElement`

A node in the world model graph.

```typescript
interface UIElement {
  id: UIElementID;
  role: UIElementRole;
  label: string | null;        // kAXTitleAttribute or kAXDescriptionAttribute
  value: string | null;        // kAXValueAttribute — text, boolean as "true"/"false", etc.
  stateBitmask: number;        // UIElementState bitmask
  stateFlags: string[];        // Human-readable state flags
  frame: UIElementFrame;       // Informational only
  childIDs: UIElementID[];     // Direct children in AX tree
  parentID: UIElementID | null;
  ownerPID: number;            // Process identifier of the owning app
}
```

**Protobuf equivalent:**

```protobuf
message UIElement {
  uint64 id = 1;
  string role = 2;
  optional string label = 3;
  optional string value = 4;
  uint32 state_bitmask = 5;
  UIElementFrame frame = 6;
  repeated uint64 child_ids = 7;
  optional uint64 parent_id = 8;
  int32 owner_pid = 9;
}

message UIElementFrame {
  double x = 1;
  double y = 2;
  double width = 3;
  double height = 4;
}
```

---

## 2. World Model Stream

### 2.1 `WorldModelDiff`

The SDD streams diffs, not full snapshots. After initial connection, agents receive
a `WorldModelSnapshot` (§2.2) followed by a continuous stream of `WorldModelDiff` messages.

```typescript
interface WorldModelDiff {
  sequenceNumber: number;      // Monotonically increasing; gap = dropped diff
  triggeredBy: AXNotification; // Which AX event caused this diff
  added: UIElement[];          // Newly visible elements
  updated: UIElement[];        // Changed elements (value, state, frame)
  removedIDs: UIElementID[];   // Elements no longer in the tree
  focusedElementID: UIElementID | null;
  timestampMs: number;         // Unix epoch milliseconds
}

type AXNotification =
  | "AXFocusedUIElementChanged"
  | "AXWindowCreated"
  | "AXWindowMiniaturized"
  | "AXUIElementDestroyed"
  | "AXValueChanged"
  | "AXSelectedTextChanged";
```

**Protobuf:**

```protobuf
message WorldModelDiff {
  uint64 sequence_number = 1;
  string triggered_by = 2;
  repeated UIElement added = 3;
  repeated UIElement updated = 4;
  repeated uint64 removed_ids = 5;
  optional uint64 focused_element_id = 6;
  int64 timestamp_ms = 7;
}
```

**Contract:**
- `sequenceNumber` starts at 0 on daemon start and increments by 1 per diff
- An agent that detects a gap MUST request a fresh `WorldModelSnapshot` (§2.2)
- An empty diff (all arrays empty) is never sent — the SDD filters these out

---

### 2.2 `WorldModelSnapshot`

Full point-in-time state. Sent once on connection; available on demand via `GetSnapshot` RPC.

```typescript
interface WorldModelSnapshot {
  sequenceNumber: number;       // Snapshot taken after this diff
  elements: UIElement[];        // All currently tracked elements
  focusedElementID: UIElementID | null;
  trackedPIDs: number[];        // All currently observed app PIDs
  capturedAtMs: number;
}
```

**Protobuf:**

```protobuf
message WorldModelSnapshot {
  uint64 sequence_number = 1;
  repeated UIElement elements = 2;
  optional uint64 focused_element_id = 3;
  repeated int32 tracked_pids = 4;
  int64 captured_at_ms = 5;
}
```

---

## 3. Action API

### 3.1 `ElementSelector`

How an agent specifies a target element. Priority order — the SDD resolves in this order:

```typescript
type ElementSelector =
  | { type: "elementID"; id: UIElementID }
  | { type: "roleAndLabel"; role: UIElementRole; label: string }
  | { type: "roleAndLabelPrefix"; role: UIElementRole; labelPrefix: string };
```

> **CRITICAL:** Coordinate-based targeting (`{ type: "xy"; x: ...; y: ... }`) is
> NOT a valid selector type. The SDD will reject any action request containing
> coordinates. All targeting is via AX handles only. See ADR-004.

---

### 3.2 `ActionRequest`

```typescript
type ActionRequest =
  | {
      type: "press";
      target: ElementSelector;
    }
  | {
      type: "setValue";
      target: ElementSelector;
      value: string;
    }
  | {
      type: "setFocused";
      target: ElementSelector;
    }
  | {
      type: "scrollIntoView";
      target: ElementSelector;
    }
  | {
      type: "keyboardShortcut";
      modifiers: KeyModifier[];  // ["command", "shift", "option", "control"]
      key: string;               // Single character or named key: "return", "tab", "escape", etc.
    };

type KeyModifier = "command" | "shift" | "option" | "control";
```

**Protobuf:**

```protobuf
message ActionRequest {
  string request_id = 1;          // Agent-assigned UUID for correlation
  oneof action {
    PressAction press = 2;
    SetValueAction set_value = 3;
    SetFocusedAction set_focused = 4;
    ScrollIntoViewAction scroll_into_view = 5;
    KeyboardShortcutAction keyboard_shortcut = 6;
  }
}

message ElementSelector {
  oneof selector {
    uint64 element_id = 1;
    RoleAndLabelSelector role_and_label = 2;
    RoleAndLabelPrefixSelector role_and_label_prefix = 3;
  }
}

message PressAction         { ElementSelector target = 1; }
message SetValueAction      { ElementSelector target = 1; string value = 2; }
message SetFocusedAction    { ElementSelector target = 1; }
message ScrollIntoViewAction { ElementSelector target = 1; }
message KeyboardShortcutAction {
  repeated string modifiers = 1;
  string key = 2;
}
```

---

### 3.3 `ActionResult`

Returned synchronously (async/await) after the action and its verification.

```typescript
interface ActionResult {
  requestID: string;
  outcome:
    | "success"           // AX action executed, world model confirmed state change
    | "unverified"        // Action executed but no world model change within 50ms
    | "elementNotFound"   // Selector matched no element
    | "axError"           // AX API returned an error (see axErrorCode)
    | "canvasRegion";     // Target element is a canvas — AX action not possible
  latencyMs: number;      // Time from SDD receiving request to verify signal
  resolvedElementID: UIElementID | null;
  axErrorCode: number | null; // AXError code when outcome == "axError"
}
```

**Protobuf:**

```protobuf
message ActionResult {
  string request_id = 1;
  string outcome = 2;
  double latency_ms = 3;
  optional uint64 resolved_element_id = 4;
  optional int32 ax_error_code = 5;
}
```

**Performance targets (EVAL-SYS-002):**
- P50 latency: < 30ms
- P95 latency: < 50ms
- P99 latency: < 80ms

---

## 4. gRPC API

Service definition (proto3):

```protobuf
syntax = "proto3";
package sdd.v1;

service SemanticDisplayDaemon {
  // Subscribe to world model diffs. First message is always a snapshot.
  rpc SubscribeWorldModel(SubscribeRequest) returns (stream WorldModelMessage);

  // Get a full snapshot on demand (e.g., after detecting a sequence gap).
  rpc GetSnapshot(GetSnapshotRequest) returns (WorldModelSnapshot);

  // Execute a single action synchronously.
  rpc ExecuteAction(ActionRequest) returns (ActionResult);

  // Execute a sequence of actions. Stops on first failure unless continue_on_failure is set.
  rpc ExecuteSequence(ExecuteSequenceRequest) returns (ExecuteSequenceResponse);
}

message SubscribeRequest {
  // If set, replay diffs from this sequence number (best-effort, ring buffer).
  optional uint64 resume_from_sequence = 1;
}

message WorldModelMessage {
  oneof payload {
    WorldModelSnapshot snapshot = 1;
    WorldModelDiff diff = 2;
  }
}

message GetSnapshotRequest {}

message ExecuteSequenceRequest {
  repeated ActionRequest actions = 1;
  bool continue_on_failure = 2;
}

message ExecuteSequenceResponse {
  repeated ActionResult results = 1;
}
```

**Connection:**
- Address: `localhost:7800`
- TLS: disabled (localhost only)
- Max message size: 32 MB (for large snapshots)

---

## 5. WebSocket / MCP API

For Claude Code and other MCP-compatible agents.

**Endpoint:** `ws://localhost:7801/mcp`

### 5.1 Subscribe (client → server)

```json
{ "type": "subscribe", "resumeFromSequence": null }
```

### 5.2 World Model Message (server → client)

First message after subscribe is always a snapshot:

```json
{
  "type": "snapshot",
  "payload": { /* WorldModelSnapshot */ }
}
```

Subsequent messages are diffs:

```json
{
  "type": "diff",
  "payload": { /* WorldModelDiff */ }
}
```

### 5.3 Execute Action (client → server)

```json
{
  "type": "executeAction",
  "requestID": "uuid-v4",
  "action": {
    "type": "press",
    "target": { "type": "roleAndLabel", "role": "button", "label": "Submit" }
  }
}
```

### 5.4 Action Result (server → client)

```json
{
  "type": "actionResult",
  "requestID": "uuid-v4",
  "result": { /* ActionResult */ }
}
```

---

## 6. Agent Implementation Checklist

Kimi and Gemini agents consuming this API MUST:

- [ ] Handle `WorldModelSnapshot` on initial subscribe before processing any diffs
- [ ] Track `sequenceNumber` and request a fresh snapshot on any gap
- [ ] Apply diffs in sequence order — do not apply out-of-order diffs
- [ ] Reference elements by `UIElementID` in all action requests
- [ ] Never construct coordinate-based actions — use `ElementSelector` only
- [ ] Handle `outcome: "unverified"` as a soft failure — retry with the same action once before escalating
- [ ] Handle `outcome: "elementNotFound"` by re-querying the world model (element may have moved)
- [ ] Handle `outcome: "canvasRegion"` by escalating to slow brain (element requires visual reasoning)
- [ ] Dispose of `UIElementID` values after a daemon restart (they are session-scoped)
- [ ] Implement gRPC reconnection with exponential backoff on connection loss

---

## 7. Versioning & Stability

- This spec is at **v0.1.0** — pre-production. Breaking changes are expected.
- The gRPC service version is embedded in the package name (`sdd.v1`).
- The WebSocket endpoint will include `/v1/` once the API stabilizes.
- Field additions are non-breaking. Field removals are always breaking and will bump the major version.

---

## 8. EVAL Targets Agents Should Track

External agents are expected to self-report these metrics:

| Metric | Target | EVAL |
|--------|--------|------|
| Actions via `elementID` selector | > 80% of all actions | EVAL-SYS-004 |
| `unverified` outcomes | < 5% of all actions | EVAL-SYS-002 |
| `elementNotFound` outcomes | < 3% of all actions | — |
| Sequence gaps detected | 0 per session | — |

---

*Generated from `SDDCore` source at commit HEAD · 2026-03-28*
