param (
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Letters,
    
    [Parameter(Mandatory=$true)]
    [ValidateNotNullOrEmpty()]
    [string]
    $Drives
)

# split out the letters and names
$lettersArray = ($Letters -split ',' | ForEach-Object { $_.Trim() })
$drivesArray = ($Drives -split ',' | ForEach-Object { $_.Trim() })

# ensure none of the drive letters exist first
$lettersArray | ForEach-Object {
    $disk = Get-PSDrive -Name $_ -PSProvider FileSystem -ErrorAction Ignore
    if ($disk -ne $null)
    {
        throw "Drive with letter '$($_)' already exists"
    }
}

# create the disk partitions
$count = 0

Get-Disk | Where-Object { $_.PartitionStyle -ieq 'raw' } | Sort-Object Number | ForEach-Object {
    $_ |
        Initialize-Disk -PartitionStyle MBR -PassThru |
        New-Partition -UseMaximumSize -DriveLetter $lettersArray[$count] |
        Format-Volume -FileSystem NTFS -NewFileSystemLabel $drivesArray[$count] -Confirm:$false -Force
    
    $count++
}
