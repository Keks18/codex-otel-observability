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
Assert-True ($cwd[0].type -eq 'query' -and $cwd[0].datasource.uid -eq 'codex-projects') 'Project cwd must use the bounded historical Tempo metadata source.'
Assert-True ($cwd[0].query.type -eq 1 -and $cwd[0].query.label -eq 'cwd') 'Project cwd must query Tempo cwd label values.'
Assert-True ($cwd[0].refresh -eq 2 -and -not $cwd[0].multi -and -not $cwd[0].includeAll) 'Project cwd must refresh on time-range changes and remain single-select.'
Assert-True ($cwd[0].description -match 'Exact span\.cwd' -and $cwd[0].description -match 'worktree' -and $cwd[0].description -match 'not merged') 'Project cwd must explain exact worktree scoping.'
$projectSource = Get-Content -Raw (Join-Path $repoRoot 'grafana/provisioning/project-datasource.yaml')
Assert-True ($projectSource -match 'timeRangeForTags:\s+604800') 'Project discovery must query stored history with explicit time bounds.'
$deleteSection = [regex]::Match($projectSource, '(?ms)^deleteDatasources:\s*$\r?\n(?<body>.*?)(?=^datasources:\s*$)')
Assert-True $deleteSection.Success 'Project datasource provisioning must declare its legacy cleanup before managed datasources.'
$legacyProjectSource = [pscustomobject]@{
    Name = 'Codex project discovery'
    Uid = 'codex-projects'
    OrgId = 1
}
$legacyDeletePattern = '(?ms)^\s*-\s+name:\s+' + [regex]::Escape($legacyProjectSource.Name) + '\s*$\r?\n\s+orgId:\s+' + $legacyProjectSource.OrgId + '\s*$'
Assert-True ($deleteSection.Groups['body'].Value -match $legacyDeletePattern) 'Project datasource provisioning must delete the legacy datasource by its persisted name and org before reusing its UID.'
$managedProjectSource = [regex]::Match($projectSource, '(?ms)^datasources:\s*$.*?^\s*-\s+name:\s+Codex projects\s*$\r?\n\s+uid:\s+(?<uid>[^\s#]+)\s*$')
Assert-True ($managedProjectSource.Success -and $managedProjectSource.Groups['uid'].Value -ceq $legacyProjectSource.Uid) 'The managed project datasource must retain the stable UID freed by legacy cleanup.'
$compose = Get-Content -Raw (Join-Path $repoRoot 'compose.yaml')
Assert-True ($compose -match 'project-datasource.yaml:/otel-lgtm/grafana/conf/provisioning/datasources/codex-projects.yaml:ro') 'Historical project discovery must be provisioned at startup.'
$tempoConfig = Get-Content -Raw (Join-Path $repoRoot 'config/tempo.yaml')
Assert-True ($compose -match 'config/tempo.yaml:/otel-lgtm/tempo-config.yaml:ro') 'Tempo query limits must be provisioned at startup.'
Assert-True ($tempoConfig -match '(?s)query_frontend:.*search:.*max_duration: 169h.*metrics:.*max_duration: 169h') 'Weekly dashboard ranges require matching trace and metric limits with boundary headroom.'
Assert-True ($cwd[0].current.isNone -and $cwd[0].current.value -eq '' -and $cwd[0].current.text -match 'Project not selected') 'Project cwd must persist the explicit safe empty state, not a machine-specific path.'
Assert-True ($dashboard.panels.Count -eq 21) 'Unexpected dashboard panel count.'
Assert-True ($raw -notmatch '>>') 'Strict descendant queries must not be used for trace joins.'
Assert-True ($raw -notmatch '"type": "loki"') 'Dashboard must not query Loki log bodies.'
Assert-True ($raw -notmatch '\{\{\.output\}\}|tool_arguments|user_prompt') 'Unbounded/private payload fields are present.'

$snapshot = @($dashboard.panels | Where-Object id -eq 16)[0]
Assert-True ($snapshot.options.content -match '\$\{cwd:text\}') 'Snapshot panel must render the project selection text.'
Assert-True ($cwd[0].current.text -match ([string][char]0x26a0) -and $cwd[0].current.text -match 'Project not selected') 'Unselected-project warning is missing.'

$statPanels = @($dashboard.panels | Where-Object id -in @(1, 2, 3, 4, 5, 6, 17))
foreach ($panel in $statPanels) {
    Assert-True ($panel.fieldConfig.defaults.noValue -eq ([string][char]0x2014)) "Stat panel $($panel.id) must stay unset when no project is selected."
    Assert-True ($null -ne $panel.fieldConfig.defaults.PSObject.Properties['color']) "Stat panel $($panel.id) must declare an explicit color policy."
    Assert-True ($panel.fieldConfig.defaults.color.mode -in @('fixed', 'thresholds')) "Stat panel $($panel.id) has an unsupported color policy."
    $nullMapping = @($panel.fieldConfig.defaults.mappings | Where-Object {
        $_.type -eq 'special' -and $_.options.match -eq 'null' -and
        $_.options.result.text -eq ([string][char]0x2014) -and $_.options.result.color -eq 'gray'
    })
    Assert-True ($nullMapping.Count -eq 1) "Stat panel $($panel.id) must render null as a gray em dash."
}

foreach ($id in @(1, 2, 3, 5)) {
    $panel = @($statPanels | Where-Object id -eq $id)[0]
    Assert-True ($panel.fieldConfig.defaults.color.mode -eq 'fixed' -and $panel.fieldConfig.defaults.color.fixedColor -eq 'blue') "Informational stat panel $id must use fixed neutral blue."
}

function Assert-ThresholdSteps($Panel, [object[]]$Expected, [string]$Message) {
    Assert-True ($Panel.fieldConfig.defaults.color.mode -eq 'thresholds') "$Message Color mode must be thresholds."
    Assert-True ($Panel.fieldConfig.defaults.thresholds.mode -eq 'absolute') "$Message Threshold mode must be absolute."
    $actual = @($Panel.fieldConfig.defaults.thresholds.steps)
    Assert-True ($actual.Count -eq $Expected.Count) "$Message Unexpected threshold count."
    for ($i = 0; $i -lt $Expected.Count; $i++) {
        $sameValue = ($null -eq $actual[$i].value -and $null -eq $Expected[$i].value) -or ($actual[$i].value -eq $Expected[$i].value)
        Assert-True ($actual[$i].color -eq $Expected[$i].color -and $sameValue) "$Message Threshold step $i drifted."
    }
}

$cacheHitPanel = @($statPanels | Where-Object id -eq 4)[0]
Assert-ThresholdSteps $cacheHitPanel @(
    [pscustomobject]@{ color = 'red'; value = $null },
    [pscustomobject]@{ color = 'orange'; value = 50 },
    [pscustomobject]@{ color = 'green'; value = 80 }
) 'Cache hit.'

$failureRatePanel = @($statPanels | Where-Object id -eq 6)[0]
Assert-True ($failureRatePanel.title -eq 'Dispatch failure rate %' -and $failureRatePanel.fieldConfig.defaults.unit -eq 'percent') 'Panel 6 must display Dispatch failure rate %.'
Assert-ThresholdSteps $failureRatePanel @(
    [pscustomobject]@{ color = 'green'; value = $null },
    [pscustomobject]@{ color = 'orange'; value = 1 },
    [pscustomobject]@{ color = 'red'; value = 5 }
) 'Tool failure rate.'
$failureTarget = @($failureRatePanel.targets | Where-Object refId -eq 'A')[0]
$callsTarget = @($failureRatePanel.targets | Where-Object refId -eq 'B')[0]
$failureReduction = @($failureRatePanel.targets | Where-Object refId -eq 'C')[0]
$callsReduction = @($failureRatePanel.targets | Where-Object refId -eq 'D')[0]
$rateTarget = @($failureRatePanel.targets | Where-Object refId -eq 'E')[0]
Assert-True ($failureTarget.query -match 'event\.success = "false"' -and $callsTarget.query -notmatch 'event\.success') 'Failure rate must use failures and all calls.'
$normalizedFailureQuery = $failureTarget.query -replace ' && event\.success = "false"', ''
Assert-True ($normalizedFailureQuery -ceq $callsTarget.query) 'Failure numerator and denominator must use the same canonical call set.'
Assert-True ($failureReduction.type -eq 'reduce' -and $failureReduction.reducer -eq 'sum' -and $failureReduction.expression -eq 'A') 'Failure rate numerator must sum the complete failure series.'
Assert-True ($callsReduction.type -eq 'reduce' -and $callsReduction.reducer -eq 'sum' -and $callsReduction.expression -eq 'B') 'Failure rate denominator must sum the complete call series.'
Assert-True ($failureReduction.settings.mode -eq 'dropNN' -and $callsReduction.settings.mode -eq 'dropNN') 'Failure rate reductions must preserve no-data instead of replacing it with zero.'
Assert-True ($rateTarget.type -eq 'math' -and $rateTarget.expression -eq '$C / ($D + ($D == 0)) * 100 + 0 * log($D != 0)') 'Failure rate must calculate 100 x failures / calls with an explicit zero-call null guard.'
Assert-True ($rateTarget.expression -notmatch '/\s*\$D(?:\s|\*)') 'Failure rate must never divide directly by a possibly-zero call count.'
function Get-SyntheticFailureRate([double]$Failures, [double]$Calls) {
    if ($Calls -eq 0) { return $null }
    return 100.0 * $Failures / $Calls
}
$zeroCallRate = Get-SyntheticFailureRate -Failures 0 -Calls 0
Assert-True ($null -eq $zeroCallRate) 'Failure rate contract must return null when calls is zero.'
Assert-True ([math]::Abs((Get-SyntheticFailureRate -Failures 11 -Calls 293) - (100.0 * 11 / 293)) -lt 0.0000001) 'Failure rate contract must retain the non-zero ratio.'
Assert-True ($failureRatePanel.options.reduceOptions.calcs[0] -eq 'lastNotNull') 'Failure rate display must preserve null instead of reducing it to numeric zero.'
Assert-True ($failureRatePanel.description -match 'failures' -and $failureRatePanel.description -match 'calls') 'Failure rate description must retain the absolute failures and calls definitions.'

foreach ($id in @(2, 3)) {
    $panel = @($statPanels | Where-Object id -eq $id)[0]
    Assert-True ($null -eq $panel.fieldConfig.defaults.PSObject.Properties['thresholds']) "Panel $id must not invent an absolute threshold without an SLO or budget."
}

$coveragePanel = @($statPanels | Where-Object id -eq 17)[0]
$coveragePolicies = @{
    'Missing terminal / outcome' = @('green', 'orange')
    'Completed without token usage' = @('green', 'orange')
}
foreach ($fieldName in $coveragePolicies.Keys) {
    $override = @($coveragePanel.fieldConfig.overrides | Where-Object { $_.matcher.id -eq 'byName' -and $_.matcher.options -eq $fieldName })
    Assert-True ($override.Count -eq 1) "Panel 17 must override $fieldName independently."
    $thresholdProperty = @($override[0].properties | Where-Object id -eq 'thresholds')
    Assert-True ($thresholdProperty.Count -eq 1 -and $thresholdProperty[0].value.mode -eq 'absolute') "Panel 17 override $fieldName must use absolute thresholds."
    $colors = @($thresholdProperty[0].value.steps | ForEach-Object color)
    Assert-True (($colors -join ',') -eq ($coveragePolicies[$fieldName] -join ',')) "Panel 17 override $fieldName has the wrong color policy."
}
$processRateOverride = @($coveragePanel.fieldConfig.overrides | Where-Object { $_.matcher.options -eq 'Process failure rate %' })[0]
Assert-True (@($processRateOverride.properties | Where-Object { $_.id -eq 'unit' -and $_.value -eq 'percent' }).Count -eq 1) 'Process failure rate must render as a percentage.'

function Get-StatColor($Panel, [double]$Value) {
    if ($Panel.fieldConfig.defaults.color.mode -eq 'fixed') { return $Panel.fieldConfig.defaults.color.fixedColor }
    $color = $Panel.fieldConfig.defaults.thresholds.steps[0].color
    foreach ($step in @($Panel.fieldConfig.defaults.thresholds.steps | Select-Object -Skip 1)) {
        if ($Value -ge [double]$step.value) { $color = $step.color }
    }
    return $color
}

$syntheticSnapshot = @(
    [pscustomobject]@{ id = 1; value = 34; expected = 'blue' },
    [pscustomobject]@{ id = 2; value = 80; expected = 'blue' },
    [pscustomobject]@{ id = 3; value = 16900000; expected = 'blue' },
    [pscustomobject]@{ id = 4; value = 91.9; expected = 'green' },
    [pscustomobject]@{ id = 5; value = 293; expected = 'blue' },
    [pscustomobject]@{ id = 6; value = (Get-SyntheticFailureRate -Failures 11 -Calls 293); expected = 'orange' }
)
$syntheticColors = @($syntheticSnapshot | ForEach-Object {
    Get-StatColor (@($statPanels | Where-Object id -eq $_.id)[0]) $_.value
})
Assert-True (($syntheticColors -join ',') -eq 'blue,blue,blue,green,blue,orange') 'Synthetic KPI snapshot must resolve to blue / blue / blue / green / blue / orange.'

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
$worktreeProjects = Get-SyntheticProjectState -TagNames @('cwd') -TagValues @('fixture://project', 'fixture://worktrees/task/project')
Assert-True ($worktreeProjects.Projects.Count -eq 2 -and $worktreeProjects.Projects -ccontains 'fixture://project' -and $worktreeProjects.Projects -ccontains 'fixture://worktrees/task/project') 'Saved project and worktree cwd must remain separate exact scopes.'

'dashboard project states: empty, single, multiple PASS'

$completed = @($dashboard.panels | Where-Object id -eq 1)[0].targets[0].query
Assert-True ($completed -match 'codex\.turn\.terminal' -and $completed -match 'codex\.turn\.status' -and $completed -match 'cwd') 'Completed-turn KPI must accept an explicit terminal signal.'

foreach ($panel in @($dashboard.panels | Where-Object id -in @(3,4,5,6))) {
    foreach ($target in @($panel.targets | Where-Object { $_.datasource.uid -eq 'tempo' })) {
        Assert-True ($target.metricsQueryType -eq 'range' -and $target.exemplars -eq 0 -and $target.step -eq '2m') 'Snapshot KPI must use complete range series with an explicit bounded step and no exemplars.'
    }
    if ($panel.id -in @(3,5)) {
        Assert-True ($panel.options.reduceOptions.calcs[0] -eq 'sum') 'Count/token KPI must sum the entire snapshot, not the last bucket.'
    }
    if ($panel.id -eq 4) {
        $reductions = @($panel.targets | Where-Object { $_.PSObject.Properties['reducer'] })
        Assert-True ($reductions.Count -eq 2 -and @($reductions | Where-Object reducer -ne 'sum').Count -eq 0) 'Ratios must divide snapshot sums, never average bucket averages.'
    }
    if ($panel.id -eq 6) {
        $reductions = @($panel.targets | Where-Object { $_.PSObject.Properties['reducer'] })
        Assert-True ($reductions.Count -eq 2 -and @($reductions | Where-Object reducer -ne 'sum').Count -eq 0) 'Failure rate must divide complete snapshot sums, never bucket rates.'
    }
}
Assert-True ($tempoConfig -match 'max_exemplars:\s+0') 'Tempo must suppress annotation frames before Grafana expressions aggregate numeric series.'

$failurePanels = @($dashboard.panels | Where-Object id -in @(6, 12, 14))
foreach ($panel in $failurePanels) {
    $queryText = (@($panel.targets | Where-Object { $_.PSObject.Properties['query'] } | ForEach-Object query) -join ' ')
    Assert-True ($queryText -match 'dispatch_tool_call_with_terminal_outcome' -and $queryText -match 'event\.success = "false"' -and $queryText -match 'cwd') "Failure panel $($panel.id) contract drifted."
}

$breakdown = @($dashboard.panels | Where-Object id -eq 13)[0]
$breakdownText = (@($breakdown.targets | ForEach-Object {
    $query = if ($_.PSObject.Properties['query']) { $_.query } else { '' }
    $expression = if ($_.PSObject.Properties['expression']) { $_.expression } else { '' }
    "$query $expression"
}) -join ' ')
Assert-True ($breakdownText -match 'run_sampling_request' -and $breakdownText -match 'dispatch_tool_call_with_terminal_outcome' -and $breakdownText -match 'traceIdHidden') 'Trace-ID time breakdown drifted.'
Assert-True ($breakdown.title -match 'cumulative' -and $breakdown.description -match 'not additive' -and $breakdownText -notmatch 'other_overhead') 'Dashboard components must be labeled cumulative and must not invent additive other time.'

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
$roundsPanel = @($dashboard.panels | Where-Object id -eq 11)[0]
Assert-True ($roundsPanel.fieldConfig.defaults.unit -eq 'none') 'Model rounds must be a count, not a duration.'
Assert-True (@($roundsPanel.targets | Where-Object { $_.datasource.uid -eq 'tempo' -and $_.queryType -eq 'traceqlSearch' -and $_.tableType -eq 'spans' }).Count -eq 5) 'Model rounds must join lifecycle and round span tables.'
$roundsSql = @($roundsPanel.targets | Where-Object refId -eq 'C')[0]
Assert-True ($roundsSql.type -eq 'sql' -and $roundsSql.expression -match 'LEFT JOIN' -and $roundsSql.expression -match 'COALESCE' -and $roundsSql.expression -match 'traceIdHidden') 'Model rounds must retain completed turns without rounds and join by Trace ID.'

$latencyText = (@($latency.targets | ForEach-Object query) -join ' ')
Assert-True ($latencyText -match 'quantile_over_time\(span:duration, \.50\)' -and $latencyText -match 'quantile_over_time\(span:duration, \.95\)' -and $latencyText -match 'max_over_time\(span:duration\)') 'Tool latency quantiles drifted.'

$linkCount = ([regex]::Matches($raw, 'Open trace in Tempo')).Count
$toolPanels = @($dashboard.panels | Where-Object id -in @(14,15,18,19))
foreach ($panel in $toolPanels) {
    foreach ($target in $panel.targets) {
        Assert-True ($target.query -match 'event\.tool_name' -and $target.query -notmatch 'span\.tool_name') "Tool panel $($panel.id) must use the event-scoped tool name."
    }
    if ($panel.type -eq 'table') {
        Assert-True (@($panel.fieldConfig.overrides | Where-Object { $_.matcher.options -eq 'event.tool_name' }).Count -eq 1) "Tool panel $($panel.id) must format the event.tool_name column."
        $organize = @($panel.transformations | Where-Object id -eq 'organize')[0]
        Assert-True ($null -ne $organize.options.indexByName.PSObject.Properties['event.tool_name']) "Tool panel $($panel.id) must position the event.tool_name column."
    }
}

Assert-True ($linkCount -ge 3) 'Required Trace ID links are missing.'

$tempoDiscards = @($dashboard.panels | Where-Object id -eq 20)[0]
Assert-True ($tempoDiscards.datasource.uid -eq 'prometheus' -and $tempoDiscards.type -eq 'timeseries') 'Tempo discard history must use the local Prometheus datasource.'
$discardQuery = @($tempoDiscards.targets | Where-Object refId -eq 'A')[0].expr
foreach ($reason in @('trace_too_large', 'trace_too_large_to_compact', 'live_traces_exceeded', 'rate_limited')) {
    Assert-True ($discardQuery -match [regex]::Escape($reason)) "Tempo discard monitoring is missing $reason."
}
Assert-True ($discardQuery -match 'tempo_discarded_spans_total' -and $discardQuery -match 'sum by \(reason\)') 'Tempo discard monitoring must retain the reason dimension.'

$collectorQueue = @($dashboard.panels | Where-Object id -eq 21)[0]
Assert-True ($collectorQueue.datasource.uid -eq 'prometheus' -and $collectorQueue.type -eq 'timeseries') 'Collector queue monitoring must use the local Prometheus datasource.'
$queueText = (@($collectorQueue.targets | ForEach-Object expr) -join ' ')
Assert-True ($queueText -match 'otelcol_exporter_queue_size' -and $queueText -match 'otelcol_exporter_queue_capacity') 'Collector queue size and capacity must remain visible together.'
Assert-True (([regex]::Matches($queueText, 'job="otel-collector"')).Count -eq 2) 'Collector queue panels must not include another Collector job.'
Assert-True ($tempoDiscards.description -match 'Stack-wide' -and $collectorQueue.description -match 'Stack-wide') 'Backend health panels must not imply Project cwd scoping.'

'codex dashboard contract regression: PASS'

foreach ($id in @(1,2,7,11,13,17)) {
    $panel = @($dashboard.panels | Where-Object id -eq $id)[0]
    $sql = @($panel.targets | Where-Object { $_.PSObject.Properties['expression'] })[-1].expression
    Assert-True ($sql -match "WHEN failed.traceIdHidden IS NOT NULL THEN 'failed'" -and $sql -match "ELSE 'unclassified'" -and $sql -notmatch 'grace|NOW\(') "Lifecycle panel $id must use the same failure precedence without age heuristics."
}
$coverage = @($dashboard.panels | Where-Object id -eq 17)[0]
foreach ($refId in @('E','L','Q','O','N')) {
    Assert-True (@($coverage.targets | Where-Object refId -eq $refId).Count -eq 1) "Coverage query $refId is missing."
}
$coverageSql = @($coverage.targets | Where-Object refId -eq 'Z')[0].expression
foreach ($field in @('Explicit terminal','Legacy completion','Missing terminal / outcome','Process failure rate %','Missing command outcomes')) {
    Assert-True ($coverageSql -match [regex]::Escape($field)) "Coverage output '$field' is missing."
}
Assert-True ($coverageSql -match 'ELSE NULL' -and $coverageSql -match 'MAX\(command_outcomes\.count\) = MAX\(command_calls\.count\)') 'Process failure rate must be null until command outcome coverage is complete.'
Assert-True ($coverageSql -notmatch 'basename|split_part|regexp_extract') 'Dashboard must not merge worktree cwd by directory name.'
Assert-True ($coverage.options.reduceOptions.calcs[0] -eq 'lastNotNull') 'Coverage panel must preserve null process failure rate as no-data.'
'lifecycle dashboard contract: PASS'
