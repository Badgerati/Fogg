# Fogg

[![MIT licensed](https://img.shields.io/badge/license-MIT-blue.svg)](https://raw.githubusercontent.com/Badgerati/Fogg/master/LICENSE.txt)
[![MIT licensed](https://img.shields.io/badge/version-Beta-red.svg)](https://github.com/Badgerati/Fogg)

Fogg is a PowerShell tool to aide and simplify the creation, deployment and provisioning of infrastructure (IaaS) in Azure using Azure Resource Manager (does not support Classic).

Fogg is still in Beta, so there may be bugs or changes to prior features that break previous releases (though I will try to keep that to a minimum). Any bugs/feature requests should be raised in the GitHub issues tab.

## Installing

[Fogg](https://chocolatey.org/packages/fogg) can be installed via Chocolatey:

```bash
choco install fogg
```

## Requirements

* PowerShell v4.0+
* PowerShellGet module
* AzureRM module (installed via PowerShellGet: `Install-Module AzureRM`)

## Features

* Deploy and provision Virtual Machines in Azure
* Spin-up mulitple Resource Groups at once using a Foggfile
* Has inbuilt provision scripts, with more that can be added on request
* Inbuilt firewall ports for quicker allow/deny of in/outbound rules
* Provision using:
  * PowerShell Desired State Configuration (DSC)
  * Custom Scripts (ps1/bat)
  * Chocolatey to install software
* Deploy:
  * Resource Groups
  * Storage Accounts
  * Virtual Networks
  * Subnets
  * Network Security Groups with firewall rules
  * Availability Sets and Load Balancers
  * Public IP addresses for your VMs/Load Balancers
  * VPN Gateways for site-to-site and point-to-site connections
* Immediate feedback if your template is about to exceed the core limit in a location
* Returns an object containing the information of what was deployed
* Ability to append new VMs rather than always creating and updating the same ones
* Add additional data drives to VMs and add them as new partitions

## Description

Fogg is a PowerShell tool to aide and simplify the creation, deployment and provisioning of infrastructure (IaaS) in Azure.

Fogg uses a JSON template file to determine what needs to be created and deployed (but don't worry, the JSON file is far, far smaller than Azure's template files!). Furthermore, Fogg also accepts a few parameters for things like `Resource Group Name`, `Subscription Name`, `Credentials` and others. While these are to be passed in via command line, I'd recommend using a `Foggfile` to version control your deployments (more later).

## Example

This simple example will just spin-up one VM. For more examples, please see the `examples` folder in the repo (a more advanced example can be found in the wiki).

The first thing you will need is a template file, which will look as follows:

```json
{
    "template": [
        {
            "type": "vm",
            "role": "test",
            "count": 1,
            "os": {
                "type": "Windows",
                "size": "Standard_DS1_v2",
                "publisher": "MicrosoftWindowsServer",
                "offer": "WindowsServer",
                "skus": "2016-Datacenter"
            },
            "usePublicIP": true
        }
    ]
}
```

The above template will be used by Fogg to deploy one public Windows 2016 VM. You will notice the `count` value, changing this to 2, 3 or more will deploy 2, 3 or more of this VM type. (Note, if you deploy a VM type with a count > 1, Fogg will automatically load balance your VMs for you, this can be disabled via: `"useLoadBalancer": false`, though you will still get an availability set).

The `role` and `type` values for template objects are mandatory. the `role` can be any unique alphanumeric string (though try and keep it short). The `type` value can only be one of either `"vm"` or `"vpn"`.

To use Fogg and the template file above, you will need an Azure Subscription. In general, the call to Fogg would look as follows:

```powershell
fogg -SubscriptionName "AzureSub" -ResourceGroupName "basic-rg" -Location "westeurope" -VNetAddress "10.1.0.0/16" -SubnetAddresses @{"vm"="10.1.0.0/24"} -TemplatePath "<path_to_above_template>"
```

This will tell Fogg to use the above template against your Subscription in Azure. Fogg will then:

* Validate the template file
* Request for you Azure Subscription credentials
* Request for administrator credentials to deploy the VMs
* Create a Resource Group called `basic-rg` in Location `westeurope`
* Create a Storage Account called `basicstdsa` (or `basic-std-sa` for Standard Storage)
* Create a Virtual Network called `basic-vnet` for address `10.1.0.0/16`
* Create a Network Security Group (`basic-vm-nsg`) and Subnet (`basic-vm-snet`) for address `10.1.0.0/24`
* Create an Availability Set called `basic-vm-as`
* A Virtual Machine called `basic-test1` will then be deployed under the `basic-vm-snet` Subnet

To create a Foggfile of the above, stored at the root of the repo (can be else where as a `-FoggfilePath` can be supplied), would look like the following:

```json
{
    "Groups": [
        {
            "ResourceGroupName": "basic-rg",
            "Location": "westeurope",
            "TemplatePath": "<path_to_above_template>",
            "VNetAddress": "10.1.0.0/16",
            "SubnetAddresses": {
                "vm": "10.1.0.0/24"
            }
        }
    ]
}
```

Note that the above leaves out the `SubscriptionName`, this is because the Foggfile at the root of a repo will mostly be used by your devs/QAs/etc. to spin-up the infrastructure in their MSDN Azure subscriptions. If the subscription name is the same for all, then you could add in the `"SubscriptionName": "<name>"` to the Foggfile (as a part of the main JSON object, not within the Groups objects); if left out Fogg will request it when called.

Also note that if the path used for the `TemplatePath` is relative, it must be relative to the Foggfile's location.

If you are using a Foggfile at the root, then the call to use Fogg would simply be:

```powershell
fogg
```

If you pass in the parameters on the CLI while using a Foggfile, the parameters from the CLI have higher precidence and will override the Foggfile's values. (ie: passing `-SubscriptionName` will override the `"SubscriptionName"` in the Foggfile)

On a successful deployment, Fogg will return a resultant object that contains the information of the infrastructure that was just deployed.
This will contain the names of resources like the VNETs, Subnets and VMs; to the IPs of them, and Ports of Load Balancer. For the above example:

```powershell
'basic-rg' = @{
    'Location' = 'westeurope';
    'VirtualNetwork' = @{
        'Name' = 'basic-vnet';
        'ResourceGroupName' = 'basic-rg';
        'Address' = '10.1.0.0/16';
    };
    'StorageAccount' = @{
        'Name' = 'basicstdsa'
    };
    'VirtualMachineInfo' = @{
        'test' = @{
            'Subnet' = @{ 
                'Name' = 'basic-test-snet';
                'Address' = '10.1.0.0/24';
            };
            'AvailabilitySet' = 'basic-test-as';
            'LoadBalancer' = @{};
            'VirtualMachines' = @(
                @{
                    'Name' = 'basic-test1';
                    'PrivateIP' = '10.1.0.1';
                    'PublicIP' = '52.139.128.96';
                };
            );
        };
    };
    'VPNInfo' = @{};
    'VirtualNetworkInfo' = @{};
}
```

## TODO

* SQL always-on clusters
* Web Apps?
* Possibilty of Chef as a provisioner
* Documentation

## Bugs and Feature Requests

For any bugs you may find or features you wish to request, please create an [issue](https://github.com/Badgerati/Fogg/issues "Issues") in GitHub.