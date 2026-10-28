param([Parameter(Mandatory=$true)][string]$SettingsPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\local\ClaudeLocalCore.ps1')
$config=Convert-CSRuntimeConfig (Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8|ConvertFrom-Json)
if(@(Get-CSConfigurationIssues $config).Count){throw 'Configuration is incomplete; no requests sent.'}
$watch=[Diagnostics.Stopwatch]::StartNew()
$port=Test-CSPort ([uri]$config.proxyUrl) $config.connectTimeoutSeconds
$responses=if($port){Invoke-CSRequestBatch $config @('https://www.cloudflare.com/cdn-cgi/trace','https://api.ipify.org','https://api.anthropic.com/v1/models')}else{@{}}
$watch.Stop()
$first='';$second=''
$trace=$responses['https://www.cloudflare.com/cdn-cgi/trace'];$ipify=$responses['https://api.ipify.org']
if($trace.Success -and $trace.HttpStatus -eq '200' -and $trace.Body -match '(?m)^ip=([^\r\n]+)'){$first=$Matches[1].Trim()}
if($ipify.Success -and $ipify.HttpStatus -eq '200'){$second=$ipify.Body.Trim()}
$tun=Get-CSExistingTunState $config
$state=New-CSLeakNetworkState $config $tun $port $first $second
[pscustomobject]@{
    ConcurrentHttpSeconds=[Math]::Round($watch.Elapsed.TotalSeconds,2)
    ProxyPortReady=$port
    CloudflareStatus=$trace.HttpStatus
    IpifyStatus=$ipify.HttpStatus
    AnthropicStatus=$responses['https://api.anthropic.com/v1/models'].HttpStatus
    EgressSourcesAgree=([bool]$first -and $first -eq $second)
    TunReady=$tun.Success
    StrictNetworkReady=$state.Ready
    BlockedReasons=@($state.Reasons|ForEach-Object {Protect-CSMessage $_})
    DnsStunProbesSent=$false
}|ConvertTo-Json -Depth 4
