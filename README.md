# Fogg

[![MIT licensed](https://img.shields.io/badge/license-MIT-blue.svg)](https://raw.githubusercontent.com/Badgerati/Fogg/master/LICENSE.txt)
[![MIT licensed](https://img.shields.io/badge/version-Alpha-red.svg)](https://github.com/Badgerati/Fogg)

Fogg is a PowerShell tool to aide and simplify the creation, deployment and provisioning of infrastructure (IaaS) in Azure using Azure Resource Manager (does not support Classic).

## Requirements

* PowerShell v4.0+
* PowerShellGet module
* AzureRM module (installed via PowerShellGet: `Install-Module AzureRM`)

## Features

* Deploy and provision Virtual Machines in Azure
* Provision using PowerShell Desired State Configuration (DSC)
* Deploy Resource Groups
* Deploy Storage Accounts
* Deploy Virtual Networks, Subnets, and Network Security Groups with firewall rules
* Create load balanced VMs in an Availability Set
* Create public IP addresses for your VMs/Load Balancer

## Description

Fogg is a PowerShell tool to aide and simplify the creation, deployment and provisioning of infrastructure (IaaS) in Azure.

Fogg uses a JSON configuration file to determine what needs to be created and deployed (but don't worry, the JSON file is far, far smaller than Azure's template file!). Furthermore, Fogg also accepts a few parameters for things like `Resource Group Name`, `Subscription Name`, `Credentials` and others. While these are be passed in via command line, I'd recommend using a `Foggfile` to version control your deployments (more later).

## Example

This simple example will just spin-up one VM. For more examples, please see the `examples` folder in the repo.

The first thing you will need is a configuration file, which will look as follows:

```json
{
    "vms": [
        {
            "tag": "vm",
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

The above configuration will be used by Fogg to deploy one public Windows 2016 VM. You will notice the `count` parameter, changing this to 2, 3 or more will deploy 2, 3 or more of this VM type. (Note, if you deploy a VM type with a count > 1, Fogg will automatically create an availability set and load balance your VMs for you, this can be disabled via: `"useLoadBalancer": false`, though you will still get an availability set).

To use Fogg and the config file above, you will also need things such as an Azure Subscription, Resource Group, Virtual Network/Subnet addresses and other things. In general, the call to Fogg would look as follows:

```powershell
fogg -SubscriptionName "AzureSub" -ResourceGroupName "basic-rg" -Location "westeurope" -VNetAddress "10.1.0.0/16" -SubnetAddresses @{"vm"="10.1.0.0/24"} -ConfigPath "<path_to_above_config>"
```

This will tell Fogg to use the above config against your Subscription in Azure. Fogg will then:

* Validate the config file
* Request for you Azure Subscription credentials
* Request for administrator credentials to deploy the VMs
* Create a Resource Group called `basic-rg` in Location `westeurope`
* Create a Storage Account called `basicstdsa` (or `basic-std-sa` for Standard Storage)
* Create a Virtual Network called `basic-vnet` for address `10.1.0.0/16`
* Create a Network Security Group (`basic-vm-nsg`) and Subnet (`basic-vm-snet`) for address `10.1.0.0/24`
* A Virtual Machine called `basic-vm1` will then be deployed under the `basic-vm-snet` Subnet

To create a Foggfile of the above, stored at the root of the repo (can be else where as a `-FoggfilePath` can be supplied), would look like the folllowing:

```json
{
    "ResourceGroupName": "basic-rg",
    "Location": "westeurope",
    "ConfigPath": "<path_to_above_config>",
    "VNetAddress": "10.1.0.0/16",
    "SubnetAddresses": {
        "vm": "10.1.0.0/24"
    }
}
```

Note that the above leaves out the `SubscriptionName`, this is because the Foggfile at the root of a repo will mostly be used by your devs/QAs/etc. to spin-up the infrastructure in their MSDN Azure subscriptions. If the subscription name is the same for all, then you could add in the `"SubscriptionName": "<name>"` to the Foggfile.

If you are using a Foggfile at the root, then the call to use Fogg would simply be:

```powershell
fogg
```

## Advanced Example

> (This is from the `examples/web-file-servers` examples directory)

The above example gave a quick overview of using Fogg to create one VM. But normally infrastructure doesn't contain just one VM, normally you might have something like 2 load balanced web servers, and a single file server for logs/reports. Here the web VMs need to be publically accessibly on port 80 (for example), and the file server only accessible by the web servers (excluding remoting access).

This includes creating firewall rules, load balancers, public IPs, and provisioning the web server with IIS/.NET. Fortunately, all possible with Fogg; let's take a look at what the config file would look like for this:

```json
{
    "vms": [
        {
            "tag": "web",
            "count": 2,
            "dsc": [
                "remoting",
                "web"
            ],
            "usePublicIP": true,
            "port": 80,
            "firewall": {
                "inbound": [
                    {
                        "name": "HTTP",
                        "priority": 101,
                        "source": "*:*",
                        "destination": "@{subnet}:80",
                        "access": "Allow"
                    }
                ]
            }
        },
        {
            "tag": "file",
            "count": 1,
            "dsc": [
                "remoting"
            ],
            "usePublicIP": true,
            "firewall": {
                "inbound": [
                    {
                        "name": "AnyPort",
                        "priority": 101,
                        "source": "@{subnet|web}:*",
                        "destination": "@{subnet}:*",
                        "access": "Allow"
                    }
                ]
            }
        }
    ],
    "os": {
        "type": "Windows",
        "size": "Standard_DS1_v2",
        "publisher": "MicrosoftWindowsServer",
        "offer": "WindowsServer",
        "skus": "2016-Datacenter"
    },
    "dsc": {
        "remoting": ".\\Remoting.ps1",
        "web": ".\\WebServer.ps1"
    },
    "firewall": {
        "inbound": [
            {
                "name": "RDP",
                "priority": 4095,
                "source": "*:*",
                "destination": "@{subnet}:3389",
                "access": "Allow"
            }
        ]
    }
}
```

The Foggfile could be the following:

```json
{
    "ResourceGroupName": "adv-rg",
    "Location": "westeurope",
    "ConfigPath": "<path_to_above_config>",
    "VNetAddress": "10.2.0.0/16",
    "SubnetAddresses": {
        "web": "10.2.0.0/24",
        "file": "10.2.1.0/24"
    }
}
```

Now, while this does seem a little big at first, it's actually fairly simple; so let's look at each section.

### DSC

First, we'll look at the `dsc` section. This section is fairly straightforward, it's a key-value map of paths to PowerShell Desired State Configuration scritps. If a path is invalid Fogg will fail. The names (`remoting` and `web`) are used in the `vms` section to specify which DSC scripts need to be run for provisioning.

### OS

The `os` section is a global section for specifying each VMs OS type. Ie, if you have 4 VM objects in your `vms` section, and each has the same `os` spec, then you'd use this global `os` section to prevent duplciating the same section everywhere. If one of your VMs requires a different OS type, then a VM with an `os` section will override the global one.

### Firewall

This is fairly straightforward, this a an array of both `inbound` and `outbound` global firewall rules for all VM NSGs. (Normally things like 3389 for RDP, etc.)

### VMs

This section is the same as the one from spinning up one VM type, though now we have two VM types.

Firstly, is the `web` type VMs (identified by the mandatory tag for each VM). Here you'll notice that this VM has a `count` of `2`, and a `port` of `80`. Remembering from above, if you give a VM a count of > 1, then Fogg will automatically create that many VMs as well as placing them into an Availability Set and Load Balancer. The Load Balancer is where the `port` comes in, as this is what port the balancer will listen on and map to for the backend VMs. So in this case, the `web` type VM section will create 2 load balanced VMs, provision them with `remoting` and `web` DSC scripts. It will set the load balancer to to port 80, and the firewall rule will publically expose port 80.

Finally is the `file` type VM. You'll notice that this creates just one of this VM type, and provisions it with the `remoting` DSC. The VM also has a public IP but this is just for remoting onto (the global firewall inbound rule). The local firewall rule here will only allow anything from the `web` VM type's subnet (`@{subnet|web}` is replaced with the `web` subnet address specified in the `SubnetAddresses` from the command line or Foggfile).