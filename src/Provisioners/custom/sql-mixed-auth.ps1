# Load the Microsoft SMO
[System.Reflection.Assembly]::LoadWithPartialName('Microsoft.SqlServer.SMO') | Out-Null

# Connect to the server
$server = New-Object ('Microsoft.SqlServer.Management.Smo.Server') '(local)'

# Set the authentication mode to Mixed
$server.Settings.LoginMode = [Microsoft.SqlServer.Management.SMO.ServerLoginMode]::Mixed

# Save the changes
$server.Alter()