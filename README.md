# Codex OTEL Observability

Unofficial, local-first observability kit for Codex. It collects Codex OpenTelemetry data through a dedicated OpenTelemetry Collector and shows completed/active coverage, tokens, cache usage, model sampling, tool calls, failures, and Tempo traces in Grafana.

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

The example keeps raw user prompts disabled. It does not edit your Codex configuration automatically.

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

## Performance report

```powershell
.\scripts\codex-performance-report.ps1 -Project 'D:\your-project' -Period '6h' -Format json
.\scripts\codex-performance-report.ps1 -Project 'D:\your-project' -Period '24h' -Format markdown
.\scripts\codex-performance-report.ps1 -Project 'D:\your-project' -Period '6h' -AsOf '2026-09-04T08:00:00Z' -Format json
```

The report captures one UTC `as_of`, uses absolute query bounds, and does not
upload results. JSON schema `2.0` includes completed/active/incomplete coverage,
token semantics, per-model and per-tool breakdowns, bounded failures, and Trace IDs.

Run the synthetic regression fixture with:

```powershell
.\scripts\test-codex-performance-report.ps1
```

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

- When Tempo has no `span.cwd` values, the dashboard leaves KPI unset and shows
  `Project not selected` until a project becomes available.
- Active turns are inferred from recently exported scoped activity; a truly
  in-flight span is not visible until its exporter emits data.
- Tempo search is limit-bound. Partial/oversized results are warnings, not proof
  that all upstream trace data was returned.
- The dashboard depends on the telemetry schema emitted by the installed Codex version.

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
