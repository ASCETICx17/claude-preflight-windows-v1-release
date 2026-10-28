$ErrorActionPreference='Stop'
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$suites=@(
    'windows\local\Test-LocalGuard.ps1',
    'windows\direct\Test-RuleVerification.ps1',
    'windows\direct\Test-TunGuard.ps1',
    'windows\direct\Test-UpgradeGuard.ps1',
    'tests\Test-Configuration.ps1',
    'tests\Test-SettingsUI.ps1',
    'tests\Test-AdvisoryUI.ps1',
    'tests\Test-PublicExport.ps1',
    'tests\Test-LeakChecks.ps1',
    'tests\Test-LeakDiagnostics.ps1',
    'tests\Test-DnsRecovery.ps1',
    'tests\Test-ProbeBudget.ps1',
    'tests\Test-LeakInterpretation.ps1',
    'tests\Test-IpQuality.ps1',
    'tests\Test-ParallelChecks.ps1',
    'tests\Test-RepairLifecycle.ps1'
)
foreach($suite in $suites){
    & (Join-Path $PSHOME 'powershell.exe') -NoProfile -STA -ExecutionPolicy Bypass -File (Join-Path $project $suite)
    if($LASTEXITCODE -ne 0){throw ('验证失败：'+$suite)}
}
'All mock suites passed. No live Claude session or system firewall was changed.'
