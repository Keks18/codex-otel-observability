[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$dashboardPath = Join-Path $repoRoot 'grafana\dashboards\codex-overview.json'
$dashboard = Get-Content -LiteralPath $dashboardPath -Raw | ConvertFrom-Json
$raw = Get-Content -LiteralPath $dashboardPath -Raw

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

Assert-True ($dashboard.refresh -eq '10s') 'Dashboard refresh must remain 10s.'
$cwd = @($dashboard.templating.list | Where-Object name -eq 'cwd')
Assert-True ($cwd.Count -eq 1 -and $cwd[0].label -eq 'Project cwd') 'Project cwd filter is missing.'
Assert-True ($cwd[0].type -eq 'textbox') 'Project cwd must work before Tempo has discovered tags.'
Assert-True ($dashboard.panels.Count -eq 19) 'Unexpected dashboard panel count.'
Assert-True ($raw -notmatch '>>') 'Strict descendant queries must not be used for trace joins.'
Assert-True ($raw -notmatch '"type": "loki"') 'Dashboard must not query Loki log bodies.'
Assert-True ($raw -notmatch '\{\{\.output\}\}|tool_arguments|user_prompt') 'Unbounded/private payload fields are present.'

$completed = @($dashboard.panels | Where-Object id -eq 1)[0].targets[0].query
Assert-True ($completed -match 'session_task\.turn' -and $completed -match 'total_tokens' -and $completed -match 'cwd') 'Completed-turn KPI contract drifted.'

$failurePanels = @($dashboard.panels | Where-Object id -in @(6, 12, 14))
foreach ($panel in $failurePanels) {
    $queryText = (@($panel.targets | Where-Object query | ForEach-Object query) -join ' ')
    Assert-True ($queryText -match 'dispatch_tool_call_with_terminal_outcome' -and $queryText -match 'event\.success = "false"' -and $queryText -match 'cwd') "Failure panel $($panel.id) contract drifted."
}

$breakdown = @($dashboard.panels | Where-Object id -eq 13)[0]
$breakdownText = (@($breakdown.targets | ForEach-Object {
    $query = if ($_.PSObject.Properties['query']) { $_.query } else { '' }
    $expression = if ($_.PSObject.Properties['expression']) { $_.expression } else { '' }
    "$query $expression"
}) -join ' ')
Assert-True ($breakdownText -match 'run_sampling_request' -and $breakdownText -match 'dispatch_tool_call_with_terminal_outcome' -and $breakdownText -match 'traceIdHidden') 'Trace-ID time breakdown drifted.'

$tokenPanel = @($dashboard.panels | Where-Object id -eq 9)[0]
$tokenText = (@($tokenPanel.targets | ForEach-Object {
    $query = if ($_.PSObject.Properties['query']) { $_.query } else { '' }
    $expression = if ($_.PSObject.Properties['expression']) { $_.expression } else { '' }
    "$query $expression"
}) -join ' ')
foreach ($field in @('input_tokens','cached_input_tokens','output_tokens','reasoning_output_tokens','total_tokens')) {
    Assert-True ($tokenText -match $field) "Token panel is missing $field."
}
Assert-True ($tokenText -match '\$A - \$B') 'Non-cached input derivation is missing.'

$latency = @($dashboard.panels | Where-Object id -eq 19)[0]
$latencyText = (@($latency.targets | ForEach-Object query) -join ' ')
Assert-True ($latencyText -match 'quantile_over_time\(span:duration, \.50\)' -and $latencyText -match 'quantile_over_time\(span:duration, \.95\)' -and $latencyText -match 'max_over_time\(span:duration\)') 'Tool latency quantiles drifted.'

$linkCount = ([regex]::Matches($raw, 'Open trace in Tempo')).Count
Assert-True ($linkCount -ge 3) 'Required Trace ID links are missing.'

'codex dashboard contract regression: PASS'
