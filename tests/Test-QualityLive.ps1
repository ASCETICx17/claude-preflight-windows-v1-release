param([Parameter(Mandatory=$true)][string]$SettingsPath)
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\local\ClaudeLocalCore.ps1')
$config=Convert-CSRuntimeConfig (Get-Content -LiteralPath $SettingsPath -Raw -Encoding UTF8|ConvertFrom-Json)
if(@(Get-CSConfigurationIssues $config).Count){throw 'Configuration is incomplete.'}
# Public fixture only; never query or print the user's actual exit IP.
$report=Invoke-CSQualityCheck $config '8.8.8.8'
if($report.Results.Count -ne 1 -or @($report.Results|Where-Object {$_.State -ne 'ok' -or $null -eq $_.Score}).Count){throw 'The anonymous provider is unavailable.'}
$report.Results|Select-Object Provider,State,Score,DataTime|ConvertTo-Json
'Passed 1 anonymous live provider check through the configured proxy; no DNS/STUN probes or system changes.'
