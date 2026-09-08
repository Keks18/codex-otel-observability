[CmdletBinding()]
param([string]$CollectorImage = 'otel/opentelemetry-collector-contrib:0.159.0')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$artifactsRoot = Join-Path $repoRoot 'artifacts'
$null = New-Item -ItemType Directory -Path $artifactsRoot -Force
$testRoot = Join-Path $artifactsRoot ('collector-privacy-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$configPath = Join-Path $testRoot 'config.yaml'
$outputPath = Join-Path $testRoot 'output.json'
$containerName = 'codex-otel-privacy-' + [guid]::NewGuid().ToString('N')

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

try {
    $config = Get-Content -Raw (Join-Path $repoRoot 'config\otel-collector.yaml')
    $config = [regex]::Replace(
        $config,
        '(?m)^exporters:\s*$',
        "exporters:`r`n  file/test:`r`n    path: /tmp-test/output.json"
    )
    $config = $config.Replace('[otlp_http/lgtm]', '[file/test, otlp_http/lgtm]')
    $config = $config.Replace('endpoint: http://codex-otel-lgtm:4318', 'endpoint: http://127.0.0.1:1')
    Set-Content -LiteralPath $configPath -Value $config -Encoding UTF8

    $mount = ($testRoot -replace '\\', '/') + ':/tmp-test'
    $containerId = (& docker run -d --rm --name $containerName -p '127.0.0.1::4318' -p '127.0.0.1::8888' -v $mount $CollectorImage --config=/tmp-test/config.yaml).Trim()
    Assert-True ($LASTEXITCODE -eq 0 -and $containerId) 'Could not start isolated Collector privacy test.'

    $binding = (& docker port $containerName '4318/tcp').Trim()
    Assert-True ($LASTEXITCODE -eq 0 -and $binding -match ':(\d+)$') 'Could not resolve isolated Collector port.'
    $endpoint = 'http://127.0.0.1:' + $Matches[1] + '/v1/traces'
    $metricsBinding = (& docker port $containerName '8888/tcp').Trim()
    Assert-True ($LASTEXITCODE -eq 0 -and $metricsBinding -match ':(\d+)$') 'Could not resolve isolated Collector metrics port.'
    $metricsEndpoint = 'http://127.0.0.1:' + $Matches[1] + '/metrics'

    $sensitive = 'PRIVATE_SENTINEL'
    $payload = @{
        resourceSpans = @(@{
            resource = @{ attributes = @(
                @{ key = 'service.name'; value = @{ stringValue = 'privacy-fixture' } },
                @{ key = 'user.email'; value = @{ stringValue = $sensitive } }
            ) }
            scopeSpans = @(@{
                scope = @{ name = 'privacy-fixture' }
                spans = @(@{
                    traceId = '11111111111111111111111111111111'
                    spanId = '2222222222222222'
                    name = 'dispatch_tool_call_with_terminal_outcome'
                    kind = 1
                    startTimeUnixNano = '1788508200000000000'
                    endTimeUnixNano = '1788508201000000000'
                    attributes = @(
                        @{ key = 'cwd'; value = @{ stringValue = 'fixture://privacy' } },
                        @{ key = 'payload'; value = @{ stringValue = $sensitive } }
                    )
                    events = @(@{
                        timeUnixNano = '1788508200500000000'
                        name = 'tool_result'
                        attributes = @(
                            @{ key = 'tool_name'; value = @{ stringValue = 'shell' } },
                            @{ key = 'success'; value = @{ boolValue = $true } },
                            @{ key = 'output'; value = @{ stringValue = $sensitive } },
                            @{ key = 'tool_arguments'; value = @{ stringValue = $sensitive } },
                            @{ key = 'exception.message'; value = @{ stringValue = $sensitive } },
                            @{ key = 'user.email'; value = @{ stringValue = $sensitive } }
                        )
                    })
                })
            })
        })
    } | ConvertTo-Json -Depth 20 -Compress

    $sent = $false
    for ($attempt = 0; $attempt -lt 20 -and -not $sent; $attempt++) {
        try {
            $null = Invoke-RestMethod -Uri $endpoint -Method Post -ContentType 'application/json' -Body $payload
            $sent = $true
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }
    Assert-True $sent 'Isolated Collector did not accept the synthetic OTLP trace.'

    for ($attempt = 0; $attempt -lt 20 -and -not (Test-Path -LiteralPath $outputPath); $attempt++) {
        Start-Sleep -Milliseconds 250
    }
    Assert-True (Test-Path -LiteralPath $outputPath) 'Isolated Collector did not export the sanitized trace.'
    # The file exporter creates its target before the batch processor's 1s flush.
    # Wait past that boundary so file existence cannot be mistaken for delivery.
    Start-Sleep -Milliseconds 1500
    [string]$metrics = (Invoke-WebRequest -UseBasicParsing -Uri $metricsEndpoint).Content
    Assert-True ($metrics -match 'otelcol_exporter_queue_size' -and $metrics -match 'otelcol_exporter_queue_capacity') 'Collector queue metrics are not exposed for the private Prometheus scrape.'
    $null = & docker stop --time 5 $containerName
    Assert-True ($LASTEXITCODE -eq 0) 'Could not stop isolated Collector before reading its output.'
    [string]$exported = [IO.File]::ReadAllText($outputPath)
    Assert-True ($exported -match '11111111111111111111111111111111') 'Synthetic trace was not present in the isolated exporter output.'
    Assert-True ($exported -notmatch [regex]::Escape($sensitive)) 'Sensitive span, resource, or span-event value reached the exporter.'
    foreach ($privateKey in @('payload', 'output', 'tool_arguments', 'exception.message', 'user.email')) {
        Assert-True ($exported -notmatch ('"' + [regex]::Escape($privateKey) + '"')) "Sensitive key $privateKey reached the exporter."
    }
    Assert-True ($exported -match 'tool_name' -and $exported -match 'shell' -and $exported -match 'success') 'Safe tool event fields were removed with the private payload.'
    Assert-True ($exported -match 'fixture://privacy') 'Safe project scope was removed by privacy processing.'

    'collector span/resource/span-event privacy smoke: PASS'
} finally {
    $existing = & docker ps -aq --filter "name=^/$containerName$"
    if ($existing) { $null = & docker rm -f $containerName }
    $resolvedArtifacts = [IO.Path]::GetFullPath($artifactsRoot).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    $resolvedTest = [IO.Path]::GetFullPath($testRoot)
    if ($resolvedTest.StartsWith($resolvedArtifacts, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $resolvedTest)) {
        Remove-Item -LiteralPath $resolvedTest -Recurse -Force
    }
}
