# This is a test custom PowerShell script that will
# create a single "FoggLogs" directory
if (!(Test-Path 'C:\FoggLogs'))
{
    New-Item -Path 'C:\FoggLogs' -ItemType Directory -Force
}