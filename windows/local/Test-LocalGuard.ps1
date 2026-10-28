$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'ClaudeLocalCore.ps1')
. (Join-Path $PSScriptRoot '..\..\tests\TestSupport.ps1')

$script:passed = 0
$script:started = 0
$script:running = $false
$script:port = $true
$script:throwOnStart = $false
$script:seenProxy = ''
$script:seenArguments = @()
$script:firewallReady = $true
$script:tunReady = $true
$script:localeReady = $true
function Get-CSLocaleState($Config) { [pscustomobject]@{Success=$script:localeReady;Detail='mock locale state'} }
function Get-CSExistingTunState($Config) { [pscustomobject]@{Success=$script:tunReady;Detail='mock TUN state'} }
function Get-DBVerification { [pscustomobject]@{verified=$script:firewallReady;checks=@([pscustomobject]@{program='C:\Mock App\Claude.exe'})} }

function Assert-Test([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw "FAILED: $Message" }
    $script:passed++
}

function Expect-Blocked([scriptblock]$Operation, [string]$Message) {
    $thrown = $false
    try { & $Operation } catch { $thrown = $true }
    Assert-Test $thrown $Message
}

# Mock all launch-side operations. These tests never launch or terminate a real app.
function Resolve-CSClaude($Config) { return 'C:\Mock App\Claude.exe' }
function Get-Process {
    [CmdletBinding()] param([string[]]$Name)
    if ($script:running) { [pscustomobject]@{ Name = 'Claude' } }
}
function Test-CSPort([uri]$Uri, [int]$Seconds) { return $script:port }
function Start-Process {
    [CmdletBinding()] param([string]$FilePath, [string[]]$ArgumentList)
    if ($script:throwOnStart) { throw 'simulated launch failure' }
    $script:started++
    $script:seenProxy = [Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Process')
    $script:seenArguments = $ArgumentList
}

$config = Get-CSConfig
$valid = @(
    (New-CSRow '代理内核' 'ok' 'mock' $true),
    (New-CSRow '本地代理' 'ok' 'mock' $true),
    (New-CSRow '代理出口' 'ok' 'mock' $true),
    (New-CSRow 'API 连接' 'ok' 'mock' $true),
    (New-CSRow '网页连接' 'warn' 'HTTP 403'),
    (New-CSRow 'Claude 安装' 'ok' 'mock' $true),
    (New-CSRow '启动状态' 'ok' 'mock' $true),
    (New-CSRow '系统设置' 'info' 'mock'),
    (New-CSRow '保护范围' 'info' 'mock')
)
foreach ($name in @('TUN网卡','固定IP','时区','地区语言','IPv6','DNS隧道','WebRTC','保镖','规则置顶','客户端语言')) {
    $valid += New-CSRow $name 'ok' 'mock' $true
}
$valid += New-CSRow '防直连规则' 'ok' 'mock' $true
$valid += New-CSRow '时区与语言' 'ok' 'mock' $true
$valid += New-CSRow 'DNS泄露' 'warn' 'mock' $false
$valid += New-CSRow 'WebRTC泄露' 'warn' 'mock' $false

Assert-Test (Test-CSFixedEgress $config.expectedEgressIP $config.expectedEgressIP $config) 'Both exact addresses must match.'
Assert-Test (-not (Test-CSFixedEgress '203.0.113.11' '203.0.113.11' $config)) 'A different address in the same documentation subnet must be blocked.'
Assert-Test (-not (Test-CSFixedEgress $config.expectedEgressIP '203.0.113.11' $config)) 'Disagreement between sources must be blocked.'
Assert-Test (-not (Test-CSFixedEgress '' '' $config)) 'Unknown egress must be blocked.'
Assert-Test (Test-CSFakeIP '198.19.0.1') 'The full Fake-IP /15 range must be recognized.'
Assert-Test (-not (Test-CSFakeIP '1.1.1.1')) 'A real DNS answer must not be mistaken for Fake-IP.'

Assert-CSCanLaunch $valid
Assert-Test $true 'Optional web warning must remain a warning, not a success assertion.'
Expect-Blocked { Assert-CSCanLaunch @() } 'Empty results must block.'
Expect-Blocked { Assert-CSCanLaunch @($valid | Select-Object -First 8) } 'Truncated results must block.'

foreach ($name in @($valid | Where-Object Required | Select-Object -ExpandProperty Name)) {
    $invalid = @($valid | ForEach-Object { New-CSRow $_.Name $_.Status $_.Detail $_.Required })
    ($invalid | Where-Object { $_.Name -eq $name }).Status = 'fail'
    Expect-Blocked { Invoke-CSLaunch $config $invalid } "Failed check must block: $name"
}
Assert-Test ($script:started -eq 0) 'No failed preflight may launch an app.'
$missingTun=@($valid|Where-Object {$_.Name -ne 'TUN网卡'})
Expect-Blocked { Assert-CSCanLaunch $missingTun } 'Omitting TUN from direct-mode results must block.'
foreach($missing in @('DNS泄露','WebRTC泄露')){
    Assert-CSCanLaunch @($valid|Where-Object Name -ne $missing)
    Assert-Test $true 'An advisory result may still be pending without blocking required checks.'
}

$script:stunValue = $null
function Get-CSStunAddress([string]$HostName,[int]$Port) { return $script:stunValue }
Assert-Test ((Test-CSStun $config).Status -eq 'fail') 'No STUN replies must mean unknown, never safe.'
$script:stunValue = '203.0.113.11'
Assert-Test ((Test-CSStun $config).Status -eq 'fail') 'STUN address outside the exact whitelist must fail.'
$script:stunValue = $config.expectedEgressIP
Assert-Test ((Test-CSStun $config).Status -eq 'ok') 'Matching STUN results may pass the probe check.'

$duplicate = @($valid) + @($valid[0])
Expect-Blocked { Assert-CSCanLaunch $duplicate } 'Duplicate mandatory results must block.'
$script:running = $true
Expect-Blocked { Invoke-CSLaunch $config $valid } 'An existing Claude process must not be reused or killed.'
$script:running = $false
$script:firewallReady = $false
Expect-Blocked { Invoke-CSLaunch $config $valid } 'Firewall rules removed after preflight must block launch.'
$script:firewallReady = $true
$script:tunReady = $false
Expect-Blocked { Invoke-CSLaunch $config $valid } 'TUN stopped after preflight must block even with a working proxy.'
$script:tunReady = $true
$missingLocale=@($valid|Where-Object {$_.Name -ne '时区与语言'})
Expect-Blocked { Assert-CSCanLaunch $missingLocale } 'Missing locale result must block.'
$script:localeReady=$false
Expect-Blocked { Invoke-CSLaunch $config $valid } 'Locale changed after preflight must block.'
$script:localeReady=$true
$script:port = $false
Expect-Blocked { Invoke-CSLaunch $config $valid } 'A proxy that disconnects after preflight must block.'
$script:port = $true

$original = @{}
foreach ($name in @('HTTP_PROXY', 'HTTPS_PROXY', 'NO_PROXY')) {
    $original[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    [Environment]::SetEnvironmentVariable('HTTPS_PROXY', 'http://previous.invalid:1', 'Process')
    Invoke-CSLaunch $config $valid
    Assert-Test ($script:started -eq 1) 'A successful preflight must launch exactly once.'
    Assert-Test ($script:seenProxy -eq $config.proxyUrl) 'The launched child must inherit the explicit HTTP proxy.'
    Assert-Test ($script:seenArguments -contains "--proxy-server=$($config.proxyUrl)") 'The desktop process must receive a proxy argument.'
    Assert-Test ($script:seenArguments -contains "--lang=$($config.expectedCulture)") 'Launch language must derive from the sole configured culture.'
    Assert-Test ([Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Process') -eq 'http://previous.invalid:1') 'The launcher must restore its prior environment.'
    $script:throwOnStart = $true
    Expect-Blocked { Invoke-CSLaunch $config $valid } 'Launch failures must be reported.'
    Assert-Test ([Environment]::GetEnvironmentVariable('HTTPS_PROXY', 'Process') -eq 'http://previous.invalid:1') 'Launch failures must also restore the prior environment.'
} finally {
    foreach ($name in $original.Keys) { [Environment]::SetEnvironmentVariable($name, $original[$name], 'Process') }
}

"Passed $script:passed launch-guard assertions; no real application or account data was touched."
