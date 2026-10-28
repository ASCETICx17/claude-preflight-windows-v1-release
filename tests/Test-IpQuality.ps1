$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\local\ClaudeLocalCore.ps1')
. (Join-Path $PSScriptRoot 'TestSupport.ps1')
$script:passed=0
function Assert-Quality([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAILED: '+$Message)};$script:passed++}
foreach($inputValue in @('203.0.113.10','https://scamalytics.com/ip/203.0.113.10','https://iprisk.top/ip/203.0.113.10?lang=zh','https://example.com/report?ip=203.0.113.10')){
    Assert-Quality ((Convert-CSQualityTarget $inputValue) -eq '203.0.113.10') 'Input must extract exactly the requested public IP without fetching its host.'
}
Assert-Quality ((Convert-CSQualityTarget '2606:4700:4700::1111') -eq '2606:4700:4700::1111') 'Full IPv6 inputs must be supported.'
foreach($inputValue in @('127.0.0.1','192.168.0.1','100.64.0.1','fe80::1','::1','198.18.0.1','2130706433','example.com','203.0.113.10/24','203.0.113.10" -Json','https://a:b@example.com/ip/203.0.113.10','https://example.com/203.0.113.10/203.0.113.11')){
    $rejected=$false;try{$null=Convert-CSQualityTarget $inputValue}catch{$rejected=$true}
    Assert-Quality $rejected 'Private, malformed, credential-bearing and ambiguous input must not issue a request.'
}
function Response($Data){[pscustomobject]@{Success=$true;HttpStatus=200;Body=($Data|ConvertTo-Json -Depth 6 -Compress)}}
$goodQuery=[pscustomobject]@{ip='203.0.113.10';risk=[pscustomobject]@{risk_score=0;is_proxy=$false;is_datacenter=$true}}
$query=Convert-CSQualityResult 'IPQuery' '203.0.113.10' (Response $goodQuery)
Assert-Quality ($query.State -eq 'ok' -and $query.Score -eq 0) 'A genuine numeric zero must display as zero.'
Assert-Quality ($query.Signals -contains 'datacenter') 'Provider labels must accompany the score.'
Assert-Quality ($query.Detail -match '机房' -and $query.Detail -match '不代表') 'A low score must retain a separate datacenter warning.'
foreach($badScore in @($null,'0',-1,101,$true)){
    $goodQuery.risk.risk_score=$badScore
    $bad=Convert-CSQualityResult 'IPQuery' '203.0.113.10' (Response $goodQuery)
    Assert-Quality ($bad.State -eq 'unavailable' -and $null -eq $bad.Score) 'Missing or invalid score must not silently cast to zero.'
}
$goodQuery.risk.risk_score=20;$goodQuery.ip='203.0.113.11'
Assert-Quality ((Convert-CSQualityResult 'IPQuery' '203.0.113.10' (Response $goodQuery)).State -eq 'unavailable') 'Mismatched response targets must be rejected.'
Assert-Quality ((Convert-CSQualityResult 'IPQuery' '203.0.113.10' ([pscustomobject]@{Success=$true;Body='<html>verification</html>'})).State -eq 'unavailable') 'A verification page must not count as a scored result.'
$limited=Convert-CSQualityResult 'IPQuery' '203.0.113.10' ([pscustomobject]@{Success=$false;HttpStatus=429;Body=''})
Assert-Quality ($limited.State -eq 'unavailable' -and $limited.Detail -match '限额') 'Rate limiting must show unavailable.'
$script:started=@();$script:waited=0
function Start-CSQualityRequest($Config,[string]$Url){$script:started+=$Url;[pscustomobject]@{Url=$Url}}
function Wait-CSQualityRequest($Request){
    Assert-Quality ($script:started.Count -eq 1) 'Only the selected anonymous provider may be contacted.'
    $script:waited++
    $goodQuery.ip='203.0.113.10';return (Response $goodQuery)
}
$report=Invoke-CSQualityCheck (Get-CSConfig) 'https://untrusted.invalid/report?ip=203.0.113.10&token=DO_NOT_FORWARD'
Assert-Quality ($report.Target -eq '203.0.113.10' -and $report.Results.Count -eq 1) 'The active provider result must be returned.'
Assert-Quality ($script:waited -eq 1 -and @($script:started|Where-Object {$_ -match 'untrusted|DO_NOT_FORWARD'}).Count -eq 0) 'Pasted host and parameters must never reach the API.'
Assert-Quality (@($script:started|Where-Object {$_ -notmatch '^https://api\.ipquery\.io/203\.0\.113\.10$'}).Count -eq 0) 'IP99 and undocumented CV endpoints must never be queried.'
$script:started=@()
function Wait-CSQualityRequest($Request){[pscustomobject]@{Success=$false;HttpStatus=0;Body=''}}
$unavailable=Invoke-CSQualityCheck (Get-CSConfig) '203.0.113.10'
Assert-Quality (@($unavailable.Results|Where-Object State -eq 'unavailable').Count -eq 1) 'A failed proxy must leave the source unavailable with no direct fallback.'
Assert-Quality (-not (Test-Path (Join-Path $PSScriptRoot '..\windows\local\settings.json'))) 'Quality mocks must not create personal config.'
"Passed $script:passed IP quality assertions; no live requests, key or query history."
