[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][string]$NotificationPath,
    [Parameter(Mandatory=$true)][ValidatePattern('^[0-9a-fA-F]{32}$')][string]$TraceId,
    [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()][string]$Project
)
# Convert an app-server turn/completed notification to a minimal OTLP trace.
# The caller must supply the SAME trace ID recorded at turn start. A turn UUID
# is not a trace ID. No network request, model invocation, or user config edit.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$notification = Get-Content -LiteralPath $NotificationPath -Raw | ConvertFrom-Json
if ($notification.method -cne 'turn/completed') { throw 'Expected a turn/completed notification.' }
$turn = $notification.params.turn
if ($turn.status -cnotin @('completed','failed','interrupted')) { throw 'Notification is not terminal.' }
if ($TraceId -match '^0+$') { throw 'The all-zero trace ID is invalid.' }
if ($null -eq $turn.startedAt -or $null -eq $turn.completedAt -or $turn.completedAt -lt $turn.startedAt) {
    throw 'Terminal notification requires explicit start/end timestamps.'
}
if ($turn.status -eq 'completed' -and $null -ne $turn.error) { throw 'Conflicting completed status and terminal error.' }
if ([string]::IsNullOrWhiteSpace($turn.id)) { throw 'Terminal notification requires a turn ID.' }
$hash = [Security.Cryptography.SHA256]::Create()
try { $spanId = ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes('codex.turn.terminal/v1:'+$TraceId.ToLowerInvariant()+':'+$turn.id)))).Replace('-','').Substring(0,16).ToLowerInvariant() }
finally { $hash.Dispose() }
$attrs = @(
    @{key='cwd';value=@{stringValue=$Project}},
    @{key='codex.turn.status';value=@{stringValue=[string]$turn.status}},
    @{key='codex.turn.signal_version';value=@{intValue='1'}}
)
# Never copy items, error messages, thread identifiers, or arbitrary attributes.
$span = @{
    traceId=$TraceId.ToLowerInvariant(); spanId=$spanId; name='codex.turn.terminal'; kind=1
    startTimeUnixNano=([decimal]$turn.startedAt*1000000000).ToString('0',[Globalization.CultureInfo]::InvariantCulture)
    endTimeUnixNano=([decimal]$turn.completedAt*1000000000).ToString('0',[Globalization.CultureInfo]::InvariantCulture)
    attributes=$attrs; status=@{code=if($turn.status -eq 'completed'){1}else{2}}
}
@{resourceSpans=@(@{
    resource=@{attributes=@(@{key='service.name';value=@{stringValue='codex-turn-lifecycle'}})}
    scopeSpans=@(@{scope=@{name='codex-otel-observability.turn-lifecycle';version='1'};spans=@($span)})
})} | ConvertTo-Json -Depth 12
