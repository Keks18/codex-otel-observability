# Codex observability metric contract

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
- The canonical turn key is `trace_id`. If more than one
  `session_task.turn` span exists in a trace, the newest span is used and a
  `duplicate_turn_span` coverage warning is emitted.

## Completeness states

| State | Rule |
|---|---|
| `completed` | A canonical `session_task.turn` span is present and exposes the turn token-usage attributes. |
| `incomplete` | A turn span is present but required completion attributes are missing, or scoped trace activity is older than the active grace period and has no completed turn. |
| `active` | Scoped trace activity has no completed turn and its latest observed span falls inside the active grace period. This is an inference because an in-flight OTel span is not exported until it ends. |
| `oversized_or_partial` | Tempo reports a partial/oversized trace or the selected trace is missing expected root/turn data. It is excluded from completed-turn KPI and surfaced as a coverage warning. |

Only `completed` turns contribute to completed-turn KPI and breakdowns.
`active`, `incomplete`, and `oversized_or_partial` traces remain visible in the
coverage summary.

## KPI formulas

| KPI | Source and formula | Filtering and deduplication |
|---|---|---|
| Turns | `count(distinct trace_id)` of completed turns | Project-scoped, snapshot-bounded, one canonical turn per trace. |
| Duration | `avg(turn.duration_ms)`; per-row duration is the canonical turn span end minus start | Completed turns only. Child span durations are not added to turn duration. |
| Input tokens | `sum(input_tokens)` from canonical turn attributes | Completed turns only; never summed from nested sampling spans. |
| Cached input | `sum(cached_input_tokens)` | Cached input is a subset of input. |
| Non-cached input | `sum(max(input_tokens - cached_input_tokens, 0))` | Derived once per completed turn. |
| Output tokens | `sum(output_tokens)` | Completed turns only. |
| Reasoning tokens | `sum(reasoning_output_tokens)` | Reasoning is a subset of output and is never added to output again. |
| Total tokens | `sum(total_tokens)` when present, otherwise `sum(input_tokens + output_tokens)` | Completed turns only; the same per-turn values feed the Turns table and model breakdown. |
| Cache hit | `100 * sum(cached_input_tokens) / sum(input_tokens)` | Returns `0` when input is zero. It is not an average of per-turn percentages. |
| Model rounds | Count of `responses_websocket.stream_request` spans grouped by `trace_id` | Joined by trace ID to completed turns; no parent/descendant requirement. |
| Model sampling | Sum of `run_sampling_request` span durations grouped by `trace_id` | Joined by trace ID to completed turns. |
| Tool calls | Count of distinct terminal-outcome call keys grouped by `trace_id` | Only `dispatch_tool_call_with_terminal_outcome`; key is `call_id`, falling back to `span_id`. Nested implementation spans are excluded. |
| Tool failures | Distinct tool calls whose terminal outcome is unsuccessful | Same project scope and call keys as Tool calls. Retries/recovered attempts are annotations on one top-level call, not extra failures. |
| Other time | `max(turn_duration - model_sampling - tool_duration, 0)` per completed turn | Components are joined by trace ID. Overlap and instrumentation gaps are reported as coverage warnings. |

## Failure and tool fields

Failure rows expose only bounded diagnostic fields:

- `failure_class`: a stable class such as `approval_denied`, `timeout`,
  `tool_error`, `transport_error`, or `unknown`;
- `reason_summary`: a short, sanitized summary, never raw arguments/output;
- `nested`, `retry_count`, and `recovered`;
- `trace_id` with a Tempo data link.

Tool analytics are grouped by tool name and report `calls`, `failures`, `p50`,
`p95`, and `max` duration. Successful latency and failed-call counts stay
separate so a fast failure cannot appear as healthy performance.

The tool name is the span event attribute `event.tool_name`. Dashboard queries
select and group by that scope. The report prefers `event.tool_name`, with
legacy `tool_name`, `span.tool_name`, `codex.tool.name`, and
`span.codex.tool.name` columns as fallbacks; missing names remain `unknown`.

## Coverage warnings

The dashboard and report must surface, rather than silently discard:

- active/incomplete turns;
- duplicate turn spans or call IDs;
- rootless traces and missing turn spans;
- traces capped by query/span limits or reported partial/oversized by Tempo;
- component duration greater than turn duration;
- disagreement between trace-derived and structured-log-derived tool totals.

Each warning includes a machine-readable `code`, `count`, and short message.

## Privacy and cardinality

- `otel.log_user_prompt` remains `false`.
- Collector processors drop log records before Loki export (the pinned build
  cannot sanitize arbitrary log bodies) and remove raw prompt, arguments,
  payload, content, output, message, user identity, exception message, and
  stacktrace attributes from traces. Safe event/tool names, success, duration,
  call ID, trace ID, and error kind remain available.
- Dashboard queries never render raw tool arguments/output or user metadata.
- High-cardinality values are table fields or structured metadata, not dashboard
  group-by dimensions. No telemetry is exported outside the local two-container
  stack.

## Upstream basis and known limits

Codex documents structured `codex.tool_result` events and the
`turn.token_usage`/`tool.call` metric families. The current dashboard also uses
Codex trace span names that are not a stable public API; schema drift therefore
produces a coverage warning instead of silently changing the formulas.

Tempo search is limit-bound and can return partial traces. A clean result means
"no incompleteness observed within configured limits", not proof that upstream
storage contains no omitted trace.
