function Get-CSProcessImagePath([int]$ProcessId) {
    if(-not ('ClaudeGuard.ProcessImage' -as [type])){
        Add-Type -TypeDefinition @'
using System;using System.Text;using System.Runtime.InteropServices;
namespace ClaudeGuard { public static class ProcessImage {
[DllImport("kernel32.dll",SetLastError=true)] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
[DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)] static extern bool QueryFullProcessImageName(IntPtr handle,int flags,StringBuilder text,ref int size);
[DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
public static string Read(int pid){var h=OpenProcess(0x1000,false,pid);if(h==IntPtr.Zero)return null;try{var b=new StringBuilder(32768);int n=b.Capacity;return QueryFullProcessImageName(h,0,b,ref n)?b.ToString():null;}finally{CloseHandle(h);}}
}}
'@
    }
    return [ClaudeGuard.ProcessImage]::Read($ProcessId)
}
function Get-CSRunningV2rayRoots {
    $roots=@()
    foreach($process in @(Get-Process -Name v2rayN -ErrorAction SilentlyContinue)){
        try{
            $path=Get-CSProcessImagePath $process.Id
            if($path){
                $root=[IO.Path]::GetDirectoryName($path)
                if(Test-Path -LiteralPath (Join-Path $root 'guiConfigs\guiNConfig.json') -PathType Leaf){$roots+=$root}
            }
        }catch{}
    }
    return @($roots|Sort-Object -Unique)
}
function Resolve-CSTunDataLocation($Config) {
    $saved=[string]$Config.proxyRoot
    $saved=$saved.TrimEnd('\')
    if((Split-Path $saved -Leaf) -in @('guiConfigs','binConfigs')){$saved=Split-Path $saved -Parent}
    $active=@(Get-CSRunningV2rayRoots)
    if($active.Count -eq 1){return [pscustomobject]@{Root=$active[0];Source='running';SavedMismatch=($active[0] -ne $saved)}}
    if($active.Count -gt 1 -and $saved -notin $active){throw '发现多个运行中的 v2rayN 数据目录，请在个人配置选择当前实例的目录。'}
    if(-not $saved -or -not(Test-Path -LiteralPath (Join-Path $saved 'guiConfigs\guiNConfig.json') -PathType Leaf)){
        throw '保存的目录不含 guiConfigs/guiNConfig.json，且未能唯一识别运行目录；请点击个人配置的“读取运行目录”。这不是 TUN 关闭的证据。'
    }
    return [pscustomobject]@{Root=$saved;Source='saved';SavedMismatch=$false}
}
