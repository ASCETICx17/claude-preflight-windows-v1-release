. (Join-Path $PSScriptRoot 'DirectBlock.ps1')

. (Join-Path $PSScriptRoot 'TunLocation.ps1')

function Get-CSExistingTunState($Config) {
    $location=$null
    try {
        if(-not $Config.proxyRoot -or -not $Config.existingTunName -or $Config.existingTunName -match '[*?\[\]]') { throw '现有 TUN 的配置路径或网卡名称未配置。' }
        $location=Resolve-CSTunDataLocation $Config
        $dataRoot=$location.Root
        $guiPath=Join-Path $dataRoot 'guiConfigs\guiNConfig.json'
        if(-not(Test-Path -LiteralPath $guiPath -PathType Leaf)){throw '找不到 v2rayN 主配置 guiConfigs/guiNConfig.json；请重选包含该文件夹的数据目录，不能据此判定 TUN 已关闭。'}
        $gui=Get-Content -LiteralPath $guiPath -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
        $switchEnabled=($gui.TunModeItem.EnableTun -eq $true)
        if(-not $switchEnabled){throw '当前识别到的 v2rayN 配置中 TUN 开关为关闭；请核对正在使用的实例。'}
        $generatedPath=@('binConfigs\configPre.json','guiConfigs\configPre.json'|ForEach-Object {Join-Path $dataRoot $_}|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf}|Select-Object -First 1)
        if(-not $generatedPath.Count){throw '找不到生成的 TUN 配置：已检查 binConfigs/configPre.json 和旧版 guiConfigs/configPre.json；这是路径或生成状态问题。'}
        $generated=Get-Content -LiteralPath $generatedPath[0] -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
        $tun=@($generated.inbounds|Where-Object {$_.type -eq 'tun' -and $_.interface_name -eq $Config.existingTunName})
        if($tun.Count -ne 1 -or $tun[0].auto_route -ne $true -or $tun[0].strict_route -ne $true) { throw '生成的 TUN 配置缺失，或自动路由、严格路由未启用。' }
        if(-not(Get-Process -Name 'sing-box' -ErrorAction SilentlyContinue)) {
            if($switchEnabled){throw '已确认界面/配置的 TUN 开关已开启，但当前没有 sing-box TUN 内核；可能启动失败或已退出，开关状态不能代替运行状态。'}
            throw 'TUN 开关未开启，且未发现 TUN 内核。'
        }
        $nic=@(Get-NetAdapter -Name $Config.existingTunName -ErrorAction Stop)
        if($nic.Count -ne 1 -or $nic[0].Name -ne $Config.existingTunName -or $nic[0].Status -ne 'Up' -or $nic[0].InterfaceDescription -notmatch '^sing-tun\b') { throw '指定的 sing-box TUN 网卡不存在、类型不符或未在线。' }
        $index=$nic[0].ifIndex
        $routes=@(Get-NetRoute -InterfaceIndex $index -AddressFamily IPv4 -PolicyStore ActiveStore -ErrorAction Stop)
        $prefixes=@($routes|Select-Object -ExpandProperty DestinationPrefix)
        if('0.0.0.0/0' -notin $prefixes -and -not('0.0.0.0/1' -in $prefixes -and '128.0.0.0/1' -in $prefixes)) { throw 'TUN 默认路由不完整。' }
        # Query Windows selection without constraining the interface or sending a packet.
        foreach($target in @('93.184.215.14','208.67.222.222')) {
            $best=@(Find-NetRoute -RemoteIPAddress $target -ErrorAction Stop|Where-Object {$_.DestinationPrefix})
            if($best.Count -ne 1 -or $best[0].InterfaceIndex -ne $index) { throw 'Windows 的选路结果没有指向指定 TUN。' }
        }
        $note=if($location.SavedMismatch){'；已自动使用运行实例的目录，保存的目录不匹配，可读取后重新保存'}else{''}
        return [pscustomobject]@{Success=$true;Detail=('TUN 开关、当前生成配置、TUN 内核、网卡、完整默认路由与实际选路均通过'+$note)}
    } catch {
        $source=if($location -and $location.SavedMismatch){'已从运行实例纠正目录；'}else{''}
        return [pscustomobject]@{Success=$false;Detail=($source+'TUN 未就绪或状态未知：'+(Protect-CSMessage $_.Exception.Message))}
    }
}

function Get-CSDirectChecks($Config) {
    $rows=@()
    $core=[bool](Get-Process -Name 'xray','sing-box' -ErrorAction SilentlyContinue)
    $rows+=if($core){New-CSRow '代理内核' 'ok' '现有代理内核在线' $true}else{New-CSRow '代理内核' 'fail' '代理内核未运行' $true}
    $port=Test-CSPort ([uri]$Config.proxyUrl) $Config.connectTimeoutSeconds
    $rows+=if($port){New-CSRow '本地代理' 'ok' '本机代理端口可达；地址不写入诊断' $true}else{New-CSRow '本地代理' 'fail' '端口未响应' $true}
    $httpPending=if($port){@(Start-CSRequestBatch $Config @('https://www.cloudflare.com/cdn-cgi/trace','https://api.ipify.org','https://api.anthropic.com/v1/models'))}else{@()}
    # Advisory probes belong to the UI background lifecycle, not this launch gate.
    $tun=Get-CSExistingTunState $Config
    $rows+=if($tun.Success){New-CSRow 'TUN网卡' 'ok' $tun.Detail $true}else{New-CSRow 'TUN网卡' 'fail' $tun.Detail $true}
    $locale=Get-CSLocaleState $Config
    $rows+=if($locale.Success){New-CSRow '时区与语言' 'ok' $locale.Detail $true}else{New-CSRow '时区与语言' 'fail' ('× 拒绝连接：'+$locale.Detail) $true}
    $verificationError=''
    try{$verification=Get-DBVerification}catch{$verification=$null;$verificationError=Protect-CSMessage $_.Exception.Message}
    $exe=Resolve-CSClaude $Config
    $first='';$second='';$country=''
    if($port){
        $http=Wait-CSRequestBatch $httpPending
        $trace=$http['https://www.cloudflare.com/cdn-cgi/trace']
        if($trace.Success -and $trace.HttpStatus -eq '200'){
            if($trace.Body -match '(?m)^ip=([^\r\n]+)'){$first=$Matches[1].Trim()}
            if($trace.Body -match '(?m)^loc=([A-Z]{2})\s*$'){$country=$Matches[1]}
        }
        $ipify=$http['https://api.ipify.org']
        if($ipify.Success -and $ipify.HttpStatus -eq '200'){$second=$ipify.Body.Trim()}
    }
    $rows+=if($country -eq $Config.requiredCountry){New-CSRow '代理出口' 'ok' '出口国家/地区符合配置' $true}else{New-CSRow '代理出口' 'fail' '出口国家未知或不匹配' $true}
    $rows+=if(Test-CSFixedEgress $first $second $Config){New-CSRow '固定IP' 'ok' '两个接口匹配完整白名单；不自动学习新地址' $true}else{New-CSRow '固定IP' 'fail' '完整出口不匹配或检测失败' $true}
    $currentCovered=($exe -and $verification -and $exe -in @($verification.checks|Select-Object -ExpandProperty program))
    if($verification -and $verification.verified -and $currentCovered) {
        $rows+=New-CSRow '防直连规则' 'ok' "当前版本 $($verification.packageVersion)：$($verification.programCount) 个官方专用程序的 IPv4 / IPv6 规则已核对" $true
    } elseif($verificationError) {
        $rows+=New-CSRow '防直连规则' 'fail' ('无法核验当前官方程序：'+$verificationError) $true
    } elseif($verification -and $verification.missingProgramCount -gt 0) {
        $rows+=New-CSRow '防直连规则' 'fail' "当前版本 $($verification.packageVersion) 有 $($verification.missingProgramCount) 个程序未覆盖或规则被改动，请点击「更新保护规则」" $true
    } else {
        $rows+=New-CSRow '防直连规则' 'fail' '当前规则或防火墙服务状态异常，拒绝启动；可点击「更新保护规则」复核' $true
    }
    if($port){
        $api=$http['https://api.anthropic.com/v1/models']
        $rows+=if($api.Success -and $api.HttpStatus -in @('200','401')){New-CSRow 'API 连接' 'ok' "HTTP $($api.HttpStatus)；未使用认证信息" $true}else{New-CSRow 'API 连接' 'fail' "HTTP $($api.HttpStatus)" $true}
    }else{$rows+=New-CSRow 'API 连接' 'fail' '代理不可用' $true}
    $rows+=if($exe){New-CSRow 'Claude 安装' 'ok' '当前安装版本已识别' $true}else{New-CSRow 'Claude 安装' 'fail' '找不到当前安装版本' $true}
    $rows+=if(Get-Process -Name 'Claude' -ErrorAction SilentlyContinue){New-CSRow '启动状态' 'fail' '请先从托盘完全退出 Claude' $true}else{New-CSRow '启动状态' 'ok' '可创建采用代理参数的新进程' $true}
    foreach($name in @('DNS泄露','WebRTC泄露')){
        $rows+=New-CSRow $name 'warn' '黄色提醒项：界面后台检测，结果不影响启动；尚未取得本轮结果。' $false
    }
    $rows+=New-CSRow '系统设置' 'info' '不修改网卡 IPv6、Tailscale、WSL、时区或现有 TUN'
    $rows+=New-CSRow '保护范围' 'info' '仅登记的专用 Windows 程序；通用工具、WSL 与共享系统服务另行隔离'
    return $rows
}
