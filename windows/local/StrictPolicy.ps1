# Strict detection supplements. Unknown results fail; raw IP responses are never logged.
function Get-CSProtectedDomains {
    @('claude.ai','claude.com','claude.app','anthropic.com','claudeusercontent.com','claudemcpcontent.com',
      'challenges.cloudflare.com','datadoghq.com','segment.io','stripe.com','stripe.network','stripecdn.com',
      'intercom.io','intercomcdn.com','intercomassets.com')
}

function Test-CSFakeIP([string]$Address) { return $Address -match '^198\.(18|19)\.' }

function Test-CSFixedEgress([string]$First, [string]$Second, $Config) {
    return ($First -eq $Config.expectedEgressIP -and $Second -eq $Config.expectedEgressIP)
}

function Test-CSTun($Config) {
    try {
        $nic = Get-NetAdapter -Name $Config.tunName -ErrorAction Stop
        $routes = @(Get-NetRoute -InterfaceAlias $Config.tunName -AddressFamily IPv4 -ErrorAction Stop)
        $defaultRoutes = @($routes | Where-Object { $_.DestinationPrefix -in @('0.0.0.0/0','0.0.0.0/1','128.0.0.0/1') })
        return ($nic.Status -eq 'Up' -and $defaultRoutes.Count -gt 0)
    } catch { return $false }
}

function Test-CSIPv6Off {
    try {
        $bindings = @(Get-NetAdapterBinding -ComponentID ms_tcpip6 -ErrorAction Stop)
        return ($bindings.Count -gt 0 -and @($bindings | Where-Object Enabled).Count -eq 0)
    } catch { return $false }
}

function Test-CSTime {
    try {
        $status = (& w32tm.exe /query /status 2>$null) -join "`n"
        if ($LASTEXITCODE -ne 0 -or $status -match 'Local CMOS Clock|Free-running System Clock') { return $false }
        $numbers = [regex]::Matches($status, '(?m)^[^\r\n:]+:\s*(\d+)')
        return ($numbers.Count -ge 2 -and [int]$numbers[0].Groups[1].Value -eq 0 -and [int]$numbers[1].Groups[1].Value -ge 1 -and [int]$numbers[1].Groups[1].Value -le 15)
    } catch { return $false }
}

function Get-CSStunAddress([string]$HostName, [int]$Port) {
    $udp = $null
    try {
        $lookup = [Net.Dns]::GetHostAddressesAsync($HostName)
        if (-not $lookup.Wait(1200)) { return $null }
        $address = $lookup.Result | Where-Object { $_.AddressFamily -eq 'InterNetwork' } | Select-Object -First 1
        if (-not $address) { return $null }
        $udp = New-Object Net.Sockets.UdpClient
        $udp.Client.ReceiveTimeout = 1400
        $transaction = New-Object byte[] 12
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($transaction) } finally { $rng.Dispose() }
        $packet = [byte[]](0,1,0,0,0x21,0x12,0xA4,0x42) + $transaction
        $udp.Connect($address,$Port)
        [void]$udp.Send($packet,$packet.Length)
        $remote = New-Object Net.IPEndPoint([Net.IPAddress]::Any,0)
        $response = $udp.Receive([ref]$remote)
        if ($response.Length -lt 20 -or $response[0] -ne 1 -or $response[1] -ne 1) { return $null }
        for ($i=0;$i -lt 4;$i++) { if ($response[$i+4] -ne $packet[$i+4]) { return $null } }
        for ($i=0;$i -lt 12;$i++) { if ($response[$i+8] -ne $transaction[$i]) { return $null } }
        $bodyLength = ([int]$response[2] -shl 8) -bor $response[3]
        if ($bodyLength + 20 -gt $response.Length) { return $null }
        $position = 20
        while ($position + 4 -le 20 + $bodyLength) {
            $type = ([int]$response[$position] -shl 8) -bor $response[$position+1]
            $length = ([int]$response[$position+2] -shl 8) -bor $response[$position+3]
            if ($position + 4 + $length -gt 20 + $bodyLength) { return $null }
            if ($type -in @(0x20,1) -and $length -ge 8 -and $response[$position+5] -eq 1) {
                $bytes = @($response[$position+8],$response[$position+9],$response[$position+10],$response[$position+11])
                if ($type -eq 0x20) { for ($i=0;$i -lt 4;$i++) { $bytes[$i] = $bytes[$i] -bxor $packet[$i+4] } }
                return ($bytes -join '.')
            }
            $position += 4 + $length + ((4 - ($length % 4)) % 4)
        }
    } catch { return $null } finally { if ($udp) { $udp.Dispose() } }
    return $null
}

function Test-CSStun($Config) {
    $received = @()
    foreach ($server in @(@('stun.miwifi.com',3478),@('stun.chat.bilibili.com',3478),@('stun.l.google.com',19302),@('stun.cloudflare.com',3478))) {
        $address = Get-CSStunAddress $server[0] $server[1]
        if ($address) { $received += $address }
    }
    if ($received.Count -eq 0) { return New-CSRow 'WebRTC' 'fail' 'STUN 无有效响应，结果未知，拒绝放行' $true }
    if (@($received | Where-Object { $_ -ne $Config.expectedEgressIP }).Count -gt 0) { return New-CSRow 'WebRTC' 'fail' 'STUN 检测到不在固定出口白名单的地址' $true }
    return New-CSRow 'WebRTC' 'ok' ("$($received.Count) 个 STUN 响应均匹配固定出口；不等同浏览器完整 ICE 审计") $true
}

function Test-CSPinnedRules {
    try {
        $tun = Get-Content -LiteralPath (Join-Path $script:CSRoot 'strict-tun.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $tun.inbounds[0].strict_route -or -not $tun.dns.fakeip.enabled -or $tun.dns.final -ne 'remote') { return $false }
        $pinned = @($tun.route.rules | Where-Object { $_.outbound -eq 'proxy' } | ForEach-Object { $_.domain_suffix })
        foreach ($domain in Get-CSProtectedDomains) { if ($domain -notin $pinned) { return $false } }
        return ($tun.route.rules[0].outbound -eq 'dns-out' -and $tun.dns.servers[0].detour -eq 'proxy')
    } catch { return $false }
}

function Test-CSGuardian($Config) {
    try {
        $health = Get-Content -LiteralPath (Join-Path $script:CSRoot 'guard-health.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        $age = ([DateTime]::UtcNow - [DateTime]::Parse($health.updatedUtc).ToUniversalTime()).TotalSeconds
        $process = Get-Process -Id $health.processId -ErrorAction Stop
        $task = Get-ScheduledTask -TaskName $Config.guardTask -ErrorAction Stop
        return ($age -ge 0 -and $age -lt 60 -and $health.ready -eq $true -and $process.ProcessName -eq 'powershell' -and $task.State -eq 'Running')
    } catch { return $false }
}

function Get-CSStrictChecks($Config, [switch]$ForGuardian) {
    $rows = @()
    $coreUp = [bool](Get-Process -Name 'xray' -ErrorAction SilentlyContinue)
    $rows += if ($coreUp) { New-CSRow '代理内核' 'ok' '现有 xray 内核正在运行' $true } else { New-CSRow '代理内核' 'fail' '代理内核未运行' $true }
    $portUp = Test-CSPort ([uri]$Config.proxyUrl) $Config.connectTimeoutSeconds
    $rows += if ($portUp) { New-CSRow '本地代理' 'ok' $Config.proxyUrl $true } else { New-CSRow '本地代理' 'fail' '代理端口不响应' $true }
    $tunUp = Test-CSTun $Config
    $rows += if ($tunUp) { New-CSRow 'TUN网卡' 'ok' '专用 TUN 网卡及路由在线' $true } else { New-CSRow 'TUN网卡' 'fail' 'TUN 网卡或路由缺失' $true }

    $country = ''; $first = ''; $second = ''
    if ($portUp) {
        $trace = Invoke-CSRequest $Config 'https://www.cloudflare.com/cdn-cgi/trace'
        if ($trace.Success -and $trace.HttpStatus -eq '200') {
            if ($trace.Body -match '(?m)^loc=([A-Z]{2})\s*$') { $country = $Matches[1] }
            if ($trace.Body -match '(?m)^ip=([^\r\n]+)') { $first = $Matches[1].Trim() }
        }
        $ipify = Invoke-CSRequest $Config 'https://api.ipify.org'
        if ($ipify.Success -and $ipify.HttpStatus -eq '200') { $second = $ipify.Body.Trim() }
    }
    $rows += if ($country -eq $Config.requiredCountry) { New-CSRow '代理出口' 'ok' "国家：$country" $true } else { New-CSRow '代理出口' 'fail' '出口国家未知或不匹配' $true }
    $rows += if (Test-CSFixedEgress $first $second $Config) { New-CSRow '固定IP' 'ok' '两个接口均与完整固定地址一致；不会自动学习新地址' $true } else { New-CSRow '固定IP' 'fail' '出口未知、两接口不一致或不在固定地址白名单' $true }

    $timeOk = ((Get-TimeZone).Id -eq $Config.expectedTimeZone -and (Test-CSTime))
    $rows += if ($timeOk) { New-CSRow '时区' 'ok' '新加坡 UTC+8；系统网络校时已同步' $true } else { New-CSRow '时区' 'fail' '时区不符或网络校时未同步' $true }
    $cultureOk = ((Get-Culture).Name -eq $Config.expectedCulture -and (Get-WinSystemLocale).Name -eq $Config.expectedCulture -and (Get-UICulture).TwoLetterISOLanguageName -eq 'zh')
    $rows += if ($cultureOk) { New-CSRow '地区语言' 'ok' '中文（新加坡）地区格式，中文界面' $true } else { New-CSRow '地区语言' 'fail' '地区格式、系统区域或界面语言不符合配置' $true }
    $rows += if (Test-CSIPv6Off) { New-CSRow 'IPv6' 'ok' '所有已发现网卡的 IPv6 绑定已关闭' $true } else { New-CSRow 'IPv6' 'fail' '仍有 IPv6 网卡绑定开启或无法读取状态' $true }

    $dnsOk = $false
    if ($tunUp) {
        try {
            $addresses = @(Resolve-DnsName 'claude.ai' -Type A -Server $Config.tunGateway -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop | Where-Object IPAddress | Select-Object -ExpandProperty IPAddress)
            $dnsOk = ($addresses.Count -gt 0 -and @($addresses | Where-Object { -not (Test-CSFakeIP $_) }).Count -eq 0 -and (Test-CSPinnedRules))
        } catch { $dnsOk = $false }
    }
    $rows += if ($dnsOk) { New-CSRow 'DNS隧道' 'ok' '受保护域名返回 Fake-IP；严格路由及代理加密 DNS 已配置' $true } else { New-CSRow 'DNS隧道' 'fail' 'Fake-IP、DNS 路由或配置验证未通过' $true }
    $rows += if ($tunUp -and $dnsOk) { Test-CSStun $Config } else { New-CSRow 'WebRTC' 'fail' 'TUN/DNS 未通过，未运行外网 STUN 探针' $true }
    $guardUp = $ForGuardian -or (Test-CSGuardian $Config)
    $rulesUp = @(Get-NetFirewallRule -Group 'ClaudeStrictLocal' -Enabled True -ErrorAction SilentlyContinue).Count -gt 0
    $rows += if ($guardUp -and $rulesUp) { New-CSRow '保镖' 'ok' '监测任务在线；专用 Claude 程序的直连防火墙规则已安装' $true } else { New-CSRow '保镖' 'fail' '监测任务或防火墙规则未就绪' $true }
    $rows += if (Test-CSPinnedRules) { New-CSRow '规则置顶' 'ok' 'Claude 及验证、支付、支持域名固定走代理' $true } else { New-CSRow '规则置顶' 'fail' '专用规则未配置或漂移' $true }
    $rows += if ($Config.clientLanguage -eq $Config.expectedCulture) { New-CSRow '客户端语言' 'ok' '本工具启动时指定中文（新加坡）' $true } else { New-CSRow '客户端语言' 'fail' '客户端语言配置不匹配' $true }
    $rows += New-CSRow 'ASN属性' 'info' '固定出口属性仅供参考，不以机房/住宅标签判定封号风险'

    if ($portUp) {
        $api = Invoke-CSRequest $Config 'https://api.anthropic.com/v1/models'
        $rows += if ($api.Success -and $api.HttpStatus -in @('200','401')) { New-CSRow 'API 连接' 'ok' "HTTP $($api.HttpStatus)，仅验证连接，未使用凭据" $true } else { New-CSRow 'API 连接' 'fail' "HTTP $($api.HttpStatus)，API 连接未通过" $true }
        $web = Invoke-CSRequest $Config 'https://claude.ai/'
        $rows += if ($web.Success -and [int]$web.HttpStatus -ge 200 -and [int]$web.HttpStatus -lt 400) { New-CSRow '网页连接' 'ok' "HTTP $($web.HttpStatus)" } elseif ($web.Success) { New-CSRow '网页连接' 'warn' "HTTP $($web.HttpStatus)，需要在应用中确认验证或拒绝原因" } else { New-CSRow '网页连接' 'fail' '网页连接失败' $true }
    } else {
        $rows += New-CSRow 'API 连接' 'fail' '本地代理不可用' $true
        $rows += New-CSRow '网页连接' 'fail' '本地代理不可用' $true
    }
    $rows += if (Resolve-CSClaude $Config) { New-CSRow 'Claude 安装' 'ok' '已识别商店版或普通桌面版' $true } else { New-CSRow 'Claude 安装' 'fail' '未找到桌面端' $true }
    if (-not $ForGuardian) {
        $rows += if (Get-Process -Name 'Claude' -ErrorAction SilentlyContinue) { New-CSRow '启动状态' 'fail' 'Claude 已运行，请先完全退出再从本工具启动' $true } else { New-CSRow '启动状态' 'ok' '可创建新进程' $true }
    }
    $rows += New-CSRow '保护边界' 'info' '后台检测有时间间隔；通用工具和 WSL 不继承按程序路径的防火墙规则'
    return $rows
}

function Stop-CSClaudeTree {
    # Enumerate ancestry once; never stop unrelated PowerShell, Codex, Tailscale or WSL sessions.
    $all = @(Get-CimInstance Win32_Process -ErrorAction Stop | Select-Object ProcessId,ParentProcessId,Name,CreationDate)
    $roots = @($all | Where-Object { $_.Name -in @('Claude.exe','claude-code.exe') })
    $ids = New-Object 'Collections.Generic.HashSet[uint32]'
    foreach ($root in $roots) { [void]$ids.Add([uint32]$root.ProcessId) }
    do {
        $added = $false
        foreach ($process in $all) {
            if ($ids.Contains([uint32]$process.ParentProcessId) -and -not $ids.Contains([uint32]$process.ProcessId)) { [void]$ids.Add([uint32]$process.ProcessId); $added=$true }
        }
    } while ($added)
    foreach ($process in @($all | Where-Object { $ids.Contains([uint32]$_.ProcessId) } | Sort-Object CreationDate -Descending)) {
        $live = Get-CimInstance Win32_Process -Filter ("ProcessId=" + $process.ProcessId) -ErrorAction SilentlyContinue
        if ($live -and $live.CreationDate -eq $process.CreationDate -and $live.ProcessId -ne $PID) {
            Stop-Process -Id $live.ProcessId -Force -ErrorAction SilentlyContinue
        }
    }
    return $ids.Count
}
