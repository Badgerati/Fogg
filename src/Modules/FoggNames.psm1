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

    if ($Name -inotlike "*$($Tag)")
    {
        $Name = "$($Name)$($Tag)"
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

    return (Get-FoggStandardisedName -Name $Name -Tag "-vm$($Index)")
}

function Get-FoggNetworkSecurityGroupName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-nsg')
}

function Get-FoggVhdName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '.vhd')
}

function Get-FoggSubnetName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    if ($Name -ieq 'gatewaysubnet')
    {
        return 'GatewaySubnet'
    }

    return (Get-FoggStandardisedName -Name $Name -Tag '-snet')
}

function Get-FoggResourceGroupName
{
    param (
        [Parameter()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-rg')
}

function Get-FoggVirtualNetworkName
{
    param (
        [Parameter()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-vnet')
}

function Get-FoggPublicIpName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-pip')
}

function Get-FoggLoadBalancerName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-lb')
}

function Get-FoggLoadBalancerBackendName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-back')
}

function Get-FoggLoadBalancerFrontendName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-front')
}

function Get-FoggLoadBalancerProbeName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-probe')
}

function Get-FoggLoadBalancerRuleName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-rule')
}

function Get-FoggAvailabilitySetName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-as')
}

function Get-FoggNetworkInterfaceName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-nic')
}

function Get-FoggLocalNetworkGatewayName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-lngw')
}

function Get-FoggVirtualNetworkGatewayName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-vngw')
}

function Get-FoggVirtualNetworkGatewayConnectionName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-vngw-con')
}

function Get-FoggVirtualNetworkGatewayIpConfigName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name $Name -Tag '-cfg')
}

function Get-FoggStorageAccountName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $Name = (Get-FoggStandardisedName -Name "$($Name)" -Tag '-sa')
    return ($Name -ireplace '-', '')
}

function Get-FoggRedisCacheName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    return (Get-FoggStandardisedName -Name "$($Name)" -Tag '-redis')
}

function Get-FoggDirectionName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name
    )

    $Name = $Name.ToLowerInvariant()

    $dirs = @{
        'south' = 's';
        'east' = 'e';
        'west' = 'w';
        'north' = 'n';
        'central' = 'c';
        'southeast' = 'se';
        'southwest' = 'sw';
        'northeast' = 'ne';
        'northwest' = 'nw';
    }

    if ($dirs.ContainsKey($Name))
    {
        return $dirs[$Name]
    }

    return [string]::Empty
}

function Get-FoggLocationName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $Location
    )

    $value = [string]::Empty

    switch ($Location.ToLowerInvariant())
    {
        'eastasia' { $value = 'asia-e' }
        'southeastasia' { $value = 'asia-se' }
        'centralus' { $value = 'us-c' }
        'eastus' { $value = 'us-e' }
        'eastus2' { $value = 'us-e2' }
        'westus' { $value = 'us-w' }
        'northcentralus' { $value = 'us-nc' }
        'southcentralus' { $value = 'us-sc' }
        'northeurope' { $value = 'eu-n' }
        'westeurope' { $value = 'eu-w' }
        'japanwest' { $value = 'jp-w' }
        'japaneast' { $value = 'jp-e' }
        'brazilsouth' { $value = 'bra-s' }
        'australiaeast' { $value = 'aus-e' }
        'australiasoutheast' { $value = 'aus-se' }
        'southindia' { $value = 'ind-s' }
        'centralindia' { $value = 'ind-c' }
        'westindia' { $value = 'ind-w' }
        'canadacentral' { $value = 'can-c' }
        'canadaeast' { $value = 'can-e' }
        'uksouth' { $value = 'uk-s' }
        'ukwest' { $value = 'uk-w' }
        'westcentralus' { $value = 'us-wc' }
        'westus2' { $value = 'us-w2' }
        'koreacentral' { $value = 'kor-c' }
        'koreasouth' { $value = 'kor-s' }
        'francecentral' { $value = 'fra-c' }
    }

    return $value
}