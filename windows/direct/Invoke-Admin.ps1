param([ValidateSet('Apply','Remove','Probe')][string]$Action='Apply',[switch]$Elevated,[string]$OperationId='',[int]$StopStalledProcessId=0)
$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
. (Join-Path $PSScriptRoot '..\local\Configuration.ps1')
. (Join-Path $PSScriptRoot 'RepairLifecycle.ps1')

function Invoke-CSAdminRuleAction([string]$RequestedAction) {
    . (Join-Path $PSScriptRoot 'DirectBlock.ps1')
    if($RequestedAction -eq 'Apply'){$null=Invoke-DBApply}
    else{
        Update-CSRepairPhase 'removing'
        Get-NetFirewallRule -Group $script:DBGroup -ErrorAction SilentlyContinue|Remove-NetFirewallRule
        Write-DBJson ([pscustomobject]@{applied=$false;removed=$true;updatedUtc=[DateTime]::UtcNow.ToString('o')}) 'status.json'
    }
}
function Invoke-CSAdminEntry([string]$RequestedAction,[bool]$IsElevated,[string]$RequestId) {
    if(-not $RequestId){$RequestId=[guid]::NewGuid().ToString('D');Initialize-CSRepairOperation $RequestId $RequestedAction}
    $request=Assert-CSRepairActive $RequestId
    if($request.Action -ne $RequestedAction){throw '管理员操作类型与请求不匹配。'}
    if(-not $IsElevated -and -not (Test-CSAdminToken)){
        $ps=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        try{
            # RunAs can itself wait on Windows consent. The owning core watches
            # the request independently and invalidates any late authorization.
            $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$PSCommandPath+'" -Action '+$RequestedAction+' -Elevated -OperationId '+$RequestId+' -StopStalledProcessId '+$StopStalledProcessId
            $child=Start-Process -FilePath $ps -Verb RunAs -WindowStyle Hidden -PassThru -ArgumentList $arguments
            try{
                while(-not $child.WaitForExit(250)){
                    $state=Get-CSRepairState $RequestId
                    if(-not $state -or $state.Cancelled){return 1}
                }
                $state=Get-CSRepairState $RequestId
                if($child.ExitCode -ne 0 -and $state -and $state.Phase -notin @('failed','cancelled')){
                    Set-CSRepairPhase $RequestId 'failed' '管理员辅助程序提前退出，操作未完成。'
                }
                return $child.ExitCode
            }finally{$child.Dispose()}
        }catch{
            $state=Get-CSRepairState $RequestId
            if($state -and -not $state.Cancelled){
                $code=$_.Exception.NativeErrorCode
                $message=if($code -eq 1223){'Windows 管理员授权被取消。'}elseif($code -eq 5){'Windows 拒绝提升权限，请检查账户或系统策略。'}else{'未能启动 Windows 管理员授权，请检查任务栏提示或系统策略。'}
                Set-CSRepairPhase $RequestId 'failed' $message
            }
            return 1
        }
    }
    $mutex=$null;$ownsMutex=$false
    try{
        if(-not(Test-CSAdminToken)){throw 'Windows 没有返回管理员令牌；操作未执行。'}
        $null=Assert-CSRepairActive $RequestId
        Set-CSRepairPhase $RequestId 'elevated'
        if($RequestedAction -eq 'Probe'){Set-CSRepairPhase $RequestId 'completed';return 0}
        $mutex=New-Object Threading.Mutex($false,'Local\ClaudeWindowsGuard-RuleUpdate')
        $ownsMutex=$mutex.WaitOne(0)
        if(-not $ownsMutex){throw '已有规则更新尚未结束，请勿同时运行多个更新。'}
        $script:CSActiveRepairId=$RequestId
        if($StopStalledProcessId -gt 0){
            $old=Get-CimInstance Win32_Process -Filter "ProcessId=$StopStalledProcessId"
            if($old){
                if($old.Name -ne 'powershell.exe' -or -not $old.CommandLine -or $old.CommandLine.IndexOf($PSCommandPath,[StringComparison]::OrdinalIgnoreCase) -lt 0 -or $old.CommandLine -notmatch '-Action Apply -Elevated' -or (Get-Date).Subtract($old.CreationDate).TotalSeconds -lt 60){throw '旧任务身份或运行时间不符合清理条件。'}
                $children=@(Get-CimInstance Win32_Process -Filter "ParentProcessId=$StopStalledProcessId"|Where-Object {$_.ExecutablePath -eq (Join-Path $PSScriptRoot 'probe\blocked-curl.exe')})
                Stop-Process -Id $StopStalledProcessId -Force -ErrorAction Stop
                foreach($item in $children){Stop-Process -Id $item.ProcessId -Force -ErrorAction SilentlyContinue}
            }
        }
        Invoke-CSAdminRuleAction $RequestedAction
        Set-CSRepairPhase $RequestId 'completed'
        return 0
    }catch{
        $state=Get-CSRepairState $RequestId
        if($state -and -not $state.Cancelled){Set-CSRepairPhase $RequestId 'failed' (Protect-CSMessage $_.Exception.Message)}
        return 1
    }finally{
        $script:CSActiveRepairId=''
        if($ownsMutex){$mutex.ReleaseMutex()}
        if($mutex){$mutex.Dispose()}
    }
}
if($MyInvocation.InvocationName -eq '.'){return}
try{exit (Invoke-CSAdminEntry $Action ([bool]$Elevated) $OperationId)}
catch{exit 1}
