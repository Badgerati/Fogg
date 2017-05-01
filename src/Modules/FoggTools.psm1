
function Write-Success
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message
    )

    Write-Host $Message -ForegroundColor Green
}


function Write-Information
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message
    )

    Write-Host $Message -ForegroundColor Magenta
}


function Write-Notice
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message
    )

    Write-Host $Message -ForegroundColor Yellow
}


function Write-Fail
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message
    )

    Write-Host $Message -ForegroundColor Red
}


function Test-PathExists
{
    param (
        [string]
        $Path
    )

    return (![string]::IsNullOrWhiteSpace($Path) -and (Test-Path $Path))
}


function Test-IsArray
{
    param (
        $Value
    )

    if ($Value -eq $null)
    {
        return $false
    }

    return ($Value.GetType().BaseType.Name -ieq 'array')
}


function Test-Empty
{
    param (
        $Value
    )

    if ($Value -eq $null)
    {
        return $true
    }

    if ($Value.GetType().Name -ieq 'string')
    {
        return [string]::IsNullOrWhiteSpace($Value)
    }

    $type = $Value.GetType().BaseType.Name.ToLowerInvariant()
    switch ($type)
    {
        'valuetype'
            {
                return $false
            }

        'array'
            {
                return (($Value | Measure-Object).Count -eq 0 -or $Value.Count -eq 0)
            }
    }

    return ([string]::IsNullOrWhiteSpace($Value) -or ($Value | Measure-Object).Count -eq 0 -or $Value.Count -eq 0)
}


function Test-ArrayEmpty
{
    param (
        $Values
    )

    if (Test-Empty $Values)
    {
        return $true
    }

    foreach ($value in $Values)
    {
        if (!(Test-Empty $value))
        {
            return $false
        }
    }

    return $true
}


function Test-VMs
{
    param (
        [Parameter(Mandatory=$true)]
        $VMs,

        [Parameter(Mandatory=$true)]
        $FoggObject,

        $OS
    )

    Write-Information "Verifying VM template sections"

    # get the count of VM types to create
    $vmCount = ($VMs | Measure-Object).Count
    if ($vmCount -eq 0)
    {
        throw 'No list of VMs was found in Fogg Azure template file'
    }

    # is there an OS section?
    $hasOS = ($OS -ne $null)

    # loop through each VM verifying
    foreach ($vm in $VMs)
    {
        $tag = $vm.tag

        # ensure each VM has a tag
        if (Test-Empty $tag)
        {
            throw 'All VM sections in Fogg Azure template file require a tag name'
        }

        # ensure that each VM section has a subnet map
        if (!$FoggObject.SubnetAddressMap.Contains($tag))
        {
            throw "No subnet address mapped for the $($tag) VM section"
        }

        # ensure VM count is not null or negative/0
        if ($vm.count -eq $null -or $vm.count -le 0)
        {
            throw "VM count cannot be null, 0 or negative: $($vm.count)"
        }

        # ensure the off count is not negative or greater than VM count
        if ($vm.off -ne $null -and ($vm.off -le 0 -or $vm.off -gt $vm.count))
        {
            throw "VMs to turn off cannot be negative or greater than VM count: $($vm.off)"
        }

        # if there's more than one VM (load balanced) a port is required
        if ($vm.count -gt 1 -and (Test-Empty $vm.port))
        {
            throw "A valid port value is required for the $($tag) VM section for load balancing"
        }

        # ensure that each VM has an OS setting if global OS does not exist
        if (!$hasOS -and $vm.os -eq $null)
        {
            throw "VM section $($tag) is missing OS settings section"
        }

        # ensure that the provisioner keys exist
        if (!$FoggObject.HasProvisionScripts -and !(Test-ArrayEmpty $vm.provisioners))
        {
            throw "VM section $($tag) specifies provisioners, but there is not Provisioner section"
        }

        if ($FoggObject.HasProvisionScripts -and !(Test-ArrayEmpty $vm.provisioners))
        {
            $vm.provisioners | ForEach-Object {
                if (!(Test-ProvisionerExists -FoggObject $FoggObject -ProvisionerName $_))
                {
                    throw "Provisioner key not specified in Provisioners section: $($_)"
                }
            }
        }
    }

    Write-Success "VM sections verified"
    return $vmCount
}


function Test-VMOS
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Tag,

        $OS
    )

    if ($OS -eq $null)
    {
        return
    }

    if (Test-Empty $OS.size)
    {
        throw "$($Tag) OS settings must declare a size type"
    }

    if (Test-Empty $OS.publisher)
    {
        throw "$($Tag) OS settings must declare a publisher type"
    }

    if (Test-Empty $OS.offer)
    {
        throw "$($Tag) OS settings must declare a offer type"
    }

    if (Test-Empty $OS.skus)
    {
        throw "$($Tag) OS settings must declare a sku type"
    }

    if (Test-Empty $OS.type)
    {
        throw "$($Tag) OS settings must declare an OS type (Windows/Linux)"
    }

    if ($OS.type -ine 'windows' -and $OS.type -ine 'linux')
    {
        throw "$($Tag) OS settings must declare a valid OS type (Windows/Linux)"
    }
}


function Test-ProvisionerExists
{
    param (
        [Parameter(Mandatory=$true)]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        $ProvisionerName
    )

    if (!$FoggObject.HasProvisionScripts)
    {
        return $false
    }

    $dsc = $FoggObject.ProvisionMap['dsc'].ContainsKey($ProvisionerName)
    $custom =  $FoggObject.ProvisionMap['custom'].ContainsKey($ProvisionerName)

    return ($dsc -or $custom)
}


function Test-Provisioners
{
    param (
        [Parameter(Mandatory=$true)]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        $Paths
    )

    if (Test-Empty $Paths)
    {
        $FoggObject.HasProvisionScripts = $false
        return
    }

    $FoggObject.HasProvisionScripts = $true
    Write-Information "Verifying Provision Scripts"

    $map = ConvertFrom-JsonObjectToMap $Paths
    $regex = '^\s*(?<type>[a-z0-9]+)\:\s*(?<file>.+?)\s*$'

    ($map.Clone()).Keys | ForEach-Object {
        $value = $map[$_]

        if ($value -imatch $regex)
        {
            $type = $Matches['type'].ToLowerInvariant()
            if ($type -ine 'dsc' -and $type -ine 'custom')
            {
                throw "Invalid provisioner type found: $($type)"
            }

            $file = Resolve-Path (Join-Path $FoggObject.TemplateParent $Matches['file'])
            if (!(Test-PathExists $file))
            {
                throw "Provision script for $($type) does not exist: $($file)"
            }

            $FoggObject.ProvisionMap[$type].Add($_, $file)
        }
        else
        {
            throw "Provisioner value is not in the correct format of '<type>: <file>': $($value)"
        }
    }

    Write-Success "Provisioners verified"
}


function Get-JSONContent
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Path
    )

    $json = Get-Content -Path $Path -Raw | ConvertFrom-Json
    if (!$?)
    {
        throw "Failed to parse the JSON content from file: $($Path)"
    }

    return $json
}


function Get-PowerShellVersion
{
    try
    {
        return [decimal]((Get-Host).Version.Major)
    }
    catch
    {
        return [decimal]([string](Get-Host | Select-Object Version).Version)
    }
}


function Test-PowerShellVersion
{
    param (
        [Parameter(Mandatory=$true)]
        [decimal]
        $ExpectedVersion
    )

    return ((Get-PowerShellVersion) -ge $ExpectedVersion)
}


function Remove-RGTag
{
    param (
        [string]
        $Value
    )

    if (Test-Empty $Value)
    {
        return $Value
    }

    return ($Value -ireplace '-rg', '')
}


function ConvertFrom-JsonObjectToMap
{
    param (
        $JsonObject
    )

    $map = @{}

    if ($JsonObject -eq $null)
    {
        return $map
    }

    $JsonObject.psobject.properties.name | ForEach-Object {
        $map.Add($_, $JsonObject.$_)
    }

    return $map
}


function Get-ReplaceSubnet
{
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Value,

        [Parameter(Mandatory=$true)]
        $Subnets,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $CurrentTag
    )

    $regex = '^@\{(?<key>.*?)(\|(?<value>.*?)){0,1}\}$'
    if ($Value -imatch $regex)
    {
        $v = $Matches['value']
        if ([string]::IsNullOrWhiteSpace($v))
        {
            $v = $CurrentTag
        }

        if ($Matches['key'] -ine 'subnet' -or !$Subnets.Contains($v))
        {
            return $Value
        }

        return ($Value -ireplace [Regex]::Escape($Matches[0]), $Subnets[$v])
    }

    return $Value
}


function Get-SubnetPort
{
    param (
        [Parameter(Mandatory=$true)]
        [string[]]
        $Values
    )

    if (($Values | Measure-Object).Count -ge 2)
    {
        return $Values[1]
    }

    return '*'
}


function New-FoggObject
{
    param (
        [string]
        $ResourceGroupName,

        [string]
        $Location,

        [string]
        $SubscriptionName,

        $SubnetAddressMap,

        [string]
        $TemplatePath,

        [string]
        $FoggfilePath,

        [pscredential]
        $SubscriptionCredentials,

        [pscredential]
        $VMCredentials,

        [string]
        $VNetAddress,

        [string]
        $VNetResourceGroupName,

        [string]
        $VNetName
    )

    $useFoggfile = $false

    # are we needing to use a Foggfile? (either path passed, or all params empty)
    if (!(Test-Empty $FoggfilePath))
    {
        $FoggfilePath = (Resolve-Path $FoggfilePath)

        if (!(Test-Path $FoggfilePath))
        {
            throw "Path to Foggfile does not exist: $($FoggfilePath)"
        }

        if ((Get-Item $FoggfilePath) -is [System.IO.DirectoryInfo])
        {
            $FoggfilePath = Join-Path $FoggfilePath 'Foggfile'
            if (!(Test-Path $FoggfilePath))
            {
                throw "Path to Foggfile does not exist: $($FoggfilePath)"
            }
        }

        $useFoggfile = $true
    }

    # if $FoggfilePath not explicitly passed, are all params empty, and does Foggfile exist at root?
    $foggParams = @(
        $ResourceGroupName,
        $Location,
        $SubscriptionName,
        $VNetAddress,
        $VNetResourceGroupName,
        $VNetName,
        $SubnetAddressMap,
        $TemplatePath
    )

    if (!$useFoggfile -and (Test-ArrayEmpty $foggParams))
    {
        if (!(Test-Path 'Foggfile'))
        {
            throw 'No Foggfile found in current directory'
        }

        $FoggfilePath = (Resolve-Path '.\Foggfile')
        $useFoggfile = $true
    }

    # set up the initial Fogg object with group array
    $props = @{}
    $props.Groups = @()
    $props.SubscriptionName = $SubscriptionName
    $props.SubscriptionCredentials = $SubscriptionCredentials
    $props.VMCredentials = $VMCredentials
    $foggObj = New-Object -TypeName PSObject -Property $props

    # if we aren't using a Foggfile, set params directly
    if (!$useFoggfile)
    {
        Write-Information 'Loading template configuration from CLI'

        $group = New-FoggGroupObject -ResourceGroupName $ResourceGroupName -Location $Location `
            -SubnetAddressMap $SubnetAddresses -TemplatePath $TemplatePath -FoggfilePath $FoggfilePath `
            -VNetAddress $VNetAddress -VNetResourceGroupName $VNetResourceGroupName -VNetName $VNetName

        $foggObj.Groups += $group
    }

    # else, we're using a Foggfile, set params and groups appropriately
    elseif ($useFoggfile)
    {
        Write-Information 'Loading template from Foggfile'

        # load Foggfile
        $file = Get-JSONContent $FoggfilePath

        # check to see if we have a Groups array
        if (Test-ArrayEmpty $file.Groups)
        {
            throw 'Missing Groups array in Foggfile'
        }

        # check if we need to set the SubscriptionName from the file
        if (Test-Empty $SubscriptionName)
        {
            $foggObj.SubscriptionName = $file.SubscriptionName
        }

        # load the groups
        $file.Groups | ForEach-Object {
            $group = New-FoggGroupObject -ResourceGroupName $ResourceGroupName -Location $Location `
                -SubnetAddressMap $SubnetAddresses -TemplatePath $TemplatePath -FoggfilePath $FoggfilePath `
                -VNetAddress $VNetAddress -VNetResourceGroupName $VNetResourceGroupName `
                -VNetName $VNetName -FoggParameters $_

            $foggObj.Groups += $group
        }
    }

    # if no subscription name supplied, request one
    if (Test-Empty $foggObj.SubscriptionName)
    {
        $foggObj.SubscriptionName = Read-Host -Prompt 'SubscriptionName'
        if (Test-Empty $foggObj.SubscriptionName)
        {
            throw 'No Azure subscription name has been supplied'
        }
    }

    # return object
    return $foggObj
}

function New-FoggGroupObject
{
    param (
        [string]
        $ResourceGroupName,

        [string]
        $Location,

        $SubnetAddressMap,

        [string]
        $TemplatePath,

        [string]
        $FoggfilePath,

        [string]
        $VNetAddress,

        [string]
        $VNetResourceGroupName,

        [string]
        $VNetName,

        $FoggParameters = $null
    )

    # Only set the params that haven't already got a value (cli overrides foggfile)
    if ($FoggParameters -ne $null)
    {
        if (Test-Empty $ResourceGroupName)
        {
            $ResourceGroupName = $FoggParameters.ResourceGroupName
        }

        if (Test-Empty $Location)
        {
            $Location = $FoggParameters.Location
        }

        if (Test-Empty $VNetAddress)
        {
            $VNetAddress = $FoggParameters.VNetAddress
        }

        if (Test-Empty $VNetResourceGroupName)
        {
            $VNetResourceGroupName = $FoggParameters.VNetResourceGroupName
        }

        if (Test-Empty $VNetName)
        {
            $VNetName = $FoggParameters.VNetName
        }

        if (Test-Empty $TemplatePath)
        {
            # this should be relative to the Foggfile
            $tmp = (Join-Path (Split-Path -Parent -Path $FoggfilePath) $FoggParameters.TemplatePath)
            $TemplatePath = Resolve-Path $tmp -ErrorAction Ignore
            if (!(Test-PathExists $TemplatePath))
            {
                if (!(Test-Empty $TemplatePath))
                {
                    $tmp = $TemplatePath
                }

                throw "Template path supplied does not exist: $(($tmp -replace '\.\.\\') -replace '\.\\')"
            }
        }

        if (Test-Empty $SubnetAddressMap)
        {
            $SubnetAddressMap = ConvertFrom-JsonObjectToMap $FoggParameters.SubnetAddresses
        }
    }

    # create fogg object with params
    $group = @{}
    $group.ResourceGroupName = $ResourceGroupName
    $group.ShortRGName = (Remove-RGTag $ResourceGroupName)
    $group.Location = $Location
    $group.VNetAddress = $VNetAddress
    $group.VNetResourceGroupName = $VNetResourceGroupName
    $group.VNetName = $VNetName
    $group.UseExistingVNet = (!(Test-Empty $VNetResourceGroupName) -and !(Test-Empty $VNetName))
    $group.SubnetAddressMap = $SubnetAddressMap
    $group.TemplatePath = $TemplatePath
    $group.TemplateParent = (Split-Path -Parent -Path $TemplatePath)
    $group.HasProvisionScripts = $false
    $group.ProvisionMap = @{'dsc' = @{}; 'custom' = @{}}
    $group.NsgMap = @{}

    $groupObj = New-Object -TypeName PSObject -Property $group

    # test the fogg parameters
    Test-FoggObjectParameters $groupObj

    # post param alterations
    $groupObj.ResourceGroupName = $groupObj.ResourceGroupName.ToLowerInvariant()
    $groupObj.ShortRGName = $groupObj.ShortRGName.ToLowerInvariant()

    # return object
    return $groupObj
}

function Test-FoggObjectParameters
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject
    )

    # if no resource group name passed, fail
    if (Test-Empty $FoggObject.ResourceGroupName)
    {
        throw 'No resource group name supplied'
    }

    # if no location passed, fail
    if (Test-Empty $FoggObject.Location)
    {
        throw 'No location to deploy VMs supplied'
    }

    # if no vnet address or vnet resource group/name for existing vnet, fail
    if (!$FoggObject.UseExistingVNet -and (Test-Empty $FoggObject.VNetAddress))
    {
        throw 'No address prefix supplied to create virtual network'
    }

    # if no subnets passed, fail
    if (Test-Empty $FoggObject.SubnetAddressMap)
    {
        throw 'No address prefixes for virtual subnets supplied'
    }

    # if the template path doesn't exist, fail
    if (!(Test-Path $FoggObject.TemplatePath))
    {
        throw "Template path supplied does not exist: $($FoggObject.TemplatePath)"
    }
}