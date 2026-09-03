# Third-party notices

This repository does not vendor the following projects. Docker Compose pulls their upstream images, and each project remains governed by its own license and notices.

## OpenTelemetry Collector

- Project: <https://github.com/open-telemetry/opentelemetry-collector>
- Image: `otel/opentelemetry-collector:0.159.0`
- License: Apache License 2.0

## Grafana Docker OTEL LGTM

- Project: <https://github.com/grafana/docker-otel-lgtm>
- Image: `grafana/otel-lgtm:0.32.0`
- Image project license: Apache License 2.0

The LGTM image bundles multiple upstream components, including Grafana, Loki, Tempo, Prometheus, Pyroscope, and an OpenTelemetry Collector. Those components retain their respective licenses. In particular, current Grafana, Loki, and Tempo releases are distributed under AGPL-3.0. Consult the image's source, SBOM, and bundled notices for the exact versions used by a release.

No license in this repository replaces or limits an upstream license. This notice is operational guidance, not legal advice.
