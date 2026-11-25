# Create .env with random passwords. Does not overwrite an existing file.
$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $Root
$Dest = Join-Path $Root ".env"
if (Test-Path $Dest) {
    Write-Host ".env already exists. Leaving it alone."
    exit 0
}
function New-Secret {
    $bytes = New-Object byte[] 18
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ([System.BitConverter]::ToString($bytes) -replace "-", "").ToLower()
}
$text = Get-Content -Raw (Join-Path $Root ".env.example")
foreach ($name in @(
    "GEOSERVER_ADMIN_PASSWORD",
    "GEOSERVER_MASTER_PASSWORD",
    "POSTGRES_PASSWORD",
    "VIEWER_PASSWORD",
    "ANALYST_PASSWORD",
    "EDITOR_PASSWORD",
    "GRAFANA_ADMIN_PASSWORD",
    "KEYCLOAK_ADMIN_PASSWORD"
)) {
    $text = [regex]::Replace($text, "(?m)^$name=.*$", "$name=$(New-Secret)")
}
Set-Content -Path $Dest -Value $text -Encoding ascii
Write-Host "Wrote .env. It stays on this computer."
