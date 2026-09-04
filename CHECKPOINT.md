# v0.2.0 implementation checkpoint

Date: 2026-09-04
Metric contract: `2.0`

## Requirement evidence

| Plan task | Evidence |
|---|---|
| 1. Metric contract | `METRIC_CONTRACT.md` defines one source, formula, scope, deduplication rule, and snapshot rule for every KPI. |
| 2. Completeness | Dashboard exposes incomplete exported turns and snapshot bounds. Report emits active/incomplete/partial/missing/limit warnings with stable codes. |
| 3. Rounds and time | Dashboard and report join WebSocket rounds, sampling, and terminal tool spans by Trace ID. Fixture result is 2 rounds, 4000 ms sampling, 5000 ms tools, and 1000 ms other for a 10000 ms turn. |
| 4. Tool failures | Terminal outcome plus `event.success=false` is used everywhere. Report deduplicates `trace_id:call_id`, excludes nested calls, and emits class, bounded reason, retry/recovered status, and Trace ID. |
| 5. Tool analytics | Dashboard has project-scoped calls/failures, p50/p95/max, and slowest-call panels. Report fixture identifies `read` at 3000 ms as the slowest tool. |
| 6. Tokens/cache | Completed canonical turns are the only token source. Fixture totals: input 100, cached 40, non-cached 60, output 20, reasoning 5, total 120. |
| 7. Observer effect | Report captures one UTC `as_of` and sends absolute `from/to`. Repeating the fixture at the same `as_of` produces byte-equivalent normalized JSON. Dashboard prints `from/as_of`; an absolute Grafana range remains stable under 10s refresh. |
| 8. Privacy/cardinality | Collector drops all log records before Loki because the pinned binary cannot sanitize arbitrary log bodies. Trace attributes remove raw payload and identity fields. Dashboard has no Loki targets or raw argument/output selectors. |
| 9. Report | JSON schema `2.0` and Markdown expose the common contract, coverage, token/model/tool breakdowns, failures, and turns. |
| 10. Regression/UI | Synthetic fixture covers partial/oversized response, duplicate turn/call, missing root/turn, nested failure, and active activity. Static dashboard contract and live query syntax checks pass. Provisioned Grafana renders all 19 panels. |

## Synthetic raw-to-report comparison

Snapshot: `2026-09-04T07:00:00Z..2026-09-04T08:00:00Z`.

| Item | Raw fixture | Canonical report |
|---|---:|---:|
| Turn rows | 3 | 1 completed, 1 incomplete; duplicate trace reduced to newest |
| Project activity traces | 4 | 1 active candidate, 1 missing/rootless, 1 incomplete, 1 completed |
| Tool rows | 4 | 2 top-level distinct calls |
| Failure rows | 2 | 1 top-level distinct failure |
| Round rows | 2 | 2 rounds on the completed turn |
| Sampling rows | 1 | 4000 ms on the completed turn |

The fixture is synthetic and contains no copied user/developer telemetry.

## Checks executed

- `docker compose config --quiet`: PASS.
- Dashboard JSON `ConvertFrom-Json`: PASS; 19 panels, `Project cwd` textbox, refresh `10s`.
- PowerShell parser for report and both regression scripts: PASS.
- `scripts/test-codex-performance-report.ps1`: PASS.
- `scripts/test-dashboard-contract.ps1`: PASS.
- Collector `0.159.0 validate --config`: PASS.
- Grafana `/api/ds/query`: all 32 Tempo targets parse and execute on a one-hour empty snapshot; PASS.
- Provisioning API: `codex-overview` contains 19 panels, refresh `10s`, cwd variable type `textbox`; PASS.
- Browser smoke at `http://localhost:3000/d/codex-overview/codex-overview`: all 19 panel headings render, empty state is explicit, and a fresh tab records no console warnings/errors; PASS.
- Running stack: LGTM healthy, Collector ready; PASS.

## Known limits

- No non-empty live Codex telemetry was available for this project during verification, so live numeric parity is not claimed. Numeric parity is covered by the deterministic synthetic fixture.
- A genuinely in-flight span cannot be observed until exported. The report therefore labels recent exported activity without a completed turn as an active inference.
- Tempo search remains limit-bound; partial/oversized warnings indicate observed incompleteness but cannot prove total upstream coverage.
- Codex trace span names are not a stable public schema. Schema drift must surface as empty/coverage warnings and requires fixture/query updates.
