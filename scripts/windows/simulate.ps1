$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $Root
if (Get-Command bash -ErrorAction SilentlyContinue) {
    bash scripts/simulate.sh
} else {
    docker compose --profile sim up --no-deps --force-recreate locust
}
