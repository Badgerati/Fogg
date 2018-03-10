
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


function Write-Details
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message
    )

    Write-Host $Message -ForegroundColor Cyan
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


function Write-Warning
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Message
    )

    Write-Host $Message -ForegroundColor DarkRed
}


function Write-Duration
{
    param (
        [Parameter(Mandatory=$true)]
        [DateTime]
        $StartTime,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $PreText,

        [switch]
        $NewLine
    )

    $end = [DateTime]::UtcNow - $StartTime

    if ($NewLine)
    {
        $n = "`n"
    }

    Write-Details "$($n)$($PreText): $($end.ToString())"
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

function Test-ArrayIsUnique
{
    param (
        $Values
    )

    if (Test-Empty $Values)
    {
        return $null
    }

    $dupe = $null

    $Values | ForEach-Object {
        $value = $_
        if (($Values | Where-Object { $_ -ieq $value } | Measure-Object).Count -ne 1)
        {
            $dupe = $value
        }
    }

    return $dupe
}


function Test-TemplateHasType
{
    param (
        [Parameter(Mandatory=$true)]
        $Template,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Type
    )

    if (($Template | Measure-Object).Count -eq 0)
    {
        return $false
    }

    foreach ($obj in $Template)
    {
        if ($obj.type -ieq $Type)
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
    $totalCores = 0

    # set up the regions and individual core counts
    $regions = @{}

    # loop through each group, tallying up the cores per region
    foreach ($group in $groups)
    {
        $template = Get-JSONContent $group.TemplatePath
        $os = $template.os

        # if the template contains no VMs, move along
        if (!(Test-TemplateHasType $template.template 'vm'))
        {
            continue
        }

        # setup the region with an initial count
        if (!$regions.ContainsKey($group.Location))
        {
            $regions.Add($group.Location, 0)
        }

        # store the VM size details to stop multiple calls
        $details = Get-FoggVMSizeDetails $group.Location

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

            # add VM size cores to total cores and regional cores
            $cores = ($details | Where-Object { $_.Name -ieq $size }).NumberOfCores * $obj.count
            $totalCores += $cores
            $regions[$group.Location] += $cores
        }
    }

    # if total cores is 0 or no regions, then just return false
    if ($totalCores -eq 0 -or (Test-ArrayEmpty $regions))
    {
        return $false
    }

    # check to see if this exceeds the max for each region
    $exceeded = $false

    $regions.Keys | ForEach-Object {
        $azureTotal = (Get-FoggVMUsageDetails -Location $_ | Where-Object { $_.Name.Value -ieq 'cores' })
        $azureCurrent = $azureTotal.CurrentValue
        $azureMax = $azureTotal.Limit
        $azureToBe = ($azureCurrent + $regions[$_])

        if ($azureToBe -gt $azureMax)
        {
            Write-Notice "Your Azure Subscription in $($_) has a maximum limit of $($azureMax) cores"
            Write-Notice "You are currently using $($azureCurrent) of those cores, and are attempting to deploy a further $($regions[$_]) core(s)`n"
            $exceeded = $true
        }
        else
        {
            Write-Details "Your Azure Subscription in $($_) has a maximum limit of $($azureMax) cores"
            Write-Details "You are currently using $($azureCurrent) of those cores, and are now deploying a further $($regions[$_]) core(s)`n"
        }
    }

    # return whether we exceeded a regional limit
    return $exceeded
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

    # split out the template objects
    $templateObjs = $Template.template

    # get the count of template objects to create
    $templateCount = ($templateObjs | Measure-Object).Count
    if ($templateCount -eq 0)
    {
        throw 'No template section was found in Fogg Azure template file'
    }

    # ensure the global OS setting is correct
    if ($OS -ne $null)
    {
        Test-TemplateVMOS -Tag 'global' -OS $OS
    }

    # get pretag
    $pretag = $FoggObject.PreTag
    if (!(Test-Empty $Template.pretag))
    {
        $pretag = $Template.pretag.ToLowerInvariant()
    }

    # get unique storage tag
    $saUniqueTag = $FoggObject.SAUniqueTag
    if (!(Test-Empty $Template.saUniqueTag))
    {
        $saUniqueTag = $Template.saUniqueTag.ToLowerInvariant()
    }

    # ensure the storage account name is valid - but only if we have VMs
    if (Test-TemplateHasType $templateObjs 'vm')
    {
        $usePremiumStorage = [bool]$Template.usePremiumStorage
        $saName = Get-FoggStorageAccountName -Name "$($saUniqueTag)-$($pretag)" -Premium:$usePremiumStorage
        Test-FoggStorageAccountName $saName
    }

    # flag variable helpers
    $alreadyHasVpn = $false
    $tagMap = @()

    # loop through each template object, verifying it
    foreach ($obj in $templateObjs)
    {
        # ensure each template has a tag, and a type
        $tag = $obj.tag
        $type = $obj.type

        if (Test-Empty $tag)
        {
            throw 'All template objects in a Fogg Azure template file require a tag name'
        }

        if (Test-Empty $type)
        {
            throw 'All template objects in a Fogg Azure template file require a type'
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
                    Test-TemplateVM -VM $obj -PreTag $pretag -FoggObject $FoggObject -OS $OS
                }

            'vpn'
                {
                    if ($alreadyHasVpn)
                    {
                        throw "Cannot have 2 VPN template objects"
                    }

                    Test-TemplateVPN -VPN $obj -PreTag $pretag -FoggObject $FoggObject
                    $alreadyHasVpn = $true
                }

            'vnet'
                {
                    Test-TemplateVNet -VNet $obj -PreTag $pretag -FoggObject $FoggObject
                }

            default
                {
                    throw "Invalid template object type found in $($tag): $($type)"
                }
        }
    }

    return $templateCount
}


function Test-TemplateVNet
{
    param (
        [Parameter(Mandatory=$true)]
        $VNet,

        [Parameter(Mandatory=$true)]
        $PreTag,

        [Parameter(Mandatory=$true)]
        $FoggObject
    )

    # get tag
    $tag = $VNet.tag.ToLowerInvariant()

    # ensure we have an address
    if (Test-Empty $VNet.address)
    {
        throw "VNet for $($tag) has no address prefix"
    }

    # ensure subnets have names and addresses
    $subnets = ConvertFrom-JsonObjectToMap $VNet.subnets
    $subnets.Keys | ForEach-Object {
        if (Test-Empty $_)
        {
            throw "Subnet on Vnet for $($tag) has an undefined name"
        }

        if (Test-Empty $subnets[$_])
        {
            throw "Subnet $($_) on Vnet for $($tag) has a no address prefix"
        }
    }
}


function Test-TemplateVPN
{
    param (
        [Parameter(Mandatory=$true)]
        $VPN,

        [Parameter(Mandatory=$true)]
        $PreTag,

        [Parameter(Mandatory=$true)]
        $FoggObject
    )

    # get tag
    $tag = $VPN.tag.ToLowerInvariant()

    # ensure that the VPN object has a subnet map
    if (!$FoggObject.SubnetAddressMap.Contains($tag))
    {
        throw "No subnet address mapped for the VPN template object"
    }

    # ensure we have a valid VPN type
    if ($VPN.vpnType -ine 'RouteBased' -and $VPN.vpnType -ine 'PolicyBased')
    {
        throw "VPN type for $($tag) must be one of either 'RouteBased' or 'PolicyBased'"
    }

    # ensure we have a Gateway SKU
    if (Test-Empty $VPN.gatewaySku)
    {
        throw "VPN has no Gateway SKU specified: Basic, Standard, or HighPerformance"
    }

    # PolicyBased VPN can only have a SKU of Basic
    if ($VPN.vpnType -ieq 'PolicyBased' -and $VPN.gatewaySku -ine 'Basic')
    {
        throw "PolicyBased VPN can only have a Gateway SKU of 'Basic'"
    }

    # Do we have a valid VPN config
    $configTypes = @('s2s', 'p2s', 'v2v')
    if ((Test-Empty $VPN.configType) -or $configTypes -inotcontains $VPN.configType)
    {
        throw "VPN configuration must be one of the following: $($configTypes -join ', ')"
    }

    # continue rest of validation based on VPN configuration
    switch ($VPN.configType.ToLowerInvariant())
    {
        's2s'
            {
                # ensure we have a VPN Gateway IP in subnet map
                $tagGIP = "$($tag)-gip"
                if (!$FoggObject.SubnetAddressMap.Contains($tagGIP))
                {
                    throw "No Gateway IP mapped for the VPN: $($tagGIP)"
                }

                # ensure we have a on-premises address prefixes in subnet map
                $tagOpm = "$($tag)-opm"
                if (!$FoggObject.SubnetAddressMap.Contains($tagOpm))
                {
                    throw "No On-Premises address prefix(es) mapped for the VPN: $($tagOpm)"
                }

                # ensure we have a shared key
                if (Test-Empty $VPN.sharedKey)
                {
                    throw "VPN has no shared key specified"
                }
            }

        'p2s'
            {
                # ensure we have a VPN client address pool in subnet map
                $tagCAP = "$($tag)-cap"
                if (!$FoggObject.SubnetAddressMap.Contains($tagCAP))
                {
                    throw "No VPN Client Address Pool mapped for the VPN: $($tagCAP)"
                }

                # ensure we have a cert path, and it exists
                if (Test-Empty $VPN.certPath)
                {
                    throw "VPN has no public certificate (.cer) path specified"
                }

                if (!(Test-PathExists $VPN.certPath))
                {
                    throw "VPN public certificate path does not exist: $($VPN.certPath)"
                }

                # ensure the certificate extension is .cer
                $file = Split-Path -Leaf -Path $VPN.certPath
                if ([System.IO.Path]::GetExtension($file) -ine '.cer')
                {
                    throw "VPN public certificate is not a valid .cer file: $($file)"
                }
            }

        default
            {
                throw 'VNet-to-VNet VPN configurations are not supported yet'
            }
    }
}


function Test-TemplateVM
{
    param (
        [Parameter(Mandatory=$true)]
        $VM,

        [Parameter(Mandatory=$true)]
        $PreTag,

        [Parameter(Mandatory=$true)]
        $FoggObject,

        $OS
    )

    # is there an OS section?
    $hasOS = ($OS -ne $null)
    $mainOS = $OS

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

    # ensure that if append is true, off count is not supplied
    if ($vm.append -and $vm.off -ne $null -and $vm.off -gt 0)
    {
        throw "VMs to turn off cannot be supplied if append property is true for $($tag)"
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
        throw "A valid port value is required for the '$($tag)' VM template for load balancing"
    }

    # ensure that each VM has an OS setting if global OS does not exist
    if (!$hasOS -and $vm.os -eq $null)
    {
        throw "The '$($tag)' VM template is missing the OS settings section"
    }

    if ($vm.os -ne $null)
    {
        Test-TemplateVMOS -Tag $tag -OS $vm.os
        $mainOS = $vm.os
    }

    # ensure the VM name is valid
    $vmName = Get-FoggVMName "$($PreTag)-$($tag)" $vm.count
    Test-FoggVMName -OSType $mainOS.type -Name $vmName

    # ensure that the provisioner keys exist
    if (!$FoggObject.HasProvisionScripts -and !(Test-ArrayEmpty $vm.provisioners))
    {
        throw "The '$($tag)' VM template specifies provisioners, but there is no Provisioner section"
    }

    if ($FoggObject.HasProvisionScripts -and !(Test-ArrayEmpty $vm.provisioners))
    {
        $vm.provisioners | ForEach-Object {
            $key = ($_ -split '\:')[0]

            if (Test-Empty $key)
            {
                throw "Provisioner key cannot be empty in '$($tag)' VM template"
            }

            if (!(Test-ProvisionerExists -FoggObject $FoggObject -ProvisionerName $key))
            {
                throw "Provisioner key not specified in Provisioners section for the '$($tag)' VM template: $($key)"
            }
        }
    }

    # ensure firewall rules are valid
    Test-FirewallRules -FirewallRules $vm.firewall

    # if the VM has extra drives, ensure the section is valid and add the provisioner
    if (!(Test-ArrayEmpty $vm.drives))
    {
        # ensure other values are correct
        $vm.drives | ForEach-Object {
            # ensure sizes are greater than 0
            if ($_.size -eq $null -or $_.size -le 0)
            {
                throw "Drive '$($_.name)' in the $($tag) VM template must have a size greater than 0Gb"
            }

            # ensure LUNs are greater than 0
            if ($_.lun -eq $null -or $_.lun -le 0)
            {
                throw "Drive '$($_.name)' in the $($tag) VM template must have a LUN greater than 0"
            }

            # ensure drives and letters aren't empty
            if (Test-Empty $_.name)
            {
                throw "Drive '$($_.letter)' in the $($tag) VM template has no drive name supplied"
            }

            if (Test-Empty $_.letter)
            {
                throw "Drive '$($_.name)' in the $($tag) VM template has no drive letter supplied"
            }

            # ensure the drive letter is not one of the reserved ones
            $reservedDrives = @('A', 'B', 'C', 'D', 'E', 'Z')
            if ($reservedDrives -icontains $_.letter)
            {
                throw "Drive '$($_.name)' in the $($tag) VM template cannot use one of the following drive letters: $($reservedDrives -join ', ')"
            }

            if ($_.letter -inotmatch '^[a-z]{1}$')
            {
                throw "Drive '$($_.name)' in the $($tag) VM template must have a valid alpha drive letter"
            }

            # ensure the name is alphanumeric
            if ($_.name -inotmatch '^[a-z0-9 ]+$')
            {
                throw "Drive '$($_.name)' in the $($tag) VM template must have a valid alphanumeric drive name"
            }

            # ensure caching value is correct
            $cachings = @('ReadOnly', 'ReadWrite', 'None')
            if (![string]::IsNullOrWhiteSpace($_.caching) -and $cachings -inotcontains $_.caching)
            {
                throw "Drive '$($_.name)' in the $($tag) VM template has an invalid caching option '$($_.caching)', valid values: $($cachings -join ', ')"
            }
        }

        # ensure the LUNs are unique
        $dupe = Test-ArrayIsUnique $vm.drives.lun
        if ($dupe -ne $null)
        {
            throw "Drive LUNs need to be unique, found two drives with LUN '$($dupe)' for the $($tag) VM template"
        }

        # ensure the name are unique
        $dupe = Test-ArrayIsUnique $vm.drives.name
        if ($dupe -ne $null)
        {
            throw "Drive names need to be unique, found two drives with name '$($dupe)' for the $($tag) VM template"
        }

        # ensure the letters are unique
        $dupe = Test-ArrayIsUnique $vm.drives.letter
        if ($dupe -ne $null)
        {
            throw "Drive letters need to be unique, found two drives with letter '$($dupe)' for the $($tag) VM template"
        }

        # get the drive names
        $drives = $vm.drives.name -join ','
        $letters = $vm.drives.letter -join ','

        # add provisioner
        $scriptPath = Get-ProvisionerInternalPath -FoggObject $FoggObject -Type 'drives' -ScriptName 'attach-drives' -OS 'win'
        Add-Provisioner -FoggObject $FoggObject -Key 'attach-drives' -Type 'drives' -ScriptPath $scriptPath -Arguments "$($letters) | $($drives)"
    }
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

    # verify inbuilt firewall ports exist
    $portMap = Get-FirewallPortMap
    $keys = $FirewallRules.psobject.properties.name
    $regex = '^(?<name>.+?)(\|(?<direction>in|out|both)){0,1}$'

    foreach ($key in $keys)
    {
        # if key doesnt match regex, throw error
        if ($key -inotmatch $regex)
        {
            throw "Firewall rule with key '$($key)' is invalid. Should be either 'inbound', 'outbound', or of the format '<name>|<direction>'"
        }

        # set port name and direction (default to inbound)
        $portname = $Matches['name'].ToLowerInvariant()

        # if in/outbound then continue
        if ($portname -ieq 'inbound' -or $portname -ieq 'outbound')
        {
            continue
        }

        # if port doesnt exist, throw error
        if (!$portMap.ContainsKey($portname))
        {
            throw "Inbuilt firewall rule for port type $($portname) does not exist"
        }
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
        [ValidateNotNullOrEmpty()]
        $ProvisionerName
    )

    if (!$FoggObject.HasProvisionScripts)
    {
        return $false
    }

    $ProvisionerName = $ProvisionerName.Trim()

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

        $Paths
    )

    # if there are no provisioners, just return
    if (Test-Empty $Paths)
    {
        $FoggObject.HasProvisionScripts = $false
        return
    }

    # convert the JSON map into a POSH map
    $map = ConvertFrom-JsonObjectToMap $Paths
    $regex = '^\s*(?<type>[a-z0-9]+)\:\s*(?<value>.+?)\s*$'
    $intRegex = '^@\{(?<name>.+?)(\|(?<os>.*?)){0,1}\}$'

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

                # get the internal path
                $scriptPath = Get-ProvisionerInternalPath -FoggObject $FoggObject -Type $type -ScriptName $name -OS $os
            }
            else
            {
                # it's a custom script
                $scriptPath = Resolve-Path (Join-Path $FoggObject.TemplateParent $value) -ErrorAction Ignore
            }

            # add to internal list of provisioners for later
            if ($isChoco)
            {
                Add-Provisioner -FoggObject $FoggObject -Key $_ -Type $type -ScriptPath $scriptPath -Arguments $value
            }
            else
            {
                Add-Provisioner -FoggObject $FoggObject -Key $_ -Type $type -ScriptPath $scriptPath
            }
        }
        else
        {
            throw "Provisioner value is not in the correct format of '<type>: <value>': $($value)"
        }
    }
}


function Get-ProvisionerInternalPath
{
    param (
        [Parameter(Mandatory=$true)]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Type,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ScriptName,

        [string]
        $OS = 'win'
    )

    # ensure the root path exists
    if (!(Test-PathExists $FoggObject.ProvisionersPath))
    {
        throw "Fogg root path for internal provisioners does not exist: $($FoggObject.ProvisionersPath)"
    }

    # ensure OS type is lowercase
    if (![string]::IsNullOrWhiteSpace($OS))
    {
        $OS = $OS.ToLowerInvariant()
    }

    # generate internal script path
    switch ($OS)
    {
        'win'
            {
                $scriptPath = Join-Path (Join-Path $FoggObject.ProvisionersPath $Type) "$($ScriptName).ps1"
            }

        'unix'
            {
                $scriptPath = Join-Path (Join-Path $FoggObject.ProvisionersPath $Type) "$($ScriptName).sh"
            }

        default
            {
                $scriptPath = Join-Path (Join-Path $FoggObject.ProvisionersPath $Type) "$($ScriptName).ps1"
            }
    }

    return $scriptPath
}


function Add-Provisioner
{
    param (
        [Parameter(Mandatory=$true)]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Key,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Type,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ScriptPath,

        [string]
        $Arguments = $null
    )

    # ensure the provisioner script path exists
    if (!(Test-PathExists $ScriptPath))
    {
        throw "Provision script for $($Key) does not exist: $($ScriptPath)"
    }

    $FoggObject.HasProvisionScripts = $true

    # add provisioner to internal map
    if (!$FoggObject.ProvisionMap[$Type].ContainsKey($Key))
    {
        if ($Arguments -eq $null)
        {
            $FoggObject.ProvisionMap[$Type].Add($Key, @($ScriptPath))
        }
        else
        {
            $FoggObject.ProvisionMap[$Type].Add($Key, @($ScriptPath, $Arguments))
        }
    }
    else
    {
        if ($Arguments -eq $null)
        {
            $FoggObject.ProvisionMap[$Type][$Key] = @($ScriptPath)
        }
        else
        {
            $FoggObject.ProvisionMap[$Type][$Key] = @($ScriptPath, $Arguments)
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

    $regex = '^@\{(?<key>.+?)(\|(?<value>.*?)){0,1}\}$'
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


function Get-NameFromAzureId
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Id
    )

    return (Split-Path -Leaf -Path $Id).ToLowerInvariant()
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
        $path = (Resolve-Path $FoggfilePath -ErrorAction Ignore)
        if (!(Test-PathExists $FoggfilePath))
        {
            throw "Path to Foggfile does not exist: $($FoggfilePath)"
        }

        if ((Get-Item $path) -is [System.IO.DirectoryInfo])
        {
            $path = Join-Path $path 'Foggfile'
            if (!(Test-PathExists $path))
            {
                throw "Path to Foggfile does not exist: $($path)"
            }
        }

        $FoggfilePath = $path
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
        if (!(Test-PathExists 'Foggfile'))
        {
            throw 'No Foggfile found in current directory'
        }

        $FoggfilePath = (Resolve-Path '.\Foggfile' -ErrorAction Ignore)
        $useFoggfile = $true
    }

    # set up the initial Fogg object with group array
    $props = @{}
    $props.Groups = @()
    $props.SubscriptionName = $SubscriptionName
    $props.SubscriptionCredentials = $SubscriptionCredentials
    $props.VMCredentials = $VMCredentials
    $foggObj = New-Object -TypeName PSObject -Property $props

    # general paths
    $provisionPath = Join-Path $FoggRootPath 'Provisioners'

    # if we aren't using a Foggfile, set params directly
    if (!$useFoggfile)
    {
        $group = New-FoggGroupObject -ResourceGroupName $ResourceGroupName -Location $Location `
            -SubnetAddresses $SubnetAddresses -TemplatePath $TemplatePath -FoggfilePath $FoggfilePath `
            -VNetAddress $VNetAddress -VNetResourceGroupName $VNetResourceGroupName -VNetName $VNetName

        $group.ProvisionersPath = $provisionPath
        $foggObj.Groups += $group
    }

    # else, we're using a Foggfile, set params and groups appropriately
    elseif ($useFoggfile)
    {
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

            $group.ProvisionersPath = $provisionPath
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

    # standardise
    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $VNetResourceGroupName = (Get-FoggResourceGroupName $VNetResourceGroupName)
    $VNetName = (Get-FoggVirtualNetworkName $VNetName)

    # create fogg object with params
    $group = @{}
    $group.ResourceGroupName = $ResourceGroupName
    $group.PreTag = (Remove-RGTag $ResourceGroupName)
    $group.SAUniqueTag = [string]::Empty
    $group.Location = $Location
    $group.VNetAddress = $VNetAddress
    $group.VNetResourceGroupName = $VNetResourceGroupName
    $group.VNetName = $VNetName
    $group.UseExistingVNet = (!(Test-Empty $VNetResourceGroupName) -and !(Test-Empty $VNetName))
    $group.UseGlobalVNet = ($group.UseExistingVNet -or !(Test-Empty $VNetAddress))
    $group.SubnetAddressMap = $SubnetAddresses
    $group.TemplatePath = $TemplatePath
    $group.TemplateParent = (Split-Path -Parent -Path $TemplatePath)
    $group.HasProvisionScripts = $false
    $group.ProvisionMap = @{'dsc' = @{}; 'custom' = @{}; 'choco' = @{}; 'drives' = @{}}
    $group.NsgMap = @{}
    $group.ProvisionersPath = $null
    $group.StorageAccountName = $null
    $group.VirtualMachineInfo = @{}
    $group.VirtualNetworkInfo = @{}
    $group.VPNInfo = @{}

    $groupObj = New-Object -TypeName PSObject -Property $group

    # validate the fogg parameters
    Test-FoggObjectParameters $groupObj

    # post param alterations
    $groupObj.ResourceGroupName = $groupObj.ResourceGroupName
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

    # if the template path doesn't exist, fail
    if (!(Test-PathExists $FoggObject.TemplatePath))
    {
        throw "Template path supplied does not exist: $($FoggObject.TemplatePath)"
    }

    # read in the template to check for object types
    $template = Get-JSONContent $FoggObject.TemplatePath

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

    # only validate vnet/snet if template has vms/vpns
    if ((Test-TemplateHasType $template.template 'vm') -or (Test-TemplateHasType $template.template 'vpn'))
    {
        # if no vnet address or vnet resource group/name for existing vnet, fail
        if (!$FoggObject.UseExistingVNet -and (Test-Empty $FoggObject.VNetAddress))
        {
            throw 'No address prefix, or resource group and vnet name, supplied to create, or re-use, virtual network'
        }

        # if no subnets passed, fail
        if (Test-Empty $FoggObject.SubnetAddressMap)
        {
            throw 'No address prefixes for virtual subnets supplied'
        }
    }

    # validate resource group name lengths
    Test-FoggResourceGroupName $FoggObject.ResourceGroupName
    Test-FoggResourceGroupName $FoggObject.VNetResourceGroupName -Optional
}


function New-DeployTemplateVNet
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $VNetTemplate,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject
    )

    $startTime = [DateTime]::UtcNow
    $tag = $VNetTemplate.tag.ToLowerInvariant()
    $tagname = "$($FoggObject.PreTag)-$($tag)"
    
    # VNet information
    $FoggObject.VirtualNetworkInfo.Add($tag, @{})
    $vnetInfo = $FoggObject.VirtualNetworkInfo[$tag]
    $vnetInfo.Add('Address', $VNetTemplate.address)
    $vnetInfo.Add('Subnets', @())

    Write-Information "Deploying VNet for the '$($tag)' template"

    # create the virtual network
    $vnet = New-FoggVirtualNetwork -ResourceGroupName $FoggObject.ResourceGroupName -Name $tagname `
        -Location $FoggObject.Location -Address $VNetTemplate.address

    $vnetInfo.Add('Name', $vnet.Name)

    # add the subnets to the vnet
    $subnets = ConvertFrom-JsonObjectToMap $VNetTemplate.subnets

    $subnets.Keys | ForEach-Object {
        $snetName = (Get-FoggSubnetName $_)

        $vnet = Add-FoggSubnetToVNet -ResourceGroupName $FoggObject.ResourceGroupName -VNetName $vnet.Name `
            -SubnetName $snetName -Address $subnets[$_]

        $vnetInfo.Subnets += @{
            'Name' = $snetName;
            'Address' = $subnets[$_]
        }
    }

    # output the time taken to create VNet
    Write-Duration $startTime -PreText 'VNet Duration'
    Write-Host ([string]::Empty)
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
    $subnetPrefix = $FoggObject.SubnetAddressMap[$tag]
    $subnetName = (Get-FoggSubnetName $tagname)
    $subnet = ($VNet.Subnets | Where-Object { $_.Name -ieq $subnetName -or $_.AddressPrefix -ieq $subnetPrefix })

    # VM information
    $FoggObject.VirtualMachineInfo.Add($tag, @{})
    $vmInfo = $FoggObject.VirtualMachineInfo[$tag]
    $vmInfo.Add('Subnet', @{})
    $vmInfo.Add('AvailabilitySet', $null)
    $vmInfo.Add('LoadBalancer', @{})
    $vmInfo.Add('VirtualMachines', @())

    # set subnet details against VM info
    $vmInfo.Subnet.Add('Name', $subnet.Name)
    $vmInfo.Subnet.Add('Address', $subnetPrefix)

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

    Write-Information "Deploying $($VMTemplate.count) VM(s) for the '$($tag)' template"

    # create an availability set and, if VM count > 1, a load balancer
    if ($useAvailabilitySet)
    {
        $avsetName = (Get-FoggAvailabilitySetName $tagname)
        $avset = New-FoggAvailabilitySet -FoggObject $FoggObject -Name $avsetName
        $vmInfo.AvailabilitySet = $avsetName
    }

    if ($useLoadBalancer -and $VMTemplate.count -gt 1)
    {
        $lbName = (Get-FoggLoadBalancerName $tagname)
        $lb = New-FoggLoadBalancer -FoggObject $FoggObject -Name $lbName -SubnetId $subnet.Id `
            -Port $VMTemplate.port -PublicIP:$usePublicIP

        $vmInfo.LoadBalancer.Add('Name', $lbName)
        $vmInfo.LoadBalancer.Add('PublicIP', $lb.FrontendIpConfigurations[0].PublicIpAddress)
        $vmInfo.LoadBalancer.Add('PrivateIP', $lb.FrontendIpConfigurations[0].PrivateIpAddress)
        $vmInfo.LoadBalancer.Add('Port', $VMTemplate.port)
    }

    # work out the base index of the VM, if we're appending instead of creating
    $baseIndex = 0

    if ($VMTemplate.append)
    {
        # get list of all VMs
        $rg_vms = Get-FoggVMs -ResourceGroupName $FoggObject.ResourceGroupName

        # if no VMs returned, keep default base index as 0
        if (!(Test-ArrayEmpty $rg_vms))
        {
            # filter on base VM name to get last VM deployed
            $name = ($rg_vms | Where-Object { $_.Name -ilike "$($tagname)*" } | Select-Object -Last 1 -ExpandProperty Name)

            # if name has a value at the end, take it as the base index
            if ($name -imatch "^$($tagname)(\d+)")
            {
                $baseIndex = ([int]$Matches[1])
            }
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
        $_vms += (New-FoggVM -FoggObject $FoggObject -Name $tagname -Index ($_ + $baseIndex) -VMCredentials $VMCredentials `
            -StorageAccount $StorageAccount -SubnetId $subnet.Id -VMSize $os.size -VMSkus $os.skus -VMOffer $os.offer `
            -VMType $os.type -VMPublisher $os.publisher -AvailabilitySet $avset -Drives $VMTemplate.drives -PublicIP:$usePublicIP)
    }

    # loop through each VM and deploy it
    foreach ($_vm in $_vms)
    {
        if ($_vm -eq $null)
        {
            continue
        }

        $startTime = [DateTime]::UtcNow

        # deploy the VM
        Save-FoggVM -FoggObject $FoggObject -VM $_vm -LoadBalancer $lb

        # see if we need to provision the machine
        if ($FoggObject.HasProvisionScripts)
        {
            $provs = $VMTemplate.provisioners
            if (Test-ArrayEmpty $provs)
            {
                $provs = @()
            }
            
            if (!(Test-ArrayEmpty $VMTemplate.drives))
            {
                $provs = @('attach-drives') + $provs
            }

            Set-ProvisionVM -FoggObject $FoggObject -Provisioners $provs -VMName $_vm.Name -StorageAccount $StorageAccount
        }

        # due to a bug with the CustomScriptExtension, if we have any uninstall the extension
        Remove-FoggCustomScriptExtension -FoggObject $FoggObject -VMName $_vm.Name

        # get VM's NIC
        $nicId = Get-NameFromAzureId $_vm.NetworkProfile.NetworkInterfaces[0].Id
        $nicIPs = (Get-FoggNetworkInterface -ResourceGroupName $FoggObject.ResourceGroupName -Name $nicId).IpConfigurations[0]

        # get VM's public IP
        if (!(Test-Empty $nicIPs.PublicIpAddress))
        {
            $pipId = Get-NameFromAzureId $nicIPs.PublicIpAddress[0].Id
            $pipIP = (Get-FoggPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName -Name $pipId).IpAddress
        }

        # save VM info details
        $vmInfo.VirtualMachines += @{
            'Name' = $_vm.Name;
            'PrivateIP' = $nicIPs.PrivateIpAddress;
            'PublicIP' = $pipIP;
        }

        # output the time taken to create VM
        Write-Duration $startTime -PreText 'VM Duration'
        Write-Host ([string]::Empty)
    }

    # turn off some of the VMs if needed
    if ($VMTemplate.off -gt 0)
    {
        $count = ($_vms | Measure-Object).Count
        $base = ($count - $VMTemplate.off) + 1

        $count..$base | ForEach-Object {
            $_vm = Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $tagname -Index $_ 
            Stop-FoggVM -FoggObject $FoggObject -Name $_vm.Name -StayProvisioned
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

    $startTime = [DateTime]::UtcNow
    $tag = $VPNTemplate.tag.ToLowerInvariant()
    $tagname = "$($FoggObject.PreTag)-$($tag)"
    
    # VPN information
    $FoggObject.VPNInfo.Add($tag, @{})

    Write-Information "Deploying VPN for '$($tag)' template"

    switch ($VPNTemplate.configType.ToLowerInvariant())
    {
        's2s'
            {
                # get required IP addresses
                $gatewayIP = $FoggObject.SubnetAddressMap["$($tag)-gip"]
                $addressOnPrem = $FoggObject.SubnetAddressMap["$($tag)-opm"]

                # create the local network gateway for the VPN
                $lng = New-FoggLocalNetworkGateway -FoggObject $FoggObject -Name $tagname `
                    -GatewayIPAddress $gatewayIP -Address $addressOnPrem

                # create public vnet gateway
                $gw = New-FoggVirtualNetworkGateway -FoggObject $FoggObject -Name $tagname -VNet $VNet `
                    -VpnType $VPNTemplate.vpnType -GatewaySku $VPNTemplate.gatewaySku

                # create VPN connection
                New-FoggVirtualNetworkGatewayConnection -FoggObject $FoggObject -Name $tagname `
                    -LocalNetworkGateway $lng -VirtualNetworkGateway $gw -SharedKey $VPNTemplate.sharedKey | Out-Null
            }

        'p2s'
            {
                # get required IP addresses
                $clientPool = $FoggObject.SubnetAddressMap["$($tag)-cap"]

                # resolve the cert path
                $certPath = Resolve-Path -Path $VPNTemplate.certPath -ErrorAction Ignore

                # create public vnet gateway
                New-FoggVirtualNetworkGateway -FoggObject $FoggObject -Name $tagname -VNet $VNet `
                    -VpnType $VPNTemplate.vpnType -GatewaySku $VPNTemplate.gatewaySku -ClientAddressPool $clientPool `
                    -PublicCertificatePath $certPath | Out-Null
            }
    }

    # output the time taken to create VM
    Write-Duration $startTime -PreText 'VPN Duration'
}
