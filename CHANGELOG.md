# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

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
