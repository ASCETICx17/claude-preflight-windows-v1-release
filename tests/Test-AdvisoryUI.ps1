$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\local\ClaudeLocalUI.ps1') -ValidateOnly
$config=Convert-CSRuntimeConfig (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'public-fixture.json') -Raw -Encoding UTF8|ConvertFrom-Json)
$config.allowedDnsResolverIPs=@()
$script:passed=0;$script:probeStarts=0
function Assert-Advisory([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAILED: '+$Message)};$script:passed++}
Add-Type -TypeDefinition 'public static class AdvisoryFixture { public static System.Threading.ManualResetEvent Dns = new System.Threading.ManualResetEvent(false); public static System.Threading.ManualResetEvent Rtc = new System.Threading.ManualResetEvent(false); }'
function Start-CSLeakTask($Config,[string]$Kind,[bool]$CheckProxy=$false){
    $script:probeStarts++
    $shell=[PowerShell]::Create()
    $null=$shell.AddScript(@'
param($Kind)
$gate=if($Kind -eq 'Dns'){[AdvisoryFixture]::Dns}else{[AdvisoryFixture]::Rtc}
if(-not $gate.WaitOne(5000)){throw 'Fixture was not released.'}
$name=if($Kind -eq 'Dns'){'DNS泄露'}else{'WebRTC泄露'}
[pscustomobject]@{Name=$name;State=$(if($Kind -eq 'Dns'){'unknown'}else{'fail'});Detail='fixture advisory';Addresses=@('198.51.100.53');Scope='fixture';Attempted=$true;CheckedUtc='fixture';Evidence=[pscustomobject]@{ReportValid=$true;ControlMatchesPinned=$false}}
'@).AddArgument($Kind)
    [pscustomobject]@{Shell=$shell;Handle=$shell.BeginInvoke();Kind=$Kind;Started=[DateTime]::UtcNow}
}
try{
    Set-CSForm $config;$script:dirty=$false;$script:hardDirty=$false
    $script:ui.LaunchButton.IsEnabled=$true
    $script:ui.StateText.Text='Required checks keep their independent result.'
    Start-CSAdvisories $config
    Assert-Advisory ($script:advisoryTasks.Count -eq 2 -and $script:probeStarts -eq 2) 'Both probes must start without waiting for either result.'
    Assert-Advisory $script:ui.LaunchButton.IsEnabled 'Pending background probes must not disable an eligible launch.'
    Assert-Advisory ($script:ui.DnsObservedBox.Text -match '正在等待' -and $script:ui.LeakProgressText.Text -match '30') 'Pending probes must explain their independent bounded wait.'
    Start-CSAdvisories $config
    Assert-Advisory ($script:probeStarts -eq 2) 'A check or launch during the same observation must reuse it, not start duplicate probes.'
    [void][AdvisoryFixture]::Dns.Set()
    Assert-Advisory ($script:advisoryTasks['Dns'].Handle.AsyncWaitHandle.WaitOne(2000)) 'DNS fixture must complete independently.'
    Update-CSAdvisories
    Assert-Advisory ($script:advisoryTasks.Count -eq 1 -and $script:ui.DnsObservedBox.Text -eq '198.51.100.53') 'DNS must be displayed while WebRTC is still pending.'
    Assert-Advisory ($script:dirty -and -not $script:hardDirty -and $script:ui.DnsAllowBox.Text -eq '198.51.100.53') 'Automatic DNS draft must be unsaved but must not become a mandatory-config edit.'
    Assert-Advisory $script:ui.LaunchButton.IsEnabled 'An advisory draft must not indirectly block launch.'
    Assert-Advisory ($script:ui.DnsDraftStatus.Text -match 'HTTP 出口未匹配') 'An automatically populated HTTP-mismatched draft must retain its warning.'
    Assert-Advisory ($script:ui.StateText.Text -eq 'Required checks keep their independent result.') 'Late advisory data must not overwrite required-check results.'
    [void][AdvisoryFixture]::Rtc.Set()
    Assert-Advisory ($script:advisoryTasks['WebRtc'].Handle.AsyncWaitHandle.WaitOne(2000)) 'WebRTC fixture must complete independently.'
    Update-CSAdvisories
    Assert-Advisory ($script:advisoryTasks.Count -eq 0 -and $script:ui.LeakRunButton.IsEnabled) 'The UI must permit a new observation after both probes finish.'
    Assert-Advisory ($script:ui.RtcResultText.Foreground.ToString() -eq '#FFE8B95F' -and $script:ui.RtcResultText.Text -match '异常提醒') 'A real abnormal observation must remain visible in yellow, never silently green.'
    Assert-Advisory (@($script:ui.ChecksList.ItemsSource|Where-Object {$_.Name -eq 'WebRTC泄露' -and $_.Icon -eq '!'}).Count -eq 1) 'The dashboard must receive the same yellow abnormal result.'
    Assert-Advisory $script:ui.LaunchButton.IsEnabled 'A late abnormal observation must not revoke launch eligibility.'
    [void][AdvisoryFixture]::Dns.Reset();[void][AdvisoryFixture]::Rtc.Reset()
    Start-CSAdvisories $config
    $script:ui.IpBox.Text='203.0.113.11'
    Assert-Advisory ($script:advisoryTasks.Count -eq 0 -and -not $script:advisoryContext -and $script:hardDirty -and -not $script:ui.LaunchButton.IsEnabled) 'Changing a required pin must cancel old probes and block launch.'
    Assert-Advisory ($script:ui.DnsObservedBox.Text -eq '尚未检测' -and -not $script:ui.FillDnsButton.IsEnabled) 'Old-network results must be cleared and cannot seed a new pin.'
    [void][AdvisoryFixture]::Dns.Set();[void][AdvisoryFixture]::Rtc.Set()
    Close-CSAdvisories
    Assert-Advisory ($script:advisoryRetired.Count -eq 0) 'Cancelled runspaces must be disposed on close.'
    Set-CSForm $config;$script:dirty=$false;$script:hardDirty=$false;$script:ui.LaunchButton.IsEnabled=$true
    [void][AdvisoryFixture]::Dns.Reset();[void][AdvisoryFixture]::Rtc.Reset()
    Start-CSAdvisories $config
    foreach($task in $script:advisoryTasks.Values){$task.Started=[DateTime]::UtcNow.AddSeconds(-31)}
    $watch=[Diagnostics.Stopwatch]::StartNew();Update-CSAdvisories;$watch.Stop()
    Assert-Advisory ($watch.Elapsed.TotalSeconds -lt 2 -and $script:advisoryTasks.Count -eq 0) 'Total-budget expiration must cancel asynchronously rather than freeze the UI waiting for a worker.'
    Assert-Advisory ($script:advisoryResults.Dns.State -eq 'unknown' -and $script:ui.DnsResultText.Text -match '30 秒' -and $script:ui.LaunchButton.IsEnabled) 'Deadline expiry must remain an explicit yellow unknown without revoking launch.'
    Assert-Advisory ($script:ui.DnsDraftStatus.Text -match '无法自动填入' -and $script:ui.DnsDraftStatus.Text -match '不影响启动') 'An empty timeout must explain why autofill is unavailable without demanding manual DNS input.'
}finally{
    [void][AdvisoryFixture]::Dns.Set();[void][AdvisoryFixture]::Rtc.Set()
    Close-CSAdvisories;$script:timer.Stop();$script:window.Close()
}
"Passed $script:passed asynchronous advisory UI assertions; local runspaces only, no network or app launch."
