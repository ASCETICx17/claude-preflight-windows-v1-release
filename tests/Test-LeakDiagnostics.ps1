$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\local\ClaudeLocalCore.ps1')
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:passed=0
function Assert-Diagnostic([bool]$Condition,[string]$Message){
    if(-not $Condition){throw ('FAILED: '+$Message)}
    $script:passed++
}
$config=Get-CSConfig
$config.allowedDnsResolverIPs=@('198.51.100.53')
Add-Type -AssemblyName System.Net.Http
foreach($kind in @('timeout','tls')){
    $completion=New-Object 'Threading.Tasks.TaskCompletionSource[System.Net.Http.HttpResponseMessage]'
    if($kind -eq 'timeout'){$completion.SetCanceled()}
    else{$completion.SetException([Exception](New-Object Security.Authentication.AuthenticationException('private failure detail')))}
    $response=Wait-CSHttpRequest ([pscustomobject]@{Client=(New-Object Net.Http.HttpClient);Task=$completion.Task})
    Assert-Diagnostic (-not $response.Success -and $response.ErrorKind -eq $kind) 'Transport diagnostics must classify cancellation and TLS failures through real Task exceptions.'
    Assert-Diagnostic (($response|ConvertTo-Json -Compress) -notmatch 'private failure detail') 'Network diagnostics must not retain exception messages.'
}
$script:mode='good';$script:queryCalls=0
$good=@([pscustomobject]@{type='ip';ip=$config.expectedEgressIP},[pscustomobject]@{type='dns';ip='198.51.100.53'})
function Invoke-CSDnsQueries([string[]]$Names,$Config){
    $script:queryCalls++
    [pscustomobject]@{Started=6;Completed=4;Failed=1;Pending=1;FakeFollowUps=0}
}
function Invoke-CSRequest($Config,[string]$Url){
    $session=($Url -eq 'https://bash.ws/id')
    if($session){
        if($script:mode -eq 'session403'){return [pscustomobject]@{Success=$true;HttpStatus='403';Body='<html>fixture</html>'}}
        if($script:mode -eq 'sessionTimeout'){return (New-CSHttpFailure 'timeout')}
        $body=if($script:mode -eq 'badId'){'../invalid'}else{'public-diagnostics-session'}
    }else{
        if($script:mode -eq 'report503'){return [pscustomobject]@{Success=$true;HttpStatus='503';Body='fixture'}}
        $body=switch($script:mode){
            'html'{'<html>fixture</html>'}
            'malformed'{'['}
            'schema'{'{"unexpected":true}'}
            'empty'{'[]'}
            default{ConvertTo-Json -InputObject $good -Compress}
        }
    }
    return [pscustomobject]@{Success=$true;HttpStatus='200';Body=$body}
}
$script:mode='session403';$r=Invoke-CSDnsLeakCheck $config
Assert-Diagnostic ($r.State -eq 'unknown' -and $r.Evidence.Stage -eq 'SessionRequest' -and $r.Detail -match '403') 'A blocked session request must show its actual HTTP status and step.'
Assert-Diagnostic ($script:queryCalls -eq 0) 'Failed session requests must emit no DNS probes.'
$script:mode='sessionTimeout';$r=Invoke-CSDnsLeakCheck $config
Assert-Diagnostic ($r.Evidence.ErrorKind -eq 'timeout' -and $r.Detail -match '超时') 'A request timeout must not be mislabeled as an invalid report.'
$script:mode='badId';$r=Invoke-CSDnsLeakCheck $config
Assert-Diagnostic ($r.Evidence.Stage -eq 'SessionValidation' -and $script:queryCalls -eq 0) 'Invalid session data must be distinguishable and must not enter a hostname.'
$script:mode='report503';$r=Invoke-CSDnsLeakCheck $config
Assert-Diagnostic ($r.Evidence.Stage -eq 'ReportRequest' -and $r.Evidence.SessionHttpStatus -eq '200' -and $r.Evidence.ReportHttpStatus -eq '503') 'A report failure must retain the successful session status.'
$script:mode='html';$r=Invoke-CSDnsLeakCheck $config
Assert-Diagnostic ($r.Evidence.Stage -eq 'ReportJson' -and $r.Detail -match '网页' -and $r.State -eq 'unknown') 'An HTTP-200 HTML page must not be treated as a DNS report.'
$script:mode='malformed';$r=Invoke-CSDnsLeakCheck $config
Assert-Diagnostic ($r.Evidence.Stage -eq 'ReportJson' -and $r.Detail -match 'JSON') 'Malformed JSON must have a parsing-specific failure.'
$script:mode='schema';$r=Invoke-CSDnsLeakCheck $config
Assert-Diagnostic ($r.Evidence.Stage -eq 'ReportSchema' -and $r.State -eq 'unknown') 'A changed response structure must not be accepted.'
$script:mode='empty';$r=Invoke-CSDnsLeakCheck $config
Assert-Diagnostic ($r.Evidence.Stage -eq 'Verdict' -and $r.Detail -match '没有解析器地址') 'A valid empty report must remain distinct from HTTP or parsing failure.'
$script:mode='good';$r=Invoke-CSDnsLeakCheck $config
Assert-Diagnostic ($r.State -eq 'ok' -and $r.Addresses.Count -eq 1 -and $r.Evidence.ControlMatchesPinned) 'A valid report must preserve addresses and the pinned-exit verification.'
Assert-Diagnostic ($r.Evidence.Queries.Completed -eq 4 -and ($r.DiagnosticLines -join '') -match '4/6') 'DNS resolution progress must survive into display diagnostics.'
Assert-Diagnostic (($r.Evidence|ConvertTo-Json -Depth 6 -Compress) -notmatch 'public-diagnostics-session|198\.51\.100\.53') 'Diagnostic metadata must exclude session tokens and resolver addresses.'
$noControl=Get-CSDnsVerdict $config @($good[1])
Assert-Diagnostic ($noControl.State -eq 'unknown' -and $noControl.Detail -match '缺少') 'Missing HTTP control evidence must not claim a detected exit mismatch.'
function New-EmptyRtc([bool]$TimedOut){
    [pscustomobject]@{supported=$true;probes=@(
        [pscustomobject]@{server='stun:stun.cloudflare.com:3478';candidates=@();completed=(-not $TimedOut);timedOut=$TimedOut;errors=@(701)},
        [pscustomobject]@{server='stun:stun.l.google.com:19302';candidates=@();completed=(-not $TimedOut);timedOut=$TimedOut;errors=@(701)}
    )}
}
$rtc=New-EmptyRtc $false
$r=Get-CSWebRtcVerdict $config $rtc
Assert-Diagnostic ($r.State -eq 'unknown' -and $r.Evidence.Observation -eq 'no_public_candidate') 'No candidates must not turn into a leak finding or a successful launch verification.'
Assert-Diagnostic ($r.Detail -match '未观察到' -and $r.EmptyReason -match '没有验证') 'The UI explanation must distinguish absence of exposure from verified routing.'
Assert-Diagnostic ($r.Evidence.Probes[0].Completed -and -not $r.Evidence.Probes[0].TimedOut -and $r.Evidence.Probes[0].Errors[0] -eq 701) 'Completed gathering and STUN errors must both remain visible.'
$r=Get-CSWebRtcVerdict $config (New-EmptyRtc $true)
Assert-Diagnostic ($r.Evidence.Probes[0].TimedOut -and -not $r.Evidence.Probes[0].Completed -and ($r.DiagnosticLines -join '') -match '时限') 'A real collection timeout must be distinguishable from completed collection with no public address.'
$rtc.probes[0].candidates=@([pscustomobject]@{address=$config.expectedEgressIP;type='srflx';protocol='udp'})
$r=Get-CSWebRtcVerdict $config $rtc
Assert-Diagnostic ($r.State -eq 'unknown' -and $r.Evidence.VerifiedStunCount -eq 1) 'One correct server must not replace the required two-server coverage.'
$rtc.probes[1].candidates=@([pscustomobject]@{address=$config.expectedEgressIP;type='srflx';protocol='udp'})
$r=Get-CSWebRtcVerdict $config $rtc
Assert-Diagnostic ($r.State -eq 'ok' -and $r.Evidence.VerifiedStunCount -eq 2) 'STUN errors on another interface must not discard two valid pinned-address observations.'
$rtc.probes[1].candidates+=@([pscustomobject]@{address='2001:db8::20';type='host';protocol='udp'})
$r=Get-CSWebRtcVerdict $config $rtc
Assert-Diagnostic ($r.State -eq 'fail' -and $r.Evidence.Observation -eq 'unexpected_public_candidate') 'Additional public IPv6 must still fail even when both pinned STUN responses exist.'
"Passed $script:passed leak-diagnostic assertions; all HTTP, DNS and browser inputs were mocked."
