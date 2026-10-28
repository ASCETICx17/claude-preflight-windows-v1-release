# UI-owned advisory lifecycle. No launch permission is granted by this module.
$script:advisoryTasks=@{}
$script:advisoryRetired=@()
$script:advisoryResults=[pscustomobject]@{Dns=$null;WebRtc=$null}
$script:advisoryContext=$null
function Stop-CSAdvisories {
    foreach($task in @($script:advisoryTasks.Values)){
        try{
            $stop=$task.Shell.BeginStop($null,$null)
            $script:advisoryRetired+=@([pscustomobject]@{Task=$task;Stop=$stop})
        }catch{$task.Shell.Dispose()}
    }
    $script:advisoryTasks=@{}
    $script:advisoryContext=$null
}
function Publish-CSAdvisories {
    if(-not $script:advisoryContext){return}
    $form=Get-CSFormConfig
    if($form.proxyUrl -ne $script:advisoryContext.Proxy -or $form.expectedEgressIP -ne $script:advisoryContext.Pinned){return}
    Set-CSLeakDisplay $script:advisoryResults
    $items=@($script:ui.ChecksList.ItemsSource|Where-Object {$_.Name -notin @('DNS泄露','WebRTC泄露')})
    foreach($kind in @('Dns','WebRtc')){
        $result=$script:advisoryResults.$kind
        if($result){
            $ok=($result.State -eq 'ok')
            $items+=[pscustomobject]@{Name=$result.Name;Detail=(Protect-CSMessage $result.Detail);Icon=$(if($ok){'✓'}else{'!'});Color=$(if($ok){'#73DFCA'}else{'#E8B95F'})}
        }
    }
    $script:ui.ChecksList.ItemsSource=$items
    if(-not $script:worker -and $script:advisoryResults.Dns.State -ne 'pending'){
        [void](Use-CSObservedDns -Automatic)
    }
}
function Start-CSAdvisories($Config) {
    $key=$Config|ConvertTo-Json -Depth 4 -Compress
    if($script:advisoryTasks.Count -and $script:advisoryContext.Key -eq $key){return}
    Stop-CSAdvisories
    $script:advisoryContext=[pscustomobject]@{Key=$key;Proxy=$Config.proxyUrl;Pinned=$Config.expectedEgressIP;Started=[DateTime]::UtcNow}
    $script:advisoryResults=[pscustomobject]@{Dns=$null;WebRtc=$null}
    foreach($kind in @('Dns','WebRtc')){
        $name=if($kind -eq 'Dns'){'DNS泄露'}else{'WebRTC泄露'}
        $script:advisoryResults.$kind=New-CSLeakResult $name 'pending' '正在后台检测，最长约 30 秒；不影响启动。' @() '黄色提醒项' $false
        try{$script:advisoryTasks[$kind]=Start-CSLeakTask $Config $kind $true}
        catch{$script:advisoryResults.$kind=New-CSLeakResult $name 'unknown' '无法启动检测任务；仅作提醒。' @() '' $false}
    }
    Publish-CSAdvisories
    $script:ui.LeakRunButton.IsEnabled=$false
    $script:ui.LeakProgressText.Text='DNS / WebRTC 正在后台检测，分别返回；最长约 30 秒，不阻塞必要检查或启动。'
    $script:timer.Start()
}
function Update-CSAdvisories {
    $remaining=@()
    foreach($retired in $script:advisoryRetired){
        if($retired.Stop.IsCompleted){try{$retired.Task.Shell.EndStop($retired.Stop)}catch{}; $retired.Task.Shell.Dispose()}
        else{$remaining+=$retired}
    }
    $script:advisoryRetired=$remaining
    $changed=$false
    foreach($kind in @($script:advisoryTasks.Keys)){
        $task=$script:advisoryTasks[$kind]
        if($task.Handle.IsCompleted){
            $script:advisoryResults.$kind=Wait-CSLeakTask $task $kind
            $script:advisoryTasks.Remove($kind)
            $changed=$true
        }elseif(([DateTime]::UtcNow-$task.Started).TotalSeconds -ge 30){
            $name=if($kind -eq 'Dns'){'DNS泄露'}else{'WebRTC泄露'}
            $script:advisoryResults.$kind=New-CSLeakResult $name 'unknown' '本轮等待达到 30 秒，未取得完整结果；仅作黄色提醒。'
            try{$stop=$task.Shell.BeginStop($null,$null);$script:advisoryRetired+=@([pscustomobject]@{Task=$task;Stop=$stop})}catch{$task.Shell.Dispose()}
            $script:advisoryTasks.Remove($kind)
            $changed=$true
        }
    }
    if($changed){Publish-CSAdvisories}
    if($script:advisoryContext){
        $seconds=[int]([DateTime]::UtcNow-$script:advisoryContext.Started).TotalSeconds
        $script:ui.LeakProgressText.Text=if($script:advisoryTasks.Count){'后台检测中：'+(2-$script:advisoryTasks.Count)+'/2 项已返回，已等待 '+$seconds+' 秒。黄色提醒，不影响启动。'}else{'DNS / WebRTC 本轮已结束。异常、超时或无法确认仅作黄色提醒；不自动阻断或关闭 Claude。'}
    }
    $script:ui.LeakRunButton.IsEnabled=(-not $script:worker -and $script:advisoryTasks.Count -eq 0)
}
function Close-CSAdvisories {
    Stop-CSAdvisories
    foreach($retired in $script:advisoryRetired){
        try{$retired.Task.Shell.EndStop($retired.Stop)}catch{}
        $retired.Task.Shell.Dispose()
    }
    $script:advisoryRetired=@()
}
