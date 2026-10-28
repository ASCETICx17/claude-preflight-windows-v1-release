$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression,System.IO.Compression.FileSystem
$source=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('CSPublicExportTest-'+[guid]::NewGuid().ToString('N'))
$project=Join-Path $testRoot 'project'
$script:passed=0
function Assert-Export([bool]$Condition,[string]$Message){if(-not $Condition){throw ('FAILED: '+$Message)};$script:passed++}
try{
    foreach($part in @('tools','windows\local')){[void][IO.Directory]::CreateDirectory((Join-Path $project $part))}
    Copy-Item -LiteralPath (Join-Path $source 'tools\Export-PublicPreview.ps1') -Destination (Join-Path $project 'tools\Export-PublicPreview.ps1')
    foreach($name in @('Configuration.ps1','LocalePolicy.ps1','settings.example.json')){Copy-Item -LiteralPath (Join-Path $source ('windows\local\'+$name)) -Destination (Join-Path $project ('windows\local\'+$name))}
    $fixture=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'public-fixture.json') -Raw|ConvertFrom-Json
    $fixture.expectedEgressIP='203.0.113.99'
    $fixture|Add-Member -NotePropertyName allowedDnsResolverIPs -NotePropertyValue @('198.51.100.53') -Force
    [IO.File]::WriteAllText((Join-Path $project 'windows\local\settings.json'),($fixture|ConvertTo-Json))
    [IO.File]::WriteAllText((Join-Path $project 'note.txt'),'203.0.113.99')
    [IO.File]::WriteAllText((Join-Path $project 'runtime.log'),'private log fixture')
    $blocked=$false
    try{& (Join-Path $project 'tools\Export-PublicPreview.ps1') -OutputPath (Join-Path $testRoot 'blocked.zip')|Out-Null}catch{$blocked=$true}
    Assert-Export $blocked 'Personal values duplicated outside config must block packaging.'
    Assert-Export (-not(Test-Path -LiteralPath (Join-Path $testRoot 'blocked.zip'))) 'Failed privacy scan must create no archive.'
    Remove-Item -LiteralPath (Join-Path $project 'note.txt')
    [IO.File]::WriteAllText((Join-Path $project 'note.txt'),'198.51.100.53')
    $dnsBlocked=$false
    try{& (Join-Path $project 'tools\Export-PublicPreview.ps1') -OutputPath (Join-Path $testRoot 'dns-blocked.zip')|Out-Null}catch{$dnsBlocked=$true}
    Assert-Export $dnsBlocked 'DNS personal values outside the sole config must block packaging.'
    Assert-Export (-not(Test-Path -LiteralPath (Join-Path $testRoot 'dns-blocked.zip'))) 'Failed DNS privacy scan must create no archive.'
    Remove-Item -LiteralPath (Join-Path $project 'note.txt')
    $zip=Join-Path $testRoot 'public.zip'
    $result=& (Join-Path $project 'tools\Export-PublicPreview.ps1') -OutputPath $zip|ConvertFrom-Json
    Assert-Export (-not $result.PrivateConfigIncluded) 'Exporter must report config excluded.'
    $archive=[IO.Compression.ZipFile]::OpenRead($zip)
    try{
        $names=@($archive.Entries.FullName)
        Assert-Export (@($names|Where-Object {$_ -match '/settings\.json$|runtime\.log$'}).Count -eq 0) 'ZIP must exclude actual config and logs.'
        Assert-Export (@($names|Where-Object {$_ -match 'settings\.example\.json$'}).Count -eq 1) 'ZIP must retain public blank template.'
        Assert-Export (@($names|Where-Object {$_ -match '/SHA256SUMS\.txt$'}).Count -eq 1) 'ZIP must include public-file integrity manifest.'
    }finally{$archive.Dispose()}
}finally{
    # Exact temporary paths; remove individual files then empty directories.
    if(Test-Path -LiteralPath $testRoot){
        Get-ChildItem -LiteralPath $testRoot -Recurse -File -Force|ForEach-Object{Remove-Item -LiteralPath $_.FullName -Force}
        Get-ChildItem -LiteralPath $testRoot -Recurse -Directory|Sort-Object {$_.FullName.Length} -Descending|ForEach-Object{[IO.Directory]::Delete($_.FullName)}
        [IO.Directory]::Delete($testRoot)
    }
}
"Passed $script:passed public-export assertions; only fictional temporary files were used."
