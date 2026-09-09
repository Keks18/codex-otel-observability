[CmdletBinding()]
param([string]$GrafanaBaseUrl = 'http://127.0.0.1:3000', [switch]$SkipGrafana)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
. (Join-Path $PSScriptRoot 'trace-activity.ps1')
$reportScript = Join-Path $PSScriptRoot 'codex-performance-report.ps1'
$search = Join-Path $root 'tests/fixtures/regular-turn-search.json'
$fixture = Join-Path $root 'tests/fixtures/regular-turn-traces.json'
$asOf = '2026-09-04T08:00:00Z'
$fromMs = 1788505200000L
$toMs = 1788508800000L
$null = New-Item -ItemType Directory -Path (Join-Path $root 'artifacts') -Force
$temporary = Join-Path $root ('artifacts/regular-turn-test-' + [guid]::NewGuid().ToString('N') + '.json')
function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -cne $Expected) { throw "$Name expected '$Expected', got '$Actual'." }
}
function Invoke-Report($Traces, [string]$At = $asOf, [string]$Period = '1h') {
    $Traces | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $temporary -Encoding UTF8
    & $reportScript -Project 'fixture://regular' -Period $Period -AsOf $At -FixturePath $search -TraceFixturePath $temporary | ConvertFrom-Json
}
function Add-Terminal($Traces, [string]$TraceId, [string]$Status, [string]$SpanId) {
    $terminal = ($Traces.PSObject.Properties['11111111111111111111111111111111'].Value.resourceSpans[0].scopeSpans[0].spans[1] | ConvertTo-Json -Depth 20) | ConvertFrom-Json
    $terminal.spanId = $SpanId
    @($terminal.attributes | Where-Object key -eq 'codex.turn.status')[0].value.stringValue = $Status
    $Traces.PSObject.Properties[$TraceId].Value.resourceSpans[0].scopeSpans[0].spans += $terminal
}
try {
    $traces = Get-Content -Raw $fixture | ConvertFrom-Json
    $report = Invoke-Report $traces
    Assert-Equal $report.summary.completedTurns 2 'regular completed turns without session_task.turn'
    Assert-Equal $report.summary.failedOrUnclassifiedTurns 1 'failed/unclassified'
    Assert-Equal $report.summary.toolCalls 33 'all terminal tool calls from hydrated traces'
    Assert-Equal $report.summary.toolDispatchFailures 2 'tool dispatch failures independent of turn status'
    Assert-Equal $report.summary.toolFailures $null 'combined failures unavailable without shell exit outcomes'
    Assert-Equal $report.summary.completedWithoutTokenUsage 2 'missing usage does not undo completion'
    Assert-Equal $report.tokens.total $null 'unknown tokens remain null'
    Assert-Equal $report.tokens.input $null 'unknown input remains null'
    Assert-Equal $report.summary.cacheHitPct $null 'unknown cache ratio remains null'
    Assert-Equal @($report.coverage.warnings | Where-Object code -eq 'missing_turn_or_root')[0].count 1 'missing terminal warning'
    Assert-Equal @($report.coverage.warnings | Where-Object code -eq 'completed_without_token_usage')[0].count 2 'token coverage warning'
    if (($report | ConvertTo-Json -Depth 20) -match 'PRIVATE_SENTINEL') { throw 'Private trace attributes leaked.' }
    $later = Invoke-Report $traces '2026-09-05T08:00:00Z' '2d'
    Assert-Equal ($later.summary | ConvertTo-Json) ($report.summary | ConvertTo-Json) 'age cannot change lifecycle state'
    $failedTraces = Get-Content -Raw $fixture | ConvertFrom-Json
    Add-Terminal $failedTraces '33333333333333333333333333333333' 'failed' 'eeeeeeeeeeeeeeee'
    $failedReport = Invoke-Report $failedTraces
    Assert-Equal $failedReport.summary.completedTurns 2 'failed turn is not completed'
    Assert-Equal $failedReport.summary.failedTurns 1 'explicit failed turn'
    Assert-Equal $failedReport.summary.unclassifiedTurns 0 'failed is classified separately'
    Assert-Equal $failedReport.summary.toolCalls 33 'failed classification retains tools'
    Assert-Equal $failedReport.summary.toolDispatchFailures 2 'failed classification retains tool dispatch failures'
    Add-Terminal $failedTraces '11111111111111111111111111111111' 'interrupted' 'ffffffffffffffff'
    $conflicting = Invoke-Report $failedTraces
    Assert-Equal $conflicting.summary.completedTurns 1 'failure overrides conflicting success'
    Assert-Equal $conflicting.summary.failedTurns 2 'interrupted is a failed terminal outcome'
    Assert-Equal @($conflicting.coverage.warnings | Where-Object code -eq 'conflicting_terminal_signals').Count 1 'conflict is visible'
    $future = Get-Content -Raw $fixture | ConvertFrom-Json
    $future.PSObject.Properties['11111111111111111111111111111111'].Value.resourceSpans[0].scopeSpans[0].spans[1].endTimeUnixNano = '1788508801000000000'
    Assert-Equal (Invoke-Report $future).summary.completedTurns 1 'terminal signal after as_of excluded'
    $unknownVersion = Get-Content -Raw $fixture | ConvertFrom-Json
    $unknownVersion.PSObject.Properties['11111111111111111111111111111111'].Value.resourceSpans[0].scopeSpans[0].spans[1].attributes[1].value.intValue = '2'
    Assert-Equal (Invoke-Report $unknownVersion).summary.completedTurns 1 'unknown terminal version is not trusted'
    $wrong = Get-Content -Raw $fixture | ConvertFrom-Json
    $wrong.PSObject.Properties['11111111111111111111111111111111'].Value.resourceSpans[0].scopeSpans[0].spans[0].attributes[0].value.stringValue = 'fixture://another-project'
    $rejected = $false
    try { $null = Invoke-Report $wrong } catch { $rejected = $_.Exception.Message -match 'exact selected project' }
    Assert-Equal $rejected $true 'hydration must validate exact cwd'
    'Regular-turn report: 2 completed, 1 failed/unclassified, 33 calls, 2 dispatch failures; lifecycle, snapshot and privacy cases PASS'

    # Independent lifecycle notification: only explicitly correlated terminal data
    # can create a marker. The converter does not send it to the running stack.
    @{method='turn/completed';params=@{threadId='synthetic-thread';turn=@{id='synthetic-turn';status='completed';error=$null;startedAt=1788508200;completedAt=1788508290;items=@('PRIVATE_SENTINEL')}}} | ConvertTo-Json -Depth 10 | Set-Content $temporary -Encoding UTF8
    $converted = & (Join-Path $PSScriptRoot 'convert-codex-turn-terminal.ps1') -NotificationPath $temporary -TraceId ('1'*32) -Project 'fixture://regular'
    if ($converted -match 'PRIVATE_SENTINEL|synthetic-thread|synthetic-turn') { throw 'Notification payload leaked into OTLP.' }
    $convertedRows = @(ConvertFrom-TraceActivity ($converted | ConvertFrom-Json) ('1'*32) $fromMs $toMs 'fixture://regular')
    Assert-Equal $convertedRows[0].'codex.turn.status' 'completed' 'explicit normalized terminal status'
    Assert-Equal $convertedRows[0].duration 90000000000 'terminal duration'
    $again = (& (Join-Path $PSScriptRoot 'convert-codex-turn-terminal.ps1') -NotificationPath $temporary -TraceId ('1'*32) -Project 'fixture://regular') | ConvertFrom-Json
    Assert-Equal $again.resourceSpans[0].scopeSpans[0].spans[0].spanId $convertedRows[0].spanID 'idempotent terminal span ID'
    'Terminal notification converter: correlation, idempotency and allowlist PASS'

    if (-not $SkipGrafana) {
        $dashboard = Get-Content -Raw (Join-Path $root 'grafana/dashboards/codex-overview.json') | ConvertFrom-Json
        function ConvertTo-SqlTable($Rows) {
            if (@($Rows).Count -eq 0) { return 'SELECT CAST(NULL AS CHAR) AS traceIdHidden, CAST(NULL AS DATETIME) AS time, CAST(NULL AS DOUBLE) AS duration WHERE 1=0' }
            (@($Rows | ForEach-Object {
                $date = [DateTimeOffset]::FromUnixTimeMilliseconds($_.time).UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss.fff',[Globalization.CultureInfo]::InvariantCulture)
                "SELECT '$($_.traceIdHidden)' AS traceIdHidden, CAST('$date' AS DATETIME) AS time, CAST($($_.duration) AS DOUBLE) AS duration"
            }) -join ' UNION ALL ')
        }
        foreach ($case in @(@{traces=$traces;report=$report},@{traces=$failedTraces;report=$conflicting})) {
            $rows = @($case.traces.PSObject.Properties | ForEach-Object { ConvertFrom-TraceActivity $_.Value $_.Name $fromMs $toMs 'fixture://regular' })
            $tables = @{
                P=@($rows | Where-Object { (Get-TraceProperty $_ 'codex.turn.status') -eq 'completed' })
                F=@($rows | Where-Object { (Get-TraceProperty $_ 'codex.turn.status') -in @('failed','interrupted') })
                X=@($rows | Where-Object source -eq 'B'); U=@(); A=@(); B=@()
                C=@($rows | Where-Object source -eq 'C')
                D=@($rows | Where-Object { (Get-TraceProperty $_ 'event.success') -eq 'false' })
                E=@($rows | Where-Object { $_.name -eq 'codex.turn.terminal' -and (Get-TraceProperty $_ 'codex.turn.signal_version') -eq 1 })
                L=@($rows | Where-Object name -eq 'session_task.turn')
                Q=@($rows | Where-Object { $_.source -eq 'C' -and (Get-TraceProperty $_ 'event.tool_name') -match '^(shell|exec|exec_command|write_stdin)$' })
                O=@($rows | Where-Object { $_.source -eq 'C' -and ((Get-TraceProperty $_ 'process.exit_code') -ne $null -or (Get-TraceProperty $_ 'process.success') -ne $null) })
                N=@($rows | Where-Object { $_.source -eq 'C' -and (((Get-TraceProperty $_ 'process.exit_code') -ne $null -and [int](Get-TraceProperty $_ 'process.exit_code') -ne 0) -or ((Get-TraceProperty $_ 'process.success') -eq $false)) })
            }
            foreach ($id in @(1,2,7,11,13,17)) {
                $panel = @($dashboard.panels | Where-Object id -eq $id)[0]
                $expression = @($panel.targets | Where-Object { $_.PSObject.Properties['expression'] })[-1].expression
                $baseRefs = [System.Collections.Generic.List[string]]::new()
                foreach ($ref in @('P','F','X','U','A','B','C','D','E','L','Q','O','N')) {
                    if ($expression -match "(?i)\b(?:FROM|JOIN)\s+$ref\b") { $baseRefs.Add($ref) }
                }
                $prefix = 'WITH ' + ((@($baseRefs) | ForEach-Object { $_+' AS ('+(ConvertTo-SqlTable $tables[$_])+')' }) -join ', ') + ', '
                $sqlExpression = $prefix + ($expression -replace '^WITH\s+','')
                if ($sqlExpression.Length -gt 10000) { throw "Lifecycle SQL panel $id synthetic expression exceeds Grafana's 10000-character limit." }
                $body = @{from=[string]$fromMs;to=[string]$toMs;queries=@(@{refId='Z';datasource=@{type='__expr__';uid='__expr__'};type='sql';expression=$sqlExpression})} | ConvertTo-Json -Depth 8
                try { $response = Invoke-RestMethod -Uri "$GrafanaBaseUrl/api/ds/query" -Method Post -ContentType 'application/json' -Body $body }
                catch { throw "Lifecycle SQL panel $id failed: $($_.Exception.Message)" }
                Assert-Equal $response.results.Z.status 200 "Grafana SQL panel $id status"
                $frame = $response.results.Z.frames[0]
                if ($id -eq 1) { Assert-Equal $frame.data.values[0][0] $case.report.summary.completedTurns 'dashboard/report completed parity' }
                if ($id -eq 17) {
                    Assert-Equal $frame.data.values[0][0] $case.report.coverage.completionSignals.explicit 'dashboard/report explicit signal parity'
                    Assert-Equal $frame.data.values[1][0] $case.report.coverage.completionSignals.legacy 'dashboard/report legacy signal parity'
                    Assert-Equal $frame.data.values[2][0] $case.report.coverage.completionSignals.missing 'dashboard/report missing signal parity'
                    Assert-Equal $frame.data.values[3][0] $case.report.summary.completedWithoutTokenUsage 'dashboard/report token warning parity'
                }
                if ($id -eq 7) {
                    $names = @($frame.schema.fields | ForEach-Object name)
                    Assert-Equal ($frame.data.values[$names.IndexOf('tool_calls')] | Measure-Object -Sum).Sum $case.report.summary.toolCalls 'dashboard/report 33 calls'
                    Assert-Equal ($frame.data.values[$names.IndexOf('dispatch_failures')] | Measure-Object -Sum).Sum $case.report.summary.toolDispatchFailures 'dashboard/report 2 dispatch failures'
                }
            }
        }
        'Actual Grafana lifecycle SQL: six panels agree with the report at the same synthetic project/from/as_of, including conflicting signals PASS'
    }
} finally {
    if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
}
