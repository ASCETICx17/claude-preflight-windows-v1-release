param(
    [ValidateSet('Check', 'Launch', 'Repair', 'LeakTest', 'ObserveNetwork', 'QualityCheck')][string]$Action = 'Check',
    [string]$QualityTarget,
    [string]$RepairOperationId,
    [switch]$Json
)

# Local compatibility mode: no account snapshots, system changes, or background daemon.
$ProgressPreference='SilentlyContinue'
$script:CSRoot = $PSScriptRoot
. (Join-Path $PSScriptRoot 'Configuration.ps1')
. (Join-Path $PSScriptRoot '..\direct\RepairLifecycle.ps1')
. (Join-Path $PSScriptRoot 'NetworkRequests.ps1')
. (Join-Path $PSScriptRoot 'LeakChecks.ps1')
. (Join-Path $PSScriptRoot 'IpQuality.ps1')
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'StrictPolicy.ps1')) {
    . (Join-Path $PSScriptRoot 'StrictPolicy.ps1')
}
if (Test-Path -LiteralPath (Join-Path $PSScriptRoot '..\direct\DirectChecks.ps1')) {
    . (Join-Path $PSScriptRoot '..\direct\DirectChecks.ps1')
}

function New-CSRow([string]$Name, [string]$Status, [string]$Detail, [bool]$Required = $false) {
    [pscustomobject]@{ Name = $Name; Status = $Status; Detail = $Detail; Required = $Required }
}

function Test-CSPort([uri]$Uri, [int]$Seconds) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($Uri.Host, $Uri.Port)
        if (-not $task.Wait($Seconds * 1000)) { return $false }
        return $client.Connected
    } catch { return $false } finally { $client.Dispose() }
}

function Invoke-CSRequest($Config, [string]$Url) {
    $responses=Invoke-CSRequestBatch $Config @($Url)
    return $responses[$Url]
}

function Resolve-CSClaude($Config) {
    $package = Get-AppxPackage -Name $Config.appPackageName -ErrorAction SilentlyContinue | Sort-Object -Property @{Expression={[version]$_.Version}} -Descending | Select-Object -First 1
    if ($package) {
        $candidate = Join-Path $package.InstallLocation 'app\Claude.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    foreach ($candidate in @(
        (Join-Path $env:LOCALAPPDATA 'AnthropicClaude\Claude.exe'),
        (Join-Path $env:LOCALAPPDATA 'Programs\Claude\Claude.exe')
    )) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

function Get-CSChecks($Config) {
    if ($Config.protectionMode -eq 'DirectBlock') { return @(Get-CSDirectChecks $Config) }
    if ($Config.strictMode) { return @(Get-CSStrictChecks $Config) }
    $rows = @()
    $core = Get-Process -Name 'xray', 'sing-box' -ErrorAction SilentlyContinue
    if ($core) { $rows += New-CSRow '代理内核' 'ok' '检测到现有代理内核' $true }
    else { $rows += New-CSRow '代理内核' 'fail' '请先启动 v2rayN' $true }

    $portUp = Test-CSPort ([uri]$Config.proxyUrl) $Config.connectTimeoutSeconds
    if ($portUp) { $rows += New-CSRow '本地代理' 'ok' $Config.proxyUrl $true }
    else { $rows += New-CSRow '本地代理' 'fail' '代理端口未响应' $true }

    if ($portUp) {
        $trace = Invoke-CSRequest $Config 'https://www.cloudflare.com/cdn-cgi/trace'
        $country = ''
        if ($trace.Success -and $trace.HttpStatus -eq '200' -and $trace.Body -match '(?m)^loc=([A-Z]{2})\s*$') { $country = $Matches[1] }
        if ($country -eq $Config.requiredCountry) { $rows += New-CSRow '代理出口' 'ok' "国家：$country；完整地址不写入日志" $true }
        elseif ($country) { $rows += New-CSRow '代理出口' 'fail' "国家：$country；当前配置要求 $($Config.requiredCountry)" $true }
        else { $rows += New-CSRow '代理出口' 'fail' '无法确认代理出口国家' $true }

        $api = Invoke-CSRequest $Config 'https://api.anthropic.com/v1/models'
        if ($api.Success -and $api.HttpStatus -in @('200', '401')) {
            $rows += New-CSRow 'API 连接' 'ok' "HTTP $($api.HttpStatus)；仅验证连接，未使用登录凭据" $true
        } else {
            $rows += New-CSRow 'API 连接' 'fail' "HTTP $($api.HttpStatus)；代理到 API 的连接未通过" $true
        }

        $web = Invoke-CSRequest $Config 'https://claude.ai/'
        if ($web.Success -and [int]$web.HttpStatus -ge 200 -and [int]$web.HttpStatus -lt 400) {
            $rows += New-CSRow '网页连接' 'ok' "HTTP $($web.HttpStatus)；登录后的可用性仍需在应用里确认"
        } elseif ($web.Success) {
            $rows += New-CSRow '网页连接' 'warn' "HTTP $($web.HttpStatus)；可能需要浏览器验证，不能认定可正常使用"
        } else { $rows += New-CSRow '网页连接' 'fail' '网页连接超时或失败' $true }
    } else {
        $rows += New-CSRow '代理出口' 'fail' '代理端口不可用，未进行请求' $true
        $rows += New-CSRow 'API 连接' 'fail' '代理端口不可用，未进行请求' $true
        $rows += New-CSRow '网页连接' 'warn' '代理端口不可用，未进行请求'
    }

    if (Resolve-CSClaude $Config) { $rows += New-CSRow 'Claude 安装' 'ok' '已识别桌面端安装位置（支持商店版）' $true }
    else { $rows += New-CSRow 'Claude 安装' 'fail' '未找到 Claude 桌面端' $true }

    if (Get-Process -Name 'Claude' -ErrorAction SilentlyContinue) {
        $rows += New-CSRow '启动状态' 'fail' '请先从托盘完全退出 Claude，再通过此工具启动' $true
    } else { $rows += New-CSRow '启动状态' 'ok' '可创建采用代理参数的新进程' $true }

    $rows += New-CSRow '系统设置' 'info' ("保留时区：" + (Get-TimeZone).Id + '；不修改地区或 IPv6')
    $rows += New-CSRow '保护范围' 'info' '仅做启动前连接检查；没有防火墙级断连保护'
    return $rows
}

function Assert-CSCanLaunch($Checks) {
    if (@($Checks).Count -lt 9) { throw '检查结果不完整，已阻止启动。' }
    $expected = @('代理内核', '本地代理', '代理出口', 'API 连接', 'Claude 安装', '启动状态')
    $guardConfig = Get-CSConfig
    if ($guardConfig.protectionMode -eq 'DirectBlock') { $expected += @('TUN网卡','固定IP','防直连规则','时区与语言') }
    elseif ($guardConfig.strictMode) { $expected += @('TUN网卡', '固定IP', '时区', '地区语言', 'IPv6', 'DNS隧道', 'WebRTC', '保镖', '规则置顶', '客户端语言') }
    foreach ($name in $expected) {
        $row = @($Checks | Where-Object { $_.Name -eq $name })
        if ($row.Count -ne 1 -or $row[0].Status -ne 'ok' -or -not $row[0].Required) { throw "检查未通过，已阻止启动：$name" }
    }
    if (@($Checks | Where-Object { $_.Required -and $_.Status -ne 'ok' }).Count -gt 0) { throw '必要检查未通过，已阻止启动。' }
}

function Invoke-CSLaunch($Config, $Checks) {
    Assert-CSCanLaunch $Checks
    $exe = Resolve-CSClaude $Config
    if (-not $exe) { throw '未找到 Claude，已阻止启动。' }
    if ($Config.protectionMode -eq 'DirectBlock') {
        $liveVerification=Get-DBVerification
        if (-not $liveVerification.verified -or $exe -notin @($liveVerification.checks | Select-Object -ExpandProperty program)) { throw '当前程序路径的防直连规则未生效或已漂移，拒绝启动。' }
    }
    # Recheck immediately before starting. Never close an existing session automatically.
    if (Get-Process -Name 'Claude' -ErrorAction SilentlyContinue) { throw 'Claude 已在运行，请先从托盘完全退出。' }
    if (-not (Test-CSPort ([uri]$Config.proxyUrl) $Config.connectTimeoutSeconds)) { throw '代理端口已断开，已阻止启动。' }
    if ($Config.protectionMode -eq 'DirectBlock') {
        $liveTun=Get-CSExistingTunState $Config
        if(-not $liveTun.Success) { throw ('启动前 TUN 复核失败，已阻止启动：'+$liveTun.Detail) }
        $liveLocale=Get-CSLocaleState $Config
        if(-not $liveLocale.Success) { throw ('× 拒绝连接：'+$liveLocale.Detail) }
    }

    # Temporary environment belongs to this launcher and its child, not the user/system.
    $variables = @{
        HTTP_PROXY = $Config.proxyUrl
        HTTPS_PROXY = $Config.proxyUrl
        NO_PROXY = 'localhost,127.0.0.1,::1'
    }
    $saved = @{}
    try {
        foreach ($name in $variables.Keys) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            [Environment]::SetEnvironmentVariable($name, $variables[$name], 'Process')
        }
        $launchArguments = @("--proxy-server=$($Config.proxyUrl)")
        if ($Config.clientLanguage) { $launchArguments += "--lang=$($Config.clientLanguage)" }
        Start-Process -FilePath $exe -ArgumentList $launchArguments -ErrorAction Stop | Out-Null
    } finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process') }
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

try {
    $configurationLoaded=$false
    [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $config = if($Action -in @('ObserveNetwork','LeakTest')){Get-CSConfig -AllowIncomplete}else{Get-CSConfig}
    if($Action -in @('ObserveNetwork','LeakTest')){$proxyIssue=Get-CSProxyIssue $config;if($proxyIssue){throw $proxyIssue}}
    $configurationLoaded=$true
    if($Action -eq 'QualityCheck'){
        $report=Invoke-CSQualityCheck $config $QualityTarget
        $result=[pscustomobject]@{Success=$true;CanLaunch=$false;NeedsRuleRefresh=$false;Action=$Action;Message='IP 质量查询已完成；此结果不参与启动放行。';Checks=@();QualityReport=$report}
        $result|ConvertTo-Json -Depth 7 -Compress
        return
    }
    if($Action -eq 'Repair') {
        if(Get-Process -Name 'Claude','cowork-svc' -ErrorAction SilentlyContinue) { throw '请先保存工作并完全退出 Claude / Cowork，再更新保护规则；不会强制结束会话。' }
        if(-not $RepairOperationId){$RepairOperationId=[guid]::NewGuid().ToString('D')}
        $null=Invoke-CSRepair 'Apply' $RepairOperationId
    }
    $script:CSLastLeakDiagnostics=$null
    $checks = if($Action -in @('ObserveNetwork','LeakTest')){@(Get-CSLeakObservation $config)}else{@(Get-CSChecks $config)}
    $canLaunch = $true
    try { Assert-CSCanLaunch $checks } catch { $canLaunch = $false }
    $message = if ($canLaunch) { '必要检查已通过，可以启动。' } else { '× 拒绝连接：请先修复下方未通过项。' }
    if($Action -eq 'LeakTest'){$message='DNS / WebRTC 检测已完成；异常或无法确认仅作黄色提醒，不影响启动条件。'}
    if($Action -eq 'ObserveNetwork'){$canLaunch=$false;$message='当前网络观测已完成，仅用于排查；不会启动 Claude，也不修改固定 IP。'} 
    if($Action -eq 'Repair') { $message='已完成规则更新并重新检查。'+$message }
    if ($Action -eq 'Launch') {
        Invoke-CSLaunch $config $checks
        $message = '已向 Claude 传入代理参数并启动；请在聊天页和 Code 页分别确认实际可用性。'
    }
    $needsRefresh=(@($checks|Where-Object {$_.Name -eq '防直连规则' -and $_.Status -ne 'ok'}).Count -gt 0)
    $result = [pscustomobject]@{ Success = $true; CanLaunch = $canLaunch; NeedsRuleRefresh=$needsRefresh; Action = $Action; Message = $message; Checks = $checks; LeakDiagnostics=$script:CSLastLeakDiagnostics }
    if ($Json) { $result | ConvertTo-Json -Depth 7 -Compress } else { $result | ConvertTo-Json -Depth 7 }
} catch {
    $result = [pscustomobject]@{ Success = $false; CanLaunch = $false; ConfigRequired=(-not $configurationLoaded); Action = $Action; Message = (Protect-CSMessage $_.Exception.Message); Checks = @() }
    $result | ConvertTo-Json -Depth 5 -Compress
    exit 1
}
