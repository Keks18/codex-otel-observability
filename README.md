# Codex OTEL Observability

Unofficial, local-first observability kit for Codex. It collects Codex OpenTelemetry data through a dedicated OpenTelemetry Collector and shows completed/failed/unclassified coverage, tokens, cache usage, model sampling, tool calls, failures, and Tempo traces in Grafana.

This repository is intended for developer workstations and small local experiments. It is not a production or shared-team observability platform.

## Architecture

```text
Codex -> OTLP/HTTP 127.0.0.1:4318 -> OTEL Collector -> Grafana LGTM
                                                   -> Grafana 127.0.0.1:3000
```

The two containers are managed as one Docker Compose project:

- `codex-otel-collector` receives all OTLP signals, drops log records for privacy,
  and forwards metrics and traces.
- `codex-otel-lgtm` provides Grafana, Loki, Tempo, and the supporting local backends.

For privacy, the Collector drops log records before export because the pinned
build cannot sanitize arbitrary log bodies. Dashboard and report diagnostics use
bounded trace attributes and never render raw prompts, tool arguments, or output.
The formulas and completeness rules are defined in [METRIC_CONTRACT.md](METRIC_CONTRACT.md).

## Requirements

- Docker Desktop with Docker Compose.
- Codex with OpenTelemetry export support.
- Windows PowerShell 5.1 or PowerShell 7 for `codex-performance-report`.

## Start

1. Review [PROJECT_MANIFEST.md](PROJECT_MANIFEST.md), especially the privacy rules.
2. Pull and start the pinned images:

   ```powershell
   docker compose pull
   docker compose up -d
   ```

3. Merge the relevant settings from [examples/codex-config.toml](examples/codex-config.toml) into the user-level Codex config and restart Codex. Do not put OTEL routing in a project-level `.codex/config.toml`.
4. Open `http://127.0.0.1:3000` and select **Codex / Codex Overview**.
5. Select **Project cwd**. Grafana discovers the exact `span.cwd` values stored in
   Tempo, automatically selects the first available project, and provides a list
   when more than one exists. Select an absolute Grafana time range when you need
   a stable `as_of` snapshot.

   Project discovery searches stored traces in the selected period (up to its
   last seven days), and reloads when that period changes. If a project has no
   recent activity, widen the period to include it. After startup, reload the
   page if it was opened before Tempo was ready. Discovery uses a dedicated
   provisioned Tempo metadata source; trace links and panel sources are unchanged.

   `Project cwd` is an exact scope. A Codex delegated task commonly runs from a
   separate worktree cwd, so a saved checkout and
   `.../worktrees/<task>/project` appear as distinct choices. They are not merged
   merely because their final directory names match.

   Trace and metric queries support ranges up to seven days. The local Tempo
   configuration allows one extra hour for query-boundary alignment; broader
   selections should be split into smaller periods.

The example keeps raw user prompts disabled. It does not edit your Codex configuration automatically.

The local Prometheus instance scrapes Tempo and the Collector every 15 seconds.
This preserves a bounded 15-day history of ingestion-quality and exporter-pressure
metrics. The **Tempo discarded spans / second** panel tracks the four actionable
discard reasons; **Collector exporter queue** shows queue occupancy and capacity.
These backend-health panels are stack-wide because Tempo and Collector counters
do not contain `Project cwd`.

Tempo uses an explicit 20,000,000-byte per-trace cap. This is enough for the
observed approximately 15.1 MB Codex trace with modest headroom, while staying
well below [Tempo's documented 60 MB upper recommendation](https://grafana.com/docs/tempo/latest/troubleshooting/out-of-memory-errors/).
The cap is still [enforced asynchronously](https://grafana.com/docs/tempo/latest/operations/manage-trace-ingestion/)
and an oversized trace can be partially dropped. Treat large traces as an
instrumentation problem first: reduce repeated spans and payload-heavy
attributes before considering another limit increase.

Useful Prometheus queries are:

```promql
sum by (reason) (rate(tempo_discarded_spans_total{reason=~"trace_too_large|trace_too_large_to_compact|live_traces_exceeded|rate_limited"}[5m]))
sum(otelcol_exporter_queue_size{job="otel-collector"})
sum(otelcol_exporter_queue_capacity{job="otel-collector"})
sum(rate(otelcol_exporter_enqueue_failed_spans_total{job="otel-collector"}[5m]))
sum(rate(otelcol_exporter_send_failed_spans_total{job="otel-collector"}[5m]))
```

The scrape is local-only and does not export metrics outside the Compose stack.

## Collector resilience and privacy

Following the [Collector processor-order guidance](https://github.com/open-telemetry/opentelemetry-collector/blob/main/processor/README.md),
`memory_limiter` is first in every pipeline. The batch processor flushes at
1,024 items and never sends more than 2,048 items in one batch. The local OTLP
exporter has an 8,192-item in-memory queue, four consumers, bounded one-minute
retry, and a ten-second attempt timeout. Queueing is intentionally not persistent:
routine restarts do not write telemetry into a new repository mount. See the
[Collector resiliency guide](https://opentelemetry.io/docs/collector/resiliency/)
for queue and retry failure modes.

Trace privacy covers resource, span, and span-event attributes. The
`attributes` and `resource` processors remove sensitive record attributes; an
OTTL [`spanevent` transform](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/main/pkg/ottl/contexts/ottlspanevent/README.md)
removes the same payload, identity, and exception fields from events while
retaining bounded analytics fields such as `tool_name`
and `success`. The event transform is fail-closed: a transform error drops the
affected batch instead of exporting an unsanitized event. Logs remain dropped
before export, and metric record attributes use the same sensitive-key policy.

There is no permanent debug exporter. If temporary diagnostics are required,
place it after all privacy processors and use only:

```yaml
debug/temporary:
  verbosity: basic
```

[`verbosity: detailed`](https://github.com/open-telemetry/opentelemetry-collector/blob/main/exporter/debugexporter/README.md)
can print telemetry contents and must not be used with real Codex data. Remove
the exporter and its pipeline references after the check.

## Update the dashboard

After pulling repository updates, run `docker compose up -d`. Compose applies
changed service mounts automatically. Dashboard JSON files are mounted as a
directory, so replacements made by Git or an editor remain visible inside LGTM.
Grafana polls that directory every 30 seconds; allow up to 30 seconds for the
provisioned dashboard to update, then reload its browser page. Its data refresh
remains `10s`.

Changes to the provisioning YAML itself are read at Grafana startup; when only
that file changes, run `docker compose up -d --no-deps --force-recreate lgtm`.
This preserves the named telemetry volume and leaves the Collector running.

The optional provisioning smoke test starts a uniquely named temporary LGTM
container on a random loopback port, replaces a synthetic dashboard file, runs
`compose up -d` again, and verifies the update without a container restart. It
removes its test container/network and never mounts the telemetry volume:

```powershell
.\scripts\test-dashboard-provisioning.ps1
```

## Regular turns and terminal outcomes

Regular turns do not need a `session_task.turn` span when they carry the explicit
terminal signal described in [METRIC_CONTRACT.md](METRIC_CONTRACT.md). Completion
and token coverage are independent: a completed turn with no usage is counted,
with a warning. Failed and unclassified traces appear separately in **Turns** and
**Turn status and coverage**. No outcome is inferred from trace age.

Stock Codex telemetry may not include this signal. If your integration captures
an app-server `turn/completed` notification and knows its original trace ID,
convert it to a bounded OTLP span with:

```powershell
$terminalPayload = .\scripts\convert-codex-turn-terminal.ps1 `
  -NotificationPath .\artifacts\turn-completed.json `
  -TraceId '<original 32-hex trace ID>' -Project 'D:\your-project'
# Optional adoption step: send only the converted allowlisted payload locally.
Invoke-RestMethod -Uri 'http://127.0.0.1:4318/v1/traces' -Method Post `
  -ContentType 'application/json' -Body $terminalPayload
```

The converter does not invoke Codex or send anything automatically. Never
substitute a turn UUID for its trace ID. Without authoritative correlation,
leave the trace unclassified. Never commit the notification or generated payload.
Existing installations are not modified by these repository changes.

A successful synthetic marker proves the Collector-to-Tempo terminal contract;
it does not prove that stock Codex instrumentation emitted a terminal signal.
Real traces without `codex.turn.terminal` or legacy token-bearing
`session_task.turn` completion remain unclassified. Only the versioned
`codex.turn.terminal` contract is called explicit completion.
Fixing the stock emitter requires an upstream Codex instrumentation change or a
separately deployed, authoritative app-server integration that preserves the
original trace ID; this repository does not infer completion from unrelated spans.

Run the synthetic acceptance snapshot (2 completed, 1 failed/unclassified,
33 tool calls, 2 dispatch failures), including actual Grafana SQL comparisons:

```powershell
.\scripts\test-regular-turns.ps1
# Report/converter-only checks when Grafana is unavailable:
.\scripts\test-regular-turns.ps1 -SkipGrafana
```

Validate the operational configuration and run the isolated synthetic privacy
smoke test with:

```powershell
.\scripts\test-observability-config.ps1
.\scripts\test-collector-privacy.ps1
```

The privacy test starts a disposable Collector container on a random loopback
port, verifies that sensitive span/resource/event fields are removed while safe
tool fields survive, confirms queue metrics are exposed, and then deletes only
its generated `artifacts/` subdirectory. Its retry target is an unused loopback
port; the synthetic trace is never sent to the running LGTM stack or the network.

## Performance report

```powershell
.\scripts\codex-performance-report.ps1 -Project 'D:\your-project' -Period '6h' -Format json
.\scripts\codex-performance-report.ps1 -Project 'D:\your-project' -Period '24h' -Format markdown
.\scripts\codex-performance-report.ps1 -Project 'D:\your-project' -Period '6h' -AsOf '2026-09-04T08:00:00Z' -Format json
```

The report captures one UTC `as_of`, uses absolute query bounds, and does not
upload results. JSON schema `4.0` separates explicit/legacy/missing completion,
dispatch failures, process-outcome coverage, and the combined failure rate.
When any recognized shell command lacks safe exit outcome telemetry, process and
combined failure rates are null rather than a healthy zero; the observable
dispatch failure rate remains separate. Hydrated turns include span-count and
HTTP JSON payload-byte diagnostics plus a non-overlapping interval union for the
wall-clock breakdown. Cumulative component durations remain explicitly
non-additive. JSON payload bytes are not Tempo's internal per-trace byte units.

## Upstream instrumentation gaps

Authoritative delegated-task metrics require Codex to export, on the original
trace, `codex.turn.terminal`, `codex.turn.status`, and
`codex.turn.signal_version`; a stable user-visible-turn versus
orchestration/setup discriminator; safe `process.exit_code` and
`process.success` for shell commands; and stable `project.root` or repository
identity shared by a checkout and its worktrees.

The Collector deliberately does not synthesize these fields from tool output,
model names, short durations, span counts, or directory names. Until upstream
instrumentation supplies them, the dashboard and report show legacy, partial,
missing, or unavailable coverage explicitly.

Run the synthetic regression fixture with:

```powershell
.\scripts\test-codex-performance-report.ps1
```

Compare lifecycle and tool KPI against the report on one immutable snapshot:

```powershell
.\scripts\test-live-snapshot.ps1 -Project 'D:\your-project' -Period '7d' -AsOf '2026-09-07T18:20:00Z'
```

This read-only test writes no telemetry files and fails on numeric disagreement.

With Grafana running, verify the **Model rounds / turn** panel's SQL against
synthetic data and the report's fixed snapshot (read-only, no telemetry writes):

```powershell
.\scripts\test-model-rounds.ps1
```

To test **Slowest tool calls** transformations against Grafana's library with
synthetic span frames, install the optional Node.js test dependencies locally
under the ignored `artifacts/` directory:

```powershell
npm install --prefix artifacts/grafana-transform-check --cache artifacts/npm-cache --ignore-scripts --no-audit --no-fund @grafana/data@13.2.0 rxjs@7.8.2
node scripts/test-slowest-tool-calls.cjs
node scripts/test-dashboard-presentation.cjs
```

## Current v0.2 limitations

- The report reads complete discovered activity traces, which is slower than
  searching span previews. Trace discovery remains limit-bound; table previews
  may omit events from long traces even below the per-trace search limit.
- When Tempo has no `span.cwd` values, the dashboard leaves KPI unset and shows
  `Project not selected` until a project becomes available.
- A trace without an explicit terminal signal or legacy completion evidence is
  unclassified, even when old. `missing_turn_or_root` appears in the dashboard.
  A truly in-flight span is not visible until its exporter emits data.
- Tempo search is limit-bound. Partial/oversized results are warnings, not proof
  that all upstream trace data was returned.
- The dashboard depends on the telemetry schema emitted by the installed Codex version.
- Without a stable upstream turn-role discriminator, orchestration/setup traces
  remain visible as turns and are accompanied by a coverage warning.
- Shell command failure rate is unavailable when safe process outcomes are not
  exported, even if dispatch delivery has `event.success=true`.

## Existing local installation

The Compose project deliberately reuses the current names `codex-otel-lgtm`, `codex-otel-collector`, `codex-observability`, and `codex-otel-lgtm-data`. If containers with those names are already running, review the migration before starting this Compose project. Keep the named volume to preserve history; never use `docker compose down -v` unless permanent data deletion is explicitly intended.

## Stop

```powershell
docker compose down
```

This keeps the telemetry volume. The project binds Grafana and OTLP only to loopback by default.

## Sources and licenses

Codex OTEL configuration is documented in the [official OpenAI documentation](https://learn.chatgpt.com/docs/config-file/config-advanced#observability-and-telemetry). The runtime uses upstream Grafana LGTM and OpenTelemetry Collector images; their licenses remain unchanged and are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

This project is not affiliated with or endorsed by OpenAI or Grafana Labs.
