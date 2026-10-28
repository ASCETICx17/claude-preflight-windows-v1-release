$script:CSConfigurationRoot=$PSScriptRoot
. (Join-Path $PSScriptRoot 'LocalePolicy.ps1')
function Get-CSConfigPath { return (Join-Path $script:CSConfigurationRoot 'settings.json') }
function Get-CSOwnerSid { return [Security.Principal.WindowsIdentity]::GetCurrent().User.Value }
function Get-CSConfigTemplate {
    Get-Content -LiteralPath (Join-Path $script:CSConfigurationRoot 'settings.example.json') -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json
}
function Convert-CSRuntimeConfig($Data) {
    # Only editable fields are persisted. Application constants and derived values stay public.
    $result=[pscustomobject]@{
        schemaVersion=2;proxyUrl=[string]$Data.proxyUrl;requiredCountry=[string]$Data.requiredCountry
        expectedEgressIP=[string]$Data.expectedEgressIP;proxyRoot=[string]$Data.proxyRoot
        existingTunName=[string]$Data.existingTunName;expectedTimeZone=[string]$Data.expectedTimeZone
        expectedCulture=[string]$Data.expectedCulture;ownerSid=[string]$Data.ownerSid
        allowedDnsResolverIPs=@($Data.allowedDnsResolverIPs|Where-Object {$_})
        appPackageName='Claude';connectTimeoutSeconds=5;requestTimeoutSeconds=8;strictMode=$true
        protectionMode='DirectBlock';clientLanguage=[string]$Data.expectedCulture
    }
    return $result
}
function Get-CSProxyIssue($Config) {
    $uri=$null
    if($Config.proxyUrl -notmatch '^http://127\.0\.0\.1:[0-9]{1,5}/?$' -or -not [uri]::TryCreate([string]$Config.proxyUrl,[UriKind]::Absolute,[ref]$uri) -or $uri.Scheme -ne 'http' -or $uri.Host -ne '127.0.0.1' -or $uri.UserInfo -or $uri.AbsolutePath -ne '/' -or $uri.Query -or $uri.Fragment -or $uri.Port -lt 1) { return '本机代理须为 http://127.0.0.1:端口，请补全端口号（1–65535）。' }
    return $null
}
function Get-CSConfigurationIssues($Config) {
    $issues=New-Object 'Collections.Generic.List[string]'
    $proxyIssue=Get-CSProxyIssue $Config
    if($proxyIssue){$issues.Add($proxyIssue)}
    $address=$null
    if(-not [Net.IPAddress]::TryParse([string]$Config.expectedEgressIP,[ref]$address) -or $address.AddressFamily -ne 'InterNetwork' -or $Config.expectedEgressIP -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { $issues.Add('请填写完整的 IPv4 出口白名单。') }
    if($Config.requiredCountry -notmatch '^[A-Z]{2}$') { $issues.Add('出口国家/地区须为两个大写英文字母。') }
    if(-not $Config.proxyRoot -or $Config.proxyRoot -notmatch '^[A-Za-z]:\\' -or $Config.proxyRoot -match '[\r\n"<>|*?]') { $issues.Add('请选择 v2rayN 的本地绝对安装目录，例如 D:\\Apps\\v2rayN。') }
    if(-not $Config.existingTunName -or $Config.existingTunName -match '[*?\[\]\r\n]') { $issues.Add('请填写精确的 TUN 网卡名称，不使用通配符。') }
    if(@($Config.allowedDnsResolverIPs).Count -gt 32){$issues.Add('DNS 解析器允许列表最多 32 个 IP。')}
    foreach($dnsIp in @($Config.allowedDnsResolverIPs)){
        $parsedDns=$null
        if(-not [Net.IPAddress]::TryParse([string]$dnsIp,[ref]$parsedDns)){$issues.Add('DNS 允许列表须为精确 IPv4 / IPv6 地址，不使用域名或网段。');break}
    }
    $locale=Get-CSLocalePairIssue $Config.expectedTimeZone $Config.expectedCulture
    if($locale) { $issues.Add($locale) }
    return $issues.ToArray()
}
function Get-CSConfig([switch]$AllowIncomplete) {
    $path=Get-CSConfigPath
    try {
        $data=if(Test-Path -LiteralPath $path) {Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop}else{Get-CSConfigTemplate}
        if($data.schemaVersion -ne 2) { throw 'Unsupported schema.' }
        $config=Convert-CSRuntimeConfig $data
    } catch { throw '配置文件无法读取或格式损坏，请在设置页重新保存。' }
    if(-not $AllowIncomplete) {
        $issues=@(Get-CSConfigurationIssues $config)
        if($issues.Count) { throw ($issues -join ' ') }
    }
    return $config
}
function Save-CSConfig($Data) {
    $config=Convert-CSRuntimeConfig $Data
    $config.proxyUrl=$config.proxyUrl.Trim()
    $config.expectedEgressIP=$config.expectedEgressIP.Trim()
    $config.requiredCountry=$config.requiredCountry.Trim().ToUpperInvariant()
    $config.proxyRoot=$config.proxyRoot.Trim()
    if($config.proxyRoot.Length -gt 3) { $config.proxyRoot=$config.proxyRoot.TrimEnd('\') }
    $config.existingTunName=$config.existingTunName.Trim()
    $issues=@(Get-CSConfigurationIssues $config)
    if($issues.Count) { throw ($issues -join ' ') }
    $dnsAllowed=@($config.allowedDnsResolverIPs|ForEach-Object {[Net.IPAddress]::Parse($_).ToString()}|Sort-Object -Unique)
    $stored=[ordered]@{schemaVersion=2;proxyUrl=$config.proxyUrl;requiredCountry=$config.requiredCountry;expectedEgressIP=$config.expectedEgressIP;proxyRoot=$config.proxyRoot;existingTunName=$config.existingTunName;expectedTimeZone=$config.expectedTimeZone;expectedCulture=$config.expectedCulture;allowedDnsResolverIPs=$dnsAllowed;ownerSid=(Get-CSOwnerSid)}
    $bytes=[Text.Encoding]::UTF8.GetBytes(($stored|ConvertTo-Json))
    # One file only: no sensitive temporary file, automatic backup or secondary cache.
    $stream=New-Object IO.FileStream((Get-CSConfigPath),[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length);$stream.Flush($true) } finally { $stream.Dispose() }
    return (Get-CSConfig)
}
function Protect-CSMessage([string]$Message) {
    $safe=$Message -replace '(?i)[A-Z]:\\[^\r\n"<>\|]*','[本地路径]'
    $safe=$safe -replace '\bS-1-5-21-[0-9-]+\b','[本地账号]'
    $safe=$safe -replace '(?<![\w])\d{1,3}(\.\d{1,3}){3}(?![\w])','[地址]'
    return $safe
}
