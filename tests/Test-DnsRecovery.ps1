$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\local\ClaudeLocalCore.ps1')
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:passed=0
function Assert-Recovery([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAILED: '+$Message)};$script:passed++}
$config=Get-CSConfig
$config.allowedDnsResolverIPs=@('198.51.100.53')
$good=@([pscustomobject]@{type='ip';ip=$config.expectedEgressIP},[pscustomobject]@{type='dns';ip='198.51.100.53'})
$payload=ConvertTo-Json -InputObject $good -Compress
$withBom=Convert-CSDnsReport ([string][char]0xFEFF+$payload)
Assert-Recovery ($withBom.Kind -eq 'report' -and $withBom.Records.Count -eq 2) 'A valid UTF-8 BOM report must retain its observations.'
$serviceError=Convert-CSDnsReport '{"error":"No data yet"}'
Assert-Recovery ($serviceError.Kind -eq 'service_error' -and $serviceError.Records.Count -eq 0) 'The real-shaped error object must not be called a schema mismatch or accepted as evidence.'
$metadata=Convert-CSDnsReport ('['+($payload.TrimStart('[').TrimEnd(']'))+',{"type":"conclusion","message":"fixture"}]')
Assert-Recovery ($metadata.Kind -eq 'report' -and $metadata.Records.Count -eq 2) 'Explanatory records without IP fields must not discard real address evidence.'
Assert-Recovery ((Convert-CSDnsReport '[{"type":"dns","ip":"not-an-address"}]').Kind -eq 'invalid_schema') 'Malformed address evidence must remain rejected.'
Assert-Recovery ((Convert-CSDnsReport '{"records":[]}').Kind -eq 'invalid_schema') 'Unknown container shapes must not silently bypass validation.'
$script:mode='late';$script:reportCalls=0;$script:reportBudget=0
function Invoke-CSDnsQueries([string[]]$Names,$Config){
    if($script:mode -eq 'pending'){return [pscustomobject]@{Started=6;Completed=0;Failed=0;Pending=6;FakeFollowUps=0}}
    return [pscustomobject]@{Started=6;Completed=6;Failed=0;Pending=0;FakeFollowUps=0}
}
function Invoke-CSRequest($Config,[string]$Url){
    if($Url -eq 'https://bash.ws/id'){return [pscustomobject]@{Success=$true;HttpStatus='200';Body='public-recovery-session'}}
    $script:reportCalls++
    $script:reportBudget=$Config.requestTimeoutSeconds
    if($script:mode -eq 'timeout' -or ($script:mode -eq 'timeout_then_good' -and $script:reportCalls -eq 1)){return (New-CSHttpFailure 'timeout')}
    $body=if($script:mode -in @('late','timeout_then_good') -and $script:reportCalls -ge 2){$payload}else{'{"error":"No data yet"}'}
    [pscustomobject]@{Success=$true;HttpStatus='200';Body=$body}
}
$r=Invoke-CSDnsLeakCheck $config
Assert-Recovery ($r.State -eq 'ok' -and $r.Evidence.ReportAttempts -eq 2) 'A delayed report must recover after one bounded retry.'
Assert-Recovery ($config.requestTimeoutSeconds -eq 8) 'Per-probe timeout tuning must not mutate the saved/runtime user configuration.'
$script:mode='permanent';$script:reportCalls=0
$r=Invoke-CSDnsLeakCheck $config
Assert-Recovery ($r.State -eq 'unknown' -and $r.Evidence.Stage -eq 'ReportService' -and $script:reportCalls -eq 2) 'Permanent service errors must stop after two report reads and remain unknown.'
$script:mode='pending';$script:reportCalls=0
$r=Invoke-CSDnsLeakCheck $config
Assert-Recovery ($r.Evidence.Stage -eq 'ReportService' -and $r.Detail -match 'Windows DNS' -and $script:reportCalls -eq 1) 'Unfinished system queries must not produce useless report polling or a misleading schema message.'
$script:mode='timeout_then_good';$script:reportCalls=0
$r=Invoke-CSDnsLeakCheck $config
Assert-Recovery ($r.State -eq 'ok' -and $script:reportCalls -eq 2 -and -not $r.Evidence.ErrorKind) 'A report transport timeout must recover once without retaining a stale error.'
Assert-Recovery ($script:reportBudget -le 10 -and $script:reportBudget -gt 0 -and $config.requestTimeoutSeconds -eq 8) 'Report download shares the thirty-second probe budget without changing mandatory HTTP checks.'
$script:mode='timeout';$script:reportCalls=0
$r=Invoke-CSDnsLeakCheck $config
Assert-Recovery ($r.State -eq 'unknown' -and $script:reportCalls -eq 2 -and $r.Evidence.ErrorKind -eq 'timeout') 'Repeated report timeouts must terminate as unknown after two attempts.'
$draft=New-CSLeakResult 'DNS泄露' 'unknown' 'fixture' @('198.51.100.53','198.51.100.53','2001:db8::53')
$draft=Add-CSLeakDiagnostics $draft ([pscustomobject]@{ReportValid=$true;ControlMatchesPinned=$true}) @()
Assert-Recovery (@(Get-CSDnsDraftAddresses $config $draft).Count -eq 2) 'Eligible draft observations must normalize and deduplicate IPv4/IPv6.'
$draft.Evidence.ControlMatchesPinned=$false
Assert-Recovery (@(Get-CSDnsDraftAddresses $config $draft).Count -eq 2) 'A valid observation remains eligible for an untrusted comparison draft even when the HTTP pin differs.'
$draft.Evidence.ControlMatchesPinned=$true;$draft.Addresses=@('127.0.0.1','198.18.0.1')
Assert-Recovery (@(Get-CSDnsDraftAddresses $config $draft).Count -eq 0) 'Loopback and virtual DNS answers must not be enrolled as public resolver exits.'
$script:lookupMode='good';$script:lookupTimeout=0
function Invoke-CSRequestBatch($Config,[string[]]$Urls){
    $script:lookupTimeout=$Config.requestTimeoutSeconds
    $responses=@{}
    foreach($url in $Urls){
        $name=if($url -match 'cloudflare'){'stun.cloudflare.com'}else{'stun.l.google.com'}
        $question=if($script:lookupMode -eq 'wrong_question'){'other.invalid'}else{$name}
        $address=if($script:lookupMode -eq 'private'){'127.0.0.1'}else{'198.51.100.20'}
        $body=@{Status=0;Question=@(@{name=$question;type=1});Answer=@(@{name=$name;type=1;data=$address})}|ConvertTo-Json -Depth 5 -Compress
        $responses[$url]=[pscustomobject]@{Success=($script:lookupMode -ne 'offline');HttpStatus='200';Body=$body}
    }
    return $responses
}
$options=Get-CSStunProbeOptions $config
Assert-Recovery ($options.servers.Count -eq 2 -and $options.servers[0].resolution -eq 'proxy_doh' -and $options.servers[0].urls[1] -eq 'stun:198.51.100.20:3478') 'Validated proxied DNS answers must supply STUN fallback addresses without another system hostname lookup.'
Assert-Recovery ($options.servers[0].urls[0] -eq $options.servers[0].id) 'The original hostname path must remain present, including any original IPv6 resolution capability.'
Assert-Recovery ($options.servers[1].id -eq 'stun:stun.l.google.com:19302') 'Changing the transport hostname must retain each provider identity for verdict coverage.'
Assert-Recovery ($script:lookupTimeout -le 5 -and $script:lookupTimeout -gt 0 -and $config.requestTimeoutSeconds -eq 8) 'STUN name lookup must be bounded without altering user configuration.'
foreach($mode in @('private','wrong_question','offline')){
    $script:lookupMode=$mode;$options=Get-CSStunProbeOptions $config
    Assert-Recovery ($options.servers[0].resolution -eq 'system_dns' -and $options.servers[0].urls[0] -eq $options.servers[0].id) 'Unavailable or invalid proxy DNS answers must fall back to the original hostname, never a private destination.'
}
"Passed $script:passed DNS recovery, draft and STUN resolution assertions; all network calls were mocked."
