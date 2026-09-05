[CmdletBinding()]
param([string]$GrafanaBaseUrl = 'http://127.0.0.1:3000')

# Read-only integration check: execute the dashboard's actual SQL against
# synthetic CTE tables. No traces, dashboards, or data sources are written.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$dashboard = Get-Content -Raw (Join-Path $repoRoot 'grafana/dashboards/codex-overview.json') | ConvertFrom-Json
$panel = @($dashboard.panels | Where-Object id -eq 11)[0]
$expression = @($panel.targets | Where-Object refId -eq 'C')[0].expression
$asOf = '2026-09-04T08:00:00Z'
$end = [DateTimeOffset]::Parse($asOf)

function ConvertTo-SqlRows($Rows) {
    if (@($Rows).Count -eq 0) {
        return "SELECT CAST(NULL AS CHAR) AS traceIdHidden, CAST(NULL AS DATETIME) AS time WHERE 1 = 0"
    }
    (@($Rows | ForEach-Object {
        $trace = ([string]$_.trace).Replace("'", "''")
        $time = [DateTimeOffset]::FromUnixTimeMilliseconds([long]$_.time).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss.fff', [Globalization.CultureInfo]::InvariantCulture)
        "SELECT '$trace' AS traceIdHidden, CAST('$time' AS DATETIME) AS time"
    }) -join ' UNION ALL ')
}

function Invoke-RoundsCase([string]$Name, $Rounds, $Turns, [double[]]$Expected) {
    $sql = 'WITH A AS (' + (ConvertTo-SqlRows $Rounds) + '), B AS (' + (ConvertTo-SqlRows $Turns) + '), ' + ($expression -replace '^WITH\s+', '')
    $body = @{
        queries = @(@{refId='C'; datasource=@{type='__expr__'; uid='__expr__'}; type='sql'; expression=$sql})
        from = [string]$end.AddHours(-1).ToUnixTimeMilliseconds()
        to = [string]$end.ToUnixTimeMilliseconds()
    } | ConvertTo-Json -Depth 10
    $response = Invoke-RestMethod -Uri "$($GrafanaBaseUrl.TrimEnd('/'))/api/ds/query" -Method Post -ContentType 'application/json' -Body $body
    $result = $response.results.C
    if ($result.status -ne 200) { throw "$Name failed: $($result | ConvertTo-Json -Depth 5)" }
    $frame = @($result.frames)[0]
    if ($frame.schema.fields[0].type -ne 'time' -or $frame.schema.fields[1].type -ne 'number') {
        throw "$Name did not return a time series."
    }
    $values = @($frame.data.values[1])
    if ($values.Count -ne $Expected.Count) { throw "$Name returned $($values.Count) points; expected $($Expected.Count)." }
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        if ($null -eq $values[$i] -or [math]::Abs([double]$values[$i] - $Expected[$i]) -gt 0.000001) {
            throw "$Name point $i expected $($Expected[$i]), got $($values[$i])."
        }
    }
    "$Name : PASS"
}

$fixturePath = Join-Path $repoRoot 'tests/fixtures/codex-performance-response.json'
$fixture = Get-Content -Raw $fixturePath | ConvertFrom-Json
$turnColumns = $fixture.results.A.frames[0].data.values
$turns = @()
for ($i = 0; $i -lt $turnColumns[0].Count; $i++) {
    # Same completed-turn predicate as the dashboard's Tempo query.
    if ($null -ne $turnColumns[9][$i] -or ($null -ne $turnColumns[5][$i] -and $null -ne $turnColumns[7][$i])) {
        $turns += @{trace=$turnColumns[2][$i]; time=$turnColumns[0][$i]}
    }
}
$roundColumns = $fixture.results.R.frames[0].data.values
$rounds = @(for ($i = 0; $i -lt $roundColumns[0].Count; $i++) {
    @{trace=$roundColumns[2][$i]; time=$roundColumns[0][$i]}
})
$report = & (Join-Path $PSScriptRoot 'codex-performance-report.ps1') -Project 'fixture://project' -Period 1h -AsOf $asOf -FixturePath $fixturePath -Format json | ConvertFrom-Json
Invoke-RoundsCase 'Fixed project/1h/as_of matches report' $rounds $turns @($report.turns[0].modelRounds)

$t = 1788508200000L
$turns = @(@{trace='zero'; time=$t}, @{trace='two'; time=($t+60000)}, @{trace='two'; time=($t+59000)})
$rounds = @(@{trace='two'; time=($t+1000)}, @{trace='two'; time=($t+2000)}, @{trace='incomplete'; time=$t})
Invoke-RoundsCase 'Zero rounds, different buckets, duplicate turns, orphan rounds' $rounds $turns @(0,2)
Invoke-RoundsCase 'All completed turns without rounds' @() $turns @(0,0)
Invoke-RoundsCase 'No completed turns' $rounds @() @()
Invoke-RoundsCase 'Same timestamp averages per-turn counts' $rounds @(@{trace='zero'; time=$t}, @{trace='two'; time=$t}) @(1)
