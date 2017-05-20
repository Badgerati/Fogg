param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Software
)

# The software will be comma-separated, so split down
$arr = $Software -split ','

# First, install Chocolatey (just the install script from chocolatey.org)
Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://chocolatey.org/install.ps1'))

# Now loop through each, installing it (checking if they have version tags)
$regex = '^(?<name>[a-z\-0-9\.]+)(\((?<version>[0-9\.]+)\)){0,1}$'
$arr | ForEach-Object {
    $value = $_.Trim()

    if ($value -imatch $regex)
    {
        Write-Host "Installing: $($value)"

        $name = $Matches['name']
        $version = $Matches['version']

        # check if we are installing a specific version or the latest
        if ([string]::IsNullOrWhiteSpace($version) -or $version -ieq 'latest')
        {
            choco install "$($name)" -y
        }
        else
        {
            choco install "$($name)" --version "$($version)" -y
        }
    }
    else
    {
        Write-Host "Failed to install $($value), because it didn't match the expected regex"
    }
}