$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'DirectBlock.ps1')
$script:passed=0
function Assert-Upgrade([bool]$Condition,[string]$Message) {
    if(-not $Condition) { throw "FAILED: $Message" }
    $script:passed++
}
function Expect-UpgradeBlocked([scriptblock]$Operation,[string]$Message) {
    $blocked=$false
    try { & $Operation|Out-Null } catch { $blocked=$true }
    Assert-Upgrade $blocked $Message
}
# Real path canonicalization, with synthetic signature results. Nothing is executed.
$fixture=Join-Path $env:TEMP ('ClaudeUpgradeTest-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $fixture|Out-Null
$inside=Join-Path $fixture 'claude.exe'
[IO.File]::WriteAllText($inside,'test fixture only')
$script:signatureStatus='Valid'
$script:signerName='Anthropic, PBC'
function Get-AuthenticodeSignature {
    [CmdletBinding()]param([string]$LiteralPath)
    $cert=New-Object psobject
    $cert|Add-Member ScriptMethod GetNameInfo {param($Kind,$Issuer) return $script:signerName}
    [pscustomobject]@{Status=$script:signatureStatus;SignerCertificate=$cert}
}
try {
    Assert-Upgrade ((Assert-DBTrustedExecutable $inside $fixture) -eq $inside) 'Valid Anthropic executable inside the exact root must pass.'
    Expect-UpgradeBlocked { Assert-DBTrustedExecutable ($fixture+'-outside\claude.exe') $fixture } 'A shared string prefix must not be treated as a child directory.'
    Expect-UpgradeBlocked { Assert-DBTrustedExecutable (Join-Path $fixture '..\outside.exe') $fixture } 'Parent traversal must be rejected after canonicalization.'
    $script:signatureStatus='HashMismatch'
    Expect-UpgradeBlocked { Assert-DBTrustedExecutable $inside $fixture } 'A modified signed file must be rejected.'
    $script:signatureStatus='NotSigned'
    Expect-UpgradeBlocked { Assert-DBTrustedExecutable $inside $fixture } 'Unsigned executable must be rejected.'
    $script:signatureStatus='Valid';$script:signerName='Other publisher'
    Expect-UpgradeBlocked { Assert-DBTrustedExecutable $inside $fixture } 'A valid signature from another publisher must be rejected.'
    $script:signerName='Anthropic, PBC'
    function Get-Item {
        [CmdletBinding()]param([string]$LiteralPath)
        if($LiteralPath -eq $fixture) { return [pscustomobject]@{Attributes=[IO.FileAttributes]::ReparsePoint} }
        Microsoft.PowerShell.Management\Get-Item @PSBoundParameters
    }
    Expect-UpgradeBlocked { Assert-DBTrustedExecutable $inside $fixture } 'A reparse point in an ancestor must be rejected.'
    Remove-Item Function:\Get-Item
} finally {
    # Only two specifically known fixture paths are removed; no recursive deletion.
    Remove-Item -LiteralPath $inside -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $fixture -ErrorAction SilentlyContinue
}
Assert-Upgrade ((Get-DBProgramFingerprint @('C:\A.exe','C:\B.exe')) -eq (Get-DBProgramFingerprint @('c:\b.exe','c:\a.exe'))) 'Fingerprint must ignore path case and order.'
Assert-Upgrade ((Get-DBProgramFingerprint @('C:\A.exe')) -ne (Get-DBProgramFingerprint @('C:\NewVersion\A.exe'))) 'An upgraded path must change the fingerprint.'
$script:version='2.1.0.0'
$script:family='Claude_pzs8sxrjxfjjc'
$script:outside=$false
$script:mainMissing=$false
$script:extraHelper=$false
$script:trustAll=$true
$script:multipleVersions=$false
function Get-MockPackageRoot {
    if($script:outside) { return (Join-Path $env:TEMP 'Claude_2.1.0.0_x64__pzs8sxrjxfjjc') }
    Join-Path $env:ProgramFiles ('WindowsApps\Claude_'+$script:version+'_x64__pzs8sxrjxfjjc')
}
function Get-AppxPackage {
    [CmdletBinding()]param([string]$Name)
    if($script:multipleVersions) { [pscustomobject]@{Version='2.2.0.0';PackageFamilyName=$script:family;InstallLocation=(Join-Path $env:ProgramFiles 'WindowsApps\Claude_2.2.0.0_x64__pzs8sxrjxfjjc')} }
    [pscustomobject]@{Version=$script:version;PackageFamilyName=$script:family;InstallLocation=(Get-MockPackageRoot)}
}
function Test-Path {
    [CmdletBinding()]param([string]$LiteralPath,[string]$PathType)
    if($LiteralPath -eq (Join-Path (Get-MockPackageRoot) 'app\claude.exe')) { return (-not $script:mainMissing) }
    return $true
}
function Get-ChildItem {
    [CmdletBinding()]param([string]$LiteralPath,[string]$Filter,[switch]$File,[switch]$Recurse)
    if($LiteralPath -eq (Join-Path (Get-MockPackageRoot) 'app')) {
        [pscustomobject]@{FullName=(Join-Path $LiteralPath 'claude.exe')}
        [pscustomobject]@{FullName=(Join-Path $LiteralPath 'resources\cowork-svc.exe')}
        if($script:extraHelper) { [pscustomobject]@{FullName=(Join-Path $LiteralPath 'resources\new-helper.exe')} }
    } else { [pscustomobject]@{FullName=(Join-Path $LiteralPath '2.1.0\claude.exe')} }
}
function Assert-DBTrustedExecutable([string]$Path,[string]$Root) {
    if(-not $script:trustAll) { throw 'Invalid mock signature' }
    return $Path
}
$before=Get-DBDiscovery
Assert-Upgrade ($before.Programs.Count -eq 4) 'Current package, embedded Code and CLI must all be discovered.'
$script:version='2.2.0.0'
$after=Get-DBDiscovery
Assert-Upgrade ($after.PackageVersion -eq '2.2.0.0' -and $after.Fingerprint -ne $before.Fingerprint) 'Discovery must follow the current registered version.'
Assert-Upgrade (@($after.Programs|Where-Object {$_ -match 'Claude_2\.1\.0\.0_'}).Count -eq 0) 'Stale package paths must not remain the authority.'
$script:multipleVersions=$true;$script:version='2.10.0.0'
Assert-Upgrade ((Get-DBDiscovery).PackageVersion -eq '2.10.0.0') 'Version selection must be numeric: 2.10 is newer than 2.2.'
$script:multipleVersions=$false;$script:version='2.2.0.0'
$script:extraHelper=$true
$withHelper=Get-DBDiscovery
Assert-Upgrade ($withHelper.Programs.Count -eq 5 -and $withHelper.Fingerprint -ne $after.Fingerprint) 'A new signed helper must be included automatically.'
$script:trustAll=$false
Expect-UpgradeBlocked { Get-DBDiscovery } 'Discovery must fail if any candidate fails trust verification.'
$script:trustAll=$true;$script:family='Impostor_other'
Expect-UpgradeBlocked { Get-DBDiscovery } 'A different package identity must be rejected.'
$script:family='Claude_pzs8sxrjxfjjc';$script:outside=$true
Expect-UpgradeBlocked { Get-DBDiscovery } 'An app registered outside the protected WindowsApps root must be rejected.'
$script:outside=$false;$script:mainMissing=$true
Expect-UpgradeBlocked { Get-DBDiscovery } 'Missing main executable must be rejected.'
$script:mainMissing=$false;$script:extraHelper=$false
$script:protectedPaths=@($before.Programs)
function Test-DBRule([string]$Program,[string]$Family) { return ($Program -in $script:protectedPaths) }
function Get-DBRuleSet([string[]]$Names){return @{}}
function Get-Service { [pscustomobject]@{Status='Running'} }
function Get-NetFirewallProfile { [pscustomobject]@{Enabled='True'} }
$verification=Get-DBVerification
Assert-Upgrade (-not $verification.verified -and $verification.missingProgramCount -eq 2) 'Rules for the old package must not count as protection for the new package.'
$script:protectedPaths=@($after.Programs)
Assert-Upgrade (Get-DBVerification).verified 'New exact rules must satisfy current-version verification.'
"Passed $script:passed upgrade and trust assertions; no firewall rules or applications were changed."
