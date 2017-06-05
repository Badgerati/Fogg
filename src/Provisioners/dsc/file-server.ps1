Configuration fileserver
{
    Node 'localhost'
    {
        WindowsFeature FileServer
        {
            Ensure = 'Present'
            Name = 'FS-FileServer'
            IncludeAllSubFeature = $true
        }

        WindowsFeature DFSNameSpace
        {
            Ensure = 'Present'
            Name = 'FS-DFS-Namespace'
            IncludeAllSubFeature = $true
        }

        WindowsFeature DFSReplication
        {
            Ensure = 'Present'
            Name = 'FS-DFS-Replication'
            IncludeAllSubFeature = $true
        }

        WindowsFeature FileResourceManager
        {
            Ensure = 'Present'
            Name = 'FS-Resource-Manager'
            IncludeAllSubFeature = $true
        }
    }
}