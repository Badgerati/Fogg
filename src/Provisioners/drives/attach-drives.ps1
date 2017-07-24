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

# filter between drives that exist and ones that dont
$count = 0
$updateNames = @()
$updateLetters = @()
$newDrives = @()

$lettersArray | ForEach-Object {
    $cLetter = $lettersArray[$count]
    $cName = $drivesArray[$count]

    $byLetter = Get-WmiObject -Class Win32_Volume -Filter "DriveLetter = '$($cLetter):'" -ErrorAction Ignore
    $byName = Get-WmiObject -Class Win32_Volume -Filter "Label = '$($cName)'" -ErrorAction Ignore

    # does the letter already exist (we're updating the name)?
    if ($byLetter -ne $null -and $byName -eq $null)
    {
        $updateNames += "$($cLetter)|$($cName)"
    }

    # does the name already exist? (we're updating the letter)
    elseif ($byName -ne $null -and $byLetter -eq $null)
    {
        $updateLetters += "$($cLetter)|$($cName)"
    }

    # else, this is a new drive partition
    elseif ($byLetter -eq $null -and $byName -eq $null)
    {
        $newDrives += "$($cLetter)|$($cName)"
    }

    $count++
}

# loop through the new drives and partition them
if (($newDrives | Measure-Object).Count -gt 0)
{
    $count = 0

    Get-Disk | Where-Object { $_.PartitionStyle -ieq 'raw' } | Sort-Object Number | ForEach-Object {
        $split = $newDrives[$count] -split '\|'
        $letter = $split[0]
        $name = $split[1]

        $_ |
            Initialize-Disk -PartitionStyle MBR -PassThru |
            New-Partition -UseMaximumSize -DriveLetter $letter |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel $name -Confirm:$false -Force
        
        $count++
    }
}

# loop through the existing drives that need their names updating
$updateNames | ForEach-Object {
    $split = $_ -split '\|'
    $letter = $split[0]
    $name = $split[1]

    $drive = Get-WmiObject -Class Win32_Volume -Filter "DriveLetter = '$($letter):'"

    if ($drive.Label -ine $name)
    {
        $drive.Label = $name
        $drive.Put()
    }
}

# loop through the existing drives that need their letters updating
$updateLetters | ForEach-Object {
    $split = $_ -split '\|'
    $letter = $split[0]
    $name = $split[1]

    $drive = Get-WmiObject -Class Win32_Volume -Filter "Label = '$($name)'"

    if ($drive.DriveLetter -ine "$($letter):")
    {
        $drive.DriveLetter = "$($letter):"
        $drive.Put()
    }
}