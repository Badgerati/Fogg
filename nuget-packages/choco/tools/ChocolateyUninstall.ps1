# Uninstall
$path = Join-Path $env:chocolateyPackageFolder 'tools/src'

Write-Host 'Removing Fogg from environment Path'
if (($env:Path.Contains($path)))
{
    $current = (Get-EnvironmentVariable -Name 'PATH' -Scope 'Machine')
    $current = $current.Replace($path, [string]::Empty)
    Set-EnvironmentVariable -Name 'PATH' -Value $current -Scope 'Machine'
    $env:PATH = (Get-EnvironmentVariable -Name 'PATH' -Scope 'Machine') + ';' + (Get-EnvironmentVariable -Name 'PATH' -Scope 'User')
}

refreshenv
