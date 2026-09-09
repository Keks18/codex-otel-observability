# Codex observability metric contract

Contract/report schema: `5.0`.

This contract is the source of truth for the provisioned dashboard and
`scripts/codex-performance-report.ps1`. The implementation is diagnostic, not
billing-grade. Every aggregate is scoped to one project and one immutable time
window.

## Snapshot and project scope

- `as_of` is the inclusive upper bound of the snapshot. `from` is exactly
  `as_of - period`. The report captures `as_of` once before issuing any query.
- In Grafana, the dashboard time-picker `to` value is `as_of`. Use an absolute
  time range when a repeatable snapshot is required. Auto-refresh remains `10s`;
  an absolute range is therefore re-queried without moving the snapshot.
- A trace belongs to a project only when it contains a span whose `span.cwd`
  equals the selected `Project cwd`. Related spans and log events are joined to
  the project through the same `trace_id`; they are not required to repeat cwd.
- Project scope is exact and case-sensitive. A Codex worktree such as
  `fixture://worktrees/task/project` is a different scope from
  `fixture://project`. The dashboard and report never merge paths by basename.
  A future stable repository identity may allow an explicit aggregate view, but
  directory-name similarity is not evidence that two cwd values are one project.
- The canonical turn key is `trace_id`. If more than one
  lifecycle/token span exists in a trace, explicit failure takes precedence,
  followed by explicit completion, followed by legacy completion. The newest
  row within that class is used. Token usage is selected once, never summed
  across duplicate spans; `duplicate_turn_span` warns about multiple candidates.

## Turn status and token coverage

| Turn state | Rule |
|---|---|
| `completed` | An **explicit completed turn** is only `codex.turn.terminal` with supported `codex.turn.signal_version` and `codex.turn.status=completed`, independent of token fields. A **legacy completed turn** is a token-bearing `session_task.turn`; it remains visible but emits `legacy_completion_signal` and is never called explicit. |
| `failed` | A supported `codex.turn.terminal` says `failed` or `interrupted`. This wins over any completed/legacy candidate in the same trace; contradictory signals emit `conflicting_terminal_signals`. A failed tool or model request alone does not prove turn failure. |
| `unclassified` | Scoped exported activity exists, but neither recognized terminal signal nor legacy completion is available. Emit `missing_turn_or_root` for every such trace, regardless of its age. |

`completionSignals` reports three independent coverage counts: `explicit` for a
supported terminal marker, `legacy` for token-bearing `session_task.turn` traces
without a supported terminal marker, and `missing` when neither is available.
Without a stable upstream user-visible/orchestration discriminator, every
completed trace remains in Turns and `turn_role_unavailable` is emitted. Short
duration, model name, span count, and directory name are not valid filters.

`active` and `incomplete` age buckets are removed. An exported span
ending, a root being present, or the passage of time is not evidence of successful
turn completion. `failedTurns` and `unclassifiedTurns` remain separate in JSON;
`failedOrUnclassifiedTurns` is their sum in the dashboard coverage panel.

Token coverage is a separate axis. `tokenUsageStatus=available` means total usage
exists, or both input and output exist; it does not imply all optional token
fields exist. A completed turn without either emits
`completed_without_token_usage`, remains in the completed count/duration/rounds,
and has null token fields. Token sums use observed values only; no observed value
means null, not measured zero. Aggregate token coverage is `missing`, `partial`,
or `available`. Unknown input/cache fields produce a null cache percentage.

Partial/oversized/query-limit warnings are a third, independent coverage axis.
They do not automatically turn a known failed/completed outcome into another
status. `turnStates` includes every observed trace and both status axes; `turns`
contains completed-turn performance details.

## Explicit terminal signal v1

The local normalized span is `codex.turn.terminal` with:

- the original 32-hex `trace_id` of the turn (never generated from a turn UUID);
- exact `cwd`, used by `Project cwd`, or another span in that trace with exact cwd;
- integer `codex.turn.signal_version=1`;
- string `codex.turn.status`: `completed`, `failed`, or `interrupted`;
- explicit start/end timestamps from the lifecycle source.

An attribute on `session_task.turn` is not promoted to this explicit contract.
Unknown marker versions/statuses remain unclassified unless the trace separately
has legacy token-bearing completion evidence.

`convert-codex-turn-terminal.ps1` converts an app-server `turn/completed`
notification into this minimal OTLP payload. The caller must provide the actual
trace ID correlation and exact cwd. It rejects nonterminal or contradictory
notifications and missing timestamps, uses a deterministic span ID for retries,
and copies no items, messages, thread identity or error text. It writes JSON to
stdout and does not send telemetry or modify Codex settings. Notification
timestamps have the precision supplied by the source (currently seconds).

The upstream [Turn type](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/typescript/v2/Turn.ts)
and [TurnStatus](https://github.com/openai/codex/blob/main/codex-rs/app-server-protocol/schema/typescript/v2/TurnStatus.ts)
provide explicit outcome and timestamps; the app-server notification does not
supply trace correlation. That must be retained by the invoking integration.
The [regular task](https://github.com/openai/codex/blob/main/codex-rs/core/src/tasks/regular.rs)
can finish with a terminal error, so its span ending is insufficient evidence.

Existing historical traces without a terminal signal cannot be reclassified as
completed by a dashboard change alone. They remain visible as unclassified until
an authoritative, correctly correlated lifecycle signal is available. No raw
Loki logs are enabled or scraped to manufacture that evidence.

## Optional agent execution lifecycle v1

Multi-agent execution is opt-in. The normalized lifecycle span is
`codex.agent.lifecycle` and has integer `codex.agent.signal_version=1`.
Unsupported versions and missing required fields are unknown; they must not be
coerced into this contract.

Each lifecycle record carries an opaque, trace-local
`codex.agent.instance_id`. Opaque IDs, bounded role/kind, and reasoning effort
are ASCII enum-like tokens (`A-Z`, `a-z`, `0-9`, `.`, `_`, `:`, `-`) of at most
96 characters; the report suppresses invalid values with a coverage warning.
It may additionally carry opaque
`codex.agent.parent_instance_id` and `codex.agent.delegation_id`, non-negative
`codex.agent.delegation_depth`, and one bounded `codex.agent.role` or
`codex.agent.task_kind`. The only lifecycle values are `spawn`, `start`,
`wait`, `join`, and `complete` in `codex.agent.lifecycle`. A `complete` record
has explicit `codex.agent.status` of `completed`, `failed`, or `interrupted`.
`model` and `codex.agent.reasoning_effort` are optional bounded fields.

The canonical agent key is `(trace_id, codex.agent.instance_id)`. Parent lookup,
depth validation, delegation counting, tool/model attribution, cycles, sorting,
and output rows use that composite key. The same opaque ID in another trace is
a different agent and must never be merged.

The authoritative timing lifecycle starts at the earliest supported `spawn` span
start and ends at the end of the selected supported `complete` span. A record
whose `codex.agent.interval_kind` is `active` or `wait` contributes its clipped
span interval to the corresponding wall-clock union. All clipping, union,
overlap, and gap comparisons use original nanoseconds before output values are
rounded. Overlapping intervals are unified, never summed within the same kind.
Wait share is derived from the unrounded nanosecond union durations; rounded
millisecond display fields are never fed back into that ratio.
`available` timing requires at least one classified interval and a combined
active/wait union that completely covers those lifecycle bounds. A gap, overlap
between active and wait unions, invalid interval, or interval outside the bounds
is contradictory: emit one `agent_timing_inconsistent` warning per affected
canonical agent, mark timing partial, and leave the per-agent and aggregate wait
share null. `uncoveredWallClockMs` is zero only for measured complete coverage,
positive for a measured gap, and null when timing is unavailable because bounds
or classified intervals are missing. A non-empty unsupported interval kind is
malformed timing evidence: it contributes no active/wait time and, when lifecycle
bounds exist, makes timing partial; it is not guessed to be one or the other.
Aggregate timing is available only when every canonical
agent has available timing; otherwise its totals and wait share are null. Tool-owned spans may repeat the opaque agent ID and may include
the existing safe process outcome, retry/recovery, `failure_class`, bounded
`reason_summary`, and `error.kind` fields.

Optional outcomes preserve unknown values. `recovered` is null when no
attributed canonical call exports it; it is false only for explicit false
telemetry and true when an observed canonical call says true. Retry and process
fields use the same unknown-preserving rule.

`codex.project.identity` is an optional opaque stable repository/project
identity, shared by a checkout and its worktrees. It is not an absolute path
and does not replace exact `span.cwd`: **Project cwd remains the dashboard and
report scope**. The Collector does not synthesize project identity from a cwd
basename or any path similarity.

The report validates, but never repairs, this topology. Duplicate spawn IDs,
orphan/self/cyclic or inconsistent parents, inconsistent depth, unsupported
versions, missing terminal outcomes, unattributed tool/model activity, and bad
active/wait intervals are machine-readable coverage warnings. A clean `available`
result requires observed v1 records and no such warnings; `partial` means
some contract evidence is malformed or incomplete; `unavailable` means no
agent contract evidence was exported. No ASCII tree is emitted for partial or
cyclic topology.

Agent IDs, delegation IDs, trace IDs, and project identity are high-cardinality
diagnostic fields. They occur only in bounded report/dashboard rows and Tempo
links; they must never become Prometheus labels or unbounded dashboard grouping
dimensions. This contract excludes thread IDs, turn IDs, prompts, task text,
tool arguments/output, account identity, and machine identity. It never derives
agent identity, parentage, role, status, completion, timing, or project identity
from span parentage, ordering, duration, model name, trace age, raw thread/turn
IDs, or directory names.

## KPI formulas

| KPI | Source and formula | Filtering and deduplication |
|---|---|---|
| Turns | `count(distinct trace_id)` of completed turns | Project-scoped, snapshot-bounded, one canonical turn per trace. |
| Duration | `avg(turn.duration_ms)`; per-row duration is the selected completed lifecycle span end minus start | Completed turns only. Child span durations are not added to turn duration. |
| Input tokens | `sum(input_tokens)` from canonical turn attributes | Completed turns only; never summed from nested sampling spans. |
| Cached input | `sum(cached_input_tokens)` | Cached input is a subset of input. |
| Non-cached input | `sum(max(input_tokens - cached_input_tokens, 0))` | Derived once per completed turn. |
| Output tokens | `sum(output_tokens)` | Completed turns only. |
| Reasoning tokens | `sum(reasoning_output_tokens)` | Reasoning is a subset of output and is never added to output again. |
| Total tokens | `sum(total_tokens)` when present, otherwise `sum(input_tokens + output_tokens)` | Completed turns only; the report uses the same per-turn values for its detail and model breakdown. |
| Cache hit | `100 * sum(cached_input_tokens) / sum(input_tokens)` | Returns `0` for observed zero input and null for missing input/cache. It is not an average of per-turn percentages. |
| Model rounds | Count of `responses_websocket.stream_request` spans grouped by `trace_id` | Joined by trace ID to completed turns; no parent/descendant requirement. |
| Model sampling cumulative | Sum of `run_sampling_request` span durations grouped by `trace_id` | Joined by trace ID to completed turns. This is cumulative span time and may overlap tool time. |
| Tool calls | Count of distinct terminal-outcome call keys grouped by `trace_id` | Only `dispatch_tool_call_with_terminal_outcome`; key is `call_id`, falling back to `span_id`. Nested implementation spans are excluded. |
| Tool dispatch failures | Distinct tool calls whose terminal dispatch outcome has `event.success=false` | This measures the tool invocation/result-delivery failure reflected by Codex telemetry. It does not prove the exit status of a delivered shell command. |
| Process failures | Non-zero safe `process.exit_code`, or `process.success=false`, on recognized shell/exec calls | The rate is null unless every recognized command call has a safe outcome. Missing outcomes produce `process_outcome_coverage_incomplete`. |
| Combined tool failure rate | Distinct calls failed by dispatch or process outcome divided by all terminal calls | Null when command outcome coverage is partial or unavailable; it must never appear as a healthy zero in that state. `dispatchFailureRatePct` remains separately observable. |
| Component wall-clock | Union of clipped sampling and tool intervals inside the completed turn interval | Calculated only from hydrated traces. `observedComponentWallClockMs + otherMs = durationMs`, with `otherMs >= 0`. |

`modelSamplingCumulativeMs` and `toolCumulativeDurationMs` are non-additive span
sums. `modelSamplingWallClockMs`, `toolWallClockMs`, and
`observedComponentWallClockMs` are interval unions; sampling/tool unions may
still overlap each other, exposed as `samplingToolOverlapMs`. The dashboard does
not hydrate complete traces, so it labels its values cumulative and does not
manufacture an `other` value.

## Failure and tool fields

Failure rows expose only bounded diagnostic fields:

- `failure_class`: a stable class such as `approval_denied`, `timeout`,
  `tool_error`, `transport_error`, or `unknown`;
- `reason_summary`: a short, sanitized summary, never raw arguments/output;
- `nested`, `retry_count`, and `recovered`;
- `trace_id` with a Tempo data link.

Tool analytics are grouped by tool name and report `calls`, `dispatchFailures`, `p50`,
`p95`, and `max` duration. Successful latency and failed-call counts stay
separate so a fast failure cannot appear as healthy performance.

The tool name is the span event attribute `event.tool_name`. Dashboard queries
select and group by that scope. The report prefers `event.tool_name`, with
legacy `tool_name`, `span.tool_name`, `codex.tool.name`, and
`span.codex.tool.name` columns as fallbacks; missing names remain `unknown`.

Duration units depend on the query type: TraceQL metrics over `span:duration`
return seconds, so **Tool latency by tool** uses Grafana's `s` unit without
rescaling the values. Tempo search table `duration` values are nanoseconds;
the report converts those to milliseconds for its `*DurationMs` fields.

## Coverage warnings

The dashboard and report must surface, rather than silently discard:

- failed/unclassified turns and completed turns without token usage;
- duplicate turn spans or call IDs;
- rootless traces and missing turn spans;
- traces capped by query/span limits or reported partial/oversized by Tempo;
- component duration greater than turn duration;
- sampling/tool overlap and search-preview time coverage;
- missing safe process outcomes, which makes process and combined failure rates unavailable;
- inability to distinguish user-visible turns from orchestration/setup traces;
- large hydrated JSON responses and span amplification (`hydratedSpanCount`,
  `hydratedPayloadBytes`, and hydration timing are diagnostics only; JSON bytes
  are not Tempo's internal per-trace accounting and are never compared as
  equivalent units). The report warns at 10,000 spans or 15,000,000 HTTP JSON
  bytes per trace;
- agent-contract unavailable/partial coverage, malformed topology, missing
  agent outcomes, unattributed activity, and inconsistent timing;
- disagreement between trace-derived and structured-log-derived tool totals.

Each warning includes a machine-readable `code`, `count`, and short message.

## Privacy and cardinality

- `otel.log_user_prompt` remains `false`.
- Collector processors drop log records before Loki export (the pinned build
  cannot sanitize arbitrary log bodies) and remove raw prompt, arguments,
  payload, content, output, message, user identity, exception message, and
  stacktrace attributes from trace resources, spans, and span events. Event
  sanitization uses an explicit OTTL `spanevent` context. Safe event/tool names,
  success, duration, call ID, trace ID, and error kind remain available.
- Dashboard queries never render raw tool arguments/output or user metadata.
- High-cardinality values are table fields or structured metadata, not dashboard
  group-by dimensions. No telemetry is exported outside the local two-container
  stack.

## Upstream basis and known limits

Completed turns, average duration, rounds, the Turns table, time breakdown and
status coverage share a Trace-ID SQL classification over bounded Tempo searches.
Their failure precedence and missing-token rules agree with the report.
Tool/token metric KPI use range queries with a two-minute step and sum all
returned buckets; cache hit divides cached/input sums, never bucket averages.
The legacy token/model metric charts remain span-based projections of available
lifecycle usage, while canonical report totals deduplicate by trace and resolve
conflicting terminal signals. Duplicate or conflicting lifecycle spans therefore
require the report for canonical token totals; the status KPI do not double-count
those traces. Missing-token counts are always visible beside the KPI.
The pinned Tempo instant query path can omit a stored turn that the range path
returns. Metric exemplars are disabled in Tempo because the bundled datasource
can return annotation frames even when the query requests zero exemplars.

The report uses span searches only to discover activity trace IDs, then reads
each discovered trace once and counts unique terminal-call keys from complete
trace contents. Activity spans are bounded by their start timestamp, inclusive
of `from` and `as_of`, and their end must not be after `as_of`. A lifecycle
completion after `as_of` is never borrowed from a later full-trace response.
Duplicate span IDs are discarded before call-key dedup.
An unavailable full trace fails the report rather than silently falling back
to incomplete search previews. This recovers events split across stored blocks;
it cannot recover traces omitted entirely by search limits.

## Desired upstream Codex instrumentation

For fully authoritative delegated-task metrics, Codex should export a minimal,
bounded contract on the original trace:

- `codex.turn.terminal` with `codex.turn.status` and
  `codex.turn.signal_version`;
- a stable user-visible-turn versus orchestration/setup discriminator;
- safe `process.exit_code` and `process.success` for shell commands;
- stable `project.root` or repository identity shared by a saved checkout and
  its Codex worktrees.

For agent execution analysis it additionally needs the optional
`codex.agent.lifecycle` v1 contract above: trace-local agent/delegation identity,
explicit lifecycle and terminal status, bounded role/kind, interval kind, and
safe ownership on tool/model spans. The report does not reconstruct these fields
when stock instrumentation omits them.

The Collector must not synthesize any of these from command output text, model
name, short duration, span count, or the final directory name. Until the emitter
provides them, the repository reports legacy/partial/unavailable coverage.

Codex documents structured `codex.tool_result` events and the
`turn.token_usage`/`tool.call` metric families. The current dashboard also uses
Codex trace span names that are not a stable public API; schema drift therefore
produces a coverage warning instead of silently changing the formulas.

Tempo search is limit-bound and can return partial traces. A clean result means
"no incompleteness observed within configured limits", not proof that upstream
storage contains no omitted trace.

Tempo and Collector health counters are stack-wide rather than project-scoped.
Prometheus retains the reason dimension for `tempo_discarded_spans_total` and
scrapes Collector exporter queue/failure metrics. The dashboard monitors the
reviewed Tempo discard reasons plus exporter queue occupancy/capacity; the
README contains failure-rate PromQL for operational diagnosis.

## Fixed regression snapshot

Synthetic project `fixture://regular`, `from=2026-09-04T07:00:00Z`,
`as_of=2026-09-04T08:00:00Z`: **2 completed, 1 failed/unclassified, 33 tool calls,
2 dispatch failures**. There is no `session_task.turn` in this fixture and both
completed turns lack token usage. In the baseline the third trace is
unclassified; an added explicit failed signal classifies it as failed without
changing tool totals. The test runs the dashboard's actual lifecycle SQL in
Grafana over the same synthetic rows and compares it with the hydrated report.
It also covers failure precedence, future terminal timestamps, unchanged outcomes
as traces age, exact project scoping, payload exclusion, and converter idempotency.
