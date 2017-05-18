Configuration remoting
{
    Node 'localhost'
    {
        Registry AllowRemoteConnections
        {
            Ensure = 'Present'
            Key = 'HKLM:\System\CurrentControlSet\Control\Terminal Server'
            ValueName = 'fDenyTSConnections'
            ValueData = '0'
        }

        Registry SecureRemoteConnections
        {
            Ensure = 'Present'
            Key = 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp'
            ValueName = 'UserAuthentication'
            ValueData = '1'
        }
    }
}