
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


function Test-TemplateHasVMs
{
    param (
        [Parameter(Mandatory=$true)]
        $Template
    )

    if (($Template | Measure-Object).Count -eq 0)
    {
        return $false
    }

    foreach ($obj in $Template)
    {
        if ($obj.type -ieq 'vm')
        {
            return $true
        }
    }

    return $false
}


function Test-VMCoresExceedMax
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Groups
    )

    # if no groups, then return false
    if (Test-ArrayEmpty $Groups)
    {
        return $false
    }

    # current amount of cores to use
    $cores = 0
    $loc = [string]::Empty

    # loop through each group, tallying up the cores
    foreach ($group in $groups)
    {
        $template = Get-JSONContent $group.TemplatePath
        $os = $template.os

        # if the template contains no VMs, move along
        if (!(Test-TemplateHasVMs -Template $template.template))
        {
            continue
        }

        # loop through each template object - only including VM types
        foreach ($obj in $template.template)
        {
            if ($obj.type -ine 'vm')
            {
                continue
            }

            # local or global OS?
            if ($obj.os -eq $null)
            {
                $size = $os.size
            }
            else
            {
                $size = $obj.os.size
            }

            # get the number of cores and add to total
            if ([string]::IsNullOrWhiteSpace($loc))
            {
                $loc = $group.Location
            }

            $cores += (Get-AzureRmVMSize -Location $group.Location | Where-Object { $_.Name -ieq $size }).NumberOfCores
        }
    }

    # if cores is still 0, then just return false
    if ($cores -eq 0)
    {
        return $false
    }

    # check to see if this exceeds the max
    $azureTotal = (Get-AzureRmVMUsage -Location $loc | Where-Object { $_.Name.Value -ieq 'cores' })
    $azureCurrent = $azureTotal.CurrentValue
    $azureMax = $azureTotal.Limit
    $azureToBe = ($azureCurrent + $cores)

    if ($azureToBe -gt $azureMax)
    {
        Write-Notice "Your Azure Subscription in $($loc) has a maximum limit of $($azureMax) cores"
        Write-Notice "You are currently using $($azureCurrent) of those cores, and are attempting to deploy a further $($cores) core(s)"
        return $true
    }

    return $false
}


function Test-Template
{
    param (
        [Parameter(Mandatory=$true)]
        $Template,

        [Parameter(Mandatory=$true)]
        $FoggObject,

        $OS
    )

    # get the count of template objects to create
    $templateCount = ($Template | Measure-Object).Count
    if ($templateCount -eq 0)
    {
        throw 'No template section was found in Fogg Azure template file'
    }

    # ensure the global OS setting is correct
    if ($OS -ne $null)
    {
        Test-TemplateVMOS -Tag 'global' -OS $OS
    }

    # flag variable helpers
    $alreadyHasVpn = $false
    $tagMap = @()

    # loop through each template object, verifying it
    foreach ($obj in $Template)
    {
        # ensure each template has a tag, and a type
        $tag = $obj.tag
        $type = $obj.type

        if (Test-Empty $tag)
        {
            throw 'All template objects in Fogg Azure template file require a tag name'
        }

        if (Test-Empty $type)
        {
            throw 'All template objects in Fogg Azure template file require a type'
        }

        # check tag uniqueness and value validity
        $tag = $tag.ToLowerInvariant()

        if ($tag -inotmatch '^[a-z0-9]+$')
        {
            throw "Tag name for template object $($tag) must be a valid alphanumerical value"
        }

        if ($tagMap.Contains($tag))
        {
            throw "There is already a template object with tag value '$($tag)'"
        }

        $tagMap += $tag

        # verify based on template object type
        switch ($type.ToLowerInvariant())
        {
            'vm'
                {
                    Test-TemplateVM -VM $obj -FoggObject $FoggObject -OS $OS
                }

            'vpn'
                {
                    if ($alreadyHasVpn)
                    {
                        throw "Cannot have 2 VPN template objects"
                    }

                    Test-TemplateVPN -VPN $obj -FoggObject $FoggObject
                    $alreadyHasVpn = $true
                }

            default
                {
                    throw "Invalid template object type found in $($tag): $($type)"
                }
        }
    }

    return $templateCount
}


function Test-TemplateVPN
{
    param (
        [Parameter(Mandatory=$true)]
        $VPN,

        [Parameter(Mandatory=$true)]
        $FoggObject
    )

    # get tag
    $tag = $VPN.tag.ToLowerInvariant()

    # ensure that the VPN object has a subnet map
    if (!$FoggObject.SubnetAddressMap.Contains($tag))
    {
        throw "No subnet address mapped for the $($tag) VPN template object"
    }

    # ensure we have a VPN Gateway IP in subnet map
    $tagGIP = "$($tag)-gip"
    if (!$FoggObject.SubnetAddressMap.Contains($tagGIP))
    {
        throw "No Gateway IP mapped for the $($tag) VPN: $($tagGIP)"
    }

    # ensure we have a on-premises address prefixes in subnet map
    $tagOpm = "$($tag)-opm"
    if (!$FoggObject.SubnetAddressMap.Contains($tagOpm))
    {
        throw "No On-Premises address prefix(es) mapped for the $($tag) VPN: $($tagOpm)"
    }

    # ensure we have a valid VPN type
    if ($VPN.vpnType -ine 'RouteBased' -and $VPN.vpnType -ine 'PolicyBased')
    {
        throw "VPN type for $($tag) must be one of either 'RouteBased' or 'PolicyBased'"
    }

    # ensure we have a Gateway SKU
    if (Test-Empty $VPN.gatewaySku)
    {
        throw "VPN $($tag) has no Gateway SKU specified: Basic, Standard, or HighPerformance"
    }

    # PolicyBased VPN can only have a SKU of Basic
    if ($VPN.vpnType -ieq 'PolicyBased' -and $VPN.gatewaySku -ine 'Basic')
    {
        throw "PolicyBased VPN $($tag) can only have a Gateway SKU of 'Basic'"
    }

    # ensure we have a shared key
    if (Test-Empty $VPN.sharedKey)
    {
        throw "VPN $($tag) has no shared key specified"
    }
}


function Test-TemplateVM
{
    param (
        [Parameter(Mandatory=$true)]
        $VM,

        [Parameter(Mandatory=$true)]
        $FoggObject,

        $OS
    )

    # is there an OS section?
    $hasOS = ($OS -ne $null)

    # get tag
    $tag = $VM.tag.ToLowerInvariant()

    # ensure that each VM object has a subnet map
    if (!$FoggObject.SubnetAddressMap.Contains($tag))
    {
        throw "No subnet address mapped for the $($tag) VM template object"
    }

    # ensure VM count is not null or negative/0
    if ($vm.count -eq $null -or $vm.count -le 0)
    {
        throw "VM count cannot be null, 0 or negative for $($tag): $($vm.count)"
    }

    # ensure the off count is not negative or greater than VM count
    if ($vm.off -ne $null -and ($vm.off -le 0 -or $vm.off -gt $vm.count))
    {
        throw "VMs to turn off cannot be negative or greater than VM count for $($tag): $($vm.off)"
    }

    # if there's more than one VM (load balanced) a port is required
    $useLoadBalancer = $true
    if (!(Test-Empty $vm.useLoadBalancer))
    {
        $useLoadBalancer = [bool]$VMTemplate.useLoadBalancer
    }

    if (!(Test-Empty $vm.useAvailabilitySet) -and $vm.useAvailabilitySet -eq $false)
    {
        $useLoadBalancer = $false
    }

    if ($vm.count -gt 1 -and $useLoadBalancer -and (Test-Empty $vm.port))
    {
        throw "A valid port value is required for the $($tag) VM template object for load balancing"
    }

    # ensure that each VM has an OS setting if global OS does not exist
    if (!$hasOS -and $vm.os -eq $null)
    {
        throw "VM $($tag) is missing OS settings section"
    }

    if ($vm.os -ne $null)
    {
        Test-TemplateVMOS -Tag $tag -OS $vm.os
    }

    # ensure that the provisioner keys exist
    if (!$FoggObject.HasProvisionScripts -and !(Test-ArrayEmpty $vm.provisioners))
    {
        throw "VM $($tag) specifies provisioners, but there is not Provisioner section"
    }

    if ($FoggObject.HasProvisionScripts -and !(Test-ArrayEmpty $vm.provisioners))
    {
        $vm.provisioners | ForEach-Object {
            if (!(Test-ProvisionerExists -FoggObject $FoggObject -ProvisionerName $_))
            {
                throw "Provisioner key not specified in Provisioners section for $($tag): $($_)"
            }
        }
    }

    # ensure firewall rules are valid
    Test-FirewallRules -FirewallRules $vm.firewall
}


function Test-FirewallRules
{
    param (
        $FirewallRules
    )

    # if no firewall rules then just return
    if ($FirewallRules -eq $null)
    {
        return
    }

    # verify the firewall inbound rules
    if (!(Test-ArrayEmpty $FirewallRules.inbound))
    {
        $FirewallRules.inbound | ForEach-Object {
            Test-FirewallRule -FirewallRule $_
        }
    }

    # verify the firewall outbound rules
    if (!(Test-ArrayEmpty $FirewallRules.outbound))
    {
        $FirewallRules.outbound | ForEach-Object {
            Test-FirewallRule -FirewallRule $_
        }
    }
}


function Test-FirewallRule
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FirewallRule
    )

    # ensure name
    if ([string]::IsNullOrWhiteSpace($FirewallRule.name))
    {
        throw 'A name is required for firewall rules'
    }

    # ensure priority
    if ([string]::IsNullOrWhiteSpace($FirewallRule.priority))
    {
        throw "A priority is required for firewall rule $($FirewallRule.name)"
    }

    if ($FirewallRule.priority -lt 100 -or $FirewallRule.priority -gt 4095)
    {
        throw "The priority must be between 100 and 4095 for firewall rule $($FirewallRule.name)"
    }

    # ensure source
    $regex = '^.+\:.+$'

    if ($FirewallRule.source -inotmatch $regex)
    {
        throw "A source IP and Port range is required for firewall rule $($FirewallRule.name)"
    }

    # ensure destination
    if ($FirewallRule.destination -inotmatch $regex)
    {
        throw "A destination IP and Port range is required for firewall rule $($FirewallRule.name)"
    }

    # ensure access rule
    $accesses = @('Allow', 'Deny')
    if ([string]::IsNullOrWhiteSpace($FirewallRule.access) -or $accesses -inotcontains $FirewallRule.access)
    {
        throw "An access of Allow or Deny is required for firewall rule $($FirewallRule.name)"
    }
}


function Test-TemplateVMOS
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

    $Tag = $Tag.ToLowerInvariant()

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
    $choco = $FoggObject.ProvisionMap['choco'].ContainsKey($ProvisionerName)

    return ($dsc -or $custom -or $choco)
}


function Test-Provisioners
{
    param (
        [Parameter(Mandatory=$true)]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $FoggProvisionersPath,

        $Paths
    )

    # if there are no provisioners, just return
    if (Test-Empty $Paths)
    {
        $FoggObject.HasProvisionScripts = $false
        return
    }

    $FoggObject.HasProvisionScripts = $true

    # ensure the root path exists
    if (!(Test-PathExists $FoggProvisionersPath))
    {
        throw "Fogg root path for internal provisioners does not exist: $($FoggProvisionersPath)"
    }

    # convert the JSON map into a POSH map
    $map = ConvertFrom-JsonObjectToMap $Paths
    $regex = '^\s*(?<type>[a-z0-9]+)\:\s*(?<value>.+?)\s*$'
    $intRegex = '^@\{(?<name>.*?)(\|(?<os>.*?)){0,1}\}$'

    # go through all the keys, validating and adding each one
    ($map.Clone()).Keys | ForEach-Object {
        $value = $map[$_]

        # ensure the value matches a "<type>: <value>" regex, else throw error
        if ($value -imatch $regex)
        {
            # ensure the type is a valid provisioner type
            $type = $Matches['type'].ToLowerInvariant()
            $types = @('dsc', 'custom', 'choco')
            if ($types -inotcontains $type)
            {
                throw "Invalid provisioner type found: $($type), must be one of: $($types -join ',')"
            }

            # is this a choco provisioner?
            $isChoco = ($type -ieq 'choco')
            $isDsc = ($type -ieq 'dsc')

            # get the value
            $value = $Matches['value']

            # check if we're dealing with an internal or custom
            if ($isChoco -or $value -imatch $intRegex)
            {
                # it's an internal script or choco, get name and optional OS type
                if ($isChoco)
                {
                    $name = 'choco-install'
                }
                else
                {
                    $name = $Matches['name'].ToLowerInvariant()
                }

                # get the os type for script extension
                if ($isChoco -or $isDsc)
                {
                    $os = 'win'
                }
                else
                {
                    $os = $Matches['os']
                }

                if (![string]::IsNullOrWhiteSpace($os))
                {
                    $os = $os.ToLowerInvariant()
                }

                # ensure the script exists internally
                switch ($os)
                {
                    'win'
                        {
                            $scriptPath = Join-Path (Join-Path $FoggProvisionersPath $type) "$($name).ps1"
                        }

                    'unix'
                        {
                            $scriptPath = Join-Path (Join-Path $FoggProvisionersPath $type) "$($name).sh"
                        }

                    default
                        {
                            $scriptPath = Join-Path (Join-Path $FoggProvisionersPath $type) "$($name).ps1"
                        }
                }
            }
            else
            {
                # it's a custom script
                $scriptPath = Resolve-Path (Join-Path $FoggObject.TemplateParent $value)
            }

            # ensure the provisioner script path exists
            if (!(Test-PathExists $scriptPath))
            {
                throw "Provision script for $($type) does not exist: $($scriptPath)"
            }

            # add to internal list of provisioners for later
            if (!$FoggObject.ProvisionMap[$type].ContainsKey($_))
            {
                if ($isChoco)
                {
                    $FoggObject.ProvisionMap[$type].Add($_, @($scriptPath, $value))
                }
                else
                {
                    $FoggObject.ProvisionMap[$type].Add($_, $scriptPath)
                }
            }
            else
            {
                if ($isChoco)
                {
                    $FoggObject.ProvisionMap[$type][$_] = @($scriptPath, $value)
                }
                else
                {
                    $FoggObject.ProvisionMap[$type][$_] = $scriptPath
                }
            }
        }
        else
        {
            throw "Provisioner value is not in the correct format of '<type>: <value>': $($value)"
        }
    }
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
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $FoggRootPath,

        [string]
        $ResourceGroupName,

        [string]
        $Location,

        [string]
        $SubscriptionName,

        $SubnetAddresses,

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
        $SubnetAddresses,
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
    $props.FoggProvisionersPath = Join-Path $FoggRootPath 'Provisioners'
    $foggObj = New-Object -TypeName PSObject -Property $props

    # if we aren't using a Foggfile, set params directly
    if (!$useFoggfile)
    {
        Write-Information 'Loading template configuration from CLI'

        $group = New-FoggGroupObject -ResourceGroupName $ResourceGroupName -Location $Location `
            -SubnetAddresses $SubnetAddresses -TemplatePath $TemplatePath -FoggfilePath $FoggfilePath `
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
                -SubnetAddresses $SubnetAddresses -TemplatePath $TemplatePath -FoggfilePath $FoggfilePath `
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

        $SubnetAddresses,

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

        if (Test-Empty $SubnetAddresses)
        {
            $SubnetAddresses = ConvertFrom-JsonObjectToMap $FoggParameters.SubnetAddresses
        }
    }

    # create fogg object with params
    $group = @{}
    $group.ResourceGroupName = $ResourceGroupName
    $group.PreTag = (Remove-RGTag $ResourceGroupName)
    $group.Location = $Location
    $group.VNetAddress = $VNetAddress
    $group.VNetResourceGroupName = $VNetResourceGroupName
    $group.VNetName = $VNetName
    $group.UseExistingVNet = (!(Test-Empty $VNetResourceGroupName) -and !(Test-Empty $VNetName))
    $group.SubnetAddressMap = $SubnetAddresses
    $group.TemplatePath = $TemplatePath
    $group.TemplateParent = (Split-Path -Parent -Path $TemplatePath)
    $group.HasProvisionScripts = $false
    $group.ProvisionMap = @{'dsc' = @{}; 'custom' = @{}; 'choco' = @{}}
    $group.NsgMap = @{}

    $groupObj = New-Object -TypeName PSObject -Property $group

    # test the fogg parameters
    Test-FoggObjectParameters $groupObj

    # post param alterations
    $groupObj.ResourceGroupName = $groupObj.ResourceGroupName.ToLowerInvariant()
    $groupObj.PreTag = $groupObj.PreTag.ToLowerInvariant()

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


function New-DeployTemplateVM
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Template,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $VMTemplate,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $VNet,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $StorageAccount,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [pscredential]
        $VMCredentials
    )

    $tag = $VMTemplate.tag.ToLowerInvariant()
    $tagname = "$($FoggObject.PreTag)-$($tag)"
    $usePublicIP = [bool]$VMTemplate.usePublicIP
    $subnetId = ($VNet.Subnets | Where-Object { $_.Name -ieq "$($tagname)-snet" }).Id

    # are we using a load balancer and availability set?
    $useLoadBalancer = $true
    if (!(Test-Empty $VMTemplate.useLoadBalancer))
    {
        $useLoadBalancer = [bool]$VMTemplate.useLoadBalancer
    }

    $useAvailabilitySet = $true
    if (!(Test-Empty $VMTemplate.useAvailabilitySet))
    {
        $useAvailabilitySet = [bool]$VMTemplate.useAvailabilitySet
    }

    # if useAvailabilitySet is false, then by default set useLoadBalancer to false
    if (!$useAvailabilitySet)
    {
        $useLoadBalancer = $false
    }

    Write-Information "Deploying VMs for $($tag)"

    # if we have more than one server count, create an availability set and load balancer
    if ($VMTemplate.count -gt 1)
    {
        if ($useAvailabilitySet)
        {
            $avset = New-FoggAvailabilitySet -FoggObject $FoggObject -Name "$($tagname)-as"
        }

        if ($useLoadBalancer)
        {
            $lb = New-FoggLoadBalancer -FoggObject $FoggObject -Name "$($tagname)-lb" -SubnetId $subnetId `
                -Port $VMTemplate.port -PublicIP:$usePublicIP
        }
    }

    # create each of the VMs
    $_vms = @()

    1..($VMTemplate.count) | ForEach-Object {
        # does the VM have OS settings, or use global?
        $os = $Template.os
        if ($VMTemplate.os -ne $null)
        {
            $os = $VMTemplate.os
        }

        # create the VM
        $_vms += (New-FoggVM -FoggObject $FoggObject -Name $tagname -VMIndex $_ -VMCredentials $VMCredentials `
            -StorageAccount $StorageAccount -SubnetId $subnetId -VMSize $os.size -VMSkus $os.skus -VMOffer $os.offer `
            -VMType $os.type -VMPublisher $os.publisher -AvailabilitySet $avset -PublicIP:$usePublicIP)
    }

    # loop through each VM and deploy it
    foreach ($_vm in $_vms)
    {
        if ($_vm -eq $null)
        {
            continue
        }

        Save-FoggVM -FoggObject $FoggObject -VM $_vm -LoadBalancer $lb

        # see if we need to provision the machine
        Set-ProvisionVM -FoggObject $FoggObject -Provisioners $VMTemplate.provisioners -VMName $_vm.Name -StorageAccount $StorageAccount

        # due to a bug with the CustomScriptExtension, if we have any uninstall the extension
        Remove-FoggCustomScriptExtension -FoggObject $FoggObject -VMName $_vm.Name
    }

    # turn off some of the VMs if needed
    if ($VMTemplate.off -gt 0)
    {
        $count = ($_vms | Measure-Object).Count
        $base = ($count - $VMTemplate.off) + 1

        $count..$base | ForEach-Object {
            Stop-FoggVM -FoggObject $FoggObject -Name "$($tagname)$($_)"
        }
    }
}


function New-DeployTemplateVPN
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $VPNTemplate,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $VNet
    )

    $tag = $VPNTemplate.tag.ToLowerInvariant()
    $tagname = "$($FoggObject.PreTag)-$($tag)"

    $gatewaySubnetId = ($VNet.Subnets | Where-Object { $_.Name -ieq 'GatewaySubnet' }).Id
    $gatewayIP = $FoggObject.SubnetAddressMap["$($tag)-gip"]
    $addressOnPrem = $FoggObject.SubnetAddressMap["$($tag)-opm"]

    Write-Information "Deploying VPN for $($tag)"

    # create the local network gateway for the VPN
    $lng = New-FoggLocalNetworkGateway -FoggObject $FoggObject -Name "$($tagname)-lng" `
        -GatewayIPAddress $gatewayIP -Address $addressOnPrem

    # create public vnet gateway
    $gw = New-FoggVirtualNetworkGateway -FoggObject $FoggObject -Name "$($tagname)-gw" -VNet $VNet `
        -VpnType $VPNTemplate.vpnType -GatewaySku $VPNTemplate.gatewaySku

    # create VPN connection
    New-FoggVirtualNetworkGatewayConnection -FoggObject $FoggObject -Name "$($tagname)-con" `
        -LocalNetworkGateway $lng -VirtualNetworkGateway $gw -SharedKey $VPNTemplate.sharedKey | Out-Null
}
