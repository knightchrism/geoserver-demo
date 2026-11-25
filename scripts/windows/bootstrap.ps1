# Start the stack, load data, and publish layers. Run new-env.ps1 first.
$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $Root
if (-not (Test-Path ".env")) {
    Write-Error "Missing .env. Run scripts\windows\new-env.ps1 first."
}
docker compose up -d
Write-Host "Waiting for GeoServer..."
$ready = $false
for ($i = 0; $i -lt 40; $i++) {
    try {
        $response = Invoke-WebRequest -Uri "http://127.0.0.1:8080/geoserver/web/" -UseBasicParsing -TimeoutSec 5
        if ($response.StatusCode -eq 200) { $ready = $true; break }
    } catch { Start-Sleep -Seconds 3 }
}
if (-not $ready) { Write-Error "GeoServer did not become ready." }
if (Get-Command bash -ErrorAction SilentlyContinue) {
    bash scripts/load-data.sh
    bash scripts/configure.sh
} else {
    Write-Host "bash was not found. Install WSL or Git Bash, then run scripts/load-data.sh and scripts/configure.sh."
    exit 1
}
Write-Host "Bootstrap finished. Open https://localhost/"
