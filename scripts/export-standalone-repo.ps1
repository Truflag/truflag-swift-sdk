param(
  [string]$TargetPath = "..\\truflag-swift-sdk"
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$sdkDir = Resolve-Path (Join-Path $scriptDir "..")
$resolvedTarget = [System.IO.Path]::GetFullPath((Join-Path (Get-Location) $TargetPath))

if (Test-Path $resolvedTarget) {
  Remove-Item -LiteralPath $resolvedTarget -Recurse -Force
}
New-Item -ItemType Directory -Path $resolvedTarget | Out-Null

Copy-Item -Path (Join-Path $sdkDir "*") -Destination $resolvedTarget -Recurse -Force

$buildDir = Join-Path $resolvedTarget ".build"
if (Test-Path $buildDir) {
  Remove-Item -LiteralPath $buildDir -Recurse -Force
}
$swiftPmDir = Join-Path $resolvedTarget ".swiftpm"
if (Test-Path $swiftPmDir) {
  Remove-Item -LiteralPath $swiftPmDir -Recurse -Force
}

if (-not (Test-Path (Join-Path $resolvedTarget ".git"))) {
  git -C $resolvedTarget init | Out-Null
}

Write-Host "Standalone SDK exported to: $resolvedTarget"
Write-Host ""
Write-Host "Next steps:"
Write-Host "  1) cd $resolvedTarget"
Write-Host "  2) git remote add origin <your-swift-sdk-repo-url>"
Write-Host "  3) swift test"
Write-Host "  4) pod lib lint TruflagSDK.podspec --allow-warnings"
Write-Host "  5) git add . && git commit -m 'Release prep'"
