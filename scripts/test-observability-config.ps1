[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$compose = Get-Content -Raw (Join-Path $repoRoot 'compose.yaml')
$collector = Get-Content -Raw (Join-Path $repoRoot 'config\otel-collector.yaml')
$tempo = Get-Content -Raw (Join-Path $repoRoot 'config\tempo.yaml')
$prometheus = Get-Content -Raw (Join-Path $repoRoot 'config\prometheus.yaml')
$readme = Get-Content -Raw (Join-Path $repoRoot 'README.md')
$notices = Get-Content -Raw (Join-Path $repoRoot 'THIRD_PARTY_NOTICES.md')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

Assert-True ($compose -match 'otel/opentelemetry-collector-contrib:0\.159\.0') 'Collector image must stay pinned to the transform-capable 0.159.0 contrib distribution.'
Assert-True ($compose -notmatch ':latest') 'Compose images must not use latest tags.'
Assert-True ($compose -match '"127\.0\.0\.1:3000:3000"' -and $compose -match '"127\.0\.0\.1:4318:4318"') 'Published ports must remain loopback-only.'
Assert-True ($compose -notmatch '(?m)^\s*-\s*["'']?(?:0\.0\.0\.0:)?8888:8888') 'Collector internal metrics must not be published to the host.'
Assert-True ($compose -match 'config/prometheus\.yaml:/otel-lgtm/prometheus\.yaml:ro') 'Prometheus configuration must remain mounted read-only.'

$limitMatch = [regex]::Match($tempo, 'max_bytes_per_trace:\s*(\d+)')
Assert-True $limitMatch.Success 'Tempo must declare an explicit per-trace size limit.'
$traceLimit = [int64]$limitMatch.Groups[1].Value
Assert-True ($traceLimit -eq 20000000 -and $traceLimit -lt 60000000) 'Tempo per-trace limit must retain the reviewed 20 MB cap below the documented 60 MB upper recommendation.'

Assert-True (([regex]::Matches($prometheus, 'scrape_interval:\s*15s')).Count -ge 3) 'Global and per-job Prometheus scrape intervals must remain 15 seconds.'
Assert-True ($prometheus -match 'targets:\s*\["127\.0\.0\.1:3200"\]') 'Prometheus must scrape Tempo locally inside LGTM.'
Assert-True ($prometheus -match 'targets:\s*\["codex-otel-collector:8888"\]') 'Prometheus must scrape Collector internal metrics over the private Compose network.'

Assert-True ($collector -match '(?s)memory_limiter:\s+check_interval:\s*1s\s+limit_mib:\s*512\s+spike_limit_mib:\s*128') 'Collector memory limiter contract drifted.'
foreach ($pipeline in @('logs', 'traces', 'metrics')) {
    $match = [regex]::Match($collector, "(?m)^    $pipeline`:\s*`r?`n      receivers:.*`r?`n      processors: \[(?<processors>[^\]]+)\]")
    Assert-True ($match.Success -and $match.Groups['processors'].Value.Trim().StartsWith('memory_limiter')) "memory_limiter must remain first in the $pipeline pipeline."
    Assert-True ($match.Groups['processors'].Value.Trim().EndsWith('batch')) "batch must remain last in the $pipeline pipeline."
}
Assert-True ($collector -match 'send_batch_size:\s*1024' -and $collector -match 'send_batch_max_size:\s*2048') 'Collector batch size must remain explicitly bounded.'
Assert-True ($collector -match '(?s)sending_queue:\s+enabled:\s*true\s+sizer:\s*items\s+queue_size:\s*8192\s+num_consumers:\s*4') 'Collector sending queue contract drifted.'
Assert-True ($collector -match '(?s)retry_on_failure:\s+enabled:\s*true\s+initial_interval:\s*1s\s+max_interval:\s*10s\s+max_elapsed_time:\s*1m') 'Collector retry contract drifted.'
Assert-True ($collector -match '(?s)transform/privacy_events:\s+.*error_mode:\s*propagate.*context:\s*spanevent\s+statements:.*delete_matching_keys\(spanevent\.attributes') 'Span-event attributes must be sanitized with a fail-closed explicit OTTL spanevent context and fully qualified paths.'
foreach ($sensitiveKey in @('tool_output', 'tool_arguments', 'exception\\.message', 'user_\(id\|name\|email\)')) {
    Assert-True ($collector -match $sensitiveKey) "Span-event privacy pattern is missing $sensitiveKey."
}
Assert-True ($collector -notmatch '(?m)^\s*debug(?:/[^:]+)?:') 'A debug exporter must not be permanent configuration.'
Assert-True ($collector -match '(?s)prometheus:\s+host:\s*0\.0\.0\.0\s+port:\s*8888') 'Collector internal metrics must be scrapeable only from its container network.'

Assert-True ($readme -match 'verbosity:\s*basic' -and $readme -match 'detailed') 'README must constrain temporary debug exporters to basic verbosity.'
Assert-True ($notices -match 'otel/opentelemetry-collector-contrib:0\.159\.0') 'Third-party notice must match the pinned Collector image.'

'observability configuration contract: PASS'
