# Project Manifest

This file is the policy boundary for humans and AI agents working in this repository. If another document conflicts with it, stop and ask the user before expanding scope.

## Supported scope

- Local Codex OTEL collection through the existing Collector and Grafana LGTM stack.
- Source-controlled Grafana dashboards and provisioning.
- Local JSON/Markdown performance reports.
- Small compatibility, correctness, privacy, and documentation improvements.

The project is local-development tooling. Do not describe it as production-ready or use it as a shared telemetry service without a separately authorized design.

## Security and privacy invariants

- Bind Grafana and OTLP endpoints to `127.0.0.1` by default.
- Keep `otel.log_user_prompt = false` in examples and defaults.
- Do not add outbound/cloud exporters, public ingress, remote access, or analytics.
- Do not store credentials or tokens in tracked files. Use environment variables only when a future authorized change requires secrets.
- Never commit Docker volumes, logs, traces, prompts, tool arguments/output, screenshots of real telemetry, account metadata, email addresses, or absolute user paths.
- Fixtures must be synthetic and contain no copied production or developer telemetry.
- Prefer bounded summaries and error classes over raw tool payloads in dashboards and reports.
- Do not automatically edit user-level Codex configuration; provide a documented snippet instead.
- Do not run `docker compose down -v`, `docker volume rm`, Docker prune commands, or equivalent destructive cleanup without explicit user authorization and an exact volume check.

## Licensing boundary

- Original files in this repository are licensed under Apache-2.0.
- Upstream images and bundled components retain their own licenses; see `THIRD_PARTY_NOTICES.md`.
- Do not copy or vendor Grafana, Loki, Tempo, Pyroscope, Prometheus, or OpenTelemetry Collector source code into this repository by default.
- Do not remove upstream copyright, license, attribution, image labels, or notices.
- A Compose reference to an upstream image does not relicense that image.
- Changes that redistribute modified AGPL components or expose a modified network service require a specific license review before release.
- Do not use OpenAI or Grafana logos, or wording that implies this is an official product.

## Operational boundary

- Keep the architecture to the two existing services unless the user authorizes more infrastructure.
- Pin image versions and review upstream release notes before changing them.
- Preserve the telemetry volume during routine stop/start and upgrades.
- Do not mutate an existing running installation merely to validate a repository change. Prefer static validation or an isolated, explicitly authorized smoke run.

## Release boundary

- Local commits are allowed for authorized repository work.
- GitHub remotes, pushes, releases, packages, and public images require an explicit user request.
- Before release, verify that Git history and tracked files contain no live telemetry or secrets.
