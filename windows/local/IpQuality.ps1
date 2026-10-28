# Optional, anonymous lookups. No keys, author backend, persistence or launch verdict.
function Convert-CSQualityTarget([string]$Value) {
    $value=$Value.Trim()
    if(-not $value -or $value.Length -gt 2048 -or $value -match '[\x00-\x20"<>]'){throw '请输入一个完整公网 IP，或只包含一个 IP 的检测报告链接。'}
    $candidates=@()
    if($value -match '^https?://'){
        $uri=$null
        if(-not [Uri]::TryCreate($value,[UriKind]::Absolute,[ref]$uri) -or $uri.UserInfo){throw '链接格式无效；不接受含账号密码的链接。'}
        # Extract text only. Never visit the pasted host, resolve it or forward its query.
        $decoded=[Uri]::UnescapeDataString($uri.AbsolutePath+'?'+$uri.Query)
        $candidates+=@([regex]::Matches($decoded,'(?<![\d.])(?:\d{1,3}\.){3}\d{1,3}(?![\d.])')|ForEach-Object {$_.Value})
        foreach($token in ($decoded -split '[/&=?#]+')){
            if($token.Contains(':')){$candidates+=$token.Trim('[',']')}
        }
        if($uri.HostNameType -in @([UriHostNameType]::IPv4,[UriHostNameType]::IPv6)){$candidates+=$uri.Host.Trim('[',']')}
    }else{$candidates=@($value)}
    $valid=@()
    foreach($candidate in $candidates){
        if($candidate -match '%' -or ($candidate -notmatch ':' -and $candidate -notmatch '^(?:\d{1,3}\.){3}\d{1,3}$')){continue}
        $ip=Convert-CSAddress $candidate
        if($ip -and (Test-CSGlobalAddress $ip.ToString())){$valid+=$ip.ToString()}
    }
    $valid=@($valid|Sort-Object -Unique)
    if($valid.Count -ne 1){throw '未识别到唯一公网 IP；不接受内网、回环地址、域名或多个目标。'}
    return $valid[0]
}
function Start-CSQualityRequest($Config,[string]$Url) {
    return (Start-CSHttpRequest $Config $Url)
}
function Wait-CSQualityRequest($Request) {
    $response=Wait-CSHttpRequest $Request
    if([int]$response.HttpStatus -lt 200 -or [int]$response.HttpStatus -ge 300){$response.Success=$false}
    return $response
}
function Convert-CSQualityResult([string]$Provider,[string]$Target,$Response) {
    $result=[ordered]@{Provider=$Provider;State='unavailable';Score=$null;Direction='风险评分：0–100，越低越好';Detail='未取得有效结果。';Signals=@();SourceUrl='https://ipquery.io/';DataTime='服务商未提供生成时间';CheckedUtc=[DateTime]::UtcNow.ToString('o')}
    if(-not $Response -or -not $Response.Success){
        $result.Detail=if($Response -and $Response.HttpStatus -eq 429){'达到服务商限额，请稍后手动重试。'}else{'接口不可用、请求失败或超时；未回退直连。'}
        return [pscustomobject]$result
    }
    try{
        if($Provider -ne 'IPQuery'){throw 'Unsupported provider.'}
        $data=$Response.Body|ConvertFrom-Json -ErrorAction Stop
        $returned=Convert-CSAddress ([string]$data.ip)
        if(-not $returned -or $returned.ToString() -ne $Target){throw 'target mismatch'}
        $score=$data.risk.risk_score
        if($null -eq $score -or $score -is [string] -or $score -is [bool]){throw 'missing numeric score'}
        $number=[double]$score
        if([double]::IsNaN($number) -or [double]::IsInfinity($number) -or $number -lt 0 -or $number -gt 100){throw 'invalid score'}
        $result.Score=$number;$result.State='ok'
        foreach($flag in @('is_proxy','is_vpn','is_tor','is_datacenter','is_mobile')){
            if($data.risk.$flag -is [bool] -and $data.risk.$flag){$result.Signals+=($flag -replace '^is_','')}
        }
        $result.Detail=if($data.risk.is_datacenter -eq $true){'识别为机房 IP。低风险分只代表此来源的判定，不代表住宅 IP，也不代表 Claude 信任度高。'}else{'IPQuery 风险评分；0 分也不能证明 Claude 可用或不会触发验证。'}
    }catch{$result.State='unavailable';$result.Score=$null;$result.Signals=@();$result.Detail='返回格式、目标 IP 或分数字段无法核实；不将缺失字段当成 0 分。'}
    return [pscustomobject]$result
}
function Invoke-CSQualityCheck($Config,[string]$Target) {
    $target=Convert-CSQualityTarget $Target
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $response=$null
    try{$request=Start-CSQualityRequest $Config ('https://api.ipquery.io/'+[Uri]::EscapeDataString($target));$response=Wait-CSQualityRequest $request}catch{}
    [pscustomobject]@{Target=$target;Results=@(Convert-CSQualityResult 'IPQuery' $target $response);CheckedUtc=[DateTime]::UtcNow.ToString('o');Note='仅查询 IPQuery 风险分；IPinfo.CV 由用户打开网页查看。不保存结果，不改变固定出口。'}
}
function Get-CSQualityWebLink([string]$Site,[string]$SavedIP='') {
    switch($Site){
        'Coffee'{return 'https://ip.net.coffee/claude/'}
        'IPRisk'{return 'https://iprisk.top/?lang=zh'}
        'IpInfoCv'{return 'https://ipinfo.cv/claude-ai-check'}
        'Scamalytics'{
            $target=Convert-CSQualityTarget $SavedIP
            return ('https://scamalytics.com/ip/'+[Uri]::EscapeDataString($target))
        }
        default{throw '未知的检测网站。'}
    }
}
