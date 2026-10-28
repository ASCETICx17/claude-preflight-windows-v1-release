$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\local\ClaudeLocalCore.ps1')
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:passed=0
function Assert-Leak([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAILED: '+$Message)};$script:passed++}
$config=Get-CSConfig
$config.allowedDnsResolverIPs=@('198.51.100.53')
$script:routeVirtual=$true;$script:routeMissing=$false
function Find-NetRoute {
    [CmdletBinding()]param([string]$RemoteIPAddress)
    if(-not $script:routeMissing){[pscustomobject]@{DestinationPrefix='198.18.0.0/15';InterfaceIndex=21}}
}
function Get-NetAdapter {
    [CmdletBinding()]param([switch]$IncludeHidden)
    [pscustomobject]@{ifIndex=21;Status='Up';Virtual=$script:routeVirtual}
}
Assert-Leak (Test-CSFakeAddressRoute '198.18.0.42') 'A live virtual route can trigger Fake-IP resolution even without any GUI config.'
$script:routeVirtual=$false
Assert-Leak (-not(Test-CSFakeAddressRoute '198.18.0.42')) 'Fake-IP follow-up must not use a physical adapter.'
$script:routeVirtual=$true;$script:routeMissing=$true
Assert-Leak (-not(Test-CSFakeAddressRoute '198.18.0.42')) 'An unknown best route must not trigger a Fake-IP connection.'
foreach($ip in @('10.0.0.1','127.0.0.1','192.168.1.1','172.16.2.1','100.100.100.100','169.254.1.1','198.18.0.1','224.0.0.1','::1','fe80::1234','fd7a:115c:a1e0::1','example.local')){
    Assert-Leak (-not(Test-CSGlobalAddress $ip)) 'Internal addresses and mDNS names must not be public leaks.'
}
foreach($ip in @('203.0.113.10','198.51.100.53','2606:4700:4700::1111','::ffff:203.0.113.10')){
    Assert-Leak (Test-CSGlobalAddress $ip) 'Global-shaped probe fixtures must be recognized.'
}
$goodDns=@([pscustomobject]@{type='ip';ip=$config.expectedEgressIP},[pscustomobject]@{type='dns';ip='198.51.100.53'})
Assert-Leak ((Get-CSDnsVerdict $config $goodDns).State -eq 'ok') 'Observed allowed resolver must pass.'
$config.allowedDnsResolverIPs=@()
Assert-Leak ((Get-CSDnsVerdict $config $goodDns).State -eq 'unknown') 'First observation must never auto-enroll a DNS resolver.'
$config.allowedDnsResolverIPs=@('198.51.100.53')
Assert-Leak ((Get-CSDnsVerdict $config @()).State -eq 'unknown') 'Empty DNS evidence must be unknown.'
$mixedDns=@($goodDns)+[pscustomobject]@{type='dns';ip='198.51.100.54'}
Assert-Leak ((Get-CSDnsVerdict $config $mixedDns).State -eq 'unknown') 'DNS pool changes alone cannot prove a leak and remain advisory.'
$badControl=@([pscustomobject]@{type='ip';ip='203.0.113.11'},$goodDns[1])
Assert-Leak ((Get-CSDnsVerdict $config $badControl).State -eq 'fail') 'Control HTTP egress mismatch must fail.'
$conclusionOnly=@([pscustomobject]@{type='conclusion';ip='DNS is not leaking.'})
Assert-Leak ((Get-CSDnsVerdict $config $conclusionOnly).State -eq 'unknown') 'Server marketing conclusion is not DNS evidence.'
function New-RtcReport([string]$Address){
    [pscustomobject]@{supported=$true;probes=@(
        [pscustomobject]@{server='stun:stun.cloudflare.com:3478';candidates=@([pscustomobject]@{address=$Address;type='srflx';protocol='udp'})},
        [pscustomobject]@{server='stun:stun.l.google.com:19302';candidates=@([pscustomobject]@{address=$Address;type='srflx';protocol='udp'})}
    )}
}
$rtc=New-RtcReport $config.expectedEgressIP
Assert-Leak ((Get-CSWebRtcVerdict $config $rtc).State -eq 'ok') 'Both expected STUN exits must pass.'
Assert-Leak ((Get-CSWebRtcVerdict $config (New-RtcReport '203.0.113.11')).State -eq 'fail') 'An unexpected public IPv4 candidate must fail.'
Assert-Leak ((Get-CSWebRtcVerdict $config (New-RtcReport '2606:4700:4700::1111')).State -eq 'fail') 'An unauthorized public IPv6 candidate must fail.'
Assert-Leak ((Get-CSWebRtcVerdict $config (New-RtcReport '192.168.1.1')).State -eq 'unknown') 'Private candidates alone cannot prove a safe public path.'
Assert-Leak ((Get-CSWebRtcVerdict $config ([pscustomobject]@{supported=$false;probes=@()})).State -eq 'unknown') 'Unsupported WebRTC must be unknown.'
Assert-Leak ((Get-CSWebRtcVerdict $config ([pscustomobject]@{supported=$true;probes=@()})).State -eq 'unknown') 'No ICE results must never be marked safe.'
$partial=New-RtcReport $config.expectedEgressIP;$partial.probes=@($partial.probes[0])
Assert-Leak ((Get-CSWebRtcVerdict $config $partial).State -eq 'unknown') 'One responding STUN endpoint is incomplete coverage.'
$duplicates=New-RtcReport $config.expectedEgressIP;$duplicates.probes[1].server=$duplicates.probes[0].server
Assert-Leak ((Get-CSWebRtcVerdict $config $duplicates).State -eq 'unknown') 'Duplicated STUN evidence must not fake two-node coverage.'
$rtc.probes[0].candidates+=@([pscustomobject]@{address='192.168.1.1';type='host';protocol='udp'},[pscustomobject]@{address='test.local';type='host';protocol='udp'})
Assert-Leak ((Get-CSWebRtcVerdict $config $rtc).State -eq 'ok') 'LAN and mDNS host candidates must not cause a false public leak.'
$rtc.probes[0].candidates+=[pscustomobject]@{address='198.51.100.20';type='relay';protocol='udp'}
Assert-Leak ((Get-CSWebRtcVerdict $config $rtc).State -eq 'ok') 'A TURN relay address must not be mistaken for the client exit.'
$rtc.probes[0].candidates+=[pscustomobject]@{address='2001:db8::20';type='host';protocol='udp'}
Assert-Leak ((Get-CSWebRtcVerdict $config $rtc).State -eq 'fail') 'A visible public-shaped IPv6 host candidate must fail.'
$script:fakeConnects=0;$script:resolved='198.18.0.42';$script:tunForFake=$true
function Get-CSDnsQueryResults([string[]]$Names){
    [pscustomobject]@{Completed=$true;Failed=$false;Pending=$false;Addresses=@([Net.IPAddress]::Parse($script:resolved))}
}
function Test-CSFakeAddressRoute([string]$Address){return $script:tunForFake}
function Invoke-CSFakeDnsConnect([string[]]$Addresses){$script:fakeConnects++}
$null=Invoke-CSDnsQueries @('1.public-fixture.bash.ws') $config
Assert-Leak ($script:fakeConnects -eq 1) 'Fake-IP DNS must trigger lazy upstream resolution through the live TUN.'
$script:resolved='198.51.100.20'
$null=Invoke-CSDnsQueries @('2.public-fixture.bash.ws') $config
Assert-Leak ($script:fakeConnects -eq 1) 'Normal DNS answers must not emit extra TCP probes.'
$script:resolved='198.18.0.43';$script:tunForFake=$false
$null=Invoke-CSDnsQueries @('3.public-fixture.bash.ws') $config
Assert-Leak ($script:fakeConnects -eq 1) 'A Fake-IP without a live virtual route must not trigger a follow-up connection.'
$script:dnsQueries=0;$script:requests=0;$script:sessionId='public-test-session'
function Invoke-CSDnsQueries([string[]]$Names){$script:dnsQueries++;Assert-Leak ($Names.Count -eq 6 -and @($Names|Where-Object {$_ -notmatch '^\d+\.public-test-session\.bash\.ws$'}).Count -eq 0) 'Only the six scoped random-session DNS names may be resolved.'}
function Invoke-CSRequest($Config,[string]$Url){
    $script:requests++
    $body=if($Url -eq 'https://bash.ws/id'){$script:sessionId}else{ConvertTo-Json -InputObject $goodDns -Compress}
    [pscustomobject]@{Success=$true;HttpStatus='200';Body=$body}
}
Assert-Leak ((Invoke-CSDnsLeakCheck $config).State -eq 'ok') 'DNS protocol must parse an actual-shaped observation.'
$script:sessionId='../invalid'
Assert-Leak ((Invoke-CSDnsLeakCheck $config).State -eq 'unknown') 'Invalid service IDs must not become DNS names or URLs.'
Assert-Leak ($script:dnsQueries -eq 1) 'Invalid sessions must emit no DNS probes.'
function Invoke-CSRequest($Config,[string]$Url){throw 'mock service failure'}
Assert-Leak ((Invoke-CSDnsLeakCheck $config).State -eq 'unknown') 'Service errors must be unknown.'
$script:probeCalls=0
function Invoke-CSDnsLeakCheck($Config){$script:probeCalls++;New-CSLeakResult 'DNS泄露' 'ok' 'mock'}
function Invoke-CSWebRtcLeakCheck($Config){$script:probeCalls++;New-CSLeakResult 'WebRTC泄露' 'unknown' 'mock'}
$script:leakStarted=0
function Start-CSLeakTask($Config,[string]$Kind){$script:leakStarted++;[pscustomobject]@{Config=$Config;Kind=$Kind}}
function Wait-CSLeakTask($Task,[string]$Kind){
    Assert-Leak ($script:leakStarted -eq 2) 'Both leak tasks must start before either is awaited.'
    if($Kind -eq 'Dns'){Invoke-CSDnsLeakCheck $Task.Config}else{Invoke-CSWebRtcLeakCheck $Task.Config}
}
$blocked=@(Get-CSLeakCheckBundle $config $false)
Assert-Leak ($script:probeCalls -eq 0 -and $blocked.Count -eq 2) 'Unready TUN or egress must emit no DNS or browser probes.'
Assert-Leak (@($blocked|Where-Object {-not $_.Required -and $_.Status -eq 'warn'}).Count -eq 2) 'Skipped probes must remain yellow advisories.'
Assert-Leak (-not $script:CSLastLeakDiagnostics.Dns.Attempted -and -not $script:CSLastLeakDiagnostics.WebRtc.Attempted) 'Skipped measurement must be distinguishable from an empty observation.'
$rows=@(Get-CSLeakCheckBundle $config $true)
Assert-Leak ($script:probeCalls -eq 2 -and $rows[0].Status -eq 'ok' -and $rows[1].Status -eq 'warn' -and -not $rows[1].Required) 'Unknown browser state must remain a yellow advisory, never a success assertion.'
$tunOff=[pscustomobject]@{Success=$false;Detail='v2rayN TUN switch is off'}
$state=New-CSLeakNetworkState $config $tunOff $true $config.expectedEgressIP $config.expectedEgressIP
Assert-Leak (-not $state.Ready -and ($state.Reasons -join '') -match 'switch is off') 'Precise TUN reason must survive the network gate.'
$state=New-CSLeakNetworkState $config ([pscustomobject]@{Success=$true}) $true '203.0.113.11' '203.0.113.11'
Assert-Leak (-not $state.Ready -and ($state.Reasons -join '') -match '固定 IP') 'A different test exit must explain the fixed IP mismatch.'
$script:leakStarted=0
function Test-CSPort($Uri,$Seconds){$true}
$observed=@(Get-CSLeakObservation $config)
Assert-Leak ($observed.Count -eq 2 -and $script:leakStarted -eq 2) 'Explicit observation must run without pretending that TUN and fixed egress passed.'
$launchBlocked=$false;try{Assert-CSCanLaunch $observed}catch{$launchBlocked=$true}
Assert-Leak $launchBlocked 'Observation alone must never authorize launch.'
$script:leakStarted=0
$pending=Start-CSLeakBundle $config $true
Assert-Leak ($pending.Started -and $script:leakStarted -eq 2 -and $null -eq $pending.Dns) 'A leak batch must start immediately and remain consumable after unrelated local checks.'
$independent=@(Complete-CSLeakBundle $pending)
Assert-Leak ($independent.Count -eq 2) 'Completion after other local work must preserve both measurements.'
$partialConfig=Convert-CSRuntimeConfig ([pscustomobject]@{proxyUrl='http://127.0.0.1:12345'})
Assert-Leak (-not (Get-CSProxyIssue $partialConfig) -and @(Get-CSConfigurationIssues $partialConfig).Count -gt 0) 'Probe configuration can have a valid saved proxy even when launch configuration is incomplete.'
$multiple=@($goodDns)+[pscustomobject]@{type='dns';ip='198.51.100.54'}
$config.allowedDnsResolverIPs=@('198.51.100.53','198.51.100.54')
Assert-Leak ((Get-CSDnsVerdict $config $multiple).State -eq 'ok') 'Multiple verified DNS resolver exits must be accepted.'
$badConfig=Get-CSConfig;$badConfig.allowedDnsResolverIPs=@('example.invalid')
Assert-Leak (@(Get-CSConfigurationIssues $badConfig).Count -gt 0) 'DNS allowlist must reject domain names.'
$badConfig.allowedDnsResolverIPs=@('198.51.100.0/24')
Assert-Leak (@(Get-CSConfigurationIssues $badConfig).Count -gt 0) 'DNS allowlist must reject CIDR expansion.'
"Passed $script:passed leak-detection assertions; all DNS, HTTP and browser calls were mocked."
