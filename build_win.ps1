# Simple Windows Build Script for Obtainium
Write-Host "Cleaning project..." -ForegroundColor Cyan
flutter clean

Write-Host "Fetching dependencies..." -ForegroundColor Cyan
flutter pub get

Write-Host "Building Windows application..." -ForegroundColor Cyan
flutter build windows --release

if ($LASTEXITCODE -eq 0) {
    $distDir = "dist"
    if (Test-Path $distDir) {
        Remove-Item -Recurse -Force $distDir
    }
    New-Item -ItemType Directory -Path $distDir | Out-Null

    $sourceDir = "build/windows/x64/runner/Release"
    
    Write-Host "Copying files to $distDir..." -ForegroundColor Green
    Copy-Item "$sourceDir/obtainium.exe" "$distDir/"
    Copy-Item "$sourceDir/*.dll" "$distDir/"
    Copy-Item -Recurse "$sourceDir/data" "$distDir/"

    Write-Host "Build complete! You can find the app in the '$distDir' folder." -ForegroundColor Green
} else {
    Write-Host "Build failed!" -ForegroundColor Red
}
