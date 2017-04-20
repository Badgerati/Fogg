
$ErrorActionPreference = 'Stop'
$WarningPreference = 'Ignore'

function Add-FoggAccount
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject
    )

    Write-Information "Attempting to sign-in to Azure Subscription: $($FoggObject.SubscriptionName)"

    if ($FoggObject.SubscriptionCredentials -ne $null)
    {
        Add-AzureRmAccount -Credential $FoggObject.SubscriptionCredentials -SubscriptionName $FoggObject.SubscriptionName | Out-Null
    }
    else
    {
        Add-AzureRmAccount -SubscriptionName $FoggObject.SubscriptionName | Out-Null
    }

    if (!$?)
    {
        throw "Failed to login into Azure Subscription: $($FoggObject.SubscriptionName)"
    }

    Write-Success "Logged into Azure Subscription: $($FoggObject.SubscriptionName)`n"
}


function Add-FoggAdminAccount
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject
    )

    if ($FoggObject.VMCredentials -eq $null)
    {
        $FoggObject.VMCredentials = Get-Credential -Message 'Supply the Admininstrator username and password for the VMs in Azure'
        if ($FoggObject.VMCredentials -eq $null)
        {
            throw 'No Azure VM Administrator credentials passed'
        }
    }
}


function Get-FoggResourceGroup
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location
    )

    try
    {
        $rg = Get-AzureRmResourceGroup -Name $ResourceGroupName -Location $Location
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


function Test-FoggStorageAccount
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


function New-FoggStorageAccount
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject,

        [switch]
        $Premium
    )

    $StorageType = 'Standard_LRS'
    $StorageTag = 'std'

    if ($Premium)
    {
        $StorageType = 'Premium_LRS'
        $StorageTag = 'prm'
    }

    $Name = ("$($FoggObject.ShortRGName)-$($StorageTag)-sa") -ireplace '-', ''

    Write-Information "Creating storage account $($Name) in resource group $($FoggObject.ResourceGroupName)"

    if (Test-FoggStorageAccount $Name)
    {
        Write-Notice "Using existing storage account for $($Name)`n"
        return (Get-AzureRmStorageAccount -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name)
    }

    $sa = New-AzureRmStorageAccount -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -SkuName $StorageType `
        -Kind Storage -Location $FoggObject.Location

    if (!$?)
    {
        throw "Failed to create storage account $($Name)"
    }

    Write-Success "Storage account $($Name) created at $($FoggObject.Location)`n"
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
            Publish-FoggDscScript -FoggObject $FoggObject -StorageAccount $StorageAccount -ScriptPath $_
        }
    }

    # are there any custom scripts to publish? if so, need a storage container first
    if (!(Test-Empty $FoggObject.ProvisionMap['custom']))
    {
        $container = New-FoggStorageContainer -FoggObject $FoggObject -StorageAccount $StorageAccount -Name 'provisioners'

        $FoggObject.ProvisionMap['custom'].Values | ForEach-Object {
            Publish-FoggCustomScript -FoggObject $FoggObject -StorageAccount $StorageAccount -Container $container -ScriptPath $_
        }
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


function Set-ProvisionVM
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $Provisioners,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMName,

        [Parameter(Mandatory=$true)]
        $StorageAccount
    )

    # check if there are any provision scripts
    if (!$FoggObject.HasProvisionScripts -or (Test-ArrayEmpty $Provisioners))
    {
        return
    }

    # loop through each provisioner, and run appropriate tool
    $Provisioners | ForEach-Object {
        if ($FoggObject.ProvisionMap['dsc'].ContainsKey($_))
        {
            Set-FoggDscConfig -FoggObject $FoggObject -VMName $VMName -StorageAccount $StorageAccount `
                -ScriptPath $FoggObject.ProvisionMap['dsc'][$_]
        }

        elseif ($FoggObject.ProvisionMap['custom'].ContainsKey($_))
        {
            Set-FoggCustomConfig -FoggObject $FoggObject -VMName $VMName -StorageAccount $StorageAccount `
                -ContainerName 'provisioners' -ScriptPath $FoggObject.ProvisionMap['custom'][$_]
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

    $file = Split-Path -Leaf -Path "$($ScriptPath)"
    $script = "$($file).zip"
    $func = ($file -ireplace '\.ps1', '')

    Write-Information "Installing DSC Extension on VM $($VMName), and running script $($script)"

    $output = Set-AzureRmVMDscExtension -ResourceGroupName $FoggObject.ResourceGroupName -VMName $VMName -ArchiveBlobName $script `
        -ArchiveStorageAccountName $StorageAccount.StorageAccountName -ConfigurationName $func -Version "2.23" -AutoUpdate `
        -Location $FoggObject.Location -Force -ErrorAction SilentlyContinue

    if (!$?)
    {
        throw "Failed to install the DSC Extension on VM $($VMName), and run script $($script):`n$($output)"
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
        $ScriptPath
    )

    $fileName = Split-Path -Leaf -Path "$($ScriptPath)"
    $fileNameNoExt = ($fileName -ireplace [Regex]::Escape([System.IO.Path]::GetExtension($fileName)), '')

    $saName = $StorageAccount.StorageAccountName
    $saKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $FoggObject.ResourceGroupName -Name $saName).Value[0]

    Write-Information "Installing Custom Script Extension on VM $($VMName), and running script $($fileName)"

    $output = Set-AzureRmVMCustomScriptExtension -ResourceGroupName $FoggObject.ResourceGroupName -VMName $VMName `
        -Location $FoggObject.Location -StorageAccountName $saName -StorageAccountKey $saKey -ContainerName $ContainerName `
        -FileName $fileName -Name $fileNameNoExt -Run $fileName -ErrorAction SilentlyContinue

    if (!$?)
    {
        throw "Failed to install the Custom Script Extension on VM $($VMName), and run script $($fileName):`n$($output)"
    }

    Write-Success "Custom Script Extension installed and script run`n"
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
        [ValidateNotNullOrEmpty()]
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

    # get storage account name and key
    $saName = $StorageAccount.StorageAccountName
    $saKey = (Get-AzureRmStorageAccountKey -ResourceGroupName $FoggObject.ResourceGroupName -Name $saName).Value[0]

    # create new storage context
    $context = New-AzureStorageContext -StorageAccountName $saName -StorageAccountKey $saKey
    if (!$?)
    {
        throw "Failed to create Storage Context for Storage Account $($saName)"
    }

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


function New-FirewallRules
{
    param (
        [Parameter(Mandatory=$true)]
        $Subnets,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $CurrentTag,

        $Firewall = $null,

        [array]
        $Rules = @()
    )

    if ($Firewall -eq $null)
    {
        return $Rules
    }

    if (!(Test-ArrayEmpty $Firewall.inbound))
    {
        $Firewall.inbound | ForEach-Object {
            $Rules += (New-FoggNetworkSecurityGroupRule -Name $_.name -Priority $_.priority -Direction 'Inbound' `
                -Source $_.source -Destination $_.destination -Subnets $Subnets -CurrentTag $CurrentTag -Access $_.access)
        }
    }

    if (!(Test-ArrayEmpty $Firewall.outbound))
    {
        $Firewall.outbound | ForEach-Object {
            $Rules += (New-FoggNetworkSecurityGroupRule -Name $_.name -Priority $_.priority -Direction 'Outbound' `
                -Source $_.source -Destination $_.destination -Subnets $Subnets -CurrentTag $CurrentTag -Access $_.access)
        }
    }

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
        $Subnets,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $CurrentTag,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Access,

        [ValidateNotNullOrEmpty()]
        [string]
        $Protocol = 'Tcp'
    )

    # split down the source for IP and Port
    $source_split = ($Source -split ':')
    $sourcePrefix = Get-ReplaceSubnet -Value $source_split[0] -Subnets $Subnets -CurrentTag $CurrentTag
    $sourcePort = Get-SubnetPort $source_split

    # split down the destination for IP and Port
    $dest_split = ($Destination -split ':')
    $destPrefix = Get-ReplaceSubnet -Value $dest_split[0] -Subnets $Subnets -CurrentTag $CurrentTag
    $destPort = Get-SubnetPort $dest_split

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

    $ResourceGroupName = $ResourceGroupName.ToLowerInvariant()
    $Name = $Name.ToLowerInvariant()

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
        [ValidateNotNull()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        $Rules
    )

    $Name = $Name.ToLowerInvariant()

    Write-Information "Creating Network Security Group $($Name) in $($FoggObject.ResourceGroupName)"

    # check to see if the NSG already exists, if so use that one
    $nsg = Get-FoggNetworkSecurityGroup -ResourceGroupName $FoggObject.ResourceGroupName -Name $name
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

    $nsg = New-AzureRmNetworkSecurityGroup -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name `
        -Location $FoggObject.Location -SecurityRules $Rules -Force

    if (!$?)
    {
        throw "Failed to create Network Security Group $($Name) in $($FoggObject.ResourceGroupName)"
    }

    Write-Success "Network security group $($Name) created in $($FoggObject.ResourceGroupName)`n"
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

    $ResourceGroupName = $ResourceGroupName.ToLowerInvariant()
    $Name = $Name.ToLowerInvariant()

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
        $FoggObject
    )

    $Name = "$($FoggObject.ShortRGName)-vnet"

    Write-Information "Creating virtual network $($Name) in $($FoggObject.ResourceGroupName)"

    # see if vnet already exists
    $vnet = Get-FoggVirtualNetwork -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($vnet -ne $null)
    {
        Write-Notice "Using existing virtual network for $($name)`n"
        return $vnet
    }

    # else create a new one
    $vnet = New-AzureRmVirtualNetwork -Name $Name -ResourceGroupName $FoggObject.ResourceGroupName `
        -Location $FoggObject.Location -AddressPrefix $FoggObject.VNetAddress -Force

    if (!$?)
    {
        throw "Failed to create virtual network $($Name)"
    }

    Write-Success "Virtual network $($Name) created for $($FoggObject.VNetAddress)`n"
    return $vnet
}


function Add-FoggSubnetToVNet
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $VNet,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $SubnetName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Address,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $NetworkSecurityGroup
    )

    $rg = $VNet.ResourceGroupName
    $name = $VNet.Name

    Write-Information "Adding subnet $($SubnetName) to Virtual Network $($name)"

    # ensure the vnet doesn't already have the subnet config
    if (($VNet.Subnets | Where-Object { $_.Name -ieq $SubnetName } | Measure-Object).Count -gt 0)
    {
        Write-Notice "Subnet $($SubnetName) already exists against $($name)`n"
        return $VNet
    }

    # attempt to add subnet to the vnet
    $output = Add-AzureRmVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $VNet `
        -AddressPrefix $Address -NetworkSecurityGroup $NetworkSecurityGroup
    if (!$?)
    {
        throw "Failed to add subnet to virtual network: $($output)"
    }

    # attempt to save the vnet
    $output = Set-AzureRmVirtualNetwork -VirtualNetwork $VNet
    if (!$?)
    {
        throw "Failed to update the virtual network with new subnet: $($output)"
    }

    # re-retrieve the vnet for updated object
    $VNet = Get-FoggVirtualNetwork -ResourceGroupName $rg -Name $name
    if (!$?)
    {
        throw "Failed to re-get Virtual Network $($name) in $($rg)"
    }

    # return vnet
    Write-Success "Virtual Subnet $($SubnetName) added`n"
    return $VNet
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

    $ResourceGroupName = $ResourceGroupName.ToLowerInvariant()
    $Name = $Name.ToLowerInvariant()

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
        $Name
    )

    $Name = $Name.ToLowerInvariant()

    Write-Information "Creating availability set $($Name) in $($FoggObject.ResourceGroupName)"

    $av = Get-FoggAvailabilitySet -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($av -ne $null)
    {
        Write-Notice "Using existing availability set for $($Name)`n"
        return $av
    }

    $av = New-AzureRmAvailabilitySet -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location
    if (!$?)
    {
        throw "Failed to create availability set $($Name)"
    }

    Write-Success "availability set $($Name) created`n"
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

    $ResourceGroupName = $ResourceGroupName.ToLowerInvariant()
    $Name = $Name.ToLowerInvariant()

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
        [int]
        $Port,

        [string]
        $SubnetId,

        [switch]
        $PublicIP
    )

    $Name = $Name.ToLowerInvariant()

    Write-Information "Creating load balancer $($Name) in $($FoggObject.ResourceGroupName)"

    # check to see if the load balancer already exists
    $lb = Get-FoggLoadBalancer -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($lb -ne $null)
    {
        Write-Notice "Using existing load balancer for $($Name)`n"
        return $lb
    }

    # create public IP address
    if ($PublicIP)
    {
        $pipId = (New-AzureRmPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName -Name "$($Name)-ip" `
            -Location $FoggObject.Location -AllocationMethod Static).Id
    }
    else
    {
        # if not subnetId, fail
        if (Test-Empty $SubnetId)
        {
            throw "SubnetId required when create private internal load balancer: $($Name)"
        }
    }

    # create frontend config
    if ($PublicIP)
    {
        $front = New-AzureRmLoadBalancerFrontendIpConfig -Name "$($Name)-front" -PublicIpAddressId $pipId
    }
    else
    {
        $front = New-AzureRmLoadBalancerFrontendIpConfig -Name "$($Name)-front" -SubnetId $SubnetId
    }

    if (!$?)
    {
        throw "Failed to create frontend IP config for $($Name)"
    }

    # create backend config
    $back = New-AzureRmLoadBalancerBackendAddressPoolConfig -Name "$($Name)-back"
    if (!$?)
    {
        throw "Failed to create backend IP config for $($Name)"
    }

    # create health probe
    $health = New-AzureRmLoadBalancerProbeConfig -Name "$($Name)-probe" -Protocol Tcp -Port $Port -IntervalInSeconds 5 -ProbeCount 2
    if (!$?)
    {
        throw "Failed to create frontend Health Probe for $($Name)"
    }

    # create balancer rules
    $rule = New-AzureRmLoadBalancerRuleConfig -Name "$($Name)-rule" -FrontendIpConfiguration $front `
        -BackendAddressPool $back -Probe $health -Protocol Tcp -FrontendPort $Port -BackendPort $Port
    if (!$?)
    {
        throw "Failed to create front end Rule for $($Name)"
    }

    # create the load balancer
    $lb = New-AzureRmLoadBalancer -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location `
        -FrontendIpConfiguration $front -BackendAddressPool $back -LoadBalancingRule $rule -Probe $health
    if (!$?)
    {
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
        $Name
    )

    $ResourceGroupName = $ResourceGroupName.ToLowerInvariant()
    $Name = $Name.ToLowerInvariant()

    try
    {
        $vm = Get-AzureRmVM -ResourceGroupName $ResourceGroupName -Name $Name
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve VM $($Name) in $($ResourceGroupName)"
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
        [ValidateNotNullOrEmpty()]
        [int]
        $VMIndex,

        [Parameter(Mandatory=$true)]
        $StorageAccount,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $SubnetId,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMSize,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMSkus,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMOffer,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMPublisher,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMType,

        $AvailabilitySet,

        [string]
        $NetworkSecurityGroupId,

        [switch]
        $PublicIP
    )

    $Name = $Name.ToLowerInvariant()
    $VMName = "$($Name)$($VMIndex)"

    $DiskName = "$($VMName)-disk1"
    $BlobName = "vhds/$($DiskName).vhd"
    $OSDisk = $StorageAccount.PrimaryEndpoints.Blob.ToString() + $BlobName

    Write-Information "Creating VM $($VMName) in $($FoggObject.ResourceGroupName)"

    # check to see if the VM already exists
    $vm = Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $VMName
    if ($vm -ne $null)
    {
        Write-Notice "Using existing VM for $($VMName)`n"
        return $vm
    }

    # create public IP address
    if ($PublicIP)
    {
        $pipId = (New-AzureRmPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName -Name "$($VMName)-ip" `
            -Location $FoggObject.Location -AllocationMethod Static).Id
    }

    # create the NIC
    $VMNIC = New-FoggNetworkInterface -FoggObject $FoggObject -Name "$($VMName)-nic" -SubnetId $SubnetId `
        -PublicIpId $pipId -NetworkSecurityGroupId $FoggObject.NsgMap[$Name]

    # setup initial VM config
    if ($AvailabilitySet -eq $null)
    {
        $VM = New-AzureRmVMConfig -VMName $VMName -VMSize $VMSize
    }
    else
    {
        $VM = New-AzureRmVMConfig -VMName $VMName -VMSize $VMSize -AvailabilitySetId $AvailabilitySet.Id
    }

    if (!$?)
    {
        throw "Failed to create the VM Config for $($VMName)"
    }

    # assign images and OS to VM
    $VM = Set-AzureRmVMOperatingSystem -VM $VM -Windows -ComputerName $VMName -Credential $FoggObject.VMCredentials -ProvisionVMAgent
    $VM = Set-AzureRmVMSourceImage -VM $VM -PublisherName $VMPublisher -Offer $VMOffer -Skus $VMSkus -Version 'latest'
    $VM = Add-AzureRmVMNetworkInterface -VM $VM -Id $VMNIC.Id

    switch ($VMType.ToLowerInvariant())
    {
        'windows'
            {
                $VM = Set-AzureRmVMOSDisk -VM $VM -Name $DiskName -VhdUri $OSDisk -CreateOption FromImage -Windows
            }

        'linux'
            {
                $VM = Set-AzureRmVMOSDisk -VM $VM -Name $DiskName -VhdUri $OSDisk -CreateOption FromImage -Linux
            }
    }

    if (!$?)
    {
        throw "Failed to assign the OS and Source Image Disks for $($VMName)"
    }

    Write-Success "VM $($VMName) created`n"
    return $VM
}


function Save-FoggVM
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        $FoggObject,

        [Parameter(Mandatory=$true)]
        $VM,

        $LoadBalancer
    )

    Write-Information "Deploying VM $($VM.Name) in $($FoggObject.ResourceGroupName)"

    # first, ensure this VM doesn't alredy exist in Azure (avoiding re-redeploying)
    if ((Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $VM.Name) -eq $null)
    {
        # create VM as it doesn't exist
        $output = New-AzureRmVM -ResourceGroupName $FoggObject.ResourceGroupName -Location $FoggObject.Location -VM $VM
        if (!$?)
        {
            throw "Failed to create VM $($VM.Name): $($output)"
        }
    }

    Write-Success "Deployed VM $($VM.Name)`n"

    # check if we need to assign a load balancer
    if ($LoadBalancer -ne $null)
    {
        Write-Information "Assigning VM $($VM.Name) to Load Balancer $($LoadBalancer.Name)"

        $nic = Get-AzureRmNetworkInterface -ResourceGroupName $FoggObject.ResourceGroupName -Name "$($VM.Name)-nic"
        if (!$? -or $nic -eq $null)
        {
            throw "Failed to retrieve Network Interface for the VM $($VM.Name)"
        }

        $back = Get-AzureRmLoadBalancerBackendAddressPoolConfig -Name "$($LoadBalancer.Name)-back" -LoadBalancer $LoadBalancer
        if (!$? -or $back -eq $null)
        {
            throw "Failed to retrieve back end pool for Load Balancer: $($LoadBalancer.Name)"
        }

        $nic.IpConfigurations[0].LoadBalancerBackendAddressPools = $back
        $output = Set-AzureRmNetworkInterface -NetworkInterface $nic

        if (!$?)
        {
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
        $Name
    )

    $Name = $Name.ToLowerInvariant()

    Write-Information "Stopping VM $($Name) in $($FoggObject.ResourceGroupName)"

    # ensure the VM exists
    if ((Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name) -eq $null)
    {
        Write-Notice "VM $($Name) does not exist"
        return
    }

    $output = Stop-AzureRmVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Force
    if (!$?)
    {
        throw "Failed to stop the VM $($Name): $($output)"
    }

    Write-Notice "VM $($Name) stopped"
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

    $ResourceGroupName = $ResourceGroupName.ToLowerInvariant()
    $Name = $Name.ToLowerInvariant()

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

    $Name = $Name.ToLowerInvariant()

    Write-Information "Creating Network Interface $($Name) in $($FoggObject.ResourceGroupName)"

    # check to see if the NIC already exists
    $nic = Get-FoggNetworkInterface -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($nic -ne $null)
    {
        Write-Notice "Using existing network interface for $($Name)`n"
        return $nic
    }

    $nic = New-AzureRmNetworkInterface -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location `
        -SubnetId $SubnetId -PublicIpAddressId $PublicIpId -NetworkSecurityGroupId $NetworkSecurityGroupId

    if (!$?)
    {
        throw "Failed to create Network Interface $($Name)"
    }

    Write-Success "Network Interface $($Name) created"
    return $nic
}