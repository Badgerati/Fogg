$ErrorActionPreference = 'Stop'
$WarningPreference = 'Ignore'

function Add-FoggAccount
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject
    )

    Write-Information "Attempting to login to Azure Subscription: $($FoggObject.SubscriptionName)"

    # do we need to request for user credentials?
    if ($FoggObject.SubscriptionCredentials -ne $null)
    {
        # connect using a service principal or a user account?
        if (Test-Empty $FoggObject.TenantId) {
            Add-AzureRmAccount -Credential $FoggObject.SubscriptionCredentials -SubscriptionName $FoggObject.SubscriptionName | Out-Null
        }
        else {
            Write-Information 'Using Service Principal account for login'
            Add-AzureRmAccount -Credential $FoggObject.SubscriptionCredentials -SubscriptionName $FoggObject.SubscriptionName -TenantId $FoggObject.TenantId -ServicePrincipal | Out-Null
        }
    }
    else {
        Add-AzureRmAccount -SubscriptionName $FoggObject.SubscriptionName | Out-Null
    }

    if (!$?) {
        throw "Failed to login into Azure Subscription: $($FoggObject.SubscriptionName)"
    }

    $FoggObject.LoggedIn = $true
    Write-Success "Logged into Azure Subscription: $($FoggObject.SubscriptionName)`n"
}

function Remove-FoggAccount
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject
    )

    if ($FoggObject.LoggedIn) {
        Write-Information "Attempting to logout of Azure Subscription: $($FoggObject.SubscriptionName)"

        Remove-AzureRmAccount | Out-Null
        if (!$?) {
            throw 'Failed to logout of Azure'
        }

        Write-Success 'Logged out of Azure successfully'
    }
}


function Add-FoggAdminAccount
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject
    )

    $attempts = 0
    $success = $false

    while ($attempts -lt 3 -and !$success) {
        try {
            # increment the number of attempts
            $attempts++

            # only request for admin creds if they weren't supplied from the CLI
            if ($FoggObject.VMCredentials -eq $null) {
                Write-Information "Setting up VM admin credentials"

                $FoggObject.VMCredentials = Get-Credential -Message 'Supply the Admininstrator username and password for the VMs in Azure'
                if ($FoggObject.VMCredentials -eq $null) {
                    throw 'No Azure VM Administrator credentials passed'
                }

                Write-Success "VM admin credentials setup`n"
            }

            # validate the admin username
            Test-FoggVMUsername $FoggObject.VMCredentials.Username

            # validate the admin password
            Test-FoggVMPassword $FoggObject.VMCredentials.Password

            # mark as successful
            $success = $true
        }
        catch [exception] {
            Write-Host "$($_.Exception.Message)" -ForegroundColor Red
            $FoggObject.VMCredentials = $null
        }
    }

    # if we get here and attempts is 3+, fail
    if ($attempts -ge 3 -and !$success) {
        throw 'You have failed to enter valid admin credentials 3 times, exitting'
    }
}


function Get-FoggResourceGroup
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter()]
        [string]
        $Location
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)

    try
    {
        if (Test-Empty $Location)
        {
            $rg = Get-AzureRmResourceGroup -Name $ResourceGroupName
        }
        else
        {
            $rg = Get-AzureRmResourceGroup -Name $ResourceGroupName -Location $Location
        }

        if (!$?)
        {
            throw "Failed to make Azure call to retrieve resource group: $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*resource group does not exist*')
        {
            $rg = $null
        }
        else
        {
            throw
        }
    }

    return $rg
}


function New-FoggResourceGroup
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject
    )

    Write-Information "Creating resource group $($FoggObject.ResourceGroupName) in $($FoggObject.Location)"

    $rg = Get-FoggResourceGroup -ResourceGroupName $FoggObject.ResourceGroupName -Location $FoggObject.Location
    if ($rg -ne $null)
    {
        Write-Notice "Using existing resource group for $($FoggObject.ResourceGroupName)`n"
        return $rg
    }

    $rg = New-AzureRmResourceGroup -Name $FoggObject.ResourceGroupName -Location $FoggObject.Location -Force
    if (!$?)
    {
        throw "Failed to create resource group $($FoggObject.ResourceGroupName) in $($FoggObject.Location)"
    }

    Write-Success "Resource group $($FoggObject.ResourceGroupName) created in $($FoggObject.Location)`n"
    return $rg
}


function Update-FoggResourceTags
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter()]
        [hashtable]
        $Tags = $null
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)

    # if there are no tags, just return
    if (Test-Empty $Tags)
    {
        return
    }

    # retieve all of the resources in the group
    $resources = Find-AzureRmResource -ResourceGroupName $ResourceGroupName
    $count = ($resources | Measure-Object).Count

    Write-Information "Updating tags on all $($count) Resource(s) in Resource Group $($ResourceGroupName)"
    $Tags.Keys | ForEach-Object {
        Write-Information "> $($_): $($Tags[$_])"
    }

    Write-Host ([string]::Empty)

    # update the tags against those resources
    foreach ($resource in $resources)
    {
        Write-Information "> Updating tags against: $($resource.Name)"

        $t = $resource.Tags
        $t = Set-FoggTags -Tags $t -UpdatedTags $Tags

        Set-AzureRmResource -ResourceGroupName $ResourceGroupName -Name $resource.Name -ResourceType $resource.ResourceType `
            -Tag $t -Force | Out-Null

        if (!$?)
        {
            throw "Failed to update tags on the $($resource.Name) resource"
        }
    }

    # now update the tags against the resource group
    Write-Information "> Updating tags against: $($ResourceGroupName)"

    $t = (Get-FoggResourceGroup -ResourceGroupName $ResourceGroupName).Tags
    $t = Set-FoggTags -Tags $t -UpdatedTags $Tags

    Set-AzureRmResourceGroup -Name $ResourceGroupName -Tag $t
    if (!$?)
    {
        throw "Failed to update tags on the resource group $($ResourceGroupName)"
    }
}


function Set-FoggTags
{
    param (
        [hashtable]
        $Tags,

        [hashtable]
        $UpdatedTags
    )

    if ($Tags -eq $null)
    {
        $Tags = @{}
    }

    $UpdatedTags.Keys | ForEach-Object {
        $Tags[$_] = $UpdatedTags[$_]
    }

    return $Tags
}

function Test-FoggRedisCacheExists
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $Name = (Get-FoggRedisCacheName -Name $Name)

    $redis = Get-AzureRmRedisCache -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Ignore
    if ($redis -eq $null)
    {
        return $false
    }

    return $true
}

function Get-FoggRedisCache
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $Name = (Get-FoggRedisCacheName -Name $Name)

    $redis = Get-AzureRmRedisCache -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Ignore
    if ($redis -eq $null)
    {
        throw "The Redis Cache '$($Name)' does not exist under Resource Group '$($ResourceGroupName)'. This is likely because the name is in use by someone else, and Redis Cache names are unique globally for everybody"
    }

    return $redis
}

function Get-FoggRedisCacheKey
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $Name = (Get-FoggRedisCacheName -Name $Name)

    $redis = Get-AzureRmRedisCacheKey -ResourceGroupName $ResourceGroupName -Name $Name -ErrorAction Ignore
    if ($redis -eq $null)
    {
        return $null
    }

    return $redis.PrimaryKey
}

function Get-FoggRedisCacheWhitelistRule
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $RuleName
    )

    return Get-AzureRmRedisCacheFirewallRule -ResourceGroupName $ResourceGroupName -Name $Name -RuleName $RuleName -ErrorAction Ignore
}

function New-FoggRedisCacheWhitelist
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [hashtable]
        $Subnets,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Role,

        [Parameter()]
        [hashtable]
        $Arguments,

        [Parameter()]
        $Whitelist
    )

    if (Test-Empty $Whitelist)
    {
        return
    }

    # check if redis cache exists - if it doesn't just return
    if (!(Test-FoggRedisCacheExists -ResourceGroupName $ResourceGroupName -Name $Name))
    {
        return
    }

    # if it does exist, is it ours?
    Get-FoggRedisCache -ResourceGroupName $ResourceGroupName -Name $Name | Out-Null

    Write-Information "Configuring Redis Cache whitelist for $($Name)"

    # loop through each firewall rule, creating and updating them
    $rules = $Whitelist.Keys

    foreach ($rule in $rules)
    {
        # check to see if the rule already exists
        $r = Get-FoggRedisCacheWhitelistRule -ResourceGroupName $ResourceGroupName -Name $Name -RuleName $rule

        # get the current range
        $range = $Whitelist[$rule]
        $range = Get-Replace -Value $range -Subnets $Subnets -Arguments $Arguments -Role $Role

        # see if we need to get subnet range from placeholder
        $subnetRange = Get-SubnetRange -SubnetMask $range
        if ($subnetRange -ne $null)
        {
            $range = "$($subnetRange.lowest)-$($subnetRange.highest)"
        }

        # get the start/end IP range
        $split = $range -isplit '-'
        $start = $split[0].Trim()
        $end = $start

        if ($split.Length -gt 1)
        {
            $end = $split[1].Trim()
        }

        Write-Information "> Rule $($rule): $($start) - $($end)"

        # if it exists, need to check if it should be deleted and re-creating (updated)
        if ($r -ne $null)
        {
            if ($r.StartIP -ine $start -or $r.EndIP -ine $end)
            {
                Remove-AzureRmRedisCacheFirewallRule -ResourceGroupName $ResourceGroupName -Name $Name -RuleName $rule | Out-Null
            }
            else
            {
                continue
            }
        }

        # create the firewall rule
        New-AzureRmRedisCacheFirewallRule -ResourceGroupName $ResourceGroupName -Name $Name -RuleName $rule -StartIP $start -EndIP $end | Out-Null
        if (!$?)
        {
            throw "Failed to create firewall rule on Redis Cache"
        }
    }

    Write-Information "Redis Cache firewall rules configured successfully"
}

function Update-FoggRedisCache
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [string]
        $Role,

        [Parameter(Mandatory=$true)]
        [string]
        $Size,

        [Parameter(Mandatory=$true)]
        [string]
        $Sku,

        [Parameter(Mandatory=$true)]
        [int]
        $ShardCount,

        [Parameter()]
        $Subnet,

        [Parameter()]
        $Configuration,

        [Parameter()]
        $Whitelist,

        [switch]
        $EnableNonSslPort
    )

    # generate the redis cache name
    $basename = (Join-ValuesDashed @($FoggObject.LocationCode, $FoggObject.Stamp, $FoggObject.Platform, $FoggObject.Environment, $Role))
    $Name = Get-FoggRedisCacheName -Name $basename

    if (Test-Empty $Configuration)
    {
        $Configuration = @{}
    }

    # check if redis cache exists - if it doesn't just return
    if (!(Test-FoggRedisCacheExists -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name))
    {
        return
    }

    # if it does exist, is it ours?
    $current = Get-FoggRedisCache -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name

    Write-Information "Updating Redis Cache $($Name) in resource group $($FoggObject.ResourceGroupName)"

    # run the updates based on the sku, and what's being updated
    if ($Sku -ieq 'premium')
    {
        # update size and sku
        if ($Size -ine $current.Size -or $Sku -ine $current.Sku)
        {
            Write-Information "> Updating sku to $($Sku) and size to $($Size)"
            $redis = Set-AzureRmRedisCache -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Size $Size -Sku $Sku -ErrorAction Stop
            Wait-FoggProvisionState -Resource $redis.Id
        }

        # update shard count
        if ($ShardCount -ine $current.ShardCount)
        {
            Write-Information "> Updating number of shards to $($ShardCount)"
            $redis = Set-AzureRmRedisCache -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -ShardCount $ShardCount -ErrorAction Stop
            Wait-FoggProvisionState -Resource $redis.Id
        }
    }
    else
    {
        # update size
        if ($Size -ine $current.Size)
        {
            Write-Information "> Updating size to $($Size)"
            $redis = Set-AzureRmRedisCache -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Size $Size -ErrorAction Stop
            Wait-FoggProvisionState -Resource $redis.Id
        }

        # update sku
        if ($Sku -ine $current.Sku)
        {
            Write-Information "> Updating sku to $($Sku)"
            $redis = Set-AzureRmRedisCache -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Sku $Sku -ErrorAction Stop
            Wait-FoggProvisionState -Resource $redis.Id
        }
    }

    # update general config
    Write-Information "> Updating general Redis configuration"
    $redis = Set-AzureRmRedisCache -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -RedisConfiguration $Configuration `
        -EnableNonSslPort $EnableNonSslPort.IsPresent -ErrorAction Stop

    # loop on ProvisionState until Succeeded
    Wait-FoggProvisionState -Resource $redis.Id

    # update any firewall rules on the cache
    if (!(Test-Empty $Whitelist))
    {
        $subnetName = $null
        if (!(Test-Empty $Subnet))
        {
            $subnetName = $Subnet.Name -ireplace '-snet', ''
        }

        $crole = ?? $subnetName (Join-ValuesDashed @($FoggObject.Platform, $Role, 'redis'))
        New-FoggRedisCacheWhitelist -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Whitelist $Whitelist `
            -Subnets $FoggObject.SubnetAddressMap -Arguments $FoggObject.Arguments -Role $crole
    }

    # refetch the cache
    $redis = Get-FoggRedisCache -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name

    Write-Success "Redis Cache $($Name) updated at $($FoggObject.Location)`n"
    return $redis
}

function New-FoggRedisCache
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [string]
        $Role,

        [Parameter(Mandatory=$true)]
        [string]
        $Size,

        [Parameter(Mandatory=$true)]
        [string]
        $Sku,

        [Parameter(Mandatory=$true)]
        [int]
        $ShardCount,

        [Parameter()]
        $Subnet,

        [Parameter()]
        $Configuration,

        [Parameter()]
        $Whitelist,

        [switch]
        $EnableNonSslPort
    )

    # generate the redis cache name
    $basename = (Join-ValuesDashed @($FoggObject.LocationCode, $FoggObject.Stamp, $FoggObject.Platform, $FoggObject.Environment, $Role))
    $Name = Get-FoggRedisCacheName -Name $basename

    if (Test-Empty $Configuration)
    {
        $Configuration = @{}
    }

    Write-Information "Creating Redis Cache $($Name) in resource group $($FoggObject.ResourceGroupName)"

    # get an existing redis cache, and check if it's ours or someone elses
    if (Test-FoggRedisCacheExists -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name)
    {
        Write-Notice "Found existing Redis Cache for $($Name)`n"
        $redis = Get-FoggRedisCache -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name

        $redis = Update-FoggRedisCache -FoggObject $FoggObject -Role $Role -Size $Size -Sku $Sku -ShardCount $ShardCount `
            -Configuration $Configuration -Whitelist $Whitelist -Subnet $Subnet -EnableNonSslPort:$EnableNonSslPort

        return $redis
    }

    # get subnetId from subnet
    $subnetId = $null
    if (!(Test-Empty $Subnet))
    {
        $subnetId = $Subnet.Id
    }

    # create a new redis cache (only pass subnet if premium)
    if ($Sku -ieq 'premium')
    {
        $redis = New-AzureRmRedisCache -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location `
            -Size $Size -Sku $Sku -RedisConfiguration $Configuration -ShardCount $ShardCount -SubnetId $subnetId -EnableNonSslPort $EnableNonSslPort.IsPresent
    }
    else
    {
        $redis = New-AzureRmRedisCache -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location `
            -Size $Size -Sku $Sku -RedisConfiguration $Configuration -SubnetId $subnetId -EnableNonSslPort $EnableNonSslPort.IsPresent
    }

    if (!$?)
    {
        throw "Failed to create Redis Cache $($Name)"
    }

    # loop on ProvisionState until Succeeded
    Wait-FoggProvisionState -Resource $redis.Id

    # add any firewall rules to the cache
    if (!(Test-Empty $Whitelist))
    {
        $subnetName = $null
        if (!(Test-Empty $Subnet))
        {
            $subnetName = $Subnet.Name -ireplace '-snet', ''
        }

        $crole = ?? $subnetName (Join-ValuesDashed @($FoggObject.Platform, $Role, 'redis'))
        New-FoggRedisCacheWhitelist -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Whitelist $Whitelist `
            -Subnets $FoggObject.SubnetAddressMap -Arguments $FoggObject.Arguments -Role $crole
    }

    Write-Success "Redis Cache $($Name) created at $($FoggObject.Location)`n"
    return $redis
}

function Test-FoggStorageAccountExists
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $StorageAccountName
    )

    $StorageAccountName = ($StorageAccountName.ToLowerInvariant()) -ireplace '-', ''

    $sa = Get-AzureRmStorageAccountNameAvailability -Name $StorageAccountName
    if ($sa.NameAvailable)
    {
        return $false
    }
    else
    {
        Write-Notice $sa.Message
        return $true
    }
}


function Get-FoggStorageAccount
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $StorageAccountName
    )

    $StorageAccountName = ($StorageAccountName.ToLowerInvariant()) -ireplace '-', ''

    $storage = Get-AzureRmStorageAccount -ResourceGroupName $ResourceGroupName -Name $StorageAccountName -ErrorAction Ignore
    if ($storage -eq $null)
    {
        throw "The Storage Account '$($StorageAccountName)' does not exist under Resource Group '$($ResourceGroupName)'. This is likely because the name is in use by someone else, and Storage Account names are unique globally for everybody"
    }

    return $storage
}


function New-FoggStorageAccount
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        [string]
        $Role,

        [switch]
        $Premium
    )

    # what's the storage type?
    $StorageType = 'Standard_LRS'
    if ($Premium)
    {
        $StorageType = 'Premium_LRS'
    }

    # generate the storage account's name
    $basename = (Join-ValuesDashed @($FoggObject.LocationCode, $FoggObject.Stamp, $FoggObject.Platform, $FoggObject.Environment, $Role))
    $Name = Get-FoggStorageAccountName -Name $basename

    Write-Information "Creating Storage Account $($Name) in Resource Group $($FoggObject.ResourceGroupName)"

    # get an existing storage account, and check if it's ours or someone elses
    if (Test-FoggStorageAccountExists $Name)
    {
        Write-Notice "Found existing Storage Account for $($Name)`n"
        $storage = Get-FoggStorageAccount -ResourceGroupName $FoggObject.ResourceGroupName -StorageAccountName $Name
        return $storage
    }

    # create a new storage account
    $sa = New-AzureRmStorageAccount -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -SkuName $StorageType `
        -Kind Storage -Location $FoggObject.Location

    if (!$?)
    {
        throw "Failed to create Storage Account $($Name)"
    }

    Write-Success "Storage Account $($Name) created at $($FoggObject.Location)`n"
    return $sa
}


function Publish-ProvisionerScripts
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $StorageAccount
    )

    # do we have any scripts that need publishing?
    if (!$FoggObject.HasProvisionScripts)
    {
        return
    }

    # are there any DSC scripts to publish?
    if (!(Test-Empty $FoggObject.ProvisionMap['dsc']))
    {
        $FoggObject.ProvisionMap['dsc'].Values | ForEach-Object {
            $script = ($_ | Select-Object -First 1)
            Publish-FoggDscScript -FoggObject $FoggObject -StorageAccount $StorageAccount -ScriptPath $script
        }
    }

    # are there any custom scripts to publish? if so, need a storage container first
    if (!(Test-Empty $FoggObject.ProvisionMap['custom']))
    {
        $container = New-FoggStorageContainer -FoggObject $FoggObject -StorageAccount $StorageAccount -Name 'provs-custom'

        $FoggObject.ProvisionMap['custom'].Values | ForEach-Object {
            $script = ($_ | Select-Object -First 1)
            Publish-FoggCustomScript -FoggObject $FoggObject -StorageAccount $StorageAccount -Container $container -ScriptPath $script
        }
    }

    # do we need to publish the choco-install script?
    if (!(Test-Empty $FoggObject.ProvisionMap['choco']))
    {
        $container = New-FoggStorageContainer -FoggObject $FoggObject -StorageAccount $StorageAccount -Name 'provs-choco'
        $script = ($FoggObject.ProvisionMap['choco'].Values | Select-Object -First 1)[0]
        Publish-FoggCustomScript -FoggObject $FoggObject -StorageAccount $StorageAccount -Container $container -ScriptPath $script
    }

    # do we need to publish any drives scripts?
    if (!(Test-Empty $FoggObject.ProvisionMap['drives']))
    {
        $container = New-FoggStorageContainer -FoggObject $FoggObject -StorageAccount $StorageAccount -Name 'provs-drives'
        $script = ($FoggObject.ProvisionMap['drives'].Values | Select-Object -First 1)[0]
        Publish-FoggCustomScript -FoggObject $FoggObject -StorageAccount $StorageAccount -Container $container -ScriptPath $script
    }
}


function Publish-FoggCustomScript
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $StorageAccount,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Container,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ScriptPath
    )

    $saName = $StorageAccount.StorageAccountName
    $fName = Split-Path -Leaf -Path "$($ScriptPath)"
    $cName = $Container.Name
    $ctx = $Container.Context

    Write-Information "Publishing $($ScriptPath) Custom script to the $($saName) storage account"

    $output = Set-AzureStorageBlobContent -Container $cName -Context $ctx -File $ScriptPath -Blob $fName -Force
    if (!$?)
    {
        throw "Failed to publish Custom script to $($saName): `n$($output)"
    }

    Write-Success "Custom script published`n"
}


function Publish-FoggDscScript
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $StorageAccount,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ScriptPath
    )

    $saName = $StorageAccount.StorageAccountName

    Write-Information "Publishing $($ScriptPath) DSC script to the $($saName) storage account"

    $output = Publish-AzureRmVMDscConfiguration -ResourceGroupName $FoggObject.ResourceGroupName `
        -StorageAccountName $saName -ConfigurationPath $ScriptPath -Force

    if (!$?)
    {
        throw "Failed to publish DSC script to $($saName): `n$($output)"
    }

    Write-Success "DSC script published`n"
}

function Set-ExtensionVM
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        $Extensions,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Role,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $OSType
    )

    # check if there are any extensions
    if (!$FoggObject.HasExtensions -or (Test-Empty $Extensions))
    {
        return
    }

    # loop through each extension and install appropriately
    $Extensions.psobject.properties.name | ForEach-Object {
        switch ($_.ToLowerInvariant()) {
            'chef' {
                Set-ExtensionVMChef -FoggObject $FoggObject -Extension $Extensions.$_ -VMName $VMName -Role $Role -OSType $OSType
            }
        }
    }
}

function Set-ExtensionVMChef
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        $Extension,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Role,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $OSType
    )

    Write-Information "Installing Chef Extension on VM $($VMName)"

    # replace any placeholders
    $chef_url = Get-Replace -Value $Extension.url -Arguments $FoggObject.Arguments -Role $Role
    $chef_ver = Get-Replace -Value $Extension.version -Arguments $FoggObject.Arguments -Role $Role
    $chef_intvl = Get-Replace -Value $Extension.interval -Arguments $FoggObject.Arguments -Role $Role
    $val_pem = Get-Replace -Value $Extension.validation.pem -Arguments $FoggObject.Arguments -Role $Role
    $val_name = Get-Replace -Value $Extension.validation.name -Arguments $FoggObject.Arguments -Role $Role

    if (!(Test-Empty $Extension.runlist)) {
        $runlist = ($Extension.runlist -join ', ')
        $runlist = Get-Replace -Value $runlist -Arguments $FoggObject.Arguments -Role $Role
    }

    # default any variables not supplied
    $chef_intvl = (?? $chef_intvl '30')
    $chef_ver = (?? $chef_ver $null)
    $runlist = (?? $runlist "")

    switch ($OSType.ToLowerInvariant()) {
        'windows' {
            $output = Set-AzureRmVMChefExtension -ResourceGroupName $FoggObject.ResourceGroupName -VMName $VMName -ValidationPem $val_pem `
                -RunList $runlist -ChefServerUrl $chef_url -ValidationClientName $val_name -Location $FoggObject.Location `
                -ChefDaemonInterval $chef_intvl -BootstrapVersion $chef_ver -AutoUpgradeMinorVersion $true -Windows -ErrorAction 'Continue'
        }

        'linux' {
            $output = Set-AzureRmVMChefExtension -ResourceGroupName $FoggObject.ResourceGroupName -VMName $VMName -ValidationPem $val_pem `
                -RunList $runlist -ChefServerUrl $chef_url -ValidationClientName $val_name -Location $FoggObject.Location `
                -ChefDaemonInterval $chef_intvl -BootstrapVersion $chef_ver -AutoUpgradeMinorVersion $true -Linux -ErrorAction 'Continue'
        }
    }

    if ($output -eq $null -or !$output.IsSuccessStatusCode)
    {
        $err = 'An unexpected error occurred, this usually happens when Internet connectivity is lost'

        if ($output -ne $null)
        {
            $err = $output.ReasonPhrase
        }

        throw "Failed to install the Chef Extension on VM $($VMName):`n$($err)"
    }

    Write-Success "Chef Extension installed`n"
}

function Set-ProvisionVM
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        $Provisioners,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMName,

        [Parameter(Mandatory=$true)]
        $StorageAccount,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $OSType
    )

    # check if there are any provision scripts
    if (!$FoggObject.HasProvisionScripts -or (Test-ArrayEmpty $Provisioners))
    {
        return
    }

    # what's the current os type?
    $OSType = $OSType.ToLowerInvariant()

    # cache the map for speed
    $map = $FoggObject.ProvisionMap

    # loop through each provisioner, and run appropriate tool
    $Provisioners | ForEach-Object {
        # Parse the key, incase we need to pass parameters
        $key = $_
        if ($key -ine 'dsc' -and $key.Contains(':'))
        {
            $arr = $key -split '\:'
            $key = $arr[0].Trim()
            $_args = $arr[1].Trim()
        }
        else
        {
            $_args = $null
        }

        # DSC (only for windows)
        if ($map['dsc'].ContainsKey($key) -and $OSType -ieq 'windows')
        {
            Set-FoggDscConfig -FoggObject $FoggObject -VMName $VMName -StorageAccount $StorageAccount `
                -ScriptPath $map['dsc'][$key][0]
        }

        # Custom (both windows and linux)
        elseif ($map['custom'].ContainsKey($key))
        {
            Set-FoggCustomConfig -FoggObject $FoggObject -VMName $VMName -StorageAccount $StorageAccount `
                -ContainerName 'provs-custom' -ScriptPath $map['custom'][$key][0] -Arguments $_args -OSType $OSType
        }

        # Chocolatey (only for windows)
        elseif ($map['choco'].ContainsKey($key) -and $OSType -ieq 'windows')
        {
            $choco = $map['choco'][$key]

            if (Test-Empty $_args)
            {
                $_args = $choco[1]
            }

            Write-Details "Chocolatey Provisioner: $($key) ($($_args))"

            Set-FoggCustomConfig -FoggObject $FoggObject -VMName $VMName -StorageAccount $StorageAccount `
                -ContainerName 'provs-choco' -ScriptPath $choco[0] -Arguments $_args -OSType $OSType
        }

        # Drives
        elseif ($map['drives'].ContainsKey($key))
        {
            $drives = $map['drives'][$key]
            $_args = $drives[1]

            Set-FoggCustomConfig -FoggObject $FoggObject -VMName $VMName -StorageAccount $StorageAccount `
                -ContainerName 'provs-drives' -ScriptPath $drives[0] -Arguments $_args -OSType $OSType
        }
    }
}

function Set-FoggDscConfig
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMName,

        [Parameter(Mandatory=$true)]
        $StorageAccount,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ScriptPath
    )

    $script = Split-Path -Leaf -Path "$($ScriptPath)"
    if (!$script.EndsWith('.zip'))
    {
        $script = "$($script).zip"
    }

    $func = ($script -ireplace '\.ps1\.zip', '') -ireplace '-', ''

    Write-Information "Installing DSC Extension on VM $($VMName), and running script $($script)"

    $output = Set-AzureRmVMDscExtension -ResourceGroupName $FoggObject.ResourceGroupName -VMName $VMName -ArchiveBlobName $script `
        -ArchiveStorageAccountName $StorageAccount.StorageAccountName -ConfigurationName $func -Version "2.23" -AutoUpdate `
        -Location $FoggObject.Location -Force -ErrorAction 'Continue'

    if ($output -eq $null -or !$output.IsSuccessStatusCode)
    {
        $err = 'An unexpected error occurred, this usually happens when Internet connectivity is lost'

        if ($output -ne $null)
        {
            $err = $output.ReasonPhrase
        }

        throw "Failed to install the DSC Extension on VM $($VMName), and run script $($script):`n$($err)"
    }

    Write-Success "DSC Extension installed and script run`n"
}


function Set-FoggCustomConfig
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMName,

        [Parameter(Mandatory=$true)]
        $StorageAccount,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ContainerName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ScriptPath,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $OSType,

        [string]
        $Arguments = $null
    )

    # get the name of the file to run
    $fileName = Split-Path -Leaf -Path "$($ScriptPath)"
    $extName = Get-FoggCustomScriptExtensionName -OSType $OSType

    # parse the arguments - if we have any - into the write format
    if (!(Test-Empty $Arguments))
    {
        $Arguments = "`"" + (($Arguments -split '\|' | ForEach-Object { $_.Trim() }) -join "`" `"") + "`""
    }

    # grab the storage account name and key
    $saName = $StorageAccount.StorageAccountName
    $saKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $FoggObject.ResourceGroupName -Name $saName).Value[0]

    Write-Information "Installing Custom Script Extension on VM $($VMName), and running script $($fileName)"

    # execute the script on the VM
    switch ($OSType.ToLowerInvariant())
    {
        'windows'
            {
                if (Test-Empty $Arguments)
                {
                    $output = Set-AzureRmVMCustomScriptExtension -ResourceGroupName $FoggObject.ResourceGroupName -VMName $VMName `
                        -Location $FoggObject.Location -StorageAccountName $saName -StorageAccountKey $saKey -ContainerName $ContainerName `
                        -FileName $fileName -Name $extName -Run $fileName -ErrorAction 'Continue'
                }
                else
                {
                    $output = Set-AzureRmVMCustomScriptExtension -ResourceGroupName $FoggObject.ResourceGroupName -VMName $VMName `
                        -Location $FoggObject.Location -StorageAccountName $saName -StorageAccountKey $saKey -ContainerName $ContainerName `
                        -FileName $fileName -Name $extName -Run $fileName -Argument $Arguments -ErrorAction 'Continue'
                }
            }

        'linux'
            {
                $fileUri = "https://$($saName).blob.core.windows.net/$($ContainerName)/$($fileName)"
                $settings = @{ "fileUris" = @($fileUri); "commandToExecute" = "./$($fileName)"; }
                $protected = @{ "storageAccountName" = $saName; "storageAccountKey" = $saKey; }

                $splitExtName = ($extName -isplit '\.')
                $publisher = ($splitExtName[0..($splitExtName.Length - 2)] -join '.')
                $extType = ($splitExtName[$splitExtName.Length - 1])

                $output = Set-AzureRmVMExtension -ResourceGroupName $FoggObject.ResourceGroupName -VMName $VMName `
                    -Location $FoggObject.Location -Name $extName -Publisher $publisher -ExtensionType $extType `
                    -TypeHandlerVersion '2.0' -Settings $settings -ProtectedSettings $protected -ErrorAction 'Continue'
            }
    }

    # did it succeed or fail?
    if ($output -eq $null -or !$output.IsSuccessStatusCode)
    {
        $err = 'An unexpected error occurred, this usually happens when Internet connectivity is lost'

        if ($output -ne $null)
        {
            $err = $output.ReasonPhrase
        }

        throw "Failed to install the Custom Script Extension on VM $($VMName), and run script $($fileName):`n$($err)"
    }

    Write-Success "Custom Script Extension installed and script run`n"
}


function Get-FoggCustomScriptExtension
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $OSType
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $VMName = $VMName.ToLowerInvariant()

    try
    {
        switch ($OSType.ToLowerInvariant())
        {
            'windows'
                {
                    $ext = Get-AzureRmVMCustomScriptExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Name $Name
                }

            'linux'
                {
                    $ext = Get-AzureRmVMExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Name $Name
                }
        }

        if (!$?)
        {
            throw "Failed to make Azure call to retrieve Custom Script Extension $($Name) in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*')
        {
            $ext = $null
        }
        else
        {
            throw
        }
    }

    return $ext
}


function Remove-FoggCustomScriptExtension
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $OSType
    )

    $VMName = $VMName.ToLowerInvariant()
    $rg = $FoggObject.ResourceGroupName
    $name = Get-FoggCustomScriptExtensionName -OSType $OSType

    # only attempt to remove if the extension exists
    $ext = Get-FoggCustomScriptExtension -ResourceGroupName $rg -VMName $VMName -Name $name -OSType $OSType
    if ($ext -ne $null)
    {
        Write-Information "Uninstalling $($name) from $($VMName)"

        switch ($OSType.ToLowerInvariant())
        {
            'windows'
                {
                    Remove-AzureRmVMCustomScriptExtension -ResourceGroupName $rg -VMName $VMName -Name $name -Force | Out-Null
                }

            'linux'
                {
                    Remove-AzureRmVMExtension -ResourceGroupName $rg -VMName $VMName -Name $name -Force | Out-Null
                }
        }

        Start-Sleep -Seconds 10
        Write-Success "Extension uninstalled from $($VMName)`n"
    }
}


function Get-FoggCustomScriptExtensionName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $OSType
    )

    switch ($OSType.ToLowerInvariant())
    {
        'windows' { return 'Microsoft.Compute.CustomScriptExtension' }
        'linux' { return 'Microsoft.Azure.Extensions.customScript' }
    }
}


function Get-FoggStorageContext
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,
        
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $StorageAccount
    )

    # get storage account name and key
    $saName = $StorageAccount.StorageAccountName
    $saKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $FoggObject.ResourceGroupName -Name $saName).Value[0]

    # create new storage context
    $context = New-AzureStorageContext -StorageAccountName $saName -StorageAccountKey $saKey
    if (!$?)
    {
        throw "Failed to create Storage Context for Storage Account $($saName)"
    }

    return $context
}


function Get-FoggStorageContainer
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Context,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $Name = $Name.ToLowerInvariant()

    try
    {
        $container = Get-AzureStorageContainer -Context $Context -Name $Name
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve Storage Container $($Name)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*can not find*')
        {
            $container = $null
        }
        else
        {
            throw
        }
    }

    return $container
}


function New-FoggStorageContainer
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $StorageAccount,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $Name = $Name.ToLowerInvariant()

    # get storage account name
    $saName = $StorageAccount.StorageAccountName

    # create new storage context
    $context = Get-FoggStorageContext -FoggObject $FoggObject -StorageAccount $StorageAccount

    # check if container already exists
    $container = Get-FoggStorageContainer -Context $context -Name $Name
    if ($container -ine $null)
    {
        return $container
    }

    # create new storage container
    $container = New-AzureStorageContainer -Context $context -Name $Name
    if (!$?)
    {
        throw "Failed to create Storage Container for Storage Account $($saName)"
    }

    return $container
}

function Add-FirewallRules
{
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]
        $Subnets,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Role,

        [Parameter()]
        [hashtable]
        $Arguments,

        [Parameter()]
        $Firewall = $null,

        [Parameter()]
        [array]
        $Rules = @()
    )

    # if there are no firewall rules, return
    if ($Firewall -eq $null) {
        return $Rules
    }

    # deal with any default inbuilt firewall rules
    $portMap = Get-FirewallPortMap
    $keys = $Firewall.psobject.properties.name
    $regex = '^(?<name>.+?)(\|(?<direction>in|out|both)){0,1}$'

    if (Test-Empty $Rules) {
        $priority = 3500
    }
    else {
        $priority = 3750
    }

    foreach ($key in $keys)
    {
        # if key doesnt match regex, continue to next
        if ($key -inotmatch $regex) {
            continue
        }

        # set port name and direction (default to inbound)
        $portname = $Matches['name'].ToLowerInvariant()
        $direction = 'in'

        if (!(Test-Empty $Matches['direction'])) {
            $direction = $Matches['direction'].ToLowerInvariant()
        }

        # if custom in/outbound, or port doesnt exist, continue
        if ($portname -ieq 'inbound' -or $portname -ieq 'outbound' -or !$portMap.ContainsKey($portname)) {
            continue
        }

        # get port and name
        $port = $portMap.$portname
        $portname = $portname.ToUpperInvariant()

        # are we allowing or denying?
        $access = 'Allow'
        if ([bool]($Firewall.$key) -eq $false) {
            $access = 'Deny'
        }

        # add rule(s) for desired direction
        switch ($direction)
        {
            'in' {
                $Rules += (New-FoggNetworkSecurityGroupRule -Name "$($portname)_IN" -Priority $priority -Direction 'Inbound' `
                    -Source '*:*' -Destination "@{subnet}:$($port)" -Subnets $Subnets -Arguments $Arguments -Role $Role -Access $access)
            }

            'out' {
                $Rules += (New-FoggNetworkSecurityGroupRule -Name "$($portname)_OUT" -Priority $priority -Direction 'Outbound' `
                    -Source '@{subnet}:*' -Destination "*:$($port)" -Subnets $Subnets -Arguments $Arguments -Role $Role -Access $access)
            }

            'both' {
                $Rules += (New-FoggNetworkSecurityGroupRule -Name "$($portname)_IN" -Priority $priority -Direction 'Inbound' `
                    -Source '*:*' -Destination "@{subnet}:$($port)" -Subnets $Subnets -Arguments $Arguments -Role $Role -Access $access)

                $Rules += (New-FoggNetworkSecurityGroupRule -Name "$($portname)_OUT" -Priority $priority -Direction 'Outbound' `
                    -Source '@{subnet}:*' -Destination "*:$($port)" -Subnets $Subnets -Arguments $Arguments -Role $Role -Access $access)
            }
        }

        # increment priority
        $priority++
    }

    # assign the inbound rules
    if (!(Test-ArrayEmpty $Firewall.inbound))
    {
        $Firewall.inbound | ForEach-Object {
            $Rules += (New-FoggNetworkSecurityGroupRule -Name $_.name -Priority $_.priority -Direction 'Inbound' `
                -Source $_.source -Destination $_.destination -Subnets $Subnets -Arguments $Arguments -Role $Role -Access $_.access)
        }
    }

    # assign the outbound rules
    if (!(Test-ArrayEmpty $Firewall.outbound))
    {
        $Firewall.outbound | ForEach-Object {
            $Rules += (New-FoggNetworkSecurityGroupRule -Name $_.name -Priority $_.priority -Direction 'Outbound' `
                -Source $_.source -Destination $_.destination -Subnets $Subnets -Arguments $Arguments -Role $Role -Access $_.access)
        }
    }

    # return the rules
    return $Rules
}

function Add-FirewallWhitelistRules
{
    param (
        [Parameter(Mandatory=$true)]
        [hashtable]
        $Subnets,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Role,

        [Parameter()]
        [hashtable]
        $Arguments,

        [Parameter()]
        $Whitelist = $null,

        [Parameter()]
        [array]
        $Rules = @()
    )

    # if there are no whitelist rules, return
    if ($Whitelist -eq $null)
    {
        return $Rules
    }

    # get redis port
    $portMap = Get-FirewallPortMap
    $port = $portMap.redis

    # add whitelist rules to nsg firewall
    if (!(Test-ArrayEmpty $Whitelist))
    {
        $priority = 3500
        $names = $Whitelist.psobject.properties.name

        $names | ForEach-Object {
            $_rule = $Whitelist.$_

            $Rules += (New-FoggNetworkSecurityGroupRule -Name $_ -Priority $priority -Direction 'Inbound' `
                -Source "$($_rule):*" -Destination "@{subnet}:$($port)" -Subnets $Subnets -Arguments $Arguments -Role $Role -Access 'Allow')

            $priority++
        }
    }

    # return the rules
    return $Rules
}

function Get-FoggNetworkSecurityGroupRule
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $NetworkSecurityGroup
    )

    try
    {
        $rule = Get-AzureRmNetworkSecurityRuleConfig -Name $Name -NetworkSecurityGroup $NetworkSecurityGroup
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve network security group rule: $($Name)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*sequence contains no matching element*')
        {
            $rule = $null
        }
        else
        {
            throw
        }
    }

    return $rule
}

function New-FoggNetworkSecurityGroupRule
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [int]
        $Priority,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Direction,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Source,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Destination,

        [Parameter(Mandatory=$true)]
        [hashtable]
        $Subnets,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Role,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Access,

        [Parameter()]
        [hashtable]
        $Arguments,

        [Parameter()]
        [ValidateNotNullOrEmpty()]
        [string]
        $Protocol = 'Tcp'
    )

    # split down the source for IP and Port
    $source_split = ($Source -split ':')
    $sourcePrefix = (Get-Replace -Value $source_split[0] -Subnets $Subnets -Arguments $Arguments -Role $Role) -ireplace ' ', ''
    $sourcePort = Get-SubnetPort $source_split

    # split down the destination for IP and Port
    $dest_split = ($Destination -split ':')
    $destPrefix = (Get-Replace -Value $dest_split[0] -Subnets $Subnets -Arguments $Arguments -Role $Role) -ireplace ' ', ''
    $destPort = Get-SubnetPort $dest_split

    # if it's an ip-range, get the subnet
    if ($sourcePrefix.Contains('-'))
    {
        $s = $sourcePrefix -isplit '-'
        $sourcePrefix = Get-SubnetMask -Low $s[0] -High $s[1]
    }

    if ($destPrefix.Contains('-'))
    {
        $s = $destPrefix -isplit '-'
        $destPrefix = Get-SubnetMask -Low $s[0] -High $s[1]
    }

    Write-Information "Creating NSG Rule $($Name), from '$($sourcePrefix):$($sourcePort)' to '$($destPrefix):$($destPort)'"

    # create the rule
    $rule = New-AzureRmNetworkSecurityRuleConfig -Name $Name -Description $Name -Protocol $Protocol `
        -Access $Access -Direction $Direction -Priority $Priority -SourceAddressPrefix $sourcePrefix `
        -SourcePortRange $sourcePort -DestinationAddressPrefix $destPrefix -DestinationPortRange $destPort

    if (!$?)
    {
        throw "Failed to create NSG Rule $($Name)"
    }

    Write-Success "NSG Rule created`n"
    return $rule
}


function Add-FoggFirewallRuleToNSG
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Rule,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $NetworkSecurityGroup
    )

    $rg = $NetworkSecurityGroup.ResourceGroupName
    $name = $NetworkSecurityGroup.Name

    # ensure the nsg doesn't already have the rule
    if ((Get-FoggNetworkSecurityGroupRule -Name $Rule.Name -NetworkSecurityGroup $NetworkSecurityGroup) -ne $null)
    {
        return $NetworkSecurityGroup
    }

    Write-Information "Adding firewall rule $($Rule.Name) to Network Security Group $($name)"

    # attempt to add the rule to the NSG
    $output = Add-AzureRmNetworkSecurityRuleConfig -NetworkSecurityGroup $NetworkSecurityGroup -Name $Rule.Name `
        -Description $Rule.Description -Protocol $Rule.Protocol -Access $Rule.Access -Direction $Rule.Direction `
        -Priority $Rule.Priority -SourceAddressPrefix $Rule.SourceAddressPrefix -SourcePortRange $Rule.SourcePortRange `
        -DestinationAddressPrefix $Rule.DestinationAddressPrefix -DestinationPortRange $Rule.DestinationPortRange

    if (!$?)
    {
        throw "Failed to add firewall rule $($Rule.Name): $($output)"
    }

    # attempt to save the NSG
    $output = Set-AzureRmNetworkSecurityGroup -NetworkSecurityGroup $NetworkSecurityGroup
    if (!$?)
    {
        throw "Failed to update network security group with new firewall rule: $($output)"
    }

    # re-retrieve the NSG for updated object
    $NetworkSecurityGroup = Get-FoggNetworkSecurityGroup -ResourceGroupName $rg -Name $name
    if (!$?)
    {
        throw "Failed to re-get the network security group $($name)"
    }

    Write-Success "Firewall rule $($Rule.Name)`n"
    return $NetworkSecurityGroup
}


function Get-FoggNetworkSecurityGroup
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $Name = (Get-FoggNetworkSecurityGroupName $Name)

    try
    {
        $nsg = Get-AzureRmNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $Name
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve Network Security Group $($Name) in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*')
        {
            $nsg = $null
        }
        else
        {
            throw
        }
    }

    return $nsg
}


function New-FoggNetworkSecurityGroup
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,
    
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        $Rules
    )

    $Name = (Get-FoggNetworkSecurityGroupName $Name)

    Write-Information "Creating Network Security Group $($Name) in $($ResourceGroupName)"

    # check to see if the NSG already exists, if so use that one
    $nsg = Get-FoggNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $Name
    if ($nsg -ne $null)
    {
        Write-Notice "Using existing network security group for $($Name)`n"

        # check and assign new rules to NSG
        if (!(Test-ArrayEmpty $Rules))
        {
            $Rules | ForEach-Object {
                $nsg = Add-FoggFirewallRuleToNSG -Rule $_ -NetworkSecurityGroup $nsg
            }

            Write-Success "$($Name) firewall rules updated`n"
        }

        # return existing NSG
        return $nsg
    }

    $nsg = New-AzureRmNetworkSecurityGroup -ResourceGroupName $ResourceGroupName -Name $Name `
        -Location $Location -SecurityRules $Rules -Force

    if (!$?)
    {
        throw "Failed to create Network Security Group $($Name) in $($ResourceGroupName)"
    }

    Write-Success "Network security group $($Name) created in $($ResourceGroupName)`n"
    return $nsg
}


function Get-FoggVirtualNetwork
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $Name = (Get-FoggVirtualNetworkName $Name)

    try
    {
        $vnet = Get-AzureRmVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $Name
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve Virtual Network $($Name) in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*')
        {
            $vnet = $null
        }
        else
        {
            throw
        }
    }

    return $vnet
}


function New-FoggVirtualNetwork
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Address
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $Name = (Get-FoggVirtualNetworkName $Name)

    Write-Information "Creating virtual network $($Name) in $($ResourceGroupName)"

    # see if vnet already exists
    $vnet = Get-FoggVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $Name
    if ($vnet -ne $null)
    {
        Write-Notice "Using existing virtual network for $($name)`n"
        return $vnet
    }

    # else create a new one
    $vnet = New-AzureRmVirtualNetwork -Name $Name -ResourceGroupName $ResourceGroupName `
        -Location $Location -AddressPrefix $Address -Force

    if (!$?)
    {
        throw "Failed to create virtual network $($Name)"
    }

    Write-Success "Virtual network $($Name) created for $($Address)`n"
    return $vnet
}


function Add-FoggGatewaySubnetToVNet
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VNetName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Address
    )

    $vnet = Add-FoggSubnetToVNet -ResourceGroupName $ResourceGroupName -VNetName $VNetName -SubnetName 'GatewaySubnet' -Address $Address
    return $vnet
}

function Update-FoggSubnetOnVNet
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VNetName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $SubnetName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Address,

        [Parameter()]
        $NetworkSecurityGroup = $null
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $VNetName = (Get-FoggVirtualNetworkName $VNetName)
    $SubnetName = (Get-FoggSubnetName $SubnetName)
    $changes = $false

    # get the existing vnet and subnet
    $vnet = Get-FoggVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VNetName
    if ($vnet -eq $null)
    {
        return
    }

    $snet = ($vnet.Subnets | Where-Object { $_.Name -ieq $SubnetName -or $_.AddressPrefix -ieq $Address } | Select-Object -First 1)

    Write-Information "Updating Subnet $($SubnetName) on Virtual Network $($VNetName)"

    # has the address changed?
    if ($snet.AddressPrefix -ine $Address)  {
        Write-Information "> Updating address to $($Address)"
        $changes = $true
    }

    # has the NSG changed?
    $_nsgId = $null
    if ($snet.NetworkSecurityGroup -ne $null) {
        $_nsgId = $snet.NetworkSecurityGroup.Id
    }

    $_newNsgId = $null
    if ($NetworkSecurityGroup -ne $null) {
        $_newNsgId = $NetworkSecurityGroup.Id
    }

    if ($_nsgId -ine $_newNsgId) {
        if (Test-Empty $_newNsgId) {
            Write-Information "> Removing Network Security Group"
        }
        else {
            $nsgName = Get-NameFromAzureId $_newNsgId
            Write-Information "> Updating Network Security Group to $($nsgName)"
        }

        $changes = $true
    }

    # save possible changes
    if ($changes) {
        Set-AzureRmVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $vnet -AddressPrefix $Address `
            -NetworkSecurityGroup $NetworkSecurityGroup | Out-Null

        if (!$?) {
            throw "Failed to update the subnet $($SubnetName)"
        }
    }

    # attempt to save the vnet
    $output = Set-AzureRmVirtualNetwork -VirtualNetwork $VNet
    if (!$?)
    {
        throw "Failed to update the virtual network with updated subnet: $($output)"
    }

    # re-retrieve the vnet for updated object
    $VNet = Get-FoggVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VNetName
    if (!$?)
    {
        throw "Failed to re-get Virtual Network $($VNetName) in $($ResourceGroupName)"
    }

    # return vnet
    Write-Success "Virtual Subnet $($SubnetName) updated`n"
    return $VNet
}

function Add-FoggSubnetToVNet
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VNetName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $SubnetName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Address,

        [Parameter()]
        $NetworkSecurityGroup = $null
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $VNetName = (Get-FoggVirtualNetworkName $VNetName)
    $SubnetName = (Get-FoggSubnetName $SubnetName)

    Write-Information "Adding subnet $($SubnetName) to Virtual Network $($VNetName)"

    # get the vnet first
    $VNet = Get-FoggVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VNetName
    if (!$?) {
        throw "Failed to get Virtual Network $($VNetName) in $($ResourceGroupName)"
    }

    # ensure the vnet doesn't already have the subnet config (if so, update)
    $snet = ($VNet.Subnets | Where-Object { $_.Name -ieq $SubnetName -or $_.AddressPrefix -ieq $Address })

    if ((Get-Count $snet) -gt 0)
    {
        Write-Notice "Subnet $($SubnetName) already exists on Virtual Network`n"
        $VNet = Update-FoggSubnetOnVNet -ResourceGroupName $ResourceGroupName -VNetName $VNetName -SubnetName $SubnetName `
            -Address $Address -NetworkSecurityGroup $NetworkSecurityGroup
        return $VNet
    }

    # attempt to add subnet to the vnet
    if ($NetworkSecurityGroup -eq $null) {
        $output = Add-AzureRmVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $VNet `
            -AddressPrefix $Address
    }
    else {
        $output = Add-AzureRmVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $VNet `
            -AddressPrefix $Address -NetworkSecurityGroup $NetworkSecurityGroup
    }

    if (!$?) {
        throw "Failed to add subnet to virtual network: $($output)"
    }

    # attempt to save the vnet
    $output = Set-AzureRmVirtualNetwork -VirtualNetwork $VNet
    if (!$?) {
        throw "Failed to update the virtual network with new subnet: $($output)"
    }

    # re-retrieve the vnet for updated object
    $VNet = Get-FoggVirtualNetwork -ResourceGroupName $ResourceGroupName -Name $VNetName
    if (!$?) {
        throw "Failed to re-get Virtual Network $($VNetName) in $($ResourceGroupName)"
    }

    # return vnet
    Write-Success "Virtual Subnet $($SubnetName) added`n"
    return $VNet
}


function Get-FoggLocalNetworkGateway
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $Name = (Get-FoggLocalNetworkGatewayName $Name)

    try
    {
        $lng = Get-AzureRmLocalNetworkGateway -ResourceGroupName $ResourceGroupName -Name $Name
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve Local Network Gateway: $($Name) in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*')
        {
            $lng = $null
        }
        else
        {
            throw
        }
    }

    return $lng
}


function New-FoggLocalNetworkGateway
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $GatewayIPAddress,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $Address
    )

    $Name = (Get-FoggLocalNetworkGatewayName $Name)

    Write-Information "Creating local network gateway $($Name) in $($FoggObject.ResourceGroupName)"

    $lng = Get-FoggLocalNetworkGateway -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($lng -ne $null)
    {
        Write-Notice "Using existing local network gateway for $($Name)`n"
        return $lng
    }

    $lng = New-AzureRmLocalNetworkGateway -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location `
        -GatewayIpAddress $GatewayIPAddress -AddressPrefix $Address -Force
    if (!$?)
    {
        throw "Failed to create local network gateway $($Name)"
    }

    Write-Success "Local network gateway $($Name) created`n"
    return $lng
}


function Get-FoggVirtualNetworkGateway
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $Name = (Get-FoggVirtualNetworkGatewayName $Name)

    try
    {
        $gw = Get-AzureRmVirtualNetworkGateway -ResourceGroupName $ResourceGroupName -Name $Name
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve Virtual Network Gateway: $($Name) in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*')
        {
            $gw = $null
        }
        else
        {
            throw
        }
    }

    return $gw
}


function New-FoggVirtualNetworkGateway
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $VNet,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VpnType,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $GatewaySku,

        [string]
        $ClientAddressPool = $null,

        [string]
        $PublicCertificatePath = $null
    )

    $Name = (Get-FoggVirtualNetworkGatewayName $Name)

    Write-Information "Creating virtual network gateway $($Name) in $($FoggObject.ResourceGroupName)"

    # check to see if vnet gateway already exists
    $gw = Get-FoggVirtualNetworkGateway -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($gw -ne $null)
    {
        Write-Notice "Using existing virtual network gateway for $($Name)`n"
        return $gw
    }

    # Get the gateway subnet from the VNet
    $gatewaySubnetId = ($VNet.Subnets | Where-Object { $_.Name -ieq 'GatewaySubnet' }).Id
    if (Test-Empty $gatewaySubnetId)
    {
        throw "Virtual Network $($VNet.Name) has no GatewaySubnet"
    }

    # create dynamic public IP
    $pipId = (New-FoggPublicIpAddress -FoggObject $FoggObject -Name $Name -AllocationMethod 'Dynamic').Id

    # create the gateway config
    $config = New-AzureRmVirtualNetworkGatewayIpConfig -Name (Get-FoggVirtualNetworkGatewayIpConfigName $Name) -SubnetId $gatewaySubnetId -PublicIpAddressId $pipId
    if (!$?)
    {
        throw "Failed to create virtual network gateway config for $($Name)"
    }

    # create the vnet gateway
    if (!(Test-Empty $ClientAddressPool) -and !(Test-Empty $PublicCertificatePath))
    {
        # serialise the certificate
        $certName = Split-Path -Leaf -Path $PublicCertificatePath
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($PublicCertificatePath)
        $certBase64 = [System.Convert]::ToBase64String($cert.RawData)
        $p2sRootCert = New-AzureRmVpnClientRootCertificate -Name $certName -PublicCertData $certBase64

        # create the gateway
        $gw = New-AzureRmVirtualNetworkGateway -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name `
            -Location $FoggObject.Location -IpConfigurations $config -GatewayType Vpn -VpnType $VpnType -GatewaySku $GatewaySku `
            -EnableBgp $false -VpnClientAddressPool $ClientAddressPool -VpnClientRootCertificates $p2sRootCert -Force
    }
    else
    {
        $gw = New-AzureRmVirtualNetworkGateway -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name `
            -Location $FoggObject.Location -IpConfigurations $config -GatewayType Vpn -VpnType $VpnType `
            -GatewaySku $GatewaySku -Force
    }

    if (!$?)
    {
        throw "Failed to create virtual network gateway $($Name)"
    }

    Write-Success "Virtual network gateway $($Name) created`n"
    return $gw
}


function Get-FoggVirtualNetworkGatewayConnection
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $Name = (Get-FoggVirtualNetworkGatewayConnectionName $Name)

    try
    {
        $con = Get-AzureRmVirtualNetworkGatewayConnection -ResourceGroupName $ResourceGroupName -Name $Name
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve Virtual Network Gateway Connection: $($Name) in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*')
        {
            $con = $null
        }
        else
        {
            throw
        }
    }

    return $con
}


function New-FoggVirtualNetworkGatewayConnection
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $LocalNetworkGateway,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $VirtualNetworkGateway,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $SharedKey
    )

    $Name = (Get-FoggVirtualNetworkGatewayConnectionName $Name)

    Write-Information "Creating virtual network gateway connection $($Name) in $($FoggObject.ResourceGroupName)"

    # check to see if vnet connection already exists
    $con = Get-FoggVirtualNetworkGatewayConnection -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($con -ne $null)
    {
        Write-Notice "Using existing virtual network gateway connection for $($Name)`n"
        return $con
    }

    # create new connection
    $con = New-AzureRmVirtualNetworkGatewayConnection -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name `
        -Location $FoggObject.Location -VirtualNetworkGateway1 $VirtualNetworkGateway -LocalNetworkGateway2 $LocalNetworkGateway `
        -ConnectionType IPsec -RoutingWeight 10 -SharedKey $SharedKey -Force

    if (!$?)
    {
        throw "Failed to create virtual network gateway connection $($Name)"
    }

    Write-Success "Virtual network gateway connection $($Name) created`n"
    return $con
}


function Get-FoggAvailabilitySet
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $Name = (Get-FoggAvailabilitySetName $Name)

    try
    {
        $av = Get-AzureRmAvailabilitySet -ResourceGroupName $ResourceGroupName -Name $Name
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve Availability Set: $($Name) in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*')
        {
            $av = $null
        }
        else
        {
            throw
        }
    }

    return $av
}


function New-FoggAvailabilitySet
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [switch]
        $Managed
    )

    $Name = (Get-FoggAvailabilitySetName $Name)

    Write-Information "Creating availability set $($Name) in $($FoggObject.ResourceGroupName)"

    # check to see if av set already exists
    $av = Get-FoggAvailabilitySet -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($av -ne $null)
    {
        if (!$av.Managed -and $Managed)
        {
            Write-Host "Updating availability set $($Name) to be managed"
            Update-AzureRmAvailabilitySet -AvailabilitySet $av -Managed | Out-Null
            if (!$?)
            {
                throw "Failed to set availability set $($Name) to managed"
            }

            $av = Get-FoggAvailabilitySet -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
        }

        Write-Notice "Using existing availability set for $($Name)`n"
        return $av
    }

    # create new av set
    if ($Managed)
    {
        $av = New-AzureRmAvailabilitySet -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location -Managed -PlatformUpdateDomainCount 2 -PlatformFaultDomainCount 2
    }
    else
    {
        $av = New-AzureRmAvailabilitySet -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location -PlatformUpdateDomainCount 2 -PlatformFaultDomainCount 2
    }

    if (!$?)
    {
        throw "Failed to create availability set $($Name)"
    }

    Write-Success "Availability set $($Name) created`n"
    return $av
}


function Get-FoggLoadBalancer
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $Name = (Get-FoggLoadBalancerName $Name)

    try
    {
        $lb = Get-AzureRmLoadBalancer -Name $Name -ResourceGroupName $ResourceGroupName
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve Load Balancer $($Name) in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*')
        {
            $lb = $null
        }
        else
        {
            throw
        }
    }

    return $lb
}


function New-FoggLoadBalancer
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [hashtable]
        $Rules,

        [Parameter()]
        [string]
        $SubnetId,

        [Parameter()]
        [ValidateSet('None', 'Static', 'Dynamic')]
        [string]
        $PublicIpType
    )

    $Name = (Get-FoggLoadBalancerName $Name)
    $usePublicIp = ($PublicIpType -ine 'None')

    Write-Information "Creating load balancer $($Name) in $($FoggObject.ResourceGroupName)"

    # check public ip and subnet config
    if (!$usePublicIp -and (Test-Empty $SubnetId)) {
        throw "SubnetId required when creating a private internal load balancer: $($Name)"
    }

    # check to see if the load balancer already exists
    $lb = Get-FoggLoadBalancer -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($lb -ne $null) {
        Write-Notice "Using existing load balancer for $($Name)`n"
        return $lb
    }

    # create backend config
    $back = New-AzureRmLoadBalancerBackendAddressPoolConfig -Name (Get-FoggLoadBalancerBackendName $Name)
    if (!$?) {
        throw "Failed to create backend IP config for $($Name)"
    }

    # create the frontend configs for each frontend rule defined
    $_frontends = @{}

    foreach ($k in $Rules.Keys) {
        $_subname = "$($Name)-$($Rules[$k].Frontend.Name)"
        $_name = Get-FoggLoadBalancerFrontendName $_subname

        # only need to create frontend once
        if ($_frontends.ContainsKey($Rules[$k].Frontend.Name)) {
            continue
        }

        # create public address and front end
        Write-Information "> Creating Frontend: $($_name)"

        if ($usePublicIp) {
            $pip = New-FoggPublicIpAddress -FoggObject $FoggObject -Name $_subname -AllocationMethod $PublicIpType
            $front = New-AzureRmLoadBalancerFrontendIpConfig -Name $_name -PublicIpAddressId $pip.Id
            $Rules[$k].Frontend.PublicIP = $pip.IpAddress
        }
        else {
            $front = New-AzureRmLoadBalancerFrontendIpConfig -Name $_name -SubnetId $SubnetId
        }

        if (!$?) {
            throw "Failed to create frontend IP config for $($Name)"
        }

        # add to list
        $Rules[$k].Frontend.PrivateIP = $front.PrivateIpAddress
        $_frontends.Add($Rules[$k].Frontend.Name, $front)
    }

    # create rules and probes
    $_rules = @()
    $_probes = @()

    foreach ($k in $Rules.Keys) {
        # do we need a default probe?
        if ($Rules[$k].Probe -eq $null) {
            $Rules[$k].Probe = @{
                'Port' = $Rules[$k].Port;
                'Interval' = 5;
                'Threshold' = 2;
            }
        }

        # create probe
        $_probeName = (Get-FoggLoadBalancerProbeName "$($Name)-$($k)")
        Write-Information "> Creating Probe: $($_probeName)"

        $_probe = New-AzureRmLoadBalancerProbeConfig -Name $_probeName -Protocol Tcp -Port $Rules[$k].Probe.Port `
            -IntervalInSeconds $Rules[$k].Probe.Interval -ProbeCount $Rules[$k].Probe.Threshold

        if (!$?) {
            throw "Failed to create frontend Health Probe for $($Name) on Rule $($k)"
        }

        # create rule
        $_ruleName = (Get-FoggLoadBalancerRuleName "$($Name)-$($k)")
        $_float = [bool]($Rules[$k].Floating)
        Write-Information "> Creating Rule: $($_ruleName)"

        $_rule = New-AzureRmLoadBalancerRuleConfig -Name $_ruleName -FrontendIpConfiguration $_frontends[$Rules[$k].Frontend.Name] `
            -BackendAddressPool $back -Probe $_probe -Protocol Tcp -FrontendPort $Rules[$k].Port -BackendPort $Rules[$k].Port `
            -IdleTimeoutInMinutes $Rules[$k].Timeout -EnableFloatingIP:$_float

        if (!$?) {
            throw "Failed to create Rule for $($Name)"
        }

        # add to rule/probe collections
        $_probes += $_probe
        $_rules += $_rule
    }

    # create the load balancer
    $lb = New-AzureRmLoadBalancer -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location `
        -FrontendIpConfiguration @($_frontends.Values) -BackendAddressPool $back -LoadBalancingRule $_rules -Probe $_probes -Sku Standard

    if (!$?) {
        throw "Failed to create $($Name) load balancer"
    }

    # return
    Write-Success "Load balancer $($Name) created`n"
    return $lb
}


function Get-FoggVM
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [int]
        $Index,

        [switch]
        $Status,

        [switch]
        $RealName
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)

    if ($RealName)
    {
        $VMName = $Name
    }
    else
    {
        $VMName = (Get-FoggVMName $Name $Index)
    }

    try
    {
        $vm = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $VMName -Status:$Status
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve VM $($VMName) in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*')
        {
            $vm = $null
        }
        else
        {
            throw
        }
    }

    return $vm
}


function Get-FoggVMs
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName
    )

    $ResourceGroupName = (Get-FoggResourceGroup $ResourceGroupName)

    try
    {
        $vms = Get-AzureRmVM -ResourceGroupName $ResourceGroupName
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve VMs in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*')
        {
            $vms = $null
        }
        else
        {
            throw
        }
    }

    return $vms
}


function New-FoggVM
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [int]
        $Index,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [pscredential]
        $VMCredentials,

        [Parameter()]
        $StorageAccount,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $SubnetId,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $OS,

        [Parameter()]
        $Vhd,

        [Parameter()]
        $Image,

        [Parameter()]
        $AvailabilitySet = $null,

        [Parameter()]
        $Drives,

        [Parameter()]
        [ValidateSet('None', 'Static', 'Dynamic')]
        [string]
        $PublicIpType,

        [Parameter()]
        [string]
        $Zone = $null,

        [switch]
        $Managed
    )

    $Name = $Name.ToLowerInvariant()
    $VMName = (Get-FoggVMName $Name $Index)
    $usePublicIp = ($PublicIpType -ine 'None')

    Write-Information "Creating VM $($VMName) in $($FoggObject.ResourceGroupName)$(if (!(Test-Empty $Zone)) { ", in Zone $($Zone)" })"

    # check to see if the VM already exists
    $vm = Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Index $Index
    if ($vm -ne $null)
    {
        Write-Notice "Updating existing VM for $($VMName)`n"
        $vm = Update-FoggVM -FoggObject $FoggObject -Name $Name -Index $Index -SubnetId $SubnetId -Zone $Zone `
            -OS $OS -Drives $Drives -StorageAccount $StorageAccount -PublicIpType $PublicIpType -Managed:$Managed
        return $vm
    }

    # set basic "has"/"is" variables
    $hasVhd = ($Vhd -ne $null)
    $hasImage = ($Image -ne $null)

    # disk/os names
    $DiskName = "$($VMName)-osdisk1"

    # only need to generate disk vhd uri if using un-managed disks
    if (!$Managed)
    {
        $ContainerName = 'vhds'
        $BlobName = "$($ContainerName)/$($DiskName).vhd"
        $SAEndpoint = $StorageAccount.PrimaryEndpoints.Blob.ToString()
        $OSDiskUri = "$($SAEndpoint)$($BlobName)"
    }

    if ($hasVhd)
    {
        $VhdSA = Get-FoggStorageAccount -ResourceGroupName $FoggObject.ResourceGroupName -StorageAccountName $Vhd.sa.name
        $VhdSAEndpoint = $VhdSA.PrimaryEndpoints.Blob.ToString()
        $VhdName = Get-FoggVhdName -Name $Vhd.name
        $VhdUri = "$($VhdSAEndpoint)$($ContainerName)/$($VhdName)"
    }

    # create public IP address
    if ($usePublicIp)
    {
        $pipId = (New-FoggPublicIpAddress -FoggObject $FoggObject -Name $VMName -AllocationMethod $PublicIpType -Zone $Zone).Id
    }

    # create the NIC
    $nic = New-FoggNetworkInterface -FoggObject $FoggObject -Name $VMName -SubnetId $SubnetId `
        -PublicIpId $pipId -NetworkSecurityGroupId $FoggObject.NsgMap[$Name]

    # setup initial VM config
    if ($AvailabilitySet -eq $null) {
        if (!(Test-Empty $Zone)) {
            $VM = New-AzureRmVMConfig -VMName $VMName -VMSize $OS.size -Zone $Zone
        }
        else {
            $VM = New-AzureRmVMConfig -VMName $VMName -VMSize $OS.size
        }
    }
    else {
        $VM = New-AzureRmVMConfig -VMName $VMName -VMSize $OS.size -AvailabilitySetId $AvailabilitySet.Id
    }

    if (!$?)
    {
        throw "Failed to create the VM Config for $($VMName)"
    }

    # assign the source image to VM
    if (!$hasVhd)
    {
        if ($hasImage)
        {
            Write-Information "Using Image: $($Image.name)"

            $rg = $Image.rg
            if (Test-Empty $rg)
            {
                $rg = $FoggObject.ResourceGroupName
            }

            $imageId = (Get-AzureRmImage -ResourceGroupName $rg -ImageName $Image.name).Id
            $VM = Set-AzureRmVMSourceImage -VM $VM -Id $imageId
        }
        else
        {
            Write-Information "Using Published Image: $($OS.offer)"
            $VM = Set-AzureRmVMSourceImage -VM $VM -PublisherName $OS.publisher -Offer $OS.offer -Skus $OS.skus -Version 'latest'
        }
    }
    else
    {
        Write-Information "Using Vhd: $($VhdName)"
    }

    Write-Information "Setting OS: $($OS.type)"

    switch ($OS.type.ToLowerInvariant())
    {
        'windows'
            {
                if ($hasVhd)
                {
                    Write-Information "=> Setting VM OS Disk"
                    $VM = Set-AzureRmVMOSDisk -VM $VM -Name $DiskName -VhdUri $VhdUri -CreateOption Attach -Windows
                }
                else
                {
                    Write-Information "=> Setting VM OS"
                    $VM = Set-AzureRmVMOperatingSystem -VM $VM -Windows -ComputerName $VMName -Credential $VMCredentials -ProvisionVMAgent

                    Write-Information "=> Setting VM OS Disk"
                    if ($Managed)
                    {
                        $VM = Set-AzureRmVMOSDisk -VM $VM -Windows -StorageAccountType PremiumLRS -DiskSizeInGB 128 -CreateOption FromImage -Caching ReadWrite -Name $DiskName
                    }
                    else
                    {
                        $VM = Set-AzureRmVMOSDisk -VM $VM -Windows -Name $DiskName -VhdUri $OSDiskUri -CreateOption FromImage
                    }
                }
            }

        'linux'
            {
                if ($hasVhd)
                {
                    Write-Information "=> Setting VM OS Disk"
                    $VM = Set-AzureRmVMOSDisk -VM $VM -Name $DiskName -VhdUri $VhdUri -CreateOption Attach -Linux
                }
                else
                {
                    Write-Information "=> Setting VM OS"
                    $VM = Set-AzureRmVMOperatingSystem -VM $VM -Linux -ComputerName $VMName -Credential $VMCredentials

                    Write-Information "=> Setting VM OS Disk"
                    if ($Managed)
                    {
                        $VM = Set-AzureRmVMOSDisk -VM $VM -Linux -StorageAccountType PremiumLRS -DiskSizeInGB 128 -CreateOption FromImage -Caching ReadWrite -Name $DiskName
                    }
                    else
                    {
                        $VM = Set-AzureRmVMOSDisk -VM $VM -Linux -Name $DiskName -VhdUri $OSDiskUri -CreateOption FromImage
                    }
                }
            }
    }

    $VM = Add-AzureRmVMNetworkInterface -VM $VM -Id $nic.Id

    if (!$?)
    {
        throw "Failed to assign the OS and Source Image Disks for $($VMName)"
    }

    # create any additional drives
    $VM = Add-FoggDataDisk -FoggObject $FoggObject -VMName $VMName -VM $VM -StorageAccount $StorageAccount -Drives $Drives -Zone $Zone -Managed:$Managed

    Write-Success "VM $($VMName) prepared`n"
    return $VM
}


function Update-FoggVM
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [int]
        $Index,

        [Parameter()]
        $StorageAccount,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $SubnetId,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $OS,

        [Parameter()]
        $Drives,

        [Parameter()]
        [ValidateSet('None', 'Static', 'Dynamic')]
        [string]
        $PublicIpType,

        [Parameter()]
        [string]
        $Zone = $null,

        [switch]
        $Managed
    )

    $Name = $Name.ToLowerInvariant()
    $VMName = (Get-FoggVMName $Name $Index)
    $usePublicIp = ($PublicIpType -ine 'None')

    # variables
    $nicName = (Get-FoggNetworkInterfaceName $VMName)

    # create public IP address if one doesn't already exist
    if ($usePublicIp)
    {
        $pipId = (New-FoggPublicIpAddress -FoggObject $FoggObject -Name $VMName -AllocationMethod $PublicIpType -Zone $Zone).Id
    }

    # update the NIC, assigning the Public IP and NSG if we have one
    New-FoggNetworkInterface -FoggObject $FoggObject -Name $nicName -SubnetId $SubnetId `
        -PublicIpId $pipId -NetworkSecurityGroupId $FoggObject.NsgMap[$Name] | Out-Null

    # update the VM size if it's different
    $vm = Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $VMName -Index $Index -RealName
    if ($vm.HardwareProfile.VmSize -ine $OS.size)
    {
        Write-Information "Updating VM size to $($OS.size)"
        Stop-FoggVM -FoggObject $FoggObject -Name $VMName -StayProvisioned

        $vm.HardwareProfile.VmSize = $OS.size
        Update-AzureRmVM -ResourceGroupName $FoggObject.ResourceGroupName -VM $vm | Out-Null
        
        Write-Success "Size of VM updated`n"
    }

    # re-retrieve the updated VM
    $vm = Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $VMName -Index $Index -RealName

    # update the VM with any additional drives not yet assigned
    $vm = Add-FoggDataDisk -FoggObject $FoggObject -VMName $VMName -VM $vm -StorageAccount $StorageAccount -Drives $Drives -Zone $Zone -Managed:$Managed

    # return the updated VM
    return $vm
}


function Save-FoggVM
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $VM,

        $LoadBalancer = $null
    )

    # do we have a zone?
    $zone = [string]($VM.Zones | Select-Object -First 1)

    # first, ensure this VM doesn't alredy exist in Azure (avoiding re-redeploying)
    if ((Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $VM.Name -Index 0 -RealName) -eq $null)
    {
        Write-Information "`nDeploying new VM '$($VM.Name)'$(if (!(Test-Empty $zone)) { ", in Zone $($zone)" })"

        # create VM as it doesn't exist
        if (!(Test-Empty $zone)) {
            $output = New-AzureRmVM -ResourceGroupName $FoggObject.ResourceGroupName -Location $FoggObject.Location -VM $VM -Zone $zone
        }
        else {
            $output = New-AzureRmVM -ResourceGroupName $FoggObject.ResourceGroupName -Location $FoggObject.Location -VM $VM
        }

        if (!$?) {
            throw "Failed to create VM $($VM.Name): $($output)"
        }
    }
    else
    {
        Write-Information "`nUpdating existing VM '$($VM.Name)'"

        $output = Update-AzureRmVM -ResourceGroupName $FoggObject.ResourceGroupName -VM $VM
        if (!$?) {
            throw "Failed to update VM $($VM.Name): $($output)"
        }

        Start-FoggVM -FoggObject $FoggObject -Name $VM.Name
    }

    Write-Success "Deployed $($VM.Name)`n"

    # check if we need to assign a load balancer
    if (!(Test-Empty $LoadBalancer))
    {
        Write-Information "Assigning VM $($VM.Name) to Load Balancer $($LoadBalancer.Name)"

        $nic = Get-FoggNetworkInterface -ResourceGroupName $FoggObject.ResourceGroupName -Name $VM.Name
        if (!$? -or $nic -eq $null) {
            throw "Failed to retrieve Network Interface for the VM $($VM.Name)"
        }

        $back = Get-AzureRmLoadBalancerBackendAddressPoolConfig -Name (Get-FoggLoadBalancerBackendName $LoadBalancer.Name) -LoadBalancer $LoadBalancer
        if (!$? -or $back -eq $null) {
            throw "Failed to retrieve back end pool for Load Balancer: $($LoadBalancer.Name)"
        }

        $nic.IpConfigurations[0].LoadBalancerBackendAddressPools = $back
        $output = Set-AzureRmNetworkInterface -NetworkInterface $nic

        if (!$?) {
            throw "Failed to save $($nic.Name) against Load Balancer $($LoadBalancer.Name): $output"
        }

        Write-Success "Assigned Load Balancer $($LoadBalancer.Name) to VM $($VM.Name)`n"
    }
}


function Stop-FoggVM
{
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [switch]
        $StayProvisioned
    )

    $Name = $Name.ToLowerInvariant()

    # ensure the VM exists
    $vm = Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Index 0 -Status -RealName
    if ($vm -eq $null)
    {
        throw "The VM '$($Name)' does not exist to stop"
    }

    $status = ($vm.Statuses.Code | Where-Object { $_ -ilike 'PowerState*' } | Select-Object -First 1)

    if ($status -ieq 'PowerState/running')
    {
        Write-Information "Stopping the VM '$($Name)'"

        if (!$StayProvisioned)
        {
            Write-Warning 'The VM is being deallocated - IP addresses and other information could be lost'
        }

        $output = Stop-AzureRmVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -StayProvisioned:$StayProvisioned -Force
        if (!$?)
        {
            throw "Failed to stop the VM '$($Name)': $($output)"
        }

        Write-Success "VM '$($Name)' stopped"
    }
    else
    {
        Write-Details "The VM is already stopped"
    }
}


function Start-FoggVM
{
    param(
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $Name = $Name.ToLowerInvariant()

    # ensure the VM exists
    $vm = Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Index 0 -Status -RealName
    if ($vm -eq $null)
    {
        throw "The VM $($Name) does not exist to start"
    }

    $status = ($vm.Statuses.Code | Where-Object { $_ -ilike 'PowerState*' } | Select-Object -First 1)

    if ($status -ine 'PowerState/running')
    {
        Write-Information "Starting the VM '$($Name)'"

        $output = Start-AzureRmVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
        if (!$?)
        {
            throw "Failed to start the VM '$($Name)': $($output)"
        }

        Write-Success "VM '$($Name)' started"
    }
    else
    {
        Write-Details "The VM is already running"
    }
}


function Add-FoggDataDisk
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $VM,

        [Parameter()]
        $StorageAccount,

        [Parameter()]
        $Drives,

        [Parameter()]
        [string]
        $Zone = $null,

        [switch]
        $Managed
    )

    Write-Information "Setting up additional data disks"

    # if no drives passed, just return the VM
    if (Test-ArrayEmpty $Drives)
    {
        Write-Host 'No additional data disks to create passed'
        return $VM
    }

    # get the storage profile of the VM
    $storage = $VM.StorageProfile

    # get existing disks
    if ($storage -ne $null -and ($storage.DataDisks | Measure-Object).Count -gt 0)
    {
        $diskNames = $storage.DataDisks.Name
        Write-Notice "Existing data disks found on $($VMName):`n> $($diskNames -join "`n> ")"
    }

    # set the storage account endpoint
    if (!$Managed)
    {
        $SAEndpoint = $StorageAccount.PrimaryEndpoints.Blob.ToString()
    }

    # loop through each of the drives, creating new ones
    $Drives | ForEach-Object {
        # generate the disk name and blob URIs
        $diskName = "$($VMName)-datadisk$($_.lun)"

        if (!$Managed)
        {
            $blobName = "vhds/$($diskName).vhd"
            $diskUri = "$($SAEndpoint)$($blobName)"
        }

        # if the profile doesn't contain the diskname, create the disk
        if ($diskNames -inotcontains $diskName)
        {
            # check the LUN doesn't already exist
            if ($storage.DataDisks.Lun -icontains $_.lun)
            {
                throw "The VM '$($VMName)' already has a data disk with a LUN of $($_.lun)"
            }

            # create new disk
            Write-Details "`nCreating new disk: $($diskName), for drive $($_.name) ($($_.letter):)$(if (!(Test-Empty $Zone)) { ", in Zone $($Zone)" })"

            if ($Managed)
            {
                if (!(Test-Empty $Zone)) {
                    $dc = New-AzureRmDiskConfig -Location $FoggObject.Location -DiskSizeGB $_.size -CreateOption Empty -Zone $Zone
                }
                else {
                    $dc = New-AzureRmDiskConfig -Location $FoggObject.Location -DiskSizeGB $_.size -CreateOption Empty
                }

                $d = New-AzureRmDisk -ResourceGroupName $FoggObject.ResourceGroupName -DiskName $diskName -Disk $dc
                $VM = Add-AzureRmVMDataDisk -VM $VM -Name $diskName -Lun $_.Lun -Caching ReadOnly -CreateOption Attach `
                    -DiskSizeInGB $_.size -ManagedDiskId $d.Id
            }
            else
            {
                $VM = Add-AzureRmVMDataDisk -VM $VM -Name $diskName -VhdUri $diskUri -Lun $_.lun -Caching ReadOnly `
                    -DiskSizeInGB $_.size -CreateOption Empty
            }

            Write-Success 'New disk created'
        }

        # if a match is found, attempt to update the disk
        else
        {
            Write-Details "`n$($diskName) already exists, checking if it needs updating"

            # check if the disk needs any updates
            $disk = ($storage.DataDisks | Where-Object { $_.Name -ieq $diskName } | Select-Object -First 1)

            # get new size/caching values
            $size = $_.size
            $caching = $_.caching
            if ([string]::IsNullOrWhiteSpace($caching))
            {
                $caching = 'ReadOnly'
            }

            # if the new size is less than the current one, error
            if ($disk.DiskSizeGB -gt $size)
            {
                throw "Decreasing data disk size from $($disk.DiskSizeGB)GB to $($size)GB is not supported for drive $($_.name) ($($_.letter):)"
            }

            # do we need to update the disk?
            if ($disk.DiskSizeGB -ne $size -or $disk.Caching -ine $caching)
            {
                Write-Information "Updating the disk to $($size)GB and caching of $($caching)"

                Stop-FoggVM -FoggObject $FoggObject -Name $VM.Name
                
                if ($Managed)
                {
                    $duc = New-AzureRmDiskUpdateConfig -DiskSizeGB $size
                    Update-AzureRmDisk -ResourceGroupName $FoggObject.ResourceGroupName -DiskName $diskName -DiskUpdate $duc | Out-Null
                    $VM = Set-AzureRmVMDataDisk -VM $VM -Lun $_.Lun -Caching $caching -DiskSizeInGB $size
                }
                else
                {
                    $VM = Set-AzureRmVMDataDisk -VM $VM -Lun $_.lun -Caching $caching -DiskSizeInGB $size
                }

                Write-Information 'Disk set to be updated'
            }
            else
            {
                Write-Success 'Disk is already up-to-date'
            }
        }
    }

    # return the updated VM
    return $VM
}


function Get-FoggNetworkInterface
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $Name = (Get-FoggNetworkInterfaceName $Name)

    try
    {
        $nic = Get-AzureRmNetworkInterface -ResourceGroupName $ResourceGroupName -Name $Name
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve Network Interface: $($Name) in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*')
        {
            $nic = $null
        }
        else
        {
            throw
        }
    }

    return $nic
}


function New-FoggNetworkInterface
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $SubnetId,

        [string]
        $PublicIpId,

        [string]
        $NetworkSecurityGroupId
    )

    $Name = (Get-FoggNetworkInterfaceName $Name)

    Write-Information "Creating Network Interface $($Name) in $($FoggObject.ResourceGroupName)"

    # check to see if the NIC already exists
    $nic = Get-FoggNetworkInterface -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($nic -ne $null)
    {
        Write-Notice "Using existing network interface for $($Name)`n"
        $nic = Update-FoggNetworkInterface -FoggObject $FoggObject -Name $Name -PublicIpId $PublicIpId -NetworkSecurityGroupId $NetworkSecurityGroupId
        return $nic
    }

    $nic = New-AzureRmNetworkInterface -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location `
        -SubnetId $SubnetId -PublicIpAddressId $PublicIpId -NetworkSecurityGroupId $NetworkSecurityGroupId

    if (!$?)
    {
        throw "Failed to create Network Interface $($Name)"
    }

    Write-Success "Network Interface $($Name) created`n"
    return $nic
}

function Update-FoggNetworkInterface
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [string]
        $PublicIpId,

        [string]
        $NetworkSecurityGroupId
    )

    $Name = (Get-FoggNetworkInterfaceName $Name)
    $changes = $false

    # get the existing NIC
    $nic = Get-FoggNetworkInterface -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($nic -eq $null)
    {
        return $null
    }

    Write-Information "Updating Network Interface $($Name) in resource group $($FoggObject.ResourceGroupName)"

    # assign Public IP if one doesn't already exist, is different, or needs to be removed
    $_pipId = $null
    if ($nic.IpConfigurations[0].PublicIpAddress -ne $null) {
        $_pipId = $nic.IpConfigurations[0].PublicIpAddress.Id
    }

    if ($_pipId -ine $PublicIpId)
    {
        $pip = $null

        if (Test-Empty $PublicIpId) {
            Write-Information "> Removing Public IP"
        }
        else {
            $pipName = Get-NameFromAzureId $PublicIpId
            $pip = Get-FoggPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName -Name $pipName
            Write-Information "> Updating Public IP to $($pipName)"
        }

        $nic.IpConfigurations[0].PublicIpAddress = $pip
        $changes = $true
    }

    # assign NSG if one doesn't already exist, is different, or needs removing
    $_nsgId = $null
    if ($nic.NetworkSecurityGroup -ne $null) {
        $_nsgId = $nic.NetworkSecurityGroup.Id
    }

    if ($_nsgId -ine $NetworkSecurityGroupId)
    {
        $nsg = $null

        if (Test-Empty $NetworkSecurityGroupId) {
            Write-Information "> Removing Network Security Group"
        }
        else {
            $nsgName = Get-NameFromAzureId $NetworkSecurityGroupId
            $nsg = Get-FoggNetworkSecurityGroup -ResourceGroupName $FoggObject.ResourceGroupName -Name $nsgName
            Write-Information "> Updating Network Security Group to $($nsgName)"
        }

        $nic.NetworkSecurityGroup = $nsg
        $changes = $true
    }

    # save possible changes
    if ($changes) {
        Set-AzureRmNetworkInterface -NetworkInterface $nic | Out-Null
        if (!$?) {
            throw "Failed to update the NIC $($Name)"
        }
    }

    Write-Success "Network Interface $($Name) updated"

    # return the updated NIC
    return (Get-FoggNetworkInterface -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name)
}


function Get-FoggPublicIpAddresses
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)

    try
    {
        $pips = Get-AzureRmPublicIpAddress -ResourceGroupName $ResourceGroupName
        if (!$?) {
            throw "Failed to make Azure call to retrieve Public IP Addresses in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*') {
            $pips = $null
        }
        else {
            throw
        }
    }

    return $pips
}

function Get-FoggPublicIpAddress
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $ResourceGroupName = (Get-FoggResourceGroupName $ResourceGroupName)
    $PipName = (Get-FoggPublicIpName $Name)

    try
    {
        $pip = Get-AzureRmPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $PipName
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve Public IP Address: $($PipName) in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*')
        {
            $pip = $null
        }
        else
        {
            throw
        }
    }

    return $pip
}

function New-FoggPublicIpAddress
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateSet('Static', 'Dynamic')]
        [string]
        $AllocationMethod,

        [Parameter()]
        [string]
        $Zone = $null
    )

    $Name = (Get-FoggPublicIpName $Name)

    Write-Information "Creating $($AllocationMethod) Public IP Address $($Name)$(if (!(Test-Empty $Zone)) { ", in Zone $($Zone)" })"

    # check to see if the IP already exists
    $pip = Get-FoggPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($pip -ne $null) {
        Write-Notice "Using existing Public IP Address for $($Name)`n"
        $pip = Update-FoggPublicIpAddress -FoggObject $FoggObject -Name $Name -AllocationMethod $AllocationMethod
        return $pip
    }

    $sku = 'Standard'
    if ($AllocationMethod -ieq 'dynamic') {
        $sku = 'Basic'
    }

    if (!(Test-Empty $Zone)) {
        $pip = New-AzureRmPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location `
            -AllocationMethod $AllocationMethod -Zone $Zone -Force -Sku $sku
    }
    else {
        $pip = New-AzureRmPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location `
            -AllocationMethod $AllocationMethod -Force -Sku $sku
    }

    if (!$?) {
        throw "Failed to create Public IP Address $($Name)"
    }

    Write-Success "Public IP Address $($Name) created`n"
    return $pip
}

function Update-FoggPublicIpAddress
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateSet('Static', 'Dynamic')]
        [string]
        $AllocationMethod
    )

    $Name = (Get-FoggPublicIpName $Name)
    $changes = $false

    # get the existing public ip
    $pip = Get-FoggPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($pip -eq $null) {
        return
    }

    Write-Information "Updating Public IP $($Name) in resource group $($FoggObject.ResourceGroupName)"

    # update the allocation method
    if ($pip.PublicIpAllocationMethod -ine $AllocationMethod) {
        Write-Information "Updating $($Name) to $($AllocationMethod) allocation"
        $pip.PublicIpAllocationMethod = $AllocationMethod
        $changes = $true
    }

    # save changes
    if ($changes) {
        Set-AzureRmPublicIpAddress -PublicIpAddress $pip | Out-Null
    }

    Write-Success "Public IP $($Name) updated"

    # return the updated ip
    return (Get-FoggPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name)
}

function Get-FoggVMSizes
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location
    )

    return Get-AzureRmVMSize -Location $Location
}


function Get-FoggVMUsageDetails
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location
    )

    return Get-AzureRmVMUsage -Location $Location
}


function Test-FoggResourceGroupName
{
    param (
        [string]
        $ResourceGroupName,

        [switch]
        $Optional
    )

    if ($Optional -and (Test-Empty $ResourceGroupName))
    {
        return
    }

    $length = $ResourceGroupName.Length
    if ($length -lt 1 -or $length -gt 90)
    {
        throw "Resource Group Name '$($ResourceGroupName)' must be between 1-90 characters"
    }

    $regex = '^[a-zA-Z0-9\._\-\(\)]*[a-zA-Z0-9_\-\(\)]$'
    if ($ResourceGroupName -notmatch $regex)
    {
        throw "Resource Group Name '$($ResourceGroupName)' can only contain alphanumeric, hyphen, underscore, period and parenthesis characters, and cannot end with a period: '$($regex)'"
    }
}


function Test-FoggVMUsername
{
    param (
        [string]
        $Username
    )

    if (Test-Empty $Username)
    {
        throw "No VM Admin username supplied"
    }

    $length = $Username.Length
    if ($length -lt 1 -or $length -gt 15)
    {
        throw "VM Admin username must be between 1-15 characters"
    }

    $regex = '[\\\/\"\[\]\:\|\<\>\+=;,\?\*@]+'
    if ($Username -match $regex -or $Username.EndsWith('.'))
    {
        throw "VM Admin username cannot end with a period or contain any of the following: \/`"[]:|<>+=;,?*@"
    }

    $reserved = @(
        'administrator', 'admin', 'user', 'user1', 'test', 'user2', 'test1', 'user3',
        'admin1', '1', '123', 'a', 'actuser', 'adm', 'admin2', 'aspnet', 'backup', 'console',
        'david', 'guest', 'john', 'owner', 'root', 'server', 'sql', 'support', 'support_388945a0',
        'sys', 'test2', 'test3', 'user4', 'user5')

    if ($reserved -icontains $Username)
    {
        throw "VM Admin username '$($Username)' cannot be used as it is a reserved word"
    }
}


function Test-FoggVMPassword
{
    param (
        [securestring]
        $Password
    )

    if ($Password -eq $null)
    {
        throw 'No VM Admin password supplied'
    }

    if ($Password.Length -lt 12 -or $Password.Length -gt 123)
    {
        throw 'VM Admin password must be between 12-123 characters'
    }
}


function Test-FoggVMName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $OSType,

        [string]
        $Name
    )

    if (Test-Empty $Name)
    {
        throw "No VM name supplied"
    }

    $maxLength = 15
    switch ($OSType.ToLowerInvariant())
    {
        'windows'
            {
                $maxLength = 15
            }
        
        'linux'
            {
                $maxLength = 64
            }
        
        default
            {
                throw "Unrecognised OS type: $($OSType)"
            }
    }

    $length = $Name.Length
    if ($length -lt 1 -or $length -gt $maxLength)
    {
        throw "VM name '$($Name)' must be between 1-$($maxLength) characters"
    }

    $regex = '^[a-zA-Z0-9\-]+$'
    if ($Name -notmatch $regex)
    {
        throw "VM name '$($Name)' can only contain alphanumeric and hyphen characters"
    }
}

function Test-FoggRedisCacheName
{
    param (
        [string]
        $Name
    )

    if (Test-Empty $Name)
    {
        throw "No Redis Cache name supplied"
    }

    $length = $Name.Length
    if ($length -lt 1 -or $length -gt 63)
    {
        throw "Redis Cache name '$($Name)' must be between 1-63 characters"
    }

    $regex = '^[a-z0-9\-]+$'
    if ($Name -notmatch $regex)
    {
        throw "Redis Cache name '$($Name)' can only contain lowercase alphanumeric and hyphen characters"
    }
}

function Test-FoggStorageAccountName
{
    param (
        [string]
        $Name
    )

    if (Test-Empty $Name)
    {
        throw "No Storage Account name supplied"
    }

    $length = $Name.Length
    if ($length -lt 3 -or $length -gt 24)
    {
        throw "Storage Account name '$($Name)' must be between 3-24 characters"
    }

    $regex = '^[a-z0-9]+$'
    if ($Name -notmatch $regex)
    {
        throw "Storage Account name '$($Name)' can only contain lowercase alphanumeric characters"
    }
}

function Test-FoggVMSize
{
    param (
        [string]
        $Size,

        [string]
        $Location
    )

    if (Test-Empty $Size)
    {
        throw "No VM size supplied"
    }

    if ((Get-AzureRmVMSize -Location $Location).Name -inotcontains $Size)
    {
        throw "VM size $($Size) is not valid for the $($Location) region"
    }
}

function Test-FoggVMPublisher
{
    param (
        [string]
        $Publisher,

        [string]
        $Location
    )

    if (Test-Empty $Publisher)
    {
        throw "No VM image publisher supplied"
    }

    if ((Get-AzureRmVMImagePublisher -Location $Location).PublisherName -inotcontains $Publisher)
    {
        throw "VM image publisher $($Publisher) is not valid for the $($Location) region"
    }
}

function Test-FoggVMOffer
{
    param (
        [string]
        $Offer,

        [string]
        $Publisher,

        [string]
        $Location
    )

    if (Test-Empty $Offer)
    {
        throw "No VM image offer supplied"
    }

    if ((Get-AzureRmVMImageOffer -Location $Location -PublisherName $Publisher).Offer -inotcontains $Offer)
    {
        throw "VM image offer $($Offer) is not valid for the $($Location) region"
    }
}

function Test-FoggVMSkus
{
    param (
        [string]
        $Skus,

        [string]
        $Offer,

        [string]
        $Publisher,

        [string]
        $Location
    )

    if (Test-Empty $Skus)
    {
        throw "No VM image skus supplied"
    }

    if ((Get-AzureRmVMImageSku -Location $Location -PublisherName $Publisher -Offer $Offer).Skus -inotcontains $Skus)
    {
        throw "VM image skus $($Skus) is not valid for the $($Location) region"
    }
}

function Wait-FoggProvisionState
{
    param (
        [Parameter()]
        [string]
        $ResourceId
    )

    # if there's no resourceId, just return
    if (Test-Empty $ResourceId)
    {
        $return
    }

    # get the resource and current state
    $state = (Get-AzureRmResource -ResourceId $ResourceId).Properties.ProvisioningState

    # if there is no state, just return
    if (Test-Empty $state)
    {
        return
    }

    # loop and sleep until state is succeeded
    while ($state -ine 'Succeeded')
    {
        Start-Sleep -Seconds 15
        $state = (Get-AzureRmResource -ResourceId $ResourceId).Properties.ProvisioningState
    }
}

function Get-FoggLocation
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location
    )

    return (Get-AzureRmLocation | Where-Object { $_.Location -ieq $Location } | Select-Object -First 1)
}

function Get-FoggLocationZones
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
        $Name
    )

    $resource = (Get-AzureRmComputeResourceSku | Where-Object {
        $_.LocationInfo.Location -ieq $Location -and $_.Name -ieq $Name -and $_.ResourceType -ieq $ResourceType
    } | Select-Object -First 1)

    if ((Test-Empty $resource) -or $resource.Restrictions.ReasonCode -ieq 'NotAvailableForSubscription')
    {
        return @()
    }

    return (@($resource.LocationInfo.Zones) | Sort-Object)
}