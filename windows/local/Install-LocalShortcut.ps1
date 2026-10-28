$ErrorActionPreference = 'Stop'
$taskDesktop = [Environment]::GetFolderPath('Desktop')
if (-not $taskDesktop -or -not (Test-Path -LiteralPath $taskDesktop)) { throw '未找到当前用户的桌面目录。' }
$taskEntry = Join-Path $PSScriptRoot 'ClaudeLocalUI.ps1'
if (-not (Test-Path -LiteralPath $taskEntry)) { throw '启动文件不存在。' }
$taskShell = New-Object -ComObject WScript.Shell
$taskShortcutPath = Join-Path $taskDesktop 'Claude Preflight.lnk'
if (Test-Path -LiteralPath $taskShortcutPath) {
    $taskExisting = $taskShell.CreateShortcut($taskShortcutPath)
    if ($taskExisting.Arguments -notlike ('*' + $taskEntry + '*')) {
        $taskShortcutPath = Join-Path $taskDesktop ('Claude Preflight-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '.lnk')
    }
}
$taskShortcut = $taskShell.CreateShortcut($taskShortcutPath)
$taskShortcut.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$taskShortcut.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $taskEntry + '"'
$taskShortcut.WorkingDirectory = $PSScriptRoot
$taskShortcut.Description = 'Claude 防直连规则校验与固定出口检查；保留现有网卡、IPv6、时区与账号。'
$taskShortcut.Save()
$taskSavedShortcut = $taskShell.CreateShortcut($taskShortcutPath)
if ($taskSavedShortcut.TargetPath -ne $taskShortcut.TargetPath -or $taskSavedShortcut.Arguments -ne $taskShortcut.Arguments) { throw '快捷方式校验失败。' }
[pscustomobject]@{ Shortcut = $taskShortcutPath; Target = $taskSavedShortcut.TargetPath; Verified = $true } | ConvertTo-Json
