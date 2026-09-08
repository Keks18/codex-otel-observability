[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [ValidatePattern('^\d+(m|h|d|w)$')][string]$Period = '6h',
    [ValidateSet('json', 'markdown')][string]$Format = 'json',
    [ValidateRange(1, 1000)][int]$MaxTurns = 500,
    [string]$AsOf,
    [string]$GrafanaBaseUrl = 'http://127.0.0.1:3000',
    [string]$FixturePath,
    [string]$TraceFixturePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$contractVersion = '4.0'
. (Join-Path $PSScriptRoot 'trace-activity.ps1')

function ConvertTo-TraceQlString([string]$Value) {
    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}
function Get-PeriodSpan([string]$Value) {
    $n = [int]$Value.Substring(0, $Value.Length - 1)
    switch ($Value.Substring($Value.Length - 1)) {
        'm' { [TimeSpan]::FromMinutes($n) }
        'h' { [TimeSpan]::FromHours($n) }
        'd' { [TimeSpan]::FromDays($n) }
        'w' { [TimeSpan]::FromDays(7 * $n) }
    }
}
function ConvertFrom-GrafanaFrame($Frame) {
    if ($null -eq $Frame -or $null -eq $Frame.data -or $null -eq $Frame.data.values) { return @() }
    $names = @($Frame.schema.fields | ForEach-Object name)
    $columns = @($Frame.data.values)
    if ($names.Count -eq 0 -or $columns.Count -eq 0) { return @() }
    $rows = @()
    for ($i = 0; $i -lt @($columns[0]).Count; $i++) {
        $item = [ordered]@{}
        for ($j = 0; $j -lt $names.Count; $j++) {
            $column = @($columns[$j])
            $item[$names[$j]] = if ($i -lt $column.Count) { $column[$i] } else { $null }
        }
        $rows += [pscustomobject]$item
    }
    return $rows
}
function Get-Result($Response, [string]$RefId) {
    $property = $Response.results.PSObject.Properties[$RefId]
    if ($null -eq $property) { throw "Grafana response is missing query result '$RefId'." }
    $result = $property.Value
    if ($null -ne $result.status -and [int]$result.status -notin @(200, 206)) {
        throw "Grafana query '$RefId' failed: $($result.error)"
    }
    return $result
}
function Get-Rows($Response, [string]$RefId) {
    $rows = @()
    foreach ($frame in @((Get-Result $Response $RefId).frames)) { $rows += @(ConvertFrom-GrafanaFrame $frame) }
    return $rows
}
function Get-Value($Row, [string[]]$Names, $Default = $null) {
    foreach ($name in $Names) {
        $p = $Row.PSObject.Properties[$name]
        if ($null -ne $p -and $null -ne $p.Value -and [string]$p.Value -ne '') { return $p.Value }
    }
    return $Default
}
function Test-Value($Row, [string[]]$Names) {
    foreach ($name in $Names) {
        $p = $Row.PSObject.Properties[$name]
        if ($null -ne $p -and $null -ne $p.Value -and [string]$p.Value -ne '') { return $true }
    }
    return $false
}
function Get-TraceId($Row) { [string](Get-Value $Row @('traceIdHidden', 'traceID', 'trace_id') '') }
function Get-TimeMs($Row) { [long](Get-Value $Row @('time', 'startTime', 'timestamp') 0) }
function Get-DurationMs($Row) { [math]::Round(([double](Get-Value $Row @('duration', 'durationNs') 0)) / 1000000, 3) }
function Get-Interval($Row) {
    $start = if (Test-Value $Row @('startTimeUnixNano')) { [decimal](Get-Value $Row @('startTimeUnixNano') 0) } else { [decimal](Get-TimeMs $Row) * 1000000 }
    $end = if (Test-Value $Row @('endTimeUnixNano')) { [decimal](Get-Value $Row @('endTimeUnixNano') 0) } else { $start + [decimal](Get-Value $Row @('duration','durationNs') 0) }
    [pscustomobject]@{ Start = $start; End = $end }
}
function Get-UnionDurationMs($Rows, [decimal]$ClipStart, [decimal]$ClipEnd) {
    $intervals = @($Rows | ForEach-Object {
        $interval = Get-Interval $_
        $start = [decimal][math]::Max($interval.Start, $ClipStart)
        $end = [decimal][math]::Min($interval.End, $ClipEnd)
        if ($end -gt $start) { [pscustomobject]@{ Start = $start; End = $end } }
    } | Sort-Object Start, End)
    if ($intervals.Count -eq 0) { return 0.0 }
    $total = [decimal]0
    $currentStart = $intervals[0].Start
    $currentEnd = $intervals[0].End
    foreach ($interval in @($intervals | Select-Object -Skip 1)) {
        if ($interval.Start -le $currentEnd) {
            if ($interval.End -gt $currentEnd) { $currentEnd = $interval.End }
        } else {
            $total += $currentEnd - $currentStart
            $currentStart = $interval.Start
            $currentEnd = $interval.End
        }
    }
    $total += $currentEnd - $currentStart
    return [math]::Round([double]($total / 1000000), 3)
}
function Get-Bool($Value) { $null -ne $Value -and [string]$Value -in @('true', 'True', '1') }
function Get-Percentile([double[]]$Values, [double]$P) {
    if ($Values.Count -eq 0) { return 0 }
    $sorted = @($Values | Sort-Object)
    [math]::Round([double]$sorted[[math]::Max([math]::Ceiling($P * $sorted.Count) - 1, 0)], 3)
}
function Get-Count($Items) { @($Items).Count }
function Get-Sum($Items, [string]$Property) {
    if (@($Items).Count -eq 0) { return 0 }
    return ($Items | Measure-Object $Property -Sum).Sum
}
function Get-ObservedSum($Items, [string]$Property) {
    $observed = @($Items | Where-Object { $null -ne $_.$Property })
    if ($observed.Count -eq 0) { return $null }
    return (Get-Sum $observed $Property)
}
function ConvertTo-Md($Value) {
    if ($null -eq $Value) { return '' }
    ([string]$Value).Replace('|', '\|').Replace([char]13, ' ').Replace([char]10, ' ')
}

$warnings = [System.Collections.Generic.List[object]]::new()
function Add-Warning([string]$Code, [int]$Count, [string]$Message) {
    if ($Count -le 0) { return }
    $existing = @($warnings | Where-Object code -eq $Code)
    if ($existing.Count) {
        $existing[0].count = [int]$existing[0].count + $Count
    } else {
        $warnings.Add([pscustomobject][ordered]@{ code = $Code; count = $Count; message = $Message })
    }
}

$asOfValue = if ([string]::IsNullOrWhiteSpace($AsOf)) {
    [DateTimeOffset]::UtcNow
} else {
    [DateTimeOffset]::Parse($AsOf, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal)
}
$asOfValue = $asOfValue.ToUniversalTime()
$fromValue = $asOfValue.Subtract((Get-PeriodSpan $Period))
$toMs = $asOfValue.ToUnixTimeMilliseconds()

$projectLiteral = ConvertTo-TraceQlString $Project
$projectSet = '{ span.cwd = ' + $projectLiteral + ' }'
$tempo = @{ type = 'tempo'; uid = 'tempo' }
$terminal = 'dispatch_tool_call_with_terminal_outcome'
$selectTools = 'select(event.tool_name, span.tool_name, span."codex.tool.name", span.call_id, span."codex.tool.call_id", span.nested, span.retry_count, span.recovered, event.success, span.failure_class, span.reason_summary, span."error.kind", span."process.exit_code", span."process.success")'
$queries = @(
    @{ refId='A'; datasource=$tempo; queryType='traceqlSearch'; tableType='spans'; limit=$MaxTurns; spss=100; query='(' + $projectSet + ' && { name = "session_task.turn" || name = "codex.turn.terminal" }) | { name = "session_task.turn" || name = "codex.turn.terminal" } | select(span."codex.turn.status", span."codex.turn.signal_version", span.model, span."codex.turn.reasoning_effort", span."codex.turn.token_usage.input_tokens", span."codex.turn.token_usage.output_tokens", span."codex.turn.token_usage.reasoning_output_tokens", span."codex.turn.token_usage.cached_input_tokens", span."codex.turn.token_usage.total_tokens")' },
    @{ refId='B'; datasource=$tempo; queryType='traceqlSearch'; tableType='spans'; limit=$MaxTurns; spss=20; query=$projectSet + ' | select(span.cwd)' },
    @{ refId='C'; datasource=$tempo; queryType='traceqlSearch'; tableType='spans'; limit=$MaxTurns; spss=100; query='(' + $projectSet + ' && { name = "' + $terminal + '" }) | { name = "' + $terminal + '" } | ' + $selectTools },
    @{ refId='D'; datasource=$tempo; queryType='traceqlSearch'; tableType='spans'; limit=$MaxTurns; spss=100; query='(' + $projectSet + ' && { name = "' + $terminal + '" && event.success = "false" }) | { name = "' + $terminal + '" && event.success = "false" } | ' + $selectTools },
    @{ refId='R'; datasource=$tempo; queryType='traceqlSearch'; tableType='spans'; limit=$MaxTurns; spss=100; query='(' + $projectSet + ' && { name = "responses_websocket.stream_request" }) | { name = "responses_websocket.stream_request" }' },
    @{ refId='S'; datasource=$tempo; queryType='traceqlSearch'; tableType='spans'; limit=$MaxTurns; spss=100; query='(' + $projectSet + ' && { name = "run_sampling_request" }) | { name = "run_sampling_request" }' }
)
if ($FixturePath) {
    $response = Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json
} else {
    $body = @{ queries=$queries; from=[string]$fromValue.ToUnixTimeMilliseconds(); to=[string]$toMs } | ConvertTo-Json -Depth 15
    try {
        $response = Invoke-RestMethod -Uri "$($GrafanaBaseUrl.TrimEnd('/'))/api/ds/query" -Method Post -ContentType 'application/json' -Body $body
    } catch {
        throw "Unable to query Grafana at '$GrafanaBaseUrl'. $($_.Exception.Message)"
    }
}

$raw = @{}
foreach ($ref in @('A','B','C','D','R','S')) {
    $raw[$ref] = @(Get-Rows $response $ref)
    $result = Get-Result $response $ref
    if (($null -ne $result.status -and [int]$result.status -eq 206) -or
        ($null -ne $result.PSObject.Properties['partial'] -and (Get-Bool $result.partial))) {
        Add-Warning 'oversized_or_partial' 1 "Query $ref returned partial data."
    }
}

# Search span sets are discovery results, not complete trace contents. Tempo can
# omit spans split across stored blocks even below spss and without HTTP 206.
# Hydrate each discovered activity trace once, then deduplicate by span/call ID.
if (-not $FixturePath -or $TraceFixturePath) {
    $traceIds = @(@($raw.A + $raw.B + $raw.C + $raw.D + $raw.R + $raw.S) | ForEach-Object { Get-TraceId $_ } | Where-Object { $_ } | Sort-Object -Unique)
    $activity = [System.Collections.Generic.List[object]]::new()
    $traceFixtures = if ($TraceFixturePath) { Get-Content -Raw $TraceFixturePath | ConvertFrom-Json } else { $null }
    $hydration = @{}
    foreach ($traceId in $traceIds) {
        if ($traceFixtures) {
            $traceResponse = $traceFixtures.PSObject.Properties[$traceId].Value
            $traceContent = $traceResponse | ConvertTo-Json -Depth 100 -Compress
        } else {
            if ($traceId -notmatch '^[0-9a-fA-F]{1,32}$') { throw 'Invalid trace ID returned by Tempo.' }
            $traceHttp = Invoke-WebRequest -UseBasicParsing -Uri "$($GrafanaBaseUrl.TrimEnd('/'))/api/datasources/proxy/uid/tempo/api/traces/$traceId" -Method Get
            $traceContent = [string]$traceHttp.Content
            $traceResponse = $traceContent | ConvertFrom-Json
        }
        $traceBatches = @(Get-TraceProperty $traceResponse 'batches' @()) + @(Get-TraceProperty $traceResponse 'resourceSpans' @())
        $traceSpans = @($traceBatches | ForEach-Object {
            $traceScopes = @(Get-TraceProperty $_ 'scopeSpans' @()) + @(Get-TraceProperty $_ 'instrumentationLibrarySpans' @())
            foreach ($traceScope in $traceScopes) { @(Get-TraceProperty $traceScope 'spans' @()) }
        })
        $hydration[$traceId] = [pscustomobject][ordered]@{
            hydratedSpanCount = $traceSpans.Count
            hydratedPayloadBytes = [Text.Encoding]::UTF8.GetByteCount($traceContent)
        }
        # A failed hydration must fail the report, never silently produce totals
        # from a mixture of complete and truncated search span sets.
        foreach ($row in @(ConvertFrom-TraceActivity $traceResponse $traceId $fromValue.ToUnixTimeMilliseconds() $toMs $Project)) { $activity.Add($row) }
    }
    foreach ($ref in @('A','B','C','R','S')) { $raw[$ref]=@($activity | Where-Object source -eq $ref) }
    $raw.D=@($raw.C | Where-Object { (Get-Value $_ @('event.success') '') -in @('false','False','0') })
} else {
    $hydration = @{}
}

# Status is independent of token coverage. Explicit terminal failure wins over
# a legacy success candidate; contradictory terminal signals are never hidden.
function Test-TokenUsage($Row) {
    (Test-Value $Row @('codex.turn.token_usage.total_tokens')) -or
    ((Test-Value $Row @('codex.turn.token_usage.input_tokens')) -and (Test-Value $Row @('codex.turn.token_usage.output_tokens')))
}
$completedRows = @()
$failedRows = @()
$unclassifiedRows = @()
$duplicateTurns = 0
$allActivity = @($raw.A + $raw.B + $raw.C + $raw.R + $raw.S)
foreach ($group in @($allActivity | Where-Object { Get-TraceId $_ } | Group-Object { Get-TraceId $_ })) {
    $candidates = @($raw.A | Where-Object { (Get-TraceId $_) -eq $group.Name -and ((Get-Value $_ @('name') 'session_task.turn') -eq 'session_task.turn' -or ((Get-Value $_ @('name') '') -eq 'codex.turn.terminal' -and (Get-Value $_ @('codex.turn.signal_version') 0) -eq 1)) } | Sort-Object { Get-TimeMs $_ } -Descending)
    $explicit = @($candidates | Where-Object {
        (Get-Value $_ @('name') '') -eq 'codex.turn.terminal' -and
        [int](Get-Value $_ @('codex.turn.signal_version') 0) -eq 1 -and
        (Get-Value $_ @('codex.turn.status') '') -in @('completed','failed','interrupted')
    })
    $fail = @($explicit | Where-Object { (Get-Value $_ @('codex.turn.status') '') -in @('failed','interrupted') })
    $success = @($explicit | Where-Object { (Get-Value $_ @('codex.turn.status') '') -eq 'completed' })
    $legacy = @($candidates | Where-Object {
        (Get-Value $_ @('name') 'session_task.turn') -eq 'session_task.turn' -and
        (Get-Value $_ @('codex.turn.status') '') -notin @('failed','interrupted') -and (Test-TokenUsage $_)
    })
    $duplicateTurns += [math]::Max($candidates.Count - 1, 0)
    if ($fail.Count) {
        $row = $fail[0]; $state = 'failed'; $completionSignal = 'explicit'
        if ($success.Count -or $legacy.Count) { Add-Warning 'conflicting_terminal_signals' 1 'Failure takes precedence over a success candidate on the same trace.' }
    } elseif ($success.Count) {
        $row = $success[0]; $state = 'completed'; $completionSignal = 'explicit'
    } elseif ($legacy.Count) {
        $row = $legacy[0]; $state = 'completed'; $completionSignal = 'legacy'
        Add-Warning 'legacy_completion_signal' 1 'Completion inferred from legacy turn token usage; adopt the explicit terminal signal.'
    } else {
        $row = @($group.Group | Sort-Object { Get-TimeMs $_ } -Descending)[0]; $state = 'unclassified'; $completionSignal = 'missing'
    }
    # Token attributes may be on a separate canonical legacy span in the trace.
    # Never sum token fields across duplicate or nested spans.
    $usage = @($candidates | Where-Object { Test-TokenUsage $_ })
    $item = [ordered]@{}
    foreach ($property in $row.PSObject.Properties) { $item[$property.Name] = $property.Value }
    $item['turnStatus'] = $state
    $item['completionSignal'] = $completionSignal
    $item['tokenUsageAvailable'] = ($usage.Count -gt 0)
    if ($usage.Count) {
        foreach ($property in $usage[0].PSObject.Properties) {
            if ($property.Name -like 'codex.turn.token_usage.*' -or $property.Name -in @('model','codex.turn.reasoning_effort')) { $item[$property.Name]=$property.Value }
        }
    }
    $canonical = [pscustomobject]$item
    switch ($state) {
        'completed' { $completedRows += $canonical }
        'failed' { $failedRows += $canonical }
        'unclassified' { $unclassifiedRows += $canonical }
    }
}
Add-Warning 'duplicate_turn_span' $duplicateTurns 'Multiple lifecycle/token spans were reduced to one trace; token usage was not summed.'
Add-Warning 'completed_without_token_usage' @($completedRows | Where-Object { -not $_.tokenUsageAvailable }).Count 'Completed turn has no token usage; token totals are partial or unknown.'
Add-Warning 'failed_turn' $failedRows.Count 'Explicit failed or interrupted terminal outcome; excluded from completed-turn KPI.'
Add-Warning 'missing_turn_or_root' $unclassifiedRows.Count 'Scoped trace has no recognized terminal signal; age cannot determine its outcome.'
Add-Warning 'turn_role_unavailable' @($completedRows).Count 'No stable upstream attribute distinguishes user-visible turns from orchestration/setup traces; every completed trace remains visible.'
foreach ($ref in @('A','B','C','D','R','S')) {
    if (@($raw[$ref] | ForEach-Object { Get-TraceId $_ } | Sort-Object -Unique).Count -ge $MaxTurns) { Add-Warning 'query_limit_reached' 1 "Query $ref reached MaxTurns." }
}

$rounds = @{}
$sampling = @{}
foreach ($row in $raw.R) { $trace=Get-TraceId $row; if ($trace) { $rounds[$trace]=1+$(if($rounds.ContainsKey($trace)){$rounds[$trace]}else{0}) } }
foreach ($row in $raw.S) { $trace=Get-TraceId $row; if ($trace) { $sampling[$trace]=(Get-DurationMs $row)+$(if($sampling.ContainsKey($trace)){$sampling[$trace]}else{0}) } }

$toolCalls = @{}
$duplicates = 0
foreach ($row in $raw.C) {
    if (Get-Bool (Get-Value $row @('nested') $false)) { continue }
    $trace = Get-TraceId $row
    if (-not $trace) { continue }
    $call = [string](Get-Value $row @('call_id','codex.tool.call_id','spanID','spanId') '')
    if (-not $call) { $call = 'fallback-' + [string](Get-TimeMs $row) }
    $key = $trace + ':' + $call
    if ($toolCalls.ContainsKey($key)) { $duplicates++; if ((Get-TimeMs $row) -le (Get-TimeMs $toolCalls[$key])) { continue } }
    $toolCalls[$key] = $row
}
Add-Warning 'duplicate_tool_call' $duplicates 'Newest terminal outcome was selected for duplicate call IDs.'
$failures = @{}
foreach ($row in $raw.D) {
    if (Get-Bool (Get-Value $row @('nested') $false)) { continue }
    $trace = Get-TraceId $row
    $call = [string](Get-Value $row @('call_id','codex.tool.call_id','spanID','spanId') '')
    if ($trace -and $call) { $failures[$trace + ':' + $call] = $row }
}
$orphanFailureCount = @($failures.Keys | Where-Object { -not $toolCalls.ContainsKey($_) }).Count
Add-Warning 'tool_source_discrepancy' $orphanFailureCount 'Failure did not match the canonical terminal-call set.'

$toolMs = @{}
foreach ($row in $toolCalls.Values) {
    $trace = Get-TraceId $row
    $toolMs[$trace] = (Get-DurationMs $row) + $(if($toolMs.ContainsKey($trace)){$toolMs[$trace]}else{0})
}

function Get-ToolName($Row) { [string](Get-Value $Row @('event.tool_name','tool_name','span.tool_name','codex.tool.name','span.codex.tool.name') 'unknown') }
function Test-CommandTool($Row) { (Get-ToolName $Row) -match '^(?i:shell|exec|exec_command|write_stdin)$' }
$commandCalls = @($toolCalls.GetEnumerator() | Where-Object { Test-CommandTool $_.Value })
$processOutcomesByKey = @{}
foreach ($entry in $commandCalls) {
    $callRow = $entry.Value
    $trace = Get-TraceId $callRow
    $call = [string](Get-Value $callRow @('call_id','codex.tool.call_id') '')
    $candidates = @($callRow) + @($raw.B | Where-Object {
        (Get-TraceId $_) -eq $trace -and $call -and
        [string](Get-Value $_ @('call_id','codex.tool.call_id') '') -eq $call
    })
    $outcome = @($candidates | Where-Object {
        (Test-Value $_ @('process.exit_code')) -or (Test-Value $_ @('process.success'))
    } | Sort-Object { Get-TimeMs $_ } -Descending | Select-Object -First 1)
    if ($outcome.Count) { $processOutcomesByKey[[string]$entry.Key] = $outcome[0] }
}
$commandOutcomes = @($processOutcomesByKey.GetEnumerator())
$processFailures = @($commandOutcomes | Where-Object {
    ((Test-Value $_.Value @('process.exit_code')) -and [long](Get-Value $_.Value @('process.exit_code') 0) -ne 0) -or
    ((Test-Value $_.Value @('process.success')) -and -not (Get-Bool (Get-Value $_.Value @('process.success') $false)))
})
$processCoverage = if ($commandCalls.Count -eq 0) { 'not_applicable' } elseif ($commandOutcomes.Count -eq 0) { 'unavailable' } elseif ($commandOutcomes.Count -lt $commandCalls.Count) { 'partial' } else { 'available' }
if ($processCoverage -in @('unavailable','partial')) {
    Add-Warning 'process_outcome_coverage_incomplete' ($commandCalls.Count - $commandOutcomes.Count) 'Shell command exit outcome is not fully observable; combined tool failure rate is unavailable.'
}
$combinedFailureKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
foreach ($key in $failures.Keys) { if ($toolCalls.ContainsKey($key)) { $null = $combinedFailureKeys.Add($key) } }
foreach ($entry in $processFailures) { $null = $combinedFailureKeys.Add([string]$entry.Key) }
$combinedFailureCount = if ($processCoverage -in @('available','not_applicable')) { $combinedFailureKeys.Count } else { $null }

$turns = @()
$overlap = 0
$intervalCoverageWarnings = 0
foreach ($row in $completedRows) {
    $trace = Get-TraceId $row
    $input = [long](Get-Value $row @('codex.turn.token_usage.input_tokens') 0)
    $cached = [long](Get-Value $row @('codex.turn.token_usage.cached_input_tokens') 0)
    $output = [long](Get-Value $row @('codex.turn.token_usage.output_tokens') 0)
    $reasoning = [long](Get-Value $row @('codex.turn.token_usage.reasoning_output_tokens') 0)
    $total = [long](Get-Value $row @('codex.turn.token_usage.total_tokens') ($input + $output))
    $duration = Get-DurationMs $row
    $samplingMs = if($sampling.ContainsKey($trace)){[double]$sampling[$trace]}else{0}
    $toolDurationMs = if($toolMs.ContainsKey($trace)){[double]$toolMs[$trace]}else{0}
    $turnInterval = Get-Interval $row
    $samplingRows = @($raw.S | Where-Object { (Get-TraceId $_) -eq $trace })
    $toolRows = @($toolCalls.Values | Where-Object { (Get-TraceId $_) -eq $trace })
    $samplingWallClockMs = Get-UnionDurationMs $samplingRows $turnInterval.Start $turnInterval.End
    $toolWallClockMs = Get-UnionDurationMs $toolRows $turnInterval.Start $turnInterval.End
    $observedComponentWallClockMs = Get-UnionDurationMs @($samplingRows + $toolRows) $turnInterval.Start $turnInterval.End
    $samplingToolOverlapMs = [math]::Round([math]::Max($samplingWallClockMs + $toolWallClockMs - $observedComponentWallClockMs, 0), 3)
    if ($samplingToolOverlapMs -gt 0 -or $samplingMs + $toolDurationMs -gt $duration) { $overlap++ }
    if (-not $hydration.ContainsKey($trace)) { $intervalCoverageWarnings++ }
    $diagnostic = if ($hydration.ContainsKey($trace)) { $hydration[$trace] } else { $null }
    $time = Get-TimeMs $row
    $turns += [pscustomobject][ordered]@{
        timestamp=if($time){[DateTimeOffset]::FromUnixTimeMilliseconds($time).ToUniversalTime().ToString('o')}else{$null}
        model=[string](Get-Value $row @('model') 'unknown')
        reasoningEffort=[string](Get-Value $row @('codex.turn.reasoning_effort') 'unknown')
        durationMs=$duration
        modelRounds=if($rounds.ContainsKey($trace)){[int]$rounds[$trace]}else{0}
        modelSamplingCumulativeMs=[math]::Round($samplingMs,3)
        toolCumulativeDurationMs=[math]::Round($toolDurationMs,3)
        modelSamplingWallClockMs=$samplingWallClockMs
        toolWallClockMs=$toolWallClockMs
        samplingToolOverlapMs=$samplingToolOverlapMs
        observedComponentWallClockMs=$observedComponentWallClockMs
        otherMs=[math]::Round([math]::Max($duration-$observedComponentWallClockMs,0),3)
        timeBreakdownCoverage=if($null -ne $diagnostic){'hydrated'}else{'search_preview'}
        hydratedSpanCount=if($null -ne $diagnostic){$diagnostic.hydratedSpanCount}else{$null}
        hydratedPayloadBytes=if($null -ne $diagnostic){$diagnostic.hydratedPayloadBytes}else{$null}
        status='completed'
        tokenUsageStatus=if($row.tokenUsageAvailable){'available'}else{'missing'}
        inputTokens=if(Test-Value $row @('codex.turn.token_usage.input_tokens')){$input}else{$null}
        cachedInputTokens=if(Test-Value $row @('codex.turn.token_usage.cached_input_tokens')){$cached}else{$null}
        nonCachedInputTokens=if((Test-Value $row @('codex.turn.token_usage.input_tokens')) -and (Test-Value $row @('codex.turn.token_usage.cached_input_tokens'))){[math]::Max($input-$cached,0)}else{$null}
        outputTokens=if(Test-Value $row @('codex.turn.token_usage.output_tokens')){$output}else{$null}
        reasoningTokens=if(Test-Value $row @('codex.turn.token_usage.reasoning_output_tokens')){$reasoning}else{$null}
        totalTokens=if($row.tokenUsageAvailable){$total}else{$null}
        cacheHitPct=if(-not ((Test-Value $row @('codex.turn.token_usage.input_tokens')) -and (Test-Value $row @('codex.turn.token_usage.cached_input_tokens')))){$null}elseif($input){[math]::Round(100*$cached/$input,2)}else{0}
        toolCalls=@($toolCalls.Keys|Where-Object{$_.StartsWith($trace+':')}).Count
        dispatchFailures=@($failures.Keys|Where-Object{$_.StartsWith($trace+':') -and $toolCalls.ContainsKey($_)}).Count
        traceId=$trace
    }
}
$turns = @($turns | Sort-Object timestamp -Descending | Select-Object -First $MaxTurns)
Add-Warning 'component_duration_overlap' $overlap 'Sampling and tool intervals overlap or cumulative duration exceeds the turn; wall-clock union remains bounded.'
Add-Warning 'time_breakdown_search_preview' $intervalCoverageWarnings 'Interval union used search previews because full trace hydration was unavailable.'
$largeHydratedTraces = @($hydration.GetEnumerator() | Where-Object { $_.Value.hydratedPayloadBytes -ge 15000000 })
Add-Warning 'trace_pressure' $largeHydratedTraces.Count 'Hydrated trace JSON is large; payload bytes are HTTP JSON diagnostics, not Tempo internal per-trace byte accounting.'

$failedCalls = @()
foreach ($key in @($failures.Keys | Where-Object { $toolCalls.ContainsKey($_) })) {
    $f=$failures[$key]; $t=$toolCalls[$key]
    $reason=[string](Get-Value $f @('reason_summary','failure_class','error.kind') 'No bounded reason was exported')
    if($reason.Length -gt 160){$reason=$reason.Substring(0,160)}
    $failedCalls += [pscustomobject][ordered]@{
        tool=Get-ToolName $t
        failureClass=[string](Get-Value $f @('failure_class','error.kind') 'unknown')
        reasonSummary=$reason.Replace([char]13,' ').Replace([char]10,' ')
        nested=$false
        retryCount=[int](Get-Value $f @('retry_count') 0)
        recovered=Get-Bool (Get-Value $f @('recovered') $false)
        durationMs=Get-DurationMs $t
        traceId=Get-TraceId $f
        callId=[string](Get-Value $f @('call_id','codex.tool.call_id','spanID') '')
    }
}

$toolsByName = @()
foreach ($group in @($toolCalls.GetEnumerator() | Group-Object { Get-ToolName $_.Value })) {
    $durations=[double[]]@($group.Group|ForEach-Object{Get-DurationMs $_.Value})
    $failureCount=@($group.Group|Where-Object{$failures.ContainsKey($_.Key)}).Count
    $slowest=$group.Group|Sort-Object{Get-DurationMs $_.Value}-Descending|Select-Object -First 1
    $toolsByName += [pscustomobject][ordered]@{
        tool=$group.Name; calls=$group.Count; dispatchFailures=$failureCount
        p50DurationMs=Get-Percentile $durations 0.5
        p95DurationMs=Get-Percentile $durations 0.95
        maxDurationMs=[math]::Round(($durations|Measure-Object -Maximum).Maximum,3)
        slowestTraceId=Get-TraceId $slowest.Value
    }
}

$models = @()
foreach ($group in @($turns|Group-Object model)) {
    $modelInput=Get-ObservedSum $group.Group inputTokens
    $modelCached=Get-ObservedSum $group.Group cachedInputTokens
    $models += [pscustomobject][ordered]@{
        model=$group.Name; turns=$group.Count
        avgDurationMs=[math]::Round(($group.Group|Measure-Object durationMs -Average).Average,3)
        modelRounds=[int](Get-Sum $group.Group modelRounds)
        inputTokens=$modelInput; cachedInputTokens=$modelCached; nonCachedInputTokens=Get-ObservedSum $group.Group nonCachedInputTokens
        outputTokens=Get-ObservedSum $group.Group outputTokens
        reasoningTokens=Get-ObservedSum $group.Group reasoningTokens
        totalTokens=Get-ObservedSum $group.Group totalTokens
        cacheHitPct=if($null -eq $modelInput -or $null -eq $modelCached){$null}elseif($modelInput){[math]::Round(100*$modelCached/$modelInput,2)}else{0}
    }
}
$inputTotal=Get-ObservedSum $turns inputTokens
$cachedTotal=Get-ObservedSum $turns cachedInputTokens
$totalTotal=if(@($turns | Where-Object tokenUsageStatus -eq 'available').Count){[long](Get-Sum $turns totalTokens)}else{$null}
$report=[pscustomobject][ordered]@{
    schemaVersion=$contractVersion; project=$Project; period=$Period
    snapshot=[pscustomobject][ordered]@{from=$fromValue.ToString('o');asOf=$asOfValue.ToString('o')}
    summary=[pscustomobject][ordered]@{
        completedTurns=$completedRows.Count;failedTurns=$failedRows.Count;unclassifiedTurns=$unclassifiedRows.Count
        failedOrUnclassifiedTurns=$failedRows.Count+$unclassifiedRows.Count
        completedWithoutTokenUsage=@($completedRows | Where-Object { -not $_.tokenUsageAvailable }).Count
        avgDurationMs=if($turns.Count){[math]::Round(($turns|Measure-Object durationMs -Average).Average,3)}else{0}
        totalTokens=$totalTotal;cacheHitPct=if($null -eq $inputTotal -or $null -eq $cachedTotal){$null}elseif($inputTotal){[math]::Round(100*$cachedTotal/$inputTotal,2)}else{0}
        toolCalls=$toolCalls.Count;toolDispatchFailures=$failedCalls.Count;processFailures=$processFailures.Count
        toolFailures=$combinedFailureCount
        toolFailureRatePct=if($null -eq $combinedFailureCount -or $toolCalls.Count -eq 0){$null}else{[math]::Round(100*$combinedFailureCount/$toolCalls.Count,2)}
    }
    tokens=[pscustomobject][ordered]@{
        input=$inputTotal;cachedInput=$cachedTotal;nonCachedInput=Get-ObservedSum $turns nonCachedInputTokens
        output=Get-ObservedSum $turns outputTokens;reasoning=Get-ObservedSum $turns reasoningTokens;total=$totalTotal
        coverage=if($turns.Count -eq 0 -or @($turns | Where-Object tokenUsageStatus -eq 'available').Count -eq 0){'missing'}elseif(@($turns | Where-Object tokenUsageStatus -eq 'missing').Count){'partial'}else{'available'}
        semantics='cachedInput is included in input; reasoning is included in output'
    }
    coverage=[pscustomobject][ordered]@{
        sourceRows=[pscustomobject][ordered]@{turns=$raw.A.Count;activity=$raw.B.Count;tools=$raw.C.Count;failures=$raw.D.Count;rounds=$raw.R.Count;sampling=$raw.S.Count}
        completionSignals=[pscustomobject][ordered]@{
            explicit=@($completedRows + $failedRows | Where-Object completionSignal -eq 'explicit').Count
            legacy=@($completedRows | Where-Object completionSignal -eq 'legacy').Count
            missing=@($unclassifiedRows | Where-Object completionSignal -eq 'missing').Count
        }
        hydration=@($hydration.GetEnumerator() | ForEach-Object { [pscustomobject][ordered]@{traceId=$_.Key;hydratedSpanCount=$_.Value.hydratedSpanCount;hydratedPayloadBytes=$_.Value.hydratedPayloadBytes} } | Sort-Object traceId)
        warnings=@($warnings)
    }
    models=@($models|Sort-Object totalTokens -Descending)
    tools=[pscustomobject][ordered]@{
        calls=$toolCalls.Count;dispatchFailures=$failedCalls.Count
        dispatchFailureRatePct=if($toolCalls.Count){[math]::Round(100*$failedCalls.Count/$toolCalls.Count,2)}else{$null}
        process=[pscustomobject][ordered]@{
            commandCalls=$commandCalls.Count;outcomesObserved=$commandOutcomes.Count;failures=$processFailures.Count
            coverage=$processCoverage
            failureRatePct=if($processCoverage -eq 'available' -and $commandCalls.Count){[math]::Round(100*$processFailures.Count/$commandCalls.Count,2)}else{$null}
        }
        combinedFailures=$combinedFailureCount
        toolFailureRatePct=if($null -eq $combinedFailureCount -or $toolCalls.Count -eq 0){$null}else{[math]::Round(100*$combinedFailureCount/$toolCalls.Count,2)}
        byName=@($toolsByName|Sort-Object maxDurationMs -Descending)
        failedCalls=@($failedCalls)
    }
    turnStates=@(@($completedRows + $failedRows + $unclassifiedRows) | ForEach-Object {
        [pscustomobject][ordered]@{traceId=Get-TraceId $_;status=$_.turnStatus;completionSignal=$_.completionSignal;tokenUsageStatus=if($_.tokenUsageAvailable){'available'}else{'missing'}}
    } | Sort-Object traceId)
    turns=$turns
}

if($Format -eq 'json'){ $report|ConvertTo-Json -Depth 12; exit 0 }
$lines=[System.Collections.Generic.List[string]]::new()
$lines.Add('# Codex performance report')
$lines.Add('')
$lines.Add("- Project: $(ConvertTo-Md $Project)")
$lines.Add("- Snapshot: $($report.snapshot.from) to $($report.snapshot.asOf)")
$lines.Add("- Contract: $contractVersion")
$lines.Add('')
$lines.Add('| Completed | Failed | Unclassified | Avg ms | Tokens | Cache hit | Tools | Dispatch failures | Process failures | Combined failure rate |')
$lines.Add('|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|')
$lines.Add("| $($report.summary.completedTurns) | $($report.summary.failedTurns) | $($report.summary.unclassifiedTurns) | $($report.summary.avgDurationMs) | $($report.summary.totalTokens) | $($report.summary.cacheHitPct)% | $($report.summary.toolCalls) | $($report.summary.toolDispatchFailures) | $($report.summary.processFailures) | $($report.summary.toolFailureRatePct)% |")
$lines.Add('')
$lines.Add('Cached input is included in input; reasoning is included in output.')
$lines.Add('')
$lines.Add('## Coverage warnings')
if($warnings.Count -eq 0){$lines.Add('No incompleteness observed within configured limits.')}
foreach($w in $warnings){$lines.Add("- $($w.code) ($($w.count)): $($w.message)")}
$lines.Add('')
$lines.Add('## Tools')
$lines.Add('| Tool | Calls | Dispatch failures | p50 ms | p95 ms | max ms | Trace ID |')
$lines.Add('|---|---:|---:|---:|---:|---:|---|')
foreach($t in $report.tools.byName){$lines.Add("| $(ConvertTo-Md $t.tool) | $($t.calls) | $($t.dispatchFailures) | $($t.p50DurationMs) | $($t.p95DurationMs) | $($t.maxDurationMs) | $($t.slowestTraceId) |")}
$lines.Add('')
$lines.Add('## Turn states')
$lines.Add('| Trace ID | Status | Completion signal | Token usage |')
$lines.Add('|---|---|---|---|')
foreach($t in $report.turnStates){$lines.Add("| $($t.traceId) | $($t.status) | $($t.completionSignal) | $($t.tokenUsageStatus) |")}
$lines.Add('')
$lines.Add('## Completed turns')
$lines.Add('| Time | Model | Duration | Rounds | Sampling cumulative | Tools cumulative | Observed union | Other | In | Cached | Non-cached | Out | Reasoning | Total | Calls | Dispatch failures | Trace ID |')
$lines.Add('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|')
foreach($t in $turns){$lines.Add("| $($t.timestamp) | $(ConvertTo-Md $t.model) | $($t.durationMs) | $($t.modelRounds) | $($t.modelSamplingCumulativeMs) | $($t.toolCumulativeDurationMs) | $($t.observedComponentWallClockMs) | $($t.otherMs) | $($t.inputTokens) | $($t.cachedInputTokens) | $($t.nonCachedInputTokens) | $($t.outputTokens) | $($t.reasoningTokens) | $($t.totalTokens) | $($t.toolCalls) | $($t.dispatchFailures) | $($t.traceId) |")}
$lines -join [Environment]::NewLine
