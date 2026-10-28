$script:CSRepairRoot=$PSScriptRoot
function Get-CSRepairStatePath { Join-Path $script:CSRepairRoot 'repair-state.json' }
function Test-CSAdminToken {
    $principal=New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-CSRepairState([string]$OperationId) {
    try{
        $state=Get-Content -LiteralPath (Get-CSRepairStatePath) -Raw -Encoding UTF8 -ErrorAction Stop|ConvertFrom-Json -ErrorAction Stop
        if($state.OperationId -eq $OperationId){return $state}
    }catch{}
    return $null
}
function Write-CSRepairState($State) {
    [IO.File]::WriteAllText((Get-CSRepairStatePath),($State|ConvertTo-Json -Depth 4 -Compress),(New-Object Text.UTF8Encoding($false)))
}
function Initialize-CSRepairOperation([string]$OperationId,[string]$Action) {
    $parsed=[guid]::Empty
    if(-not [guid]::TryParse($OperationId,[ref]$parsed)){throw '管理员操作标识无效。'}
    Write-CSRepairState ([pscustomobject]@{OperationId=$OperationId;Action=$Action;Phase='requesting';Elevated=$false;Cancelled=$false;Succeeded=$false;Error='';StartedUtc=[DateTime]::UtcNow.ToString('o');UpdatedUtc=[DateTime]::UtcNow.ToString('o')})
}
function Assert-CSRepairActive([string]$OperationId) {
    $state=Get-CSRepairState $OperationId
    if(-not $state -or $state.Cancelled){throw '本次管理员请求已取消或失效，拒绝继续操作。'}
    return $state
}
function Set-CSRepairPhase([string]$OperationId,[string]$Phase,[string]$ErrorMessage='') {
    $state=Assert-CSRepairActive $OperationId
    $state.Phase=$Phase
    if($Phase -eq 'elevated'){$state.Elevated=$true}
    if($Phase -eq 'completed'){$state.Succeeded=$true}
    $state.Error=Protect-CSMessage $ErrorMessage
    $state.UpdatedUtc=[DateTime]::UtcNow.ToString('o')
    Write-CSRepairState $state
}
function Cancel-CSRepairOperation([string]$OperationId,[string]$Message) {
    $state=Get-CSRepairState $OperationId
    if($state){$state.Cancelled=$true;$state.Phase='cancelled';$state.Error=$Message;$state.UpdatedUtc=[DateTime]::UtcNow.ToString('o');Write-CSRepairState $state}
}
function Get-CSRepairPhaseText($State) {
    if(-not $State){return '正在启动管理员请求…'}
    switch($State.Phase){
        'requesting'{'等待 Windows 管理员授权；请查看任务栏中的盾牌提示…'}
        'elevated'{'已确认管理员权限，正在准备操作…'}
        'discovering'{'已获管理员权限：正在识别官方程序并核验签名…'}
        'network-test'{'已获管理员权限：正在执行阻断对照测试…'}
        'applying'{'已获管理员权限：正在应用程序保护规则…'}
        'verifying'{'已获管理员权限：正在核对生效规则…'}
        'removing'{'已获管理员权限：正在撤销本项目规则…'}
        'completed'{'管理员操作已完成；正在重新检查连接条件…'}
        'failed'{'管理员操作失败：'+$State.Error}
        'cancelled'{$State.Error}
        default{'管理员操作正在进行…'}
    }
}
function Update-CSRepairPhase([string]$Phase) {
    if($script:CSActiveRepairId){Set-CSRepairPhase $script:CSActiveRepairId $Phase}
}
function Get-CSRepairTimeoutReason($State,[double]$Seconds,[int]$AuthorizationSeconds=45,[int]$OperationSeconds=180) {
    if((-not $State -or -not $State.Elevated) -and $Seconds -ge $AuthorizationSeconds){return '等待 Windows 管理员授权超时；本次请求已失效，稍后批准也不会继续应用规则。'}
    if($State -and $State.Elevated -and $Seconds -ge $OperationSeconds){return '管理员权限已取得，但系统规则操作超时；已请求停止，本次拒绝启动，请确认旧操作结束后重试。'}
    return $null
}
function Invoke-CSRepair([string]$Action,[string]$OperationId,[int]$AuthorizationSeconds=45,[int]$OperationSeconds=180) {
    Initialize-CSRepairOperation $OperationId $Action
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $entry=Join-Path $script:CSRepairRoot 'Invoke-Admin.ps1'
    $info.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$entry+'" -Action '+$Action+' -OperationId '+$OperationId
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true;$info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $process=New-Object Diagnostics.Process
    $process.StartInfo=$info
    $watch=[Diagnostics.Stopwatch]::StartNew()
    try{
        [void]$process.Start()
        $output=$process.StandardOutput.ReadToEndAsync();$errors=$process.StandardError.ReadToEndAsync()
        while(-not $process.WaitForExit(200)){
            $state=Get-CSRepairState $OperationId
            $reason=Get-CSRepairTimeoutReason $state $watch.Elapsed.TotalSeconds $AuthorizationSeconds $OperationSeconds
            if($reason){
                Cancel-CSRepairOperation $OperationId $reason
                # Only terminate our unelevated waiting launcher. An elevated task
                # observes cancellation at its next checkpoint and rolls back.
                if(-not $state -or -not $state.Elevated){try{$process.Kill()}catch{}}
                throw $reason
            }
        }
        $state=Get-CSRepairState $OperationId
        if(-not $state -or $state.Cancelled -or -not $state.Succeeded -or $process.ExitCode -ne 0){
            $message=if($state -and $state.Error){$state.Error}else{'管理员辅助程序未返回成功结果，请检查 Windows 授权或程序启动状态。'}
            throw $message
        }
        return $state
    }finally{$watch.Stop();$process.Dispose()}
}
