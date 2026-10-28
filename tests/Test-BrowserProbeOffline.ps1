$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot '..\windows\local\LeakChecks.ps1')
Initialize-CSBrowserProbe
$edge=Get-CSEdgePath
$folder=Join-Path ([IO.Path]::GetTempPath()) ('GuardOfflineFixture-'+[guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($folder)
$page=Join-Path $folder 'fixture.html'
try{
    # Deliberately no STUN, DNS, fetch or account data: exercises real Edge/CDP and cleanup only.
    $production=Join-Path $PSScriptRoot '..\windows\local\probes'
    $fake=@'
globalThis.RTCPeerConnection=class {
  createDataChannel(){}
  async createOffer(){return {};}
  async setLocalDescription(){setTimeout(()=>{
    this.onicecandidate({candidate:{address:"203.0.113.10",type:"srflx",protocol:"udp"}});
    this.onicecandidate({candidate:null});
  },1);}
  close(){}
};
'@
    [IO.File]::WriteAllText($page,[IO.File]::ReadAllText((Join-Path $production 'webrtc.html')))
    [IO.File]::WriteAllText((Join-Path $folder 'webrtc.js'),($fake+[Environment]::NewLine+[IO.File]::ReadAllText((Join-Path $production 'webrtc.js'))))
    $before=@(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'ClaudeGuardProbe-*'|Select-Object -ExpandProperty FullName)
    $result=[ClaudeGuardProbe.BrowserClient]::Run($edge,'http://127.0.0.1:1',$page,20)
    $body=$result.Json|ConvertFrom-Json
    if(-not $body.supported -or @($body.probes).Count -ne 2 -or $body.probes[0].candidates[0].address -ne '203.0.113.10' -or -not $result.CleanupComplete){throw 'Offline browser probe or cleanup failed.'}
    $options=@{servers=@(
        @{id='stun:stun.cloudflare.com:3478';urls=@('stun:198.51.100.20:3478');resolution='proxy_doh'},
        @{id='stun:stun.l.google.com:19302';urls=@('stun:198.51.100.21:19302');resolution='proxy_doh'}
    )}|ConvertTo-Json -Depth 5 -Compress
    $withOptions=[ClaudeGuardProbe.BrowserClient]::Run($edge,'http://127.0.0.1:1',$page,20,$options)
    $optionBody=$withOptions.Json|ConvertFrom-Json
    if($optionBody.probes[0].server -ne 'stun:stun.cloudflare.com:3478' -or $optionBody.probes[0].resolution -ne 'proxy_doh'){throw 'C# to JavaScript probe options were lost.'}
    if(-not $withOptions.CleanupComplete){throw 'Option-probe browser cleanup failed.'}
    $after=@(Get-ChildItem -LiteralPath ([IO.Path]::GetTempPath()) -Directory -Filter 'ClaudeGuardProbe-*'|Where-Object FullName -notin $before)
    if($after.Count){throw 'Probe profile was left behind.'}
    'Passed 5 offline browser assertions: Edge/CDP, legacy call, option transport and both temporary-profile cleanups.'
}catch{
    throw $_.Exception.ToString()
}finally{
    Remove-Item -LiteralPath $page -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $folder 'webrtc.js') -Force -ErrorAction SilentlyContinue
    [IO.Directory]::Delete($folder)
}
