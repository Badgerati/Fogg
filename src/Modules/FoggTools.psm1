function _coalesce($a, $b) {
    if (Test-Empty $a) { $b } else { $a }
}

New-Alias '??' _coalesce -Force

function Get-Count($a) {
    return ($a | Measure-Object).Count
}


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

function Get-FoggDefaultInt
{
    param (
        [Parameter()]
        $Value,

        [Parameter()]
        [ValidateNotNull()]
        [int]
        $Default = 1
    )

    if (Test-Empty $Value) {
        return $Default
    }

    return $Value
}

function Join-ValuesDashed
{
    param (
        [string[]]
        $Values
    )

    $v = [string]::Empty

    if (Test-ArrayEmpty $Values)
    {
        return $v
    }

    $v = ($Values | Where-Object { !(Test-Empty $_) }) -join '-'
    return ($v -ireplace '--', '-')
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
        [Parameter()]
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

    if ($Value.GetType().Name -ieq 'hashtable')
    {
        return $Value.Count -eq 0
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
        $details = Get-FoggVMSizes -Location $group.Location

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

            # vm count
            $_count = (Get-FoggDefaultInt -Value $obj.count -Default 1)

            # add VM size cores to total cores and regional cores
            $cores = ($details | Where-Object { $_.Name -ieq $size }).NumberOfCores * $_count
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

function Test-Extensions
{
    param (
        [Parameter(Mandatory=$true)]
        $FoggObject,

        [Parameter()]
        $Extensions
    )

    # if there are no extensions, just return
    if (Test-Empty $Extensions) {
        $FoggObject.HasExtensions = $false
        return
    }

    # loop through each extension and verify
    $keys = $Extensions.psobject.properties.name

    foreach ($key in $keys) {
        switch ($key.ToLowerInvariant()) {
            'chef' {
                Test-ExtensionChef -Template $Extensions.$key -FoggObject $FoggObject
            }

            default {
                throw "Unknown extension type provided: $($key)"
            }
        }
    }

    # set we have extensions
    $FoggObject.HasExtensions = $true
}

function Test-ExtensionChef
{
    param (
        [Parameter(Mandatory=$true)]
        $Template,

        [Parameter(Mandatory=$true)]
        $FoggObject
    )

    $_args = $FoggObject.Arguments

    # ensure there's a validation section
    if (Test-Empty $Template.validation) {
        throw 'No validation section has been supplied for the Chef Extension'
    }

    $pem = Get-Replace $Template.validation.pem 'none' $_args
    if (Test-Empty $pem) {
        throw 'A path to a pem file is required in the validation section for the Chef Extension'
    }

    $name = Get-Replace $Template.validation.name 'none' $_args
    if (Test-Empty $name) {
        throw 'A client name is required in the validation section for the Chef Extension'
    }

    # ensure there's a chef server url
    $url = Get-Replace $Template.url 'none' $_args
    if (Test-Empty $url) {
        throw "A Chef Server URL is required for the Chef Extension"
    }
}

function Test-Template
{
    param (
        [Parameter(Mandatory=$true)]
        $Template,

        [Parameter(Mandatory=$true)]
        $FoggObject,

        [switch]
        $Online
    )

    # split out the template objects
    $templateObjs = $Template.template

    # get the count of template objects to create
    $templateCount = ($templateObjs | Measure-Object).Count
    if ($templateCount -eq 0) {
        throw 'No template section was found in Fogg Azure template file'
    }

    # ensure the global OS setting is correct
    $OS = $Template.os
    if ($OS -ne $null) {
        Test-TemplateVMOS -Role 'global' -Location $FoggObject.Location -OS $OS -Online:$Online
    }

    # ensure the global storage account name is valid - but only if we have VMs, and if one of them is unmanaged
    if (Test-TemplateHasType $templateObjs 'vm')
    {
        $saName = Get-FoggStorageAccountName -Name (Join-ValuesDashed @($FoggObject.LocationCode, $FoggObject.Stamp, $FoggObject.Platform, 'gbl'))
        Test-FoggStorageAccountName $saName

        if ($Online) {
            if (Test-FoggStorageAccountExists $saName) {
                Get-FoggStorageAccount -ResourceGroupName $FoggObject.ResourceGroupName -StorageAccountName $saName | Out-Null
            }
        }
    }

    # flag variable helpers
    $alreadyHasVpn = $false
    $roleMap = @{}

    # loop through each template object, verifying it
    foreach ($obj in $templateObjs)
    {
        # ensure each template has a role, and a type
        $role = $obj.role
        $type = $obj.type

        if (Test-Empty $role) {
            throw 'All template objects in a Fogg template file require a role'
        }

        if (Test-Empty $type) {
            throw 'All template objects in a Fogg template file require a type'
        }

        # check role uniqueness and value validity
        $role = $role.ToLowerInvariant()
        $type = $type.ToLowerInvariant()

        if ($role -inotmatch '^[a-z0-9\-]+$') {
            throw "Role for template object $($role) must be a valid alphanumerical value, including dashes"
        }

        if ($roleMap.ContainsKey($type)) {
            if ($roleMap[$type].Contains($role)) {
                throw "There is already a template $($type) object with role: $($role)"
            }
            else {
                $roleMap[$type] += $role
            }
        }
        else {
            $roleMap.Add($type, @($role))
        }

        # verify based on template object type
        switch ($type)
        {
            'vm' {
                Test-TemplateVM -Template $obj -FoggObject $FoggObject -OS $OS -Online:$Online
            }

            'vpn' {
                if ($alreadyHasVpn) {
                    throw "Cannot have 2 VPN template objects"
                }

                Test-TemplateVPN -Template $obj -FoggObject $FoggObject
                $alreadyHasVpn = $true
            }

            'vnet' {
                Test-TemplateVNet -Template $obj -FoggObject $FoggObject
            }

            'sa' {
                Test-TemplateSA -Template $obj -FoggObject $FoggObject -Online:$Online
            }

            'redis' {
                Test-TemplateRedis -Template $obj -FoggObject $FoggObject -Online:$Online
            }

            default {
                throw "Invalid template object type found in $($role): $($type)"
            }
        }
    }

    return $templateCount
}

function Test-TemplateRedis
{
    param (
        [Parameter(Mandatory=$true)]
        $Template,

        [Parameter(Mandatory=$true)]
        $FoggObject,

        [switch]
        $Online
    )

    $_args = $FoggObject.Arguments

    # get role
    $role = $Template.role.ToLowerInvariant()
    $type = $Template.type.ToLowerInvariant()
    $basename = (Join-ValuesDashed @($FoggObject.Platform, $role))
    $isPrivate = [bool]$Template.private

    # ensure name is valid
    $name = Get-FoggRedisCacheName -Name (Join-ValuesDashed @($FoggObject.LocationCode, $FoggObject.Stamp, $FoggObject.Platform, $role))
    Test-FoggRedisCacheName $name

    # ensure the sku is valid
    $skus = @('Basic', 'Standard', 'Premium')
    $sku = (Get-Replace $Template.sku $role $_args)
    if ($skus -inotcontains $sku)
    {
        throw "The $($role) Redis Cache sku supplied is invalid, valid values are: $($skus -join ', ')"
    }

    # ensure the shard count is valid
    $shards = [int](Get-Replace $Template.shards $role $_args)
    if (!(Test-Empty $Template.shards) -and ($shards -lt 1 -or $shards -gt 10))
    {
        throw "The $($role) Redis Cache shard count is invalid, should be between 1-10"
    }

    # ensure the whitelist rules have names and ip ranges
    if (!(Test-Empty $Template.whitelist))
    {
        $whitelist = ConvertFrom-JsonObjectToMap -JsonObject $Template.whitelist
        $whitelist.Keys | ForEach-Object {
            if (Test-Empty $_)
            {
                throw "The $($role) Redis Cache has a whitelist rule with no name supplied"
            }

            if (Test-Empty $whitelist[$_])
            {
                throw "The $($role) Redis Cache whitelist rule '$($_)' has no IP range supplied"
            }
        }
    }

    # ensure the redis config keys supplied are valid
    $configKeys = @('rdb-backup-enabled', 'rdb-storage-connection-string', 'rdb-backup-frequency', 'maxmemory-reserved', 'maxmemory-policy', 'notify-keyspace-events',
        'hash-max-ziplist-entries', 'hash-max-ziplist-value', 'set-max-intset-entries', 'zset-max-ziplist-entries', 'zset-max-ziplist-value', 'databases')

    if (!(Test-Empty $Template.config))
    {
        $config = ConvertFrom-JsonObjectToMap -JsonObject $Template.config
        $config.Keys | ForEach-Object {
            if ($configKeys -inotcontains $_)
            {
                throw "The $($role) Redis Cache configuration has an invalid property: $($_). Valid values are:`n$($configKeys -join "`n")"
            }
        }
    }

    # check certain args when sku is premium
    $size = (Get-Replace $Template.size $role $_args)

    if ($sku -ieq 'premium')
    {
        $sizes = @('P1', 'P2', 'P3', 'P4')
        if ($sizes -inotcontains $size)
        {
            throw "The $($role) Redis Cache size supplied is invalid for Premium caches, valid values are: $($sizes -join ', ')"
        }
    }

    # check certain arguments against sku when not premium
    else
    {
        $sizes = @('C0', 'C1', 'C2', 'C3', 'C4', 'C5', 'C6', '250MB', '1GB', '2.5GB', '6GB', '13GB', '26GB', '53GB')
        if ($sizes -inotcontains $size)
        {
            throw "The $($role) Redis Cache size supplied is invalid for Basic and Standard caches, valid values are: $($sizes -join ', ')"
        }

        if ($isPrivate)
        {
            throw "The $($role) Redis Cache can only use a subnet if it's Sku is Premium"
        }

        if ($shards -ne 1)
        {
            throw "The $($role) Redis Cache can only have more than 1 shard if it's Sku is Premium"
        }
    }

    # if subnet is true, check we have a subnet for this redis cache
    if ($isPrivate -and $Online)
    {
        $subnet = ?? (Get-Replace $Template.subnet $role $_args) "$($basename)-$($type)"

        if (!$FoggObject.SubnetAddressMap.ContainsKey($subnet))
        {
            throw "No subnet address mapped for the $($role) Redis Cache object, expecting subnet with name: $($subnet)"
        }
    }

    # if online and the cache exist, ensure it's ours
    if ($Online)
    {
        if (Test-FoggRedisCacheExists -ResourceGroupName $FoggObject.ResourceGroupName -Name $name)
        {
            Get-FoggRedisCache -ResourceGroupName $FoggObject.ResourceGroupName -Name $name | Out-Null
        }
    }
}

function Test-TemplateSA
{
    param (
        [Parameter(Mandatory=$true)]
        $Template,

        [Parameter(Mandatory=$true)]
        $FoggObject,

        [switch]
        $Online
    )

    # ensure name is valid
    $name = Get-FoggStorageAccountName -Name (Join-ValuesDashed @($FoggObject.LocationCode, $FoggObject.Stamp, $FoggObject.Platform, $Template.role))
    Test-FoggStorageAccountName $name

    # if online and storage account exists, ensure it's ours
    if ($Online)
    {
        if (Test-FoggStorageAccountExists $name)
        {
            Get-FoggStorageAccount -ResourceGroupName $FoggObject.ResourceGroupName -StorageAccountName $name | Out-Null
        }
    }
}

function Test-TemplateVNet
{
    param (
        [Parameter(Mandatory=$true)]
        $Template,

        [Parameter(Mandatory=$true)]
        $FoggObject
    )

    # get role
    $role = $Template.role.ToLowerInvariant()

    # ensure we have an address
    if (Test-Empty $Template.address)
    {
        throw "VNet for $($role) has no address prefix"
    }

    # ensure subnets have names and addresses
    $subnets = ConvertFrom-JsonObjectToMap $Template.subnets
    $subnets.Keys | ForEach-Object {
        if (Test-Empty $_)
        {
            throw "Subnet on Vnet for $($role) has an undefined name"
        }

        if (Test-Empty $subnets[$_])
        {
            throw "Subnet $($_) on Vnet for $($role) has a no address prefix"
        }
    }
}

function Test-TemplateVPN
{
    param (
        [Parameter(Mandatory=$true)]
        $Template,

        [Parameter(Mandatory=$true)]
        $FoggObject
    )

    # get role
    $role = $Template.role.ToLowerInvariant()
    $type = $Template.type.ToLowerInvariant()
    $basename = (Join-ValuesDashed @($role))

    # ensure that the VPN object has a subnet map
    $subnet = ?? $Template.subnet "$($basename)-$($type)"

    if ($Online -and !$FoggObject.SubnetAddressMap.ContainsKey($subnet))
    {
        throw "No subnet address mapped for the $($role) VPN object, expecting subnet with name: $($subnet)"
    }

    # ensure we have a valid VPN type
    if ($Template.vpnType -ine 'RouteBased' -and $Template.vpnType -ine 'PolicyBased')
    {
        throw "VPN type for $($role) must be one of either 'RouteBased' or 'PolicyBased'"
    }

    # ensure we have a Gateway SKU
    if (Test-Empty $Template.gatewaySku)
    {
        throw "VPN has no Gateway SKU specified: Basic, Standard, or HighPerformance"
    }

    # PolicyBased VPN can only have a SKU of Basic
    if ($Template.vpnType -ieq 'PolicyBased' -and $Template.gatewaySku -ine 'Basic')
    {
        throw "PolicyBased VPN can only have a Gateway SKU of 'Basic'"
    }

    # Do we have a valid VPN config
    $configTypes = @('s2s', 'p2s', 'v2v')
    if ((Test-Empty $Template.configType) -or $configTypes -inotcontains $Template.configType)
    {
        throw "VPN configuration must be one of the following: $($configTypes -join ', ')"
    }

    # continue rest of validation based on VPN configuration
    switch ($Template.configType.ToLowerInvariant())
    {
        's2s'
            {
                # ensure we have a VPN Gateway IP in subnet map
                $roleGIP = "$($basename)-gip"
                if ($Online -and !$FoggObject.SubnetAddressMap.Contains("$($roleGIP)-$($type)"))
                {
                    throw "No Gateway IP mapped for the VPN: $($roleGIP)-$($type)"
                }

                # ensure we have a on-premises address prefixes in subnet map
                $roleOpm = "$($basename)-opm"
                if ($Online -and !$FoggObject.SubnetAddressMap.Contains("$($roleOpm)-$($type)"))
                {
                    throw "No On-Premises address prefix(es) mapped for the VPN: $($roleOpm)-$($type)"
                }

                # ensure we have a shared key
                if (Test-Empty $Template.sharedKey)
                {
                    throw "VPN has no shared key specified"
                }
            }

        'p2s'
            {
                # ensure we have a VPN client address pool in subnet map
                $roleCAP = "$($basename)-cap"
                if ($Online -and !$FoggObject.SubnetAddressMap.Contains("$($roleCAP)-$($type)"))
                {
                    throw "No VPN Client Address Pool mapped for the VPN: $($roleCAP)-$($type)"
                }

                # ensure we have a cert path, and it exists
                if (Test-Empty $Template.certPath)
                {
                    throw "VPN has no public certificate (.cer) path specified"
                }

                if (!(Test-PathExists $Template.certPath))
                {
                    throw "VPN public certificate path does not exist: $($Template.certPath)"
                }

                # ensure the certificate extension is .cer
                $file = Split-Path -Leaf -Path $Template.certPath
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
        $Template,

        [Parameter(Mandatory=$true)]
        $FoggObject,

        $OS,

        [switch]
        $Online
    )

    $_args = $FoggObject.Arguments

    # is there an OS section?
    $hasOS = ($OS -ne $null)
    $hasVhd = ($Template.vhd -ne $null)
    $hasImage = ($Template.image -ne $null)
    $isManaged = [bool]$Template.managed
    $mainOS = $OS

    # get role
    $role = $Template.role.ToLowerInvariant()
    $type = $Template.type.ToLowerInvariant()
    $basename = (Join-ValuesDashed @($role))

    # ensure we don't have a vhd and an image
    if ($hasVhd -and $hasImage) {
        throw "The $($role) VM object cannot have both a Vhd and Image sections defined"
    }

    # ensure we dont have a vhd and the vm is managed
    if ($hasVhd -and $isManaged) {
        throw "The $($Role) VM object cannot be both managed and have Vhd defined"
    }

    # ensure that each VM object has a subnet map
    $subnet = (?? (Get-Replace $Template.subnet $role $_args) "$($basename)-$($type)")

    if ($Online -and !$FoggObject.SubnetAddressMap.ContainsKey($subnet)) {
        throw "No subnet address mapped for the $($role) VM object, expecting subnet with name: $($subnet)"
    }

    # ensure VM count is not negative/0
    $_count = (Get-FoggDefaultInt -Value (Get-Replace $Template.count $role $_args) -Default 1)
    if ($_count -le 0) {
        throw "VM count cannot be 0 or negative for $($role): $($_count)"
    }

    # ensure that if append is true, off count is not supplied
    if ($Template.append -and $Template.off -ne $null -and $Template.off -gt 0) {
        throw "VMs to turn off cannot be supplied if append property is true for $($role)"
    }

    # ensure the off count is not negative or greater than VM count
    if ($Template.off -ne $null -and ($Template.off -le 0 -or $Template.off -gt $_count)) {
        throw "VMs to turn off cannot be negative or greater than VM count for $($role): $($Template.off)"
    }

    # ensure the publicIp value is valid
    $publicIps = @('none', 'static', 'dynamic')
    $publicIp = (Get-Replace $Template.publicIp $role $_args)

    if (!(Test-Empty $publicIp) -and $publicIps -inotcontains $publicIp) {
        throw "VM publicIp value for $($role) is invalid, should be: $($publicIps -join ', ')"
    }

    # validate the load balancer logic
    if (!(Test-Empty $Template.loadBalancer)) {
        Test-VMLoadBalancer -FoggObject $FoggObject -Role $role -LoadBalancer $Template.loadBalancer
    }

    # check if vhd is valid, if supplied
    if ($hasVhd) {
        Test-TemplateVMVhd -Role $role -Vhd $Template.vhd -FoggObject $FoggObject -Online:$Online
    }

    # check if image is valid, if supplied
    if ($hasImage) {
        Test-TemplateVMImage -Role $role -Image $Template.image -FoggObject $FoggObject -Online:$Online
    }

    # ensure that each VM has an OS setting if global OS does not exist
    if (!$hasOS -and $Template.os -eq $null) {
        throw "The '$($role)' VM object is missing the OS settings section"
    }

    if ($Template.os -ne $null) {
        Test-TemplateVMOS -Role $role -Location $FoggObject.Location -OS $Template.os -Online:$Online -VhdPresent:$hasVhd
        $mainOS = $Template.os
    }

    $osType = $mainOS.type

    # ensure the VM name is valid
    $vmName = Get-FoggVMName -Name (Join-ValuesDashed @($role)) -Index $_count
    Test-FoggVMName -OSType $osType -Name $vmName

    # ensure supplied zones are numeric, and location supports them
    if (!(Test-Empty $Template.zones))
    {
        # ensure they're all numeric
        if (($Template.zones | Where-Object { $_ -match '\D+' } | Measure-Object).Count -ne 0) {
            throw "The $($role) VM zones should all be numeric"
        }

        # does the location/size support the supplied zones?
        if ($Online -and !(Test-FoggLocationZones -Location $FoggObject.Location -ResourceType 'VirtualMachines' -Name $mainOS.size -Zones $Template.zones))
        {
            $zs = Get-FoggLocationZones -Location $FoggObject.Location -ResourceType 'VirtualMachines' -Name $mainOS.size
            throw "The $($role) VM zones are invalid for the size $($mainOS.size) in $($FoggObject.Location), valid zones are: $($zs -join ', ')"
        }
    }

    # ensure that the provisioner keys exist
    if (!$FoggObject.HasProvisionScripts -and !(Test-ArrayEmpty $Template.provisioners)) {
        throw "The '$($role)' VM object specifies provisioners, but there is no Provisioner section"
    }

    if ($FoggObject.HasProvisionScripts -and !(Test-ArrayEmpty $Template.provisioners))
    {
        $Template.provisioners | ForEach-Object {
            $key = ($_ -split '\:')[0]

            if (Test-Empty $key) {
                throw "Provisioner key cannot be empty in '$($role)' VM object"
            }

            if (!(Test-ProvisionerExists -FoggObject $FoggObject -ProvisionerName $key)) {
                throw "Provisioner key not specified in Provisioners section for the '$($role)' VM object: $($key)"
            }
        }
    }

    # ensure firewall rules are valid
    Test-FirewallRules -FirewallRules $Template.firewall

    # if the VM has extra drives, ensure the section is valid and add the provisioner
    Test-VMDrives -FoggObject $FoggObject -Role $role -Drives $Template.drives
}

function Test-VMLoadBalancer
{
    param (
        [Parameter(Mandatory=$true)]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Role,

        [Parameter()]
        $LoadBalancer
    )

    # validate load balancer frontends
    $frontends = @()
    if (!(Test-Empty $LoadBalancer.frontends)) {
        if (Test-ArrayEmpty $LoadBalancer.frontends) {
            throw "Frontend load balancer names must all be populated for the $($Role) VM"
        }

        if ((Test-ArrayIsUnique $LoadBalancer.frontends) -ne $null) {
            throw "Frontend load balancer names must be unique for the $($role) VM"
        }

        if ($LoadBalancer.frontends -icontains 'default') {
            throw "Cannot have a frontend called 'default' on the load balancer for the $($Role) VM"
        }

        $frontends = $LoadBalancer.frontends
    }

    # validate load balancer rules
    if (Test-ArrayEmpty $LoadBalancer.rules) {
        throw "No load balancer rules have been supplied for the $($Role) VM"
    }

    if ((Test-ArrayIsUnique $LoadBalancer.rules.name) -ne $null) {
        throw "Rule names for load balancer must be unique for the $($Role) VM"
    }

    foreach ($rule in $LoadBalancer.rules) {
        # ensure they have a name
        if (Test-Empty $rule.name) {
            throw "A valid name is required for the load balancing rule for the $($Role) VM"
        }

        # ensure they have a valid port
        if ((Test-Empty $rule.port) -or $rule.port -le 0) {
            throw "A valid port is required for the load balancing rule '$($rule.name)' for the $($Role) VM"
        }

        # if passed, timeout is correct
        if (!(Test-Empty $rule.timeout) -and ($rule.timeout -lt 4 -or $rule.timeout -gt 30)) {
            throw "An invalid timeout has been supplied for the $($Role) VM load balancer rule '$($rule.name)', should be between 4-30mins (def: 4)"
        }

        # if passed, frontend name exists
        if (!(Test-Empty $rule.frontend) -and ($frontends -inotcontains $rule.frontend)) {
            throw "Frontend '$($rule.frontend)' does not exist for rule '$($rule.name)' for the $($Role) VM load balancer"
        }
    }

    $rules = $LoadBalancer.rules

    # validate load balancer probes
    foreach ($probe in $LoadBalancer.probes) {
        if ($probe -eq $null) {
            continue
        }

        if ((Test-ArrayEmpty $probe.rules) -or (Get-Count ($probe.rules | Where-Object { $rules.name -inotcontains $_ }) -ne 0)) {
            throw "An invalid rule name for probe has been supplied for the $($Role) VM load balancer"
        }

        if (!(Test-Empty $probe.port) -and $probe.port -le 0) {
            throw "An invalid probe port has been supplied for the $($Role) VM load balancer (def: rule port)"
        }

        if (!(Test-Empty $probe.interval) -and ($probe.interval -lt 5 -or $probe.interval -gt 2147483646)) {
            throw "An invalid probe interval has been supplied for the $($Role) VM load balancer, should be between 5-2147483646 (def: 5)"
        }

        if (!(Test-Empty $probe.threshold) -and ($probe.threshold -lt 2 -or $probe.threshold -gt 429496729)) {
            throw "An invalid probe threshold has been supplied for the $($Role) VM load balancer, should be between 2-429496729 (def: 2)"
        }
    }
}

function Test-VMDrives
{
    param (
        [Parameter(Mandatory=$true)]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Role,

        [Parameter()]
        $Drives
    )

    # if there are no drives, just return
    if (Test-ArrayEmpty $Drives) {
        return
    }

    # ensure other values are correct
    $Drives | ForEach-Object {
        # ensure sizes are greater than 0
        if ($_.size -eq $null -or $_.size -le 0) {
            throw "Drive '$($_.name)' in the $($Role) VM object must have a size greater than 0Gb"
        }

        # ensure LUNs are greater than 0
        if ($_.lun -eq $null -or $_.lun -le 0) {
            throw "Drive '$($_.name)' in the $($Role) VM object must have a LUN greater than 0"
        }

        # ensure drives and letters aren't empty
        if (Test-Empty $_.name) {
            throw "Drive '$($_.letter)' in the $($Role) VM object has no drive name supplied"
        }

        if (Test-Empty $_.letter) {
            throw "Drive '$($_.name)' in the $($Role) VM object has no drive letter supplied"
        }

        # ensure the drive letter is not one of the reserved ones
        $reservedDrives = @('A', 'B', 'C', 'D', 'E', 'Z')
        if ($reservedDrives -icontains $_.letter) {
            throw "Drive '$($_.name)' in the $($Role) VM object cannot use one of the following drive letters: $($reservedDrives -join ', ')"
        }

        if ($_.letter -inotmatch '^[a-z]{1}$') {
            throw "Drive '$($_.name)' in the $($Role) VM object must have a valid alpha drive letter"
        }

        # ensure the name is alphanumeric
        if ($_.name -inotmatch '^[a-z0-9 ]+$') {
            throw "Drive '$($_.name)' in the $($Role) VM object must have a valid alphanumeric drive name"
        }

        # ensure caching value is correct
        $cachings = @('ReadOnly', 'ReadWrite', 'None')
        if (![string]::IsNullOrWhiteSpace($_.caching) -and $cachings -inotcontains $_.caching) {
            throw "Drive '$($_.name)' in the $($Role) VM object has an invalid caching option '$($_.caching)', valid values: $($cachings -join ', ')"
        }
    }

    # ensure the LUNs are unique
    $dupe = Test-ArrayIsUnique $Drives.lun
    if ($dupe -ne $null) {
        throw "Drive LUNs need to be unique, found two drives with LUN '$($dupe)' for the $($Role) VM object"
    }

    # ensure the name are unique
    $dupe = Test-ArrayIsUnique $Drives.name
    if ($dupe -ne $null) {
        throw "Drive names need to be unique, found two drives with name '$($dupe)' for the $($Role) VM object"
    }

    # ensure the letters are unique
    $dupe = Test-ArrayIsUnique $Drives.letter
    if ($dupe -ne $null) {
        throw "Drive letters need to be unique, found two drives with letter '$($dupe)' for the $($Role) VM object"
    }

    # get the drive names
    $names = $Drives.name -join ','
    $letters = $Drives.letter -join ','

    # add provisioner
    $scriptPath = Get-ProvisionerInternalPath -FoggObject $FoggObject -Type 'drives' -ScriptName 'attach-drives' -OS 'win'
    Add-Provisioner -FoggObject $FoggObject -Key 'attach-drives' -Type 'drives' -ScriptPath $scriptPath -Arguments "$($letters) | $($names)"
}

function Test-FirewallRules
{
    param (
        [Parameter()]
        $FirewallRules
    )

    # if no firewall rules then just return
    if ($FirewallRules -eq $null) {
        return
    }

    # verify inbuilt firewall ports exist
    $portMap = Get-FirewallPortMap
    $keys = $FirewallRules.psobject.properties.name
    $regex = '^(?<name>.+?)(\|(?<direction>in|out|both)){0,1}$'

    foreach ($key in $keys)
    {
        # if key doesnt match regex, throw error
        if ($key -inotmatch $regex) {
            throw "Firewall rule with key '$($key)' is invalid. Should be either 'inbound', 'outbound', or of the format '<name>|<direction>'"
        }

        # set port name and direction (default to inbound)
        $portname = $Matches['name'].ToLowerInvariant()

        # if in/outbound then continue
        if ($portname -ieq 'inbound' -or $portname -ieq 'outbound') {
            continue
        }

        # if port doesnt exist, throw error
        if (!$portMap.ContainsKey($portname)) {
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
    if (Test-Empty $FirewallRule.name) {
        throw 'A name is required for firewall rules'
    }

    # ensure priority
    if (Test-Empty $FirewallRule.priority) {
        throw "A priority is required for firewall rule $($FirewallRule.name)"
    }

    if ($FirewallRule.priority -lt 100 -or $FirewallRule.priority -gt 4095) {
        throw "The priority must be between 100 and 4095 for firewall rule $($FirewallRule.name)"
    }

    # ensure source
    $regex = '^(?<name>.+?)\:(?<port>[\d*-]+)$'

    if ($FirewallRule.source -inotmatch $regex) {
        throw "A source IP and Port range is required for firewall rule $($FirewallRule.name), and must match the following pattern: $($regex)"
    }

    # ensure destination
    if ($FirewallRule.destination -inotmatch $regex) {
        throw "A destination IP and Port range is required for firewall rule $($FirewallRule.name), and must match the following pattern: $($regex)"
    }

    # ensure access rule
    $accesses = @('Allow', 'Deny')
    if ((Test-Empty $FirewallRule.access) -or ($accesses -inotcontains $FirewallRule.access)) {
        throw "An access of Allow or Deny is required for firewall rule $($FirewallRule.name)"
    }
}

function Test-TemplateVMImage
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Role,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        $Image,

        [switch]
        $Online
    )

    if ($Image -eq $null) {
        return
    }

    $Role = $Role.ToLowerInvariant()

    # if there's no image name, fail
    if (Test-Empty $Image.name) {
        throw "The $($Role) VM object has no image name supplied"
    }

    if ($Online)
    {
        $rg = $Image.rg
        if (Test-Empty $rg) {
            $rg = $FoggObject.ResourceGroupName
        }

        # ensure the image actually exists
        $img = (Get-AzureRmImage -ResourceGroupName $rg -ImageName $Image.name -ErrorAction Ignore).Id

        if (Test-Empty $img) {
            throw "Failed to find image $($name) in resource group $($rg)"
        }
    }
}

function Test-TemplateVMVhd
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Role,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        $Vhd,

        [switch]
        $Online
    )

    if ($Vhd -eq $null) {
        return
    }

    $Role = $Role.ToLowerInvariant()

    # if there's no vhd name, fail
    if (Test-Empty $Vhd.name) {
        throw "The $($Role) VM object has no VHD name supplied"
    }

    # ensure that a valid storage account has been supplied
    if ($Vhd.sa -eq $null -or (Test-Empty $Vhd.sa.name)) {
        throw "The $($Role) VM object has no storage account supplied"
    }

    if ($Online)
    {
        # test that the storage account exists and we have access
        if (Test-FoggStorageAccountExists $Vhd.sa.name) {
            $sa = Get-FoggStorageAccount -ResourceGroupName $FoggObject.ResourceGroupName -StorageAccountName $Vhd.sa.name
        }

        # ensure the vhd actually exists
        $name = Get-FoggVhdName -Name $Vhd.name
        $ctx = $sa.Context
        $blob = (Get-AzureStorageBlob -Blob $name -Context $ctx -ErrorAction Ignore -Container 'vhds').Name

        if (Test-Empty $blob) {
            throw "Failed to find VHD $($name) in storage account $($Vhd.sa.name)"
        }
    }
}

function Test-TemplateVMOS
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Role,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location,

        $OS,

        [switch]
        $VhdPresent,

        [switch]
        $Online
    )

    if ($OS -eq $null) {
        return
    }

    $Role = $Role.ToLowerInvariant()

    if (Test-Empty $OS.size) {
        throw "$($Role) OS settings must declare a size type"
    }

    if (Test-Empty $OS.type) {
        throw "$($Role) OS settings must declare an OS type of either: Windows, Linux"
    }

    if (@('windows', 'linux') -inotcontains $OS.type) {
        throw "$($Role) OS settings must declare a valid OS type of either: Windows, Linux"
    }

    if (!$VhdPresent)
    {
        if (Test-Empty $OS.publisher) {
            throw "$($Role) OS settings must declare a publisher type"
        }

        if (Test-Empty $OS.offer) {
            throw "$($Role) OS settings must declare a offer type"
        }

        if (Test-Empty $OS.skus) {
            throw "$($Role) OS settings must declare a sku type"
        }
    }

    if ($Online)
    {
        Test-FoggVMSize -Size $OS.size -Location $Location

        if (!$VhdPresent) {
            Test-FoggVMPublisher -Publisher $OS.publisher -Location $Location
            Test-FoggVMOffer -Offer $OS.offer -Publisher $OS.publisher -Location $Location
            Test-FoggVMSkus -Skus $OS.skus -Offer $OS.offer -Publisher $OS.publisher -Location $Location
        }
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

    if (!$FoggObject.HasProvisionScripts) {
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

        [Parameter()]
        $Paths
    )

    # if there are no provisioners, just return
    if (Test-Empty $Paths) {
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

            if ($types -inotcontains $type) {
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
                if ($isChoco) {
                    $name = 'choco-install'
                }
                else {
                    $name = $Matches['name'].ToLowerInvariant()
                }

                # get the os type for script extension
                if ($isChoco -or $isDsc) {
                    $os = 'win'
                }
                else {
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
            if ($isChoco) {
                Add-Provisioner -FoggObject $FoggObject -Key $_ -Type $type -ScriptPath $scriptPath -Arguments $value
            }
            else {
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
    if (!(Test-PathExists $FoggObject.ProvisionersPath)) {
        throw "Fogg root path for internal provisioners does not exist: $($FoggObject.ProvisionersPath)"
    }

    # ensure OS type is lowercase
    if (![string]::IsNullOrWhiteSpace($OS)) {
        $OS = $OS.ToLowerInvariant()
    }

    # generate internal script path
    switch ($OS)
    {
        'win' {
            $scriptPath = Join-Path (Join-Path $FoggObject.ProvisionersPath $Type) "$($ScriptName).ps1"
        }

        'unix' {
            $scriptPath = Join-Path (Join-Path $FoggObject.ProvisionersPath $Type) "$($ScriptName).sh"
        }

        default {
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
    if (!(Test-PathExists $ScriptPath)) {
        throw "Provision script for $($Key) does not exist: $($ScriptPath)"
    }

    $FoggObject.HasProvisionScripts = $true

    # add provisioner to internal map
    if (!$FoggObject.ProvisionMap[$Type].ContainsKey($Key))
    {
        if ($Arguments -eq $null) {
            $FoggObject.ProvisionMap[$Type].Add($Key, @($ScriptPath))
        }
        else {
            $FoggObject.ProvisionMap[$Type].Add($Key, @($ScriptPath, $Arguments))
        }
    }
    else
    {
        if ($Arguments -eq $null) {
            $FoggObject.ProvisionMap[$Type][$Key] = @($ScriptPath)
        }
        else {
            $FoggObject.ProvisionMap[$Type][$Key] = @($ScriptPath, $Arguments)
        }
    }
}


function Get-FirewallPortMap
{
    return @{
        'ftp' = '20-21';
        'ssh' = '22';
        'smtp' = '25';
        'http' = '80';
        'sftp' = '115';
        'https' = '443';
        'smb' = '445';
        'ftps' = '989-990';
        'sql' = '1433-1434';
        'grafana' = '3000';
        'mysql' = '3306';
        'rdp' = '3389';
        'svn' = '3690';
        'sql-mirror' = '5022-5023';
        'postgresql' = '5432';
        'winrm' = '5985-5986';
        'redis' = '6379';
        'puppet' = '8139-8140';
        'influxdb' = '8086';
        'vault' = '8200';
        'consul' = '8500';
        'git' = '9418';
        'octopus' = '10933';
        'redis-sentinel' ='26379';
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
    if (!$?) {
        throw "Failed to parse the JSON content from file: $($Path)"
    }

    return $json
}


function Get-PowerShellVersion
{
    try {
        return [decimal]((Get-Host).Version.Major)
    }
    catch {
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

    if (Test-Empty $Value) {
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

    if ($JsonObject -eq $null) {
        return $map
    }

    $JsonObject.psobject.properties.name | ForEach-Object {
        $map.Add($_, $JsonObject.$_)
    }

    return $map
}

function Get-Replace
{
    param (
        [Parameter()]
        [string]
        $Value,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Role,

        [Parameter()]
        [hashtable]
        $Arguments = $null,

        [Parameter()]
        [hashtable]
        $Subnets = $null
    )

    if (Test-Empty $Value) {
        return $Value
    }

    # regex to match on placeholders
    $regex = '@\{(?<key>.+?)(\|(?<value>.*?)){0,1}\}'

    # keep looping until there's no match
    while ($Value -imatch $regex)
    {
        # should the value be defaulted to the role (mostly for subnets)
        $v = (?? $Matches['value'] $Role)

        switch ($Matches['key'].ToLowerInvariant()) {
            'subnet' {
                if ($Subnets -ne $null -and $Subnets.ContainsKey($v)) {
                    $Value = ($Value -ireplace [Regex]::Escape($Matches[0]), $Subnets[$v])
                }
                else {
                    $Value = ($Value -ireplace [Regex]::Escape($Matches[0]), "")
                }
            }

            'args' {
                if ($Arguments -ne $null -and $Arguments.ContainsKey($v)) {
                    $Value = ($Value -ireplace [Regex]::Escape($Matches[0]), $Arguments[$v])
                }
                else {
                    $Value = ($Value -ireplace [Regex]::Escape($Matches[0]), "")
                }
            }

            'role' {
                $Value = ($Value -ireplace [Regex]::Escape($Matches[0]), $Role)
            }
        }
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

function Get-SubnetRange
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $SubnetMask
    )

    # split for ip and number of 1 bits
    $split = $SubnetMask -split '/'
    if ($split.Length -le 1)
    {
        return $null
    }

    $ip_parts = $split[0] -isplit '\.'
    $bits = [int]$split[1]

    # generate the netmask
    $network = @("", "", "", "")
    $count = 0

    foreach ($i in 0..3)
    {
        foreach ($b in 1..8)
        {
            $count++

            if ($count -le $bits) {
                $network[$i] += "1"
            }
            else {
                $network[$i] += "0"
            }
        }
    }

    # covert netmask to bytes
    0..3 | ForEach-Object {
        $network[$_] = [Convert]::ToByte($network[$_], 2)
    }

    # calculate the bottom range
    $bottom = @(0..3 | ForEach-Object { [byte]([byte]$network[$_] -band [byte]$ip_parts[$_]) })

    # calculate the range
    $range = @(0..3 | ForEach-Object { 256 + (-bnot [byte]$network[$_]) })

    # calculate the top range
    $top = @(0..3 | ForEach-Object { [byte]([byte]$ip_parts[$_] + [byte]$range[$_]) })

    return @{
        'lowest' = ($bottom -join '.');
        'highest' = ($top -join '.');
        'range' = ($range -join '.');
        'netmask' = ($network -join '.');
        'ip' = ($ip_parts -join '.');
    }
}

function Get-SubnetMask
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Low,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $High
    )

    # split low and high
    $low_parts = $Low -split '\.'
    $high_parts = $High -split '\.'

    # subtract and bitwise not to get network
    $network = @(0..3 | ForEach-Object { 256 + (-bnot ([byte]$high_parts[$_] - [byte]$low_parts[$_])) })

    # convert the network to binary
    $binary = ((($network | ForEach-Object { [Convert]::ToString($_, 2) }) -join '') -split '0')[0] -join ''
    $binary = $binary + (New-Object String -ArgumentList "0", (32 - $binary.Length))

    # re-calc the network and low address
    $network = @(0..3 | ForEach-Object { [Convert]::ToByte(($binary[($_ * 8)..(($_ * 8) + 7)] -join ''), 2) })
    $Low = @(0..3 | ForEach-Object { [byte]([byte]$network[$_] -band [byte]$low_parts[$_]) }) -join '.'

    # count the 1 bits of the network
    $bits = ($binary.ToCharArray() | ForEach-Object { Invoke-Expression $_ } | Measure-Object -Sum).Sum

    # return the mask
    return "$($Low)/$($bits)"
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
        $VNetName,

        $Tags,

        [string]
        $Platform,

        [string]
        $Environment,

        [string]
        $Provider,

        [string]
        $Stamp,

        [string]
        $TenantId,

        [hashtable]
        $Arguments
    )

    $useFoggfile = $false

    # are we needing to use a Foggfile? (either path passed, or all params empty)
    if (!(Test-Empty $FoggfilePath))
    {
        $path = (Resolve-Path $FoggfilePath -ErrorAction Ignore)
        if (!(Test-PathExists $FoggfilePath)) {
            throw "Path to Foggfile does not exist: $($FoggfilePath)"
        }

        if ((Get-Item $path) -is [System.IO.DirectoryInfo])
        {
            $path = Join-Path $path 'Foggfile'
            if (!(Test-PathExists $path)) {
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
        $TemplatePath,
        $Tags,
        $Platform,
        $Environment,
        $Provider,
        $Stamp
    )

    if (!$useFoggfile -and (Test-ArrayEmpty $foggParams) -and (Test-PathExists 'Foggfile'))
    {
        $FoggfilePath = (Resolve-Path '.\Foggfile' -ErrorAction Ignore)
        $useFoggfile = $true
    }

    # set up the initial Fogg object with group array
    $props = @{}
    $props.Groups = @()
    $props.SubscriptionName = $SubscriptionName
    $props.SubscriptionCredentials = $SubscriptionCredentials
    $props.TenantId = $TenantId
    $props.VMCredentials = $VMCredentials
    $props.LoggedIn = $false
    $props.Tags = $Tags
    $foggObj = New-Object -TypeName PSObject -Property $props

    # set some defaults
    if (Test-Empty $foggObj.Tags) {
        $foggObj.Tags = @{}
    }

    # general paths
    $provisionPath = Join-Path $FoggRootPath 'Provisioners'

    # if we aren't using a Foggfile, set params directly
    if (!$useFoggfile)
    {
        $group = New-FoggGroupObject -ResourceGroupName $ResourceGroupName -Location $Location `
            -SubnetAddresses $SubnetAddresses -TemplatePath $TemplatePath -FoggfilePath $FoggfilePath `
            -VNetAddress $VNetAddress -VNetResourceGroupName $VNetResourceGroupName -VNetName $VNetName `
            -Platform $Platform -Environment $Environment -Provider $Provider -Stamp $Stamp -Arguments $Arguments

        $group.ProvisionersPath = $provisionPath
        $foggObj.Groups += $group
    }

    # else, we're using a Foggfile, set params and groups appropriately
    elseif ($useFoggfile)
    {
        # load Foggfile
        $file = Get-JSONContent $FoggfilePath

        # check to see if we have a Groups array
        if (Test-ArrayEmpty $file.Groups) {
            throw 'Missing Groups array in Foggfile'
        }

        # check if we need to set the SubscriptionName from the file
        if (Test-Empty $SubscriptionName) {
            $foggObj.SubscriptionName = $file.SubscriptionName
        }

        # check if we need to set the tags from the file
        if (Test-Empty $Tags) {
            $foggObj.Tags = $file.Tags
        }

        # check if we need to set the platform from the file
        if (Test-Empty $Platform) {
            $Platform = $file.Platform
        }

        # check if we need to set the environment from the file
        if (Test-Empty $Environment) {
            $Environment = $file.Environment
        }

        # check if we need to set the provider from the file
        if (Test-Empty $Provider) {
            $Provider = $file.Provider
        }

        # check if we need to set arguments from file
        if (Test-Empty $Arguments) {
            $Arguments = ConvertFrom-JsonObjectToMap $file.Arguments
        }

        # load the groups
        $file.Groups | ForEach-Object {
            $group = New-FoggGroupObject -ResourceGroupName $ResourceGroupName -Location $Location `
                -SubnetAddresses $SubnetAddresses -TemplatePath $TemplatePath -FoggfilePath $FoggfilePath `
                -VNetAddress $VNetAddress -VNetResourceGroupName $VNetResourceGroupName -VNetName $VNetName `
                -Platform $Platform -Environment $Environment -Provider $Provider -Stamp $Stamp -Arguments $Arguments `
                -FoggParameters $_

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

        [string]
        $Platform,

        [string]
        $Environment,

        [string]
        $Provider,

        [string]
        $Stamp,

        [hashtable]
        $Arguments,

        $FoggParameters = $null
    )

    # Only set the params that haven't already got a value (cli overrides foggfile)
    if ($FoggParameters -ne $null)
    {
        if (Test-Empty $ResourceGroupName) {
            $ResourceGroupName = $FoggParameters.ResourceGroupName
        }

        if (Test-Empty $Location) {
            $Location = $FoggParameters.Location
        }

        if (Test-Empty $Stamp) {
            $Stamp = $FoggParameters.Stamp
        }

        if (Test-Empty $VNetAddress) {
            $VNetAddress = $FoggParameters.VNetAddress
        }

        if (Test-Empty $VNetResourceGroupName) {
            $VNetResourceGroupName = $FoggParameters.VNetResourceGroupName
        }

        if (Test-Empty $VNetName) {
            $VNetName = $FoggParameters.VNetName
        }

        if (Test-Empty $TemplatePath) {
            # this should be relative to the Foggfile
            $tmp = (Join-Path (Split-Path -Parent -Path $FoggfilePath) $FoggParameters.TemplatePath)
            $TemplatePath = Resolve-Path $tmp -ErrorAction Ignore

            if (!(Test-PathExists $TemplatePath)) {
                if (!(Test-Empty $TemplatePath)) {
                    $tmp = $TemplatePath
                }

                throw "Template path supplied does not exist: $(($tmp -replace '\.\.\\') -replace '\.\\')"
            }
        }

        if (Test-Empty $SubnetAddresses) {
            $SubnetAddresses = ConvertFrom-JsonObjectToMap $FoggParameters.SubnetAddresses
        }
    }

    # location code from the supplied location
    $locationCode = (Get-FoggLocationName -Location $Location)

    # generate the resource group name if not supplied
    if (Test-Empty $ResourceGroupName) {
        if (Test-Empty $Platform) {
            throw 'No Resource Group Name has been supplied, which means a Platform value is mandatory'
        }

        if (Test-Empty $Environment) {
            throw 'No Resource Group Name has been supplied, which means an Environment value is mandatory'
        }

        $ResourceGroupName = (Join-ValuesDashed @($locationCode, $Platform, $Environment))
    }

    # standardise
    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $VNetResourceGroupName = (Get-FoggResourceGroupName $VNetResourceGroupName)
    $VNetName = (Get-FoggVirtualNetworkName $VNetName)

    if ($SubnetAddresses -eq $null) {
        $SubnetAddresses = @{}
    }

    # create fogg object with params
    $group = @{}
    $group.ResourceGroupName = $ResourceGroupName
    $group.Platform = $Platform
    $group.Environment = $Environment
    $group.Provider = $Provider
    $group.Stamp = $Stamp
    $group.Location = $Location
    $group.LocationCode = $locationCode
    $group.VNetAddress = $VNetAddress
    $group.VNetResourceGroupName = $VNetResourceGroupName
    $group.VNetName = $VNetName
    $group.UseExistingVNet = (!(Test-Empty $VNetResourceGroupName) -and !(Test-Empty $VNetName))
    $group.UseGlobalVNet = ($group.UseExistingVNet -or !(Test-Empty $VNetAddress))
    $group.SubnetAddressMap = $SubnetAddresses
    $group.Arguments = $Arguments
    $group.TemplatePath = $TemplatePath
    $group.TemplateParent = (Split-Path -Parent -Path $TemplatePath)
    $group.HasProvisionScripts = $false
    $group.HasExtensions = $false
    $group.ProvisionMap = @{'dsc' = @{}; 'custom' = @{}; 'choco' = @{}; 'drives' = @{}}
    $group.NsgMap = @{}
    $group.ProvisionersPath = $null
    $group.StorageAccountName = $null
    $group.VirtualMachineInfo = @{}
    $group.VirtualNetworkInfo = @{}
    $group.StorageAccountInfo = @{}
    $group.RedisCacheInfo = @{}
    $group.VPNInfo = @{}

    $groupObj = New-Object -TypeName PSObject -Property $group

    # validate the fogg parameters
    Test-FoggObjectParameters $groupObj

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
    if (!(Test-PathExists $FoggObject.TemplatePath)) {
        throw "Template path supplied does not exist: $($FoggObject.TemplatePath)"
    }

    # read in the template to check for object types
    $template = Get-JSONContent $FoggObject.TemplatePath

    # if no resource group name passed, fail
    if (Test-Empty $FoggObject.ResourceGroupName) {
        throw 'No Resource Group Name has been supplied'
    }

    # if no location passed, fail
    if (Test-Empty $FoggObject.Location) {
        throw 'No Location to deploy VMs into has been supplied'
    }

    # only validate vnet/snet if template has a vm/vpn/redis - and only if redis uses subnets
    $hasVMs = (Test-TemplateHasType $template.template 'vm')
    $hasVPNs = (Test-TemplateHasType $template.template 'vpn')

    $hasRedisSubnet = $false
    if (Test-TemplateHasType $template.template 'redis') {
        $hasRedisSubnet = ($template.template | Where-Object { $_.type -ieq 'redis' -and $_.subnet -eq $true } | Measure-Object).Count -ne 0
    }

    if ($hasVMs -or $hasVPNs -or $hasRedisSubnet)
    {
        # if no vnet address or vnet resource group/name for existing vnet, fail
        if (!$FoggObject.UseExistingVNet -and (Test-Empty $FoggObject.VNetAddress)) {
            throw 'No Address prefix, Resource Group or VNet name has been supplied to create, or re-use, a Virtual Network'
        }

        # subnets are required when creating a new global vnet
        if (!$FoggObject.UseExistingVNet -and (Test-Empty $FoggObject.SubnetAddressMap)) {
            throw 'No Address prefixes for new Subnets have been supplied'
        }
    }

    # validate resource group name lengths
    Test-FoggResourceGroupName $FoggObject.ResourceGroupName
    Test-FoggResourceGroupName $FoggObject.VNetResourceGroupName -Optional
}

function Test-FoggLocation
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location
    )

    return ((Get-FoggLocation -Location $Location) -ne $null)
}

function Test-FoggLocationZones
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location,

        [Parameter(Mandatory=$true)]
        [ValidateSet('VirtualMachines')]
        [string]
        $ResourceType,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [string[]]
        $Zones
    )

    $zs = (Get-FoggLocationZones -Location $Location -ResourceType $ResourceType -Name $Name)
    return (($Zones | Where-Object { $zs -notcontains $_ } | Measure-Object).Count -eq 0)
}

function New-DeployTemplateRedis
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Template,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        [Parameter()]
        $VNet
    )

    $_args = $FoggObject.Arguments

    $startTime = [DateTime]::UtcNow
    $role = $Template.role.ToLowerInvariant()
    $type = $Template.type.ToLowerInvariant()
    $basename = (Join-ValuesDashed @($FoggObject.Platform, $role))

    # template variables
    $nonSsl = [bool]$Template.nonSsl
    $isPrivate = [bool]$Template.private
    $shards = (Get-FoggDefaultInt -Value (Get-Replace $Template.shards $role $_args) -Default 1)

    # subnet info
    if ($isPrivate) {
        $subnet = (?? (Get-Replace $Template.subnet $role $_args) "$($basename)-$($type)")
        $subnetPrefix = $FoggObject.SubnetAddressMap[$subnet]
        $subnetName = (Get-FoggSubnetName $subnet)
        $subnetObj = ($VNet.Subnets | Where-Object { $_.Name -ieq $subnetName -or $_.AddressPrefix -ieq $subnetPrefix } | Select-Object -First 1)
    }

    # Redis Cache information
    $FoggObject.RedisCacheInfo.Add($role, @{})
    $redisInfo = $FoggObject.RedisCacheInfo[$role]

    Write-Information "Deploying Redis Cache for the '$($role)' template"

    # default variables
    $config = @{}
    if ($Template.config -ne $null) {
        $config = ConvertFrom-JsonObjectToMap -JsonObject $Template.config
    }

    $whitelist = $null
    if ($Template.whitelist -ne $null) {
        $whitelist = ConvertFrom-JsonObjectToMap -JsonObject $Template.whitelist
    }

    # create the redis cache
    $size = (Get-Replace $Template.size $role $_args)
    $sku = (Get-Replace $Template.sku $role $_args)

    $redis = New-FoggRedisCache -FoggObject $FoggObject -Role $role -Size $size -Sku $sku -ShardCount $shards `
        -Subnet $subnetObj -Configuration $config -Whitelist $whitelist -EnableNonSslPort:$nonSsl

    # basic redis info
    $redisInfo.Add('Name', $redis.Name)
    $redisInfo.Add('HostName', $redis.HostName)
    $redisInfo.Add('StaticIP', $redis.StaticIP)
    $redisInfo.Add('Shards', $redis.ShardCount)
    
    # redis ports info
    $redisInfo.Add('Ports', @{})
    $redisInfo.Ports.Add('Ssl', $redis.SslPort)
    $redisInfo.Ports.Add('NonSsl', $redis.Port)
    $redisInfo.Ports.Add('NonSslPortEnabled', $nonSsl)

    # redis access key info
    $key = (Get-FoggRedisCacheKey -ResourceGroupName $FoggObject.ResourceGroupName -Name $redis.Name)
    $redisInfo.Add('AccessKey', $key)

    # output the time taken to create Redis Cache
    Write-Duration $startTime -PreText 'Redis Cache Duration'
    Write-Host ([string]::Empty)
}

function New-DeployTemplateSA
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Template,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject
    )

    $startTime = [DateTime]::UtcNow
    $role = $Template.role.ToLowerInvariant()

    # Storage Account information
    $FoggObject.StorageAccountInfo.Add($role, @{})
    $saInfo = $FoggObject.StorageAccountInfo[$role]

    Write-Information "Deploying Storage Account for the '$($role)' template"

    # create the storage account
    $premium = [bool]$Template.premium
    $sa = New-FoggStorageAccount -FoggObject $FoggObject -Role $role -Premium:$premium

    $saInfo.Add('Name', $sa.StorageAccountName)
    $saInfo.Add('Premium', $premium)

    # output the time taken to create Storage Account
    Write-Duration $startTime -PreText 'Storage Account Duration'
    Write-Host ([string]::Empty)
}

function New-DeployTemplateVNet
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Template,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject
    )

    $startTime = [DateTime]::UtcNow
    $role = $Template.role.ToLowerInvariant()
    $basename = (Join-ValuesDashed @($role))

    # VNet information
    $FoggObject.VirtualNetworkInfo.Add($role, @{})
    $vnetInfo = $FoggObject.VirtualNetworkInfo[$role]
    $vnetInfo.Add('Address', $Template.address)
    $vnetInfo.Add('Subnets', @())

    Write-Information "Deploying Virtual Network for the '$($role)' template"

    # create the virtual network
    $vnet = New-FoggVirtualNetwork -ResourceGroupName $FoggObject.ResourceGroupName -Name $basename `
        -Location $FoggObject.Location -Address $Template.address

    $vnetInfo.Add('Name', $vnet.Name)

    # add the subnets to the vnet
    $subnets = ConvertFrom-JsonObjectToMap $Template.subnets

    $subnets.Keys | ForEach-Object {
        $snetName = (Get-FoggSubnetName $_)

        $vnet = Add-FoggSubnetToVNet -ResourceGroupName $FoggObject.ResourceGroupName -VNetName $vnet.Name `
            -SubnetName $snetName -Address $subnets[$_]

        $vnetInfo.Subnets += @{
            'Name' = $snetName;
            'Address' = $subnets[$_];
        }
    }

    # output the time taken to create VNet
    Write-Duration $startTime -PreText 'Virtual Network Duration'
    Write-Host ([string]::Empty)
}

function New-DeployTemplateVM
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FullTemplate,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Template,

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

    $_args = $FoggObject.Arguments
    $_exts = $FullTemplate.extensions

    $role = $Template.role.ToLowerInvariant()
    $type = $Template.type.ToLowerInvariant()
    $basename = (Join-ValuesDashed @($role))
    $publicIpType = (?? (Get-Replace $Template.publicIp $role $_args) 'none')
    $useManagedDisks = [bool]$Template.managed
    $subnet = (?? (Get-Replace $Template.subnet $role $_args) "$($basename)-$($type)")
    $subnetPrefix = $FoggObject.SubnetAddressMap[$subnet]
    $subnetName = (Get-FoggSubnetName $subnet)
    $subnetObj = ($VNet.Subnets | Where-Object { $_.Name -ieq $subnetName -or $_.AddressPrefix -ieq $subnetPrefix })

    # VM information
    $FoggObject.VirtualMachineInfo.Add($role, @{})
    $vmInfo = $FoggObject.VirtualMachineInfo[$role]
    $vmInfo.Add('Subnet', @{})
    $vmInfo.Add('AvailabilitySet', $null)
    $vmInfo.Add('AvailabilityZones', @())
    $vmInfo.Add('LoadBalancer', @{})
    $vmInfo.Add('VirtualMachines', @())

    # set subnet details against VM info
    $vmInfo.Subnet.Add('Name', $subnetObj.Name)
    $vmInfo.Subnet.Add('Address', $subnetPrefix)

    # are we using availability zones
    $zonesCount = Get-Count $Template.zones
    $useAvailabilityZones = ($zonesCount -ne 0)

    # are we using a load balancer and availability set/zones?
    $useLoadBalancer = !(Test-Empty $Template.loadBalancer)

    # if zones have been supplied, availability set should be false!
    $useAvailabilitySet = (!$useAvailabilityZones)
    if ($useAvailabilitySet -and !(Test-Empty $Template.availabilitySet)) {
        $useAvailabilitySet = [bool]$Template.availabilitySet
    }

    $_count = (Get-FoggDefaultInt -Value (Get-Replace $Template.count $role $_args) -Default 1)
    Write-Information "Deploying $($_count) VM(s) for the '$($role)' template"

    # create an availability set
    if ($useAvailabilitySet) {
        $avsetName = (Get-FoggAvailabilitySetName $basename)
        $avset = New-FoggAvailabilitySet -FoggObject $FoggObject -Name $avsetName -Managed:$useManagedDisks
        $vmInfo.AvailabilitySet = $avsetName
    }

    if ($useAvailabilityZones) {
        $vmInfo.AvailabilityZones = $Templates.zones
    }

    # if supplied, create load balancer
    if ($useLoadBalancer) {
        $lb = $Template.loadBalancer
        $lbName = (Get-FoggLoadBalancerName $basename)

        Write-Information "Setting up Load Balancer: $($lbName)"

        # create base rules config
        $rules = @{}
        foreach ($rule in $lb.rules) {
            $rules.Add($rule.name, @{
                'Port' = $rule.port;
                'Floating' = (?? $rule.floating $false);
                'Timeout' = (?? $rule.timeout 4);
                'Probe' = $null;
                'Frontend' = @{
                    'Name' = (?? $rule.frontend 'default')
                    'PublicIP' = $null;
                    'PrivateIP' = $null;
                };
            })
        }

        # attach probes to rules
        foreach ($probe in $lb.probes) {
            foreach ($rule in $probe.rules) {
                $rules[$rule].Probe = @{
                    'Port' = (?? $probe.port $rules[$rule].Port);
                    'Interval' = (?? $probe.interval 5);
                    'Threshold' = (?? $probe.threshold 2);
                }
            }
        }

        # create the load balancer
        $lb = New-FoggLoadBalancer -FoggObject $FoggObject -Name $lbName -SubnetId $subnetObj.Id `
            -Rules $rules -PublicIpType $publicIpType

        # return object details
        $vmInfo.LoadBalancer.Add('Name', $lbName)
        $vmInfo.LoadBalancer.Add('Rules', $rules)

        # set publicIp to none after creating public load balancer
        $publicIpType = 'none'
    }
    else {
        $lb = $null
    }

    # work out the base index of the VM, if we're appending instead of creating
    $baseIndex = 0

    if ($Template.append) {
        # get list of all VMs
        $rg_vms = Get-FoggVMs -ResourceGroupName $FoggObject.ResourceGroupName

        # if no VMs returned, keep default base index as 0
        if (!(Test-ArrayEmpty $rg_vms)) {
            # filter on base VM name to get last VM deployed
            $name = ($rg_vms | Where-Object { $_.Name -ilike "$($basename)*" } | Select-Object -Last 1 -ExpandProperty Name)

            # if name has a value at the end, take it as the base index
            if ($name -imatch "^$($basename)(\d+)") {
                $baseIndex = ([int]$Matches[1])
            }
        }
    }

    # does the VM have OS settings, or use global?
    $os = $FullTemplate.os
    if ($Template.os -ne $null) {
        $os = $Template.os
    }

    # create each of the VMs
    $_vms = @()

    1..($_count) | ForEach-Object {
        $index = ($_ + $baseIndex)

        $zone = $null
        if ($useAvailabilityZones) {
            $zone = $Template.zones[($index % $zonesCount)]
        }

        $_vms += (New-FoggVM -FoggObject $FoggObject -Name $basename -Index $index -VMCredentials $VMCredentials `
            -StorageAccount $StorageAccount -SubnetId $subnetObj.Id -OS $os -Vhd $Template.vhd -Image $Template.image `
            -AvailabilitySet $avset -Drives $Template.drives -PublicIpType $publicIpType -Zone $zone -Managed:$useManagedDisks)
    }

    # loop through each VM and deploy it
    foreach ($_vm in $_vms) {
        if ($_vm -eq $null) {
            continue
        }

        $startTime = [DateTime]::UtcNow

        # deploy the VM
        Save-FoggVM -FoggObject $FoggObject -VM $_vm -LoadBalancer $lb

        # see if we need to provision the machine
        if ($FoggObject.HasProvisionScripts) {
            # check if we have an provisioners defined
            $provs = $Template.provisioners
            if (Test-ArrayEmpty $provs) {
                $provs = @()
            }

            if (!(Test-ArrayEmpty $Template.drives)) {
                $provs = @('attach-drives') + $provs
            }

            Set-ProvisionVM -FoggObject $FoggObject -Provisioners $provs -VMName $_vm.Name -StorageAccount $StorageAccount -OSType $os.type
        }

        # due to a bug with the CustomScriptExtension, if we have any uninstall the extension
        Remove-FoggCustomScriptExtension -FoggObject $FoggObject -VMName $_vm.Name -OSType $os.type

        # see if we need to attach and further extensions onto the machine
        if ($FoggObject.HasExtensions) {
            Set-ExtensionVM -FoggObject $FoggObject -Extensions $_exts -VMName $_vm.Name -Role $role -OSType $os.type
        }

        # get VM's NIC
        $nicId = Get-NameFromAzureId $_vm.NetworkProfile.NetworkInterfaces[0].Id
        $nicIPs = (Get-FoggNetworkInterface -ResourceGroupName $FoggObject.ResourceGroupName -Name $nicId).IpConfigurations[0]

        # get VM's public IP
        if (!(Test-Empty $nicIPs.PublicIpAddress)) {
            $pipId = Get-NameFromAzureId $nicIPs.PublicIpAddress[0].Id
            $pipIP = (Get-FoggPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName -Name $pipId).IpAddress
        }

        # save VM info details
        $vmInfo.VirtualMachines += @{
            'Name' = $_vm.Name;
            'PrivateIP' = $nicIPs.PrivateIpAddress;
            'PublicIP' = $pipIP;
            'Zone' = ($_vm.Zones | Select-Object -First 1)
        }

        # output the time taken to create VM
        Write-Duration $startTime -PreText 'VM Duration'
        Write-Host ([string]::Empty)
    }

    # turn off some of the VMs if needed
    if ($Template.off -gt 0) {
        $count = ($_vms | Measure-Object).Count
        $base = ($count - $Template.off) + 1

        $count..$base | ForEach-Object {
            $_vm = Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $basename -Index $_ 
            Stop-FoggVM -FoggObject $FoggObject -Name $_vm.Name -StayProvisioned
        }
    }
}

function New-DeployTemplateVPN
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Template,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $VNet
    )

    $startTime = [DateTime]::UtcNow
    $role = $Template.role.ToLowerInvariant()
    $basename = (Join-ValuesDashed @($role))

    # VPN information
    $FoggObject.VPNInfo.Add($role, @{})

    Write-Information "Deploying VPN for '$($role)' template"

    switch ($Template.configType.ToLowerInvariant())
    {
        's2s' {
            # get required IP addresses
            $gatewayIP = $FoggObject.SubnetAddressMap["$($basename)-gip"]
            $addressOnPrem = $FoggObject.SubnetAddressMap["$($basename)-opm"]

            # create the local network gateway for the VPN
            $lng = New-FoggLocalNetworkGateway -FoggObject $FoggObject -Name $basename `
                -GatewayIPAddress $gatewayIP -Address $addressOnPrem

            # create public vnet gateway
            $gw = New-FoggVirtualNetworkGateway -FoggObject $FoggObject -Name $basename -VNet $VNet `
                -VpnType $Template.vpnType -GatewaySku $Template.gatewaySku

            # create VPN connection
            New-FoggVirtualNetworkGatewayConnection -FoggObject $FoggObject -Name $basename `
                -LocalNetworkGateway $lng -VirtualNetworkGateway $gw -SharedKey $Template.sharedKey | Out-Null
        }

        'p2s' {
            # get required IP addresses
            $clientPool = $FoggObject.SubnetAddressMap["$($basename)-cap"]

            # resolve the cert path
            $certPath = Resolve-Path -Path $Template.certPath -ErrorAction Ignore

            # create public vnet gateway
            New-FoggVirtualNetworkGateway -FoggObject $FoggObject -Name $basename -VNet $VNet `
                -VpnType $Template.vpnType -GatewaySku $Template.gatewaySku -ClientAddressPool $clientPool `
                -PublicCertificatePath $certPath | Out-Null
        }
    }

    # output the time taken to create VM
    Write-Duration $startTime -PreText 'VPN Duration'
}
