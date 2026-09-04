# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

### Changed

- `Project cwd` now discovers exact `span.cwd` values from Tempo, auto-selects an
  available project, and keeps the multi-project dropdown.
- Empty Tempo starts with an explicit `Project not selected` state; KPI remain
  unset instead of presenting zero as measured project data.

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

[0.2.0]: https://github.com/Keks18/codex-otel-observability/releases/tag/v0.2.0
