# Regular-turn support checkpoint (unreleased)

Date: 2026-09-07. Branch: `main`. Report schema: `3.0`.

- Synthetic fixed snapshot: 2 completed, 1 failed/unclassified, 33 tool calls,
  2 tool failures; both completed turns have missing token usage.
- Six actual Grafana lifecycle SQL panels agree with the hydrated report on the
  same synthetic project/from/as_of, including conflicting failed/completed
  signals. Future completion, trace age, exact cwd, payload filtering, unknown
  signal version, and terminal converter idempotency checks pass.
- Compose/JSON and all PowerShell parser checks pass. Existing report, dashboard,
  model-round, presentation and slowest-call regressions pass. Report and regular
  turn/converter checks also pass in Windows PowerShell 5.1.
- Restored Tempo configuration validates with the pinned image. All dashboard
  targets execute on the fixed empty live snapshot.
- Local Tempo searches returned no traces for each of the preceding seven days;
  Loki returned no stream labels over that period. Non-empty live parity and
  browser rendering are not verified. Existing containers/volumes were not
  changed; the config verifier used a disposable network-isolated container.
- The normalized terminal marker is an explicit integration contract. Stock
  telemetry without authoritative outcome/correlation stays unclassified; the
  converter does not automatically capture notifications or publish markers.

The following checkpoint is historical:

# v0.2.1 verification checkpoint

Date: 2026-09-05
Metric contract: `2.0`

## Fix evidence

| Task | Implementation and evidence |
|---|---|
| 1. Tokens by model | Tempo targets disable exemplar frames before Grafana expressions. Static contract checks pass; non-empty live expression rendering was not verified. |
| 2. Model rounds / turn | SQL joins rounds to completed turns by Trace ID, includes zero-round turns, and returns time/number fields. Five synthetic cases execute in the running Grafana SQL engine, including comparison with the report at one fixed snapshot. |
| 3. Tool names | Dashboard uses `event.tool_name`. Report regression covers preferred event names, conflicting legacy names, four legacy fallbacks, and missing names. |
| 4. Tool latency | Aggregate duration series use seconds; span-search duration tables retain nanosecond units. Unit contracts pass. |
| 5. Slowest tool calls | Actual Grafana transformations use Tempo display names, sort duration numerically, then keep 20 rows. Synthetic cases cover missing optional fields, empty data, and Trace ID alignment/links. The old configuration reproduced incorrect sorting; its reported non-empty live `No data` state was not reproduced. |
| 6. Legends | Actual Grafana field override processing produces explicit names for 34 synthetic series and preserves model/tool labels. |
| 7. Failure colors | Actual Grafana display processing confirms zero is green, positive values are red, and missing values are neutral. |
| 8. Dashboard updates | An isolated pinned LGTM container loads an atomically replaced dashboard after a second `docker compose up -d`. Container ID and start time remain unchanged. The temporary container and network are removed afterward. |

## Synthetic snapshot

Project: `fixture://project`.
Period: `2026-09-04T07:00:00Z..2026-09-04T08:00:00Z`.

The report regression verifies input 100, cached input 40, non-cached input 60,
output 20, reasoning 5, and total 120 tokens. It identifies two distinct top-level
tool calls, one failure, and `read` at 3000 ms as the slowest tool. The completed
turn has two model rounds; the dashboard SQL matches this result at the same
project, period, and `as_of`. All fixture data is synthetic.

## Checks executed

- `docker compose config --quiet`: PASS.
- Dashboard JSON `ConvertFrom-Json`: PASS.
- PowerShell parser for every script in `scripts/`: PASS.
- `scripts/test-dashboard-contract.ps1`: PASS; 19 panels, `Project cwd`, refresh
  `10s`, Trace ID links, and query/display contracts preserved.
- `scripts/test-codex-performance-report.ps1`: PASS.
- `scripts/test-model-rounds.ps1`: PASS; five cases in the running Grafana SQL
  engine. This check only executes read-only synthetic queries.
- `node scripts/test-slowest-tool-calls.cjs`: PASS with `@grafana/data@13.2.0`.
- `node scripts/test-dashboard-presentation.cjs`: PASS with
  `@grafana/data@13.2.0`; 34 series names and zero/positive/missing colors.
- `scripts/test-dashboard-provisioning.ps1`: PASS against the pinned LGTM image
  in an isolated Compose project using temporary data, without changing the
  existing installation or its volumes.

## Known limits

- This release has no browser rendering verification or numeric parity check
  against non-empty live Codex telemetry. Synthetic regression and Grafana API /
  library checks are evidence for the tested contracts, not complete UI coverage.
- Model-round searches are bounded to 500 traces and 100 spans per span set.
  Tempo search limits and partial results can still affect completeness.
- New Compose mounts take effect on `docker compose up -d`; an existing LGTM
  may be recreated once when adopting this release. Subsequent dashboard JSON
  updates are polled within 30 seconds. Provisioning YAML changes still require
  recreating LGTM, as documented in the README.
- A genuinely in-flight span cannot be observed until exported. Codex span
  schemas may change and require query/fixture updates.
