$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\local\ClaudeLocalCore.ps1')
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
. (Join-Path $PSScriptRoot '..\windows\local\NetworkRequests.ps1')
$script:passed=0
function Assert-Parallel([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAILED: '+$Message)};$script:passed++}
Add-Type -AssemblyName System.Net.Http
$script:started=@()
function Start-CSHttpRequest($Config,[string]$Url){
    $script:started+=$Url
    if($Url -match 'failure'){throw 'Simulated start failure'}
    $completion=New-Object 'Threading.Tasks.TaskCompletionSource[System.Net.Http.HttpResponseMessage]'
    $response=New-Object Net.Http.HttpResponseMessage([Net.HttpStatusCode]::Unauthorized)
    $response.Content=New-Object Net.Http.StringContent('public fixture')
    $completion.SetResult($response)
    [pscustomobject]@{Client=(New-Object Net.Http.HttpClient);Task=$completion.Task}
}
$pending=@(Start-CSRequestBatch (Get-CSConfig) @('https://a.invalid/','https://b.invalid/','https://failure.invalid/'))
Assert-Parallel ($pending.Count -eq 3 -and $script:started.Count -eq 3) 'All HTTP calls must start before any result is consumed.'
$responses=Wait-CSRequestBatch $pending
Assert-Parallel ($responses['https://a.invalid/'].HttpStatus -eq '401' -and $responses['https://a.invalid/'].Success) 'Expected HTTP 401 must remain a reachable endpoint, not a transport failure.'
Assert-Parallel ($responses['https://a.invalid/'].Body -eq 'public fixture') 'The completed body must be available after asynchronous transport.'
Assert-Parallel (-not $responses['https://failure.invalid/'].Success -and $responses.Count -eq 3) 'One request failure must not discard other endpoint results.'
# Real in-process runspaces load a local fixture core. No browser or network.
Add-Type -TypeDefinition 'public static class GuardProbeBarrier { public static System.Threading.CountdownEvent Ready = new System.Threading.CountdownEvent(2); public static bool Meet() { Ready.Signal(); return Ready.Wait(4000); } }'
$savedRoot=$script:CSLeakRoot
$fixtureRoot=Join-Path ([IO.Path]::GetTempPath()) ('GuardParallel-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixtureRoot)
$fixtureCore=@'
function Invoke-CSDnsLeakCheck($Config) {
    $state=if([GuardProbeBarrier]::Meet()){'ok'}else{'unknown'}
    [pscustomobject]@{Name='DNS泄露';State=$state;Detail='fixture';Addresses=@('198.51.100.53');Scope='fixture';Attempted=$true}
}
function Invoke-CSWebRtcLeakCheck($Config) {
    $state=if([GuardProbeBarrier]::Meet()){'ok'}else{'unknown'}
    [pscustomobject]@{Name='WebRTC泄露';State=$state;Detail='fixture';Addresses=@('203.0.113.10');Scope='fixture';Attempted=$true}
}
'@
try{
    [IO.File]::WriteAllText((Join-Path $fixtureRoot 'ClaudeLocalCore.ps1'),$fixtureCore,(New-Object Text.UTF8Encoding($true)))
    $script:CSLeakRoot=$fixtureRoot
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $rows=@(Get-CSLeakCheckBundle (Get-CSConfig) $true)
    $watch.Stop()
    Assert-Parallel ($rows.Count -eq 2 -and @($rows|Where-Object Status -eq 'ok').Count -eq 2) 'DNS and RTC runspaces must overlap at the same barrier; serial execution would fail.'
    Assert-Parallel ($script:CSLastLeakDiagnostics.Dns.Addresses.Count -eq 1 -and $script:CSLastLeakDiagnostics.WebRtc.Addresses.Count -eq 1) 'Parallel results must retain their separate observations.'
    $blocked=$false;try{Assert-CSCanLaunch $rows}catch{$blocked=$true}
    Assert-Parallel $blocked 'Two successful probes alone cannot bypass full launch checks.'
}finally{
    $script:CSLeakRoot=$savedRoot
    $owned=[IO.Path]::GetFullPath($fixtureRoot)
    $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\GuardParallel-'
    if(-not $owned.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe fixture cleanup path.'}
    Remove-Item -LiteralPath $owned -Recurse -Force
}
"Passed $script:passed parallel HTTP and real-runspace assertions; no network/browser/system changes."
