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
Assert-True ($cwd[0].type -eq 'query' -and $cwd[0].datasource.uid -eq 'tempo') 'Project cwd must be populated by Tempo.'
Assert-True ($cwd[0].query.type -eq 1 -and $cwd[0].query.label -eq 'cwd') 'Project cwd must query Tempo cwd label values.'
Assert-True ($cwd[0].refresh -eq 1 -and -not $cwd[0].multi -and -not $cwd[0].includeAll) 'Project cwd must auto-select one exact value and remain single-select.'
Assert-True ($cwd[0].current.isNone -and $cwd[0].current.value -eq '' -and $cwd[0].current.text -match 'Project not selected') 'Project cwd must persist the explicit safe empty state, not a machine-specific path.'
Assert-True ($dashboard.panels.Count -eq 19) 'Unexpected dashboard panel count.'
Assert-True ($raw -notmatch '>>') 'Strict descendant queries must not be used for trace joins.'
Assert-True ($raw -notmatch '"type": "loki"') 'Dashboard must not query Loki log bodies.'
Assert-True ($raw -notmatch '\{\{\.output\}\}|tool_arguments|user_prompt') 'Unbounded/private payload fields are present.'

$snapshot = @($dashboard.panels | Where-Object id -eq 16)[0]
Assert-True ($snapshot.options.content -match '\$\{cwd:text\}') 'Snapshot panel must render the project selection text.'
Assert-True ($cwd[0].current.text -match '⚠' -and $cwd[0].current.text -match 'Project not selected') 'Unselected-project warning is missing.'

$statPanels = @($dashboard.panels | Where-Object id -in @(1, 2, 3, 4, 5, 6, 17))
foreach ($panel in $statPanels) {
    Assert-True ($panel.fieldConfig.defaults.noValue -eq '—') "Stat panel $($panel.id) must stay unset when no project is selected."
}

$tempoQueries = @($dashboard.panels | ForEach-Object {
    if ($_.PSObject.Properties['targets']) {
        @($_.targets | Where-Object {
            $_.PSObject.Properties['query'] -and $_.datasource.uid -eq 'tempo'
        } | ForEach-Object query)
    }
})
foreach ($query in $tempoQueries) {
    Assert-True ($query -match 'span\.cwd = "\$\{cwd:regex\}"') 'Tempo target lost exact Project cwd equality.'
    Assert-True ($query -notmatch 'span\.cwd\s*=~') 'Project cwd must not use regex comparison.'
}

function Get-SyntheticProjectState([string[]]$TagNames, [string[]]$TagValues) {
    $hasCwdTag = $TagNames -ccontains 'cwd'
    $projects = [System.Collections.Generic.List[string]]::new()
    $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    if ($hasCwdTag) {
        foreach ($value in $TagValues) {
            if ($seen.Add($value)) { $projects.Add($value) }
        }
        $projects.Sort([System.StringComparer]::Ordinal)
    }
    [pscustomobject]@{
        Projects = @($projects)
        Selected = if ($projects.Count -gt 0) { $projects[0] } else { $null }
        Warning = $projects.Count -eq 0
    }
}

$emptyTempo = Get-SyntheticProjectState -TagNames @() -TagValues @()
Assert-True ($emptyTempo.Warning -and $emptyTempo.Projects.Count -eq 0 -and $null -eq $emptyTempo.Selected) 'Empty Tempo state must remain unselected.'

$singleProject = Get-SyntheticProjectState -TagNames @('cwd') -TagValues @('C:\work\alpha')
Assert-True (-not $singleProject.Warning -and $singleProject.Selected -ceq 'C:\work\alpha') 'Single-project Tempo state must auto-select the exact path.'

$multipleProjects = Get-SyntheticProjectState -TagNames @('cwd') -TagValues @('C:\work\alpha', 'D:\work\beta', 'c:\work\alpha', 'C:\work\alpha')
Assert-True (-not $multipleProjects.Warning -and $multipleProjects.Projects.Count -eq 3) 'Multi-project Tempo state must expose the unique project list.'
Assert-True ($multipleProjects.Projects -ccontains 'C:\work\alpha' -and $multipleProjects.Projects -ccontains 'c:\work\alpha') 'Windows project paths must remain case-sensitive and exact.'

'dashboard project states: empty, single, multiple PASS'

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

# Tempo exemplars add long annotation frames alongside the metric series.
# Grafana server-side math tries to read those frames as wide numeric series.
# Disable exemplars on every Tempo target in a panel using expressions.
foreach ($target in @($tokenPanel.targets | Where-Object { $_.datasource.uid -eq 'tempo' })) {
    Assert-True ($null -ne $target.PSObject.Properties['exemplars'] -and $target.exemplars -eq 0) "Token target $($target.refId) must disable exemplars before Grafana math reads its frames."
}

$latency = @($dashboard.panels | Where-Object id -eq 19)[0]
$latencyText = (@($latency.targets | ForEach-Object query) -join ' ')
Assert-True ($latencyText -match 'quantile_over_time\(span:duration, \.50\)' -and $latencyText -match 'quantile_over_time\(span:duration, \.95\)' -and $latencyText -match 'max_over_time\(span:duration\)') 'Tool latency quantiles drifted.'

$linkCount = ([regex]::Matches($raw, 'Open trace in Tempo')).Count
Assert-True ($linkCount -ge 3) 'Required Trace ID links are missing.'

'codex dashboard contract regression: PASS'
