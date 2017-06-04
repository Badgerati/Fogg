# general variables
$hostName = $env:COMPUTERNAME
$ruleName = 'WinRM HTTPS Port'

# enable PSRemoting on the VM
Enable-PSRemoting -Force

# create firewall rule on VM
$rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction Ignore

if (($rule | Measure-Object).Count -eq 0)
{
    New-NetFirewallRule -DisplayName $ruleName -Direction 'Inbound' -LocalPort '5986' -Protocol 'TCP' -Action 'Allow'
}

# create Self Signed certificate and store thumbprint
if ((((Get-ChildItem Cert:\LocalMachine\My\).Subject -ilike "CN=$($hostName)") | Measure-Object).Count -eq 0)
{
    $thumbprint = (New-SelfSignedCertificate -DnsName $hostName -CertStoreLocation Cert:\LocalMachine\My).Thumbprint

    # run winrm command
    $cmd = "winrm create winrm/config/Listener?Address=*+Transport=HTTPS @{Hostname=`"$($hostName)`";CertificateThumbprint=`"$($thumbprint)`"}"
    cmd.exe /C $cmd
}