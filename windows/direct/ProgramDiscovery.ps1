function Assert-DBTrustedExecutable([string]$Path,[string]$Root) {
    $full=[IO.Path]::GetFullPath($Path)
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\')
    if(-not $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '发现超出官方目录的程序，拒绝更新规则。' }
    $item=Get-Item -LiteralPath $full -ErrorAction Stop
    if($item.PSIsContainer -or $item.Extension -ne '.exe') { throw '程序路径不是可执行文件。' }
    $cursor=$full
    while($cursor.Length -ge $base.Length) {
        $entry=Get-Item -LiteralPath $cursor -ErrorAction Stop
        if(($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '发现重解析点，拒绝扩大程序保护范围。' }
        if($cursor -eq $base) { break }
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
    $signature=Get-AuthenticodeSignature -LiteralPath $full -ErrorAction Stop
    if($signature.Status -ne 'Valid' -or -not $signature.SignerCertificate -or $signature.SignerCertificate.GetNameInfo([Security.Cryptography.X509Certificates.X509NameType]::SimpleName,$false) -ne 'Anthropic, PBC') { throw ('程序没有有效的 Anthropic 签名，拒绝更新规则：'+$item.Name) }
    return $full
}

function Get-DBProgramFingerprint([string[]]$Programs) {
    $sha=[Security.Cryptography.SHA256]::Create()
    try {
        $data=(@($Programs|ForEach-Object {$_.ToLowerInvariant()}|Sort-Object -Unique) -join "`n")
        return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($data))).Replace('-','')
    } finally { $sha.Dispose() }
}

function Get-DBDiscovery {
    $package=Get-AppxPackage -Name Claude -ErrorAction Stop|Sort-Object -Property @{Expression={[version]$_.Version}} -Descending|Select-Object -First 1
    if(-not $package -or $package.PackageFamilyName -ne 'Claude_pzs8sxrjxfjjc') { throw '未发现预期的官方 Claude 应用包，拒绝自动扩展目录。' }
    $packageRoot=[IO.Path]::GetFullPath($package.InstallLocation).TrimEnd('\')
    $windowsApps=Join-Path $env:ProgramFiles 'WindowsApps'
    if([IO.Path]::GetDirectoryName($packageRoot) -ne $windowsApps -or [IO.Path]::GetFileName($packageRoot) -notmatch '^Claude_\d+\.\d+\.\d+\.\d+_(x64|arm64)__pzs8sxrjxfjjc$') { throw 'Claude 应用包安装位置异常，拒绝自动扩展目录。' }
    $appRoot=Join-Path $packageRoot 'app'
    $main=Join-Path $appRoot 'claude.exe'
    if(-not(Test-Path -LiteralPath $main -PathType Leaf)) { throw '当前 Claude 应用包缺少主程序。' }
    $programs=New-Object 'Collections.Generic.List[string]'
    foreach($file in @(Get-ChildItem -LiteralPath $appRoot -Filter '*.exe' -File -Recurse -ErrorAction Stop)) {
        $programs.Add((Assert-DBTrustedExecutable $file.FullName $packageRoot))
    }
    if($main -notin $programs) { throw '未能登记当前 Claude 主程序。' }
    $codeRoot=Join-Path $env:APPDATA 'Claude\claude-code'
    if(Test-Path -LiteralPath $codeRoot) {
        foreach($file in @(Get-ChildItem -LiteralPath $codeRoot -Filter 'claude.exe' -File -Recurse -ErrorAction Stop)) {
            $programs.Add((Assert-DBTrustedExecutable $file.FullName $codeRoot))
        }
    }
    $cliRoot=Join-Path $env:USERPROFILE '.local\bin'
    $cli=Join-Path $cliRoot 'claude.exe'
    if(Test-Path -LiteralPath $cli -PathType Leaf) { $programs.Add((Assert-DBTrustedExecutable $cli $cliRoot)) }
    $unique=@($programs|Sort-Object -Unique)
    [pscustomobject]@{OwnerSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;PackageFamilyName=$package.PackageFamilyName;PackageVersion=[string]$package.Version;PackageRoot=$packageRoot;Programs=$unique;Fingerprint=(Get-DBProgramFingerprint $unique);PreparedUtc=[DateTime]::UtcNow.ToString('o')}
}
