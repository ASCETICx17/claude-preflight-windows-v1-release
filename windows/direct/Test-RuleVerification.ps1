$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'DirectBlock.ps1')
$script:passed=0
$script:testProgram='C:\Test App\Claude.exe'
function Reset-TestRule {
    $script:testRule=[pscustomobject]@{Group=$script:DBGroup;Enabled='True';Direction='Outbound';Action='Block';Profile='Any'}
    $script:testApp=$script:testProgram
    $script:testProtocol='Any'
    $script:testPort='Any'
    $script:testAddresses=$script:DBV4
}
function Assert-RuleTest([bool]$Condition,[string]$Message) {
    if(-not $Condition){throw "FAILED: $Message"}
    $script:passed++
}
function Get-NetFirewallRule {
    [CmdletBinding()]param([string]$Name,[string]$PolicyStore)
    return $script:testRule
}
function Get-NetFirewallApplicationFilter {
    [CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject)
    process{[pscustomobject]@{Program=$script:testApp}}
}
function Get-NetFirewallPortFilter {
    [CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject)
    process{[pscustomobject]@{Protocol=$script:testProtocol;RemotePort=$script:testPort}}
}
function Get-NetFirewallAddressFilter {
    [CmdletBinding()]param([Parameter(ValueFromPipeline)]$InputObject)
    process{[pscustomobject]@{RemoteAddress=$script:testAddresses}}
}
Reset-TestRule
Assert-RuleTest (Test-DBRule $script:testProgram 'IPv4') 'Exact active IPv4 block should pass.'
$script:testAddresses=$script:DBV6
Assert-RuleTest (Test-DBRule $script:testProgram 'IPv6') 'Exact active IPv6 block should pass.'
foreach($property in @('Enabled','Action','Direction','Profile','Group')) {
    Reset-TestRule
    $script:testRule.$property='Wrong'
    Assert-RuleTest (-not(Test-DBRule $script:testProgram 'IPv4')) "Unsafe rule property must fail: $property"
}
Reset-TestRule
$script:testApp='C:\Unrelated\Codex.exe'
Assert-RuleTest (-not(Test-DBRule $script:testProgram 'IPv4')) 'A rule for a different executable must fail.'
Reset-TestRule
$script:testProtocol='TCP'
Assert-RuleTest (-not(Test-DBRule $script:testProgram 'IPv4')) 'A TCP-only rule must not count as all-protocol coverage.'
Reset-TestRule
$script:testPort='443'
Assert-RuleTest (-not(Test-DBRule $script:testProgram 'IPv4')) 'A single-port rule must not count as complete coverage.'
Reset-TestRule
$script:testAddresses=@('10.0.0.0/8')
Assert-RuleTest (-not(Test-DBRule $script:testProgram 'IPv4')) 'An incomplete remote address range must fail.'
Reset-TestRule
$script:testAddresses=@('Any')
Assert-RuleTest (-not(Test-DBRule $script:testProgram 'IPv4')) 'A rule blocking loopback too must not match the intended policy.'
Reset-TestRule
$name4=Get-DBRuleName $script:testProgram 'IPv4'
$name6=Get-DBRuleName $script:testProgram 'IPv6'
$script:testRule|Add-Member NoteProperty Name $name4
Assert-RuleTest (Test-DBRule $script:testProgram 'IPv4' -Rule $script:testRule) 'An exact rule from a fresh snapshot must receive the same field validation.'
Assert-RuleTest (-not(Test-DBRule $script:testProgram 'IPv4' -Rule $null)) 'A missing snapshot entry must fail without a fallback.'
Assert-RuleTest (-not(Test-DBRule $script:testProgram 'IPv4' -Rule @($script:testRule,$script:testRule))) 'Duplicate snapshot entries must fail closed.'
$script:testRule.Name=$name6
Assert-RuleTest (-not(Test-DBRule $script:testProgram 'IPv4' -Rule $script:testRule)) 'A snapshot rule with the wrong exact name must be rejected.'
$script:batchCalls=0
function Get-NetFirewallRule {
    [CmdletBinding()]param([string[]]$Name,[string]$PolicyStore)
    $script:batchCalls++
    if($PolicyStore -ne 'ActiveStore'){throw 'Expected current effective policy.'}
    foreach($item in $Name){[pscustomobject]@{Name=$item}}
    [pscustomobject]@{Name='unrelated-rule'}
}
$snapshot=Get-DBRuleSet @($name4,$name6)
Assert-RuleTest ($script:batchCalls -eq 1 -and $snapshot.Count -eq 2) 'One ActiveStore query must cover all requested names while excluding unrelated rules.'
$null=Get-DBRuleSet @($name4,$name6)
Assert-RuleTest ($script:batchCalls -eq 2) 'A new verification must query again instead of reusing a stale snapshot.'
"Passed $script:passed active-rule validation assertions; no real firewall rules were changed."
