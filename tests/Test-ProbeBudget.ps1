$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\local\ClaudeLocalCore.ps1')
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:passed=0
function Assert-Budget([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAILED: '+$Message)};$script:passed++}
foreach($case in @(@(9003,'not_found'),@(9002,'server_failure'),@(9005,'refused'),@(1460,'timeout'),@(5,'access_denied'),@(9501,'no_record'))){
    $exception=New-Object ComponentModel.Win32Exception([int]$case[0],'private-query-and-path-must-not-appear')
    $errorRecord=New-Object Management.Automation.ErrorRecord($exception,'DNS_ERROR_FIXTURE',[Management.Automation.ErrorCategory]::NotSpecified,'private-target')
    $failure=Get-CSDnsFailure $errorRecord
    Assert-Budget ($failure.Code -eq $case[0] -and $failure.Kind -eq $case[1]) 'Windows DNS error codes must survive into a precise category.'
    Assert-Budget (($failure|ConvertTo-Json -Compress) -notmatch 'private') 'Raw exception message and target must not be retained.'
}
$missing=[pscustomobject]@{Exception=[Exception]::new('private');FullyQualifiedErrorId='CommandNotFoundException'}
Assert-Budget ((Get-CSDnsFailure $missing).Kind -eq 'command_unavailable') 'A missing PowerShell command must not be blamed on DNS or the network.'
$pipeline=[PowerShell]::Create();$wrapped=$null
$null=$pipeline.AddScript(@'
$native=New-Object ComponentModel.Win32Exception(9003,'private-domain')
$record=New-Object Management.Automation.ErrorRecord($native,'DNS_ERROR_RCODE_NAME_ERROR',[Management.Automation.ErrorCategory]::NotSpecified,'private-domain')
Write-Error -ErrorRecord $record -ErrorAction Stop
'@)
try{$handle=$pipeline.BeginInvoke();$null=$pipeline.EndInvoke($handle)}catch{$wrapped=Get-CSDnsFailure $_}finally{$pipeline.Dispose()}
Assert-Budget ($wrapped.Code -eq 9003 -and $wrapped.Kind -eq 'not_found') 'The real EndInvoke/ActionPreferenceStopException/ErrorRecord nesting must preserve DNS code 9003.'
Assert-Budget (($wrapped|ConvertTo-Json -Compress) -notmatch 'private-domain|wrapper') 'Unwrapping PowerShell errors must not retain private message strings.'
$config=Get-CSConfig
$before=[DateTime]::UtcNow;$deadline=Get-CSProbeDeadline $config
Assert-Budget (($deadline-$before).TotalSeconds -ge 29 -and ($deadline-$before).TotalSeconds -le 31) 'Standalone probes must receive a thirty-second total budget.'
$clone=$config.PSObject.Copy();$clone|Add-Member probeDeadlineUtc ([DateTime]::UtcNow.AddSeconds(2))
$shared=Get-CSProbeDeadline $clone
Assert-Budget ($shared -eq $clone.probeDeadlineUtc -and (Get-CSProbeSeconds $shared 10) -le 2) 'Nested phases must consume the original deadline rather than reset their timer.'
$expired=$false;try{$null=Get-CSProbeSeconds ([DateTime]::UtcNow.AddSeconds(-1)) 10}catch [TimeoutException]{$expired=$true}
Assert-Budget $expired 'An expired budget must prevent new requests.'
Assert-Budget (-not $config.PSObject.Properties['probeDeadlineUtc'] -and $config.requestTimeoutSeconds -eq 8) 'Transient deadlines must not mutate the personal or mandatory-check configuration.'
$nearFull=Get-CSDnsWaitMilliseconds ([DateTime]::UtcNow.AddSeconds(30))
Assert-Budget ($nearFull -gt 24000 -and $nearFull -le 26000) 'DNS must use the remaining budget instead of the old ten-second cap, reserving four seconds for its report.'
$nearEnd=Get-CSDnsWaitMilliseconds ([DateTime]::UtcNow.AddSeconds(6))
Assert-Budget ($nearEnd -gt 0 -and $nearEnd -le 2000) 'A late DNS phase must not reset the shared deadline.'
$noTime=$false;try{$null=Get-CSDnsWaitMilliseconds ([DateTime]::UtcNow.AddSeconds(3))}catch [TimeoutException]{$noTime=$true}
Assert-Budget $noTime 'Do not start system queries if no report budget remains.'
$pending=[pscustomobject]@{Started=6;Completed=0;Failed=0;Pending=6;WaitSeconds=25;WaitLimitSeconds=25;Errors=@()}
$pendingLines=(Get-CSDnsProgressLines $pending) -join ' '
Assert-Budget ($pendingLines -match '程序到达等待上限时仍未返回 6' -and $pendingLines -notmatch '6 超时') 'App-cancelled queries must not be mislabeled as native timeout errors.'
Assert-Budget ($pendingLines -match '实际查询等待 25 秒' -and $pendingLines -match '上限 25 秒') 'The actual DNS wait and allocated stage budget must be visible.'
$baselineFailure=New-CSDnsProbeFailure 'ReportService' '本轮查询失败' @{SavedBaselineCount=12;Queries=$pending;SessionHttpStatus='200';ReportHttpStatus='200'}
Assert-Budget ($baselineFailure.State -eq 'unknown' -and ($baselineFailure.DiagnosticLines -join ' ') -match '已保存比较基线：12 个地址' -and ($baselineFailure.DiagnosticLines -join ' ') -match '尚未进行基线比较') 'A saved baseline must not turn absent current observations into a pass or a mismatch finding.'
function Get-CSDnsQueryResults([string[]]$Names,[int]$TimeoutMilliseconds){
    foreach($name in $Names){[pscustomobject]@{Completed=$false;Failed=$true;Pending=$false;Addresses=@();Failure=[pscustomobject]@{Kind='refused';Code=9005;Label='DNS 服务器拒绝查询'}}}
}
$queries=Invoke-CSDnsQueries @('public-1.invalid','public-2.invalid') $config 500
Assert-Budget ($queries.Failed -eq 2 -and $queries.Errors.Count -eq 1 -and $queries.Errors[0].Count -eq 2) 'Identical query errors must be grouped without losing their count.'
$evidence=@{SessionHttpStatus='200';ReportHttpStatus='200';Queries=$queries}
$r=New-CSDnsProbeFailure 'ReportService' 'fixture' $evidence
Assert-Budget (($r.DiagnosticLines -join ' ') -match '9005' -and ($r.DiagnosticLines -join ' ') -match '拒绝查询') 'The exact diagnostic code and meaning must reach the UI-visible lines.'
$rtc=[pscustomobject]@{supported=$true;probes=@([pscustomobject]@{server='stun:stun.cloudflare.com:3478';errors=@(701);errorKinds=@('name_resolution','private-message');candidates=@();completed=$true;timedOut=$false})}
$rtcResult=Get-CSWebRtcVerdict $config $rtc
Assert-Budget (($rtcResult.DiagnosticLines -join ' ') -match '名称解析失败' -and $rtcResult.State -eq 'unknown') 'Browser error categories must reach the visible result without turning an empty observation into success.'
Assert-Budget (($rtcResult|ConvertTo-Json -Depth 8 -Compress) -notmatch 'private-message') 'Only whitelisted browser categories may survive into diagnostics.'
$rtc.probes[0]|Add-Member waitedMs 23000
$rtc.probes[0]|Add-Member waitLimitMs 24000
$rtc.probes[0].timedOut=$true
$rtcResult=Get-CSWebRtcVerdict $config $rtc
Assert-Budget ($rtcResult.Evidence.Probes[0].WaitSeconds -eq 23 -and ($rtcResult.DiagnosticLines -join ' ') -match '实际等待 23 秒') 'Browser wait duration must reach the diagnostic display.'
Assert-Budget (($rtcResult.DiagnosticLines -join ' ') -match '程序达到等待时限') 'Browser application deadline must be explicit rather than presented as a server error.'
$rtc.probes[0].errors=@(-1)
$rtcResult=Get-CSWebRtcVerdict $config $rtc
Assert-Budget (($rtcResult.DiagnosticLines -join ' ') -match '创建探针或会话失败' -and $rtcResult.State -eq 'unknown') 'A browser setup failure must not be diagnosed as STUN network timeout.'
$native=[TimeoutException]::new('private-local-path')
$native.Data['CSProbeStage']='DebugChannel'
$failure=[pscustomobject]@{Exception=[Exception]::new('private-wrapper',$native)}
$r=New-CSWebRtcProbeFailure 'BrowserStart' $failure
Assert-Budget ($r.Evidence.Stage -eq 'DebugChannel' -and $r.Evidence.ErrorKind -eq 'timeout' -and $r.Detail -match '本机浏览器调试通道') 'A nested browser timeout must keep the actual stage.'
Assert-Budget (($r|ConvertTo-Json -Depth 8 -Compress) -notmatch 'private') 'Stage diagnostics must not serialize raw exception paths or messages.'
$native.Data['CSProbeStage']='private-stage'
$r=New-CSWebRtcProbeFailure 'BrowserStart' $failure
Assert-Budget ($r.Evidence.Stage -eq 'BrowserStart' -and ($r|ConvertTo-Json -Compress) -notmatch 'private') 'Unknown stage names must not enter diagnostics.'
# Exercise production orchestration and cleanup precedence without starting Edge.
function Get-CSEdgePath{return 'fixture-edge'}
function Initialize-CSBrowserProbe{}
function Get-CSStunProbeOptions($Config){[pscustomobject]@{totalTimeoutMs=30000;timeoutMs=30000;servers=@()}}
function Invoke-CSBrowserProbe {
    if($script:badBrowserJson){return [pscustomobject]@{Json='invalid';CleanupComplete=$true}}
    $body=@{supported=$true;probes=@(@{server='stun:stun.l.google.com:19302';candidates=@(@{address='203.0.113.99';type='srflx';protocol='udp'});errors=@();completed=$true;timedOut=$false})}
    [pscustomobject]@{Json=($body|ConvertTo-Json -Depth 8 -Compress);CleanupComplete=$false}
}
$script:badBrowserJson=$false
$r=Invoke-CSWebRtcLeakCheck $config
Assert-Budget ($r.State -eq 'fail' -and $r.Addresses -contains '203.0.113.99' -and $r.Detail -match '固定出口之外' -and $r.Detail -match '未完全清理') 'Cleanup failure must not overwrite observed unexpected public-address evidence.'
$script:badBrowserJson=$true
$r=Invoke-CSWebRtcLeakCheck $config
Assert-Budget ($r.Evidence.Stage -eq 'ReportJson' -and $r.State -eq 'unknown') 'A malformed browser report must be separated from network unreachability.'
"Passed $script:passed deadline and DNS error-preservation assertions; no network requests."
