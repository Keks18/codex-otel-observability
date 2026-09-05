[CmdletBinding()]
param()

# Isolated smoke run using the repository's pinned LGTM image. No production
# containers or telemetry volumes are touched; /data lives on temporary tmpfs.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$testName = 'codex-otel-provisioning-test-' + [guid]::NewGuid().ToString('N').Substring(0, 12)
$testRoot = Join-Path $repoRoot "artifacts/$testName"
$dashboardDir = Join-Path $testRoot 'dashboards'
$dashboardPath = Join-Path $dashboardDir 'codex-overview.json'
$providerPath = Join-Path $testRoot 'dashboards.yaml'
$composePath = Join-Path $testRoot 'compose.json'
$null = New-Item -ItemType Directory -Path $dashboardDir -Force

function Invoke-Compose([string[]]$Arguments) {
    & docker compose -f $composePath @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Isolated Compose command failed: $Arguments" }
}
function Wait-Dashboard([string]$ExpectedDescription, [int]$TimeoutSeconds) {
    $deadline = [DateTimeOffset]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            $result = Invoke-RestMethod "$baseUrl/api/dashboards/uid/codex-overview" -TimeoutSec 5
            if ($result.dashboard.description -eq $ExpectedDescription) { return $result.dashboard }
        } catch { }
        Start-Sleep -Seconds 2
    } while ([DateTimeOffset]::UtcNow -lt $deadline)
    throw "Dashboard did not reach '$ExpectedDescription' within $TimeoutSeconds seconds."
}

$model = & docker compose -f (Join-Path $repoRoot 'compose.yaml') config --format json | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) { throw 'Repository Compose configuration is invalid.' }
$service = $model.services.lgtm
$service.container_name = $testName
$service.restart = 'no'
$service.ports[0].published = '0'
$service.networks = @{ observability = @{} }
$mounts = @()
foreach ($mount in $service.volumes) {
    if ($mount.target -eq '/data') { continue }
    if ($mount.target -eq '/otel-lgtm/grafana/conf/provisioning/dashboards/codex') {
        if (-not (Test-Path -LiteralPath $mount.source -PathType Container)) { throw 'Dashboards must be mounted as a directory.' }
        $mount.source = $dashboardDir
    } elseif ($mount.target -eq '/otel-lgtm/grafana/conf/provisioning/dashboards/codex.yaml') {
        Copy-Item -LiteralPath $mount.source -Destination $providerPath
        $mount.source = $providerPath
    } else { throw "Unexpected LGTM mount: $($mount.target)" }
    $mounts += $mount
}
$service.volumes = @($mounts) + @(@{type='tmpfs'; target='/data'; tmpfs=@{size=1073741824}})
$smoke = @{name=$testName; services=@{lgtm=$service}; networks=@{observability=@{name=$testName}}}
$smoke | ConvertTo-Json -Depth 25 | Set-Content -LiteralPath $composePath -Encoding UTF8
$dashboard = Get-Content -Raw (Join-Path $repoRoot 'grafana/dashboards/codex-overview.json') | ConvertFrom-Json
$dashboard | Add-Member -NotePropertyName description -NotePropertyValue 'Synthetic provisioning baseline' -Force
$dashboard | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $dashboardPath -Encoding UTF8

try {
    Invoke-Compose @('up','-d')
    $address = (Invoke-Compose @('port','lgtm','3000') | Out-String).Trim()
    if ($address -notmatch '^127\.0\.0\.1:\d+$') { throw 'Smoke port must remain bound to loopback.' }
    $baseUrl = 'http://' + $address
    "Waiting for isolated Grafana at $baseUrl"
    $initial = Wait-Dashboard 'Synthetic provisioning baseline' 240
    if ($initial.refresh -ne '10s' -or $initial.panels.Count -ne 19) { throw 'Initial dashboard contract changed.' }
    $containerBefore = (Invoke-Compose @('ps','-q','lgtm') | Out-String).Trim()
    $startedBefore = & docker inspect --format '{{.State.StartedAt}}' $containerBefore
    $dashboard.description = 'Synthetic provisioning updated without restart'
    $replacement = Join-Path $dashboardDir 'replacement.json.tmp'
    $dashboard | ConvertTo-Json -Depth 60 | Set-Content -LiteralPath $replacement -Encoding UTF8
    # Replace the inode, as Git/editors do, rather than writing the open file.
    [System.IO.File]::Replace($replacement, $dashboardPath, (Join-Path $testRoot 'baseline.bak'))
    Invoke-Compose @('up','-d')
    $updated = Wait-Dashboard 'Synthetic provisioning updated without restart' 75
    $containerAfter = (Invoke-Compose @('ps','-q','lgtm') | Out-String).Trim()
    $startedAfter = & docker inspect --format '{{.State.StartedAt}}' $containerAfter
    if ($containerBefore -ne $containerAfter -or $startedBefore -ne $startedAfter) { throw 'LGTM unexpectedly restarted during the dashboard update.' }
    if ($updated.refresh -ne '10s' -or $updated.panels.Count -ne 19) { throw 'Updated dashboard contract changed.' }
    'Provisioning: atomic file replacement + compose up -d + polling without restart PASS'
} finally {
    # Only the uniquely named test project is removed. No named volumes exist.
    Invoke-Compose @('down')
}
