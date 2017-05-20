# General variables
$name = 'SQL Ports'

# Ensure the rule doesn't already exist
$rule = Get-NetFirewallRule -DisplayName $name -ErrorAction Ignore

if (($rule | Measure-Object).Count -eq 0)
{
    # Allows the SQL port range 1433-1434 to be open
    New-NetFirewallRule -DisplayName $name -Description 'Inbound' -LocalPort '1433-1434' -Protocol 'TCP' -Action 'Allow'
}