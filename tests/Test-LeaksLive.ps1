param([Parameter(Mandatory=$true)][string]$SettingsPath,[switch]$FullCheck)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot '..\windows\local\ClaudeLocalCore.ps1')
$config=Convert-CSRuntimeConfig (Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8|ConvertFrom-Json)
$proxyIssue=Get-CSProxyIssue $config
if($proxyIssue){throw 'The saved local proxy is invalid; no probes were sent.'}
if($FullCheck -and @(Get-CSConfigurationIssues $config).Count){throw 'Full launch configuration is incomplete.'}
$watch=[Diagnostics.Stopwatch]::StartNew()
$requiredSeconds=$null
if($FullCheck){
    # Explicit diagnostic CLI only: emulate the independent UI lifecycle.
    $pending=Start-CSLeakBundle $config (Test-CSPort ([uri]$config.proxyUrl) $config.connectTimeoutSeconds)
    $checks=@(Get-CSDirectChecks $config)
    $requiredSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,2)
    $null=Complete-CSLeakBundle $pending
}else{$checks=@(Get-CSLeakObservation $config)}
$watch.Stop()
[pscustomobject]@{
    FullCheck=[bool]$FullCheck
    Seconds=[Math]::Round($watch.Elapsed.TotalSeconds,2)
    RequiredChecksSeconds=$requiredSeconds
    DnsAttempted=$script:CSLastLeakDiagnostics.Dns.Attempted
    DnsState=$script:CSLastLeakDiagnostics.Dns.State
    DnsAddressCount=@($script:CSLastLeakDiagnostics.Dns.Addresses).Count
    DnsDetail=$script:CSLastLeakDiagnostics.Dns.Detail
    DnsEvidence=$script:CSLastLeakDiagnostics.Dns.Evidence
    WebRtcAttempted=$script:CSLastLeakDiagnostics.WebRtc.Attempted
    WebRtcState=$script:CSLastLeakDiagnostics.WebRtc.State
    RtcAddressCount=@($script:CSLastLeakDiagnostics.WebRtc.Addresses).Count
    RtcDetail=$script:CSLastLeakDiagnostics.WebRtc.Detail
    RtcEvidence=$script:CSLastLeakDiagnostics.WebRtc.Evidence
    TunStatus=[string]($checks|Where-Object Name -eq 'TUN网卡').Status
    FixedIpStatus=[string]($checks|Where-Object Name -eq '固定IP').Status
    ClaudeStarted=$false
    SystemChangesApplied=$false
}|ConvertTo-Json -Depth 7
