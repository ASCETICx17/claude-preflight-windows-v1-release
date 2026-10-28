param([ValidateSet('Prepare','Apply','Verify','Remove')][string]$Operation='Verify')
if($MyInvocation.InvocationName -ne '.') { $ErrorActionPreference='Stop' }
$script:DBRoot=$PSScriptRoot
$script:DBGroup='ClaudeNoDirect-v1'
. (Join-Path $PSScriptRoot '..\local\Configuration.ps1')
$script:DBV4=@('0.0.0.0-126.255.255.255','128.0.0.0-255.255.255.255')
$script:DBV6=@('::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff')
. (Join-Path $PSScriptRoot 'ProgramDiscovery.ps1')

function Write-DBJson($Value,[string]$Name) {
    [IO.File]::WriteAllText((Join-Path $script:DBRoot $Name),($Value|ConvertTo-Json -Depth 8),(New-Object Text.UTF8Encoding($false)))
}
function Get-DBPolicy {
    return (Get-CSConfig)
}
function Get-DBPrograms {
    # Discovered paths stay in memory. No secondary personal inventory is written.
    return @((Get-DBDiscovery).Programs)
}
function Get-DBRuleName([string]$Program,[string]$Family) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try { $id=[BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Program.ToLowerInvariant()))).Replace('-','').Substring(0,16) } finally { $sha.Dispose() }
    return "ClaudeNoDirect-v1-$id-$Family"
}
function Convert-DBAddress([string]$Value) {
    if($Value -match '-') { return ((($Value -split '-')|ForEach-Object {[Net.IPAddress]::Parse($_).ToString()}) -join '-') }
    return $Value.ToLowerInvariant()
}
function Test-DBRule([string]$Program,[string]$Family,$Rule) {
    $name=Get-DBRuleName $Program $Family
    $rule=if($PSBoundParameters.ContainsKey('Rule')){$Rule}else{Get-NetFirewallRule -Name $name -PolicyStore ActiveStore -ErrorAction SilentlyContinue}
    $rule=@($rule|Where-Object {$_})
    if($rule.Count -ne 1){return $false}
    $rule=$rule[0]
    if($PSBoundParameters.ContainsKey('Rule') -and $rule.Name -ne $name){return $false}
    if(-not $rule -or $rule.Group -ne $script:DBGroup -or $rule.Enabled -ne 'True' -or $rule.Direction -ne 'Outbound' -or $rule.Action -ne 'Block' -or [string]$rule.Profile -ne 'Any') { return $false }
    $app=$rule|Get-NetFirewallApplicationFilter
    $port=$rule|Get-NetFirewallPortFilter
    if($app.Program -ne $Program -or [string]$port.Protocol -ne 'Any' -or [string]$port.RemotePort -ne 'Any') { return $false }
    $wanted=if($Family -eq 'IPv4') {$script:DBV4} else {$script:DBV6}
    $actual=@(($rule|Get-NetFirewallAddressFilter).RemoteAddress|ForEach-Object {Convert-DBAddress $_}|Sort-Object)
    $expected=@($wanted|ForEach-Object {Convert-DBAddress $_}|Sort-Object)
    return (($actual -join '|') -eq ($expected -join '|'))
}
function Add-DBRules([string]$Program) {
    foreach($family in @('IPv4','IPv6')) {
        if(Get-Command Update-CSRepairPhase -ErrorAction SilentlyContinue){Update-CSRepairPhase 'applying'}
        $name=Get-DBRuleName $Program $family
        if(-not(Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue)) {
            $addresses=if($family -eq 'IPv4') {$script:DBV4} else {$script:DBV6}
            New-NetFirewallRule -Name $name -DisplayName "Claude: deny non-loopback $family" -Group $script:DBGroup -Description 'Only this executable is restricted. No adapter, global profile, proxy or time settings are changed.' `
                -Direction Outbound -Action Block -Enabled True -Profile Any -Program $Program -Protocol Any -RemoteAddress $addresses | Out-Null
        }
        if(-not(Test-DBRule $Program $family)) { throw "生效策略中的 $family 规则校验失败。" }
    }
}
function Get-DBVerification {
    $discovery=Get-DBDiscovery
    $programs=@($discovery.Programs)
    $names=@(foreach($program in $programs){Get-DBRuleName $program 'IPv4';Get-DBRuleName $program 'IPv6'})
    $ruleSet=Get-DBRuleSet $names
    $checks=@()
    foreach($program in $programs) {
        $checks+=[pscustomobject]@{program=$program;ipv4=(Test-DBRule $program 'IPv4' -Rule $ruleSet[(Get-DBRuleName $program 'IPv4')]);ipv6=(Test-DBRule $program 'IPv6' -Rule $ruleSet[(Get-DBRuleName $program 'IPv6')])}
    }
    $servicesUp=(@(Get-Service BFE,MpsSvc|Where-Object {$_.Status -ne 'Running'}).Count -eq 0)
    $profilesUp=(@(Get-NetFirewallProfile|Where-Object {$_.Enabled -ne 'True'}).Count -eq 0)
    $missing=@($checks|Where-Object {-not $_.ipv4 -or -not $_.ipv6}).Count
    [pscustomobject]@{verified=($servicesUp -and $profilesUp -and $missing -eq 0);programCount=$programs.Count;missingProgramCount=$missing;packageVersion=$discovery.PackageVersion;fingerprint=$discovery.Fingerprint;servicesRunning=$servicesUp;profilesEnabled=$profilesUp;checks=$checks}
}
function Get-DBRuleSet([string[]]$Names) {
    # One fresh ActiveStore query per verification; never reuse across checks.
    $set=@{}
    foreach($rule in @(Get-NetFirewallRule -Name $Names -PolicyStore ActiveStore -ErrorAction SilentlyContinue)){
        if($rule -and $rule.Name -in $Names){$set[$rule.Name]=@($set[$rule.Name]|Where-Object {$_})+@($rule)}
    }
    return $set
}
function Invoke-DBCurl([string]$Executable,[string]$Mode,[string]$Url,$Config) {
    $arguments=@('--silent','--connect-timeout','3','--max-time','6','--output','NUL','--write-out',"%{http_code}|%{time_connect}")
    if($Mode -eq 'Proxy') { $arguments+=@('--proxy',$Config.proxyUrl,'--noproxy','localhost,127.0.0.1') }
    elseif($Mode -eq 'DeadProxy') { $arguments+=@('--proxy','http://127.0.0.1:1','--noproxy','localhost,127.0.0.1') }
    else { $arguments+=@('--noproxy','*') }
    $start=New-Object Diagnostics.ProcessStartInfo
    $start.FileName=$Executable
    $quoted=@()
    foreach($argument in @($arguments)+@($Url)) {
        if($argument -match '["\r\n]') { throw '测试参数包含非法字符。' }
        $quoted+='"'+$argument+'"'
    }
    $start.Arguments=$quoted -join ' '
    $start.UseShellExecute=$false
    $start.CreateNoWindow=$true
    $start.RedirectStandardInput=$true
    $start.RedirectStandardOutput=$true
    $start.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$start
    $timedOut=$false
    try {
        [void]$process.Start()
        # Close TELNET input so an elevated hidden console cannot wait for typing.
        $process.StandardInput.Close()
        $outputTask=$process.StandardOutput.ReadToEndAsync()
        $errorTask=$process.StandardError.ReadToEndAsync()
        if(-not $process.WaitForExit(9000)) {
            $timedOut=$true
            $process.Kill()
            if(-not $process.WaitForExit(2000)) { throw '测试程序未能在强制超时后退出。' }
        }
        $raw=$outputTask.GetAwaiter().GetResult()
        [void]$errorTask.GetAwaiter().GetResult()
        $exit=$process.ExitCode
    } finally { $process.Dispose() }
    $parts=($raw -join '') -split '\|'
    $connect=0.0
    if($parts.Count -eq 2) { [void][double]::TryParse($parts[1],[Globalization.NumberStyles]::Float,[Globalization.CultureInfo]::InvariantCulture,[ref]$connect) }
    [pscustomobject]@{exit=$exit;http=$parts[0];connected=($connect -gt 0);timedOut=$timedOut}
}
function Test-DBNetwork($Config) {
    $systemCurl=Join-Path $env:SystemRoot 'System32\curl.exe'
    $probe=Join-Path $script:DBRoot 'probe\blocked-curl.exe'
    if(-not(Test-Path -LiteralPath $probe)) { throw '测试程序未准备。' }
    if((Get-FileHash -LiteralPath $probe).Hash -ne (Get-FileHash -LiteralPath $systemCurl).Hash) { throw '测试程序与系统 curl 不一致。' }
    $control=Invoke-DBCurl $probe 'Direct' 'telnet://1.1.1.1:443' $Config
    if($control.timedOut -or -not $control.connected) { throw '直连测试的未阻断对照未建立连接，不能把天然不可达当作阻断成功。' }
    $v6Control=Invoke-DBCurl $probe 'Direct' 'telnet://[2606:4700:4700::1111]:443' $Config
    try {
        Add-DBRules $probe
        $blocked=Invoke-DBCurl $probe 'Direct' 'telnet://1.1.1.1:443' $Config
        $v6Blocked=Invoke-DBCurl $probe 'Direct' 'telnet://[2606:4700:4700::1111]:443' $Config
        $proxied=Invoke-DBCurl $probe 'Proxy' 'https://www.cloudflare.com/cdn-cgi/trace' $Config
        $dead=Invoke-DBCurl $probe 'DeadProxy' 'https://www.cloudflare.com/cdn-cgi/trace' $Config
        $anyTimeout=($blocked.timedOut -or $v6Control.timedOut -or $v6Blocked.timedOut -or $proxied.timedOut -or $dead.timedOut)
        $success=(-not $anyTimeout -and -not $blocked.connected -and $proxied.exit -eq 0 -and $proxied.http -eq '200' -and $dead.exit -ne 0)
        if($v6Control.connected -and $v6Blocked.connected) { $success=$false }
        [pscustomobject]@{passed=$success;ipv4ControlConnected=$control.connected;ipv4Blocked=(-not $blocked.connected);loopbackProxyWorks=($proxied.exit -eq 0 -and $proxied.http -eq '200');deadProxyFailed=($dead.exit -ne 0);ipv6ControlAvailable=$v6Control.connected;ipv6BlockedWhenControlAvailable=($v6Control.connected -and -not $v6Blocked.connected);udp='Covered by Protocol Any rules; not independently packet-tested.'}
    } finally {
        foreach($family in @('IPv4','IPv6')) { Get-NetFirewallRule -Name (Get-DBRuleName $probe $family) -ErrorAction SilentlyContinue|Remove-NetFirewallRule }
    }
}
function Invoke-DBApply {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if(-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '防火墙应用需要 Windows 管理员授权。' }
    $config=Get-DBPolicy
    if(-not $config.ownerSid -or $config.ownerSid -ne [Security.Principal.WindowsIdentity]::GetCurrent().User.Value) { throw '请先在设置页保存配置，并使用同一 Windows 账号的管理员授权。' }
    if(Get-Command Update-CSRepairPhase -ErrorAction SilentlyContinue){Update-CSRepairPhase 'discovering'}
    $discovery=Get-DBDiscovery
    $programs=@($discovery.Programs)
    if(@(Get-CimInstance Win32_Process|Where-Object {$_.ExecutablePath -in $programs}).Count -gt 0) { throw '请先保存工作并完全退出 Claude / Cowork，再更新保护规则；本次不会强制结束会话。' }
    $probeDir=Join-Path $script:DBRoot 'probe'
    New-Item -ItemType Directory -Path $probeDir -Force|Out-Null
    Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\curl.exe') -Destination (Join-Path $probeDir 'blocked-curl.exe') -Force
    $beforeIPv6=@(Get-NetAdapterBinding -ComponentID ms_tcpip6|Select-Object Name,Enabled)
    $beforeProfiles=@(Get-NetFirewallProfile|Select-Object Name,Enabled,DefaultOutboundAction)
    if(Get-Command Update-CSRepairPhase -ErrorAction SilentlyContinue){Update-CSRepairPhase 'network-test'}
    $test=Test-DBNetwork $config
    Write-DBJson $test 'network-test.json'
    if(-not $test.passed) { throw '真实网络阻断测试未通过，未应用 Claude 正式规则。' }
    $created=New-Object 'Collections.Generic.List[string]'
    try {
        foreach($program in $programs) {
            foreach($family in @('IPv4','IPv6')) {
                $name=Get-DBRuleName $program $family
                if(-not(Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue)) { $created.Add($name) }
            }
            Add-DBRules $program
        }
        if(Get-Command Update-CSRepairPhase -ErrorAction SilentlyContinue){Update-CSRepairPhase 'verifying'}
        $verification=Get-DBVerification
        if(-not $verification.verified -or $verification.fingerprint -ne $discovery.Fingerprint) { throw '当前版本在应用期间变化，或正式规则未全部生效；拒绝放行，请重新更新规则。' }
        $afterIPv6=@(Get-NetAdapterBinding -ComponentID ms_tcpip6|Select-Object Name,Enabled)
        $afterProfiles=@(Get-NetFirewallProfile|Select-Object Name,Enabled,DefaultOutboundAction)
        $unchanged=(($beforeIPv6|ConvertTo-Json -Compress) -eq ($afterIPv6|ConvertTo-Json -Compress) -and ($beforeProfiles|ConvertTo-Json -Compress) -eq ($afterProfiles|ConvertTo-Json -Compress))
        if(-not $unchanged) { throw '检测到网卡或防火墙默认配置变化，需复核。' }
        $result=[pscustomobject]@{applied=$true;verified=$true;packageVersion=$discovery.PackageVersion;programCount=$programs.Count;ruleCount=($programs.Count*2);olderRulesRetained=$true;systemSettingsUnchanged=$unchanged;networkTest=$test;updatedUtc=[DateTime]::UtcNow.ToString('o');scope='Signed dedicated Windows executables; discovered paths remain in memory.'}
        if(Get-Command Update-CSRepairPhase -ErrorAction SilentlyContinue){Update-CSRepairPhase 'verifying'}
        Write-DBJson $result 'status.json'
        return $result
    } catch {
        foreach($name in $created) { Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue|Remove-NetFirewallRule -ErrorAction SilentlyContinue }
        throw
    }
}

if($MyInvocation.InvocationName -eq '.') { return }
try {
    switch($Operation) {
        'Prepare' {
            [void](Get-DBPolicy); $programs=@(Get-DBPrograms)
            $probeDir=Join-Path $script:DBRoot 'probe'
            New-Item -ItemType Directory -Path $probeDir -Force|Out-Null
            Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\curl.exe') -Destination (Join-Path $probeDir 'blocked-curl.exe') -Force
            [pscustomobject]@{prepared=$true;programCount=$programs.Count}|ConvertTo-Json
        }
        'Apply' { Invoke-DBApply|ConvertTo-Json -Depth 8 }
        'Verify' { Get-DBVerification|Select-Object verified,programCount,missingProgramCount,packageVersion,servicesRunning,profilesEnabled|ConvertTo-Json }
        'Remove' {
            Get-NetFirewallRule -Group $script:DBGroup -ErrorAction SilentlyContinue|Remove-NetFirewallRule
            Write-DBJson ([pscustomobject]@{applied=$false;removed=$true;updatedUtc=[DateTime]::UtcNow.ToString('o')}) 'status.json'
            'Removed only ClaudeNoDirect-v1 rules.'
        }
    }
} catch {
    $friendly=Protect-CSMessage $_.Exception.Message
    if($Operation -eq 'Apply') { Write-DBJson ([pscustomobject]@{applied=$false;verified=$false;error='保护规则未完成应用，请在界面重新检查。';updatedUtc=[DateTime]::UtcNow.ToString('o')}) 'status.json' }
    Write-Error $friendly
    exit 1
}
