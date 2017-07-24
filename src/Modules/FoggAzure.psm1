
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

    $attempts = 0
    $success = $false

    while ($attempts -lt 3 -and !$success)
    {
        try
        {
            # increment the number of attempts
            $attempts++

            # only request for admin creds if they weren't supplied from the CLI
            if ($FoggObject.VMCredentials -eq $null)
            {
                Write-Information "Setting up VM admin credentials"

                $FoggObject.VMCredentials = Get-Credential -Message 'Supply the Admininstrator username and password for the VMs in Azure'
                if ($FoggObject.VMCredentials -eq $null)
                {
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
        catch [exception]
        {
            Write-Host "$($_.Exception.Message)" -ForegroundColor Red
            $FoggObject.VMCredentials = $null
        }
    }

    # if we get here and attempts is 3+, fail
    if ($attempts -ge 3 -and !$success)
    {
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


function Get-FoggStorageAccountName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseName,

        [switch]
        $Premium
    )

    $tag = 'std'
    if ($Premium)
    {
        $tag = 'prm'
    }

    return (("$($BaseName)-$($tag)-sa") -ireplace '-', '').ToLowerInvariant()
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
    if ($Premium)
    {
        $StorageType = 'Premium_LRS'
    }

    $Name = Get-FoggStorageAccountName -BaseName $FoggObject.PreTag -Premium:$Premium

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
        $container = New-FoggStorageContainer -FoggObject $FoggObject -StorageAccount $StorageAccount -Name 'provs-custom'

        $FoggObject.ProvisionMap['custom'].Values | ForEach-Object {
            Publish-FoggCustomScript -FoggObject $FoggObject -StorageAccount $StorageAccount -Container $container -ScriptPath $_
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
        $StorageAccount
    )

    # check if there are any provision scripts
    if (!$FoggObject.HasProvisionScripts -or (Test-ArrayEmpty $Provisioners))
    {
        return
    }

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

        # DSC
        if ($map['dsc'].ContainsKey($key))
        {
            Set-FoggDscConfig -FoggObject $FoggObject -VMName $VMName -StorageAccount $StorageAccount `
                -ScriptPath $map['dsc'][$key]
        }

        # Custom
        elseif ($map['custom'].ContainsKey($key))
        {
            Set-FoggCustomConfig -FoggObject $FoggObject -VMName $VMName -StorageAccount $StorageAccount `
                -ContainerName 'provs-custom' -ScriptPath $map['custom'][$key] -Arguments $_args
        }

        # Chocolatey
        elseif ($map['choco'].ContainsKey($key))
        {
            $choco = $map['choco'][$key]

            if (Test-Empty $_args)
            {
                $_args = $choco[1]
            }

            Write-Details "Chocolatey Provisioner: $($key) ($($_args))"

            Set-FoggCustomConfig -FoggObject $FoggObject -VMName $VMName -StorageAccount $StorageAccount `
                -ContainerName 'provs-choco' -ScriptPath $choco[0] -Arguments $_args
        }

        # Drives
        elseif ($map['drives'].ContainsKey($key))
        {
            $drives = $map['drives'][$key]
            $_args = $drives[1]

            Set-FoggCustomConfig -FoggObject $FoggObject -VMName $VMName -StorageAccount $StorageAccount `
                -ContainerName 'provs-drives' -ScriptPath $drives[0] -Arguments $_args
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

        [string]
        $Arguments = $null
    )

    # get the name of the file to run
    $fileName = Split-Path -Leaf -Path "$($ScriptPath)"
    $extName = Get-FoggCustomScriptExtensionName

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
        $Name
    )

    $ResourceGroupName = $ResourceGroupName.ToLowerInvariant()
    $VMName = $VMName.ToLowerInvariant()

    try
    {
        $ext = Get-AzureRmVMCustomScriptExtension -ResourceGroupName $ResourceGroupName -VMName $VMName -Name $Name
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
        $VMName
    )

    $VMName = $VMName.ToLowerInvariant()
    $rg = $FoggObject.ResourceGroupName
    $name = Get-FoggCustomScriptExtensionName

    # only attempt to remove if the extension exists
    $ext = Get-FoggCustomScriptExtension -ResourceGroupName $rg -VMName $VMName -Name $name
    if ($ext -ne $null)
    {
        Write-Information "Uninstalling $($name) from $($VMName)"
        Remove-AzureRmVMCustomScriptExtension -ResourceGroupName $rg -VMName $VMName -Name $name -Force | Out-Null
        Write-Success "Extension uninstalled from $($VMName)`n"
    }
}


function Get-FoggCustomScriptExtensionName
{
    return 'Microsoft.Compute.CustomScriptExtension'
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
        'mysql' = '3306';
        'rdp' = '3389';
        'svn' = '3690';
        'sql-mirror' = '5022-5023';
        'postgresql' = '5432';
        'winrm' = '5985-5986';
        'redis' = '6379';
        'puppet' = '8139-8140';
        'git' = '9418';
        'octopus' = '10933';
    }
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

    # if there are no firewall rules, return
    if ($Firewall -eq $null)
    {
        return $Rules
    }

    # deal with any default inbuilt firewall rules
    $portMap = Get-FirewallPortMap
    $keys = $Firewall.psobject.properties.name
    $regex = '^(?<name>.+?)(\|(?<direction>in|out|both)){0,1}$'

    if (Test-Empty $Rules)
    {
        $priority = 3500
    }
    else
    {
        $priority = 3750
    }

    foreach ($key in $keys)
    {
        # if key doesnt match regex, continue to next
        if ($key -inotmatch $regex)
        {
            continue
        }

        # set port name and direction (default to inbound)
        $portname = $Matches['name'].ToLowerInvariant()
        $direction = 'in'
        if (!(Test-Empty $Matches['direction']))
        {
            $direction = $Matches['direction'].ToLowerInvariant()
        }

        # if custom in/outbound, or port doesnt exist, continue
        if ($portname -ieq 'inbound' -or $portname -ieq 'outbound' -or !$portMap.ContainsKey($portname))
        {
            continue
        }

        # get port and name
        $port = $portMap.$portname
        $portname = $portname.ToUpperInvariant()

        # are we allowing or denying?
        $access = 'Allow'
        if ([bool]($Firewall.$key) -eq $false)
        {
            $access = 'Deny'
        }

        # add rule(s) for desired direction
        switch ($direction)
        {
            'in'
                {
                    $Rules += (New-FoggNetworkSecurityGroupRule -Name "$($portname)_IN" -Priority $priority -Direction 'Inbound' `
                        -Source '*:*' -Destination "@{subnet}:$($port)" -Subnets $Subnets -CurrentTag $CurrentTag -Access $access)
                }

            'out'
                {
                    $Rules += (New-FoggNetworkSecurityGroupRule -Name "$($portname)_OUT" -Priority $priority -Direction 'Outbound' `
                        -Source '@{subnet}:*' -Destination "*:$($port)" -Subnets $Subnets -CurrentTag $CurrentTag -Access $access)
                }

            'both'
                {
                    $Rules += (New-FoggNetworkSecurityGroupRule -Name "$($portname)_IN" -Priority $priority -Direction 'Inbound' `
                        -Source '*:*' -Destination "@{subnet}:$($port)" -Subnets $Subnets -CurrentTag $CurrentTag -Access $access)

                    $Rules += (New-FoggNetworkSecurityGroupRule -Name "$($portname)_OUT" -Priority $priority -Direction 'Outbound' `
                        -Source '@{subnet}:*' -Destination "*:$($port)" -Subnets $Subnets -CurrentTag $CurrentTag -Access $access)
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
                -Source $_.source -Destination $_.destination -Subnets $Subnets -CurrentTag $CurrentTag -Access $_.access)
        }
    }

    # assign the outbound rules
    if (!(Test-ArrayEmpty $Firewall.outbound))
    {
        $Firewall.outbound | ForEach-Object {
            $Rules += (New-FoggNetworkSecurityGroupRule -Name $_.name -Priority $_.priority -Direction 'Outbound' `
                -Source $_.source -Destination $_.destination -Subnets $Subnets -CurrentTag $CurrentTag -Access $_.access)
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

    $Name = "$($FoggObject.PreTag)-vnet"

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


function Add-FoggGatewaySubnetToVNet
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
        $Address
    )

    $vnet = Add-FoggSubnetToVNet -FoggObject $FoggObject -VNet $VNet -SubnetName 'GatewaySubnet' -Address $Address
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

        $NetworkSecurityGroup = $null
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

    if (($VNet.Subnets | Where-Object { $_.AddressPrefix -ieq $Address } | Measure-Object).Count -gt 0)
    {
        Write-Notice "Subnet with address $($Address) already exists against $($name)`n"
        return $VNet
    }

    # attempt to add subnet to the vnet
    if ($NetworkSecurityGroup -eq $null)
    {
        $output = Add-AzureRmVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $VNet `
            -AddressPrefix $Address
    }
    else
    {
        $output = Add-AzureRmVirtualNetworkSubnetConfig -Name $SubnetName -VirtualNetwork $VNet `
            -AddressPrefix $Address -NetworkSecurityGroup $NetworkSecurityGroup
    }

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

    $ResourceGroupName = $ResourceGroupName.ToLowerInvariant()
    $Name = $Name.ToLowerInvariant()

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

    $Name = $Name.ToLowerInvariant()

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

    $ResourceGroupName = $ResourceGroupName.ToLowerInvariant()
    $Name = $Name.ToLowerInvariant()

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

    $Name = $Name.ToLowerInvariant()

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
    $config = New-AzureRmVirtualNetworkGatewayIpConfig -Name "$($Name)-cfg" -SubnetId $gatewaySubnetId -PublicIpAddressId $pipId
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

    $ResourceGroupName = $ResourceGroupName.ToLowerInvariant()
    $Name = $Name.ToLowerInvariant()

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

    $Name = $Name.ToLowerInvariant()

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

    # check to see if av set already exists
    $av = Get-FoggAvailabilitySet -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($av -ne $null)
    {
        Write-Notice "Using existing availability set for $($Name)`n"
        return $av
    }

    # create new av set
    $av = New-AzureRmAvailabilitySet -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location
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
        $pipId = (New-FoggPublicIpAddress -FoggObject $FoggObject -Name $Name -AllocationMethod 'Static').Id
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


function Get-FoggVMName
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $BaseName,
        
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [int]
        $Index
    )

    return ("$($BaseName)$($Index)").ToLowerInvariant()
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


function Get-FoggVMs
{
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $ResourceGroupName
    )

    $ResourceGroupName = $ResourceGroupName.ToLowerInvariant()

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
        $BaseName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [pscredential]
        $VMCredentials,

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

        $Drives,

        [switch]
        $PublicIP
    )

    $BaseName = $BaseName.ToLowerInvariant()
    $VMName = $VMName.ToLowerInvariant()

    $DiskName = "$($VMName)-disk1"
    $BlobName = "vhds/$($DiskName).vhd"
    $SAEndpoint = $StorageAccount.PrimaryEndpoints.Blob.ToString()
    $OSDiskUri = "$($SAEndpoint)$($BlobName)"

    Write-Information "Creating VM $($VMName) in $($FoggObject.ResourceGroupName)"

    # check to see if the VM already exists
    $vm = Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $VMName
    if ($vm -ne $null)
    {
        Write-Notice "Updating existing VM for $($VMName)`n"
        $vm = Update-FoggVM -FoggObject $FoggObject -BaseName $BaseName -VMName $VMName -SubnetId $SubnetId `
            -VMSize $VMSize -Drives $Drives -StorageAccount $StorageAccount -PublicIP:$PublicIP
        return $vm
    }

    # create public IP address
    if ($PublicIP)
    {
        $pipId = (New-FoggPublicIpAddress -FoggObject $FoggObject -Name $VMName -AllocationMethod 'Static').Id
    }

    # create the NIC
    $nic = New-FoggNetworkInterface -FoggObject $FoggObject -Name "$($VMName)-nic" -SubnetId $SubnetId `
        -PublicIpId $pipId -NetworkSecurityGroupId $FoggObject.NsgMap[$BaseName]

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
    $VM = Set-AzureRmVMOperatingSystem -VM $VM -Windows -ComputerName $VMName -Credential $VMCredentials -ProvisionVMAgent
    $VM = Set-AzureRmVMSourceImage -VM $VM -PublisherName $VMPublisher -Offer $VMOffer -Skus $VMSkus -Version 'latest'
    $VM = Add-AzureRmVMNetworkInterface -VM $VM -Id $nic.Id

    switch ($VMType.ToLowerInvariant())
    {
        'windows'
            {
                $VM = Set-AzureRmVMOSDisk -VM $VM -Name $DiskName -VhdUri $OSDiskUri -CreateOption FromImage -Windows
            }

        'linux'
            {
                $VM = Set-AzureRmVMOSDisk -VM $VM -Name $DiskName -VhdUri $OSDiskUri -CreateOption FromImage -Linux
            }
    }

    if (!$?)
    {
        throw "Failed to assign the OS and Source Image Disks for $($VMName)"
    }

    # create any additional drives
    if (!(Test-ArrayEmpty $Drives))
    {
        $lun = 1

        $Drives | ForEach-Object {
            $xDiskName = "$($VMName)-$($_.type.ToLowerInvariant())-$($_.name.ToLowerInvariant())"
            $BlobName = "vhds/$($xDiskName).vhd"
            $xDiskUri = "$($SAEndpoint)$($BlobName)"
    
            Write-Information "Creating drive: $($xDiskName)"
            $VM = Add-AzureRmVMDataDisk -VM $VM -Name $xDiskName -VhdUri $xDiskUri -Lun $lun -Caching ReadOnly -DiskSizeInGB $_.size -CreateOption Empty
            $lun++
        }
    }

    Write-Success "VM $($VMName) created`n"
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
        $BaseName,

        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $VMName,

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

        $Drives,

        [switch]
        $PublicIP
    )

    $BaseName = $BaseName.ToLowerInvariant()
    $VMName = $VMName.ToLowerInvariant()
    $SAEndpoint = $StorageAccount.PrimaryEndpoints.Blob.ToString()

    # variables
    $nicName = "$($VMName)-nic"

    # create public IP address if one doesn't already exist
    if ($PublicIP)
    {
        $pipId = (New-FoggPublicIpAddress -FoggObject $FoggObject -Name $VMName -AllocationMethod 'Static').Id
    }

    # update the NIC, assigning the Public IP and NSG if we have one
    New-FoggNetworkInterface -FoggObject $FoggObject -Name $nicName -SubnetId $SubnetId `
        -PublicIpId $pipId -NetworkSecurityGroupId $FoggObject.NsgMap[$BaseName] | Out-Null

    # update the VM size if it's different
    $vm = Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $VMName
    if ($vm.HardwareProfile.VmSize -ine $VMSize)
    {
        Write-Information "Updating VM size to $($VMSize)"
        Stop-FoggVM -FoggObject $FoggObject -Name $VMName

        $vm.HardwareProfile.VmSize = $VMSize
        Update-AzureRmVM -ResourceGroupName $FoggObject.ResourceGroupName -VM $vm | Out-Null

        Start-FoggVM -FoggObject $FoggObject -Name $VMName
        Write-Success "Size of VM updated`n"
    }

    # re-retrieve the updated VM
    $vm = Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $VMName

    # update the VM with any additional drives not yet assigned
    if (!(Test-ArrayEmpty $Drives))
    {
        $lun = $vm.StorageProfile.DataDisks.Count + 1

        # check to see if we have any new drives
        $Drives | ForEach-Object {
            $xDiskName = "$($VMName)-$($_.type.ToLowerInvariant())-$($_.name.ToLowerInvariant())"
            $BlobName = "vhds/$($xDiskName).vhd"
            $xDiskUri = "$($SAEndpoint)$($BlobName)"

            if ($vm.StorageProfile.DataDisks.Name -inotcontains $xDiskName)
            {
                Write-Information "Creating drive: $($xDiskName)"
                $vm = Add-AzureRmVMDataDisk -VM $vm -Name $xDiskName -VhdUri $xDiskUri -Lun $lun -Caching ReadOnly -DiskSizeInGB $_.size -CreateOption Empty
                $lun++
            }
        }
    }

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
    else
    {
        $output = Update-AzureRmVM -ResourceGroupName $FoggObject.ResourceGroupName -VM $VM
        if (!$?)
        {
            throw "Failed to update VM $($VM.Name): $($output)"
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

    $output = Stop-AzureRmVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -StayProvisioned -Force
    if (!$?)
    {
        throw "Failed to stop the VM $($Name): $($output)"
    }

    Write-Notice "VM $($Name) stopped"
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

    Write-Information "Starting VM $($Name) in $($FoggObject.ResourceGroupName)"

    # ensure the VM exists
    if ((Get-FoggVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name) -eq $null)
    {
        Write-Notice "VM $($Name) does not exist"
        return
    }

    $output = Start-AzureRmVM -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if (!$?)
    {
        throw "Failed to start the VM $($Name): $($output)"
    }

    Write-Success "VM $($Name) started"
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
        $nic = Update-FoggNetworkInterface -FoggObject $FoggObject -Name $Name -PublicIpId $PublicIpId -NetworkSecurityGroupId $NetworkSecurityGroupId
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

    $Name = $Name.ToLowerInvariant()
    $changes = $false

    # get the existing NIC
    $nic = Get-FoggNetworkInterface -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($nic -eq $null)
    {
        return
    }

    # assign Public IP if one doesn't already exist
    if (!(Test-Empty $PublicIpId) -and $nic.IpConfigurations[0].PublicIpAddress -eq $null)
    {
        $pipName = Get-NameFromAzureId $PublicIpId
        $pip = Get-FoggPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName -Name $pipName

        Write-Information "Updating $($Name) with Public IP $($pipName)"
        $nic.IpConfigurations[0].PublicIpAddress = $pip
        $changes = $true
    }

    # assign NSG if one doesn't already exist
    if (!(Test-Empty $NetworkSecurityGroupId) -and $nic.NetworkSecurityGroup -eq $null)
    {
        $nsgName = Get-NameFromAzureId $NetworkSecurityGroupId
        $nsg = Get-FoggNetworkSecurityGroup -ResourceGroupName $FoggObject.ResourceGroupName -Name $nsgName

        Write-Information "Updating $($Name) with NSG $($nsg)"
        $nic.NetworkSecurityGroup = $nsg
        $changes = $true
    }

    # save possible changes
    if ($changes)
    {
        Set-AzureRmNetworkInterface -NetworkInterface $nic | Out-Null
    }

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

    $ResourceGroupName = $ResourceGroupName.ToLowerInvariant()

    try
    {
        $pips = Get-AzureRmPublicIpAddress -ResourceGroupName $ResourceGroupName
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve Public IP Addresses in $($ResourceGroupName)"
        }
    }
    catch [exception]
    {
        if ($_.Exception.Message -ilike '*was not found*')
        {
            $pips = $null
        }
        else
        {
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

    $ResourceGroupName = $ResourceGroupName.ToLowerInvariant()
    $Name = $Name.ToLowerInvariant()

    try
    {
        $pip = Get-AzureRmPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $Name
        if (!$?)
        {
            throw "Failed to make Azure call to retrieve Public IP Address: $($Name) in $($ResourceGroupName)"
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

    # TODO: Remove backwards compatibility
    if ($pip -eq $null -and $Name -ilike '*-pip')
    {
        $backwards = $Name -ireplace '-pip', '-ip'
        Write-Notice "Could not find public IP $($Name), attempting back compatibility for: $($backwards)"
        return (Get-FoggPublicIpAddress -ResourceGroupName $ResourceGroupName -Name $backwards)
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
        [ValidateNotNullOrEmpty()]
        [string]
        $AllocationMethod
    )

    $Name = "$($Name.ToLowerInvariant())-pip"

    Write-Information "Creating Public IP Address $($Name)"

    # check to see if the IP already exists
    $pip = Get-FoggPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name
    if ($pip -ne $null)
    {
        Write-Notice "Using existing Public IP Address for $($Name)`n"
        return $pip
    }

    $pip = New-AzureRmPublicIpAddress -ResourceGroupName $FoggObject.ResourceGroupName -Name $Name -Location $FoggObject.Location `
        -AllocationMethod $AllocationMethod -Force

    if (!$?)
    {
        throw "Failed to create Public IP Address $($Name)"
    }

    Write-Success "Public IP Address $($Name) created`n"
    return $pip
}


function Get-FoggVMSizeDetails
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