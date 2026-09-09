[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$reportScript = Join-Path $PSScriptRoot 'codex-performance-report.ps1'
$fixture = Join-Path $repoRoot 'tests\fixtures\codex-performance-response.json'
$asOf = '2026-09-04T08:00:00Z'

$json1 = & $reportScript -Project 'fixture://project' -Period 1h -AsOf $asOf -FixturePath $fixture -Format json | ConvertFrom-Json
$json2 = & $reportScript -Project 'fixture://project' -Period 1h -AsOf $asOf -FixturePath $fixture -Format json | ConvertFrom-Json

function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -ne $Expected) { throw "$Name expected '$Expected', got '$Actual'." }
}

Assert-Equal $json1.schemaVersion '5.0' 'schemaVersion'
Assert-Equal $json1.snapshot.asOf '2026-09-04T08:00:00.0000000+00:00' 'asOf'
Assert-Equal $json1.summary.completedTurns 1 'completed turns'
Assert-Equal $json1.summary.failedTurns 0 'failed turns'
Assert-Equal $json1.summary.unclassifiedTurns 3 'unclassified turns'
Assert-Equal $json1.summary.totalTokens 120 'total tokens'
Assert-Equal $json1.tokens.input 100 'input tokens'
Assert-Equal $json1.tokens.cachedInput 40 'cached input'
Assert-Equal $json1.tokens.nonCachedInput 60 'non-cached input'
Assert-Equal $json1.tokens.output 20 'output tokens'
Assert-Equal $json1.tokens.reasoning 5 'reasoning tokens'
Assert-Equal $json1.summary.toolCalls 2 'top-level tool calls'
Assert-Equal $json1.summary.toolDispatchFailures 1 'deduplicated dispatch failures'
Assert-Equal $json1.summary.toolFailures $null 'combined failures unavailable without command outcome coverage'
Assert-Equal $json1.tools.dispatchFailureRatePct 50 'observable dispatch failure rate'
Assert-Equal $json1.tools.process.coverage 'unavailable' 'process outcome coverage'
Assert-Equal $json1.tools.toolFailureRatePct $null 'combined tool failure rate'
Assert-Equal $json1.turns[0].modelRounds 2 'model rounds'
Assert-Equal $json1.turns[0].modelSamplingCumulativeMs 4000 'sampling cumulative duration'
Assert-Equal $json1.turns[0].toolCumulativeDurationMs 5000 'tool cumulative duration'
Assert-Equal $json1.turns[0].otherMs 6000 'search-preview wall-clock other duration'
Assert-Equal $json1.tools.byName[0].tool 'read' 'slowest tool'
Assert-Equal $json1.tools.byName[0].maxDurationMs 3000 'slowest duration'
Assert-Equal $json1.tools.failedCalls[0].failureClass 'tool_error' 'failure class'
Assert-Equal $json1.tools.failedCalls[0].nested $false 'nested exclusion'
Assert-Equal $json1.tools.failedCalls[0].retryCount 1 'retry count'
Assert-Equal $json1.tools.failedCalls[0].tool 'shell' 'event tool name on failed call'
Assert-Equal $json1.agentExecution.coverage 'unavailable' 'stock telemetry agent topology coverage'
Assert-Equal $json1.agentExecution.agentCount 0 'stock telemetry must not invent agents'
Assert-Equal @($json1.agentExecution.agents).Count 0 'stock telemetry has no agent rows'
Assert-Equal @($json1.agentExecution.warnings | Where-Object code -eq 'agent_topology_unavailable')[0].count 1 'stock telemetry emits topology unavailable warning'

function Test-ToolNameSource([string]$Source) {
    $response = Get-Content -Raw $fixture | ConvertFrom-Json
    foreach ($ref in @('C','D')) {
        $frame = $response.results.$ref.frames[0]
        $field = @($frame.schema.fields | Where-Object name -eq 'event.tool_name')[0]
        $field.name = $Source
        if ($Source -eq 'event.tool_name') {
            # A conflicting legacy name must not override the event attribute.
            $frame.schema.fields += [pscustomobject]@{name='tool_name'}
            $frame.data.values += ,@($frame.data.values[0] | ForEach-Object { 'legacy-wrong' })
        } else {
            # An absent/empty event value must still allow legacy fixtures.
            $frame.schema.fields += [pscustomobject]@{name='event.tool_name'}
            $frame.data.values += ,@($frame.data.values[0] | ForEach-Object { '' })
        }
    }
    # Exercise legacy search-response compatibility without live hydration.
    function Get-Content($LiteralPath, [switch]$Raw) {
        return ($response | ConvertTo-Json -Depth 20)
    }
    $actual = & $reportScript -Project 'fixture://project' -Period 1h -AsOf $asOf -FixturePath $fixture -Format json | ConvertFrom-Json
    if ($Source -eq 'missing-name') {
        Assert-Equal $actual.tools.byName.Count 1 'missing names group together'
        Assert-Equal $actual.tools.byName[0].tool 'unknown' 'missing name fallback'
        Assert-Equal $actual.tools.failedCalls[0].tool 'unknown' 'missing failed tool name'
    } else {
        Assert-Equal ($actual.tools | ConvertTo-Json -Depth 10) ($json1.tools | ConvertTo-Json -Depth 10) "tool source $Source"
    }
}
foreach ($source in @('event.tool_name','tool_name','span.tool_name','codex.tool.name','span.codex.tool.name','missing-name')) {
    Test-ToolNameSource $source
}

$warningCodes = @($json1.coverage.warnings | ForEach-Object code)
foreach ($code in @('oversized_or_partial','duplicate_turn_span','legacy_completion_signal','missing_turn_or_root','duplicate_tool_call')) {
    if ($code -notin $warningCodes) { throw "Missing expected coverage warning '$code'." }
}
Assert-Equal ($json1 | ConvertTo-Json -Depth 12) ($json2 | ConvertTo-Json -Depth 12) 'stable snapshot'

$markdown = & $reportScript -Project 'fixture://project' -Period 1h -AsOf $asOf -FixturePath $fixture -Format markdown
if ($markdown -notmatch 'Completed.*Failed.*Unclassified') { throw 'Markdown summary is missing completeness columns.' }
if ($markdown -notmatch 'Non-cached') { throw 'Markdown report is missing token semantics.' }
if ($markdown -match 'nested implementation failure') { throw 'Nested failure leaked into Markdown.' }

'codex-performance-report regression: PASS'

$hydrated = & $reportScript -Project 'fixture://project' -Period 1h -AsOf $asOf -FixturePath $fixture -TraceFixturePath (Join-Path $repoRoot 'tests/fixtures/complete-trace-activity.json') -Format json | ConvertFrom-Json
Assert-Equal $hydrated.summary.toolCalls 3 'complete trace recovers call omitted by search'
Assert-Equal $hydrated.summary.toolDispatchFailures 1 'complete trace terminal dispatch failure'
Assert-Equal $hydrated.turns[0].modelRounds 2 'complete trace rounds'
Assert-Equal $hydrated.turns[0].modelSamplingCumulativeMs 4000 'complete trace sampling'
Assert-Equal $hydrated.turns[0].toolCumulativeDurationMs 6000 'duplicate spans and out-of-window activity excluded'
Assert-Equal $hydrated.turns[0].hydratedSpanCount 14 'hydrated span diagnostics'
Assert-Equal $hydrated.coverage.hydration.concurrency 4 'hydration concurrency default'
if ($hydrated.coverage.hydration.totalDurationMs -le 0) { throw 'Total hydration timing diagnostics are missing.' }
if ($hydrated.coverage.hydration.traces[0].hydrationDurationMs -le 0) { throw 'Per-trace hydration timing diagnostics are missing.' }
if ($hydrated.turns[0].hydratedPayloadBytes -le 0) { throw 'Hydrated payload byte diagnostics are missing.' }
if (($hydrated | ConvertTo-Json -Depth 20) -match 'PRIVATE_SENTINEL') { throw 'Raw trace payload leaked into report.' }
'complete trace hydration regression: PASS'

$semanticsSearch = Join-Path $repoRoot 'tests\fixtures\delegated-metrics-search.json'
$semanticsTraces = Join-Path $repoRoot 'tests\fixtures\delegated-metrics-traces.json'
$semantics = & $reportScript -Project 'fixture://project' -Period 1h -AsOf $asOf -FixturePath $semanticsSearch -TraceFixturePath $semanticsTraces -Format json | ConvertFrom-Json
Assert-Equal $semantics.summary.completedTurns 3 'explicit and both legacy/orchestration traces stay visible'
Assert-Equal $semantics.summary.unclassifiedTurns 1 'missing completion stays unclassified'
Assert-Equal $semantics.coverage.completionSignals.explicit 1 'explicit terminal coverage'
Assert-Equal $semantics.coverage.completionSignals.legacy 2 'legacy completion coverage'
Assert-Equal $semantics.coverage.completionSignals.missing 1 'missing completion coverage'
Assert-Equal @($semantics.turnStates | Where-Object traceId -eq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')[0].completionSignal 'explicit' 'explicit signal classification'
Assert-Equal @($semantics.turnStates | Where-Object traceId -eq 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb')[0].completionSignal 'legacy' 'legacy signal classification'
Assert-Equal @($semantics.turnStates | Where-Object traceId -eq 'dddddddddddddddddddddddddddddddd')[0].status 'unclassified' 'missing signal classification'
Assert-Equal $semantics.tools.dispatchFailures 1 'dispatch failure independent of process failure'
Assert-Equal $semantics.tools.dispatchFailureRatePct 33.33 'dispatch failure rate'
Assert-Equal $semantics.tools.process.commandCalls 2 'shell command calls'
Assert-Equal $semantics.tools.process.outcomesObserved 1 'safe process outcomes observed'
Assert-Equal $semantics.tools.process.failures 1 'non-zero process exit failure'
Assert-Equal $semantics.tools.process.coverage 'partial' 'partial process coverage'
Assert-Equal $semantics.tools.process.failureRatePct $null 'partial process failure rate is unavailable'
Assert-Equal $semantics.tools.toolFailureRatePct $null 'combined failure rate is unavailable with partial coverage'
$explicitTurn = @($semantics.turns | Where-Object traceId -eq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa')[0]
Assert-Equal $explicitTurn.modelSamplingCumulativeMs 40000 'overlap sampling cumulative duration'
Assert-Equal $explicitTurn.toolCumulativeDurationMs 45000 'overlap tool cumulative duration'
Assert-Equal $explicitTurn.observedComponentWallClockMs 50000 'non-overlapping component union'
Assert-Equal $explicitTurn.samplingToolOverlapMs 35000 'sampling/tool overlap'
Assert-Equal $explicitTurn.otherMs 10000 'bounded other wall-clock duration'
if ($explicitTurn.observedComponentWallClockMs + $explicitTurn.otherMs -gt $explicitTurn.durationMs -or $explicitTurn.otherMs -lt 0) { throw 'Wall-clock breakdown exceeds turn duration.' }
$semanticWarnings = @($semantics.coverage.warnings | ForEach-Object code)
foreach ($code in @('legacy_completion_signal','missing_turn_or_root','turn_role_unavailable','process_outcome_coverage_incomplete','component_duration_overlap')) {
    if ($code -notin $semanticWarnings) { throw "Missing semantic coverage warning '$code'." }
}
Assert-Equal @($semantics.coverage.warnings | Where-Object code -eq 'legacy_completion_signal')[0].count 2 'two legacy traces including orchestration remain counted'
'delegated metrics semantics regression: PASS'

. (Join-Path $PSScriptRoot 'trace-activity.ps1')
$scopeFixture = Get-Content -Raw $semanticsTraces | ConvertFrom-Json
$worktreeTrace = $scopeFixture.PSObject.Properties['eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'].Value
$worktreeRows = @(ConvertFrom-TraceActivity $worktreeTrace 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' 1788505200000 1788508800000 'fixture://worktrees/task/project')
Assert-Equal $worktreeRows.Count 1 'exact worktree scope'
$scopeRejected = $false
try { $null = @(ConvertFrom-TraceActivity $worktreeTrace 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee' 1788505200000 1788508800000 'fixture://project') } catch { $scopeRejected = $_.Exception.Message -match 'exact selected project' }
if (-not $scopeRejected) { throw 'Worktree cwd was incorrectly merged with a same-basename project.' }
'exact worktree scope regression: PASS'

$tempRoot = Join-Path $repoRoot 'artifacts\test-large-trace'
if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
$null = New-Item -ItemType Directory -Path $tempRoot
try {
    $largeTraceId = 'ffffffffffffffffffffffffffffffff'
    $largeSpans = [System.Collections.Generic.List[object]]::new()
    $largeSpans.Add([pscustomobject]@{spanId='0000000000000001';name='project_activity';startTimeUnixNano='1788508200000000000';endTimeUnixNano='1788508200001000000';attributes=@([pscustomobject]@{key='cwd';value=[pscustomobject]@{stringValue='fixture://large'}});events=@()})
    $largeSpans[0].attributes += [pscustomobject]@{key='synthetic.padding';value=[pscustomobject]@{stringValue=('x' * 15000000)}}
    $largeSpans.Add([pscustomobject]@{spanId='0000000000000002';name='codex.turn.terminal';startTimeUnixNano='1788508200000000000';endTimeUnixNano='1788508260000000000';attributes=@([pscustomobject]@{key='codex.turn.status';value=[pscustomobject]@{stringValue='completed'}},[pscustomobject]@{key='codex.turn.signal_version';value=[pscustomobject]@{intValue='1'}});events=@()})
    for ($i=3; $i -le 1202; $i++) { $largeSpans.Add([pscustomobject]@{spanId=('{0:x16}' -f $i);name='synthetic_activity';startTimeUnixNano='1788508200000000000';endTimeUnixNano='1788508200001000000';attributes=@();events=@()}) }
    $largeTraces = [pscustomobject]@{$largeTraceId=[pscustomobject]@{resourceSpans=@([pscustomobject]@{scopeSpans=@([pscustomobject]@{spans=@($largeSpans)})})}}
    $largeSearch = Get-Content -Raw $semanticsSearch | ConvertFrom-Json
    $largeSearch.results.B.frames[0].data.values[0] = @(1788508200000)
    $largeSearch.results.B.frames[0].data.values[1] = @($largeTraceId)
    $largeSearch.results.B.frames[0].data.values[2] = @('fixture://large')
    $largeSearchPath = Join-Path $tempRoot 'search.json'
    $largeTracePath = Join-Path $tempRoot 'traces.json'
    $largeSearch | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $largeSearchPath -Encoding utf8
    $largeTraces | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $largeTracePath -Encoding utf8
    $large = & $reportScript -Project 'fixture://large' -Period 1h -AsOf $asOf -FixturePath $largeSearchPath -TraceFixturePath $largeTracePath -Format json | ConvertFrom-Json
    Assert-Equal $large.coverage.hydration.traces[0].hydratedSpanCount 1202 'large trace hydrated span count'
    Assert-Equal $large.turns[0].traceId $largeTraceId 'large trace ID retained'
    if ($large.coverage.hydration.traces[0].hydratedPayloadBytes -le 0) { throw 'Large trace payload bytes are missing.' }
    if ('span_amplification' -notin @($large.coverage.warnings | ForEach-Object code)) { throw 'Large trace amplification warning is missing.' }
    if (($large | ConvertTo-Json -Depth 20) -match 'synthetic.padding') { throw 'Synthetic padding attribute leaked into the report.' }
    'large trace hydration regression: PASS'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
