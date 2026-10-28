$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\local\ClaudeLocalUI.ps1') -ValidateOnly
$fixture=Convert-CSRuntimeConfig (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'public-fixture.json') -Raw -Encoding UTF8|ConvertFrom-Json)
$script:passed=0
function Assert-UI([bool]$Condition,[string]$Message){
    if(-not $Condition){throw ('FAILED: '+$Message)}
    $script:passed++
}
Assert-UI ($script:window.WindowState -eq 'Maximized') 'Default app opening must be maximized.'
Assert-UI ($script:window.Title -match '^Claude Preflight') 'The current window must use the new project name.'
Assert-UI ($script:ui.SaveButton.MinWidth -ge 220 -and $script:ui.SaveButton.MinHeight -ge 64) 'Save must provide a larger click target.'
Assert-UI ($script:ui.ZoneRecommendationText.Text -eq '推荐新加坡、台北、美国。') 'Static timezone hint must omit mainland and neutral-region commentary.'
Assert-UI ($script:ui.ManualSitesGrid.Rows -eq 2 -and $script:ui.ManualSitesGrid.Columns -eq 2 -and $script:ui.ManualSitesGrid.Children.Count -eq 4) 'The four manual websites must form a uniform two by two block.'
Assert-UI (-not $xaml.OuterXml.Contains('风险 / 欺诈分建议尽量为 0')) 'The requested bottom fine print must be removed.'
Set-CSForm $fixture
Show-CSQuality -FromSettings
Assert-UI ($script:ui.QualityPanel.Visibility -eq 'Visible' -and $script:ui.QualityTargetBox.Text -eq $fixture.expectedEgressIP) 'Optional quality page must take the visible IP without changing the configured pin.'
Set-CSQualityDisplay ([pscustomobject]@{Target='203.0.113.10';Results=@([pscustomobject]@{Provider='IPQuery';State='ok';Score=0;Detail='fixture';Signals=@();DataTime='fixture';CheckedUtc='fixture'})})
Assert-UI ($script:ui.IpQueryScoreText.Text -eq '0 / 100') 'A real zero must remain distinct from unavailable data.'
Set-CSQualityDisplay $null
Assert-UI ($script:ui.IpQueryScoreText.Text -eq '—') 'A new quality check must clear stale scores.'
Show-CSPage $true
Assert-UI ($script:ui.QualityPanel.Visibility -eq 'Collapsed') 'Configuration navigation must hide optional quality results.'
Assert-UI ((Get-CSFormConfig).expectedCulture -eq 'zh-TW') 'Form must preserve configured language.'
Show-CSLeaks
Assert-UI ($script:ui.LeaksPanel.Visibility -eq 'Visible' -and $script:ui.SettingsPanel.Visibility -eq 'Collapsed') 'Diagnostics navigation must show only the leak page.'
Show-CSPage $true
$script:ui.DnsAllowBox.Text='198.51.100.53, 2001:db8::53'
Assert-UI (@((Get-CSFormConfig).allowedDnsResolverIPs).Count -eq 2) 'DNS field must parse IPv4 and IPv6 into the central form data.'
$script:ui.DnsAllowBox.Text='invalid.example'
Assert-UI (-not $script:ui.SaveButton.IsEnabled) 'Invalid DNS allowlist must disable Save.'
$script:ui.DnsAllowBox.Text=''
Set-CSLeakDisplay ([pscustomobject]@{Dns=[pscustomobject]@{State='unknown';Detail='fixture';Addresses=@('198.51.100.53');Scope='fixture';CheckedUtc='fixture'};WebRtc=$null})
Assert-UI ($script:ui.DnsResultText.Text -match '提醒' -and $script:ui.DnsObservedBox.Text -eq '198.51.100.53') 'Unknown diagnostics must preserve useful observations without showing success.'
Set-CSLeakDisplay ([pscustomobject]@{Dns=$null;WebRtc=[pscustomobject]@{State='unknown';Detail='本轮未观察到公网地址暴露';Addresses=@();Scope='fixture';EmptyReason='未暴露地址，未完成出口核验';DiagnosticLines=@('Google：收集完成；错误码 701','固定出口核验 0/2');CheckedUtc='fixture'}})
Assert-UI ($script:ui.RtcObservedBox.Text -eq '未暴露地址，未完成出口核验' -and $script:ui.RtcResultText.Text -match '提醒') 'The actual empty observation explanation must remain separate from launch permission.'
Assert-UI ($script:ui.RtcScopeText.Text -match '701' -and $script:ui.RtcScopeText.Text -match '0/2') 'Per-server diagnostics must reach the visible WPF control.'
Set-CSLeakDisplay $null
Assert-UI ($script:ui.DnsObservedBox.Text -eq '尚未检测') 'Starting a new check must clear stale observations.'
Set-CSLeakDisplay ([pscustomobject]@{Dns=[pscustomobject]@{State='unknown';Detail='TUN off';Addresses=@();Attempted=$false;Scope='skipped';CheckedUtc='2026-10-22T04:40:54.9124480Z'};WebRtc=$null})
Assert-UI ($script:ui.DnsObservedBox.Text -match '本次未执行') 'Skipped probes must be shown as not executed, rather than no address.'
Assert-UI ($script:ui.DnsScopeText.Text -match '检查时间（本机）' -and $script:ui.DnsScopeText.Text -notmatch '9124480Z') 'Timestamps must be human-readable with a local-time label.'
Assert-UI ((Format-CSCheckTime '2026-10-22T04:40:54Z') -match '^2026-10-22 \d{2}:\d{2}:\d{2} [+-]\d{2}:\d{2}$') 'Formatted time must include a timezone offset.'
Assert-UI ((Get-CSQualityWebLink 'Scamalytics' $fixture.expectedEgressIP) -eq ('https://scamalytics.com/ip/'+$fixture.expectedEgressIP)) 'Scamalytics must use the validated saved IP.'
Assert-UI ((Get-CSQualityWebLink 'Coffee') -eq 'https://ip.net.coffee/claude/' -and (Get-CSQualityWebLink 'IPRisk') -eq 'https://iprisk.top/?lang=zh') 'Manual web links must use the requested sites.'
Assert-UI ($script:ui.LanguageCombo.SelectedItem.Label -notmatch '^@\{') 'Language item must expose a readable label.'
$script:dirty=$false
$script:ui.IpBox.Text='203.0.113.11'
Assert-UI $script:dirty 'Editing an input must mark the form unsaved.'
Assert-UI $script:ui.SaveButton.IsEnabled 'Valid edits must enable Save.'
Assert-UI (-not $script:ui.LaunchButton.IsEnabled) 'Unsaved edits must disable launch.'
$script:ui.IpBox.Text='203.0'
Assert-UI (-not $script:ui.SaveButton.IsEnabled) 'Partial IP must disable Save.'
$script:ui.ZoneCombo.SelectedItem=$script:zones|Where-Object Id -eq 'Singapore Standard Time'
Assert-UI ((Get-CSFormConfig).expectedCulture -in @('en-SG','zh-SG')) 'Changing zone must offer only compatible cultures.'
$neutralFixture=Convert-CSRuntimeConfig $fixture
$neutralFixture.expectedTimeZone='GMT Standard Time';$neutralFixture.expectedCulture='ja-JP'
Set-CSForm $neutralFixture
Assert-UI ((Get-CSFormConfig).expectedCulture -eq 'ja-JP') 'Neutral region must preserve a recognized user language.'
Assert-UI (@($script:ui.LanguageCombo.ItemsSource|Where-Object Name -eq 'en-US').Count -eq 1) 'Neutral region must expose other recognized languages.'
Assert-UI ($script:ui.ZoneCombo.SelectedItem.Label -notmatch '^(不推荐|推荐)') 'Neutral selection must have no recommendation prefix.'
$script:ui.ZoneCombo.SelectedItem=$script:zones|Where-Object Id -eq 'China Standard Time'
Assert-UI ($script:ui.ZoneCombo.SelectedItem.Selectable -and $script:ui.ZoneCombo.SelectedItem.Color -eq '#E8B95F') 'Mainland must be selectable with a yellow advisory.'
function Get-TimeZone {[CmdletBinding()]param();[pscustomobject]@{Id='GMT Standard Time';DisplayName='Example London time'}}
function Get-Culture {[CmdletBinding()]param();[Globalization.CultureInfo]::GetCultureInfo('ja-JP')}
$script:ui.ReadSystemButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Assert-UI ((Get-CSFormConfig).expectedTimeZone -eq 'GMT Standard Time' -and (Get-CSFormConfig).expectedCulture -eq 'ja-JP') 'Read System must recognize a neutral timezone and culture.'
Assert-UI ($script:ui.LocaleStatus.Text -match '^✓') 'Matching neutral system choices must pass the consistency check.'
$fixture.expectedCulture='en-US'
Set-CSForm $fixture
Assert-UI (-not $script:ui.LanguageCombo.SelectedItem) 'Invalid stored pairing must not be silently repaired and accepted.'
Update-CSForm
Assert-UI ($script:ui.LocaleStatus.Text -match '× 拒绝连接') 'Mismatch must show the explicit red rejection.'
Assert-UI (-not $script:ui.SaveButton.IsEnabled) 'Incomplete locale must prevent Save.'
$fixture.expectedCulture='zh-TW';Set-CSForm $fixture;Update-CSForm $true
function Get-CSRunningV2rayRoots {return @('C:\Mock\RunningV2ray')}
$script:ui.DetectProxyButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Assert-UI ($script:ui.ProxyRootBox.Text -eq 'C:\Mock\RunningV2ray' -and $script:dirty) 'Read-running-directory must populate the one central form and require Save.'
Set-CSForm $fixture
$script:ui.DnsAllowBox.Text=''
$draft=New-CSLeakResult 'DNS泄露' 'unknown' 'fixture' @('198.51.100.53','198.51.100.54')
$draft=Add-CSLeakDiagnostics $draft ([pscustomobject]@{ReportValid=$true;ControlMatchesPinned=$true}) @()
Set-CSLeakDisplay ([pscustomobject]@{Dns=$draft;WebRtc=$null})
Assert-UI (Use-CSObservedDns -Automatic) 'A fresh eligible observation must fill an empty DNS baseline automatically.'
Assert-UI ($script:ui.DnsAllowBox.Text -eq '198.51.100.53, 198.51.100.54' -and $script:dirty -and -not $script:ui.LaunchButton.IsEnabled) 'Draft fill must require Save and keep launch disabled.'
Assert-UI ($script:ui.DnsDraftStatus.Text -match '尚未保存') 'The form must clearly label the result as an unsaved draft.'
$script:ui.DnsAllowBox.Text='198.51.100.99'
Assert-UI (-not (Use-CSObservedDns -Automatic) -and $script:ui.DnsAllowBox.Text -eq '198.51.100.99') 'Existing custom baselines must not be widened by background checking.'
$script:ui.FillDnsButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Assert-UI ($script:ui.DnsAllowBox.Text -eq '198.51.100.53, 198.51.100.54') 'An explicit one-click action must refill the current draft without manual IP copying.'
$script:ui.DnsAllowBox.Text=$fixture.expectedEgressIP
Assert-UI (Use-CSObservedDns -Automatic) 'An accidental proxy-IP-only baseline must be replaceable by actual observed resolvers.'
$script:ui.IpBox.Text='203.0.113.11'
Assert-UI (-not $script:ui.FillDnsButton.IsEnabled -and -not (Use-CSObservedDns)) 'Changing the pinned exit must invalidate an older DNS draft.'
Set-CSForm $fixture
$draft.Evidence.ControlMatchesPinned=$false
Set-CSLeakDisplay ([pscustomobject]@{Dns=$draft;WebRtc=$null})
Assert-UI $script:ui.FillDnsButton.IsEnabled 'An HTTP mismatch must not hide a valid optional comparison draft.'
Set-CSLeakDisplay $null
Assert-UI (-not $script:ui.FillDnsButton.IsEnabled) 'A new measurement must clear stale one-click adoption state.'
Set-CSForm $fixture;Update-CSForm $true
function Save-CSConfig($Data){$script:savedData=$Data;return $Data}
function Start-CSWorker([string]$Action){$script:askedAction=$Action}
$script:ui.SaveButton.RaiseEvent((New-Object Windows.RoutedEventArgs([Windows.Controls.Primitives.ButtonBase]::ClickEvent)))
Assert-UI ($script:savedData.expectedEgressIP -eq $fixture.expectedEgressIP) 'Save click must send the visible values to the central saver.'
Assert-UI ($script:savedData.clientLanguage -eq 'zh-TW') 'Save click must preserve derived language.'
Assert-UI (-not $script:dirty) 'Successful Save must clear the unsaved state.'
Assert-UI ($script:askedAction -eq 'Check') 'Successful Save must request fresh checks.'
Assert-UI ($script:ui.SettingsPanel.Visibility -eq 'Collapsed') 'Successful Save must show the check page.'
# The save and worker functions above are mocked; no private file is created.
$script:window.Close()
"Passed $script:passed WPF settings interaction assertions; no private config was saved."
