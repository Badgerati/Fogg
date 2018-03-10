function Get-FoggStandardisedName
{
    param (
        [Parameter()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Tag
    )

    if (Test-Empty $Name)
    {
        return [string]::Empty
    }

    if ($Name -inotlike "*-$($Tag)")
    {
        $Name = "$($Name)-$($Tag)"
    }

    return $Name.ToLowerInvariant()
}

function Get-FoggVMName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [int]
        $Index
    )

    if ($Name -ilike "*-vm$($Index)")
    {
        return $Name.ToLowerInvariant()
    }

    if ($Name -ilike "*-vm")
    {
        return "$($Name)$($Index)".ToLowerInvariant()
    }

    return (Get-FoggStandardisedName -Name $Name -Tag "vm$($Index)")
}

function Get-FoggNetworkSecurityGroupName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'nsg')
}

function Get-FoggSubnetName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'snet')
}

function Get-FoggResourceGroupName
{
    param (
        [Parameter()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'rg')
}

function Get-FoggVirtualNetworkName
{
    param (
        [Parameter()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'vnet')
}

function Get-FoggPublicIpName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'pip')
}

function Get-FoggLoadBalancerName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'lb')
}

function Get-FoggLoadBalancerBackendName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'back')
}

function Get-FoggLoadBalancerFrontendName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'front')
}

function Get-FoggLoadBalancerProbeName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'probe')
}

function Get-FoggLoadBalancerRuleName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'rule')
}

function Get-FoggAvailabilitySetName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'as')
}

function Get-FoggNetworkInterfaceName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'nic')
}

function Get-FoggLocalNetworkGatewayName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'lngw')
}

function Get-FoggVirtualNetworkGatewayName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'vngw')
}

function Get-FoggVirtualNetworkGatewayConnectionName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'vngw-con')
}

function Get-FoggVirtualNetworkGatewayIpConfigName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'cfg')
}