[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Project,

    [ValidatePattern('^\d+(m|h|d|w)$')]
    [string]$Period = '6h',

    [ValidateSet('json', 'markdown')]
    [string]$Format = 'json',

    [ValidateRange(1, 1000)]
    [int]$MaxTurns = 200,

    [string]$GrafanaBaseUrl = 'http://127.0.0.1:3000'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-TraceQlString {
    param([Parameter(Mandatory = $true)][string]$Value)

    return '"' + $Value.Replace('\', '\\').Replace('"', '\"') + '"'
}

function ConvertFrom-GrafanaFrame {
    param($Frame)

    if ($null -eq $Frame -or $null -eq $Frame.data -or $null -eq $Frame.data.values) {
        return @()
    }

    $fieldNames = @($Frame.schema.fields | ForEach-Object { $_.name })
    $columns = @($Frame.data.values)
    if ($fieldNames.Count -eq 0 -or $columns.Count -eq 0) {
        return @()
    }

    $rowCount = @($columns[0]).Count
    $rows = @()
    for ($rowIndex = 0; $rowIndex -lt $rowCount; $rowIndex++) {
        $row = [ordered]@{}
        for ($fieldIndex = 0; $fieldIndex -lt $fieldNames.Count; $fieldIndex++) {
            $column = @($columns[$fieldIndex])
            $row[$fieldNames[$fieldIndex]] = if ($rowIndex -lt $column.Count) { $column[$rowIndex] } else { $null }
        }
        $rows += [pscustomobject]$row
    }

    return $rows
}

function Get-ResultRows {
    param(
        [Parameter(Mandatory = $true)]$Response,
        [Parameter(Mandatory = $true)][string]$RefId
    )

    $result = $Response.results.PSObject.Properties[$RefId].Value
    if ($null -eq $result) {
        throw "Grafana response is missing query result '$RefId'."
    }
    if ($result.status -ne 200) {
        throw "Grafana query '$RefId' failed: $($result.error)"
    }

    $rows = @()
    foreach ($frame in @($result.frames)) {
        $rows += @(ConvertFrom-GrafanaFrame -Frame $frame)
    }
    return $rows
}

function Get-RowValue {
    param(
        [Parameter(Mandatory = $true)]$Row,
        [Parameter(Mandatory = $true)][string]$Name,
        $Default = $null
    )

    $property = $Row.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $Default
    }
    return $property.Value
}

function ConvertTo-MarkdownCell {
    param($Value)

    if ($null -eq $Value) {
        return ''
    }
    return ([string]$Value).Replace('|', '\|').Replace("`r", ' ').Replace("`n", ' ')
}

function Get-NumberOrZero {
    param($Value)

    if ($null -eq $Value) {
        return 0
    }
    return $Value
}

$tempoDatasource = @{ type = 'tempo'; uid = 'tempo' }
$projectLiteral = ConvertTo-TraceQlString -Value $Project
$turnBase = "({ span.cwd = $projectLiteral } && { name = `"session_task.turn`" }) | { name = `"session_task.turn`" }"
$cwdBase = "({ name = `"session_task.turn`" } && { span.cwd = $projectLiteral }) | { span.cwd != nil }"
$toolBase = "({ span.cwd = $projectLiteral } && { name = `"dispatch_tool_call_with_terminal_outcome`" }) | { name = `"dispatch_tool_call_with_terminal_outcome`" }"
$failureBase = "({ span.cwd = $projectLiteral } && { event.success = `"false`" }) | { event.success = `"false`" }"
$samplingBase = "{ name = `"run_sampling_request`" && span.cwd = $projectLiteral }"

$queries = @(
    @{
        refId = 'A'; datasource = $tempoDatasource; queryType = 'traceqlSearch'; tableType = 'spans'
        limit = $MaxTurns; spss = 1
        query = "$turnBase | select(span.model, span.`"codex.turn.reasoning_effort`", span.`"codex.turn.token_usage.input_tokens`", span.`"codex.turn.token_usage.output_tokens`", span.`"codex.turn.token_usage.reasoning_output_tokens`", span.`"codex.turn.token_usage.cached_input_tokens`", span.`"codex.turn.token_usage.total_tokens`")"
    },
    @{
        refId = 'B'; datasource = $tempoDatasource; queryType = 'traceqlSearch'; tableType = 'spans'
        limit = $MaxTurns; spss = 1; query = "$cwdBase | select(span.cwd)"
    },
    @{
        refId = 'C'; datasource = $tempoDatasource; queryType = 'traceqlSearch'; tableType = 'spans'
        limit = $MaxTurns; spss = 100; query = $toolBase
    },
    @{
        refId = 'D'; datasource = $tempoDatasource; queryType = 'traceqlSearch'; tableType = 'spans'
        limit = $MaxTurns; spss = 100; query = $failureBase
    },
    @{
        refId = 'S'; datasource = $tempoDatasource; queryType = 'traceqlSearch'; tableType = 'spans'
        limit = $MaxTurns; spss = 100; query = "$samplingBase | select(span.cwd, span.model)"
    }
)

$requestBody = @{
    queries = $queries
    from = "now-$Period"
    to = 'now'
} | ConvertTo-Json -Depth 15

try {
    $response = Invoke-RestMethod -Uri "$($GrafanaBaseUrl.TrimEnd('/'))/api/ds/query" -Method Post -ContentType 'application/json' -Body $requestBody
}
catch {
    throw "Unable to query Grafana at '$GrafanaBaseUrl'. Ensure the existing local observability stack is running. $($_.Exception.Message)"
}

$rawTurns = @(Get-ResultRows -Response $response -RefId 'A')
$rawCwds = @(Get-ResultRows -Response $response -RefId 'B')
$rawTools = @(Get-ResultRows -Response $response -RefId 'C')
$rawFailures = @(Get-ResultRows -Response $response -RefId 'D')
$rawSampling = @(Get-ResultRows -Response $response -RefId 'S')

$cwdByTrace = @{}
foreach ($row in $rawCwds) {
    $traceId = [string](Get-RowValue -Row $row -Name 'traceIdHidden' -Default '')
    $cwd = [string](Get-RowValue -Row $row -Name 'cwd' -Default $Project)
    if ($traceId -and -not $cwdByTrace.ContainsKey($traceId)) {
        $cwdByTrace[$traceId] = $cwd
    }
}

$toolCallsByTrace = @{}
foreach ($row in $rawTools) {
    $traceId = [string](Get-RowValue -Row $row -Name 'traceIdHidden' -Default '')
    if ($traceId) {
        $previousCount = if ($toolCallsByTrace.ContainsKey($traceId)) { [int]$toolCallsByTrace[$traceId] } else { 0 }
        $toolCallsByTrace[$traceId] = 1 + $previousCount
    }
}

$failuresByTrace = @{}
foreach ($row in $rawFailures) {
    $traceId = [string](Get-RowValue -Row $row -Name 'traceIdHidden' -Default '')
    if ($traceId) {
        $previousCount = if ($failuresByTrace.ContainsKey($traceId)) { [int]$failuresByTrace[$traceId] } else { 0 }
        $failuresByTrace[$traceId] = 1 + $previousCount
    }
}

$turns = @()
foreach ($row in $rawTurns) {
    $traceId = [string](Get-RowValue -Row $row -Name 'traceIdHidden' -Default '')
    $inputTokens = [long](Get-RowValue -Row $row -Name 'codex.turn.token_usage.input_tokens' -Default 0)
    $outputTokens = [long](Get-RowValue -Row $row -Name 'codex.turn.token_usage.output_tokens' -Default 0)
    $totalTokens = [long](Get-RowValue -Row $row -Name 'codex.turn.token_usage.total_tokens' -Default ($inputTokens + $outputTokens))
    $timeMs = [long](Get-RowValue -Row $row -Name 'time' -Default 0)
    $turns += [pscustomobject][ordered]@{
        timestamp = if ($timeMs -gt 0) { [DateTimeOffset]::FromUnixTimeMilliseconds($timeMs).ToString('o') } else { $null }
        cwd = if ($cwdByTrace.ContainsKey($traceId)) { $cwdByTrace[$traceId] } else { $Project }
        model = [string](Get-RowValue -Row $row -Name 'model' -Default 'unknown')
        reasoningEffort = [string](Get-RowValue -Row $row -Name 'codex.turn.reasoning_effort' -Default 'unknown')
        durationMs = [math]::Round(([double](Get-RowValue -Row $row -Name 'duration' -Default 0)) / 1000000, 2)
        inputTokens = $inputTokens
        outputTokens = $outputTokens
        reasoningTokens = [long](Get-RowValue -Row $row -Name 'codex.turn.token_usage.reasoning_output_tokens' -Default 0)
        cachedTokens = [long](Get-RowValue -Row $row -Name 'codex.turn.token_usage.cached_input_tokens' -Default 0)
        totalTokens = $totalTokens
        toolCalls = if ($toolCallsByTrace.ContainsKey($traceId)) { [int]$toolCallsByTrace[$traceId] } else { 0 }
        failures = if ($failuresByTrace.ContainsKey($traceId)) { [int]$failuresByTrace[$traceId] } else { 0 }
        traceId = $traceId
    }
}
$turns = @($turns | Sort-Object timestamp -Descending | Select-Object -First $MaxTurns)

$samplingByModel = @{}
foreach ($row in $rawSampling) {
    $model = [string](Get-RowValue -Row $row -Name 'model' -Default 'unknown')
    if (-not $samplingByModel.ContainsKey($model)) {
        $samplingByModel[$model] = [System.Collections.Generic.List[double]]::new()
    }
    $samplingByModel[$model].Add(([double](Get-RowValue -Row $row -Name 'duration' -Default 0)) / 1000000)
}

$models = @()
foreach ($group in @($turns | Group-Object model)) {
    $samplingValues = @(if ($samplingByModel.ContainsKey($group.Name)) { $samplingByModel[$group.Name] })
    $models += [pscustomobject][ordered]@{
        model = $group.Name
        turns = $group.Count
        avgDurationMs = [math]::Round((Get-NumberOrZero (($group.Group | Measure-Object durationMs -Average).Average)), 2)
        totalTokens = [long](Get-NumberOrZero (($group.Group | Measure-Object totalTokens -Sum).Sum))
        avgSamplingMs = if ($samplingValues.Count -gt 0) { [math]::Round((($samplingValues | Measure-Object -Average).Average), 2) } else { 0 }
    }
}
$models = @($models | Sort-Object totalTokens -Descending)

$turnCount = $turns.Count
$inputTotal = if ($turnCount -gt 0) { [long](($turns | Measure-Object inputTokens -Sum).Sum) } else { 0 }
$cachedTotal = if ($turnCount -gt 0) { [long](($turns | Measure-Object cachedTokens -Sum).Sum) } else { 0 }
$toolDurationValues = @($rawTools | ForEach-Object { ([double](Get-RowValue -Row $_ -Name 'duration' -Default 0)) / 1000000 })
$summary = [pscustomobject][ordered]@{
    turns = $turnCount
    avgDurationMs = if ($turnCount -gt 0) { [math]::Round((($turns | Measure-Object durationMs -Average).Average), 2) } else { 0 }
    totalTokens = if ($turnCount -gt 0) { [long](($turns | Measure-Object totalTokens -Sum).Sum) } else { 0 }
    cacheHitPct = if ($inputTotal -gt 0) { [math]::Round(($cachedTotal / $inputTotal) * 100, 2) } else { 0 }
    toolCalls = $rawTools.Count
    toolFailures = $rawFailures.Count
}

$report = [pscustomobject][ordered]@{
    project = $Project
    period = $Period
    generatedAt = [DateTimeOffset]::Now.ToString('o')
    summary = $summary
    models = $models
    tools = [pscustomobject][ordered]@{
        calls = $rawTools.Count
        failures = $rawFailures.Count
        failureRatePct = if ($rawTools.Count -gt 0) { [math]::Round(($rawFailures.Count / $rawTools.Count) * 100, 2) } else { 0 }
        avgDurationMs = if ($toolDurationValues.Count -gt 0) { [math]::Round((($toolDurationValues | Measure-Object -Average).Average), 2) } else { 0 }
    }
    turns = $turns
}

if ($Format -eq 'json') {
    $report | ConvertTo-Json -Depth 8
    exit 0
}

$lines = [System.Collections.Generic.List[string]]::new()
$lines.Add('# Codex performance report')
$lines.Add('')
$lines.Add('- Project: `' + (ConvertTo-MarkdownCell $Project) + '`')
$lines.Add('- Period: `' + $Period + '`')
$lines.Add("- Generated: $($report.generatedAt)")
$lines.Add('')
$lines.Add('| Metric | Value |')
$lines.Add('|---|---:|')
$lines.Add("| Turns | $($summary.turns) |")
$lines.Add("| Avg duration | $($summary.avgDurationMs) ms |")
$lines.Add("| Total tokens | $($summary.totalTokens) |")
$lines.Add("| Cache hit | $($summary.cacheHitPct)% |")
$lines.Add("| Tool calls | $($summary.toolCalls) |")
$lines.Add("| Tool failures | $($summary.toolFailures) |")
$lines.Add('')
$lines.Add('## Models')
$lines.Add('')
$lines.Add('| Model | Turns | Avg duration, ms | Tokens | Avg sampling, ms |')
$lines.Add('|---|---:|---:|---:|---:|')
foreach ($model in $models) {
    $lines.Add("| $(ConvertTo-MarkdownCell $model.model) | $($model.turns) | $($model.avgDurationMs) | $($model.totalTokens) | $($model.avgSamplingMs) |")
}
$lines.Add('')
$lines.Add('## Turns')
$lines.Add('')
$lines.Add('| Timestamp | Model | Effort | Duration, ms | In | Out | Reasoning | Cached | Tools | Failures | Trace ID |')
$lines.Add('|---|---|---|---:|---:|---:|---:|---:|---:|---:|---|')
foreach ($turn in $turns) {
    $lines.Add("| $(ConvertTo-MarkdownCell $turn.timestamp) | $(ConvertTo-MarkdownCell $turn.model) | $(ConvertTo-MarkdownCell $turn.reasoningEffort) | $($turn.durationMs) | $($turn.inputTokens) | $($turn.outputTokens) | $($turn.reasoningTokens) | $($turn.cachedTokens) | $($turn.toolCalls) | $($turn.failures) | $(ConvertTo-MarkdownCell $turn.traceId) |")
}

$lines -join [Environment]::NewLine
