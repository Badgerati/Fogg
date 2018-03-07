function Get-FoggStandardisedName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Tag
    )

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
        $Index,

        [switch]
        $Legacy
    )

    if ($Legacy)
    {
        if ($Name -ilike "*$($Index)")
        {
            return $Name.ToLowerInvariant()
        }

        return "$($Name)$($Index)".ToLowerInvariant()
    }
    else
    {
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
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag 'rg')
}

function Get-FoggVirtualNetworkName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
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
        $Name,

        [switch]
        $Legacy
    )

    if ($Legacy)
    {
        return (Get-FoggStandardisedName -Name $Name -Tag 'ip')
    }

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