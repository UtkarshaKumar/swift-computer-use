# Monetization Strategy

> Business model, pricing, and go-to-market for the Semantic Display Daemon.

---

## Core Product Decision: Option A (Intelligence Inside)

The slow brain lives inside the daemon. Users configure one API key. SDD handles routing, context management, model selection, and fast/slow escalation logic internally.

**Why this is the right product decision:**

- Users don't want to wire together infrastructure. They want a thing that works.
- Intelligence-inside = complete product. Intelligence-outside = SDK. SDKs are harder to monetize, easier to copy.
- We control the model routing — we can optimize cost, latency, model choice without user involvement.
- We can abstract over LLM providers (today Claude, tomorrow mix of Claude + local model) without changing the user-facing API.
- It creates a **moat**: the quality of our fast/slow routing, world model, and context summarization is a product differentiator that can't be replicated by just calling the same LLM.

**The risk to manage:** Users with existing LLM contracts may want BYO-model. Offer this as an Enterprise tier option, not the default.

---

## Who Is the Customer

### Primary: Developers building AI agents
They want their agents to do computer use reliably. They're paying today for Anthropic Computer Use, BrowserUse, or building custom screenshot loops. They will pay for something that is faster, more reliable, and handles cases their current solution can't (file dialogs, native apps, precise clicking).

**Willingness to pay:** High. Their agents failing = their product failing. Reliability has clear ROI.

### Secondary: Enterprises running automation at scale
Internal IT automation, RPA replacement, testing infrastructure. Currently using UiPath, Selenium, or expensive human QA. Latency and reliability matter more than unit cost.

**Willingness to pay:** Very high. RPA licenses (UiPath, Automation Anywhere) are $15,000-$100,000/yr per deployment.

### Tertiary: Power users / prosumers
Individuals who want AI agents to handle their computer — booking, research, form-filling, file management. Smaller contracts, higher volume. Think Zapier-for-desktop.

---

## Pricing Model

### Tier 1: Developer (Self-Serve)
- **Price:** $29/month per machine
- **What's included:**
  - SDD daemon (unlimited installs on licensed machine)
  - Fast brain (local, bundled)
  - Slow brain: included LLM calls up to 10,000 actions/month
  - MCP + gRPC API access
  - Browser + native app + file dialog coverage
- **Target:** Individual developers, small teams

### Tier 2: Team
- **Price:** $99/month per machine (or $79/seat for 5+ seats)
- **What's added:**
  - 50,000 actions/month included
  - Priority slow brain routing (dedicated inference capacity)
  - Action logging + replay (debug failed runs)
  - Team dashboard: usage, error rates, latency percentiles
- **Target:** Product teams building agent products

### Tier 3: Enterprise
- **Price:** Custom (floor $2,000/month per deployment)
- **What's added:**
  - Unlimited actions (metered overage pricing)
  - BYO LLM (bring your own API key / on-prem model)
  - SLA: 99.9% uptime, <50ms P95 fast-path latency guarantee
  - SSO, audit logs, compliance export
  - Dedicated support, onboarding, custom eval suite
- **Target:** Enterprises replacing RPA, QA infrastructure, internal automation

### Overage Pricing (all tiers)
Actions beyond included allotment: $0.002 per action (fast path) / $0.02 per action (slow brain invocation)

---

## Revenue Model Comparison

| RPA / Automation Tool | Pricing |
|-----------------------|---------|
| UiPath (enterprise) | $15,000-$60,000/yr |
| Automation Anywhere | $15,000+/yr |
| Zapier (pro) | $49-$799/month |
| Anthropic Computer Use | $3/1000 screenshots (~$0.003/action) + inference |
| **SDD Developer tier** | **$29/month, ~$0.003/action all-in** |
| **SDD Enterprise** | **$2,000-$10,000/month, SLA-backed** |

Positioning: cheaper than RPA, more capable than screenshot-based computer use, faster than anything else.

---

## Moat Building

### Technical moats
1. **World model quality** — the longer SDD runs, the better it knows common app patterns. This can be a learned component over time.
2. **Fast brain rule engine** — built from observing millions of UI interactions. Hard to replicate without the data.
3. **macOS-specific optimization** — deep integration with ScreenCaptureKit, AX framework. Not portable. Not easy to copy.

### Distribution moats
1. **MCP-first** — being the best computer use tool in the Claude Code / MCP ecosystem means Anthropic's own distribution amplifies us.
2. **Agent framework integrations** — first-class support in LangChain, CrewAI, AutoGen means every agent built on those platforms is a potential customer.
3. **EVAL suite** — public, reproducible benchmarks (see `04-use-cases-evals.md`) that others can run. If we top the leaderboard, that's marketing.

---

## Go-To-Market: Phase 1

1. **Open-source the daemon layer** (sensor/actuator, world model, API). Keep the fast brain rule engine and slow brain routing proprietary. Classic open-core.
2. **MCP-first launch** — ship as an MCP server. Every Claude Code user can install it. Anthropic has incentive to promote (makes their product better).
3. **EVAL-driven credibility** — publish benchmark results before launch. "X seconds to fill a form" vs Anthropic Computer Use vs BrowserUse. Numbers win.
4. **Developer tier free trial** — 30 days, 5,000 actions. Let them see the speed difference themselves.

---

## Why Option A Enables This Business Model

If the slow brain were external (Option B), the product would be:
- A client library / SDK
- Priced by API calls (no recurring SaaS)
- Easily replicated (just wrap the same LLM APIs)
- No differentiation from "just use Playwright + Claude"

Option A makes the routing, context management, and fast/slow brain logic **our IP inside a running service**. That's the SaaS surface. That's what gets a subscription.

---

*Last updated: 2026-03-28*
