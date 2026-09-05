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

Assert-Equal $json1.schemaVersion '2.0' 'schemaVersion'
Assert-Equal $json1.snapshot.asOf '2026-09-04T08:00:00.0000000+00:00' 'asOf'
Assert-Equal $json1.summary.completedTurns 1 'completed turns'
Assert-Equal $json1.summary.activeTurns 1 'active turns'
Assert-Equal $json1.summary.incompleteTurns 2 'incomplete turns'
Assert-Equal $json1.summary.totalTokens 120 'total tokens'
Assert-Equal $json1.tokens.input 100 'input tokens'
Assert-Equal $json1.tokens.cachedInput 40 'cached input'
Assert-Equal $json1.tokens.nonCachedInput 60 'non-cached input'
Assert-Equal $json1.tokens.output 20 'output tokens'
Assert-Equal $json1.tokens.reasoning 5 'reasoning tokens'
Assert-Equal $json1.summary.toolCalls 2 'top-level tool calls'
Assert-Equal $json1.summary.toolFailures 1 'deduplicated failures'
Assert-Equal $json1.turns[0].modelRounds 2 'model rounds'
Assert-Equal $json1.turns[0].modelSamplingMs 4000 'sampling duration'
Assert-Equal $json1.turns[0].toolDurationMs 5000 'tool duration'
Assert-Equal $json1.turns[0].otherMs 1000 'other duration'
Assert-Equal $json1.tools.byName[0].tool 'read' 'slowest tool'
Assert-Equal $json1.tools.byName[0].maxDurationMs 3000 'slowest duration'
Assert-Equal $json1.tools.failedCalls[0].failureClass 'tool_error' 'failure class'
Assert-Equal $json1.tools.failedCalls[0].nested $false 'nested exclusion'
Assert-Equal $json1.tools.failedCalls[0].retryCount 1 'retry count'
Assert-Equal $json1.tools.failedCalls[0].tool 'shell' 'event tool name on failed call'

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
    # Exercise query construction without writing fixtures or contacting Grafana.
    function Invoke-RestMethod($Uri, $Method, $ContentType, $Body) {
        $request = $Body | ConvertFrom-Json
        foreach ($query in @($request.queries | Where-Object refId -in @('C','D'))) {
            if ($query.query -notmatch 'select\(event\.tool_name,') { throw 'Tool query does not select event.tool_name first.' }
        }
        return $response
    }
    $actual = & $reportScript -Project 'fixture://project' -Period 1h -AsOf $asOf -Format json | ConvertFrom-Json
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
foreach ($code in @('oversized_or_partial','duplicate_turn_span','active_turn','incomplete_turn','missing_turn_or_root','duplicate_tool_call')) {
    if ($code -notin $warningCodes) { throw "Missing expected coverage warning '$code'." }
}
Assert-Equal ($json1 | ConvertTo-Json -Depth 12) ($json2 | ConvertTo-Json -Depth 12) 'stable snapshot'

$markdown = & $reportScript -Project 'fixture://project' -Period 1h -AsOf $asOf -FixturePath $fixture -Format markdown
if ($markdown -notmatch 'Completed.*Active.*Incomplete') { throw 'Markdown summary is missing completeness columns.' }
if ($markdown -notmatch 'Non-cached') { throw 'Markdown report is missing token semantics.' }
if ($markdown -match 'nested implementation failure') { throw 'Nested failure leaked into Markdown.' }

'codex-performance-report regression: PASS'
