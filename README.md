# Codex OTEL Observability

Unofficial, local-first observability kit for Codex. It collects Codex OpenTelemetry data through a dedicated OpenTelemetry Collector and shows turns, tokens, cache usage, model sampling, tool calls, failures, and Tempo traces in Grafana.

This repository is intended for developer workstations and small local experiments. It is not a production or shared-team observability platform.

## Architecture

```text
Codex -> OTLP/HTTP 127.0.0.1:4318 -> OTEL Collector -> Grafana LGTM
                                                   -> Grafana 127.0.0.1:3000
```

The two containers are managed as one Docker Compose project:

- `codex-otel-collector` receives and forwards logs, metrics, and traces.
- `codex-otel-lgtm` provides Grafana, Loki, Tempo, and the supporting local backends.

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

The example keeps raw user prompts disabled. It does not edit your Codex configuration automatically.

## Performance report

```powershell
.\scripts\codex-performance-report.ps1 -Project 'D:\your-project' -Period '6h' -Format json
.\scripts\codex-performance-report.ps1 -Project 'D:\your-project' -Period '24h' -Format markdown
```

The report queries the local Grafana datasources and does not upload results.

## Current v0.1 limitations

- Failure and nested tool-call deduplication is not final; treat those counts as diagnostic rather than billing-grade.
- Active turns and incomplete/oversized traces can affect short time ranges.
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
