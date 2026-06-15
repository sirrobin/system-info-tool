# Run this script to find out which data-fetch in Get-SystemReport is slow.
# Output: a table of section -> milliseconds, sorted slowest first.
# Just runs the same WMI/CIM/PnP queries the main app does, each in isolation.
#
# Usage (from PowerShell prompt, elevated):
#   .\profile-startup.ps1

$ErrorActionPreference = 'SilentlyContinue'
$results = New-Object System.Collections.ArrayList

function Time {
    param([string]$Name, [scriptblock]$Action)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $count = $null
    try {
        $r = & $Action
        if ($r -is [System.Collections.IEnumerable] -and $r -isnot [string]) {
            $count = @($r).Count
        }
    } catch {
        $count = "ERR: $($_.Exception.Message.Substring(0, [Math]::Min(60, $_.Exception.Message.Length)))"
    }
    $sw.Stop()
    [void]$results.Add([PSCustomObject]@{
        Section = $Name
        Ms      = [int]$sw.ElapsedMilliseconds
        Count   = $count
    })
}

# ---- Sections that Get-SystemReport runs (in order) ----
Time 'Win32_ComputerSystem'         { Get-CimInstance Win32_ComputerSystem }
Time 'Win32_BIOS'                   { Get-CimInstance Win32_BIOS }
Time 'Win32_SystemEnclosure(laptop?)' { Get-CimInstance Win32_SystemEnclosure }
Time 'Win32_Battery (IsLaptop)'     { Get-CimInstance Win32_Battery }
Time 'BatteryInfoView /sxml (laptop only)' {
    $biv = Get-ChildItem -Path $env:TEMP -Filter 'SystemInfo-BIV.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $biv) {
        $biv = Get-Item '.\BatteryInfoView.exe' -ErrorAction SilentlyContinue
    }
    if ($biv) {
        $out = Join-Path $env:TEMP "profile-biv-$([Guid]::NewGuid().ToString('N')).xml"
        Start-Process -FilePath $biv.FullName -ArgumentList @('/sxml', "`"$out`"") -WindowStyle Hidden -Wait
        if (Test-Path $out) { $size = (Get-Item $out).Length; Remove-Item $out; $size }
    }
}
Time 'Win32_Processor (CPU)'        { Get-CimInstance Win32_Processor }
Time 'Win32_VideoController (GPU)'  { Get-CimInstance Win32_VideoController }
Time 'Win32_SoundDevice (Audio)'    { Get-CimInstance Win32_SoundDevice }
Time 'Get-PnpDevice touch (laptop)' { Get-PnpDevice -PresentOnly | Where-Object { $_.FriendlyName -match 'touch screen' } }
Time 'Get-PhysicalDisk'             { Get-PhysicalDisk }
Time 'Win32_DiskDrive'              { Get-CimInstance Win32_DiskDrive }
Time 'Get-StorageReliabilityCounter (all disks)' {
    Get-PhysicalDisk | ForEach-Object { $_ | Get-StorageReliabilityCounter }
}
Time 'Get-PnpDeviceProperty for NVMe PCIe lookup' {
    $w32 = Get-CimInstance Win32_DiskDrive | Where-Object { $_.InterfaceType -eq 'SCSI' -or $_.Model -match 'NVMe' } | Select-Object -First 1
    if ($w32) {
        $cur = $w32.PNPDeviceID
        for ($i=0; $i -lt 8; $i++) {
            $null = Get-PnpDeviceProperty -InstanceId $cur -KeyName '{4340A6C5-93FA-4706-972C-7B648008A5A7} 8'
            $null = Get-PnpDeviceProperty -InstanceId $cur -KeyName '{3AB22E31-8264-4B4E-9AF5-A8D2D8E33E62} 9'
            $cur = (Get-PnpDeviceProperty -InstanceId $cur -KeyName '{4340A6C5-93FA-4706-972C-7B648008A5A7} 8').Data
            if (-not $cur) { break }
        }
    }
}
Time 'Win32_PhysicalMemoryArray'    { Get-CimInstance Win32_PhysicalMemoryArray }
Time 'Win32_PhysicalMemory'         { Get-CimInstance Win32_PhysicalMemory }
Time 'Win32_NetworkAdapter (Wi-Fi/BT/WWAN)' { Get-CimInstance Win32_NetworkAdapter }
Time 'Get-NetAdapter'               { Get-NetAdapter }
Time 'Win32_OperatingSystem'        { Get-CimInstance Win32_OperatingSystem }
Time 'SoftwareLicensingProduct (activation)' {
    Get-CimInstance -Query ("SELECT LicenseStatus FROM SoftwareLicensingProduct " +
        "WHERE ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL")
}
Time 'Win32_PnPEntity (driver problem scan)' {
    Get-CimInstance -ClassName Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -gt 0 }
}

# ---- Print sorted slowest first ----
$total = ($results | Measure-Object Ms -Sum).Sum
Write-Host ""
Write-Host ("Total: {0} ms ({1:N1} s)" -f $total, ($total / 1000.0))
Write-Host ""
$results | Sort-Object Ms -Descending | Format-Table -AutoSize Section, Ms, Count
