param([string]$OutputPath)
$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$project=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
. (Join-Path $project 'windows\local\Configuration.ps1')
if(-not $OutputPath){$OutputPath=Join-Path (Split-Path $project -Parent) 'claude-preflight-windows-v1.zip'}
$OutputPath=[IO.Path]::GetFullPath($OutputPath)
if([IO.Path]::GetExtension($OutputPath) -ne '.zip'){throw '输出文件必须为 ZIP。'}
if(Test-Path -LiteralPath $OutputPath){throw '输出已存在，请指定一个新 ZIP 文件名。'}
$privatePath=Get-CSConfigPath
$sensitive=@()
if(Test-Path -LiteralPath $privatePath){
    $config=Get-CSConfig -AllowIncomplete
    $sensitive=@(@($config.expectedEgressIP,$config.proxyRoot,$config.ownerSid)+@($config.allowedDnsResolverIPs))|Where-Object {$_ -and $_.Length -gt 5}
}
$publicJson=@('windows/local/settings.example.json','tests/public-fixture.json','docs/packaging-check.json')
$files=@()
foreach($file in Get-ChildItem -LiteralPath $project -Recurse -File -Force){
    $relative=$file.FullName.Substring($project.Length+1).Replace('\','/')
    if($file.FullName -eq $privatePath -or $relative -eq 'SHA256SUMS.txt'){continue}
    if($relative -match '(^|/)(\.git|\.codex|\.agents|accounts|node_modules|probe)(/|$)'){continue}
    if($file.Name -match '^\.env($|\.)' -or $file.Extension -match '^\.(zip|log|tmp|exe|dll|pfx|pem|key|bak)$'){continue}
    if($file.Extension -eq '.json' -and $relative -notin $publicJson){continue}
    if($file.Extension -notin @('.png','.jpg','.jpeg','.gif','.ico')){
        $content=[IO.File]::ReadAllText($file.FullName)
        foreach($value in $sensitive){
            if($content.IndexOf($value,[StringComparison]::OrdinalIgnoreCase) -ge 0){throw '发布检查失败：配置文件以外存在个人出口、目录或账号标识，请先清理。'}
        }
        if($content -match 'sk-ant-[A-Za-z0-9_-]{20,}'){throw '发布检查失败：发现疑似 API 密钥。'}
    }
    $files+=[pscustomobject]@{File=$file;Relative=$relative}
}
$files=@($files|Sort-Object Relative)
$manifest=($files|ForEach-Object{(Get-FileHash -LiteralPath $_.File.FullName -Algorithm SHA256).Hash+'  '+$_.Relative}) -join [Environment]::NewLine
$stream=[IO.File]::Open($OutputPath,[IO.FileMode]::CreateNew)
try{
    $archive=New-Object IO.Compression.ZipArchive($stream,[IO.Compression.ZipArchiveMode]::Create,$true)
    try{
        foreach($item in $files){
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive,$item.File.FullName,('claude-preflight-windows/'+$item.Relative),[IO.Compression.CompressionLevel]::Optimal)
        }
        $entry=$archive.CreateEntry('claude-preflight-windows/SHA256SUMS.txt')
        $writer=New-Object IO.StreamWriter($entry.Open(),(New-Object Text.UTF8Encoding($false)))
        try{$writer.Write($manifest)}finally{$writer.Dispose()}
    }finally{$archive.Dispose()}
}catch{
    $stream.Dispose()
    [IO.File]::Delete($OutputPath)
    throw
}finally{$stream.Dispose()}
[pscustomobject]@{Archive=(Split-Path $OutputPath -Leaf);PublicFiles=($files.Count+1);PrivateConfigIncluded=$false;SHA256=(Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash}|ConvertTo-Json
