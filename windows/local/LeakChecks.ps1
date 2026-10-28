$script:CSLeakRoot=$PSScriptRoot
function Convert-CSAddress([string]$Value) {
    $address=$null
    if(-not [Net.IPAddress]::TryParse($Value,[ref]$address)){return $null}
    if($address.IsIPv4MappedToIPv6){$address=$address.MapToIPv4()}
    return $address
}
function Test-CSGlobalAddress([string]$Value) {
    $address=Convert-CSAddress $Value
    if(-not $address -or [Net.IPAddress]::IsLoopback($address)){return $false}
    $bytes=$address.GetAddressBytes()
    if($address.AddressFamily -eq 'InterNetwork'){
        return -not ($bytes[0] -in @(0,10,127) -or $bytes[0] -ge 224 -or
            ($bytes[0] -eq 100 -and $bytes[1] -ge 64 -and $bytes[1] -le 127) -or
            ($bytes[0] -eq 169 -and $bytes[1] -eq 254) -or
            ($bytes[0] -eq 172 -and $bytes[1] -ge 16 -and $bytes[1] -le 31) -or
            ($bytes[0] -eq 192 -and $bytes[1] -eq 168) -or
            ($bytes[0] -eq 198 -and $bytes[1] -in @(18,19)))
    }
    return (($bytes[0] -band 0xE0) -eq 0x20)
}
function New-CSLeakResult([string]$Name,[string]$State,[string]$Detail,[object[]]$Addresses=@(),[string]$Scope='',[bool]$Attempted=$true) {
    [pscustomobject]@{Name=$Name;State=$State;Detail=$Detail;Addresses=@($Addresses);Scope=$Scope;Attempted=$Attempted;CheckedUtc=[DateTime]::UtcNow.ToString('o')}
}
function Add-CSLeakDiagnostics($Result,$Evidence,[string[]]$Lines,[string]$EmptyReason='') {
    $Result|Add-Member -NotePropertyName Evidence -NotePropertyValue $Evidence -Force
    $Result|Add-Member -NotePropertyName DiagnosticLines -NotePropertyValue @($Lines) -Force
    $Result|Add-Member -NotePropertyName EmptyReason -NotePropertyValue $EmptyReason -Force
    return $Result
}
function Get-CSHttpProbeIssue($Response) {
    if(-not $Response -or -not $Response.Success){
        switch([string]$Response.ErrorKind){
            'timeout'{return '请求超时'}
            'tls'{return 'TLS 安全连接失败'}
            'name_resolution'{return '连接代理或目标时域名解析失败'}
            default{return '网络连接失败（未取得 HTTP 响应）'}
        }
    }
    $status=[string]$Response.HttpStatus
    if($status -ne '200'){
        if($status -match '^3\d\d$'){return ('接口返回 HTTP '+$status+' 跳转；本工具不跟随未核实的跳转')}
        if($status -match '^\d{3}$'){return ('接口返回 HTTP '+$status)}
        return '接口未返回有效 HTTP 状态'
    }
    return ''
}
function Get-CSProbeDeadline($Config) {
    if($Config.PSObject.Properties['probeDeadlineUtc']){return [DateTime]$Config.probeDeadlineUtc}
    return [DateTime]::UtcNow.AddSeconds(30)
}
function Get-CSProbeSeconds([DateTime]$Deadline,[double]$Maximum) {
    $remaining=($Deadline-[DateTime]::UtcNow).TotalSeconds
    if($remaining -le 0){throw [TimeoutException]::new('Probe total budget expired.')}
    return [Math]::Min($Maximum,$remaining)
}
function Get-CSDnsWaitMilliseconds([DateTime]$Deadline) {
    # Use the remaining budget, reserving time to retrieve the observer report.
    # Do not stop at ten seconds before Windows can return its native error.
    $seconds=(Get-CSProbeSeconds $Deadline 30)-4
    if($seconds -le 0){throw [TimeoutException]::new('Insufficient DNS observation budget.')}
    return [int][Math]::Floor($seconds*1000)
}
function Get-CSDnsProgressLines($Queries) {
    if(-not $Queries){return @()}
    $lines=@('Windows DNS：成功 '+$Queries.Completed+'/'+$Queries.Started+'；系统返回错误 '+$Queries.Failed+'；程序到达等待上限时仍未返回 '+$Queries.Pending)
    if($Queries.PSObject.Properties['WaitSeconds']){$lines+=('实际查询等待 '+$Queries.WaitSeconds+' 秒，本阶段上限 '+$Queries.WaitLimitSeconds+' 秒')}
    foreach($failure in @($Queries.Errors)){
        if($failure){$code=if($null -ne $failure.Code){'，错误码 '+$failure.Code}else{''};$lines+=($failure.Label+$code+'（'+$failure.Count+' 次）')}
    }
    return $lines
}
function Get-CSDnsFailure($Failure) {
    # Keep only numeric/native categories. Exception text can contain query IDs,
    # hostnames and local paths, so it must never enter the public diagnostics.
    $exception=$Failure.Exception;$code=$null;$id=[string]$Failure.FullyQualifiedErrorId
    for($depth=0;$exception -and $depth -lt 8;$depth++){
        if($exception -is [ComponentModel.Win32Exception]){$code=[int]$exception.NativeErrorCode;break}
        # PowerShell -ErrorAction Stop wraps DNS errors in
        # ActionPreferenceStopException.ErrorRecord, not always InnerException.
        if($exception.ErrorRecord -and $exception.ErrorRecord.FullyQualifiedErrorId){$id=[string]$exception.ErrorRecord.FullyQualifiedErrorId}
        $next=$exception.InnerException
        if(-not $next -and $exception.ErrorRecord){$next=$exception.ErrorRecord.Exception}
        if([object]::ReferenceEquals($exception,$next)){break}
        $exception=$next
    }
    $kind=if($null -ne $code){switch($code){
        1460{'timeout'} 10060{'timeout'} 9003{'not_found'} 11001{'not_found'}
        9002{'server_failure'} 9005{'refused'} 9501{'no_record'} 5{'access_denied'} default{'native_error'}
    }}elseif($id -match 'CommandNotFound|CouldNotAutoload|ModuleNotFound'){'command_unavailable'}
    elseif($id -match 'PipelineStopped'){'cancelled'}else{'execution_error'}
    $label=switch($kind){
        'timeout'{'系统解析等待超时'} 'not_found'{'域名不存在 / 无法找到主机'}
        'server_failure'{'DNS 服务器处理失败'} 'refused'{'DNS 服务器拒绝查询'}
        'no_record'{'没有所需 A 记录'} 'access_denied'{'系统拒绝执行查询'}
        'command_unavailable'{'DNS 查询命令或模块不可用'} 'cancelled'{'查询已取消'}
        'native_error'{'Windows DNS 返回错误'} default{'查询脚本执行错误'}
    }
    [pscustomobject]@{Kind=$kind;Code=$code;Label=$label}
}
function New-CSDnsProbeFailure([string]$Stage,[string]$Reason,$Evidence) {
    $label=switch($Stage){
        'SessionRequest'{'获取检测会话'}
        'SessionValidation'{'校验检测会话'}
        'DnsQueries'{'触发 Windows DNS 查询'}
        'ReportRequest'{'下载 DNS 报告'}
        'ReportJson'{'解析 DNS 报告'}
        'ReportSchema'{'校验 DNS 报告结构'}
        'ReportService'{'等待 DNS 观测报告'}
        default{'处理 DNS 观测结果'}
    }
    $Evidence.Stage=$Stage
    $lines=@('失败步骤：'+$label)
    if($Evidence.SessionHttpStatus){$lines+=('会话接口 HTTP '+$Evidence.SessionHttpStatus)}
    if($Evidence.ReportHttpStatus){$lines+=('报告接口 HTTP '+$Evidence.ReportHttpStatus)}
    $lines+=@(Get-CSDnsProgressLines $Evidence.Queries)
    if($null -ne $Evidence.SavedBaselineCount){$lines+=('已保存比较基线：'+$Evidence.SavedBaselineCount+' 个地址；本轮没有有效数据，尚未进行基线比较。填入基线不改变 DNS 查询路径')}
    $result=New-CSLeakResult 'DNS泄露' 'unknown' ($label+'失败：'+$Reason+'；仅作提醒。') @() 'Windows 默认解析链'
    return (Add-CSLeakDiagnostics $result ([pscustomobject]$Evidence) $lines ('未取得可核验的 DNS 地址：'+$label+'失败'))
}
function Get-CSDnsQueryResults([string[]]$Names,[int]$TimeoutMilliseconds=30000) {
    # Ask Windows for A records only, using its own DNS policy/server selection.
    # No selected public resolver, hosts/NetBIOS fallback or AAAA wait.
    $pending=@()
    try{
        foreach($name in $Names){
            $shell=[PowerShell]::Create()
            [void]$shell.AddCommand('Resolve-DnsName').AddParameter('Name',$name).AddParameter('Type','A').AddParameter('DnsOnly').AddParameter('NoHostsFile').AddParameter('ErrorAction','Stop')
            try{$pending+=[pscustomobject]@{Shell=$shell;Handle=$shell.BeginInvoke()}}
            catch{$shell.Dispose();throw}
        }
        $deadline=[DateTime]::UtcNow.AddMilliseconds($TimeoutMilliseconds)
        foreach($item in $pending){
            $remaining=[Math]::Max(0,($deadline-[DateTime]::UtcNow).TotalMilliseconds)
            [void]$item.Handle.AsyncWaitHandle.WaitOne([int]$remaining)
        }
        foreach($item in $pending){
            $addresses=@();$failed=$false;$failure=$null;$complete=$item.Handle.IsCompleted
            if($complete){
                try{
                    $records=@($item.Shell.EndInvoke($item.Handle))
                    foreach($record in $records){
                        $ip=Convert-CSAddress ([string]$record.IPAddress)
                        if($ip){$addresses+=$ip}
                    }
                    $failed=$item.Shell.HadErrors
                    if($failed -and $item.Shell.Streams.Error.Count){$failure=Get-CSDnsFailure $item.Shell.Streams.Error[0]}
                }catch{
                    $failed=$true
                    $errorRecord=if($item.Shell.Streams.Error.Count){$item.Shell.Streams.Error[0]}else{$_}
                    $failure=Get-CSDnsFailure $errorRecord
                }
            }
            [pscustomobject]@{Completed=($complete -and -not $failed);Failed=$failed;Pending=(-not $complete);Addresses=$addresses;Failure=$failure}
        }
    }finally{
        foreach($item in $pending){
            try{if(-not $item.Handle.IsCompleted){$item.Shell.Stop()}}finally{$item.Shell.Dispose()}
        }
    }
}
function Invoke-CSFakeDnsConnect([string[]]$Addresses) {
    $clients=@();$tasks=@()
    try{
        foreach($address in $Addresses){
            $client=New-Object Net.Sockets.TcpClient
            $clients+=$client;$tasks+=$client.ConnectAsync([Net.IPAddress]::Parse($address),443)
        }
        if($tasks.Count){try{[void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]$tasks,2000)}catch{}}
    }finally{foreach($client in $clients){$client.Dispose()}}
}
function Test-CSFakeAddressRoute([string]$Address) {
    try{
        $route=@(Find-NetRoute -RemoteIPAddress $Address -ErrorAction Stop|Where-Object {$_.DestinationPrefix})
        if($route.Count -ne 1){return $false}
        $adapter=@(Get-NetAdapter -IncludeHidden -ErrorAction Stop|Where-Object {$_.ifIndex -eq $route[0].InterfaceIndex -and $_.Status -eq 'Up'})
        return ($adapter.Count -eq 1 -and $adapter[0].Virtual -eq $true)
    }catch{return $false}
}
function Invoke-CSDnsQueries([string[]]$Names,$Config,[int]$TimeoutMilliseconds=30000) {
    # Use the default Windows resolver, not a selected public resolver; no ICMP.
    $watch=[Diagnostics.Stopwatch]::StartNew()
    $results=@(Get-CSDnsQueryResults $Names $TimeoutMilliseconds)
    $watch.Stop()
    $fake=@()
    foreach($result in $results){
        if($result.Completed){
            $fake+=@($result.Addresses|Where-Object {$_.ToString() -match '^198\.(18|19)\.'}|Select-Object -First 1|ForEach-Object {$_.ToString()})
        }
    }
    # Fake-IP may resolve lazily. A short connection to the virtual address causes
    # the TUN core to resolve its mapped name; no HTTP data or credentials are sent.
    $routed=@($fake|Sort-Object -Unique|Where-Object {Test-CSFakeAddressRoute $_})
    if($routed.Count){Invoke-CSFakeDnsConnect $routed}
    [pscustomobject]@{
        Started=$results.Count
        Completed=@($results|Where-Object Completed).Count
        Failed=@($results|Where-Object Failed).Count
        Pending=@($results|Where-Object Pending).Count
        WaitSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,2)
        WaitLimitSeconds=[Math]::Round($TimeoutMilliseconds/1000.0,2)
        FakeFollowUps=$routed.Count
        Errors=@($results|Where-Object Failure|Group-Object {$_.Failure.Kind+':'+$_.Failure.Code}|ForEach-Object {
            $failure=$_.Group[0].Failure
            [pscustomobject]@{Kind=$failure.Kind;Code=$failure.Code;Label=$failure.Label;Count=$_.Count}
        })
    }
}
function Convert-CSDnsReport([string]$Body) {
    $text=$Body.TrimStart([char[]]@([char]0xFEFF,[char]32,[char]9,[char]10,[char]13))
    try{$parsed=$text|ConvertFrom-Json -ErrorAction Stop}catch{return [pscustomobject]@{Kind='invalid_json';Records=@()}}
    if($text.StartsWith('{') -and 'error' -in $parsed.PSObject.Properties.Name){
        return [pscustomobject]@{Kind='service_error';Records=@()}
    }
    $records=@($parsed)
    if(-not $text.StartsWith('[') -or $records.Count -gt 100){
        return [pscustomobject]@{Kind='invalid_schema';Records=@()}
    }
    # Only typed address records are evidence. Ignore explanatory metadata.
    $evidence=@($records|Where-Object {$_.type -in @('ip','dns')})
    if(@($evidence|Where-Object {-not (Convert-CSAddress ([string]$_.ip))}).Count){
        return [pscustomobject]@{Kind='invalid_schema';Records=@()}
    }
    return [pscustomobject]@{Kind='report';Records=$evidence}
}
function Get-CSDnsDraftAddresses($Config,$Result) {
    # An observed draft is not a trusted-network allow decision. HTTP pin
    # mismatch must remain visible, but must not hide valid DNS observations.
    if(-not $Result -or -not $Result.Evidence -or $Result.Evidence.ReportValid -ne $true){return @()}
    $addresses=@($Result.Addresses|ForEach-Object {
        $ip=Convert-CSAddress ([string]$_)
        if($ip -and (Test-CSGlobalAddress $ip.ToString())){$ip.ToString()}
    }|Sort-Object -Unique)
    if(-not $addresses.Count -or $addresses.Count -gt 32){return @()}
    return $addresses
}
function Get-CSDnsVerdict($Config,$Observation) {
    $scope='Windows 默认解析链；随机域名权威侧观测，不覆盖浏览器自有 DoH'
    $addresses=@()
    foreach($item in @($Observation|Where-Object type -eq 'dns')){
        $address=Convert-CSAddress ([string]$item.ip)
        if($address -and (Test-CSGlobalAddress $address.ToString())){$addresses+=$address.ToString()}
    }
    $addresses=@($addresses|Sort-Object -Unique)
    if(-not $addresses.Count){return (New-CSLeakResult 'DNS泄露' 'unknown' '服务报告没有解析器地址；查询未被记录或结果尚未出现，无法判断。' @() $scope)}
    $control=@($Observation|Where-Object type -eq 'ip')
    if(-not $control.Count){
        return (New-CSLeakResult 'DNS泄露' 'unknown' '报告缺少用于核对固定出口的 HTTP 地址；下列 DNS 地址仅供排查。' $addresses $scope)
    }
    if(@($control|Where-Object {$_.ip -ne $Config.expectedEgressIP}).Count){
        return (New-CSLeakResult 'DNS泄露' 'fail' 'DNS 地址已取得；检测服务看到的 HTTP 出口与保存值不同。这说明出口不一致，不等于下列 DNS 地址是你的真实 IP。' $addresses $scope)
    }
    $allowed=@($Config.allowedDnsResolverIPs|ForEach-Object {$ip=Convert-CSAddress ([string]$_);if($ip){$ip.ToString()}})
    if(-not $allowed.Count){return (New-CSLeakResult 'DNS泄露' 'unknown' '已取得解析器地址，将自动填入可选比较基线；无需手填，留空也不影响启动。尚未判断这些服务器是否属于你的代理。' $addresses $scope)}
    if(@($addresses|Where-Object {$_ -notin $allowed}).Count){
        return (New-CSLeakResult 'DNS泄露' 'unknown' '解析器地址较已保存基线有变化，可能是地址池轮换或解析路径改变；仅凭地址变化不能认定泄露。' $addresses $scope)
    }
    return (New-CSLeakResult 'DNS泄露' 'ok' '本轮解析器地址与已保存基线一致；这项比较不单独证明解析流量全程经过代理。' $addresses $scope)
}
function Invoke-CSDnsLeakCheck($Config) {
    $stage='SessionRequest'
    $evidence=@{Stage=$stage;SessionHttpStatus='';ReportHttpStatus='';ErrorKind='';SavedBaselineCount=@($Config.allowedDnsResolverIPs).Count}
    try{
        $deadline=Get-CSProbeDeadline $Config
        $probeConfig=$Config.PSObject.Copy();$probeConfig.requestTimeoutSeconds=Get-CSProbeSeconds $deadline 10
        $idResponse=Invoke-CSRequest $probeConfig 'https://bash.ws/id'
        $evidence.SessionHttpStatus=[string]$idResponse.HttpStatus
        $issue=Get-CSHttpProbeIssue $idResponse
        if($issue){$evidence.ErrorKind=[string]$idResponse.ErrorKind;return (New-CSDnsProbeFailure $stage $issue $evidence)}
        $stage='SessionValidation'
        $id=$idResponse.Body.Trim()
        if($id -notmatch '^[A-Za-z0-9-]{1,80}$'){return (New-CSDnsProbeFailure $stage '接口响应不是预期的会话编号' $evidence)}
        $stage='DnsQueries'
        $queryBudget=Get-CSDnsWaitMilliseconds $deadline
        $queryReport=Invoke-CSDnsQueries @(1..6|ForEach-Object {([string]$_)+'.'+$id+'.bash.ws'}) $Config $queryBudget
        $evidence.Queries=$queryReport
        $reportConfig=$probeConfig
        for($attempt=1;$attempt -le 2;$attempt++){
            $stage='ReportRequest';$evidence.ReportAttempts=$attempt
            $reportConfig.requestTimeoutSeconds=Get-CSProbeSeconds $deadline 10
            $result=Invoke-CSRequest $reportConfig ('https://bash.ws/dnsleak/test/'+$id+'?json')
            $evidence.ReportHttpStatus=[string]$result.HttpStatus
            $issue=Get-CSHttpProbeIssue $result
            if($issue){
                $evidence.ErrorKind=[string]$result.ErrorKind
                # Retry a transient report transport timeout once, in the same session.
                if($attempt -eq 1 -and $result.ErrorKind -eq 'timeout'){continue}
                return (New-CSDnsProbeFailure $stage $issue $evidence)
            }
            $evidence.ErrorKind=''
            $stage='ReportJson'
            if($result.Body.TrimStart().StartsWith('<')){return (New-CSDnsProbeFailure $stage '接口返回了网页，未返回 JSON 数据' $evidence)}
            $parsed=Convert-CSDnsReport $result.Body
            if($parsed.Kind -eq 'invalid_json'){return (New-CSDnsProbeFailure $stage '响应无法解析为 JSON' $evidence)}
            if($parsed.Kind -eq 'invalid_schema'){return (New-CSDnsProbeFailure 'ReportSchema' '报告格式与已支持的接口协议不符' $evidence)}
            $hasDns=(@($parsed.Records|Where-Object type -eq 'dns').Count -gt 0)
            if($parsed.Kind -eq 'report' -and $hasDns){break}
            # Reports can lag behind the authoritative query. One bounded retry;
            # never retry a format error or switch to a different resolver.
            if($attempt -eq 1 -and $queryReport -and ($queryReport.Completed+$queryReport.Failed) -gt 0){Start-Sleep -Milliseconds 300;continue}
            break
        }
        if($parsed.Kind -eq 'service_error'){
            $nativeTimeout=@($queryReport.Errors|Where-Object {$_.Kind -eq 'timeout' -and $null -ne $_.Code}).Count -gt 0
            $reason=if($queryReport -and $queryReport.Pending -eq $queryReport.Started -and $queryReport.Started -gt 0){'HTTPS 接口正常；'+$queryReport.Pending+'/'+$queryReport.Started+' 次 Windows DNS 查询在本程序等待上限内未返回，已停止等待。这不是 Windows 返回的超时错误；服务没有可用报告'}elseif($nativeTimeout){'HTTPS 接口正常，但 Windows DNS 已自行返回超时错误；不是程序提前停止等待。未取得本轮数据，尚未进行基线比较'}elseif($queryReport -and -not $queryReport.Completed){'HTTPS 接口正常，但 DNS 查询命令已返回错误；不是基线地址不匹配。具体错误见下方'}else{'HTTP 接口可达，但服务返回错误对象，未生成有效报告；稍后重试'}
            return (New-CSDnsProbeFailure 'ReportService' $reason $evidence)
        }
        $observation=@($parsed.Records)
        $stage='Verdict';$evidence.Stage=$stage
        $evidence.ReportValid=$true
        $verdict=Get-CSDnsVerdict $Config $observation
        $control=@($observation|Where-Object type -eq 'ip')
        $evidence.ControlPresent=($control.Count -gt 0)
        $evidence.ControlMatchesPinned=($control.Count -gt 0 -and @($control|Where-Object {$_.ip -ne $Config.expectedEgressIP}).Count -eq 0)
        $lines=@('会话接口 HTTP 200；报告接口 HTTP 200，JSON 解析成功')
        $lines+=@(Get-CSDnsProgressLines $queryReport)
        $lines+=('已保存比较基线：'+$evidence.SavedBaselineCount+' 个地址；当前实测结果与基线分开显示')
        $lines+=('观测到 '+@($verdict.Addresses).Count+' 个解析器出口；DNS 地址允许有多个，不必与代理出口相同')
        $dnsV6=@($verdict.Addresses|Where-Object {(Convert-CSAddress $_).AddressFamily -eq 'InterNetworkV6'}).Count
        if($dnsV6){$lines+=('其中 '+$dnsV6+' 个是 DNS 服务器的 IPv6 地址，不表示本机使用公网 IPv6 联网')}
        return (Add-CSLeakDiagnostics $verdict ([pscustomobject]$evidence) $lines '报告中没有可用的 DNS 解析器地址')
    }catch{
        $reason=switch($stage){
            'ReportJson'{'响应无法解析为 JSON'}
            'DnsQueries'{'系统解析探针没有正常完成'}
            default{'探针在该步骤发生错误'}
        }
        return (New-CSDnsProbeFailure $stage $reason $evidence)
    }
}
function Get-CSWebRtcVerdict($Config,$Observation) {
    $scope='独立临时 Edge 的浏览器 ICE；不读取 Claude 内部状态'
    if(-not $Observation -or $Observation.supported -ne $true){return (New-CSLeakResult 'WebRTC泄露' 'unknown' '浏览器不支持 WebRTC 或没有有效报告。' @() $scope)}
    $public=@();$reflexiveServers=@();$probeEvidence=@();$lines=@()
    foreach($probe in @($Observation.probes)){
        $clientPublic=0;$reflexiveCount=0
        foreach($candidate in @($probe.candidates)){
            $address=Convert-CSAddress ([string]$candidate.address)
            if(-not $address -or -not(Test-CSGlobalAddress $address.ToString())){continue}
            # TURN relay addresses belong to a server, not to the client.
            if($candidate.type -notin @('host','srflx','prflx')){continue}
            $public+=$address.ToString()
            $clientPublic++
            if($candidate.type -eq 'srflx'){$reflexiveCount++}
            if($candidate.type -eq 'srflx' -and $address.ToString() -eq $Config.expectedEgressIP){$reflexiveServers+=[string]$probe.server}
        }
        $name=switch([string]$probe.server){'stun:stun.cloudflare.com:3478'{'Cloudflare'}'stun:stun.l.google.com:19302'{'Google'}default{'其他 STUN'}}
        $errors=@($probe.errors|Where-Object {[string]$_ -match '^-?\d{1,5}$'}|ForEach-Object {[int]$_}|Sort-Object -Unique)
        $errorKinds=@($probe.errorKinds|Where-Object {$_ -in @('name_resolution','timeout','unreachable','transport')}|Sort-Object -Unique)
        $resolution=if($probe.resolution -eq 'proxy_doh'){'proxy_doh'}else{'system_dns'}
        $attempts=if($probe.attempts -eq 2){2}else{1}
        $waitSeconds=if($probe.PSObject.Properties['waitedMs']){[Math]::Round([Math]::Min(30000,[Math]::Max(0,[double]$probe.waitedMs))/1000,2)}else{$null}
        $limitSeconds=if($probe.PSObject.Properties['waitLimitMs']){[Math]::Round([Math]::Min(30000,[Math]::Max(0,[double]$probe.waitLimitMs))/1000,2)}else{$null}
        $probeEvidence+=[pscustomobject]@{Provider=$name;Resolution=$resolution;Attempts=$attempts;Completed=($probe.completed -eq $true);TimedOut=($probe.timedOut -eq $true);WaitSeconds=$waitSeconds;WaitLimitSeconds=$limitSeconds;Errors=$errors;ErrorKinds=$errorKinds;CandidateCount=@($probe.candidates).Count;PublicCandidateCount=$clientPublic;ReflexiveCount=$reflexiveCount}
        $progress=if(@($errors|Where-Object {$_ -lt 0}).Count){'浏览器创建探针或会话失败，不能据此判断 STUN 网络'}elseif($probe.timedOut -eq $true){'程序达到等待时限，停止本次收集'}elseif($probe.completed -eq $true){'浏览器已结束候选收集'}else{'候选收集未完成'}
        $line=$name+'：'+$progress+'；STUN 公网反射地址 '+$reflexiveCount+' 个'
        if($null -ne $waitSeconds){$line+='；实际等待 '+$waitSeconds+' 秒 / 本阶段预算 '+$limitSeconds+' 秒'}
        if($resolution -eq 'proxy_doh'){$line+='；已加入代理内解析的备用地址'}
        if($attempts -eq 2){$line+='；已单独复测一次'}
        if($errors.Count){$line+=('；错误码 '+($errors -join ', '))}
        if($errorKinds.Count){$line+='；浏览器报告：'+(@($errorKinds|ForEach-Object {switch($_){'name_resolution'{'部分 STUN 名称解析失败'}'timeout'{'STUN 请求超时'}'unreachable'{'STUN 目标不可达'}default{'STUN 传输错误'}}}) -join '、')}
        $lines+=$line
    }
    $public=@($public|Sort-Object -Unique)
    $required=@('stun:stun.cloudflare.com:3478','stun:stun.l.google.com:19302')
    $matched=@($required|Where-Object {$_ -in $reflexiveServers}).Count
    $publicV6=@($public|Where-Object {(Convert-CSAddress $_).AddressFamily -eq 'InterNetworkV6'}).Count
    $unexpected=@($public|Where-Object {$_ -ne $Config.expectedEgressIP})
    $unexpectedV6=@($unexpected|Where-Object {(Convert-CSAddress $_).AddressFamily -eq 'InterNetworkV6'}).Count
    $evidence=[pscustomobject]@{Stage='IceGathering';Observation='';VerifiedStunCount=$matched;RequiredStunCount=2;PublicIPv4Count=($public.Count-$publicV6);PublicIPv6Count=$publicV6;Probes=$probeEvidence}
    if($unexpected.Count){
        $evidence.Observation='unexpected_public_candidate'
        $families=if($unexpectedV6 -eq 0){'公网 IPv4 地址'}elseif($unexpectedV6 -eq $unexpected.Count){'公网 IPv6 地址'}else{'公网 IPv4 和 IPv6 地址'}
        $result=New-CSLeakResult 'WebRTC泄露' 'fail' ('发现固定出口之外的'+$families+'，需核实是否属于代理；不能仅凭此项认定是校园网出口。仅作黄色提醒。') $public $scope
    }elseif($matched -lt 2){
        $evidence.Observation=if($public.Count){'partial_verification'}else{'no_public_candidate'}
        $detail=if($public.Count){'只完成 '+$matched+'/2 处 STUN 的固定出口核验；覆盖不足，仅作提醒。'}else{'本轮未观察到公网地址暴露。两处 STUN 未取得足够回复，无法核验 UDP 出口；这是检测未完成，不是已发现泄露。不阻止启动。'}
        $result=New-CSLeakResult 'WebRTC泄露' 'unknown' $detail $public $scope
    }else{
        $evidence.Observation='verified'
        $result=New-CSLeakResult 'WebRTC泄露' 'ok' '两处 STUN 的公网反射地址符合固定出口，未发现其他可见公网候选。' $public $scope
    }
    $lines+=('已核验固定出口的 STUN：'+$matched+'/2。候选收集完成不等于 STUN 请求成功')
    $lines+=('实测公网候选：IPv4 '+($public.Count-$publicV6)+' 个，IPv6 '+$publicV6+' 个；不计本地链路、内网、mDNS 和 TURN 中继地址')
    return (Add-CSLeakDiagnostics $result $evidence $lines '本轮未收集到公网地址：没有观察到暴露，也没有验证到代理出口')
}
function Get-CSEdgePath {
    $candidates=@((Join-Path ([Environment]::GetEnvironmentVariable('ProgramFiles(x86)')) 'Microsoft\Edge\Application\msedge.exe'),(Join-Path $env:ProgramFiles 'Microsoft\Edge\Application\msedge.exe'))
    foreach($path in $candidates){
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){continue}
        $signature=Get-AuthenticodeSignature -LiteralPath $path -ErrorAction Stop
        if($signature.Status -eq 'Valid' -and $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -eq 'Microsoft Corporation'){return $path}
    }
    throw '未发现可核验的 Microsoft Edge。'
}
function Initialize-CSBrowserProbe {
    if(-not ('ClaudeGuardProbe.BrowserClient' -as [type])){
        Add-Type -AssemblyName System.Web.Extensions
        Add-Type -Path (Join-Path $script:CSLeakRoot 'probes\BrowserProbe.cs') -ReferencedAssemblies ([System.Web.Script.Serialization.JavaScriptSerializer].Assembly.Location) -ErrorAction Stop
    }
}
function Get-CSStunProbeOptions($Config) {
    $targets=@(
        [pscustomobject]@{HostName='stun.cloudflare.com';Port=3478;Id='stun:stun.cloudflare.com:3478'},
        [pscustomobject]@{HostName='stun.l.google.com';Port=19302;Id='stun:stun.l.google.com:19302'}
    )
    $lookupConfig=$Config.PSObject.Copy();$lookupConfig.requestTimeoutSeconds=Get-CSProbeSeconds (Get-CSProbeDeadline $Config) 5
    $urls=@($targets|ForEach-Object {'https://dns.google/resolve?name='+$_.HostName+'&type=A'})
    $responses=Invoke-CSRequestBatch $lookupConfig $urls
    $servers=@()
    for($index=0;$index -lt $targets.Count;$index++){
        $target=$targets[$index];$addresses=@();$response=$responses[$urls[$index]]
        if($response.Success -and $response.HttpStatus -eq '200'){
            try{
                $answer=$response.Body|ConvertFrom-Json -ErrorAction Stop
                if($answer.Status -eq 0 -and @($answer.Question|Where-Object {$_.name.TrimEnd('.') -eq $target.HostName -and $_.type -eq 1}).Count -eq 1){
                    $addresses=@($answer.Answer|Where-Object type -eq 1|ForEach-Object {
                        $ip=Convert-CSAddress ([string]$_.data)
                        if($ip -and $ip.AddressFamily -eq 'InterNetwork' -and (Test-CSGlobalAddress $ip.ToString())){$ip.ToString()}
                    }|Sort-Object -Unique|Select-Object -First 2)
                }
            }catch{}
        }
        $mode=if($addresses.Count){'proxy_doh'}else{'system_dns'}
        # Preserve the original hostname path (including its IPv6 capability).
        # Add IPv4 fallback addresses instead of replacing the original probe.
        $stunUrls=@($target.Id)+@($addresses|ForEach-Object {'stun:'+$_+':'+$target.Port})
        $servers+=[pscustomobject]@{id=$target.Id;urls=@($stunUrls);resolution=$mode}
    }
    return [pscustomobject]@{servers=$servers;timeoutMs=30000;retryTimeoutMs=3000;totalTimeoutMs=30000}
}
function Invoke-CSBrowserProbe([string]$Edge,[string]$Proxy,[string]$Page,[int]$Seconds,[string]$OptionsJson) {
    [ClaudeGuardProbe.BrowserClient]::Run($Edge,$Proxy,$Page,$Seconds,$OptionsJson)
}
function New-CSWebRtcProbeFailure([string]$Stage,$Failure) {
    $labels=@{BrowserStart='启动独立 Edge';BrowserCompile='准备浏览器探针';StunResolution='取得 STUN 备用地址';DebugChannel='连接本机浏览器调试通道';LocalPage='加载本地检测页面';IceGathering='执行浏览器 ICE 检测';ReportJson='读取浏览器结果'}
    $kind='execution';$exception=$Failure.Exception
    for($depth=0;$exception -and $depth -lt 10;$depth++){
        if($exception.Data -and $labels.ContainsKey([string]$exception.Data['CSProbeStage'])){$Stage=[string]$exception.Data['CSProbeStage']}
        if($exception -is [OperationCanceledException] -or $exception -is [TimeoutException]){$kind='timeout'}
        $exception=$exception.InnerException
    }
    if(-not $labels.ContainsKey($Stage)){$Stage='IceGathering'}
    $reason=if($kind -eq 'timeout'){'本程序的剩余时间预算已用完'}else{'该步骤未成功完成'}
    $result=New-CSLeakResult 'WebRTC泄露' 'unknown' ($labels[$Stage]+'未完成：'+$reason+'。未取得完整探针结果，不代表发现泄露；仅作提醒。') @() '独立临时 Edge'
    Add-CSLeakDiagnostics $result ([pscustomobject]@{Stage=$Stage;ErrorKind=$kind}) @('未完成步骤：'+$labels[$Stage]) '未取得完整的浏览器检测结果；请查看上方失败步骤'
}
function Invoke-CSWebRtcLeakCheck($Config) {
    $stage='BrowserStart'
    try{
        $deadline=Get-CSProbeDeadline $Config
        $edge=Get-CSEdgePath
        $stage='BrowserCompile'
        Initialize-CSBrowserProbe
        $stage='StunResolution'
        $options=Get-CSStunProbeOptions $Config
        $browserSeconds=[Math]::Floor((Get-CSProbeSeconds $deadline 28))
        if($browserSeconds -lt 2){throw [TimeoutException]::new('Probe total budget expired.')}
        $options.totalTimeoutMs=[Math]::Max(500,($browserSeconds-3)*1000)
        $options.timeoutMs=$options.totalTimeoutMs
        $optionsJson=ConvertTo-Json -InputObject $options -Depth 5 -Compress
        $stage='BrowserStart'
        $output=Invoke-CSBrowserProbe $edge $Config.proxyUrl (Join-Path $script:CSLeakRoot 'probes\webrtc.html') ([int]$browserSeconds) $optionsJson
        $stage='ReportJson'
        $result=Get-CSWebRtcVerdict $Config ($output.Json|ConvertFrom-Json -ErrorAction Stop)
        if(-not $output.CleanupComplete){
            if($result.State -eq 'ok'){$result.State='unknown'}
            $result.Detail+=' 临时浏览器目录未完全清理；本轮地址观测仍保留。'
        }
        return $result
    }catch{return (New-CSWebRtcProbeFailure $stage $_)}
}
function Start-CSLeakTask($Config,[string]$Kind,[bool]$CheckProxy=$false) {
    $started=[DateTime]::UtcNow
    $probeConfig=$Config.PSObject.Copy()
    $probeConfig|Add-Member -NotePropertyName probeDeadlineUtc -NotePropertyValue $started.AddSeconds(30) -Force
    $shell=[PowerShell]::Create()
    $null=$shell.AddScript(@'
param($CorePath,$ProbeConfig,$Kind,$CheckProxy)
. $CorePath
if($CheckProxy -and ((Get-CSProxyIssue $ProbeConfig) -or -not(Test-CSPort ([uri]$ProbeConfig.proxyUrl) $ProbeConfig.connectTimeoutSeconds))){
    $name=if($Kind -eq 'Dns'){'DNS泄露'}else{'WebRTC泄露'}
    return (New-CSLeakResult $name 'unknown' '本机代理不可用，本次未检测；仅作提醒。' @() '本机代理端口检查' $false)
}
if($Kind -eq 'Dns'){Invoke-CSDnsLeakCheck $ProbeConfig}else{Invoke-CSWebRtcLeakCheck $ProbeConfig}
'@).AddArgument((Join-Path $script:CSLeakRoot 'ClaudeLocalCore.ps1')).AddArgument($probeConfig).AddArgument($Kind).AddArgument($CheckProxy)
    try{[pscustomobject]@{Shell=$shell;Handle=$shell.BeginInvoke();Kind=$Kind;Started=$started}}
    catch{$shell.Dispose();throw}
}
function Wait-CSLeakTask($Task,[string]$Kind) {
    $name=if($Kind -eq 'Dns'){'DNS泄露'}else{'WebRTC泄露'}
    if(-not $Task){return (New-CSLeakResult $name 'unknown' '无法启动检测任务；未取得地址。')}
    try{
        $remaining=[Math]::Max(1,30000-([DateTime]::UtcNow-$Task.Started).TotalMilliseconds)
        if(-not $Task.Handle.AsyncWaitHandle.WaitOne([int]$remaining)){$Task.Shell.Stop();throw 'Probe timed out.'}
        $items=@($Task.Shell.EndInvoke($Task.Handle)|Where-Object {$_.Name -eq $name})
        if($items.Count -ne 1){throw 'Missing probe report.'}
        return $items[0]
    }catch{return (New-CSLeakResult $name 'unknown' '检测任务超时或结果不完整；仅作提醒。')}
    finally{$Task.Shell.Dispose()}
}
function Start-CSLeakBundle($Config,[bool]$ProxyReady,[string]$BlockedReason='保存的本机 HTTP 代理端口没有响应。') {
    if(-not $ProxyReady){
        $detail='本次未检测：'+$BlockedReason
        $dns=New-CSLeakResult 'DNS泄露' 'unknown' $detail @() '本机代理不可用，尚未发出 DNS 探针' $false
        $rtc=New-CSLeakResult 'WebRTC泄露' 'unknown' $detail @() '本机代理不可用，尚未启动浏览器探针' $false
        return [pscustomobject]@{Dns=$dns;WebRtc=$rtc;DnsTask=$null;RtcTask=$null;Started=$false}
    }else{
        $dnsTask=$null;$rtcTask=$null
        try{$dnsTask=Start-CSLeakTask $Config 'Dns'}catch{}
        try{$rtcTask=Start-CSLeakTask $Config 'WebRtc'}catch{}
        return [pscustomobject]@{Dns=$null;WebRtc=$null;DnsTask=$dnsTask;RtcTask=$rtcTask;Started=$true}
    }
}
function Complete-CSLeakBundle($Pending) {
    if($Pending.Started){$dns=Wait-CSLeakTask $Pending.DnsTask 'Dns';$rtc=Wait-CSLeakTask $Pending.RtcTask 'WebRtc'}
    else{$dns=$Pending.Dns;$rtc=$Pending.WebRtc}
    $rows=@(@($dns,$rtc)|ForEach-Object {New-CSRow $_.Name $(if($_.State -eq 'ok'){'ok'}else{'warn'}) $_.Detail $false})
    $script:CSLastLeakDiagnostics=[pscustomobject]@{Dns=$dns;WebRtc=$rtc}
    return $rows
}
function Get-CSLeakCheckBundle($Config,[bool]$ProxyReady,[string]$BlockedReason='保存的本机 HTTP 代理端口没有响应。') {
    return @(Complete-CSLeakBundle (Start-CSLeakBundle $Config $ProxyReady $BlockedReason))
}
function New-CSLeakNetworkState($Config,$Tun,[bool]$Port,[string]$First,[string]$Second) {
    $reasons=@()
    if(-not $Tun.Success){$reasons+=('TUN：'+$Tun.Detail)}
    if(-not $Port){$reasons+='保存的本机代理端口没有响应'}
    elseif(-not $First -or -not $Second){$reasons+='出口查询失败或超时，尚未核实固定 IP'}
    elseif(-not (Test-CSFixedEgress $First $Second $Config)){$reasons+='两个出口查询不一致，或当前出口不是保存的固定 IP'}
    [pscustomobject]@{Ready=($reasons.Count -eq 0);Reasons=$reasons}
}
function Get-CSLeakNetworkState($Config) {
    $tun=Get-CSExistingTunState $Config
    $port=Test-CSPort ([uri]$Config.proxyUrl) $Config.connectTimeoutSeconds
    $first='';$second=''
    if($port){
        $responses=Invoke-CSRequestBatch $Config @('https://www.cloudflare.com/cdn-cgi/trace','https://api.ipify.org')
        $trace=$responses['https://www.cloudflare.com/cdn-cgi/trace'];$ipify=$responses['https://api.ipify.org']
        if($trace.Success -and $trace.HttpStatus -eq '200' -and $trace.Body -match '(?m)^ip=([^\r\n]+)'){$first=$Matches[1].Trim()}
        if($ipify.Success -and $ipify.HttpStatus -eq '200'){$second=$ipify.Body.Trim()}
    }
    return (New-CSLeakNetworkState $Config $tun $port $first $second)
}
function Test-CSLeakNetworkReady($Config) {
    try{return (Get-CSLeakNetworkState $Config).Ready}catch{return $false}
}
function Get-CSLeakObservation($Config) {
    $port=Test-CSPort ([uri]$Config.proxyUrl) $Config.connectTimeoutSeconds
    return @(Get-CSLeakCheckBundle $Config $port '本机 HTTP 代理端口没有响应，无法取得检测会话。')
}
