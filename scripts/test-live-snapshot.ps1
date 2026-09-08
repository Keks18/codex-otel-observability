[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$Project,
    [ValidatePattern('^\d+(m|h|d|w)$')][string]$Period = '1h',
    [Parameter(Mandatory=$true)][string]$AsOf,
    [string]$GrafanaBaseUrl = 'http://127.0.0.1:3000'
)
# Read-only: no trace, log, dashboard or datasource writes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$report = & (Join-Path $PSScriptRoot 'codex-performance-report.ps1') -Project $Project -Period $Period -AsOf $AsOf -GrafanaBaseUrl $GrafanaBaseUrl | ConvertFrom-Json
$dashboard = Get-Content -Raw (Join-Path $root 'grafana/dashboards/codex-overview.json') | ConvertFrom-Json
$from = ([DateTimeOffset]$report.snapshot.from).ToUnixTimeMilliseconds().ToString([Globalization.CultureInfo]::InvariantCulture)
$to = ([DateTimeOffset]$report.snapshot.asOf).ToUnixTimeMilliseconds().ToString([Globalization.CultureInfo]::InvariantCulture)
$literal = $Project.Replace('\','\\').Replace('"','\"')
$panelResults = @{}
foreach ($panel in @($dashboard.panels | Where-Object { $_.PSObject.Properties['targets'] })) {
    foreach ($target in $panel.targets) {
        if ($target.PSObject.Properties['query']) { $target.query = $target.query.Replace('${cwd:regex}',$literal) }
    }
    $body = @{from=$from;to=$to;queries=@($panel.targets)} | ConvertTo-Json -Depth 20
    try { $response = Invoke-RestMethod -Uri "$GrafanaBaseUrl/api/ds/query" -Method Post -ContentType 'application/json' -Body $body }
    catch { throw "Dashboard panel $($panel.id) failed: $($_.Exception.Message)" }
    foreach ($result in $response.results.PSObject.Properties) {
        if ($result.Value.status -notin @(200,206)) { throw "Dashboard panel $($panel.id)/$($result.Name) returned $($result.Value.status)." }
    }
    $panelResults[[int]$panel.id] = $response
}
'All dashboard target queries execute on the fixed live snapshot: PASS'
if ($report.turnStates.Count -eq 0) {
    'No scoped live traces: non-empty numeric parity was NOT verified.'
    return
}
function Get-FirstValue([int]$PanelId, [string]$Ref, [int]$Column=0) {
    $frames = @($panelResults[$PanelId].results.$Ref.frames)
    if ($frames.Count -eq 0 -or $frames[0].data.values[$Column].Count -eq 0) { return $null }
    return $frames[0].data.values[$Column][0]
}
function Assert-Number($Actual, $Expected, [string]$Name) {
    if ($null -eq $Actual -and $null -eq $Expected) { return }
    if ($null -eq $Actual -or $null -eq $Expected -or [math]::Abs([double]$Actual-[double]$Expected) -gt 0.0001) { throw "$Name mismatch: dashboard=$Actual; report=$Expected." }
}
Assert-Number (Get-FirstValue 1 'Z') $report.summary.completedTurns 'Completed turns'
Assert-Number (Get-FirstValue 17 'Z' 0) $report.coverage.completionSignals.explicit 'Explicit terminal'
Assert-Number (Get-FirstValue 17 'Z' 1) $report.coverage.completionSignals.legacy 'Legacy completion'
Assert-Number (Get-FirstValue 17 'Z' 2) $report.coverage.completionSignals.missing 'Missing terminal / outcome'
Assert-Number (Get-FirstValue 17 'Z' 3) $report.summary.completedWithoutTokenUsage 'Completed without tokens'
$toolCalls = 0
foreach ($frame in @($panelResults[5].results.A.frames)) {
    for ($j=0;$j -lt $frame.schema.fields.Count;$j++) {
        if ($frame.schema.fields[$j].type -eq 'number') { $toolCalls += ($frame.data.values[$j] | Measure-Object -Sum).Sum }
    }
}
Assert-Number $toolCalls $report.summary.toolCalls 'Tool calls'
$expectedDispatchFailureRate = $report.tools.dispatchFailureRatePct
Assert-Number (Get-FirstValue 6 'E') $expectedDispatchFailureRate 'Dispatch failure rate %'
"Live dashboard/report parity: completed=$($report.summary.completedTurns), explicit=$($report.coverage.completionSignals.explicit), legacy=$($report.coverage.completionSignals.legacy), missing=$($report.coverage.completionSignals.missing), calls=$($report.summary.toolCalls), dispatch failures=$($report.summary.toolDispatchFailures), dispatch failure rate=$expectedDispatchFailureRate% PASS"
