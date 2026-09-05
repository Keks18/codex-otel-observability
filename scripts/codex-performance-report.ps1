[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Project,
    [ValidatePattern('^\d+(m|h|d|w)$')][string]$Period = '6h',
    [ValidateSet('json', 'markdown')][string]$Format = 'json',
    [ValidateRange(1, 1000)][int]$MaxTurns = 500,
    [string]$AsOf,
    [string]$GrafanaBaseUrl = 'http://127.0.0.1:3000',
    [string]$FixturePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$contractVersion = '2.0'
$activeGraceSeconds = 120

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
function ConvertTo-Md($Value) {
    if ($null -eq $Value) { return '' }
    ([string]$Value).Replace('|', '\|').Replace([char]13, ' ').Replace([char]10, ' ')
}

$warnings = [System.Collections.Generic.List[object]]::new()
function Add-Warning([string]$Code, [int]$Count, [string]$Message) {
    if ($Count -gt 0) { $warnings.Add([pscustomobject][ordered]@{ code = $Code; count = $Count; message = $Message }) }
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
$selectTools = 'select(event.tool_name, span.tool_name, span."codex.tool.name", span.call_id, span."codex.tool.call_id", span.nested, span.retry_count, span.recovered, event.success, span.failure_class, span.reason_summary, span."error.kind")'
$queries = @(
    @{ refId='A'; datasource=$tempo; queryType='traceqlSearch'; tableType='spans'; limit=$MaxTurns; spss=1; query='(' + $projectSet + ' && { name = "session_task.turn" }) | { name = "session_task.turn" } | select(span.model, span."codex.turn.reasoning_effort", span."codex.turn.token_usage.input_tokens", span."codex.turn.token_usage.output_tokens", span."codex.turn.token_usage.reasoning_output_tokens", span."codex.turn.token_usage.cached_input_tokens", span."codex.turn.token_usage.total_tokens")' },
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

$turnRows = @()
$duplicateTurns = 0
foreach ($group in @($raw.A | Where-Object { Get-TraceId $_ } | Group-Object { Get-TraceId $_ })) {
    $ordered = @($group.Group | Sort-Object { Get-TimeMs $_ } -Descending)
    $turnRows += $ordered[0]
    $duplicateTurns += [math]::Max($ordered.Count - 1, 0)
}
Add-Warning 'duplicate_turn_span' $duplicateTurns 'Newest duplicate turn span was selected.'

$completedRows = @()
$incompleteRows = @()
$knownTurn = @{}
foreach ($row in $turnRows) {
    $trace = Get-TraceId $row
    $knownTurn[$trace] = $true
    if ((Test-Value $row @('codex.turn.token_usage.total_tokens')) -or
        ((Test-Value $row @('codex.turn.token_usage.input_tokens')) -and (Test-Value $row @('codex.turn.token_usage.output_tokens')))) {
        $completedRows += $row
    } else { $incompleteRows += $row }
}

$latestActivity = @{}
foreach ($row in @($raw.B + $raw.C + $raw.D + $raw.R + $raw.S)) {
    $trace = Get-TraceId $row
    $time = Get-TimeMs $row
    if ($trace -and (-not $latestActivity.ContainsKey($trace) -or $time -gt $latestActivity[$trace])) { $latestActivity[$trace] = $time }
}
$activeIds = @()
$missingIds = @()
foreach ($trace in $latestActivity.Keys) {
    if ($knownTurn.ContainsKey($trace)) { continue }
    $age = ($toMs - [long]$latestActivity[$trace]) / 1000
    if ($age -ge 0 -and $age -le $activeGraceSeconds) { $activeIds += $trace } else { $missingIds += $trace }
}
Add-Warning 'active_turn' $activeIds.Count 'Recent scoped activity has no completed turn.'
Add-Warning 'incomplete_turn' $incompleteRows.Count 'Turn completion token attributes are missing.'
Add-Warning 'missing_turn_or_root' $missingIds.Count 'Scoped activity has no canonical turn.'
if ($raw.A.Count -ge $MaxTurns) { Add-Warning 'query_limit_reached' 1 'Turn query reached MaxTurns.' }

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

$turns = @()
$overlap = 0
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
    if ($samplingMs + $toolDurationMs -gt $duration) { $overlap++ }
    $time = Get-TimeMs $row
    $turns += [pscustomobject][ordered]@{
        timestamp=if($time){[DateTimeOffset]::FromUnixTimeMilliseconds($time).ToUniversalTime().ToString('o')}else{$null}
        model=[string](Get-Value $row @('model') 'unknown')
        reasoningEffort=[string](Get-Value $row @('codex.turn.reasoning_effort') 'unknown')
        durationMs=$duration
        modelRounds=if($rounds.ContainsKey($trace)){[int]$rounds[$trace]}else{0}
        modelSamplingMs=[math]::Round($samplingMs,3)
        toolDurationMs=[math]::Round($toolDurationMs,3)
        otherMs=[math]::Round([math]::Max($duration-$samplingMs-$toolDurationMs,0),3)
        inputTokens=$input
        cachedInputTokens=$cached
        nonCachedInputTokens=[math]::Max($input-$cached,0)
        outputTokens=$output
        reasoningTokens=$reasoning
        totalTokens=$total
        cacheHitPct=if($input){[math]::Round(100*$cached/$input,2)}else{0}
        toolCalls=@($toolCalls.Keys|Where-Object{$_.StartsWith($trace+':')}).Count
        failures=@($failures.Keys|Where-Object{$_.StartsWith($trace+':') -and $toolCalls.ContainsKey($_)}).Count
        traceId=$trace
    }
}
$turns = @($turns | Sort-Object timestamp -Descending | Select-Object -First $MaxTurns)
Add-Warning 'component_duration_overlap' $overlap 'Sampling plus tool duration exceeded turn duration; other was clamped.'

$failedCalls = @()
foreach ($key in @($failures.Keys | Where-Object { $toolCalls.ContainsKey($_) })) {
    $f=$failures[$key]; $t=$toolCalls[$key]
    $reason=[string](Get-Value $f @('reason_summary','failure_class','error.kind') 'No bounded reason was exported')
    if($reason.Length -gt 160){$reason=$reason.Substring(0,160)}
    $failedCalls += [pscustomobject][ordered]@{
        tool=[string](Get-Value $t @('event.tool_name','tool_name','span.tool_name','codex.tool.name','span.codex.tool.name') 'unknown')
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
foreach ($group in @($toolCalls.GetEnumerator() | Group-Object { [string](Get-Value $_.Value @('event.tool_name','tool_name','span.tool_name','codex.tool.name','span.codex.tool.name') 'unknown') })) {
    $durations=[double[]]@($group.Group|ForEach-Object{Get-DurationMs $_.Value})
    $failureCount=@($group.Group|Where-Object{$failures.ContainsKey($_.Key)}).Count
    $slowest=$group.Group|Sort-Object{Get-DurationMs $_.Value}-Descending|Select-Object -First 1
    $toolsByName += [pscustomobject][ordered]@{
        tool=$group.Name; calls=$group.Count; failures=$failureCount
        p50DurationMs=Get-Percentile $durations 0.5
        p95DurationMs=Get-Percentile $durations 0.95
        maxDurationMs=[math]::Round(($durations|Measure-Object -Maximum).Maximum,3)
        slowestTraceId=Get-TraceId $slowest.Value
    }
}

$models = @()
foreach ($group in @($turns|Group-Object model)) {
    $modelInput=[long](Get-Sum $group.Group inputTokens)
    $modelCached=[long](Get-Sum $group.Group cachedInputTokens)
    $models += [pscustomobject][ordered]@{
        model=$group.Name; turns=$group.Count
        avgDurationMs=[math]::Round(($group.Group|Measure-Object durationMs -Average).Average,3)
        modelRounds=[int](Get-Sum $group.Group modelRounds)
        inputTokens=$modelInput; cachedInputTokens=$modelCached; nonCachedInputTokens=$modelInput-$modelCached
        outputTokens=[long](Get-Sum $group.Group outputTokens)
        reasoningTokens=[long](Get-Sum $group.Group reasoningTokens)
        totalTokens=[long](Get-Sum $group.Group totalTokens)
        cacheHitPct=if($modelInput){[math]::Round(100*$modelCached/$modelInput,2)}else{0}
    }
}
$inputTotal=[long](Get-Sum $turns inputTokens)
$cachedTotal=[long](Get-Sum $turns cachedInputTokens)
$totalTotal=[long](Get-Sum $turns totalTokens)
$report=[pscustomobject][ordered]@{
    schemaVersion=$contractVersion; project=$Project; period=$Period
    snapshot=[pscustomobject][ordered]@{from=$fromValue.ToString('o');asOf=$asOfValue.ToString('o');activeGraceSeconds=$activeGraceSeconds}
    summary=[pscustomobject][ordered]@{
        completedTurns=$turns.Count;activeTurns=$activeIds.Count;incompleteTurns=$incompleteRows.Count+$missingIds.Count
        avgDurationMs=if($turns.Count){[math]::Round(($turns|Measure-Object durationMs -Average).Average,3)}else{0}
        totalTokens=$totalTotal;cacheHitPct=if($inputTotal){[math]::Round(100*$cachedTotal/$inputTotal,2)}else{0}
        toolCalls=$toolCalls.Count;toolFailures=$failedCalls.Count
    }
    tokens=[pscustomobject][ordered]@{
        input=$inputTotal;cachedInput=$cachedTotal;nonCachedInput=$inputTotal-$cachedTotal
        output=[long](Get-Sum $turns outputTokens);reasoning=[long](Get-Sum $turns reasoningTokens);total=$totalTotal
        semantics='cachedInput is included in input; reasoning is included in output'
    }
    coverage=[pscustomobject][ordered]@{
        sourceRows=[pscustomobject][ordered]@{turns=$raw.A.Count;activity=$raw.B.Count;tools=$raw.C.Count;failures=$raw.D.Count;rounds=$raw.R.Count;sampling=$raw.S.Count}
        warnings=@($warnings)
    }
    models=@($models|Sort-Object totalTokens -Descending)
    tools=[pscustomobject][ordered]@{
        calls=$toolCalls.Count;failures=$failedCalls.Count
        failureRatePct=if($toolCalls.Count){[math]::Round(100*$failedCalls.Count/$toolCalls.Count,2)}else{0}
        byName=@($toolsByName|Sort-Object maxDurationMs -Descending)
        failedCalls=@($failedCalls)
    }
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
$lines.Add('| Completed | Active | Incomplete | Avg ms | Tokens | Cache hit | Tools | Failures |')
$lines.Add('|---:|---:|---:|---:|---:|---:|---:|---:|')
$lines.Add("| $($report.summary.completedTurns) | $($report.summary.activeTurns) | $($report.summary.incompleteTurns) | $($report.summary.avgDurationMs) | $($report.summary.totalTokens) | $($report.summary.cacheHitPct)% | $($report.summary.toolCalls) | $($report.summary.toolFailures) |")
$lines.Add('')
$lines.Add('Cached input is included in input; reasoning is included in output.')
$lines.Add('')
$lines.Add('## Coverage warnings')
if($warnings.Count -eq 0){$lines.Add('No incompleteness observed within configured limits.')}
foreach($w in $warnings){$lines.Add("- $($w.code) ($($w.count)): $($w.message)")}
$lines.Add('')
$lines.Add('## Tools')
$lines.Add('| Tool | Calls | Failures | p50 ms | p95 ms | max ms | Trace ID |')
$lines.Add('|---|---:|---:|---:|---:|---:|---|')
foreach($t in $report.tools.byName){$lines.Add("| $(ConvertTo-Md $t.tool) | $($t.calls) | $($t.failures) | $($t.p50DurationMs) | $($t.p95DurationMs) | $($t.maxDurationMs) | $($t.slowestTraceId) |")}
$lines.Add('')
$lines.Add('## Turns')
$lines.Add('| Time | Model | Duration | Rounds | Sampling | Tools ms | Other | In | Cached | Non-cached | Out | Reasoning | Total | Calls | Failures | Trace ID |')
$lines.Add('|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|')
foreach($t in $turns){$lines.Add("| $($t.timestamp) | $(ConvertTo-Md $t.model) | $($t.durationMs) | $($t.modelRounds) | $($t.modelSamplingMs) | $($t.toolDurationMs) | $($t.otherMs) | $($t.inputTokens) | $($t.cachedInputTokens) | $($t.nonCachedInputTokens) | $($t.outputTokens) | $($t.reasoningTokens) | $($t.totalTokens) | $($t.toolCalls) | $($t.failures) | $($t.traceId) |")}
$lines -join [Environment]::NewLine
