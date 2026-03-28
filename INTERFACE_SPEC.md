# ActionExecutor Interface Specification

This document defines the `ActionExecutor` protocol for the Semantic Display Daemon (SDD), enabling deterministic UI interactions on macOS.

## Protocol: `ActionExecutorProtocol`

```swift
public protocol ActionExecutorProtocol {
    /// Executes a specified action on a UI element.
    /// Returns a synchronous VerifySignal within 50ms.
    func execute(_ action: Action, on element: UIElement) async throws -> VerifySignal
    
    /// Counter for coordinate-based fallback actions (EVAL-SYS-004).
    var coordinateActionCount: Int { get }
}
```

## Supported Actions

1.  **Primary: `AXUIElement` actions**
    - `AXPress`: Trigger the default action of an element.
    - `AXSetValue`: Set the text or state value of an element.
    - `AXSetFocused`: Request focus for an element.
2.  **Secondary: `CGEvent` Keyboard Injection**
    - Keyboard shortcuts and key combinations (e.g., `Cmd+Shift+G`).
3.  **Tertiary: `CGEvent` Mouse Fallback**
    - Click at a specific `CGPoint` (centroid).
    - **Restriction:** ONLY permitted for elements flagged with `isCanvasRegion: true`.

## Synchronous Verification

All actions must return a `VerifySignal` confirming the outcome. The executor must wait for a state update from the `WorldModel`.
- **Latency Requirement:** P95 < 50ms.
- **Timeout:** If no verification occurs within 50ms, the action fails.

## File Dialog Navigation

The executor provides specialized AX-based navigation for `NSOpenPanel` and `NSSavePanel` to handle file operations natively.

## EVAL Tracking

- `coordinateActionCount`: Every coordinate action (mouse fallback) must increment this counter to track the "Coordinate-Free Action Rate" (EVAL-SYS-004).
