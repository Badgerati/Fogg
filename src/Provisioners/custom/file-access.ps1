param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Path,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $UserName,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Permission,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Access
)

# basic validation
if (!(Test-Path $Path))
{
    throw "Path to alter permissions does not exist: $($Path)"
}

# update placeholder in username
$UserName = $UserName -ireplace [Regex]::Escape('${COMPUTERNAME}'), $env:COMPUTERNAME

# get the path's current permissions
$acl = Get-Acl -Path $Path -ErrorAction Stop
if (!$? -or $acl -eq $null)
{
    throw "Failed to get Access Control permissions for $($Path)"
}

# check if the user is already setup
$user = $acl.Access | ForEach-Object { $_.identityReference.value | Where-Object { $_ -imatch [Regex]::Escape($UserName) } } | Select-Object -First 1

# grant/deny new user access to path
if ([string]::IsNullOrWhiteSpace($user))
{
    $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($UserName, $Permission, 'ContainerInherit,ObjectInherit', 'None', $Access)
    $acl.SetAccessRule($rule)
    if (!$?)
    {
        throw "Failed to assign $($Access) $($Permission) permission for user $($UserName) on path $($Path)"
    }

    # save the updated permissions
    Set-Acl -Path $Path -AclObject $acl -ErrorAction Stop
    if (!$?)
    {
        throw "Failed to update permissions for path $($Path)"
    }
}