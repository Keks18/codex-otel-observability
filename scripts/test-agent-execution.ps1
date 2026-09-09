[CmdletBinding()]
param(
    [string]$GrafanaBaseUrl = 'http://127.0.0.1:3000',
    [switch]$SkipGrafana
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$reportScript = Join-Path $PSScriptRoot 'codex-performance-report.ps1'
$traceActivity = Join-Path $PSScriptRoot 'trace-activity.ps1'
$asOf = '2026-09-04T08:00:00Z'
$baseNano = [long]1788508200000000000
$tempRoot = Join-Path $repoRoot 'artifacts\test-agent-execution'

function Assert-Equal($Actual, $Expected, [string]$Name) {
    if ($Actual -ne $Expected) { throw "$Name expected '$Expected', got '$Actual'." }
}
function Assert-True([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw $Name }
}
function New-Attribute([string]$Key, [string]$Value, [string]$Kind = 'stringValue') {
    [pscustomobject]@{ key=$Key; value=[pscustomobject]@{ $Kind=$Value } }
}
function New-Span([int]$Number, [string]$Name, [int]$StartMs, [int]$EndMs, [object[]]$Attributes, [object[]]$Events = @()) {
    [pscustomobject]@{
        spanId=('{0:x16}' -f $Number); name=$Name
        startTimeUnixNano=[string]($baseNano + ([long]$StartMs * 1000000))
        endTimeUnixNano=[string]($baseNano + ([long]$EndMs * 1000000))
        attributes=@($Attributes); events=@($Events)
    }
}
function New-Trace([object[]]$Spans, [int]$DelayMs = 0) {
    [pscustomobject]@{
        hydrationDelayMs=$DelayMs
        resourceSpans=@([pscustomobject]@{scopeSpans=@([pscustomobject]@{spans=@($Spans)})})
    }
}
function New-Search([string[]]$TraceIds, [string]$Project) {
    $times = @($TraceIds | ForEach-Object { 1788508200000 })
    [pscustomobject]@{results=[pscustomobject]@{
        A=[pscustomobject]@{status=200;frames=@()}
        B=[pscustomobject]@{status=200;frames=@([pscustomobject]@{schema=[pscustomobject]@{fields=@([pscustomobject]@{name='time'},[pscustomobject]@{name='traceIdHidden'},[pscustomobject]@{name='cwd'})};data=[pscustomobject]@{values=@($times,@($TraceIds),@($TraceIds | ForEach-Object { $Project }))}})}
        C=[pscustomobject]@{status=200;frames=@()};D=[pscustomobject]@{status=200;frames=@()};R=[pscustomobject]@{status=200;frames=@()};S=[pscustomobject]@{status=200;frames=@()}
    }}
}
function ConvertTo-AgentSqlTable($Rows) {
    if (@($Rows).Count -eq 0) {
        return 'SELECT CAST(NULL AS CHAR) AS traceIdHidden, CAST(NULL AS CHAR) AS `span.codex.agent.instance_id`, CAST(NULL AS CHAR) AS `span.codex.agent.delegation_id`, CAST(NULL AS CHAR) AS `span.codex.agent.delegation_depth`, CAST(NULL AS CHAR) AS `span.codex.agent.lifecycle`, CAST(NULL AS CHAR) AS `span.codex.agent.status` WHERE 1=0'
    }
    function Sql-Value($Value) {
        if ($null -eq $Value -or [string]$Value -eq '') { return 'NULL' }
        return "'" + ([string]$Value).Replace("'", "''") + "'"
    }
    return (@($Rows | ForEach-Object {
        'SELECT ' + (Sql-Value $_.traceIdHidden) + ' AS traceIdHidden, ' +
        (Sql-Value (Get-TraceProperty $_ 'codex.agent.instance_id')) + ' AS `span.codex.agent.instance_id`, ' +
        (Sql-Value (Get-TraceProperty $_ 'codex.agent.delegation_id')) + ' AS `span.codex.agent.delegation_id`, ' +
        (Sql-Value (Get-TraceProperty $_ 'codex.agent.delegation_depth')) + ' AS `span.codex.agent.delegation_depth`, ' +
        (Sql-Value (Get-TraceProperty $_ 'codex.agent.lifecycle')) + ' AS `span.codex.agent.lifecycle`, ' +
        (Sql-Value (Get-TraceProperty $_ 'codex.agent.status')) + ' AS `span.codex.agent.status`'
    }) -join ' UNION ALL ')
}
function Agent-Attributes([string]$Id, [string]$State, [string]$Depth, [string]$Parent = '', [string]$Delegation = '', [string]$Status = '', [string]$Interval = '', [string]$Role = '') {
    $attrs = @(
        (New-Attribute 'codex.agent.signal_version' '1' 'intValue'),
        (New-Attribute 'codex.agent.instance_id' $Id),
        (New-Attribute 'codex.agent.lifecycle' $State),
        (New-Attribute 'codex.agent.delegation_depth' $Depth 'intValue'),
        (New-Attribute 'codex.project.identity' 'repo-fixture')
    )
    if ($Parent) { $attrs += New-Attribute 'codex.agent.parent_instance_id' $Parent }
    if ($Delegation) { $attrs += New-Attribute 'codex.agent.delegation_id' $Delegation }
    if ($Status) { $attrs += New-Attribute 'codex.agent.status' $Status }
    if ($Interval) { $attrs += New-Attribute 'codex.agent.interval_kind' $Interval }
    if ($Role) { $attrs += New-Attribute 'codex.agent.role' $Role }
    return @($attrs)
}
function New-AgentTimingSpan([int]$Number, [string]$Id, [string]$State, [int]$StartMs, [int]$EndMs, [string]$Interval = '', [string]$Status = '') {
    return New-Span $Number 'codex.agent.lifecycle' $StartMs $EndMs (Agent-Attributes $Id $State '0' -Status $Status -Interval $Interval)
}
function New-AgentTimingSpanNs([int]$Number, [string]$Id, [string]$State, [long]$StartNs, [long]$EndNs, [string]$Interval = '', [string]$Status = '') {
    return [pscustomobject]@{
        spanId=('{0:x16}' -f $Number); name='codex.agent.lifecycle'
        startTimeUnixNano=[string]($baseNano + $StartNs); endTimeUnixNano=[string]($baseNano + $EndNs)
        attributes=@(Agent-Attributes $Id $State '0' -Status $Status -Interval $Interval); events=@()
    }
}
function Get-TimingReport([string]$Stem, [object[]]$TimingSpans) {
    $traceId = ('a' * (32 - $Stem.Length)) + $Stem
    $project = 'fixture://timing-' + $Stem
    $searchFile = Join-Path $tempRoot ($Stem + '-search.json')
    $traceFile = Join-Path $tempRoot ($Stem + '-traces.json')
    $spans = @((New-Span 900 'project_activity' 0 1 @((New-Attribute 'cwd' $project)))) + @($TimingSpans)
    (New-Search @($traceId) $project) | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $searchFile -Encoding utf8
    ([pscustomobject]@{$traceId=(New-Trace $spans)}) | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $traceFile -Encoding utf8
    return & $reportScript -Project $project -Period 1h -AsOf $asOf -FixturePath $searchFile -TraceFixturePath $traceFile -Format json | ConvertFrom-Json
}

if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
$null = New-Item -ItemType Directory -Path $tempRoot
try {
    $validTraceId = '11111111111111111111111111111111'
    $auxTraceId = '22222222222222222222222222222222'
    $validSpans = [System.Collections.Generic.List[object]]::new()
    $validSpans.Add((New-Span 1 'project_activity' 0 1 @((New-Attribute 'cwd' 'fixture://agent'))))
    # Root active intervals overlap: union is 0-6 seconds, not 0-4 + 3-6.
    $validSpans.Add((New-Span 2 'codex.agent.lifecycle' 0 4000 (Agent-Attributes 'agent-root' 'spawn' '0' -Interval 'active' -Role 'root')))
    $validSpans.Add((New-Span 3 'codex.agent.lifecycle' 3000 6000 (Agent-Attributes 'agent-root' 'start' '0' -Interval 'active' -Role 'root')))
    $validSpans.Add((New-Span 4 'codex.agent.lifecycle' 6000 9000 (Agent-Attributes 'agent-root' 'wait' '0' -Interval 'wait' -Role 'root')))
    $validSpans.Add((New-Span 5 'codex.agent.lifecycle' 8000 9000 (Agent-Attributes 'agent-root' 'complete' '0' -Status 'completed' -Role 'root')))
    $validSpans.Add((New-Span 6 'codex.agent.lifecycle' 1000 3000 (Agent-Attributes 'agent-ok' 'spawn' '1' -Parent 'agent-root' -Delegation 'delegation-a' -Interval 'active' -Role 'worker')))
    $validSpans.Add((New-Span 7 'codex.agent.lifecycle' 3000 4000 (Agent-Attributes 'agent-ok' 'complete' '1' -Parent 'agent-root' -Delegation 'delegation-a' -Status 'completed' -Interval 'active' -Role 'worker')))
    $validSpans.Add((New-Span 8 'codex.agent.lifecycle' 1000 3000 (Agent-Attributes 'agent-failed' 'spawn' '1' -Parent 'agent-root' -Delegation 'delegation-b' -Interval 'active' -Role 'worker')))
    $validSpans.Add((New-Span 9 'codex.agent.lifecycle' 3000 4000 (Agent-Attributes 'agent-failed' 'complete' '1' -Parent 'agent-root' -Delegation 'delegation-b' -Status 'failed' -Interval 'active' -Role 'worker')))
    $validSpans.Add((New-Span 10 'dispatch_tool_call_with_terminal_outcome' 1500 2000 @((New-Attribute 'call_id' 'agent-call'),(New-Attribute 'codex.agent.instance_id' 'agent-ok')) @([pscustomobject]@{attributes=@((New-Attribute 'tool_name' 'read'),(New-Attribute 'success' 'true'))})))
    $validSpans[1].attributes += New-Attribute 'PRIVATE_AGENT_PAYLOAD' 'must-not-leak'
    $auxSpans = @((New-Span 20 'project_activity' 0 1 @((New-Attribute 'cwd' 'fixture://agent'))))
    $validTraces = [pscustomobject]@{
        $validTraceId=(New-Trace @($validSpans) 120)
        $auxTraceId=(New-Trace $auxSpans 0)
    }
    $searchPath = Join-Path $tempRoot 'valid-search.json'
    $tracesPath = Join-Path $tempRoot 'valid-traces.json'
    (New-Search @($validTraceId,$auxTraceId) 'fixture://agent') | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $searchPath -Encoding utf8
    $validTraces | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $tracesPath -Encoding utf8
    $serial = & $reportScript -Project 'fixture://agent' -Period 1h -AsOf $asOf -FixturePath $searchPath -TraceFixturePath $tracesPath -HydrationConcurrency 1 -Format json | ConvertFrom-Json
    $concurrent = & $reportScript -Project 'fixture://agent' -Period 1h -AsOf $asOf -FixturePath $searchPath -TraceFixturePath $tracesPath -HydrationConcurrency 2 -Format json | ConvertFrom-Json
    Assert-Equal $concurrent.agentExecution.coverage 'available' 'valid agent coverage'
    Assert-Equal $concurrent.agentExecution.agentCount 3 'root and two children'
    Assert-Equal $concurrent.agentExecution.delegationCount 2 'delegation count'
    Assert-Equal $concurrent.agentExecution.rootCount 1 'root count'
    Assert-Equal $concurrent.agentExecution.maximumDepth 1 'maximum depth'
    Assert-Equal $concurrent.agentExecution.completed 2 'completed agent count'
    Assert-Equal $concurrent.agentExecution.failedOrInterrupted 1 'failed agent count'
    Assert-Equal $concurrent.agentExecution.unclassified 0 'unclassified valid agent count'
    $root = @($concurrent.agentExecution.agents | Where-Object agentId -eq 'agent-root')[0]
    Assert-Equal $root.activeWallClockMs 6000 'overlapping active intervals use union'
    Assert-Equal $root.waitWallClockMs 3000 'wait interval union'
    Assert-Equal $root.timingCoverage 'available' 'nominal root timing coverage'
    Assert-Equal $root.uncoveredWallClockMs 0 'nominal root has measured complete timing coverage'
    Assert-Equal $root.waitSharePct 33.33 'nominal root wait share'
    Assert-Equal $concurrent.agentExecution.timingCoverage 'available' 'nominal aggregate timing coverage'
    Assert-Equal $concurrent.agentExecution.waitSharePct 20 'nominal aggregate wait share'
    Assert-Equal ($serial.agentExecution | ConvertTo-Json -Depth 10) ($concurrent.agentExecution | ConvertTo-Json -Depth 10) 'out-of-order hydration keeps agent semantics deterministic'
    Assert-Equal (($concurrent.coverage.hydration.traces | ForEach-Object traceId) -join ',') ((@($validTraceId,$auxTraceId | Sort-Object)) -join ',') 'hydration diagnostics are sorted'
    Assert-True (($concurrent | ConvertTo-Json -Depth 20) -notmatch 'PRIVATE_AGENT_PAYLOAD|must-not-leak') 'Agent fixture payload leaked into report.'
    'agent execution valid topology and bounded concurrent hydration: PASS'

    # Timing coverage is computed from earliest spawn start to the selected
    # complete end, with all union decisions made before millisecond rounding.
    $adjacent = Get-TimingReport '01' @(
        (New-AgentTimingSpan 100 'adjacent' 'spawn' 0 4000 'active'),
        (New-AgentTimingSpan 101 'adjacent' 'wait' 4000 10000 'wait'),
        (New-AgentTimingSpan 102 'adjacent' 'complete' 9000 10000 '' 'completed')
    )
    $adjacentAgent = $adjacent.agentExecution.agents[0]
    Assert-Equal $adjacentAgent.timingCoverage 'available' 'adjacent active/wait timing coverage'
    Assert-Equal $adjacentAgent.uncoveredWallClockMs 0 'adjacent active/wait uncovered time'
    Assert-Equal $adjacentAgent.waitSharePct 60 'adjacent active/wait share'
    Assert-Equal $adjacent.agentExecution.timingCoverage 'available' 'adjacent aggregate timing coverage'
    Assert-Equal $adjacent.agentExecution.waitSharePct 60 'adjacent aggregate wait share'

    $sameKindOverlap = Get-TimingReport '02' @(
        (New-AgentTimingSpan 110 'same-kind' 'spawn' 0 5000 'active'),
        (New-AgentTimingSpan 111 'same-kind' 'start' 4000 8000 'active'),
        (New-AgentTimingSpan 112 'same-kind' 'wait' 8000 10000 'wait'),
        (New-AgentTimingSpan 113 'same-kind' 'complete' 9000 10000 '' 'completed')
    )
    $sameKindAgent = $sameKindOverlap.agentExecution.agents[0]
    Assert-Equal $sameKindAgent.timingCoverage 'available' 'same-kind overlap remains available'
    Assert-Equal $sameKindAgent.activeWallClockMs 8000 'same-kind overlap uses active union'
    Assert-Equal $sameKindAgent.uncoveredWallClockMs 0 'same-kind overlap has no uncovered lifecycle'

    $betweenGap = Get-TimingReport '03' @(
        (New-AgentTimingSpan 120 'between-gap' 'spawn' 0 4000 'active'),
        (New-AgentTimingSpan 121 'between-gap' 'wait' 5000 10000 'wait'),
        (New-AgentTimingSpan 122 'between-gap' 'complete' 9000 10000 '' 'completed')
    )
    $betweenGapAgent = $betweenGap.agentExecution.agents[0]
    Assert-Equal $betweenGapAgent.timingCoverage 'partial' 'gap between active and wait timing coverage'
    Assert-Equal $betweenGapAgent.uncoveredWallClockMs 1000 'gap between active and wait uncovered time'
    Assert-Equal $betweenGapAgent.waitSharePct $null 'gap between active and wait share'
    Assert-Equal @($betweenGap.agentExecution.warnings | Where-Object code -eq 'agent_timing_inconsistent')[0].count 1 'gap warning counts canonical agents'

    $afterGap = Get-TimingReport '04' @(
        (New-AgentTimingSpan 130 'after-gap' 'spawn' 0 6000 'active'),
        (New-AgentTimingSpan 131 'after-gap' 'wait' 6000 8000 'wait'),
        (New-AgentTimingSpan 132 'after-gap' 'complete' 9000 10000 '' 'completed')
    )
    $afterGapAgent = $afterGap.agentExecution.agents[0]
    Assert-Equal $afterGapAgent.timingCoverage 'partial' 'gap before terminal timing coverage'
    Assert-Equal $afterGapAgent.uncoveredWallClockMs 2000 'gap before terminal uncovered time'

    $beforeGap = Get-TimingReport '05' @(
        (New-AgentTimingSpan 140 'before-gap' 'spawn' 0 2000 'active'),
        (New-AgentTimingSpan 141 'before-gap' 'wait' 3000 10000 'wait'),
        (New-AgentTimingSpan 142 'before-gap' 'complete' 9000 10000 '' 'completed')
    )
    $beforeGapAgent = $beforeGap.agentExecution.agents[0]
    Assert-Equal $beforeGapAgent.timingCoverage 'partial' 'gap after spawn timing coverage'
    Assert-Equal $beforeGapAgent.uncoveredWallClockMs 1000 'gap after spawn uncovered time'

    $crossKindOverlap = Get-TimingReport '06' @(
        (New-AgentTimingSpan 150 'cross-kind' 'spawn' 0 6000 'active'),
        (New-AgentTimingSpan 151 'cross-kind' 'wait' 5000 10000 'wait'),
        (New-AgentTimingSpan 152 'cross-kind' 'complete' 9000 10000 '' 'completed')
    )
    $crossKindAgent = $crossKindOverlap.agentExecution.agents[0]
    Assert-Equal $crossKindAgent.timingCoverage 'partial' 'active/wait mutual overlap timing coverage'
    Assert-Equal $crossKindAgent.uncoveredWallClockMs 0 'cross-kind overlap still measures complete union'
    Assert-Equal $crossKindAgent.waitSharePct $null 'cross-kind overlap suppresses wait share'
    Assert-Equal @($crossKindOverlap.agentExecution.warnings | Where-Object code -eq 'agent_timing_inconsistent')[0].count 1 'cross-kind overlap warning count'

    $noClassified = Get-TimingReport '07' @(
        (New-AgentTimingSpan 160 'no-classified' 'spawn' 0 1000),
        (New-AgentTimingSpan 161 'no-classified' 'complete' 9000 10000 '' 'completed')
    )
    $noClassifiedAgent = $noClassified.agentExecution.agents[0]
    Assert-Equal $noClassifiedAgent.timingCoverage 'unavailable' 'bounds without classified timing are unavailable'
    Assert-Equal $noClassifiedAgent.uncoveredWallClockMs $null 'bounds without classified timing uncovered time unknown'
    Assert-Equal $noClassifiedAgent.waitSharePct $null 'bounds without classified timing wait share'
    Assert-Equal $noClassified.agentExecution.timingCoverage 'unavailable' 'no classified aggregate timing coverage'

    $missingBounds = Get-TimingReport '08' @(
        (New-AgentTimingSpan 170 'missing-terminal' 'spawn' 0 10000 'active'),
        (New-AgentTimingSpan 171 'missing-spawn' 'wait' 0 10000 'wait'),
        (New-AgentTimingSpan 172 'missing-spawn' 'complete' 9000 10000 '' 'completed')
    )
    Assert-Equal @($missingBounds.agentExecution.agents | Where-Object agentId -eq 'missing-terminal')[0].timingCoverage 'unavailable' 'missing terminal timing coverage'
    Assert-Equal @($missingBounds.agentExecution.agents | Where-Object agentId -eq 'missing-spawn')[0].uncoveredWallClockMs $null 'missing spawn uncovered time unknown'
    Assert-Equal $missingBounds.agentExecution.timingCoverage 'unavailable' 'missing bounds aggregate timing coverage'

    $mixedTiming = Get-TimingReport '09' @(
        (New-AgentTimingSpan 180 'available-agent' 'spawn' 0 5000 'active'),
        (New-AgentTimingSpan 181 'available-agent' 'wait' 5000 10000 'wait'),
        (New-AgentTimingSpan 182 'available-agent' 'complete' 9000 10000 '' 'completed'),
        (New-AgentTimingSpan 183 'partial-agent' 'spawn' 0 4000 'active'),
        (New-AgentTimingSpan 184 'partial-agent' 'wait' 5000 10000 'wait'),
        (New-AgentTimingSpan 185 'partial-agent' 'complete' 9000 10000 '' 'completed')
    )
    Assert-Equal $mixedTiming.agentExecution.timingCoverage 'partial' 'mixed agent timing aggregate coverage'
    Assert-Equal $mixedTiming.agentExecution.activeWallClockMs $null 'mixed agent timing aggregate active total'
    Assert-Equal $mixedTiming.agentExecution.waitWallClockMs $null 'mixed agent timing aggregate wait total'
    Assert-Equal $mixedTiming.agentExecution.waitSharePct $null 'mixed agent timing aggregate wait share'
    Assert-Equal @($mixedTiming.agentExecution.warnings | Where-Object code -eq 'agent_timing_inconsistent')[0].count 1 'mixed timing warning counts affected agents'

    $nanosecondAdjacent = Get-TimingReport '0a' @(
        (New-AgentTimingSpanNs 190 'nanosecond-adjacent' 'spawn' 0 500000001 'active'),
        (New-AgentTimingSpanNs 191 'nanosecond-adjacent' 'wait' 500000001 1000000001 'wait'),
        (New-AgentTimingSpanNs 192 'nanosecond-adjacent' 'complete' 1000000000 1000000001 '' 'completed')
    )
    $nanosecondAgent = $nanosecondAdjacent.agentExecution.agents[0]
    Assert-Equal $nanosecondAgent.timingCoverage 'available' 'nanosecond-adjacent intervals have no rounding gap'
    Assert-Equal $nanosecondAgent.uncoveredWallClockMs 0 'nanosecond-adjacent uncovered time'
    Assert-Equal $nanosecondAgent.waitSharePct 50 'nanosecond-adjacent wait share'
    $nanosecondGap = Get-TimingReport '0b' @(
        (New-AgentTimingSpanNs 193 'nanosecond-gap' 'spawn' 0 500000000 'active'),
        (New-AgentTimingSpanNs 194 'nanosecond-gap' 'wait' 500000001 1000000001 'wait'),
        (New-AgentTimingSpanNs 195 'nanosecond-gap' 'complete' 1000000000 1000000001 '' 'completed')
    )
    $nanosecondGapAgent = $nanosecondGap.agentExecution.agents[0]
    Assert-Equal $nanosecondGapAgent.timingCoverage 'partial' 'one-nanosecond gap cannot become available after rounding'
    Assert-Equal $nanosecondGapAgent.uncoveredWallClockMs 0.000001 'one-nanosecond gap stays positive in diagnostics'
    Assert-Equal $nanosecondGapAgent.waitSharePct $null 'one-nanosecond gap suppresses wait share'
    $tinyNanosecondLifecycle = Get-TimingReport '0c' @(
        (New-AgentTimingSpanNs 196 'tiny-nanosecond' 'spawn' 0 1 'active'),
        (New-AgentTimingSpanNs 197 'tiny-nanosecond' 'wait' 1 2 'wait'),
        (New-AgentTimingSpanNs 198 'tiny-nanosecond' 'complete' 1 2 '' 'completed')
    )
    $tinyNanosecondAgent = $tinyNanosecondLifecycle.agentExecution.agents[0]
    Assert-Equal $tinyNanosecondAgent.timingCoverage 'available' 'tiny nanosecond lifecycle timing coverage'
    Assert-Equal $tinyNanosecondAgent.activeWallClockMs 0 'tiny active duration may round for display'
    Assert-Equal $tinyNanosecondAgent.waitWallClockMs 0 'tiny wait duration may round for display'
    Assert-Equal $tinyNanosecondAgent.waitSharePct 50 'tiny lifecycle row share uses unrounded nanoseconds'
    Assert-Equal $tinyNanosecondLifecycle.agentExecution.waitSharePct 50 'tiny lifecycle aggregate share uses unrounded nanoseconds'
    $unsupportedIntervalKind = Get-TimingReport '0d' @(
        (New-AgentTimingSpan 199 'unsupported-kind' 'spawn' 0 10000 'blocked'),
        (New-AgentTimingSpan 200 'unsupported-kind' 'complete' 9000 10000 '' 'completed')
    )
    $unsupportedIntervalAgent = $unsupportedIntervalKind.agentExecution.agents[0]
    Assert-Equal $unsupportedIntervalAgent.timingCoverage 'partial' 'unsupported non-empty interval kind is malformed timing evidence'
    Assert-Equal $unsupportedIntervalAgent.uncoveredWallClockMs 10000 'unsupported interval kind leaves lifecycle uncovered'
    Assert-Equal $unsupportedIntervalAgent.waitSharePct $null 'unsupported interval kind suppresses wait share'
    Assert-Equal @($unsupportedIntervalKind.agentExecution.warnings | Where-Object code -eq 'agent_timing_inconsistent')[0].count 1 'unsupported interval warning counts canonical agents'
    'agent execution authoritative timing coverage regressions: PASS'

    # Agent instance IDs are trace-local. Reusing the same opaque IDs in a
    # second trace must create a second independent topology.
    $reusedTraceId = '44444444444444444444444444444444'
    $reused = ($validTraces.PSObject.Properties[$validTraceId].Value | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    $reusedTraces = [pscustomobject]@{ $validTraceId=$validTraces.PSObject.Properties[$validTraceId].Value; $reusedTraceId=$reused }
    $reusedSearchPath = Join-Path $tempRoot 'reused-search.json'
    $reusedTracesPath = Join-Path $tempRoot 'reused-traces.json'
    (New-Search @($validTraceId,$reusedTraceId) 'fixture://agent') | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $reusedSearchPath -Encoding utf8
    $reusedTraces | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $reusedTracesPath -Encoding utf8
    $reusedReport = & $reportScript -Project 'fixture://agent' -Period 1h -AsOf $asOf -FixturePath $reusedSearchPath -TraceFixturePath $reusedTracesPath -Format json | ConvertFrom-Json
    Assert-Equal $reusedReport.agentExecution.agentCount 6 'same agent IDs in two traces remain separate'
    Assert-Equal $reusedReport.agentExecution.delegationCount 4 'delegation IDs are trace-local'
    foreach ($warning in @('agent_duplicate_id','agent_invalid_parent','agent_parent_cycle')) {
        Assert-True ($warning -notin @($reusedReport.agentExecution.warnings | ForEach-Object code)) "Trace-local reuse incorrectly produced '$warning'."
    }
    Assert-Equal @($reusedReport.agentExecution.agents | Where-Object agentId -eq 'agent-root').Count 2 'two root rows retain the shared opaque ID'
    'agent execution trace-local identity regression: PASS'

    # Active-active overlap is valid; active-wait overlap is contradictory and
    # must make both the row and aggregate wait share unavailable.
    $overlapTrace = ($validTraces.PSObject.Properties[$validTraceId].Value | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    $overlapTrace.resourceSpans[0].scopeSpans[0].spans[3].startTimeUnixNano = [string]($baseNano + 5000L * 1000000L)
    $overlapTraceId = '55555555555555555555555555555555'
    $overlapSearchPath = Join-Path $tempRoot 'overlap-search.json'
    $overlapTracesPath = Join-Path $tempRoot 'overlap-traces.json'
    (New-Search @($overlapTraceId) 'fixture://agent-overlap') | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $overlapSearchPath -Encoding utf8
    $overlapTrace.resourceSpans[0].scopeSpans[0].spans[0].attributes[0].value.stringValue = 'fixture://agent-overlap'
    ([pscustomobject]@{$overlapTraceId=$overlapTrace}) | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $overlapTracesPath -Encoding utf8
    $overlapReport = & $reportScript -Project 'fixture://agent-overlap' -Period 1h -AsOf $asOf -FixturePath $overlapSearchPath -TraceFixturePath $overlapTracesPath -Format json | ConvertFrom-Json
    $overlapRoot = @($overlapReport.agentExecution.agents | Where-Object agentId -eq 'agent-root')[0]
    Assert-Equal $overlapRoot.timingCoverage 'partial' 'active-wait overlap timing coverage'
    Assert-Equal $overlapRoot.waitSharePct $null 'active-wait overlap row wait share'
    Assert-Equal $overlapReport.agentExecution.waitSharePct $null 'active-wait overlap aggregate wait share'
    Assert-True ('agent_timing_inconsistent' -in @($overlapReport.agentExecution.warnings | ForEach-Object code)) 'Active-wait overlap warning is missing.'
    Assert-True ((& $reportScript -Project 'fixture://agent-overlap' -Period 1h -AsOf $asOf -FixturePath $overlapSearchPath -TraceFixturePath $overlapTracesPath -Format markdown) -match 'Timing coverage.*Wait share') 'Markdown must expose partial timing coverage and wait share.'
    'agent execution active/wait overlap regression: PASS'

    $falseRecovery = ($validTraces.PSObject.Properties[$validTraceId].Value | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    $falseRecovery.resourceSpans[0].scopeSpans[0].spans[9].attributes += New-Attribute 'recovered' 'false' 'boolValue'
    $trueRecovery = ($validTraces.PSObject.Properties[$validTraceId].Value | ConvertTo-Json -Depth 30) | ConvertFrom-Json
    $trueRecovery.resourceSpans[0].scopeSpans[0].spans[9].attributes += New-Attribute 'recovered' 'true' 'boolValue'
    function Get-RecoveryReport($Trace, [string]$TraceId, [string]$Stem, [string]$Format = 'json') {
        $searchFile = Join-Path $tempRoot ($Stem + '-search.json'); $traceFile = Join-Path $tempRoot ($Stem + '-traces.json')
        $Trace.resourceSpans[0].scopeSpans[0].spans[0].attributes[0].value.stringValue = 'fixture://agent-recovery'
        (New-Search @($TraceId) 'fixture://agent-recovery') | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $searchFile -Encoding utf8
        ([pscustomobject]@{$TraceId=$Trace}) | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $traceFile -Encoding utf8
        return & $reportScript -Project 'fixture://agent-recovery' -Period 1h -AsOf $asOf -FixturePath $searchFile -TraceFixturePath $traceFile -Format $Format
    }
    Assert-Equal @($concurrent.agentExecution.agents | Where-Object agentId -eq 'agent-ok')[0].recovered $null 'missing recovery remains unknown'
    $falseJson = Get-RecoveryReport $falseRecovery '66666666666666666666666666666666' 'recovered-false' | ConvertFrom-Json
    $trueJson = Get-RecoveryReport $trueRecovery '77777777777777777777777777777777' 'recovered-true' | ConvertFrom-Json
    Assert-Equal @($falseJson.agentExecution.agents | Where-Object agentId -eq 'agent-ok')[0].recovered $false 'explicit false recovery'
    Assert-Equal @($trueJson.agentExecution.agents | Where-Object agentId -eq 'agent-ok')[0].recovered $true 'explicit true recovery'
    Assert-True ((Get-RecoveryReport $falseRecovery '88888888888888888888888888888888' 'recovered-false-markdown' 'markdown') -match '\| False \|') 'Markdown must preserve explicit false recovery.'
    Assert-True ((Get-RecoveryReport $trueRecovery '99999999999999999999999999999999' 'recovered-true-markdown' 'markdown') -match '\| True \|') 'Markdown must preserve explicit true recovery.'
    Assert-True (($concurrent | ConvertTo-Json -Depth 20) -notmatch '"recovered"\s*:\s*false') 'Missing recovery became false in JSON.'
    'agent execution recovery unknown/false/true regression: PASS'

    if (-not $SkipGrafana) {
        . $traceActivity
        $dashboard = (Invoke-RestMethod -Uri "$GrafanaBaseUrl/api/dashboards/uid/codex-overview" -TimeoutSec 10).dashboard
        $availabilityPanel = @($dashboard.panels | Where-Object id -eq 25)[0]
        $availabilityTarget = $availabilityPanel.targets[0]
        $noEvidenceQuery = $availabilityTarget.query.Replace('${cwd:regex}', 'fixture://agent-no-evidence')
        $noEvidenceBody = @{from='1788504600000';to='1788508800000';queries=@(@{refId='N';datasource=$availabilityTarget.datasource;queryType=$availabilityTarget.queryType;tableType=$availabilityTarget.tableType;limit=$availabilityTarget.limit;spss=$availabilityTarget.spss;query=$noEvidenceQuery})} | ConvertTo-Json -Depth 10
        $noEvidence = Invoke-RestMethod -Uri "$GrafanaBaseUrl/api/ds/query" -Method Post -ContentType 'application/json' -Body $noEvidenceBody -TimeoutSec 15
        Assert-Equal $noEvidence.results.N.status 200 'Actual Grafana no-evidence availability query status'
        $noEvidenceValues = @($noEvidence.results.N.frames | ForEach-Object { $_.data.values } | ForEach-Object { $_ } | ForEach-Object { $_ } | Where-Object { $null -ne $_ })
        Assert-Equal $noEvidenceValues.Count 0 'Actual Grafana no-evidence availability query has no numeric zero bucket'
        $agentKpiPanel = @($dashboard.panels | Where-Object id -eq 23)[0]
        $expression = @($agentKpiPanel.targets | Where-Object refId -eq 'B')[0].expression
        $agentRows = @($validTraces.PSObject.Properties | ForEach-Object { ConvertFrom-TraceActivity $_.Value $_.Name 1788504600000 1788508800000 'fixture://agent' } | Where-Object { $_.name -eq 'codex.agent.lifecycle' -and $_.'codex.agent.signal_version' -eq '1' })
        $body = @{from='1788504600000';to='1788508800000';queries=@(@{refId='Z';datasource=@{type='__expr__';uid='__expr__'};type='sql';expression=('WITH A AS (' + (ConvertTo-AgentSqlTable $agentRows) + '), ' + ($expression -replace '^WITH\s+',''))})} | ConvertTo-Json -Depth 10
        $response = Invoke-RestMethod -Uri "$GrafanaBaseUrl/api/ds/query" -Method Post -ContentType 'application/json' -Body $body -TimeoutSec 15
        Assert-Equal $response.results.Z.status 200 'Actual Grafana agent KPI SQL status'
        $frame = $response.results.Z.frames[0]
        $fields = @($frame.schema.fields | ForEach-Object name)
        $values = @{}
        for ($i=0; $i -lt $fields.Count; $i++) { $values[$fields[$i]]=$frame.data.values[$i][0] }
        Assert-Equal $values['Agents'] 3 'Actual Grafana agent count'
        Assert-Equal $values['Delegations'] 2 'Actual Grafana delegation count'
        Assert-Equal $values['Failed / interrupted'] 1 'Actual Grafana failed agent count'
        Assert-Equal $values['Unclassified'] 0 'Actual Grafana unclassified agent count'
        Assert-Equal $values['Maximum depth'] '1' 'Actual Grafana maximum depth'
        'Actual Grafana agent KPI SQL: versioned synthetic lifecycle agrees with report counts PASS'
    }

    $badTraceId = '33333333333333333333333333333333'
    $badSpans = [System.Collections.Generic.List[object]]::new()
    $badSpans.Add((New-Span 30 'project_activity' 0 1 @((New-Attribute 'cwd' 'fixture://agent-bad'))))
    $badSpans.Add((New-Span 31 'codex.agent.lifecycle' 0 1000 (Agent-Attributes 'agent-duplicate' 'spawn' '0' -Interval 'active')))
    $badSpans.Add((New-Span 32 'codex.agent.lifecycle' 1000 2000 (Agent-Attributes 'agent-duplicate' 'spawn' '0' -Interval 'active')))
    $badSpans.Add((New-Span 33 'codex.agent.lifecycle' 0 1000 (Agent-Attributes 'agent-orphan' 'complete' '4' -Parent 'missing-agent' -Status 'completed')))
    $badSpans.Add((New-Span 34 'codex.agent.lifecycle' 0 1000 (Agent-Attributes 'agent-self' 'complete' '1' -Parent 'agent-self' -Status 'completed')))
    $badSpans.Add((New-Span 35 'codex.agent.lifecycle' 0 1000 (Agent-Attributes 'agent-cycle-a' 'complete' '1' -Parent 'agent-cycle-b' -Status 'completed')))
    $badSpans.Add((New-Span 36 'codex.agent.lifecycle' 0 1000 (Agent-Attributes 'agent-cycle-b' 'complete' '1' -Parent 'agent-cycle-a' -Status 'completed')))
    $badSpans.Add((New-Span 37 'codex.agent.lifecycle' 0 1000 @((New-Attribute 'codex.agent.signal_version' '9' 'intValue'),(New-Attribute 'codex.agent.instance_id' 'agent-unsupported'),(New-Attribute 'codex.agent.lifecycle' 'complete'))))
    $badSpans.Add((New-Span 38 'run_sampling_request' 0 1000 @()))
    $badSpans.Add((New-Span 39 'codex.agent.lifecycle' 3000 2000 (Agent-Attributes 'agent-bad-time' 'wait' '0' -Interval 'wait')))
    $badSpans.Add((New-Span 40 'codex.agent.lifecycle' 0 1000 (Agent-Attributes 'agent-bad-field' 'spawn' '0' -Role 'free form task text')))
    $badSpans.Add((New-Span 41 'codex.agent.lifecycle' 0 1000 (Agent-Attributes 'agent-bad-time' 'spawn' '0' -Interval 'active')))
    $badSpans.Add((New-Span 42 'codex.agent.lifecycle' 3000 4000 (Agent-Attributes 'agent-bad-time' 'complete' '0' -Status 'completed')))
    $badSearchPath = Join-Path $tempRoot 'bad-search.json'
    $badTracesPath = Join-Path $tempRoot 'bad-traces.json'
    (New-Search @($badTraceId) 'fixture://agent-bad') | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $badSearchPath -Encoding utf8
    ([pscustomobject]@{$badTraceId=(New-Trace @($badSpans))}) | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $badTracesPath -Encoding utf8
    $bad = & $reportScript -Project 'fixture://agent-bad' -Period 1h -AsOf $asOf -FixturePath $badSearchPath -TraceFixturePath $badTracesPath -Format json | ConvertFrom-Json
    Assert-Equal $bad.agentExecution.coverage 'partial' 'malformed agent coverage'
    $badWarnings = @($bad.agentExecution.warnings | ForEach-Object code)
    foreach ($warning in @('agent_contract_unsupported','agent_field_invalid','agent_duplicate_id','agent_invalid_parent','agent_parent_cycle','agent_depth_inconsistent','agent_terminal_outcome_missing','agent_timing_inconsistent','agent_activity_unattributed')) {
        Assert-True ($warning -in $badWarnings) "Malformed topology warning '$warning' is missing."
    }
    Assert-True (($bad | ConvertTo-Json -Depth 20) -notmatch 'free form task text') 'Unbounded role text leaked into the report.'
    'agent execution malformed topology coverage: PASS'

    # Full-trace hydration remains fail-closed, but failure diagnostics are
    # bounded and actionable without retaining any response body.
    function Assert-HydrationFailure([object]$Failure, [string]$ExpectedClass, [string]$ExpectedStatus, [string]$Stem) {
        $traceId = if($ExpectedClass -eq 'trace_too_large'){'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'}else{'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'}
        $searchFile = Join-Path $tempRoot ($Stem + '-search.json'); $traceFile = Join-Path $tempRoot ($Stem + '-traces.json')
        (New-Search @($traceId) 'fixture://hydration-failure') | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $searchFile -Encoding utf8
        ([pscustomobject]@{$traceId=[pscustomobject]@{hydrationFailure=$Failure}}) | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $traceFile -Encoding utf8
        $beforeJobs = @((Get-Job | ForEach-Object Id) | Sort-Object)
        $failed = $false
        try { & $reportScript -Project 'fixture://hydration-failure' -Period 1h -AsOf $asOf -FixturePath $searchFile -TraceFixturePath $traceFile -Format json | Out-Null } catch {
            $failed = $true; $message=$_.Exception.Message
            Assert-True ($message -match [regex]::Escape($traceId) -and $message -match [regex]::Escape($ExpectedClass) -and $message -match [regex]::Escape($ExpectedStatus)) "Hydration failure lost its bounded classification: $message"
            Assert-True ($message -notmatch 'PRIVATE_RESPONSE_BODY|headers|stacktrace') 'Hydration failure leaked an unsafe response detail.'
        }
        Assert-True $failed 'Hydration failure must fail closed.'
        Assert-Equal ((@(Get-Job | ForEach-Object Id | Sort-Object) -join ',')) ($beforeJobs -join ',') 'Hydration failure leaves no job behind'
    }
    Assert-HydrationFailure ([pscustomobject]@{status=422;failureClass='trace_too_large'}) 'trace_too_large' '422' 'hydration-422'
    Assert-HydrationFailure ([pscustomobject]@{failureClass='transport_error'}) 'transport_error' 'none' 'hydration-transport'
    'agent execution bounded hydration failure regression: PASS'

    . $traceActivity
    $worktreeTrace = New-Trace @((New-Span 40 'project_activity' 0 1 @((New-Attribute 'cwd' 'fixture://worktrees/agent/task'),(New-Attribute 'codex.project.identity' 'repo-fixture'))))
    $worktreeRows = @(ConvertFrom-TraceActivity $worktreeTrace $auxTraceId 1788504600000 1788508800000 'fixture://worktrees/agent/task')
    Assert-Equal $worktreeRows[0].'codex.project.identity' 'repo-fixture' 'shared opaque project identity survives allowlist'
    $rejected = $false
    try { $null = @(ConvertFrom-TraceActivity $worktreeTrace $auxTraceId 1788504600000 1788508800000 'fixture://agent') } catch { $rejected = $_.Exception.Message -match 'exact selected project' }
    Assert-True $rejected 'Exact Project cwd must not merge a worktree despite shared project identity.'
    'agent execution project identity and exact cwd scope: PASS'
} finally {
    if (Test-Path -LiteralPath $tempRoot) { Remove-Item -LiteralPath $tempRoot -Recurse -Force }
}
