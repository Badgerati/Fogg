# Uninstall
function Remove-Fogg($path)
{
    $current = (Get-EnvironmentVariable -Name 'PATH' -Scope 'Machine')
    $current = $current.Replace($path, [string]::Empty)
    Set-EnvironmentVariable -Name 'PATH' -Value $current -Scope 'Machine'
    $env:PATH = (Get-EnvironmentVariable -Name 'PATH' -Scope 'Machine') + ';' + (Get-EnvironmentVariable -Name 'PATH' -Scope 'User')
}

$path = Join-Path $env:chocolateyPackageFolder 'tools/src'
$pathSemi = "$($path);"

Write-Host 'Removing Fogg from environment Path'
if (($env:Path.Contains($pathSemi)))
{
    Remove-Fogg $pathSemi
}
elseif (($env:Path.Contains($path)))
{
    Remove-Fogg $path
}
