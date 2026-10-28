# Process-local, bounded HTTP requests. Every request uses the configured proxy.
function Get-CSHttpFailureKind($Failure) {
    $errorObject=$Failure.Exception
    for($depth=0;$errorObject -and $depth -lt 10;$depth++){
        if($errorObject -is [OperationCanceledException]){return 'timeout'}
        if($errorObject -is [Net.WebException]){
            switch([string]$errorObject.Status){
                'Timeout'{return 'timeout'}
                'NameResolutionFailure'{return 'name_resolution'}
                'ProxyNameResolutionFailure'{return 'name_resolution'}
                'TrustFailure'{return 'tls'}
                'SecureChannelFailure'{return 'tls'}
            }
        }
        if($errorObject -is [Security.Authentication.AuthenticationException]){return 'tls'}
        $errorObject=$errorObject.InnerException
    }
    # Never retain exception messages: they can contain proxy URLs or addresses.
    return 'transport'
}
function New-CSHttpFailure([string]$Kind='transport') {
    [pscustomobject]@{Success=$false;HttpStatus='000';Body='';ContentType='';ErrorKind=$Kind}
}
function Start-CSHttpRequest($Config,[string]$Url) {
    Add-Type -AssemblyName System.Net.Http
    $uri=[uri]$Url
    if($uri.Scheme -ne 'https' -or $uri.UserInfo){throw 'Only fixed HTTPS probe URLs are accepted.'}
    $handler=New-Object Net.Http.HttpClientHandler
    $handler.Proxy=New-Object Net.WebProxy([uri]$Config.proxyUrl)
    $handler.UseProxy=$true;$handler.UseCookies=$false;$handler.AllowAutoRedirect=$false
    $handler.UseDefaultCredentials=$false
    $client=New-Object Net.Http.HttpClient($handler)
    $client.Timeout=[TimeSpan]::FromSeconds($Config.requestTimeoutSeconds)
    $client.MaxResponseContentBufferSize=262144
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('Claude-Preflight-Windows/0.6')
    try{return [pscustomobject]@{Client=$client;Task=$client.GetAsync($Url)}}
    catch{$client.Dispose();throw}
}
function Wait-CSHttpRequest($Request) {
    $response=$null
    try{
        $response=$Request.Task.GetAwaiter().GetResult()
        $contentType=if($response.Content.Headers.ContentType){[string]$response.Content.Headers.ContentType.MediaType}else{''}
        [pscustomobject]@{Success=$true;HttpStatus=[string][int]$response.StatusCode;Body=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult();ContentType=$contentType;ErrorKind=''}
    }catch{New-CSHttpFailure (Get-CSHttpFailureKind $_)}
    finally{if($response){$response.Dispose()};$Request.Client.Dispose()}
}
function Start-CSRequestBatch($Config,[string[]]$Urls) {
    [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $pending=@()
    foreach($url in $Urls){
        $request=$null;$failure=$null
        try{$request=Start-CSHttpRequest $Config $url}catch{$failure=New-CSHttpFailure (Get-CSHttpFailureKind $_)}
        $pending+=[pscustomobject]@{Url=$url;Request=$request;Failure=$failure}
    }
    return $pending
}
function Wait-CSRequestBatch($Pending) {
    $responses=@{}
    foreach($item in @($Pending)){
        $responses[$item.Url]=if($item.Request){Wait-CSHttpRequest $item.Request}elseif($item.Failure){$item.Failure}else{New-CSHttpFailure}
    }
    return $responses
}
function Invoke-CSRequestBatch($Config,[string[]]$Urls) {
    return (Wait-CSRequestBatch (Start-CSRequestBatch $Config $Urls))
}
