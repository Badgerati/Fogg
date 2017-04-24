Write-Host 'Packing Fogg'

# == VERSION =======================================================

Write-Host 'Setting version'
Push-Location './src'

try
{
    (Get-Content 'Fogg.ps1') | ForEach-Object { $_ -replace '\$version\$', $env:BUILD_VERSION } | Set-Content 'Fogg.ps1'
    Write-Host 'Version set'
}
finally
{
    Pop-Location
}

# == BUNDLE =======================================================

Write-Host "Copying scripts into package"
New-Item -ItemType Directory -Path './Package/src'

Copy-Item -Path './src/Modules' -Destination './Package/src/' -Force -Recurse
Copy-Item -Path './src/Fogg.ps1' -Destination './Package/src/' -Force

Write-Host "Scripts copied successfully"

# == ZIP =======================================================

Write-Host "Zipping package"
Push-Location "C:\Program Files\7-Zip\"
$zipName = "$env:BUILD_VERSION-Binaries.zip"

try
{
    .\7z.exe -tzip a "$env:WORKSPACE\$zipName" "$env:WORKSPACE\Package\*"
    Write-Host "Package zipped successfully"
}
finally
{
    Pop-Location
}

# == CHOCO =======================================================

Write-Host "Building Package Checksum"
Push-Location "$env:WORKSPACE"

try
{
    $checksum = (checksum -t sha256 -f $zipName)
    Write-Host "Checksum: $checksum"
}
finally
{
    Pop-Location
}

Write-Host "Building Choco Package"
Push-Location "./nuget-packages/choco"

try
{
    (Get-Content 'fogg.nuspec') | ForEach-Object { $_ -replace '\$version\$', $env:BUILD_VERSION } | Set-Content 'fogg.nuspec'
    cd tools
    (Get-Content 'ChocolateyInstall.ps1') | ForEach-Object { $_ -replace '\$version\$', $env:BUILD_VERSION } | Set-Content 'ChocolateyInstall.ps1'
    (Get-Content 'Chocolateyinstall.ps1') | ForEach-Object { $_ -replace '\$checksum\$', $checksum } | Set-Content 'Chocolateyinstall.ps1'
    cd ..
    choco pack
}
finally
{
    Pop-Location
}

# =========================================================

Write-Host 'Fogg Packed'