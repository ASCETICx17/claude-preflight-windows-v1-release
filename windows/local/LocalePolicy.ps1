# Public display preferences and pairing policy; personal choices stay in settings.json.
function Get-CSCultureCatalog {
    if(-not $script:CSCultureOptions) {
        $script:CSCultureOptions=@([Globalization.CultureInfo]::GetCultures([Globalization.CultureTypes]::SpecificCultures) |
            Sort-Object Name -Unique | ForEach-Object {
                [pscustomobject]@{Name=$_.Name;Label=($_.NativeName+'  ·  '+$_.Name)}
            })
    }
    return $script:CSCultureOptions
}
function Get-CSLocaleCatalog {
    $profiles=@{
        'Pacific Standard Time'=@{Region='US';Name='美国 · 太平洋';Cultures=@('en-US')}
        'Mountain Standard Time'=@{Region='US';Name='美国 · 山地';Cultures=@('en-US')}
        'US Mountain Standard Time'=@{Region='US';Name='美国 · 亚利桑那';Cultures=@('en-US')}
        'Central Standard Time'=@{Region='US';Name='美国 · 中部';Cultures=@('en-US')}
        'Eastern Standard Time'=@{Region='US';Name='美国 · 东部';Cultures=@('en-US')}
        'US Eastern Standard Time'=@{Region='US';Name='美国 · 印第安纳';Cultures=@('en-US')}
        'Alaskan Standard Time'=@{Region='US';Name='美国 · 阿拉斯加';Cultures=@('en-US')}
        'Aleutian Standard Time'=@{Region='US';Name='美国 · 阿留申群岛';Cultures=@('en-US')}
        'Hawaiian Standard Time'=@{Region='US';Name='美国 · 夏威夷';Cultures=@('en-US')}
        'Taipei Standard Time'=@{Region='TW';Name='台北';Cultures=@('zh-TW')}
        'Singapore Standard Time'=@{Region='SG';Name='新加坡';Cultures=@('en-SG','zh-SG')}
        'China Standard Time'=@{Region='CN';Name='中国大陆';Cultures=@('zh-CN')}
    }
    foreach($zone in [TimeZoneInfo]::GetSystemTimeZones()) {
        $profile=$profiles[$zone.Id]
        $recommendation='neutral';$label=$zone.DisplayName;$color='#DDE9F6';$region=''
        if($profile) {
            $region=$profile.Region
            if($region -eq 'CN') {
                $recommendation='warning';$label='不推荐 · '+$profile.Name+'  '+$zone.DisplayName;$color='#E8B95F'
            } else {
                $recommendation='recommended';$label='推荐 · '+$profile.Name+'  '+$zone.DisplayName
            }
        }
        [pscustomobject]@{
            Id=$zone.Id;Label=$label;Region=$region;Recommendation=$recommendation
            Recommended=($recommendation -eq 'recommended');Selectable=$true;Color=$color
            EnforceCulturePair=($null -ne $profile)
            Cultures=$(if($profile){@($profile.Cultures)}else{@()})
        }
    }
}
function Get-CSCultureChoices($ZoneItem) {
    if(-not $ZoneItem) { return @() }
    if($ZoneItem.EnforceCulturePair) { return @(Get-CSCultureCatalog|Where-Object {$_.Name -in $ZoneItem.Cultures}) }
    return @(Get-CSCultureCatalog)
}
function Get-CSLocalePairIssue([string]$Zone,[string]$Culture) {
    if(-not $Zone -or -not $Culture) { return '请选择时区和地区语言。' }
    $item=Get-CSLocaleCatalog|Where-Object Id -eq $Zone|Select-Object -First 1
    if(-not $item) { return '未识别此 Windows 时区，请从系统时区列表中选择。' }
    if($Culture -notin @(Get-CSCultureCatalog|Select-Object -ExpandProperty Name)) { return '未识别此区域格式，请从语言列表中选择。' }
    # Neutral zones have no recommendation and no country-language pairing restriction.
    if($item.EnforceCulturePair -and $Culture -notin $item.Cultures) { return '时区与地区语言不匹配，拒绝连接。' }
    return $null
}
function Get-CSLocaleState($Config) {
    $issue=Get-CSLocalePairIssue $Config.expectedTimeZone $Config.expectedCulture
    if($issue) { return [pscustomobject]@{Success=$false;Detail=$issue} }
    try {
        if((Get-TimeZone -ErrorAction Stop).Id -ne $Config.expectedTimeZone) { return [pscustomobject]@{Success=$false;Detail='Windows 实际时区与所选时区不同，拒绝连接。'} }
        if((Get-Culture -ErrorAction Stop).Name -ne $Config.expectedCulture) { return [pscustomobject]@{Success=$false;Detail='Windows 区域格式与所选语言不同，拒绝连接。'} }
        if($Config.clientLanguage -ne $Config.expectedCulture) { return [pscustomobject]@{Success=$false;Detail='Claude 启动语言与地区语言不同，拒绝连接。'} }
        return [pscustomobject]@{Success=$true;Detail='所选时区、Windows 区域格式及 Claude 启动语言一致'}
    } catch { return [pscustomobject]@{Success=$false;Detail='无法确认 Windows 时区或区域格式，拒绝连接。'} }
}