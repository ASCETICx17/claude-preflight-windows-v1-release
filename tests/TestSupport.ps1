# Public, fictional test data. Never read, copy or create a user's settings.json.
function Get-CSPublicFixture {
    $data=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'public-fixture.json') -Raw -Encoding UTF8|ConvertFrom-Json
    return (Convert-CSRuntimeConfig $data)
}
function Get-CSConfig { return (Get-CSPublicFixture) }
# Adapt existing single-response mocks to the production asynchronous interface.
function Start-CSRequestBatch($Config,[string[]]$Urls) {
    return @($Urls|ForEach-Object {[pscustomobject]@{Url=$_;Config=$Config}})
}
function Wait-CSRequestBatch($Pending) {
    $results=@{}
    foreach($item in $Pending){$results[$item.Url]=Invoke-CSRequest $item.Config $item.Url}
    return $results
}
