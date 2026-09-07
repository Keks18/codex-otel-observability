# Read only allowlisted attributes from full OTLP/Tempo traces. Never copy bodies,
# messages, exception text, arguments, or output into report rows.
function Get-TraceProperty($Object, [string]$Name, $Default = $null) {
    if ($null -ne $Object) {
        $property = $Object.PSObject.Properties[$Name]
        if ($null -ne $property) { return $property.Value }
    }
    return $Default
}
function ConvertFrom-OtelAttributes($Attributes) {
    $result = @{}
    foreach ($attribute in @($Attributes)) {
        if ($null -eq $attribute) { continue }
        foreach ($kind in @('stringValue','intValue','doubleValue','boolValue')) {
            $value = Get-TraceProperty $attribute.value $kind
            if ($null -ne $value) { $result[$attribute.key] = $value; break }
        }
    }
    return $result
}
function ConvertFrom-TraceActivity($Response, [string]$TraceId, [long]$FromMs, [long]$ToMs, [string]$Project = '') {
    $batches = @(Get-TraceProperty $Response 'batches' @()) + @(Get-TraceProperty $Response 'resourceSpans' @())
    if ($batches.Count -eq 0) { throw 'Full trace response has no resource spans.' }
    $spans = @($batches | ForEach-Object {
        $scopes = @(Get-TraceProperty $_ 'scopeSpans' @()) + @(Get-TraceProperty $_ 'instrumentationLibrarySpans' @())
        foreach ($scope in $scopes) { @(Get-TraceProperty $scope 'spans' @()) }
    })
    $scoped = [string]::IsNullOrEmpty($Project)
    foreach ($span in $spans) {
        $attributes = ConvertFrom-OtelAttributes (Get-TraceProperty $span 'attributes' @())
        if ($attributes.ContainsKey('cwd') -and [string]$attributes.cwd -ceq $Project) { $scoped = $true }
    }
    if (-not $scoped) { throw 'Hydrated trace does not contain the exact selected project.' }
    $seen = @{}
    $allowed = @('model','cwd','codex.turn.reasoning_effort','codex.turn.status','codex.turn.signal_version',
        'codex.turn.token_usage.input_tokens','codex.turn.token_usage.output_tokens',
        'codex.turn.token_usage.cached_input_tokens','codex.turn.token_usage.reasoning_output_tokens',
        'codex.turn.token_usage.total_tokens','tool_name','codex.tool.name','call_id','codex.tool.call_id',
        'nested','retry_count','recovered','failure_class','error.kind')
    foreach ($span in $spans) {
        $id = [string](Get-TraceProperty $span 'spanId' '')
        if (-not $id) { throw 'Full trace span is missing its ID.' }
        if ($seen.ContainsKey($id)) { continue }
        $seen[$id] = $true
        $start = [decimal](Get-TraceProperty $span 'startTimeUnixNano' 0)
        $end = [decimal](Get-TraceProperty $span 'endTimeUnixNano' 0)
        $time = [long][math]::Floor($start / 1000000)
        if ($time -lt $FromMs -or $time -gt $ToMs -or $end -gt ([decimal]$ToMs * 1000000)) { continue }
        $name = [string](Get-TraceProperty $span 'name' '')
        $attributes = ConvertFrom-OtelAttributes (Get-TraceProperty $span 'attributes' @())
        $source = switch ($name) {
            'session_task.turn' { 'A' }
            'codex.turn.terminal' { 'A' }
            'dispatch_tool_call_with_terminal_outcome' { 'C' }
            'responses_websocket.stream_request' { 'R' }
            'run_sampling_request' { 'S' }
            default { 'B' }
        }
        $row = [ordered]@{source=$source;name=$name;time=$time;duration=[double]($end-$start);traceIdHidden=$TraceId;spanID=$id}
        foreach ($key in $allowed) { if ($attributes.ContainsKey($key)) { $row[$key]=$attributes[$key] } }
        $row['otel.status_code'] = Get-TraceProperty (Get-TraceProperty $span 'status') 'code' 0
        foreach ($event in @(Get-TraceProperty $span 'events' @())) {
            if ($null -eq $event) { continue }
            $eventTime = [decimal](Get-TraceProperty $event 'timeUnixNano' $end)
            if ($eventTime -gt ([decimal]$ToMs * 1000000)) { continue }
            $eventAttrs = ConvertFrom-OtelAttributes (Get-TraceProperty $event 'attributes' @())
            foreach ($key in @('tool_name','success')) {
                if ($eventAttrs.ContainsKey($key)) { $row['event.'+$key]=$eventAttrs[$key] }
            }
        }
        [pscustomobject]$row
    }
}
