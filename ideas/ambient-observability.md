# Ambient Observability — service context without asking

**Status:** Idea / parked
**Date:** 2026-04-23
**Related tools:** `dd_*`, `grafana_*`, `obsguard_*`, `mm_cp_*`, `cx_staging_*`
(8+ MCP observability tools already connected)

## Context

The harness has access to a large observability surface via MCP:
- Datadog: metrics, traces, logs, monitors, incidents, RUM, SLOs
- Grafana: dashboards, Prometheus, Pyroscope, ClickHouse
- Observability Guard: service alerts, alert variables
- Coralogix (staging): logs, schemas, traces, alerts
- monday-mirror Context Propagation: routing-key tracing

Today all of these are **pull-only**: Claude calls them when asked
("check Datadog for service X"). The user is responsible for knowing
*when* to ask, which for 80% of cases means they don't ask — and Claude
makes suggestions blind to the live state of production.

## The idea

Invert the flow. When the user opens a repo, branch, or file tied to a
known service, the harness **proactively pulls** a small, bounded set of
signals about that service and either:

1. **Surfaces in the HUD**: "⚠ svc-ingest: 2 alerts firing · p95 +40% · 3
   incidents in last 24h" — glanceable, not intrusive.
2. **Injects as system context**: the current Claude session's system
   prompt silently includes recent error-rate, firing alerts, and recent
   incident summaries for the service you're editing. When you then ask
   "why is this slow", Claude already *knows* about the ongoing incident
   and anchors its answer to reality.

## Why this matters

- Closes a major blindspot: AI suggestions today are code-structural
  ("this could be slow") but lack production grounding ("this *is* slow
  right now, here's the trace"). Ambient context makes suggestions
  actionable.
- Changes the user's debug workflow from "open terminal, curl metrics,
  summarise, ask Claude" to "Claude already knows, conversation is
  already informed."
- The observability tools are already wired up — this is connective
  tissue, not new infrastructure.

## Design sketch

### Service detection

Given a repo / branch / current file, infer the service name:
- `.observability-guard.yaml` or similar config file listing the service
- Repo name maps directly to service name (common convention)
- `obsguard_get_service_alerts` accepts a service name — use it as the
  source of truth for which services exist

Fallback: prompt once, remember in per-repo memory.

### The signal bundle

Keep it bounded — context is expensive. For a given service, pull:
- **Active alerts** from Observability Guard (state: firing) — max 5
- **Open incidents** from Datadog — max 3, last 24h only
- **One top anomaly**: p95 latency delta vs 7-day baseline (single number)
- **Last deploy** timestamp + diff summary if available

Total payload: ~300 tokens. Refresh cadence: on session start, then every
10 min idle. Cache per service to avoid hammering APIs on every
`find-file`.

### Injection modes

- **HUD**: add a "Service: svc-ingest · alerts: 2 firing · p95: +40%"
  line to `claude-collab-hud-mode`. Red fontification if anything is
  firing. Click/RET on the line runs `obsguard_get_service_alerts` full
  detail.
- **Session context**: prepend a structured block to the Claude system
  prompt when starting a new claude-code-ide session in a known-service
  repo. Via `claude-code-ide-system-prompt` variable (already configured
  for the emacs-mcp hint at `init.el:70`).
- **Opt-out**: per-repo disable (some repos are not services, or not
  wired to this observability stack).

## Open questions / tensions

- **Privacy / scope**: piping alert details + metrics into every Claude
  session means sending production state to the model. For staging
  Coralogix yes; for prod Datadog, depends on contract.
- **Stale context**: the 10-min refresh window means the session could
  reference a no-longer-firing alert. Add a "as of HH:MM" timestamp in
  the injected block.
- **Noise floor**: most services have 0 firing alerts most of the time.
  Injecting "0 alerts" every session is pure overhead. Gate on
  "something interesting": only inject when alerts > 0, anomaly > 2σ, or
  incident active.
- **Cross-service awareness**: edits to `shared-lib` touch dozens of
  services. Which one(s) to pull for? Maybe: show a picker, or pull the
  top-N most-recently-deployed consumers.
- **MCP tool cost**: some of these tools (dd_search_datadog_spans,
  grafana_query_prometheus) are expensive. Use lightweight summaries only
  for ambient pulls; reserve the heavy ones for explicit user asks.

## Minimal v1

1. Service-name detection: read a `.service.yaml` or use
   `(projectile-project-name)` as the service name, with per-repo
   override.
2. Single ambient pull: `obsguard_get_service_alerts` only. Most
   signal-dense call.
3. Surface in HUD line, gated on `count > 0`.
4. No system-prompt injection in v1 — just the HUD. Session-context
   injection can be v2 once we see whether the HUD signal is useful.

Total implementation: ~2 hours of Elisp + an async MCP caller.

## Dependencies

- Stable HUD (✅ shipped).
- MCP tool call from Elisp (not currently possible — claude-collab's MCP
  server is the Emacs *side* of the bus; calling outgoing MCP tools from
  Elisp requires the Agent SDK or a new shim). Alternative: shell out to
  `claude --print "use obsguard_get_service_alerts for X"` with strict
  JSON output. Hackier but works without the SDK.
- Per-repo config convention.
