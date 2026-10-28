$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\local\ClaudeLocalCore.ps1')
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$config=Get-CSConfig
$script:passed=0
function Assert-Interpretation([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAILED: '+$Message)};$script:passed++}
function New-InterpretationRtc([string]$Address){
    [pscustomobject]@{supported=$true;probes=@(
        [pscustomobject]@{server='stun:stun.cloudflare.com:3478';completed=$true;candidates=@([pscustomobject]@{type='srflx';address=$Address;port=12345})},
        [pscustomobject]@{server='stun:stun.l.google.com:19302';completed=$true;candidates=@([pscustomobject]@{type='srflx';address=$Address;port=54321})}
    )}
}
$r=Get-CSWebRtcVerdict $config (New-InterpretationRtc '203.0.113.90')
Assert-Interpretation ($r.State -eq 'fail' -and $r.Detail -match '公网 IPv4 地址' -and $r.Detail -notmatch 'IPv6') 'IPv4-only observations must not claim possible IPv6 exposure.'
Assert-Interpretation ($r.Evidence.PublicIPv4Count -eq 1 -and $r.Evidence.PublicIPv6Count -eq 0) 'Address-family counts must reflect deduplicated actual observations.'
$r=Get-CSWebRtcVerdict $config (New-InterpretationRtc '2001:db8::90')
Assert-Interpretation ($r.Detail -match '公网 IPv6 地址' -and $r.Evidence.PublicIPv6Count -eq 1) 'Real public-shaped IPv6 candidates must remain visible.'
$rtc=New-InterpretationRtc $config.expectedEgressIP
$rtc.probes[0].candidates+=@([pscustomobject]@{type='host';address='fe80::1234%18'},[pscustomobject]@{type='host';address='fd7a:115c:a1e0::1'},[pscustomobject]@{type='relay';address='2001:db8::99'})
$r=Get-CSWebRtcVerdict $config $rtc
Assert-Interpretation ($r.State -eq 'ok' -and $r.Evidence.PublicIPv6Count -eq 0) 'Link-local, ULA and remote relay IPv6 must not be counted as public client exposure.'
Assert-Interpretation ($r.Evidence.VerifiedStunCount -eq 2) 'Different source ports must not break IP-only exit verification.'
$rtc.probes[0].candidates+=[pscustomobject]@{type='host';address='2001:db8::10'}
$rtc.probes[1].candidates+=[pscustomobject]@{type='srflx';address='203.0.113.91'}
$r=Get-CSWebRtcVerdict $config $rtc
Assert-Interpretation ($r.Detail -match 'IPv4 和 IPv6' -and $r.Evidence.PublicIPv6Count -eq 1) 'Mixed address families must be named accurately.'
$r=Get-CSWebRtcVerdict $config ([pscustomobject]@{supported=$true;probes=@()})
Assert-Interpretation ($r.State -eq 'unknown' -and $r.Detail -match '不是已发现泄露' -and $r.Detail -match '检测未完成') 'No replies must distinguish no observed exposure from a completed safety check.'
$draft=New-CSLeakResult 'DNS泄露' 'fail' 'fixture HTTP mismatch' @('198.51.100.53','2001:db8::53')
$draft=Add-CSLeakDiagnostics $draft ([pscustomobject]@{ReportValid=$true;ControlMatchesPinned=$false}) @()
Assert-Interpretation (@(Get-CSDnsDraftAddresses $config $draft).Count -eq 2) 'Valid observations must be available as comparison drafts without a matching HTTP pin.'
Assert-Interpretation ($draft.State -eq 'fail' -and -not $draft.Evidence.ControlMatchesPinned) 'Preparing a draft must not alter an exit mismatch verdict.'
$draft.Evidence.ReportValid=$false
Assert-Interpretation (@(Get-CSDnsDraftAddresses $config $draft).Count -eq 0) 'Malformed or unvalidated reports must not populate drafts.'
$draft.Evidence.ReportValid=$true;$draft.Addresses=@()
Assert-Interpretation (@(Get-CSDnsDraftAddresses $config $draft).Count -eq 0) 'Missing DNS data must never invent a resolver baseline.'
$config.allowedDnsResolverIPs=@('198.51.100.53')
$r=Get-CSDnsVerdict $config @([pscustomobject]@{type='ip';ip=$config.expectedEgressIP},[pscustomobject]@{type='dns';ip='198.51.100.54'})
Assert-Interpretation ($r.State -eq 'unknown' -and $r.Detail -match '地址池轮换' -and $r.Detail -match '不能认定泄露') 'Resolver pool rotation alone must remain an observation, not a proven leak.'
$config.allowedDnsResolverIPs=@()
$r=Get-CSDnsVerdict $config @([pscustomobject]@{type='ip';ip=$config.expectedEgressIP},[pscustomobject]@{type='dns';ip='2001:db8::53'})
Assert-Interpretation ($r.Detail -match '留空也不影响启动') 'The baseline must be described as optional.'
$evidence=@{Stage='';SessionHttpStatus='200';ReportHttpStatus='200';Queries=[pscustomobject]@{Started=6;Completed=0;Failed=0;Pending=6;Errors=@()}}
$r=New-CSDnsProbeFailure 'ReportService' 'Windows DNS 查询全部超时' $evidence
Assert-Interpretation ($r.State -eq 'unknown' -and ($r.DiagnosticLines -join ' ') -match '仍未返回 6') 'All timed-out system DNS probes must remain distinct from parse failures.'
"Passed $script:passed leak interpretation assertions; only fictional reports were used."
