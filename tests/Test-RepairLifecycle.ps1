$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\direct\Invoke-Admin.ps1')
$script:passed=0
function Assert-Repair([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAILED: '+$Message)};$script:passed++}
function Expect-RepairBlock([scriptblock]$Action,[string]$Message){$blocked=$false;try{& $Action|Out-Null}catch{$blocked=$true};Assert-Repair $blocked $Message}
$owned=Join-Path ([IO.Path]::GetTempPath()) ('GuardRepairTest-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($owned)
$originalRoot=$script:CSRepairRoot;$script:CSRepairRoot=$owned
try{
    $id=[guid]::NewGuid().ToString('D')
    Initialize-CSRepairOperation $id 'Probe'
    $state=Get-CSRepairState $id
    Assert-Repair ($state.Phase -eq 'requesting' -and -not $state.Elevated) 'A new request must start without assuming admin access.'
    Assert-Repair (-not(Get-CSRepairState ([guid]::NewGuid().ToString('D')))) 'Old or different request IDs must not be consumed.'
    Assert-Repair (-not(Get-CSRepairTimeoutReason $state 44)) 'Authorization must have a bounded opportunity to finish.'
    Assert-Repair ([bool](Get-CSRepairTimeoutReason $state 45)) 'A missing prompt must not wait for hundreds of seconds.'
    Set-CSRepairPhase $id 'elevated'
    Assert-Repair (Get-CSRepairState $id).Elevated 'An actual-token handshake must separate authorization from later work.'
    Set-CSRepairPhase $id 'network-test'
    Assert-Repair ((Get-CSRepairPhaseText (Get-CSRepairState $id)) -match '已获管理员权限.*对照测试') 'Network testing must not still be labelled waiting for consent.'
    Assert-Repair (-not(Get-CSRepairTimeoutReason (Get-CSRepairState $id) 100)) 'Authorized work uses a separate longer limit.'
    Assert-Repair ([bool](Get-CSRepairTimeoutReason (Get-CSRepairState $id) 180)) 'Authorized work must also have a finite limit.'
    Cancel-CSRepairOperation $id 'fixture timeout'
    Expect-RepairBlock {Set-CSRepairPhase $id 'elevated'} 'Late consent must not revive a cancelled request.'
    Expect-RepairBlock {Assert-CSRepairActive $id} 'Cancelled work must stop at mutation checkpoints.'
    Expect-RepairBlock {Initialize-CSRepairOperation 'not-a-guid' 'Probe'} 'Malformed request IDs must be rejected.'
    $id=[guid]::NewGuid().ToString('D');Initialize-CSRepairOperation $id 'Probe'
    function Test-CSAdminToken {$false}
    Assert-Repair ((Invoke-CSAdminEntry 'Probe' $true $id) -eq 1) 'An Elevated flag alone cannot grant privileges.'
    Assert-Repair ((Get-CSRepairState $id).Phase -eq 'failed') 'Missing real admin token must have an explicit error.'
    $id=[guid]::NewGuid().ToString('D');Initialize-CSRepairOperation $id 'Probe'
    function Test-CSAdminToken {$true}
    function Invoke-CSAdminRuleAction {throw 'Rule mutation must not run in a probe'}
    Assert-Repair ((Invoke-CSAdminEntry 'Probe' $true $id) -eq 0) 'A token-only probe must complete without running any rule action.'
    Assert-Repair ((Get-CSRepairState $id).Succeeded) 'A successful probe must be distinguished from an application failure.'
    $id=[guid]::NewGuid().ToString('D');Initialize-CSRepairOperation $id 'Apply'
    function Invoke-CSAdminRuleAction {throw 'fixture apply failed'}
    Assert-Repair ((Invoke-CSAdminEntry 'Apply' $true $id) -eq 1) 'Rule failures must propagate as a nonzero result.'
    Assert-Repair ((Get-CSRepairState $id).Error -match 'fixture apply failed') 'The actual safe failure reason must reach the UI.'
    $id=[guid]::NewGuid().ToString('D');Initialize-CSRepairOperation $id 'Probe'
    function Test-CSAdminToken {$false}
    function Start-Process {throw (New-Object ComponentModel.Win32Exception(1223))}
    Assert-Repair ((Invoke-CSAdminEntry 'Probe' $false $id) -eq 1) 'Cancelled Windows consent must return failure.'
    Assert-Repair ((Get-CSRepairState $id).Error -match '被取消') 'Consent cancellation must not be a vague connection rejection.'
    $raw=[IO.File]::ReadAllText((Get-CSRepairStatePath))
    Assert-Repair ($raw -notmatch 'proxyUrl|expectedEgressIP|ownerSid') 'Transient operation status must not duplicate personal configuration.'
}finally{
    $script:CSRepairRoot=$originalRoot
    $full=[IO.Path]::GetFullPath($owned)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')+'\GuardRepairTest-'
    if(-not $full.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe test cleanup path.'}
    Remove-Item -LiteralPath $full -Recurse -Force
}
"Passed $script:passed admin-lifecycle assertions; no real elevation or firewall changes."
