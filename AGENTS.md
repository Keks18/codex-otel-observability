# AGENTS.md

## Purpose

This repository packages a local-first Codex OpenTelemetry dashboard and report. The priorities are metric correctness, privacy, reproducible startup, and a small maintainable configuration surface.

## Read first

1. `PROJECT_MANIFEST.md` — non-negotiable security, privacy, licensing, and release boundaries.
2. `README.md` — supported workflow and architecture.
3. `compose.yaml`, `config/otel-collector.yaml`, and the affected dashboard or script.

## Repository map

- `compose.yaml` — the complete two-container local stack.
- `config/` — OpenTelemetry Collector configuration.
- `grafana/` — dashboard JSON and file provisioning.
- `scripts/` — compact JSON/Markdown performance report.
- `examples/` — configuration snippets for manual user adoption.

## Working rules

- Work only inside this repository unless the user explicitly expands scope.
- Do not modify Codex, application repositories, user config, running containers, Docker volumes, or GitHub state without explicit authorization.
- Keep ports bound to `127.0.0.1`; do not add cloud exporters, authentication services, or other infrastructure by inference.
- Never commit telemetry data, traces, logs, prompts, tool payloads, credentials, local paths, or generated `graphify-out/` content.
- Treat provisioned dashboard JSON as the source of truth; do not leave changes only in the Grafana UI.
- Pin upstream image versions. Do not replace them with `latest`.
- Preserve `Project cwd`, the `10s` dashboard refresh, and Trace ID links unless the task explicitly changes them.
- Read files before editing, preserve unrelated work, and make the smallest compatible change.

## Minimum verification

From the repository root:

```powershell
docker compose config --quiet
Get-Content -Raw .\grafana\dashboards\codex-overview.json | ConvertFrom-Json | Out-Null
$tokens = $null
$parseErrors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path .\scripts\codex-performance-report.ps1), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw ($parseErrors | Out-String) }
```

For changes to queries or metric semantics, also compare dashboard and report results over the same fixed project, period, and `as_of` snapshot. Report exactly which checks ran; do not claim live or browser verification that was not performed.

For Collector, Tempo, Prometheus, queue/retry, or privacy changes, also run:

```powershell
.\scripts\test-observability-config.ps1
.\scripts\test-collector-privacy.ps1
```

The privacy smoke must use only synthetic telemetry and a disposable isolated
Collector. It must not write into the running LGTM stack or its volume.

## Git and releases

- Use semantic versions; `v0.x` means the metric contract may still change.
- Do not push, create a remote, publish an image, or create a GitHub release without an explicit user request.
- Review staged content for secrets and telemetry before every commit.
