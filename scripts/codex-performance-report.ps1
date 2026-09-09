[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [ValidatePattern('^\d+(m|h|d|w)$')][string]$Period = '6h',
    [ValidateSet('json', 'markdown')][string]$Format = 'json',
    [ValidateRange(1, 1000)][int]$MaxTurns = 500,
    [string]$AsOf,
    [string]$GrafanaBaseUrl = 'http://127.0.0.1:3000',
    [string]$FixturePath,
    [string]$TraceFixturePath,
    [ValidateRange(1, 8)][int]$HydrationConcurrency = 4
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$contractVersion = '5.0'
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
function Get-UnionDurationNs($Rows, [decimal]$ClipStart, [decimal]$ClipEnd) {
    $intervals = @($Rows | ForEach-Object {
        $interval = Get-Interval $_
        $start = if ($interval.Start -gt $ClipStart) { $interval.Start } else { $ClipStart }
        $end = if ($interval.End -lt $ClipEnd) { $interval.End } else { $ClipEnd }
        if ($end -gt $start) { [pscustomobject]@{ Start = $start; End = $end } }
    } | Sort-Object Start, End)
    if ($intervals.Count -eq 0) { return [decimal]0 }
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
    return $total
}
function Get-UnionDurationMs($Rows, [decimal]$ClipStart, [decimal]$ClipEnd) {
    return [math]::Round([double]((Get-UnionDurationNs $Rows $ClipStart $ClipEnd) / 1000000), 3)
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

function Get-AgentValue($Row, [string[]]$Names, $Default = $null) {
    return Get-Value $Row $Names $Default
}

function Get-BoundedAgentValue($Row, [string[]]$Names, [int]$MaxLength = 96) {
    $value = [string](Get-AgentValue $Row $Names '')
    if ($value -and $value.Length -le $MaxLength -and $value -match '^[A-Za-z0-9._:-]+$') { return $value }
    return $null
}

function Test-SupportedAgentLifecycle($Row) {
    return (Get-Value $Row @('name') '') -eq 'codex.agent.lifecycle' -and
        [string](Get-AgentValue $Row @('codex.agent.signal_version') '') -eq '1'
}

function Get-AgentIntervalKind($Row) {
    return [string](Get-AgentValue $Row @('codex.agent.interval_kind') '')
}

function Get-AgentCompositeKey($Row) {
    $traceId = Get-TraceId $Row
    $agentId = Get-BoundedAgentValue $Row @('codex.agent.instance_id')
    if (-not $traceId -or -not $agentId) { return $null }
    return $traceId + [char]31 + $agentId
}

function Get-AgentCompositeKeyFromValues([string]$TraceId, [string]$AgentId) {
    if (-not $TraceId -or -not $AgentId) { return $null }
    return $TraceId + [char]31 + $AgentId
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
    $traceFixtureContent = if ($TraceFixturePath) { Get-Content -Raw $TraceFixturePath } else { $null }
    $hydration = @{}
    $hydrationStopwatch = [Diagnostics.Stopwatch]::StartNew()
    $pending = [System.Collections.Generic.List[object]]::new()
    $hydratedContent = @{}
    $nextTrace = 0
    # Start-Job is available in Windows PowerShell 5.1 and gives us a bounded
    # retrieval pool without requiring PowerShell 7 parallel syntax. Parsing and
    # all semantic aggregation stay in this process, so output ordering remains
    # deterministic even when HTTP responses complete out of order.
    $hydrateJob = {
        param([string]$TraceId, [string]$FixtureContent, [string]$BaseUrl)
        function Throw-HydrationFailure([string]$Id, [int]$HttpStatus, [string]$FailureClass) {
            $safeClass = if ($FailureClass -in @('trace_too_large','not_found','timeout','transport_error')) { $FailureClass } else { 'unknown' }
            $safeReason = switch ($safeClass) {
                'trace_too_large' { 'trace_exceeds_configured_size' }
                'not_found' { 'trace_not_found' }
                'timeout' { 'request_timed_out' }
                'transport_error' { 'transport_request_failed' }
                default { 'hydration_request_failed' }
            }
            $statusText = if ($HttpStatus -gt 0) { [string]$HttpStatus } else { 'none' }
            throw "Hydration failed for trace ${Id}: http_status=$statusText failure_class=$safeClass reason=$safeReason"
        }
        $stopwatch = [Diagnostics.Stopwatch]::StartNew()
        if ($FixtureContent) {
            $fixtures = $FixtureContent | ConvertFrom-Json
            $property = $fixtures.PSObject.Properties[$TraceId]
            if ($null -eq $property) { throw "Trace fixture is missing returned trace ID '$TraceId'." }
            $failureProperty = $property.Value.PSObject.Properties['hydrationFailure']
            if ($null -ne $failureProperty -and $null -ne $failureProperty.Value) {
                $statusProperty = $failureProperty.Value.PSObject.Properties['status']
                $classProperty = $failureProperty.Value.PSObject.Properties['failureClass']
                $status = if ($null -ne $statusProperty -and [string]$statusProperty.Value -match '^\d{3}$') { [int]$statusProperty.Value } else { 0 }
                $failureClass = if ($null -ne $classProperty) { [string]$classProperty.Value } else { 'unknown' }
                Throw-HydrationFailure $TraceId $status $failureClass
            }
            $delayProperty = $property.Value.PSObject.Properties['hydrationDelayMs']
            $delay = if ($null -ne $delayProperty) { $delayProperty.Value } else { 0 }
            if ([int]$delay -gt 0) { Start-Sleep -Milliseconds ([int]$delay) }
            $content = $property.Value | ConvertTo-Json -Depth 100 -Compress
        } else {
            if ($TraceId -notmatch '^[0-9a-fA-F]{1,32}$') { throw 'Invalid trace ID returned by Tempo.' }
            try {
                $response = Invoke-WebRequest -UseBasicParsing -Uri "$($BaseUrl.TrimEnd('/'))/api/datasources/proxy/uid/tempo/api/traces/$TraceId" -Method Get -ErrorAction Stop
            } catch {
                $httpStatus = 0
                if ($null -ne $_.Exception.Response -and $null -ne $_.Exception.Response.StatusCode) { $httpStatus = [int]$_.Exception.Response.StatusCode }
                $failureClass = if ($httpStatus -eq 422) { 'trace_too_large' } elseif ($httpStatus -eq 404) { 'not_found' } elseif ($_.Exception -is [System.Net.WebException] -and $_.Exception.Status -eq [System.Net.WebExceptionStatus]::Timeout) { 'timeout' } else { 'transport_error' }
                Throw-HydrationFailure $TraceId $httpStatus $failureClass
            }
            $content = [string]$response.Content
            if ([string]::IsNullOrWhiteSpace($content)) { Throw-HydrationFailure $TraceId 0 'unknown' }
        }
        [pscustomobject]@{ traceId=$TraceId; content=$content; retrievalDurationMs=[math]::Round($stopwatch.Elapsed.TotalMilliseconds,3) }
    }
    try {
        while ($nextTrace -lt $traceIds.Count -or $pending.Count -gt 0) {
            while ($nextTrace -lt $traceIds.Count -and $pending.Count -lt $HydrationConcurrency) {
                $traceId = $traceIds[$nextTrace]
                $pending.Add((Start-Job -ScriptBlock $hydrateJob -ArgumentList $traceId,$traceFixtureContent,$GrafanaBaseUrl))
                $nextTrace++
            }
            $completedJobs = @($pending | Where-Object { $_.State -in @('Completed','Failed','Stopped') })
            if ($completedJobs.Count -eq 0) { Start-Sleep -Milliseconds 20; continue }
            foreach ($job in $completedJobs) {
                $null = $pending.Remove($job)
                if ($job.State -ne 'Completed') {
                    $details = @($job.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason.Message } | Where-Object { $_ }) -join '; '
                    Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
                    throw "Full trace hydration failed. $details"
                }
                try { $result = @(Receive-Job -Job $job -ErrorAction Stop) }
                finally { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
                if ($result.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$result[0].content)) { throw 'Full trace hydration returned an invalid response.' }
                $hydratedContent[[string]$result[0].traceId] = $result[0]
                Write-Progress -Activity 'Hydrating Tempo traces' -Status "$($hydratedContent.Count) of $($traceIds.Count) traces" -PercentComplete ([math]::Floor(100 * $hydratedContent.Count / [math]::Max($traceIds.Count, 1)))
            }
        }
    } finally {
        foreach ($job in @($pending)) { Stop-Job -Job $job -ErrorAction SilentlyContinue; Remove-Job -Job $job -Force -ErrorAction SilentlyContinue }
        Write-Progress -Activity 'Hydrating Tempo traces' -Completed
    }
    foreach ($traceId in $traceIds) {
        $traceResult = $hydratedContent[$traceId]
        if ($null -eq $traceResult) { throw 'Full trace hydration did not return every discovered trace.' }
        $traceContent = [string]$traceResult.content
        $traceResponse = $traceContent | ConvertFrom-Json
        $traceBatches = @(Get-TraceProperty $traceResponse 'batches' @()) + @(Get-TraceProperty $traceResponse 'resourceSpans' @())
        $traceSpans = @($traceBatches | ForEach-Object {
            $traceScopes = @(Get-TraceProperty $_ 'scopeSpans' @()) + @(Get-TraceProperty $_ 'instrumentationLibrarySpans' @())
            foreach ($traceScope in $traceScopes) { @(Get-TraceProperty $traceScope 'spans' @()) }
        })
        $hydration[$traceId] = [pscustomobject][ordered]@{
            hydratedSpanCount = $traceSpans.Count
            hydratedPayloadBytes = [Text.Encoding]::UTF8.GetByteCount($traceContent)
            hydrationDurationMs = [double]$traceResult.retrievalDurationMs
        }
        # A failed hydration must fail the report, never silently produce totals
        # from a mixture of complete and truncated search span sets.
        foreach ($row in @(ConvertFrom-TraceActivity $traceResponse $traceId $fromValue.ToUnixTimeMilliseconds() $toMs $Project)) { $activity.Add($row) }
    }
    foreach ($ref in @('A','B','C','R','S')) { $raw[$ref]=@($activity | Where-Object source -eq $ref) }
    $raw.D=@($raw.C | Where-Object { (Get-Value $_ @('event.success') '') -in @('false','False','0') })
    $hydrationTotalDurationMs = [math]::Round($hydrationStopwatch.Elapsed.TotalMilliseconds,3)
} else {
    $hydration = @{}
    $hydrationTotalDurationMs = 0
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

# Agent execution is an opt-in, trace-local contract. The parser reads only
# allowlisted attributes from complete traces; it never derives a parent, depth,
# status, or project identity from Codex thread/turn IDs, span parentage, timing,
# model names, or cwd similarity.
$agentWarningRows = [System.Collections.Generic.List[object]]::new()
function Add-AgentWarning([string]$Code, [int]$Count, [string]$Message) {
    if ($Count -le 0) { return }
    Add-Warning $Code $Count $Message
    $existing = @($agentWarningRows | Where-Object code -eq $Code)
    if ($existing.Count) { $existing[0].count = [int]$existing[0].count + $Count }
    else { $agentWarningRows.Add([pscustomobject][ordered]@{ code=$Code; count=$Count; message=$Message }) }
}
function Get-AgentDepth($Row) {
    $value = [string](Get-AgentValue $Row @('codex.agent.delegation_depth') '')
    if ($value -match '^\d+$') { return [int]$value }
    return $null
}

$agentLifecycleRows = @($raw.B | Where-Object { (Get-Value $_ @('name') '') -eq 'codex.agent.lifecycle' })
$agentVersions = @($agentLifecycleRows | ForEach-Object { [string](Get-AgentValue $_ @('codex.agent.signal_version') '') } | Where-Object { $_ } | Sort-Object -Unique)
$supportedAgentRows = @($agentLifecycleRows | Where-Object { Test-SupportedAgentLifecycle $_ })
$unsupportedAgentRows = @($agentLifecycleRows | Where-Object { -not (Test-SupportedAgentLifecycle $_) })
Add-AgentWarning 'agent_contract_unsupported' $unsupportedAgentRows.Count 'Agent lifecycle records have an unsupported or missing contract version.'
$invalidAgentFieldRows = @($supportedAgentRows | Where-Object {
    $agentRow = $_
    $rawFields = @('codex.agent.instance_id','codex.agent.parent_instance_id','codex.agent.delegation_id','codex.agent.role','codex.agent.task_kind','codex.agent.reasoning_effort')
    @($rawFields | Where-Object {
        [string](Get-AgentValue $agentRow @($_) '') -and -not (Get-BoundedAgentValue $agentRow @($_))
    }).Count -gt 0
})
Add-AgentWarning 'agent_field_invalid' $invalidAgentFieldRows.Count 'Agent contract field is not a bounded opaque or enum-like token and was not rendered.'
$missingAgentIdRows = @($supportedAgentRows | Where-Object { -not (Get-BoundedAgentValue $_ @('codex.agent.instance_id')) })
Add-AgentWarning 'agent_topology_partial' $missingAgentIdRows.Count 'Supported agent lifecycle activity has no opaque agent instance ID.'
$agentRows = @($supportedAgentRows | Where-Object { Get-AgentCompositeKey $_ })
$agents = @()
$agentTimingNsByKey = @{}
if ($agentRows.Count) {
    $agentGroups = @($agentRows | Group-Object { Get-AgentCompositeKey $_ })
    $agentKeySet = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    $agentGroupsByKey = @{}
    foreach ($group in $agentGroups) { $null = $agentKeySet.Add([string]$group.Name); $agentGroupsByKey[[string]$group.Name] = $group }
    $parentKeyByAgentKey = @{}
    $duplicateSpawnCount = 0
    $invalidParentCount = 0
    $badDepthCount = 0
    $missingTerminalCount = 0
    $invalidTimingCount = 0
    $cycleKeys = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($group in $agentGroups) {
        $rows = @($group.Group | Sort-Object { Get-TimeMs $_ }, spanID)
        $traceId = Get-TraceId $rows[0]
        $id = Get-BoundedAgentValue $rows[0] @('codex.agent.instance_id')
        $agentKey = [string]$group.Name
        $parents = @($rows | ForEach-Object { Get-BoundedAgentValue $_ @('codex.agent.parent_instance_id') } | Where-Object { $_ } | Sort-Object -Unique)
        $parent = if ($parents.Count -eq 1) { $parents[0] } else { $null }
        $parentKey = Get-AgentCompositeKeyFromValues $traceId $parent
        $parentKeyByAgentKey[$agentKey] = $parentKey
        if ($parents.Count -gt 1 -or ($parent -and ($parent -eq $id -or -not $agentKeySet.Contains($parentKey)))) { $invalidParentCount++ }
        $depths = @($rows | ForEach-Object { Get-AgentDepth $_ } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
        $depth = if ($depths.Count -eq 1) { [int]$depths[0] } else { $null }
        if ($depths.Count -gt 1 -or ($null -eq $depth)) { $badDepthCount++ }
        if ($parent -and $agentKeySet.Contains($parentKey) -and $null -ne $depth) {
            $parentRows = @($agentGroupsByKey[$parentKey].Group)
            $parentDepths = @($parentRows | ForEach-Object { Get-AgentDepth $_ } | Where-Object { $null -ne $_ } | Sort-Object -Unique)
            if ($parentDepths.Count -ne 1 -or $depth -ne ([int]$parentDepths[0] + 1)) { $badDepthCount++ }
        } elseif (-not $parent -and $null -ne $depth -and $depth -ne 0) { $badDepthCount++ }
        $spawnCount = @($rows | Where-Object { [string](Get-AgentValue $_ @('codex.agent.lifecycle') '') -eq 'spawn' }).Count
        if ($spawnCount -gt 1) { $duplicateSpawnCount += $spawnCount - 1 }
        $terminals = @($rows | Where-Object {
            [string](Get-AgentValue $_ @('codex.agent.lifecycle') '') -eq 'complete' -and
            [string](Get-AgentValue $_ @('codex.agent.status') '') -in @('completed','failed','interrupted')
        } | Sort-Object { Get-TimeMs $_ } -Descending)
        $status = if ($terminals.Count) { [string](Get-AgentValue $terminals[0] @('codex.agent.status') '') } else { 'unclassified' }
        if (-not $terminals.Count) { $missingTerminalCount++ }
        $timingSignalRows = @($rows | Where-Object { Get-AgentIntervalKind $_ })
        $intervalRows = @($timingSignalRows | Where-Object { (Get-AgentIntervalKind $_) -in @('active','wait') })
        $invalidIntervals = @($rows | Where-Object {
            $kind = Get-AgentIntervalKind $_
            $interval = Get-Interval $_
            ($kind -and $kind -notin @('active','wait')) -or (($kind -in @('active','wait')) -and $interval.End -le $interval.Start)
        })
        $validIntervalRows = @($intervalRows | Where-Object { $interval = Get-Interval $_; $interval.End -gt $interval.Start })
        $activeRows = @($validIntervalRows | Where-Object { (Get-AgentIntervalKind $_) -eq 'active' })
        $waitRows = @($validIntervalRows | Where-Object { (Get-AgentIntervalKind $_) -eq 'wait' })
        $spawnRows = @($rows | Where-Object { [string](Get-AgentValue $_ @('codex.agent.lifecycle') '') -eq 'spawn' })
        $lifecycleStart = if ($spawnRows.Count) { ((@($spawnRows | ForEach-Object { (Get-Interval $_).Start }) | Measure-Object -Minimum).Minimum) } else { $null }
        # A terminal is selected by the existing deterministic terminal policy;
        # do not widen the lifecycle by taking the latest terminal end.
        $lifecycleEnd = if ($terminals.Count) { (Get-Interval $terminals[0]).End } else { $null }
        $hasLifecycleBounds = $null -ne $lifecycleStart -and $null -ne $lifecycleEnd -and $lifecycleEnd -gt $lifecycleStart
        $hasTimingExport = $timingSignalRows.Count -gt 0
        $durationMs = if ($hasLifecycleBounds) { [math]::Round([double](($lifecycleEnd - $lifecycleStart) / 1000000),3) } else { $null }
        $outsideLifecycleCount = if ($hasLifecycleBounds) { @($validIntervalRows | Where-Object { $interval=Get-Interval $_; $interval.Start -lt $lifecycleStart -or $interval.End -gt $lifecycleEnd }).Count } else { 0 }
        if ($hasLifecycleBounds -and $hasTimingExport) {
            # Keep all topology decisions in native nanoseconds. Conversion to
            # milliseconds happens only after unions and comparisons are complete.
            $lifecycleNs = $lifecycleEnd - $lifecycleStart
            $activeNs = Get-UnionDurationNs $activeRows $lifecycleStart $lifecycleEnd
            $waitNs = Get-UnionDurationNs $waitRows $lifecycleStart $lifecycleEnd
            $combinedTimingNs = Get-UnionDurationNs @($activeRows + $waitRows) $lifecycleStart $lifecycleEnd
            $activeWaitOverlapNs = $activeNs + $waitNs - $combinedTimingNs
            if ($activeWaitOverlapNs -lt 0) { $activeWaitOverlapNs = [decimal]0 }
            $uncoveredNs = $lifecycleNs - $combinedTimingNs
            if ($uncoveredNs -lt 0) { $uncoveredNs = [decimal]0 }
            $activeMs = [math]::Round([double]($activeNs / 1000000), 3)
            $waitMs = [math]::Round([double]($waitNs / 1000000), 3)
            $combinedTimingMs = [math]::Round([double]($combinedTimingNs / 1000000), 3)
            $activeWaitOverlapMs = [math]::Round([double]($activeWaitOverlapNs / 1000000), 3)
            # A nanosecond-sized measured gap must stay positive in the
            # diagnostic instead of rounding to a misleading zero milliseconds.
            $uncoveredMs = [math]::Round([double]($uncoveredNs / 1000000), 6)
            $timingInconsistent = $invalidIntervals.Count -gt 0 -or $outsideLifecycleCount -gt 0 -or $activeWaitOverlapNs -gt 0 -or $uncoveredNs -gt 0
            $timingCoverage = if ($timingInconsistent) { 'partial' } else { 'available' }
            $agentTimingNsByKey[$agentKey] = [pscustomobject]@{ activeNs=$activeNs; waitNs=$waitNs }
            $waitSharePct = if ($timingCoverage -eq 'available' -and ($activeNs + $waitNs) -gt 0) {
                [math]::Round([double](100 * $waitNs / ($activeNs + $waitNs)), 2)
            } else { $null }
        } else {
            $activeMs = $null; $waitMs = $null; $combinedTimingMs = $null; $activeWaitOverlapMs = $null; $uncoveredMs = $null
            $timingInconsistent = $false
            $timingCoverage = 'unavailable'
            $waitSharePct = $null
        }
        if ($timingInconsistent) { $invalidTimingCount++ }
        $traceIds = @($rows | ForEach-Object { Get-TraceId $_ } | Sort-Object -Unique)
        $agentCalls = @($toolCalls.Values | Where-Object { (Get-TraceId $_) -eq $traceId -and (Get-BoundedAgentValue $_ @('codex.agent.instance_id')) -eq $id })
        $agentCallKeys = @($toolCalls.GetEnumerator() | Where-Object { (Get-TraceId $_.Value) -eq $traceId -and (Get-BoundedAgentValue $_.Value @('codex.agent.instance_id')) -eq $id } | ForEach-Object Key)
        $agentCommandKeys = @($agentCallKeys | Where-Object { Test-CommandTool $toolCalls[$_] })
        $agentObservedOutcomes = @($agentCommandKeys | Where-Object { $processOutcomesByKey.ContainsKey($_) })
        $agentProcessCoverage = if ($agentCommandKeys.Count -eq 0) { 'not_applicable' } elseif ($agentObservedOutcomes.Count -eq 0) { 'unavailable' } elseif ($agentObservedOutcomes.Count -lt $agentCommandKeys.Count) { 'partial' } else { 'available' }
        $agentFailureCount = @($agentCallKeys | Where-Object { $failures.ContainsKey($_) }).Count
        $agentRetryRows = @($agentCalls | Where-Object { Test-Value $_ @('retry_count') })
        $agentModelRows = @($raw.S | Where-Object { (Get-TraceId $_) -eq $traceId -and (Get-BoundedAgentValue $_ @('codex.agent.instance_id')) -eq $id })
        $roles = @($rows | ForEach-Object { Get-BoundedAgentValue $_ @('codex.agent.role','codex.agent.task_kind') } | Where-Object { $_ } | Sort-Object -Unique)
        $modelsForAgent = @($rows + $agentModelRows | ForEach-Object { [string](Get-AgentValue $_ @('model') '') } | Where-Object { $_ } | Sort-Object -Unique)
        $efforts = @($rows | ForEach-Object { Get-BoundedAgentValue $_ @('codex.agent.reasoning_effort','codex.turn.reasoning_effort') } | Where-Object { $_ } | Sort-Object -Unique)
        $delegations = @($rows | ForEach-Object { Get-BoundedAgentValue $_ @('codex.agent.delegation_id') } | Where-Object { $_ } | Sort-Object -Unique)
        $agents += [pscustomobject][ordered]@{
            agentId=$id;parentAgentId=$parent;delegationId=if($delegations.Count -eq 1){$delegations[0]}else{$null};depth=$depth
            roleOrTaskKind=if($roles.Count -eq 1){$roles[0]}else{$null};status=$status
            model=if($modelsForAgent.Count -eq 1){$modelsForAgent[0]}else{$null};reasoningEffort=if($efforts.Count -eq 1){$efforts[0]}else{$null}
            durationMs=$durationMs
            activeWallClockMs=$activeMs
            waitWallClockMs=$waitMs
            activeWaitOverlapMs=$activeWaitOverlapMs
            uncoveredWallClockMs=$uncoveredMs
            timingCoverage=$timingCoverage
            waitSharePct=$waitSharePct
            modelWallClockMs=if($hasLifecycleBounds){Get-UnionDurationMs $agentModelRows $lifecycleStart $lifecycleEnd}else{$null}
            toolCalls=$agentCalls.Count;dispatchFailures=$agentFailureCount;processOutcomeCoverage=$agentProcessCoverage
            retryCount=if($agentRetryRows.Count){[int](($agentRetryRows | ForEach-Object { [int](Get-AgentValue $_ @('retry_count') 0) } | Measure-Object -Maximum).Maximum)}else{$null}
            recovered=if(@($agentCalls | Where-Object { Test-Value $_ @('recovered') }).Count -eq 0){$null}elseif(@($agentCalls | Where-Object { Get-Bool (Get-AgentValue $_ @('recovered') $false) }).Count -gt 0){$true}else{$false}
            traceId=if($traceIds.Count -eq 1){$traceIds[0]}else{$null}
        }
    }
    foreach ($agent in $agents) {
        $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        $cursor = Get-AgentCompositeKeyFromValues $agent.traceId $agent.agentId
        while ($cursor) {
            if (-not $seen.Add($cursor)) { $null = $cycleKeys.Add((@($seen) | Sort-Object) -join '|'); break }
            $next = $parentKeyByAgentKey[$cursor]
            if (-not $next -or -not $agentKeySet.Contains($next)) { break }
            $cursor = $next
        }
    }
    Add-AgentWarning 'agent_duplicate_id' $duplicateSpawnCount 'An opaque agent ID has multiple spawn lifecycle records.'
    Add-AgentWarning 'agent_invalid_parent' $invalidParentCount 'Agent parent is missing, self-referential, inconsistent, or orphaned; no relationship was repaired.'
    Add-AgentWarning 'agent_parent_cycle' $cycleKeys.Count 'Agent parent graph contains a cycle; no tree was rendered.'
    Add-AgentWarning 'agent_depth_inconsistent' $badDepthCount 'Agent delegation depth is missing or inconsistent with the exported parent.'
    Add-AgentWarning 'agent_terminal_outcome_missing' $missingTerminalCount 'Agent has no supported complete lifecycle terminal outcome.'
    Add-AgentWarning 'agent_timing_inconsistent' $invalidTimingCount 'Canonical agent timing has a gap, contradiction, invalid interval, or interval outside authoritative lifecycle bounds.'
    $topologyTraces = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    foreach ($row in $agentRows) { $null = $topologyTraces.Add((Get-TraceId $row)) }
    $unattributed = @($raw.C + $raw.R + $raw.S | Where-Object {
        $topologyTraces.Contains((Get-TraceId $_)) -and -not (Get-BoundedAgentValue $_ @('codex.agent.instance_id'))
    })
    Add-AgentWarning 'agent_activity_unattributed' $unattributed.Count 'Tool, model, or round activity on an agent-contract trace has no opaque agent ID.'
}
if ($agentLifecycleRows.Count -eq 0) {
    Add-AgentWarning 'agent_topology_unavailable' 1 'No supported agent lifecycle evidence was exported; agent topology is unavailable.'
}
$agentCoverage = if ($agentRows.Count -eq 0) {
    if ($agentLifecycleRows.Count -eq 0) { 'unavailable' } else { 'partial' }
} elseif ($agentWarningRows.Count -gt 0) { 'partial' } else { 'available' }
$agentDelegationCount = @($agents | ForEach-Object { if($_.delegationId){ Get-AgentCompositeKeyFromValues $_.traceId $_.delegationId } } | Where-Object { $_ } | Sort-Object -Unique).Count
$timingAgents = @($agents | Where-Object { $_.timingCoverage -ne 'unavailable' })
$agentTimingCoverage = if ($timingAgents.Count -eq 0) { 'unavailable' } elseif ($timingAgents.Count -ne $agents.Count -or @($agents | Where-Object timingCoverage -eq 'partial').Count) { 'partial' } else { 'available' }
$agentActiveTotalNs = [decimal]0
$agentWaitTotalNs = [decimal]0
if ($agentTimingCoverage -eq 'available') {
    foreach ($agent in $agents) {
        $timingNs = $agentTimingNsByKey[(Get-AgentCompositeKeyFromValues $agent.traceId $agent.agentId)]
        $agentActiveTotalNs += [decimal]$timingNs.activeNs
        $agentWaitTotalNs += [decimal]$timingNs.waitNs
    }
}
$agentActiveTotal = if($agentTimingCoverage -eq 'available'){[math]::Round([double]($agentActiveTotalNs / 1000000),3)}else{$null}
$agentWaitTotal = if($agentTimingCoverage -eq 'available'){[math]::Round([double]($agentWaitTotalNs / 1000000),3)}else{$null}
$agentWaitSharePct = if($agentTimingCoverage -eq 'available' -and ($agentActiveTotalNs + $agentWaitTotalNs) -gt 0){[math]::Round([double](100 * $agentWaitTotalNs / ($agentActiveTotalNs + $agentWaitTotalNs)),2)}else{$null}
$agentModelTotal = Get-ObservedSum $agents modelWallClockMs

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
$spanAmplificationSpanThreshold = 10000
$spanAmplificationPayloadBytesThreshold = 15000000
$largeHydratedTraces = @($hydration.GetEnumerator() | Where-Object {
    $_.Value.hydratedSpanCount -ge $spanAmplificationSpanThreshold -or
    $_.Value.hydratedPayloadBytes -ge $spanAmplificationPayloadBytesThreshold
})
Add-Warning 'span_amplification' $largeHydratedTraces.Count "Hydrated trace exceeds diagnostic threshold ($spanAmplificationSpanThreshold spans or $spanAmplificationPayloadBytesThreshold HTTP JSON bytes); JSON bytes are not Tempo storage bytes."

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
        hydration=[pscustomobject][ordered]@{
            concurrency=$HydrationConcurrency
            totalDurationMs=$hydrationTotalDurationMs
            traces=@($hydration.GetEnumerator() | ForEach-Object { [pscustomobject][ordered]@{traceId=$_.Key;hydratedSpanCount=$_.Value.hydratedSpanCount;hydratedPayloadBytes=$_.Value.hydratedPayloadBytes;hydrationDurationMs=$_.Value.hydrationDurationMs} } | Sort-Object traceId)
        }
        warnings=@($warnings)
    }
    agentExecution=[pscustomobject][ordered]@{
        coverage=$agentCoverage
        observedContractVersions=$agentVersions
        agentCount=$agents.Count
        delegationCount=$agentDelegationCount
        rootCount=@($agents | Where-Object { -not $_.parentAgentId }).Count
        maximumDepth=if(@($agents | Where-Object { $null -ne $_.depth }).Count){($agents | Where-Object { $null -ne $_.depth } | Measure-Object depth -Maximum).Maximum}else{$null}
        completed=@($agents | Where-Object status -eq 'completed').Count
        failedOrInterrupted=@($agents | Where-Object { $_.status -in @('failed','interrupted') }).Count
        unclassified=@($agents | Where-Object status -eq 'unclassified').Count
        activeWallClockMs=$agentActiveTotal
        waitWallClockMs=$agentWaitTotal
        modelWallClockMs=$agentModelTotal
        timingCoverage=$agentTimingCoverage
        waitSharePct=$agentWaitSharePct
        agents=@($agents | Sort-Object traceId, depth, agentId)
        warnings=@($agentWarningRows)
        semantics='Optional agent contract only; topology, identity, terminal status, and project identity are never inferred.'
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
$lines.Add('## Agent execution')
$lines.Add("- Coverage: $($report.agentExecution.coverage)")
$lines.Add("- Contract versions: $($report.agentExecution.observedContractVersions -join ', ')")
$lines.Add("- Agents: $($report.agentExecution.agentCount); delegations: $($report.agentExecution.delegationCount); roots: $($report.agentExecution.rootCount); maximum depth: $($report.agentExecution.maximumDepth)")
$lines.Add("- Completed: $($report.agentExecution.completed); failed/interrupted: $($report.agentExecution.failedOrInterrupted); unclassified: $($report.agentExecution.unclassified); wait share: $($report.agentExecution.waitSharePct)%")
$lines.Add('Topology is reported only from the optional versioned contract; no tree is inferred or rendered when coverage is partial or cyclic.')
$lines.Add('')
$lines.Add('| Agent ID | Parent | Depth | Role / task kind | Status | Model | Reasoning | Duration ms | Active ms | Wait ms | Uncovered ms | Timing coverage | Wait share % | Calls | Dispatch failures | Process outcome coverage | Retries | Recovered | Trace ID |')
$lines.Add('|---|---|---:|---|---|---|---|---:|---:|---:|---:|---|---:|---:|---:|---|---:|---|---|')
foreach($agent in $report.agentExecution.agents){$lines.Add("| $(ConvertTo-Md $agent.agentId) | $(ConvertTo-Md $agent.parentAgentId) | $($agent.depth) | $(ConvertTo-Md $agent.roleOrTaskKind) | $($agent.status) | $(ConvertTo-Md $agent.model) | $(ConvertTo-Md $agent.reasoningEffort) | $($agent.durationMs) | $($agent.activeWallClockMs) | $($agent.waitWallClockMs) | $($agent.uncoveredWallClockMs) | $($agent.timingCoverage) | $($agent.waitSharePct) | $($agent.toolCalls) | $($agent.dispatchFailures) | $($agent.processOutcomeCoverage) | $($agent.retryCount) | $($agent.recovered) | $($agent.traceId) |")}
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
