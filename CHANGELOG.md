# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed

- Raise Tempo's explicit per-trace cap from its 5 MB default to a reviewed
  20 MB ceiling, enough for the observed 15.1 MB class without retaining the
  temporary 50 MB diagnostic value.
- Add `memory_limiter` first in every Collector pipeline, bounded batching,
  an explicit in-memory sending queue/retry policy, and private-network scraping
  of Collector internal metrics.
- Use the pinned contrib Collector distribution so OTTL can remove sensitive
  span-event attributes while retaining safe tool analytics.
- Add stack-wide dashboard panels for the four actionable Tempo discard reasons
  and Collector queue size/capacity.
- Add static operational-contract and isolated synthetic Collector privacy tests.
- Report schema 3.0 separates completed/failed/unclassified turn status from
  token availability. No trace-age completion inference; missing tokens stay
  unknown and completed turns without usage emit a warning.
- Dashboard lifecycle panels join explicit terminal signals by Trace ID, expose
  `missing_turn_or_root`, and show readable status/count labels.
- Add a minimal app-server terminal-notification to OTLP converter with required
  original trace correlation; existing historical traces are not relabeled
  without authoritative terminal evidence.
- Restore configuration, full-trace reader and regression dependencies referenced
  by the previous update but absent from its commit.

### Verification

- Collector config validation uses the pinned contrib image. The isolated
  privacy smoke asserts sensitive resource/span/span-event fields do not reach
  a file exporter while safe `tool_name`, `success`, and cwd fields survive.
- Synthetic snapshot: 2 completed, 1 failed/unclassified, 33 tool calls and
  2 tool failures. Actual Grafana lifecycle SQL agrees with the hydrated report.
- Existing report, dashboard, model-round, presentation and tool-table checks
  pass. Pinned Tempo configuration validates; live queries execute on an empty
  snapshot. Non-empty local telemetry/browser verification is not claimed.

## [0.2.1] - 2026-09-05

### Changed

- `Project cwd` now discovers exact `span.cwd` values from Tempo, auto-selects an
  available project, and keeps the multi-project dropdown.
- Empty Tempo starts with an explicit `Project not selected` state; KPI remain
  unset instead of presenting zero as measured project data.

### Fixed

- Disable Tempo exemplar frames for `Tokens by model` expressions to avoid
  mixing annotation tables with time series.
- Calculate `Model rounds / turn` by joining completed turns and model rounds
  by Trace ID, including completed turns with zero rounds.
- Read tool names from `event.tool_name`; retain legacy fallbacks in the report.
- Format tool latency metrics as seconds, matching Tempo's duration aggregates.
- Align `Slowest tool calls` transformations with Tempo field names and sort
  numeric duration before limiting the table to 20 calls.
- Give dashboard series explicit names while preserving model/tool labels.
- Show zero tool failures in green, positive counts in red, and missing values
  in a neutral color.
- Mount the dashboard directory and poll it every 30 seconds so atomic file
  replacements are loaded without restarting LGTM. Document provisioning updates.

### Verification

- Compose, JSON, PowerShell parsing, dashboard/report regressions, and five
  Grafana SQL cases pass, including a fixed synthetic report snapshot.
- Actual Grafana transformations and display processing pass slowest-call,
  34-series legend, and failure-color checks.
- An isolated pinned LGTM smoke test loads an atomically replaced dashboard
  after `docker compose up -d`, preserving the container ID and start time.
- Non-empty live telemetry parity and browser rendering were not verified for
  this release; see `CHECKPOINT.md` for evidence and remaining limits.

## [0.2.0] - 2026-09-04

### Added

- Metric contract for project scoping, immutable snapshots, completeness,
  token semantics, tool-call deduplication, and coverage warnings.
- Dashboard panels for snapshot coverage, tool throughput, tool latency
  percentiles, bounded failures, and Trace ID navigation.
- Performance report schema `2.0` with `as_of`, active/incomplete coverage,
  non-cached input, per-model/per-tool breakdowns, and deduplicated failures.
- Synthetic regression fixtures and dashboard/report contract checks.

### Changed

- Model rounds, sampling time, and tool time are joined by Trace ID instead of
  requiring a strict parent/descendant span relationship.
- Dashboard project selection uses a `Project cwd` textbox so an empty Tempo
  store does not break dashboard loading.
- Collector drops log records before Loki export and strips sensitive trace
  attributes; metrics and traces remain local to the two-container stack.

### Verification

- All 32 provisioned Tempo targets parse and execute against the pinned stack.
- Dashboard and report regression checks pass.
- Grafana renders all 19 panels with refresh preserved at `10s`.

[Unreleased]: https://github.com/Keks18/codex-otel-observability/compare/v0.2.1...HEAD
[0.2.1]: https://github.com/Keks18/codex-otel-observability/releases/tag/v0.2.1
[0.2.0]: https://github.com/Keks18/codex-otel-observability/releases/tag/v0.2.0
