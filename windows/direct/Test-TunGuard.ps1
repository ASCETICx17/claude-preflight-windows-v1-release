$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\local\ClaudeLocalCore.ps1')
. (Join-Path $PSScriptRoot '..\..\tests\TestSupport.ps1')
$config=Get-CSConfig
if(-not $config.proxyRoot) { $config.proxyRoot='C:\Mock\v2rayN' }
$script:fixtureProxyRoot=$config.proxyRoot
$script:passed=0
function Reset-TunMock {
    $script:guiEnabled=$true
    $script:coreRunning=$true
    $script:nicPresent=$true
    $script:nicStatus='Up'
    $script:nicDescription='sing-tun Tunnel'
    $script:prefixes=@('0.0.0.0/0')
    $script:bestIndex=31
    $script:bestMissing=$false
    $script:strictRoute=$true
    $script:autoRoute=$true
    $script:readThrows=$false
    $script:guiExists=$true
    $script:newGenerated=$false
    $script:legacyGenerated=$true
    $script:runningRoots=@()
}
function Assert-Tun([bool]$Condition,[string]$Message) {
    if(-not $Condition) { throw "FAILED: $Message" }
    $script:passed++
}
function Get-CSRunningV2rayRoots {return $script:runningRoots}
function Get-Content {
    [CmdletBinding()]param([string]$LiteralPath,[switch]$Raw,[string]$Encoding)
    if($LiteralPath -eq (Join-Path $config.proxyRoot 'guiConfigs\guiNConfig.json')) {
        if($script:readThrows) { throw 'Simulated denied read' }
        return ([pscustomobject]@{TunModeItem=@{EnableTun=$script:guiEnabled}}|ConvertTo-Json -Depth 4)
    }
    if($LiteralPath -in @((Join-Path $config.proxyRoot 'guiConfigs\configPre.json'),(Join-Path $config.proxyRoot 'binConfigs\configPre.json'))) {
        return ([pscustomobject]@{inbounds=@(@{type='tun';interface_name=$config.existingTunName;auto_route=$script:autoRoute;strict_route=$script:strictRoute})}|ConvertTo-Json -Depth 4)
    }
    Microsoft.PowerShell.Management\Get-Content @PSBoundParameters
}
function Test-Path {
    [CmdletBinding()]param([string]$LiteralPath,[string]$PathType)
    if($LiteralPath -eq (Join-Path $config.proxyRoot 'guiConfigs\guiNConfig.json')){return $script:guiExists}
    if($LiteralPath -eq (Join-Path $config.proxyRoot 'binConfigs\configPre.json')){return $script:newGenerated}
    if($LiteralPath -eq (Join-Path $config.proxyRoot 'guiConfigs\configPre.json')){return $script:legacyGenerated}
    Microsoft.PowerShell.Management\Test-Path @PSBoundParameters
}
function Get-Process {
    [CmdletBinding()]param([string[]]$Name)
    if($Name.Count -eq 1 -and $Name[0] -eq 'Claude') { return }
    if($Name.Count -eq 1 -and $Name[0] -eq 'sing-box') {
        if($script:coreRunning) { [pscustomobject]@{Name='sing-box'} }
        return
    }
    # Ordinary xray HTTP proxy remains available even when the TUN core is absent.
    [pscustomobject]@{Name='xray'}
}
function Get-NetAdapter {
    [CmdletBinding()]param([string]$Name)
    if($script:nicPresent) { [pscustomobject]@{Name=$Name;Status=$script:nicStatus;ifIndex=31;InterfaceDescription=$script:nicDescription} }
}
function Get-NetRoute {
    [CmdletBinding()]param([int]$InterfaceIndex,[string]$AddressFamily,[string]$PolicyStore)
    foreach($prefix in $script:prefixes) { [pscustomobject]@{DestinationPrefix=$prefix;InterfaceIndex=$InterfaceIndex} }
}
function Find-NetRoute {
    [CmdletBinding()]param([string]$RemoteIPAddress)
    if(-not $script:bestMissing) {
        [pscustomobject]@{IPAddress='172.18.0.1';InterfaceIndex=$script:bestIndex}
        [pscustomobject]@{DestinationPrefix='0.0.0.0/0';InterfaceIndex=$script:bestIndex}
    }
}
Reset-TunMock
Assert-Tun (Get-CSExistingTunState $config).Success 'Complete TUN state must pass.'
Reset-TunMock
$script:newGenerated=$true;$script:legacyGenerated=$false
Assert-Tun (Get-CSExistingTunState $config).Success 'New binConfigs layout must pass without a legacy generated file.'
$script:newGenerated=$false
Assert-Tun (-not (Get-CSExistingTunState $config).Success -and (Get-CSExistingTunState $config).Detail -match 'binConfigs/configPre.json') 'Missing generated config must explain layout mismatch, not claim TUN was switched off.'
Reset-TunMock;$script:guiExists=$false
Assert-Tun ((Get-CSExistingTunState $config).Detail -match '不是 TUN 关闭') 'Missing main config must not be confused with a disabled TUN.'
Reset-TunMock
$script:runningRoots=@($script:fixtureProxyRoot)
$wrong=Convert-CSRuntimeConfig $config;$wrong.proxyRoot='C:\Wrong\PreviewFolder'
$found=Resolve-CSTunDataLocation $wrong
Assert-Tun ($found.Root -eq $script:fixtureProxyRoot -and $found.SavedMismatch -and $found.Source -eq 'running') 'The actual running data directory must correct a wrong saved folder in memory.'
$script:runningRoots=@('C:\FirstV2ray','C:\SecondV2ray')
$ambiguous=$false;try{$null=Resolve-CSTunDataLocation $wrong}catch{$ambiguous=$true}
Assert-Tun $ambiguous 'Multiple active instances must not be guessed.'
Reset-TunMock;$script:coreRunning=$false
Assert-Tun ((Get-CSExistingTunState $config).Detail -match '开关已开启.*没有 sing-box') 'An enabled switch with a missing core must describe startup failure, not say switched off.'
Reset-TunMock
foreach($case in @('gui','core','missingNic','downNic','wrongNic','noRoute','halfRoute','wrongBest','missingBest','strict','auto','unreadable')) {
    Reset-TunMock
    switch($case) {
        'gui' {$script:guiEnabled=$false}
        'core' {$script:coreRunning=$false}
        'missingNic' {$script:nicPresent=$false}
        'downNic' {$script:nicStatus='Disconnected'}
        'wrongNic' {$script:nicDescription='Tailscale Tunnel'}
        'noRoute' {$script:prefixes=@()}
        'halfRoute' {$script:prefixes=@('0.0.0.0/1')}
        'wrongBest' {$script:bestIndex=18}
        'missingBest' {$script:bestMissing=$true}
        'strict' {$script:strictRoute=$false}
        'auto' {$script:autoRoute=$false}
        'unreadable' {$script:readThrows=$true}
    }
    Assert-Tun (-not (Get-CSExistingTunState $config).Success) "Incomplete or unknown TUN must fail: $case"
}
Reset-TunMock
$script:prefixes=@('0.0.0.0/1','128.0.0.0/1')
Assert-Tun (Get-CSExistingTunState $config).Success 'Both split defaults must count as a complete default route.'
Reset-TunMock
function Test-CSPort($Uri,$Seconds) { return $true }
function Invoke-CSRequest($Config,[string]$Url) {
    $exit=if($script:fakeEgress){$script:fakeEgress}else{$Config.expectedEgressIP}
    $body=if($Url -match 'cdn-cgi/trace') { 'ip='+$exit+"`nloc=US" } elseif($Url -match 'ipify') {$exit} else {''}
    [pscustomobject]@{Success=$true;HttpStatus='200';Body=$body}
}
function Get-DBVerification { [pscustomobject]@{verified=$true;programCount=9;checks=@([pscustomobject]@{program='C:\Mock\Claude.exe'})} }
function Resolve-CSClaude($Config) { 'C:\Mock\Claude.exe' }
function Get-CSLocaleState($Config) { [pscustomobject]@{Success=$true;Detail='mock locale state'} }
$script:leakStarted=0
function Start-CSLeakTask($Config,[string]$Kind){$script:leakStarted++;[pscustomobject]@{Kind=$Kind}}
function Wait-CSLeakTask($Task,[string]$Kind){New-CSLeakResult $(if($Kind -eq 'Dns'){'DNS泄露'}else{'WebRTC泄露'}) 'unknown' 'fixture measurement'}
$script:guiEnabled=$false
$checks=@(Get-CSDirectChecks $config)
$row=@($checks|Where-Object Name -eq 'TUN网卡')
Assert-Tun ($row.Count -eq 1 -and $row[0].Required -and $row[0].Status -eq 'fail') 'Direct-mode checks must include a mandatory failed TUN row.'
Assert-Tun (@($checks|Where-Object {$_.Required -and $_.Name -notin @('TUN网卡','DNS泄露','WebRTC泄露') -and $_.Status -ne 'ok'}).Count -eq 0) 'The ordinary proxy and other preflight checks remain healthy in this regression scenario.'
Assert-Tun ($script:leakStarted -eq 0) 'Required checks must never start or wait for advisory probes.'
Assert-Tun (@($checks|Where-Object {$_.Name -in @('DNS泄露','WebRTC泄露') -and -not $_.Required -and $_.Status -eq 'warn'}).Count -eq 2) 'Both pending observations must be yellow non-blocking reminders.'
$blocked=$false
try { Assert-CSCanLaunch $checks } catch { $blocked=$true }
Assert-Tun $blocked 'Disabled TUN must deny launch even when the proxy, egress and firewall are healthy.'
Reset-TunMock
$script:fakeEgress='203.0.113.11';$script:leakStarted=0
$checks=@(Get-CSDirectChecks $config)
Assert-Tun (@($checks|Where-Object {$_.Name -eq '固定IP' -and $_.Status -eq 'fail'}).Count -eq 1) 'A mismatched exit must still fail the fixed-IP launch check.'
Assert-Tun ($script:leakStarted -eq 0) 'A mismatched exit must return without waiting for a diagnostic probe.'
Reset-TunMock;$script:fakeEgress=$null
$checks=@(Get-CSDirectChecks $config)
Assert-CSCanLaunch $checks
Assert-Tun $true 'Complete required checks must pass while both advisory results are still pending.'
"Passed $script:passed TUN state and regression assertions; no network settings or applications were changed."
