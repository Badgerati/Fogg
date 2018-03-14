<#
    .SYNOPSIS
        Fogg is a PowerShell tool to aide and simplify the creation, deployment and provisioning of infrastructure in Azure

    .DESCRIPTION
        Fogg is a PowerShell tool to aide and simplify the creation, deployment and provisioning of infrastructure in Azure

    .PARAMETER ResourceGroupName
        The name of the Resource Group you wish to create or use in Azure

    .PARAMETER Location
        The location of where the VMs, etc. will be deployed (ie, westeurope)

    .PARAMETER TemplatePath
        The path to your Fogg template file, can be absolute or relative
        (unless absolute, paths in the file must be relative to the TemplatePath (ie, provision scripts))

    .PARAMETER FoggfilePath
        The path to a Foggfile with verioned Fogg parameter values, can be absolute or relative
        (unless absolute, the TemplatePath in the Foggfile must be relative to to the Foggfile)

    .PARAMETER SubscriptionName
        The name of the Subscription you are using in Azure

    .PARAMETER SubscriptionCredentials
        This is your Azure Subscription credentials, to allow Fogg to create and deploy in Azure
        These credentials will only work for Organisational/Work accounts - NOT Personal ones

    .PARAMETER VMCredentials
        This is the administrator credentials that will be used to create each box. They are the credentials
        that you would use to login to the admin account after a VM has been created (ie, to remote onto a VM)

    .PARAMETER SubnetAddresses
        This is a map of subnet addresses for VMs (ie, @{'web'='10.1.0.0/24'})
        The subnet name is the role of the VM, and there must be a subnet for each VM section in you template

        You can pass more subnets than you have VMs (for linking/firewalling to existing ones), as these can
        be referenced in firewalls as "@{subnet|jump}" for example if you pass "@{'jump'='10.1.99.0/24'}"

    .PARAMETER VNetAddress
        Used when creating a new Virtual Network, this is the address prefix (ie, 10.1.0.0/16)

    .PARAMETER VNetResourceGroupName
        Paired with VNetName, if passed will use an existing Virtual Network in Azure

    .PARAMETER VNetName
        Paired with VNetResourceGroupName, if passed will use an existing Virtual Network in Azure

    .PARAMETER Platform
        (Optional) The name of the platform that is being deployed

    .PARAMETER Stamp
        (Optional) This is a unique value that is used for storage accounts

    .PARAMETER Tags
        (Optional) This is a map of tags to set/update against each resource within the created resource group. The tags
        against the resource group are also set/updated.

    .PARAMETER Version
        Switch parameter, if passed will display the current version of Fogg and end execution

    .PARAMETER Validate
        Switch parameter, if passed will only run validation on the Foggfile and templates

    .PARAMETER IgnoreCores
        Switch parameter, if passed will ignore the exceeding cores limit and continue to deploy to Azure

    .PARAMETER NoOutput
        Switch parameter, if passed, the resultant object with information of what was deployed will not be returned

    .EXAMPLE
        fogg -SubscriptionName "AzureSub" -ResourceGroupName "basic-rg" -Location "westeurope" -VNetAddress "10.1.0.0/16" -SubnetAddresses @{"vm"="10.1.0.0/24"} -TemplatePath "./path/to/template.json"
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
    [Alias('rg')]
    $ResourceGroupName,

    [string]
    [Alias('loc')]
    $Location,

    [string]
    [Alias('sub')]
    $SubscriptionName,

    [Alias('snets')]
    $SubnetAddresses,

    [string]
    [Alias('tp')]
    $TemplatePath,

    [string]
    [Alias('fp')]
    $FoggfilePath,

    [pscredential]
    [Alias('screds')]
    $SubscriptionCredentials,

    [pscredential]
    [Alias('vmcreds')]
    $VMCredentials,

    [string]
    [Alias('vnetaddr')]
    $VNetAddress,

    [string]
    [Alias('vnetrg')]
    $VNetResourceGroupName,

    [string]
    [Alias('vnet')]
    $VNetName,

    [string]
    [Alias('p')]
    $Platform,

    [string]
    [Alias('s')]
    $Stamp,

    [Alias('t')]
    $Tags,

    [switch]
    [Alias('v')]
    $Version,

    [switch]
    $Validate,

    [switch]
    $IgnoreCores,

    [switch]
    [Alias('no')]
    $NoOutput
)

$ErrorActionPreference = 'Stop'
$WarningPreference = 'Ignore'


function Restore-FoggModule([string]$Path, [string]$Name)
{
    if ((Get-Module -Name $Name) -ne $null)
    {
        Remove-Module -Name $Name -Force | Out-Null
    }

    Import-Module "$($Root)\Modules\$($Name).psm1" -Force -ErrorAction Stop
}


# Import the FoggTools
$root = Split-Path -Parent -Path $MyInvocation.MyCommand.Path
Restore-FoggModule -Path $root -Name 'FoggTools'
Restore-FoggModule -Path $root -Name 'FoggNames'
Restore-FoggModule -Path $root -Name 'FoggAzure'


# Simple function for validating the Foggfile and templates
function Test-Files
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        $FoggObject
    )

    # Parse the contents of the template file
    $template = Get-JSONContent $FoggObject.TemplatePath

    # Check that the Provisioner script paths exist
    Test-Provisioners -FoggObject $FoggObject -Paths $template.provisioners

    # Check the global firewall rules are valid
    Test-FirewallRules -FirewallRules $template.firewall

    # Check the template section
    Test-Template -Template $template -FoggObject $FoggObject | Out-Null

    # return the template for further usage
    return $template
}



# Output the version
$ver = 'v$version$'
Write-Details "Fogg $($ver)`n"

# if we were only after the version, just return
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
$FoggObjects = New-FoggObject -FoggRootPath $root -ResourceGroupName $ResourceGroupName -Location $Location -SubscriptionName $SubscriptionName `
    -SubnetAddresses $SubnetAddresses -TemplatePath $TemplatePath -FoggfilePath $FoggfilePath -SubscriptionCredentials $SubscriptionCredentials `
    -VMCredentials $VMCredentials -VNetAddress $VNetAddress -VNetResourceGroupName $VNetResourceGroupName -VNetName $VNetName -Tags $Tags `
    -Platform $Platform -Stamp $Stamp

# Start timer
$timer = [DateTime]::UtcNow


try
{
    # validate the template files and sections
    Write-Information "Verifying template files"

    foreach ($FoggObject in $FoggObjects.Groups)
    {
        Write-Host "> Verifying: $($FoggObject.TemplatePath)"
        Test-Files -FoggObject $FoggObject | Out-Null
    }

    Write-Success "Templates verified`n"


    # if we're only validating, return
    if ($Validate)
    {
        return
    }


    # Login to Azure Subscription
    Add-FoggAccount -FoggObject $FoggObjects


    # Before we attempt anything, ensure that all the VMs we're about to deploy don't exceed the Max Core limit
    # This cannot be done during normal validation, as we require the user to be logged in first
    if (Test-VMCoresExceedMax -Groups $FoggObjects.Groups)
    {
        if ($IgnoreCores)
        {
            Write-Notice 'Deployment exceeds a regional limit, but IgnoreCores has been specified'
        }
        else
        {
            return
        }
    }


    # ensure that each of the locations specified are valid, and set location short codes
    $locs = @()

    foreach ($FoggObject in $FoggObjects.Groups)
    {
        if ($locs -icontains $FoggObject.Location)
        {
            continue
        }

        if (!(Test-FoggLocation -Location $FoggObject.Location))
        {
            throw "Location supplied is invalid: $($FoggObject.Location)"
        }

        $locs += $FoggObject.Location
    }


    # have we set VM creds? but only if we have VMs to create
    $VMCredentialsSet = $false


    # loop through each group within the FoggObject
    foreach ($FoggObject in $FoggObjects.Groups)
    {
        # Retrieve the template for the current Group
        $template = Test-Files -FoggObject $FoggObject

        # Set the VM admin credentials, but only if we have VMs to create
        if (!$VMCredentialsSet -and (Test-TemplateHasType $template.template 'vm'))
        {
            Add-FoggAdminAccount -FoggObject $FoggObjects
            $VMCredentialsSet = $true
        }


        # If we're using an existng virtual network, ensure it actually exists
        if ($FoggObject.UseGlobalVNet -and $FoggObject.UseExistingVNet)
        {
            if ((Get-FoggVirtualNetwork -ResourceGroupName $FoggObject.VNetResourceGroupName -Name $FoggObject.VNetName) -eq $null)
            {
                throw "Virtual network $($FoggObject.VNetName) in resource group $($FoggObject.VNetResourceGroupName) does not exist"
            }
        }


        try
        {
            # Create the resource group
            New-FoggResourceGroup -FoggObject $FoggObject | Out-Null


            # only create global storage account if we have VMs
            if (Test-TemplateHasType $template.template 'vm')
            {
                # Create the storage account
                $usePremiumStorage = [bool]$template.usePremiumStorage
                $sa = New-FoggStorageAccount -FoggObject $FoggObject -Role 'gbl' -Premium:$usePremiumStorage
                $FoggObject.StorageAccountName = $sa.StorageAccountName

                # publish Provisioner scripts to storage account
                Publish-ProvisionerScripts -FoggObject $FoggObject -StorageAccount $sa
            }


            # create vnet/snet if we're using a global one
            if ($FoggObject.UseGlobalVNet)
            {
                # create the virtual network, or use existing one (by name and resource group)
                if ($FoggObject.UseExistingVNet)
                {
                    $vnet = Get-FoggVirtualNetwork -ResourceGroupName $FoggObject.VNetResourceGroupName -Name $FoggObject.VNetName
                }
                else
                {
                    $vnet = New-FoggVirtualNetwork -ResourceGroupName $FoggObject.ResourceGroupName -Name (Remove-RGTag $FoggObject.ResourceGroupName) `
                        -Location $FoggObject.Location -Address $FoggObject.VNetAddress
                }

                # set vnet group information
                $FoggObject.VNetAddress = $vnet.AddressSpace.AddressPrefixes[0]
                $FoggObject.VNetResourceGroupName = $vnet.ResourceGroupName
                $FoggObject.VNetName = $vnet.Name
            }


            # Create virtual subnets and security groups for VM objects in template
            $vms = ($template.template | Where-Object { $_.type -ieq 'vm' })
            foreach ($vm in $vms)
            {
                $role = $vm.role.ToLowerInvariant()
                $basename = (Join-ValuesDashed @($FoggObject.Platform, $role))
                $subnet = $FoggObject.SubnetAddressMap[$role]

                # Create network security group inbound/outbound rules
                $rules = New-FirewallRules -Firewall $vm.firewall -Subnets $FoggObject.SubnetAddressMap -CurrentRole $role
                $rules = New-FirewallRules -Firewall $template.firewall -Subnets $FoggObject.SubnetAddressMap -CurrentRole $role -Rules $rules

                # Create network security group rules, and bind to VM
                $nsg = New-FoggNetworkSecurityGroup -FoggObject $FoggObject -Name $basename -Rules $rules
                $FoggObject.NsgMap.Add($basename, $nsg.Id)

                # assign subnet to vnet
                $vnet = Add-FoggSubnetToVNet -ResourceGroupName $vnet.ResourceGroupName -VNetName $vnet.Name -SubnetName $basename -Address $subnet -NetworkSecurityGroup $nsg
            }


            # Create Gateway subnet for VPN objects in template
            $vpn = ($template.template | Where-Object { $_.type -ieq 'vpn' } | Select-Object -First 1)
            if ($vpn -ne $null)
            {
                $role = $vpn.role.ToLowerInvariant()
                $subnet = $FoggObject.SubnetAddressMap[$role]
                $vnet = Add-FoggGatewaySubnetToVNet -ResourceGroupName $vnet.ResourceGroupName -VNetName $vnet.Name -Address $subnet
            }


            # loop through each template object, building a deploying each one
            foreach ($obj in $template.template)
            {
                switch ($obj.type.ToLowerInvariant())
                {
                    'vm'
                        {
                            New-DeployTemplateVM -Template $template -VMTemplate $obj -FoggObject $FoggObject `
                                -VNet $vnet -StorageAccount $sa -VMCredentials $FoggObjects.VMCredentials
                        }

                    'vpn'
                        {
                            New-DeployTemplateVPN -VPNTemplate $obj -FoggObject $FoggObject -VNet $vnet
                        }

                    'vnet'
                        {
                            New-DeployTemplateVNet -VNetTemplate $obj -FoggObject $FoggObject
                        }

                    'sa'
                        {
                            New-DeployTemplateSA -SATemplate $obj -FoggObject $FoggObject
                        }
                }
            }

            # set/update all tags within the group
            Update-FoggResourceTags -ResourceGroupName $FoggObject.ResourceGroupName -Tags $FoggObjects.Tags
        }
        catch [exception]
        {
            Write-Fail "`nFogg failed to deploy to Azure:"
            Write-Fail $_.Exception.Message
            throw
        }
    }

    # attempt to output any public IP addresses
    Write-Information "`nPublic IP Addresses:"

    foreach ($FoggObject in $FoggObjects.Groups)
    {
        $ips = Get-FoggPublicIpAddresses $FoggObject.ResourceGroupName

        if (!(Test-ArrayEmpty $ips))
        {
            $ips | ForEach-Object {
                Write-Host "> $($_.Name): $($_.IpAddress)"
            }
        }
    }
}
finally
{
    # logout of azure
    Remove-FoggAccount -FoggObject $FoggObjects

    # Output the total time taken
    Write-Duration $timer -PreText 'Total Duration' -NewLine
}


# if we don't care about the resultant object, just return
if ($NoOutput)
{
    return
}


# re-loop through each group, constructing result object to return
$result = @{}

foreach ($FoggObject in $FoggObjects.Groups)
{
    # check if resource group already exists in result
    if (!$result.ContainsKey($FoggObject.ResourceGroupName))
    {
        $result.Add($FoggObject.ResourceGroupName, @{})
    }

    $rg = $result[$FoggObject.ResourceGroupName]

    # set location info
    $rg.Location = $FoggObject.Location

    # set global vnet info
    $rg.VirtualNetwork = @{
        'Name' = $FoggObject.VNetName;
        'ResourceGroupName' = $FoggObject.VNetResourceGroupName;
        'Address' = $FoggObject.VNetAddress;
    }

    # set storage account info
    $rg.StorageAccount = @{
        'Name' = $FoggObject.StorageAccountName;
    }

    # set vm info
    if ($rg.VirtualMachineInfo -eq $null)
    {
        $rg.VirtualMachineInfo = @{}
    }

    $info = @{}
    $FoggObject.VirtualMachineInfo.GetEnumerator() | 
        Where-Object { !$rg.VirtualMachineInfo.ContainsKey($_.Name) } |
        ForEach-Object { $info.Add($_.Name, $_.Value) }

    $rg.VirtualMachineInfo += $info

    # set vpn info
    if ($rg.VPNInfo -eq $null)
    {
        $rg.VPNInfo = @{}
    }

    $info = @{}
    $FoggObject.VPNInfo.GetEnumerator() | 
        Where-Object { !$rg.VPNInfo.ContainsKey($_.Name) } |
        ForEach-Object { $info.Add($_.Name, $_.Value) }

    $rg.VPNInfo += $info

    # set vnet info
    if ($rg.VirtualNetworkInfo -eq $null)
    {
        $rg.VirtualNetworkInfo = @{}
    }

    $info = @{}
    $FoggObject.VirtualNetworkInfo.GetEnumerator() | 
        Where-Object { !$rg.VirtualNetworkInfo.ContainsKey($_.Name) } |
        ForEach-Object { $info.Add($_.Name, $_.Value) }

    $rg.VirtualNetworkInfo += $info

    # set storage account info
    if ($rg.StorageAccountInfo -eq $null)
    {
        $rg.StorageAccountInfo = @{}
    }

    $info = @{}
    $FoggObject.StorageAccountInfo.GetEnumerator() | 
        Where-Object { !$rg.StorageAccountInfo.ContainsKey($_.Name) } |
        ForEach-Object { $info.Add($_.Name, $_.Value) }

    $rg.StorageAccountInfo += $info
}

return $result