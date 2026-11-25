$ErrorActionPreference = "Stop"
$Root = Resolve-Path (Join-Path $PSScriptRoot "..\..")
Set-Location $Root
if (Get-Command bash -ErrorAction SilentlyContinue) {
    bash scripts/smoke-test.sh
} else {
    Write-Error "bash is required to run the smoke test. Use WSL or Git Bash."
}
