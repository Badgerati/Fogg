Configuration WebServer
{
    Node 'localhost'
    {
        WindowsFeature IIS
        {
            Ensure = 'Present'
            Name = 'Web-Server'
            IncludeAllSubFeature = $true
        }

        WindowsFeature ASPNET46
        {
            Ensure = 'Present'
            Name = 'Web-Asp-Net45'
            IncludeAllSubFeature = $true
        }

        WindowsFeature WCFServices
        {
            Ensure = 'Present'
            Name = 'NET-WCF-Services45'
            IncludeAllSubFeature = $true
        }

        WindowsFeature HTTPActivation
        {
            Ensure = 'Present'
            Name = 'NET-HTTP-Activation'
        }

        WindowsFeature HTTPNonActivation
        {
            Ensure = 'Present'
            Name = 'NET-Non-HTTP-Activ'
        }
    }
}