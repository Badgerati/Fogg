<#
    .SYNOPSIS
        Fogg is an Azure VM deployer
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
Write-Host "Fogg v0.1.0a" -ForegroundColor Cyan
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
$FoggObject = New-FoggObject -ResourceGroupName $ResourceGroupName -Location $Location -SubscriptionName $SubscriptionName `
    -SubnetAddressMap $SubnetAddresses -ConfigPath $ConfigPath -FoggfilePath $FoggfilePath -SubscriptionCredentials $SubscriptionCredentials `
    -VMCredentials $VMCredentials -VNetAddress $VNetAddress -VNetResourceGroupName $VNetResourceGroupName -VNetName $VNetName

# Start timer
$timer = [DateTime]::UtcNow


try
{
    # Parse the contents of the config file
    $config = Get-JSONContent $FoggObject.ConfigPath

    # Check the VM section of the config
    $vmCount = Test-VMs -VMs $config.vms -FoggObject $FoggObject -OS $config.os

    # Check that the DSC script paths exist
    Test-DSCPaths -FoggObject $FoggObject -Paths $config.dsc


    # Login to Azure Subscription
    Add-FoggAccount -FoggObject $FoggObject


    # If we're using an existng virtual network, ensure it actually exists
    if ($FoggObject.UseExistingVNet)
    {
        if ((Get-FoggVirtualNetwork -ResourceGroupName $FoggObject.VNetResourceGroupName -Name -$FoggObject.VNetName) -eq $null)
        {
            throw "Virtual network $($FoggObject.VNetName) in resource group $($FoggObject.VNetResourceGroupName) does not exist"
        }
    }


    # Set the VM admin credentials
    Add-FoggAdminAccount -FoggObject $FoggObject


    try
    {
        # Create the resource group
        $rg = New-FoggResourceGroup -FoggObject $FoggObject


        # Create the storage account
        $usePremiumStorage = [bool]$config.usePremiumStorage
        $sa = New-FoggStorageAccount -FoggObject $FoggObject -Premium:$usePremiumStorage


        # publish DSC scripts to storage account
        if (!(Test-Empty $FoggObject.DscMap))
        {
            $FoggObject.DscMap.Values | ForEach-Object {
                Publish-FoggDscConfig -FoggObject $FoggObject -StorageAccount $sa -DscConfigPath $_
            }
        }


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
                $_vms += (New-FoggVM -FoggObject $FoggObject -Name $vmname -VMIndex $_ -StorageAccount $sa `
                    -SubnetId $subnetId -VMSize $os.size -VMSkus $os.skus -VMOffer $os.offer -VMType $os.type`
                    -VMPublisher $os.publisher -AvailabilitySet $avset -PublicIP:$usePublicIP)
            }

            # loop through each VM and deploy it
            foreach ($_vm in $_vms)
            {
                if ($_vm -eq $null)
                {
                    continue
                }

                Save-FoggVM -FoggObject $FoggObject -VM $_vm -LoadBalancer $lb

                # see if we need to provision the machine via DSC
                if ($FoggObject.HasDscScripts)
                {
                    $vm.dsc | Where-Object { $FoggObject.DscMap.Contains($_) } | ForEach-Object {
                        Set-FoggDscConfig -FoggObject $FoggObject -VMName $_vm.Name -StorageAccount $sa -DscName $_
                    }
                }
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
finally
{
    # Output the total time taken
    $timer = [DateTime]::UtcNow - $timer
    Write-Host "Duration: $($timer.ToString())"
}

