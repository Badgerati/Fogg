<#
    .SYNOPSIS
        Fogg is a PowerShell tool to aide and simplify the creation, deployment and provisioning of infrastructure in Azure

    .DESCRIPTION
        Fogg is a PowerShell tool to aide and simplify the creation, deployment and provisioning of infrastructure in Azur

    .PARAMETER ResourceGroupName
        The name of the Resource Group you wish to create or use in Azure

    .PARAMETER Location
        The location of where the VMs, etc. will be deployed (ie, westeurope)

    .PARAMETER ConfigPath
        The path to your Fogg configuration file, can be absolute or relative
        (unless absolute, paths in the ConfigPath must be relative to the ConfigPath (ie, provision scripts))

    .PARAMETER FoggfilePath
        The path to a Foggfile with verioned Fogg parameter values, can be absolute or relative
        (unless absolute, the ConfigPath in the Foggfile must be relative to to the Foggfile)

    .PARAMETER SubscriptionName
        The name of the Subscription you are using in Azure

    .PARAMETER SubscriptionCredentials
        This is your Azure Subscription credentials, to allow Fogg to create and deploy in Azure

    .PARAMETER VMCredentials
        This is the administrator credentials that will be used to create each box. They are the credentials
        that you would use to login to the admin account after a VM has been created (ie, to remote onto a VM)

    .PARAMETER SubnetAddresses
        This is a map of subnet addresses for VMs (ie, @{'web'='10.1.0.0/24'})
        The name is the tag name of the VM, and there must be a subnet for each VM section in you config

        You can pass more subnets than you have VMs (for linking/firewalling to existing ones), as these can
        be referenced in firewalls as "@{subnet|jump}" for example if you pass "@{'jump'='10.1.99.0/24'}"

    .PARAMETER VNetAddress
        Used when creating a new Virtual Network, this is the address prefix (ie, 10.1.0.0/16)

    .PARAMETER VNetResourceGroupName
        Paired with VNetName, if passed will use an existing Virtual Network in Azure

    .PARAMETER VNetName
        Paired with VNetResourceGroupName, if passed will use an existing Virtual Network in Azure

    .PARAMETER Version
        Switch parameter, if passed will display the current version of Fogg and end execution

    .EXAMPLE
        fogg -SubscriptionName "AzureSub" -ResourceGroupName "basic-rg" -Location "westeurope" -VNetAddress "10.1.0.0/16" -SubnetAddresses @{"vm"="10.1.0.0/24"} -ConfigPath "./path/to/config.json"
        Passing the parameters if you don't use a Foggfile

    .EXAMPLE
        fogg
        If the Foggfile is at the root of the repo where you're running Fogg

    .EXAMPLE
        fogg -FoggfilePath "./path/to/Foggfile"
        If the Foggfile is not at the root, and a path needs to be passed
#>
param (
    [string]
    $ResourceGroupName,

    [string]
    $Location,

    [string]
    $SubscriptionName,

    $SubnetAddresses,

    [string]
    $ConfigPath,

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

    [switch]
    $Version
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'Ignore'



# Import the FoggTools
$root = Split-Path -Parent -Path $MyInvocation.MyCommand.Path
Import-Module "$($root)\Modules\FoggTools.psm1" -ErrorAction Stop
Import-Module "$($root)\Modules\FoggAzure.psm1" -ErrorAction Stop


# Output the version
Write-Host 'Fogg v$version$' -ForegroundColor Cyan
if ($Version)
{
    return
}

# Test version of POSH, needs to be 4+
if (!(Test-PowerShellVersion 4))
{
    throw 'Fogg requires PowerShell v4.0 or greater'
}


# create new fogg object from parameters and foggfile
$FoggObjects = New-FoggObject -ResourceGroupName $ResourceGroupName -Location $Location -SubscriptionName $SubscriptionName `
    -SubnetAddressMap $SubnetAddresses -ConfigPath $ConfigPath -FoggfilePath $FoggfilePath -SubscriptionCredentials $SubscriptionCredentials `
    -VMCredentials $VMCredentials -VNetAddress $VNetAddress -VNetResourceGroupName $VNetResourceGroupName -VNetName $VNetName

# Start timer
$timer = [DateTime]::UtcNow


try
{
    # Login to Azure Subscription
    Add-FoggAccount -FoggObject $FoggObjects

    # Set the VM admin credentials
    Add-FoggAdminAccount -FoggObject $FoggObjects


    # loop through each group within the FoggObject
    foreach ($FoggObject in $FoggObjects.Groups)
    {
        # Parse the contents of the config file
        $config = Get-JSONContent $FoggObject.ConfigPath

        # Check that the Provisioner script paths exist
        Test-Provisioners -FoggObject $FoggObject -Paths $config.provisioners

        # Check the VM section of the config
        $vmCount = Test-VMs -VMs $config.vms -FoggObject $FoggObject -OS $config.os


        # If we're using an existng virtual network, ensure it actually exists
        if ($FoggObject.UseExistingVNet)
        {
            if ((Get-FoggVirtualNetwork -ResourceGroupName $FoggObject.VNetResourceGroupName -Name $FoggObject.VNetName) -eq $null)
            {
                throw "Virtual network $($FoggObject.VNetName) in resource group $($FoggObject.VNetResourceGroupName) does not exist"
            }
        }


        try
        {
            # Create the resource group
            $rg = New-FoggResourceGroup -FoggObject $FoggObject


            # Create the storage account
            $usePremiumStorage = [bool]$config.usePremiumStorage
            $sa = New-FoggStorageAccount -FoggObject $FoggObject -Premium:$usePremiumStorage


            # publish Provisioner scripts to storage account
            Publish-ProvisionerScripts -FoggObject $FoggObject -StorageAccount $sa


            # create the virtual network, or use existing one
            if ($FoggObject.UseExistingVNet)
            {
                $vnet = Get-FoggVirtualNetwork -ResourceGroupName $FoggObject.VNetResourceGroupName -Name $FoggObject.VNetName
            }
            else
            {
                $vnet = New-FoggVirtualNetwork -FoggObject $FoggObject
            }


            # Create virtual subnets and security groups
            foreach ($vm in $config.vms)
            {
                $tag = $vm.tag
                $vmname = "$($FoggObject.ShortRGName)-$($tag)"
                $snetname = "$($vmname)-snet"
                $subnet = $FoggObject.SubnetAddressMap[$tag]

                # Create network security group inbound/outbound rules
                $rules = New-FirewallRules -Firewall $vm.firewall -Subnets $FoggObject.SubnetAddressMap -CurrentTag $tag
                $rules = New-FirewallRules -Firewall $config.firewall -Subnets $FoggObject.SubnetAddressMap -CurrentTag $tag -Rules $rules

                # Create network security group rules, and bind to VM
                $nsg = New-FoggNetworkSecurityGroup -FoggObject $FoggObject -Name "$($vmname)-nsg" -Rules $rules
                $FoggObject.NsgMap.Add($vmname, $nsg.Id)

                # assign subnet to vnet
                $vnet = Add-FoggSubnetToVNet -FoggObject $FoggObject -VNet $vnet -SubnetName $snetname `
                    -Address $subnet -NetworkSecurityGroup $nsg
            }


            # loop through each VM, building a deploying each one
            foreach ($vm in $config.vms)
            {
                $tag = $vm.tag
                $vmname = "$($FoggObject.ShortRGName)-$($tag)"
                $usePublicIP = [bool]$vm.usePublicIP
                $subnetId = ($vnet.Subnets | Where-Object { $_.Name -ieq "$($vmname)-snet" }).Id

                $useLoadBalancer = $true
                if (!(Test-Empty $vm.useLoadBalancer))
                {
                    $useLoadBalancer = [bool]$vm.useLoadBalancer
                }

                Write-Information "Deploying VMs for $($tag)"

                # if we have more than one server count, create an availability set and load balancer
                if ($vm.count -gt 1)
                {
                    $avset = New-FoggAvailabilitySet -FoggObject $FoggObject -Name "$($vmname)-as"

                    if ($useLoadBalancer)
                    {
                        $lb = New-FoggLoadBalancer -FoggObject $FoggObject -Name "$($vmname)-lb" -SubnetId $subnetId `
                            -Port $vm.port -PublicIP:$usePublicIP
                    }
                }

                # create each of the VMs
                $_vms = @()

                1..($vm.count) | ForEach-Object {
                    # does the VM have OS settings, or use global?
                    $os = $config.os
                    if ($vm.os -ne $null)
                    {
                        $os = $vm.os
                    }

                    # create the VM
                    $_vms += (New-FoggVM -FoggObject $FoggObject -Name $vmname -VMIndex $_ -VMCredentials $FoggObjects.VMCredentials `
                        -StorageAccount $sa -SubnetId $subnetId -VMSize $os.size -VMSkus $os.skus -VMOffer $os.offer `
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
                    Set-ProvisionVM -FoggObject $FoggObject -Provisioners $vm.provisioners -VMName $_vm.Name -StorageAccount $sa
                }

                # turn off some of the VMs if needed
                if ($vm.off -gt 0)
                {
                    $count = ($_vms | Measure-Object).Count
                    $base = ($count - $vm.off) + 1

                    $count..$base | ForEach-Object {
                        Stop-FoggVM -FoggObject $FoggObject -Name "$($vmname)$($_)"
                    }
                }
            }

            # attempt to output any public IP addresses
            $ips = Get-AzureRmPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName

            if (!(Test-ArrayEmpty $ips))
            {
                Write-Information "Public IP Addresses:"

                $ips | ForEach-Object {
                    Write-Host "> $($_.Name): $($_.IpAddress)"
                }

                Write-Host ([string]::Empty)
            }
        }
        catch [exception]
        {
            Write-Fail 'Fogg failed to deploy to Azure:'
            Write-Fail $_.Exception.Message
            throw
        }
    }
}
finally
{
    # Output the total time taken
    $timer = [DateTime]::UtcNow - $timer
    Write-Host "Duration: $($timer.ToString())"
}

