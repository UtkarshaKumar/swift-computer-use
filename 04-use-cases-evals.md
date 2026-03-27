# Use Cases & EVAL Suite

> These use cases define what the SDD must handle. Each is also an EVAL — a reproducible test with a pass/fail condition and performance target. Do not soften targets without explicit decision.

---

## Performance Baseline (Ground Truth)

These numbers define the gap we're closing. All targets are derived from human-speed interaction and self-driving car latency research.

| Metric | Human Baseline | Current Agents (screenshot loop) | SDD Fast Path Target | SDD Slow Brain Target |
|--------|---------------|-----------------------------------|---------------------|----------------------|
| Single action latency | 150-300ms | 2,000-5,000ms | <50ms | <1,500ms |
| Form fill (10 fields) | 15-30s | 3-8 minutes | <20s | <45s |
| File upload (find + select) | 5-10s | Fails or 60s+ | <8s | <15s |
| Navigate to page (3 clicks) | 2-4s | 8-20s | <3s | <6s |
| App switch + task | 1-3s | 10-30s | <2s | <5s |
| Action precision (% correct) | ~99% | 60-75% (coord guessing) | >97% (AX handles) | >99% |
| Verification latency (did it work?) | Immediate | Next screenshot: 500ms-2s | <50ms | <50ms |

---

## Use Case Categories

### Category 1: Web Browser Automation

These are high-frequency, well-understood tasks. Fast brain should handle most of these with zero slow brain invocation.

---

**EVAL-WEB-001: Standard Form Fill**

Task: Fill a multi-field web form (name, email, phone, address, dropdown, checkbox) and submit.

```
Input:    Form URL + field values as JSON
Success:  Form submitted, confirmation page reached
Timeout:  30 seconds

Performance targets:
  P50 completion time:  <15s
  P95 completion time:  <25s
  Success rate:         >98%
  Slow brain invocations: 0 (fast brain should handle entirely)
  Coordinate clicks used: 0 (all via AX handles)
```

---

**EVAL-WEB-002: File Upload via Browser**

Task: Trigger a file input, navigate native macOS dialog to a specified path, select file, confirm upload.

```
Input:    Page URL + local file path
Success:  File appears in upload confirmation UI
Timeout:  20 seconds

Performance targets:
  P50 completion time:  <8s
  P95 completion time:  <15s
  Success rate:         >97%
  Slow brain invocations: 0
  Note: This is the hardest case for all existing agents — file dialog is native macOS
```

---

**EVAL-WEB-003: Multi-Tab Research Task**

Task: Open 3 tabs, read specific content from each, synthesize into a typed response in a 4th tab.

```
Input:    3 URLs + extraction target + destination URL + field
Success:  Response filled correctly with information from all 3 sources
Timeout:  90 seconds

Performance targets:
  P50 completion time:  <45s
  P95 completion time:  <75s
  Success rate:         >90%
  Slow brain invocations: 1-3 (content reasoning expected)
```

---

**EVAL-WEB-004: Login + Authenticated Action**

Task: Log in to a web app (username/password form), navigate to a specific page, perform an action (e.g., click a button, change a setting).

```
Input:    URL + credentials (from keychain) + target action
Success:  Action completed, verified by world model state change
Timeout:  30 seconds

Performance targets:
  P50 completion time:  <12s
  P95 completion time:  <20s
  Success rate:         >97%
  Slow brain invocations: 0-1
```

---

### Category 2: Native macOS App Automation

These require AXUIElement system-wide. No existing agent framework handles these reliably.

---

**EVAL-MAC-001: Finder File Operation**

Task: Open Finder, navigate to a specified folder path, rename a file, move it to another folder.

```
Input:    Source path + new name + destination path
Success:  File renamed and moved, verified via AX tree
Timeout:  20 seconds

Performance targets:
  P50 completion time:  <8s
  P95 completion time:  <15s
  Success rate:         >97%
  Slow brain invocations: 0
```

---

**EVAL-MAC-002: System Preferences Change**

Task: Open System Settings, navigate to a specific pane, change a setting (e.g., toggle, dropdown, slider).

```
Input:    Setting identifier + desired value
Success:  Setting changed, confirmed via AX state read
Timeout:  15 seconds

Performance targets:
  P50 completion time:  <6s
  P95 completion time:  <12s
  Success rate:         >95%
  Slow brain invocations: 0
```

---

**EVAL-MAC-003: Cross-App Data Transfer**

Task: Copy a value from one app (e.g., a record in a spreadsheet), switch to another app, paste/enter into a form field.

```
Input:    Source app + element selector + destination app + field
Success:  Value transferred correctly
Timeout:  15 seconds

Performance targets:
  P50 completion time:  <5s
  P95 completion time:  <10s
  Success rate:         >96%
  Slow brain invocations: 0
```

---

**EVAL-MAC-004: Native Dialog Handling**

Task: Trigger an app action that produces a native modal dialog (save, confirm, permission), respond correctly.

```
Input:    Action that triggers dialog + expected dialog type + response
Success:  Dialog dismissed correctly, app state matches expected
Timeout:  10 seconds

Performance targets:
  P50 completion time:  <3s
  P95 completion time:  <6s
  Success rate:         >98%
  Slow brain invocations: 0
```

---

### Category 3: Complex Multi-Step Workflows

These are the flagship use cases — the ones that justify the product's existence. Fast brain executes mechanics; slow brain drives decisions.

---

**EVAL-FLOW-001: Job Application (End to End)**

Task: Given a job URL and resume path, fill out an online job application including file upload, answer screening questions, and submit.

```
Input:    Job posting URL + resume path + candidate data JSON
Success:  Application submitted, confirmation received
Timeout:  5 minutes

Performance targets:
  P50 completion time:  <3 minutes
  P95 completion time:  <5 minutes
  Success rate:         >85%
  Slow brain invocations: 3-8 (screening questions require reasoning)
  Human equivalent:     15-30 minutes
```

---

**EVAL-FLOW-002: Meeting Setup (Calendar + Email)**

Task: Find a free time slot, create a calendar event, draft and send an email invite to specified recipients.

```
Input:    Recipient list + meeting details + date range preference
Success:  Event on calendar, email sent, recipients match
Timeout:  3 minutes

Performance targets:
  P50 completion time:  <90s
  P95 completion time:  <3 minutes
  Success rate:         >90%
  Slow brain invocations: 2-4
```

---

**EVAL-FLOW-003: Research + Document**

Task: Research a topic across 5+ web sources, open a local document (Word/Pages/Google Docs), write a structured summary.

```
Input:    Research topic + document path + output structure
Success:  Document updated with factually grounded content from sources
Timeout:  8 minutes

Performance targets:
  P50 completion time:  <5 minutes
  P95 completion time:  <8 minutes
  Success rate:         >80%
  Slow brain invocations: 10-20 (heavy content reasoning)
```

---

**EVAL-FLOW-004: Software Setup (Dev Environment)**

Task: Clone a repo, install dependencies, run setup script, verify running in browser — all via terminal + Finder + browser.

```
Input:    Git URL + setup instructions
Success:  App running at expected local URL
Timeout:  10 minutes (excluding actual npm install time)

Performance targets:
  P50 completion time:  <5 minutes (excl. install)
  P95 completion time:  <10 minutes
  Success rate:         >80%
  Slow brain invocations: 2-5 (error interpretation, decision points)
```

---

### Category 4: System-Level Precision (Technical EVALs)

These test the SDD's infrastructure, not agent intelligence. They are pass/fail against hard numbers.

---

**EVAL-SYS-001: World Model Update Latency**

Test: Trigger a UI change (open window, focus element, scroll). Measure time from OS event to world model diff emitted to subscriber.

```
Target:   P50 <20ms, P95 <50ms, P99 <100ms
Failure:  Any P95 >100ms
```

---

**EVAL-SYS-002: Action Execution Latency (Fast Path)**

Test: Submit an AXPress action on a known visible element. Measure time from API call received to verify signal returned.

```
Target:   P50 <30ms, P95 <50ms, P99 <80ms
Failure:  Any P95 >100ms
```

---

**EVAL-SYS-003: AX Tree Coverage**

Test: For each target app (Safari, Chrome, Finder, System Settings, Terminal, VS Code), measure % of interactive elements correctly identified in AX tree vs visual count.

```
Target:   >95% coverage on standard apps
          >80% coverage on Electron apps (known hard case)
          >60% coverage on canvas-based UIs (expected lower — flag for slow brain)
Failure:  <90% on standard apps
```

---

**EVAL-SYS-004: Coordinate-Free Action Rate**

Test: Over 1,000 real-world actions across a mixed workload, measure % executed via AX handles vs coordinate fallback.

```
Target:   >97% AX handle execution
          <3% coordinate fallback
Failure:  >5% coordinate fallback
```

---

**EVAL-SYS-005: Fast Brain Escalation Accuracy**

Test: Run 500 actions where ground truth is known (fast brain should handle) and 500 where slow brain is needed. Measure fast brain's escalation decision accuracy.

```
Target:   >95% correct escalation decisions
          False negative (should escalate, didn't): <3%
          False positive (escalated unnecessarily): <8%
Failure:  >5% false negative rate (silent failures are worse than over-escalation)
```

---

## EVAL Running Protocol

1. All EVALs run against a clean macOS VM (fresh login, no residual state)
2. SYS EVALs run 1,000 iterations minimum; report P50/P95/P99
3. USE CASE EVALs run 20 iterations minimum (cost constrained); report mean + success rate
4. Results logged to `eval-results/YYYY-MM-DD.json`
5. Regression: any EVAL that drops >10% from last baseline blocks merge

---

*Last updated: 2026-03-28*
