$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\local\Configuration.ps1')
$fixturePath=Join-Path $PSScriptRoot 'public-fixture.json'
$script:passed=0
function New-Fixture { Convert-CSRuntimeConfig (Get-Content -LiteralPath $fixturePath -Raw -Encoding UTF8|ConvertFrom-Json) }
function Assert-Config([bool]$Condition,[string]$Message){
    if(-not $Condition){throw ('FAILED: '+$Message)}
    $script:passed++
}
function Expect-ConfigBlock([scriptblock]$Operation,[string]$Message){
    $blocked=$false
    try{& $Operation|Out-Null}catch{$blocked=$true}
    Assert-Config $blocked $Message
}
$config=New-Fixture
Assert-Config (@(Get-CSConfigurationIssues $config).Count -eq 0) 'Public fictional fixture must be valid.'
foreach($url in @('http://127.0.0.1:','http://127.0.0.1','http://127.0.0.1:0','http://127.0.0.1:99999','https://127.0.0.1:12345','http://example.invalid:12345','http://[::1]:12345','http://user:pass@127.0.0.1:12345','http://127.0.0.1:12345/path','http://127.0.0.1:12345/?secret=1')){
    $invalid=New-Fixture;$invalid.proxyUrl=$url
    Assert-Config (@(Get-CSConfigurationIssues $invalid).Count -gt 0) 'Nonlocal or credential-bearing proxy must fail.'
}
foreach($ip in @('','155.1','::1','999.0.0.1','203.0.113.*')){
    $invalid=New-Fixture;$invalid.expectedEgressIP=$ip
    Assert-Config (@(Get-CSConfigurationIssues $invalid).Count -gt 0) 'Invalid or partial IPv4 whitelist must fail.'
}
foreach($path in @('','v2rayN','D:Apps','\\server\share')){
    $invalid=New-Fixture;$invalid.proxyRoot=$path
    Assert-Config (@(Get-CSConfigurationIssues $invalid).Count -gt 0) 'Only local absolute proxy folders are allowed.'
}
$invalid=New-Fixture;$invalid.existingTunName='tun*'
Assert-Config (@(Get-CSConfigurationIssues $invalid).Count -gt 0) 'Wildcard adapter names must fail.'
Assert-Config (-not (Get-CSLocalePairIssue 'Taipei Standard Time' 'zh-TW')) 'Taipei must allow zh-TW.'
Assert-Config ([bool](Get-CSLocalePairIssue 'Taipei Standard Time' 'en-US')) 'Taipei paired with US culture must fail.'
Assert-Config (-not (Get-CSLocalePairIssue 'Singapore Standard Time' 'en-SG')) 'Singapore must allow en-SG.'
Assert-Config (-not (Get-CSLocalePairIssue 'Singapore Standard Time' 'zh-SG')) 'Singapore must allow zh-SG.'
Assert-Config (-not (Get-CSLocalePairIssue 'China Standard Time' 'zh-CN')) 'Mainland warning must be advisory rather than a selection ban.'
$catalog=@(Get-CSLocaleCatalog)
Assert-Config (@($catalog|Where-Object {-not $_.Selectable}).Count -eq 0) 'All recognized zones must remain selectable.'
$recommended=@($catalog|Where-Object Recommended)
Assert-Config (@($recommended.Region|Sort-Object -Unique).Count -eq 3 -and @($recommended|Where-Object {$_.Region -notin @('US','TW','SG')}).Count -eq 0) 'Only US, Taipei and Singapore may be recommended.'
$warnings=@($catalog|Where-Object Recommendation -eq 'warning')
Assert-Config ($warnings.Count -eq 1 -and $warnings[0].Id -eq 'China Standard Time' -and $warnings[0].Color -eq '#E8B95F') 'Only mainland must carry the yellow warning.'
$neutral=@($catalog|Where-Object Recommendation -eq 'neutral')
Assert-Config (@($neutral|Where-Object {$_.Label -match '^(不推荐|推荐)' -or $_.EnforceCulturePair -or $_.Color -eq '#E8B95F'}).Count -eq 0) 'Other regions must be unmarked and free of inferred language pairing.'
Assert-Config (-not (Get-CSLocalePairIssue 'GMT Standard Time' 'ja-JP')) 'Neutral timezone must accept a recognized language without country inference.'
Assert-Config (-not (Get-CSLocalePairIssue 'Tokyo Standard Time' 'en-US')) 'Other zones must not be rejected by the previous whitelist.'
Assert-Config ([bool](Get-CSLocalePairIssue 'Eastern Standard Time' 'en-CA')) 'US preset must use en-US.'
Assert-Config ([bool](Get-CSLocalePairIssue 'Unknown Example Zone' 'en-US')) 'Unrecognized timezone identifiers must fail.'
Assert-Config ([bool](Get-CSLocalePairIssue 'GMT Standard Time' 'unknown-example')) 'Unrecognized language identifiers must fail.'
$london=$catalog|Where-Object Id -eq 'GMT Standard Time'
Assert-Config (@(Get-CSCultureChoices $london|Where-Object {$_.Name -in @('ja-JP','en-US','zh-TW')}).Count -eq 3) 'Neutral zones must expose the system culture catalogue.'
foreach($item in $catalog|Where-Object EnforceCulturePair){
    foreach($culture in $item.Cultures){Assert-Config (-not (Get-CSLocalePairIssue $item.Id $culture)) 'Every public preset pairing must validate.'}
}
$script:mockZone='Taipei Standard Time';$script:mockCulture='zh-TW';$script:localeReadFails=$false
function Get-TimeZone {
    [CmdletBinding()]param()
    if($script:localeReadFails){throw 'mock failure'}
    [pscustomobject]@{Id=$script:mockZone}
}
function Get-Culture { [CmdletBinding()]param();[pscustomobject]@{Name=$script:mockCulture} }
Assert-Config (Get-CSLocaleState $config).Success 'Matching actual settings must pass.'
$script:mockZone='Singapore Standard Time'
Assert-Config (-not (Get-CSLocaleState $config).Success) 'Actual Windows timezone mismatch must fail.'
$script:mockZone='Taipei Standard Time';$script:mockCulture='zh-CN'
Assert-Config (-not (Get-CSLocaleState $config).Success) 'Actual Windows regional format mismatch must fail.'
$script:mockCulture='zh-TW';$config.clientLanguage='en-US'
Assert-Config (-not (Get-CSLocaleState $config).Success) 'Derived launch language disagreement must fail.'
$config=New-Fixture;$script:localeReadFails=$true
Assert-Config (-not (Get-CSLocaleState $config).Success) 'Unreadable system locale must fail closed.'
$script:localeReadFails=$false;$script:mockZone='GMT Standard Time';$script:mockCulture='ja-JP'
$neutralConfig=New-Fixture;$neutralConfig.expectedTimeZone='GMT Standard Time';$neutralConfig.expectedCulture='ja-JP';$neutralConfig.clientLanguage='ja-JP'
Assert-Config (Get-CSLocaleState $neutralConfig).Success 'Neutral region must pass when actual settings match the stored choices.'
$message=Protect-CSMessage 'fixture 203.0.113.10 C:\Users\Example\private S-1-5-21-111-222-333-444'
Assert-Config ($message -notmatch '203\.0\.113\.10|C:\\Users|S-1-5-21') 'IP, path and account identifiers must be redacted.'
# Use a synthetic owner and isolated temporary directory; never touch local settings.
$testFolder=Join-Path ([IO.Path]::GetTempPath()) ('CSConfigTest-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($testFolder)
$originalRoot=$script:CSConfigurationRoot
function Get-CSOwnerSid {'S-1-5-21-111-222-333-444'}
try{
    $script:CSConfigurationRoot=$testFolder
    Copy-Item -LiteralPath (Join-Path $originalRoot 'settings.example.json') -Destination (Join-Path $testFolder 'settings.example.json')
    Expect-ConfigBlock {Get-CSConfig} 'Fresh blank template must block.'
    $saved=Save-CSConfig (New-Fixture)
    Assert-Config ($saved.clientLanguage -eq $saved.expectedCulture) 'Language must derive from the single persisted field.'
    $raw=Get-Content -LiteralPath (Get-CSConfigPath) -Raw|ConvertFrom-Json
    Assert-Config ('clientLanguage' -notin $raw.PSObject.Properties.Name) 'Derived language must not be duplicated in the private file.'
    Assert-Config ($raw.ownerSid -eq (Get-CSOwnerSid)) 'Owner belongs in the single private file.'
    $withDns=New-Fixture;$withDns.allowedDnsResolverIPs=@('198.51.100.53','2001:db8::53')
    $saved=Save-CSConfig $withDns
    Assert-Config (@($saved.allowedDnsResolverIPs).Count -eq 2) 'DNS allowed addresses must round-trip through the same private file.'
    $badDns=New-Fixture;$badDns.allowedDnsResolverIPs=@('example.invalid')
    Expect-ConfigBlock {Save-CSConfig $badDns} 'DNS allowlist must reject hostnames.'
    $badDns.allowedDnsResolverIPs=@('198.51.100.0/24')
    Expect-ConfigBlock {Save-CSConfig $badDns} 'DNS allowlist must reject CIDR.'
    $badDns.allowedDnsResolverIPs=@(1..33|ForEach-Object {'198.51.100.'+$_})
    Expect-ConfigBlock {Save-CSConfig $badDns} 'DNS allowlist size must be bounded.'
    Assert-Config (@(Get-ChildItem -LiteralPath $testFolder -File|Where-Object Name -ne 'settings.example.json').Count -eq 1) 'Saving must create exactly one private file with no backup or cache.'
    $prior=[IO.File]::ReadAllText((Get-CSConfigPath))
    $invalid=New-Fixture;$invalid.expectedEgressIP=''
    Expect-ConfigBlock {Save-CSConfig $invalid} 'Invalid input must not save.'
    Assert-Config ([IO.File]::ReadAllText((Get-CSConfigPath)) -eq $prior) 'Invalid save must preserve the previous file.'
    $rootFixture=New-Fixture;$rootFixture.proxyRoot='D:\'
    Assert-Config ((Save-CSConfig $rootFixture).proxyRoot -eq 'D:\') 'Drive-root directory must not become drive-relative.'
    [IO.File]::WriteAllText((Get-CSConfigPath),'{broken')
    Expect-ConfigBlock {Get-CSConfig} 'Corrupted config must block.'
    [IO.File]::WriteAllText((Get-CSConfigPath),'{"schemaVersion":99}')
    Expect-ConfigBlock {Get-CSConfig} 'Unknown schema must block.'
}finally{
    $script:CSConfigurationRoot=$originalRoot
    # Exact file cleanup only inside the just-created test directory.
    Remove-Item -LiteralPath (Join-Path $testFolder 'settings.json'),(Join-Path $testFolder 'settings.example.json') -Force -ErrorAction SilentlyContinue
    [IO.Directory]::Delete($testFolder)
}
"Passed $script:passed configuration and locale assertions; only fictional temporary files were used."
