<#
.SYNOPSIS
    Windows GUI for the system information report.

.DESCRIPTION
    Starts elevated automatically (UAC prompt on launch). Admin rights are
    needed to read SMART/wear data for SSD health.

.NOTES
    To convert this to a standalone .exe (no PowerShell window):
        Install-Module ps2exe -Scope CurrentUser
        Invoke-ps2exe .\SystemInfo-GUI.ps1 .\SystemInfo.exe -noConsole

    For ps2exe builds, also pass -requireAdmin to embed an admin manifest:
        Invoke-ps2exe .\SystemInfo-GUI.ps1 .\SystemInfo.exe -noConsole -requireAdmin
    That makes Windows show the UAC prompt before the .exe even starts,
    which is cleaner than the in-script relaunch this script falls back to.
#>

# ----------------------------------------------------------------------
# Auto-elevate: if we're not running as Administrator, relaunch via UAC
# and exit. The relaunched copy starts elevated and runs the rest of
# the script normally.
# ----------------------------------------------------------------------
$_isAdminCheck = $false
try {
    $_id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $_pr = New-Object System.Security.Principal.WindowsPrincipal($_id)
    $_isAdminCheck = $_pr.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
} catch { }

if (-not $_isAdminCheck) {
    try {
        $_exePath = $null
        try {
            $_main = [System.Diagnostics.Process]::GetCurrentProcess().MainModule
            if ($_main) { $_exePath = $_main.FileName }
        } catch {}

        $_isPwshHost = ($_exePath -match '\\powershell(_ise)?\.exe$' -or $_exePath -match '\\pwsh\.exe$')

        if ($_exePath -and ($_exePath -like '*.exe') -and -not $_isPwshHost) {
            # ps2exe-built .exe — relaunch ourselves elevated
            Start-Process -FilePath $_exePath -Verb RunAs | Out-Null
            exit
        } else {
            # Running as a .ps1 — relaunch via PowerShell elevated.
            # -WindowStyle Hidden suppresses the empty console window that
            # would otherwise flash up behind the UAC prompt.
            $_scriptPath = $null
            if ($PSCommandPath)                  { $_scriptPath = $PSCommandPath }
            elseif ($MyInvocation.MyCommand.Path){ $_scriptPath = $MyInvocation.MyCommand.Path }

            if ($_scriptPath) {
                Start-Process -FilePath 'powershell.exe' `
                    -ArgumentList @('-NoProfile','-NonInteractive','-WindowStyle','Hidden','-ExecutionPolicy','Bypass','-File',"`"$_scriptPath`"") `
                    -Verb RunAs `
                    -WindowStyle Hidden | Out-Null
                exit
            }
        }
    } catch {
        # User clicked "No" on UAC, or relaunch failed for some reason.
        # Show a brief notice and continue running unelevated — the user
        # can use the in-app Restart as Admin button later if they change
        # their mind.
        Add-Type -AssemblyName System.Windows.Forms
        [System.Windows.Forms.MessageBox]::Show(
            "Continuing without administrator rights. SSD health values will not be available.",
            "Not elevated",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
    }
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ----------------------------------------------------------------------
# Locate the directory the script/exe lives in (works for .ps1 and ps2exe)
# ----------------------------------------------------------------------
$script:AppDir = $null
if ($PSScriptRoot)                                  { $script:AppDir = $PSScriptRoot }
elseif ($MyInvocation.MyCommand.Path)               { $script:AppDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
else {
    try {
        $main = [System.Diagnostics.Process]::GetCurrentProcess().MainModule
        if ($main -and $main.FileName) { $script:AppDir = Split-Path -Parent $main.FileName }
    } catch { }
}
if (-not $script:AppDir) { $script:AppDir = (Get-Location).Path }

# ======================================================================
#  DATA GATHERING
# ======================================================================
function Get-Safe {
    param([scriptblock]$Script, [string]$Default = 'Unknown')
    try {
        $v = & $Script
        if ($null -eq $v -or "$v".Trim() -eq '') { return $Default }
        return $v
    } catch { return $Default }
}

# DEVPKEY property IDs from pciprop.h
#    9 = CurrentLinkSpeed   10 = CurrentLinkWidth
#   11 = MaxLinkSpeed       12 = MaxLinkWidth
$script:PKEY_Parent      = '{4340A6C5-93FA-4706-972C-7B648008A5A7} 8'
$script:PKEY_PciCurSpeed = '{3AB22E31-8264-4B4E-9AF5-A8D2D8E33E62} 9'
$script:PKEY_PciCurWidth = '{3AB22E31-8264-4B4E-9AF5-A8D2D8E33E62} 10'
$script:PKEY_PciMaxSpeed = '{3AB22E31-8264-4B4E-9AF5-A8D2D8E33E62} 11'
$script:PKEY_PciMaxWidth = '{3AB22E31-8264-4B4E-9AF5-A8D2D8E33E62} 12'
$script:PKEY_BtLmp       = '{83DA6326-97A6-4088-9453-A1923F573B29} 12'
$script:PcieGenMap       = @{1='Gen1';2='Gen2';3='Gen3';4='Gen4';5='Gen5';6='Gen6'}
$script:ValidPcieWidths  = @(1, 2, 4, 8, 12, 16, 32)

function Get-PcieLinkForNvme {
    param([string]$DiskPnpId)
    if (-not $DiskPnpId) { return $null }
    $current = $DiskPnpId
    for ($i = 0; $i -lt 8; $i++) {
        if (-not $current) { break }
        $maxSpeed = $null; $maxWidth = $null; $curSpeed = $null
        try { $maxSpeed = (Get-PnpDeviceProperty -InstanceId $current -KeyName $script:PKEY_PciMaxSpeed -ErrorAction Stop).Data } catch {}
        try { $maxWidth = (Get-PnpDeviceProperty -InstanceId $current -KeyName $script:PKEY_PciMaxWidth -ErrorAction Stop).Data } catch {}
        try { $curSpeed = (Get-PnpDeviceProperty -InstanceId $current -KeyName $script:PKEY_PciCurSpeed -ErrorAction Stop).Data } catch {}

        $speedOk = ($maxSpeed -and [int]$maxSpeed -ge 1 -and [int]$maxSpeed -le 6)
        $widthOk = ($maxWidth -and $script:ValidPcieWidths -contains [int]$maxWidth)

        if ($speedOk -and $widthOk) {
            $desc = "PCIe $($script:PcieGenMap[[int]$maxSpeed]) x$maxWidth"
            $curOk = ($curSpeed -and [int]$curSpeed -ge 1 -and [int]$curSpeed -le 6)
            if ($curOk -and [int]$curSpeed -lt [int]$maxSpeed) {
                $desc += " (currently $($script:PcieGenMap[[int]$curSpeed]))"
            }
            return $desc
        }
        try { $current = (Get-PnpDeviceProperty -InstanceId $current -KeyName $script:PKEY_Parent -ErrorAction Stop).Data } catch { break }
    }
    return $null
}

function Get-DiskHealthPercent {
    <#
      Returns an int 0-100 or $null. Tries multiple sources because no
      single API works for every drive:
        1. Get-StorageReliabilityCounter Wear (NVMe + SATA SSD, needs admin)
        2. MSFT_PhysicalDisk Reliability Wear via the Storage namespace
        3. Get-PhysicalDisk -IncludeDiagnosticInfo (newer Windows)
    #>
    param($PhysicalDisk)

    # Source 1: Get-StorageReliabilityCounter (the cleanest path)
    try {
        $rel = $PhysicalDisk | Get-StorageReliabilityCounter -ErrorAction Stop
        if ($rel -and $null -ne $rel.Wear) {
            return [Math]::Max(0, [Math]::Min(100, 100 - [int]$rel.Wear))
        }
    } catch { }

    # Source 2: query the Storage namespace directly. Sometimes this works
    # when Get-StorageReliabilityCounter doesn't.
    try {
        $rel2 = Get-CimInstance -Namespace root\Microsoft\Windows\Storage `
            -ClassName MSFT_StorageReliabilityCounter -ErrorAction Stop |
            Where-Object { $_.DeviceId -eq $PhysicalDisk.DeviceId } |
            Select-Object -First 1
        if ($rel2 -and $null -ne $rel2.Wear) {
            return [Math]::Max(0, [Math]::Min(100, 100 - [int]$rel2.Wear))
        }
    } catch { }

    return $null
}

function Test-IsAdmin {
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $p  = New-Object System.Security.Principal.WindowsPrincipal($id)
        return $p.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Test-IsLaptop {
    <#
      Returns $true if this looks like a portable/laptop machine, $false
      for desktops/towers/servers. Uses Win32_SystemEnclosure ChassisTypes
      (SMBIOS spec): 8=Portable, 9=Laptop, 10=Notebook, 11=HandHeld,
      12=DockingStation, 14=SubNotebook, 18=ExpansionChassis (rare),
      21=PeripheralChassis (rare), 30=Tablet, 31=Convertible, 32=Detachable.
      Falls back to "is there a battery?" if chassis is missing/unknown.
    #>
    $portable = @(8, 9, 10, 11, 12, 14, 30, 31, 32)
    try {
        $enc = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop
        foreach ($e in $enc) {
            foreach ($t in $e.ChassisTypes) {
                if ($portable -contains [int]$t) { return $true }
            }
        }
    } catch { }
    # Fallback: if there's a battery on the system, treat it as a laptop
    try {
        $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($bat) { return $true }
    } catch { }
    return $false
}

function Get-WindowsActivationStatus {
    <# Returns "Activated", "Not activated", "Grace period", or "Unknown". #>
    try {
        # ApplicationID 55c92734-... is the well-known Windows OS license app ID,
        # which filters out Office and other products.
        $q = "SELECT LicenseStatus, Description FROM SoftwareLicensingProduct " +
             "WHERE ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' " +
             "AND PartialProductKey IS NOT NULL"
        $lic = Get-CimInstance -Query $q -ErrorAction Stop | Select-Object -First 1
        if (-not $lic) { return 'Not activated' }
        switch ([int]$lic.LicenseStatus) {
            1 { 'Activated' }
            0 { 'Unlicensed' }
            2 { 'Initial grace' }
            3 { 'Additional grace' }
            4 { 'Non-genuine grace' }
            5 { 'Notification (not activated)' }
            6 { 'Extended grace' }
            default { "Status $($lic.LicenseStatus)" }
        }
    } catch { 'Unknown' }
}

function Get-SystemReport {
    $script:IsAdmin  = Test-IsAdmin
    $script:IsLaptop = Test-IsLaptop

    $report = [System.Collections.ArrayList]::new()
    function _Add {
        param($Property, $Value, [switch]$Highlight)
        [void]$report.Add([PSCustomObject]@{
            Property  = $Property
            Value     = [string]$Value
            Highlight = [bool]$Highlight
        })
    }

    $cs   = Get-CimInstance -ClassName Win32_ComputerSystem
    $bios = Get-CimInstance -ClassName Win32_BIOS

    _Add 'Manufacturer'  (Get-Safe { $cs.Manufacturer })
    _Add 'Model'         (Get-Safe { $cs.Model })
    _Add 'Serial Number' (Get-Safe { $bios.SerialNumber })

    _Add 'CPU' (Get-Safe { (Get-CimInstance Win32_Processor | Select-Object -First 1).Name.Trim() })

    # GPUs
    $vcs = @()
    try {
        $vcs = Get-CimInstance Win32_VideoController |
            Where-Object { $_.Name -and $_.Name -notmatch 'Microsoft Basic|Remote|Virtual|Meta|Parsec' }
    } catch { }
    $ded = @(); $int = @()
    foreach ($vc in $vcs) {
        $n = $vc.Name.Trim()
        if ($n -match 'NVIDIA|GeForce|RTX|GTX|Quadro' -or
            $n -match 'Radeon\s+(RX|Pro|R\d|HD\s+[5-9]\d{3})' -or
            $n -match 'Intel.*\bArc\b.*A\d{3}') { $ded += $n } else { $int += $n }
    }
    _Add 'Dedicated GPU'  $(if ($ded) { $ded -join '; ' } else { 'None' })
    _Add 'Integrated GPU' $(if ($int) { $int -join '; ' } else { 'None' })

    _Add 'Audio' (Get-Safe {
        $devs = Get-CimInstance Win32_SoundDevice -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'OK' -and $_.Name -notmatch 'Virtual|Remote' }
        if (-not $devs) { return 'Unknown' }
        ($devs | ForEach-Object {
            if ($_.Manufacturer -and $_.Manufacturer -notmatch 'Microsoft|\(Standard') {
                "$($_.Name) ($($_.Manufacturer))"
            } else { $_.Name }
        }) -join '; '
    })

    if ($script:IsLaptop) {
        _Add 'Touchscreen' (Get-Safe {
            $touch = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'OK' -and $_.FriendlyName -match 'touch screen|HID-compliant touch screen' }
            if ($touch) { 'Yes' } else { 'No' }
        })

        _Add 'Screen size' (Get-Safe {
            $m = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction Stop | Select-Object -First 1
            if ($m.MaxHorizontalImageSize -and $m.MaxVerticalImageSize) {
                $wCm = [double]$m.MaxHorizontalImageSize
                $hCm = [double]$m.MaxVerticalImageSize
                $inches = [Math]::Sqrt(($wCm*$wCm)+($hCm*$hCm)) / 2.54
                "{0:N1}`" ({1:N1} cm x {2:N1} cm)" -f $inches, $wCm, $hCm
            } else { 'Unknown' }
        })

        _Add 'Screen max resolution' (Get-Safe {
            $res = $null
            try {
                $modes = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction Stop
                $best = $modes | ForEach-Object {
                    $_.MonitorSourceModes | Sort-Object { $_.HorizontalActivePixels * $_.VerticalActivePixels } -Descending |
                        Select-Object -First 1
                } | Sort-Object { $_.HorizontalActivePixels * $_.VerticalActivePixels } -Descending | Select-Object -First 1
                if ($best) { $res = "{0} x {1}" -f $best.HorizontalActivePixels, $best.VerticalActivePixels }
            } catch { }
            if (-not $res) {
                $vc = Get-CimInstance Win32_VideoController |
                    Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
                if ($vc) { $res = "{0} x {1} (current)" -f $vc.CurrentHorizontalResolution, $vc.CurrentVerticalResolution }
            }
            $res
        })
    }

    # ---- Storage: one row per physical disk ----------------------------
    try {
        $physDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId
        if (-not $physDisks) { _Add 'Storage' 'Unknown' }
        else {
            $w32Map = @{}
            Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue | ForEach-Object {
                $w32Map[[int]$_.Index] = $_
            }

            foreach ($d in $physDisks) {
                $sizeGB = [Math]::Round($d.Size / 1GB, 0)
                $model  = if ($d.FriendlyName) { $d.FriendlyName.Trim() } else { 'Unknown disk' }

                $typeDesc = ''
                switch ($d.MediaType) {
                    'SSD' {
                        switch ($d.BusType) {
                            'NVMe' {
                                $w32  = $w32Map[[int]$d.DeviceId]
                                $pcie = if ($w32) { Get-PcieLinkForNvme -DiskPnpId $w32.PNPDeviceID } else { $null }
                                $typeDesc = if ($pcie) { "NVMe SSD ($pcie)" } else { 'NVMe SSD' }
                            }
                            'SATA' { $typeDesc = 'SATA SSD' }
                            'USB'  { $typeDesc = 'USB SSD' }
                            'SCSI' { $typeDesc = 'SCSI SSD' }
                            'RAID' { $typeDesc = 'RAID SSD' }
                            default { $typeDesc = "$($d.BusType) SSD" }
                        }
                    }
                    'HDD' {
                        switch ($d.BusType) {
                            'SATA' { $typeDesc = 'SATA HDD' }
                            'USB'  { $typeDesc = 'USB HDD' }
                            default { $typeDesc = "$($d.BusType) HDD" }
                        }
                    }
                    default { $typeDesc = "$($d.BusType) $($d.MediaType)" }
                }

                # Health: try to show as %; if unavailable, the drive
                # doesn't expose Wear via SMART (rare on modern SSDs but
                # common on cheap/old drives and USB-attached storage).
                $health = Get-DiskHealthPercent $d
                $highlight = $false
                if ($null -ne $health) {
                    $healthStr = "Health: $health%"
                    if ($d.MediaType -eq 'SSD' -and $health -lt 70) { $highlight = $true }
                } else {
                    $healthStr = "Health: N/A"
                }

                $value = "$model -- $sizeGB GB -- $typeDesc -- $healthStr"
                _Add "Storage (Disk $($d.DeviceId))" $value -Highlight:$highlight
            }
        }
    } catch { _Add 'Storage' "Error: $($_.Exception.Message)" }

    _Add 'RAM' (Get-Safe { "{0:N0} GB" -f [Math]::Round($cs.TotalPhysicalMemory / 1GB, 0) })

    _Add 'RAM Slots' (Get-Safe {
        $array = Get-CimInstance Win32_PhysicalMemoryArray | Select-Object -First 1
        $totalSlots = if ($array) { [int]$array.MemoryDevices } else { 0 }
        $modules = Get-CimInstance Win32_PhysicalMemory | Sort-Object DeviceLocator
        $populated = @($modules).Count

        $looksSoldered = $false
        foreach ($m in $modules) {
            if ($m.FormFactor -eq 11 -or $m.DeviceLocator -match 'onboard|soldered|system\s*board') { $looksSoldered = $true; break }
        }
        $typeMap = @{20='DDR';21='DDR2';24='DDR3';26='DDR4';34='DDR5';27='FBD2';30='LPDDR';31='LPDDR2';32='LPDDR3';33='LPDDR4';35='LPDDR5'}
        $formMap = @{8='DIMM';11='Row-of-chips (soldered)';12='SODIMM';13='SRIMM';15='FB-DIMM'}

        $slotLines = foreach ($m in $modules) {
            $sizeGB = [Math]::Round($m.Capacity / 1GB, 0)
            $type = if ($typeMap.ContainsKey([int]$m.SMBIOSMemoryType)) { $typeMap[[int]$m.SMBIOSMemoryType] } else { "Type$($m.SMBIOSMemoryType)" }
            $form = if ($formMap.ContainsKey([int]$m.FormFactor)) { $formMap[[int]$m.FormFactor] } else { "Form$($m.FormFactor)" }
            $speed = if ($m.ConfiguredClockSpeed) { "$($m.ConfiguredClockSpeed) MT/s" } elseif ($m.Speed) { "$($m.Speed) MT/s" } else { '' }
            $loc = if ($m.DeviceLocator) { $m.DeviceLocator.Trim() } else { 'Slot?' }
            "[$loc] ${sizeGB} GB $type $form $speed".TrimEnd()
        }
        $header = "$totalSlots slot(s), $populated populated"
        if ($totalSlots -gt $populated) { $header += ", $($totalSlots - $populated) empty" }
        if ($looksSoldered) { $header += " (appears soldered)" }
        $header + "`r`n" + ($slotLines -join "`r`n")
    })

    _Add 'Wi-Fi' (Get-Safe {
        $adapter = Get-NetAdapter -ErrorAction SilentlyContinue |
            Where-Object {
                ($_.PhysicalMediaType -eq 'Native 802.11' -or $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11') -and
                $_.InterfaceDescription -notmatch 'Virtual|Bluetooth|WWAN'
            } | Select-Object -First 1
        if (-not $adapter) { return 'No Wi-Fi adapter found' }
        $radioTypes = ''
        try {
            $netshOut = netsh wlan show drivers 2>$null
            $line = $netshOut | Where-Object { $_ -match 'Radio types supported' } | Select-Object -First 1
            if ($line) { $radioTypes = ($line -split ':', 2)[1].Trim() }
        } catch {}
        $gen = 'Wi-Fi version unknown'
        if     ($radioTypes -match '802\.11be') { $gen = 'Wi-Fi 7 (802.11be)' }
        elseif ($radioTypes -match '802\.11ax') { $gen = 'Wi-Fi 6/6E (802.11ax)' }
        elseif ($radioTypes -match '802\.11ac') { $gen = 'Wi-Fi 5 (802.11ac)' }
        elseif ($radioTypes -match '802\.11n')  { $gen = 'Wi-Fi 4 (802.11n)' }
        "$gen -- $($adapter.InterfaceDescription)"
    })

    _Add 'Bluetooth' (Get-Safe {
        $bt = Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'OK' -and $_.FriendlyName -match 'Bluetooth' -and $_.FriendlyName -notmatch 'Enumerator' } |
            Select-Object -First 1
        if (-not $bt) { return 'No Bluetooth adapter found' }
        $lmp = $null
        try {
            $prop = Get-PnpDeviceProperty -InstanceId $bt.InstanceId -KeyName $script:PKEY_BtLmp -ErrorAction Stop
            if ($null -ne $prop.Data) { $lmp = [int]$prop.Data }
        } catch {}
        $btVer = switch ($lmp) {
            0 {'Bluetooth 1.0b'} 1 {'Bluetooth 1.1'} 2 {'Bluetooth 1.2'}
            3 {'Bluetooth 2.0 + EDR'} 4 {'Bluetooth 2.1 + EDR'} 5 {'Bluetooth 3.0 + HS'}
            6 {'Bluetooth 4.0'} 7 {'Bluetooth 4.1'} 8 {'Bluetooth 4.2'}
            9 {'Bluetooth 5.0'} 10 {'Bluetooth 5.1'} 11 {'Bluetooth 5.2'}
            12 {'Bluetooth 5.3'} 13 {'Bluetooth 5.4'}
            default { if ($null -ne $lmp) { "Bluetooth (LMP $lmp)" } else { 'Bluetooth version unknown' } }
        }
        "$btVer -- $($bt.FriendlyName)"
    })

    _Add 'WWAN' (Get-Safe {
        $a = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
            Where-Object {
                $_.PhysicalMediaType -eq 'Wireless WAN' -or
                $_.InterfaceDescription -match 'WWAN|Mobile Broadband|Cellular|\bLTE\b|\b5G\b|\b4G\b'
            } | Select-Object -First 1
        if ($a) { "Yes -- $($a.InterfaceDescription)" } else { 'Not present' }
    } 'Not present')

    # OS row now also includes Windows activation status
    _Add 'Operating System' (Get-Safe {
        $o = Get-CimInstance Win32_OperatingSystem
        $caption = $o.Caption.Trim()
        if ($o.BuildNumber -ge 22000 -and $caption -notmatch '11') { $caption = $caption -replace 'Windows 10', 'Windows 11' }
        $activation = Get-WindowsActivationStatus
        "{0} (Version {1}, Build {2}) -- {3}" -f $caption, $o.Version, $o.BuildNumber, $activation
    })

    if ($script:IsLaptop) {
        _Add 'Battery Health Percentage' (Get-Safe {
            $full   = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop
            $static = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData        -ErrorAction Stop
            if ($full -and $static -and $static.DesignedCapacity -gt 0) {
                $fullCap   = ($full   | Measure-Object FullChargedCapacity -Sum).Sum
                $designCap = ($static | Measure-Object DesignedCapacity    -Sum).Sum
                $pct = [Math]::Round(($fullCap / $designCap) * 100, 1)
                "{0}% ({1:N0} / {2:N0} mWh)" -f $pct, $fullCap, $designCap
            } else { 'N/A (no battery detected)' }
        } 'N/A (no battery detected)')
    }

    return ,$report.ToArray()
}

function Format-ReportAsText {
    param($Report)
    $labelWidth = ($Report | ForEach-Object { $_.Property.Length } | Measure-Object -Maximum).Maximum
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine("System Information Report")
    [void]$sb.AppendLine("Generated: $(Get-Date)")
    [void]$sb.AppendLine("Computer:  $env:COMPUTERNAME")
    [void]$sb.AppendLine(("=" * 60))
    foreach ($item in $Report) {
        $label = $item.Property.PadRight($labelWidth)
        $lines = $item.Value -split "`r?`n"
        [void]$sb.AppendLine("$label : $($lines[0])")
        if ($lines.Count -gt 1) {
            $indent = ' ' * ($labelWidth + 3)
            for ($i = 1; $i -lt $lines.Count; $i++) { [void]$sb.AppendLine("$indent$($lines[$i])") }
        }
    }
    $sb.ToString()
}

# ======================================================================
#  AUDIO (panned tone generation for speaker test)
# ======================================================================
function New-PannedToneFile {
    param(
        [string]$Path,
        [int]$Frequency = 600,
        [int]$DurationMs = 900,
        [ValidateSet('Left','Right','Both')] [string]$Channel = 'Both'
    )
    $sampleRate    = 44100
    $channels      = 2
    $bitsPerSample = 16
    $totalSamples  = [int]($sampleRate * $DurationMs / 1000)
    $dataSize      = $totalSamples * $channels * 2

    $fs = [System.IO.File]::Create($Path)
    $bw = New-Object System.IO.BinaryWriter($fs)
    try {
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('RIFF'))
        $bw.Write([uint32](36 + $dataSize))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('WAVE'))
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('fmt '))
        $bw.Write([uint32]16)
        $bw.Write([uint16]1)
        $bw.Write([uint16]$channels)
        $bw.Write([uint32]$sampleRate)
        $bw.Write([uint32]($sampleRate * $channels * 2))
        $bw.Write([uint16]($channels * 2))
        $bw.Write([uint16]$bitsPerSample)
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
        $bw.Write([uint32]$dataSize)

        $amp = 16000
        $twoPiF = 2 * [Math]::PI * $Frequency
        $fadeSamples = [int]($sampleRate * 0.025)

        for ($i = 0; $i -lt $totalSamples; $i++) {
            $env = 1.0
            if ($i -lt $fadeSamples)                  { $env = $i / $fadeSamples }
            elseif ($i -gt $totalSamples - $fadeSamples) { $env = ($totalSamples - $i) / $fadeSamples }

            $val = [int16]($amp * $env * [Math]::Sin($twoPiF * $i / $sampleRate))
            $silence = [int16]0
            switch ($Channel) {
                'Left'  { $bw.Write($val);    $bw.Write($silence) }
                'Right' { $bw.Write($silence); $bw.Write($val) }
                'Both'  { $bw.Write($val);    $bw.Write($val) }
            }
        }
    } finally {
        $bw.Close()
        $fs.Close()
    }
}

# ======================================================================
#  LABEL GENERATION (Dymo 89mm x 36mm PDF)
# ======================================================================
function Get-ShortCpuName {
    param([string]$Full)
    if (-not $Full) { return 'CPU' }
    # Common Intel desktop/laptop SKUs: i3-1115G4, i7-13700H, i9-14900K
    if ($Full -match '\b(i\d-\d{3,5}\w*)\b')                    { return $matches[1] }
    # Intel Core Ultra: "Core Ultra 7 155H"
    if ($Full -match '\b(Core\s*Ultra\s*\d+\s*\d{3}\w*)\b')     { return $matches[1] }
    # Intel Xeon (e.g., "Xeon W-1290P")
    if ($Full -match '\b(Xeon\s+\S+)\b')                        { return $matches[1] }
    # AMD Ryzen: "Ryzen 7 5800H", "Ryzen 5 PRO 7530U"
    if ($Full -match '\b(Ryzen\s+\d(?:\s+PRO)?\s+\d{3,4}\w*)\b'){ return $matches[1] }
    # Last resort: strip vendor/brand cruft
    $clean = $Full -replace 'Intel\(R\)|Core\(TM\)|AMD|\(R\)|\(TM\)|CPU|Processor|@.*$|\d+(?:\.\d+)?\s*GHz', ''
    return ($clean -replace '\s+', ' ').Trim()
}

function Get-LabelStorageSummary {
    # Returns "512GB SSD", "1TB SSD + 2TB HDD", etc. Internal disks only.
    $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -ne 'USB' }
    if (-not $disks) { return 'Storage Unknown' }

    $ssdBytes = ($disks | Where-Object MediaType -eq 'SSD' | Measure-Object Size -Sum).Sum
    $hddBytes = ($disks | Where-Object MediaType -eq 'HDD' | Measure-Object Size -Sum).Sum
    $otherBytes = ($disks | Where-Object { $_.MediaType -ne 'SSD' -and $_.MediaType -ne 'HDD' } | Measure-Object Size -Sum).Sum

    # Snap reported binary size to the marketing/consumer-friendly size that
    # matches what's printed on the box (953 GiB -> "1TB").
    function _Pretty([Int64]$bytes) {
        if (-not $bytes) { return $null }
        $gib = $bytes / 1GB
        if     ($gib -lt 100)    { '{0:0}GB' -f $gib }
        elseif ($gib -lt 200)    { '128GB' }
        elseif ($gib -lt 350)    { '256GB' }
        elseif ($gib -lt 700)    { '512GB' }
        elseif ($gib -lt 1400)   { '1TB' }
        elseif ($gib -lt 2700)   { '2TB' }
        elseif ($gib -lt 5500)   { '4TB' }
        elseif ($gib -lt 11000)  { '8TB' }
        elseif ($gib -lt 22000)  { '16TB' }
        else                     { '{0:0}TB' -f ($gib / 1024) }
    }

    $parts = @()
    if ($ssdBytes)   { $parts += "$(_Pretty $ssdBytes) SSD" }
    if ($hddBytes)   { $parts += "$(_Pretty $hddBytes) HDD" }
    if ($otherBytes) { $parts += "$(_Pretty $otherBytes) Storage" }
    if (-not $parts) { return 'Storage Unknown' }
    return ($parts -join ' + ')
}

function Get-LabelDisplaySummary {
    $sizeStr = ''; $resStr = ''; $touchStr = ''

    try {
        $m = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction Stop | Select-Object -First 1
        if ($m -and $m.MaxHorizontalImageSize -and $m.MaxVerticalImageSize) {
            $wCm = [double]$m.MaxHorizontalImageSize
            $hCm = [double]$m.MaxVerticalImageSize
            $inches = [Math]::Sqrt(($wCm*$wCm)+($hCm*$hCm)) / 2.54
            $sizeStr = '{0:N1}"' -f $inches
        }
    } catch {}

    try {
        $modes = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction Stop
        $best = $modes | ForEach-Object {
            $_.MonitorSourceModes | Sort-Object { $_.HorizontalActivePixels * $_.VerticalActivePixels } -Descending |
                Select-Object -First 1
        } | Sort-Object { $_.HorizontalActivePixels * $_.VerticalActivePixels } -Descending | Select-Object -First 1
        if ($best) { $resStr = '{0}x{1}' -f $best.HorizontalActivePixels, $best.VerticalActivePixels }
    } catch {}

    if (-not $resStr) {
        $vc = Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue |
            Where-Object { $_.CurrentHorizontalResolution -gt 0 } | Select-Object -First 1
        if ($vc) { $resStr = '{0}x{1}' -f $vc.CurrentHorizontalResolution, $vc.CurrentVerticalResolution }
    }

    $touch = Get-PnpDevice -PresentOnly -ErrorAction SilentlyContinue |
        Where-Object { $_.Status -eq 'OK' -and $_.FriendlyName -match 'touch screen|HID-compliant touch screen' } |
        Select-Object -First 1
    if ($touch) { $touchStr = ' touchscreen' }

    $parts = @($sizeStr, $resStr) | Where-Object { $_ }
    if (-not $parts) { return 'Display Unknown' }
    return (($parts -join ' ') + $touchStr).Trim()
}

function Get-LabelGpuSummary {
    param([string]$DedicatedGpuFull)
    if (-not $DedicatedGpuFull -or $DedicatedGpuFull -eq 'None') { return $null }
    # Trim parentheticals like "(Notebook)" and squeeze whitespace
    $s = $DedicatedGpuFull -replace '\([^)]+\)', ''
    $s = $s -replace '^\s*NVIDIA\s+', ''
    $s = $s -replace '\s+', ' '
    return $s.Trim()
}

function Get-LabelBatterySummary {
    <# Returns "Battery: 87%" or $null if unavailable. #>
    try {
        $full   = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop
        $static = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData        -ErrorAction Stop
        if ($full -and $static -and $static.DesignedCapacity -gt 0) {
            $fullCap   = ($full   | Measure-Object FullChargedCapacity -Sum).Sum
            $designCap = ($static | Measure-Object DesignedCapacity    -Sum).Sum
            $pct = [Math]::Round(($fullCap / $designCap) * 100, 0)
            return "Battery: $pct%"
        }
    } catch {}
    return $null
}

function Get-LabelData {
    # Pull raw data once and shape it into label fields. Fields that don't
    # apply (display/battery on a desktop) come back as $null and the PDF
    # renderer skips them.
    $cs = Get-CimInstance Win32_ComputerSystem
    $cpuFull = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    $isLaptop = Test-IsLaptop

    # Model only — strip manufacturer. Lenovo uses ComputerSystemProduct.Version
    # for the user-friendly product name (e.g., "ThinkPad T14 Gen 3").
    $modelLine = ''
    try {
        $cs2 = Get-CimInstance Win32_ComputerSystemProduct
        if ($cs2.Vendor -match 'LENOVO' -and $cs2.Version) { $modelLine = $cs2.Version }
    } catch {}
    if (-not $modelLine) { $modelLine = $cs.Model }
    $modelLine = ($modelLine -replace '\s+', ' ').Trim()

    $ramGB = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 0)
    $cpuShort = Get-ShortCpuName $cpuFull
    $storageShort = Get-LabelStorageSummary
    $specsLine = "$cpuShort / ${ramGB}GB RAM / $storageShort"

    # Display only on portable machines
    $displayLine = $null
    if ($isLaptop) { $displayLine = Get-LabelDisplaySummary }

    # Reuse the same dGPU detection used for the on-screen report
    $dedicated = $null
    try {
        $vcs = Get-CimInstance Win32_VideoController |
            Where-Object { $_.Name -and $_.Name -notmatch 'Microsoft Basic|Remote|Virtual|Meta|Parsec' }
        $dedicated = ($vcs | Where-Object {
            $_.Name -match 'NVIDIA|GeForce|RTX|GTX|Quadro' -or
            $_.Name -match 'Radeon\s+(RX|Pro|R\d|HD\s+[5-9]\d{3})' -or
            $_.Name -match 'Intel.*\bArc\b.*A\d{3}'
        } | Select-Object -First 1 -ExpandProperty Name)
    } catch {}
    $gpuLine = Get-LabelGpuSummary $dedicated

    # Battery only on portable machines
    $batteryLine = $null
    if ($isLaptop) { $batteryLine = Get-LabelBatterySummary }

    [PSCustomObject]@{
        Model   = $modelLine
        Specs   = $specsLine
        Display = $displayLine
        Gpu     = $gpuLine
        Battery = $batteryLine
    }
}

function Format-PdfString {
    # Escape text for a PDF literal string and force ASCII (built-in
    # Helvetica is WinAnsi-encoded; non-ASCII would render as garbage).
    param([string]$s)
    if (-not $s) { return '' }
    $s = $s -replace '\\', '\\\\'
    $s = $s -replace '\(',  '\('
    $s = $s -replace '\)',  '\)'
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $code = [int]$ch
        if ($code -ge 32 -and $code -le 126) { [void]$sb.Append($ch) }
        else { [void]$sb.Append('?') }
    }
    return $sb.ToString()
}

function New-DymoLabelPdf {
    <#
      Writes a PDF label sized 89mm x 36mm. Lines below the model are
      optional — pass $null/empty for any that don't apply. Built byte-by-
      byte so we don't need any external libraries; the resulting PDF is
      under 1 KB.
    #>
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $ModelLine,
        [Parameter(Mandatory)] [string] $SpecsLine,
        [string] $DisplayLine = '',
        [string] $GpuLine     = '',
        [string] $BatteryLine = ''
    )

    # 1mm = 2.83465 points; 89x36 mm rounds to 252.28 x 102.05 pt
    $pageW = 252.28
    $pageH = 102.05

    # Build the optional body lines in order
    $bodyTexts = @()
    $bodyTexts += $SpecsLine
    if ($DisplayLine) { $bodyTexts += $DisplayLine }
    if ($GpuLine)     { $bodyTexts += $GpuLine }
    if ($BatteryLine) { $bodyTexts += $BatteryLine }

    # Pick font sizes that comfortably fit the number of lines. The label
    # is ~36mm tall (102 pt) with ~5mm safe margins top/bottom.
    $totalLines = 1 + $bodyTexts.Count   # bold model + body
    if     ($totalLines -le 3) { $modelSize = 12; $bodySize = 10; $bodyLead = 14 }
    elseif ($totalLines -eq 4) { $modelSize = 11; $bodySize = 9;  $bodyLead = 13 }
    else                       { $modelSize = 10; $bodySize = 8;  $bodyLead = 11 }

    $modelText = Format-PdfString $ModelLine
    $bodyTextsEsc = $bodyTexts | ForEach-Object { Format-PdfString $_ }

    # Layout (PDF origin is bottom-left). Y position calculated to top-align.
    $startY = $pageH - 6 - $modelSize
    $contentLines = @(
        'BT'
        "/F2 $modelSize Tf"          # Helvetica-Bold
        "6 $startY Td"
        "($modelText) Tj"
        "/F1 $bodySize Tf"           # Helvetica
    )
    foreach ($t in $bodyTextsEsc) {
        $contentLines += "0 -$bodyLead Td"
        $contentLines += "($t) Tj"
    }
    $contentLines += 'ET'

    $contentStr   = ($contentLines -join "`n") + "`n"
    $contentBytes = [System.Text.Encoding]::ASCII.GetBytes($contentStr)
    $contentLen   = $contentBytes.Length

    $ms     = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($ms, [System.Text.Encoding]::ASCII)

    # Helpers for byte-level output. Defined inline so they capture $writer/$ms.
    function _WL([string]$s) {
        $bytes = [System.Text.Encoding]::ASCII.GetBytes($s)
        $writer.Write($bytes)
        $writer.Write([byte]10)   # LF
    }
    function _Pos { return [int]$ms.Position }

    _WL '%PDF-1.4'
    # Binary marker — 4 bytes >= 128 telling viewers this isn't a text PDF
    $writer.Write([byte[]]@(37, 226, 227, 207, 211, 10))

    $offsets = @{}

    $offsets[1] = _Pos
    _WL '1 0 obj'
    _WL '<< /Type /Catalog /Pages 2 0 R >>'
    _WL 'endobj'

    $offsets[2] = _Pos
    _WL '2 0 obj'
    _WL '<< /Type /Pages /Kids [3 0 R] /Count 1 >>'
    _WL 'endobj'

    $offsets[3] = _Pos
    _WL '3 0 obj'
    _WL ("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {0} {1}] /Resources << /Font << /F1 4 0 R /F2 5 0 R >> >> /Contents 6 0 R >>" -f $pageW, $pageH)
    _WL 'endobj'

    $offsets[4] = _Pos
    _WL '4 0 obj'
    _WL '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>'
    _WL 'endobj'

    $offsets[5] = _Pos
    _WL '5 0 obj'
    _WL '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>'
    _WL 'endobj'

    $offsets[6] = _Pos
    _WL '6 0 obj'
    _WL ("<< /Length {0} >>" -f $contentLen)
    _WL 'stream'
    $writer.Write($contentBytes)
    _WL 'endstream'
    _WL 'endobj'

    $xrefPos = _Pos
    _WL 'xref'
    _WL '0 7'
    # PDF spec: each xref entry is exactly 20 bytes including the LF.
    # The 19-char body below + LF written by _WL = 20 bytes.
    _WL '0000000000 65535 f '
    for ($i = 1; $i -le 6; $i++) {
        _WL ("{0:D10} 00000 n " -f $offsets[$i])
    }

    _WL 'trailer'
    _WL '<< /Size 7 /Root 1 0 R >>'
    _WL 'startxref'
    _WL "$xrefPos"
    _WL '%%EOF'

    $writer.Flush()
    [System.IO.File]::WriteAllBytes($Path, $ms.ToArray())
    $writer.Close()
    $ms.Close()
}

# ======================================================================
#  FORM
# ======================================================================
$baseFont   = New-Object System.Drawing.Font('Segoe UI', 10.5)
$titleFont  = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$headerFont = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$propFont   = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$valFont    = New-Object System.Drawing.Font('Consolas', 10.5)

$form = New-Object System.Windows.Forms.Form
$form.Text          = if (Test-IsAdmin) { "System Information (Administrator)" } else { "System Information" }
$form.Size          = New-Object System.Drawing.Size(960, 760)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size(740, 540)
$form.Font          = $baseFont

$header = New-Object System.Windows.Forms.Panel
$header.Dock      = 'Top'
$header.Height    = 60
$header.BackColor = [System.Drawing.Color]::FromArgb(30, 64, 102)
$form.Controls.Add($header)

$titleLabel = New-Object System.Windows.Forms.Label
$titleLabel.Text      = "System Information Report"
$titleLabel.ForeColor = [System.Drawing.Color]::White
$titleLabel.Font      = $titleFont
$titleLabel.AutoSize  = $true
$titleLabel.Location  = New-Object System.Drawing.Point(18, 14)
$header.Controls.Add($titleLabel)

# Buttons in a wrapping flow panel so they don't push off screen
$buttons = New-Object System.Windows.Forms.FlowLayoutPanel
$buttons.Dock          = 'Bottom'
$buttons.Height        = 100
$buttons.Padding       = New-Object System.Windows.Forms.Padding(10, 10, 10, 10)
$buttons.FlowDirection = 'LeftToRight'
$buttons.WrapContents  = $true
$form.Controls.Add($buttons)

function New-ActionButton {
    param([string]$Text)
    $b = New-Object System.Windows.Forms.Button
    $b.Text   = $Text
    $b.Size   = New-Object System.Drawing.Size(150, 36)
    $b.Margin = New-Object System.Windows.Forms.Padding(0, 0, 8, 6)
    $b.Font   = $baseFont
    return $b
}

$btnRefresh  = New-ActionButton "Refresh"
$btnCopy     = New-ActionButton "Copy to Clipboard"
$btnSave     = New-ActionButton "Save as Text..."
$btnBattery  = New-ActionButton "Battery Report"
$btnLabel    = New-ActionButton "Print Label (PDF)"
$btnQR       = New-ActionButton "Show QR Code"
$btnSpeakers = New-ActionButton "Test Speakers"
$btnCamera   = New-ActionButton "Test Camera"
$btnKeyboard = New-ActionButton "Test Keyboard"
$btnClose    = New-ActionButton "Close"

$buttons.Controls.AddRange(@($btnRefresh, $btnCopy, $btnSave, $btnBattery, $btnLabel, $btnQR, $btnSpeakers, $btnCamera, $btnKeyboard, $btnClose))

$status = New-Object System.Windows.Forms.StatusStrip
$status.Font = $baseFont
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "Ready"
[void]$status.Items.Add($statusLabel)
$form.Controls.Add($status)

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock                      = 'Fill'
$grid.ReadOnly                  = $true
$grid.AllowUserToAddRows        = $false
$grid.AllowUserToDeleteRows     = $false
$grid.AllowUserToResizeRows     = $false
$grid.RowHeadersVisible         = $false
$grid.SelectionMode             = 'FullRowSelect'
$grid.MultiSelect               = $false
$grid.AutoSizeRowsMode          = 'AllCells'
$grid.EnableHeadersVisualStyles = $false
$grid.BackgroundColor           = [System.Drawing.Color]::White
$grid.BorderStyle               = 'None'
$grid.GridColor                 = [System.Drawing.Color]::FromArgb(230, 230, 235)
$grid.ColumnHeadersDefaultCellStyle.Font      = $headerFont
$grid.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 245)
$grid.ColumnHeadersDefaultCellStyle.Padding   = New-Object System.Windows.Forms.Padding(8, 6, 8, 6)
$grid.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(248, 249, 252)
$grid.DefaultCellStyle.Padding  = New-Object System.Windows.Forms.Padding(6, 4, 6, 4)
$grid.RowTemplate.MinimumHeight = 30

[void]$grid.Columns.Add("Property", "Property")
[void]$grid.Columns.Add("Value", "Value")
$grid.Columns[0].Width                     = 240
$grid.Columns[0].DefaultCellStyle.Font     = $propFont
$grid.Columns[1].AutoSizeMode              = 'Fill'
$grid.Columns[1].DefaultCellStyle.WrapMode = 'True'
$grid.Columns[1].DefaultCellStyle.Font     = $valFont

$form.Controls.Add($grid)
$grid.BringToFront()

# ======================================================================
#  ACTIONS
# ======================================================================
$script:currentReport = $null

function Resize-FormToContent {
    if ($grid.Rows.Count -eq 0) { return }
    [System.Windows.Forms.Application]::DoEvents()

    $rowsHeight = 0
    foreach ($row in $grid.Rows) { $rowsHeight += $row.Height }
    $gridNeeded = $rowsHeight + $grid.ColumnHeadersHeight + 4

    $chrome = $form.Height - $form.ClientSize.Height
    $targetClient = $header.Height + $buttons.Height + $status.Height + $gridNeeded
    $targetForm   = $targetClient + $chrome

    $screen = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $maxH = $screen.Height - 40
    $newH = [Math]::Max($form.MinimumSize.Height, [Math]::Min($targetForm, $maxH))

    if ($newH -ne $form.Height) {
        $top = $form.Top
        if (($top + $newH) -gt ($screen.Top + $screen.Height)) {
            $top = [Math]::Max($screen.Top, $screen.Top + $screen.Height - $newH)
        }
        $form.SetBounds($form.Left, $top, $form.Width, $newH)
    }
}

function Populate-Grid {
    $statusLabel.Text = "Gathering system information..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $btnRefresh.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $report = Get-SystemReport
        $script:currentReport = $report
        $grid.Rows.Clear()
        foreach ($item in $report) {
            $rowIndex = $grid.Rows.Add($item.Property, $item.Value)
            if ($item.Highlight) {
                $bg = [System.Drawing.Color]::FromArgb(232, 90, 90)
                $fg = [System.Drawing.Color]::White
                $grid.Rows[$rowIndex].DefaultCellStyle.BackColor          = $bg
                $grid.Rows[$rowIndex].DefaultCellStyle.ForeColor          = $fg
                $grid.Rows[$rowIndex].DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
                $grid.Rows[$rowIndex].DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
            }
        }
        Resize-FormToContent
        $statusLabel.Text = "Ready. $($report.Count) items. Last refreshed $(Get-Date -Format 'HH:mm:ss')."
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, "Error gathering information:`r`n$($_.Exception.Message)",
            "Error", 'OK', 'Error') | Out-Null
        $statusLabel.Text = "Error: $($_.Exception.Message)"
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
        $btnRefresh.Enabled = $true
    }
}

$btnRefresh.Add_Click({ Populate-Grid })

$btnCopy.Add_Click({
    if ($script:currentReport) {
        [System.Windows.Forms.Clipboard]::SetText((Format-ReportAsText $script:currentReport))
        $statusLabel.Text = "Report copied to clipboard."
    }
})

$btnSave.Add_Click({
    if (-not $script:currentReport) { return }
    $dlg = New-Object System.Windows.Forms.SaveFileDialog
    $dlg.Filter   = "Text files (*.txt)|*.txt|All files (*.*)|*.*"
    $dlg.FileName = "SystemInfo-$env:COMPUTERNAME-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
    $dlg.Title    = "Save System Information Report"
    if ($dlg.ShowDialog($form) -eq 'OK') {
        try {
            Format-ReportAsText $script:currentReport | Out-File -FilePath $dlg.FileName -Encoding UTF8
            $statusLabel.Text = "Saved to $($dlg.FileName)"
        } catch {
            [System.Windows.Forms.MessageBox]::Show($form, "Couldn't save:`r`n$($_.Exception.Message)",
                "Save error", 'OK', 'Error') | Out-Null
        }
    }
})

$btnBattery.Add_Click({
    $statusLabel.Text = "Generating battery report..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $out = Join-Path $env:TEMP "battery-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').html"
        $null = powercfg /batteryreport /output $out /duration 14 2>&1
        if (Test-Path $out) {
            Start-Process $out
            $statusLabel.Text = "Battery report opened: $out"
        } else {
            [System.Windows.Forms.MessageBox]::Show($form,
                "Could not generate battery report. This machine may not have a battery.",
                "Battery Report", 'OK', 'Warning') | Out-Null
            $statusLabel.Text = "No battery report (no battery?)."
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, "Error", 'OK', 'Error') | Out-Null
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# ======================================================================
#  NETWORK SHARE HELPER  (scheduled task, runs non-elevated)
# ======================================================================
# WHY A SCHEDULED TASK:
#   Our app runs elevated (admin token). Windows UAC splits the admin token
#   from the regular-user token; the elevated token has a different network
#   identity, so SMB shares that work in Explorer (regular user) fail from
#   our elevated process regardless of cmdkey or net use.
#   A scheduled task with RunLevel = Limited runs as the current user WITHOUT
#   elevation -- exactly like Explorer -- so the NAS accepts it normally.

$script:LabelShare = '\\momo\labels'

function Copy-ToLabelShare {
    <#
      Spawns a non-elevated scheduled task to copy $LocalFile to
      \\momo\labels\$FileName. The task writes "OK" or "ERR:..." to a
      temp result file which we poll for. Returns "OK:<path>" or "ERR:<detail>".
    #>
    param([string]$LocalFile, [string]$FileName)

    $dest        = Join-Path $script:LabelShare $FileName
    $guid        = [Guid]::NewGuid().ToString('N')
    $scriptFile  = Join-Path $env:TEMP "lbl_${guid}.ps1"
    $resultFile  = Join-Path $env:TEMP "lbl_${guid}_result.txt"
    $taskName    = "SysInfoLabel_${guid}"
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name

    # Write the copy logic to a .ps1 file so we avoid any command-line
    # quoting issues with paths that contain spaces or special characters.
    $scriptContent = @"
`$src = '$($LocalFile -replace "'", "''")'
`$dst = '$($dest      -replace "'", "''")'
`$res = '$($resultFile -replace "'", "''")'
try {
    Copy-Item -LiteralPath `$src -Destination `$dst -Force -ErrorAction Stop
    'OK' | Set-Content -LiteralPath `$res -Encoding UTF8
} catch {
    ('ERR:' + `$_.Exception.Message) | Set-Content -LiteralPath `$res -Encoding UTF8
}
"@
    $scriptContent | Set-Content -LiteralPath $scriptFile -Encoding UTF8

    try {
        $action    = New-ScheduledTaskAction -Execute 'powershell.exe' `
                         -Argument "-NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$scriptFile`""
        $principal = New-ScheduledTaskPrincipal -UserId $currentUser -RunLevel Limited
        $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 1) `
                         -StartWhenAvailable
        $trigger   = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(2)

        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal `
            -Settings $settings -Trigger $trigger -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $taskName -ErrorAction Stop

        # Poll for the result file while keeping the UI responsive (max 30 s)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while ($sw.ElapsedMilliseconds -lt 30000 -and -not (Test-Path $resultFile)) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 400
        }

        if (Test-Path $resultFile) {
            $r = (Get-Content $resultFile -Raw -Encoding UTF8).Trim()
            if ($r -eq 'OK') { return "OK:$dest" }
            return $r   # already starts with "ERR:"
        }
        return 'ERR:Timed out (30 s) - verify \\momo is online and reachable from this machine'

    } catch {
        return "ERR:$($_.Exception.Message)"
    } finally {
        try { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue } catch {}
        try { Remove-Item $scriptFile, $resultFile -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# --- Print Label (Dymo 89mm x 36mm PDF) ---------------------------------
$btnLabel.Add_Click({
    $statusLabel.Text = "Generating label..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $data = Get-LabelData
        $serialPart = ''
        try { $serialPart = (Get-CimInstance Win32_BIOS).SerialNumber -replace '[^A-Za-z0-9]', '' } catch {}
        if (-not $serialPart) { $serialPart = $env:COMPUTERNAME }
        $fileName  = "Label-{0}-{1}.pdf" -f $serialPart, (Get-Date -Format 'yyyyMMdd-HHmmss')
        $desktop   = [Environment]::GetFolderPath('Desktop')
        $localFile = Join-Path $desktop $fileName

        # 1. Write PDF locally (always fast, always works)
        New-DymoLabelPdf -Path $localFile `
            -ModelLine   $data.Model `
            -SpecsLine   $data.Specs `
            -DisplayLine $data.Display `
            -GpuLine     $data.Gpu `
            -BatteryLine $data.Battery

        # 2. Open it immediately so the user does not wait for the network
        Start-Process $localFile

        # 3. Copy to network share via non-elevated scheduled task
        $statusLabel.Text = "Copying to $($script:LabelShare) (non-elevated task)..."
        [System.Windows.Forms.Application]::DoEvents()
        $result = Copy-ToLabelShare -LocalFile $localFile -FileName $fileName

        if ($result -like 'OK:*') {
            $statusLabel.Text = "Label saved: Desktop + $($result.Substring(3))"
        } else {
            $statusLabel.Text = "Label on Desktop only ($($result.Substring(4)))"
        }

    } catch {
        [System.Windows.Forms.MessageBox]::Show($form,
            "Could not generate label:`r`n$($_.Exception.Message)",
            "Print Label", 'OK', 'Error') | Out-Null
        $statusLabel.Text = "Label generation failed."
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})
# --- Show QR Code -------------------------------------------------------
$btnQR.Add_Click({
    $statusLabel.Text = "Generating QR code..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    [System.Windows.Forms.Application]::DoEvents()
    try {
        if (-not $script:currentReport) {
            throw "No report data yet. Please wait for the report to load."
        }

        # Build a compact spec string for the QR payload. Keep it short
        # so the QR code stays scannable — most Level-H QR codes max out
        # around 1800 alphanumeric characters.
        $qrLines = @()
        $wantedKeys = @(
            'Manufacturer', 'Model', 'Serial Number', 'CPU',
            'Dedicated GPU', 'Integrated GPU', 'RAM', 'Operating System',
            'Battery Health Percentage'
        )
        # Add storage rows (dynamic keys)
        $storageKeys = $script:currentReport | Where-Object { $_.Property -like 'Storage*' } |
            ForEach-Object { $_.Property }

        $allKeys = $wantedKeys + $storageKeys
        foreach ($item in $script:currentReport) {
            if ($allKeys -contains $item.Property) {
                # Flatten multiline values (RAM Slots etc.) to single line
                $val = ($item.Value -split "`r?`n")[0]
                $qrLines += "$($item.Property): $val"
            }
        }
        $qrData = $qrLines -join "`n"

        # URL-encode the payload
        Add-Type -AssemblyName System.Web
        $encoded = [System.Web.HttpUtility]::UrlEncode($qrData)

        # Fetch the QR image from qrserver.com (500x500 px, error correction H)
        $url = "https://api.qrserver.com/v1/create-qr-code/?size=400x400&ecc=M&data=$encoded"
        $statusLabel.Text = "Downloading QR code..."
        [System.Windows.Forms.Application]::DoEvents()

        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'SystemInfoTool/1.0')
        $imgBytes = $wc.DownloadData($url)
        $wc.Dispose()

        $ms  = New-Object System.IO.MemoryStream(,$imgBytes)
        $bmp = [System.Drawing.Bitmap]::FromStream($ms)

        # Build a dialog to display the QR code
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text            = "QR Code - System Specs"
        $dlg.Size            = New-Object System.Drawing.Size(460, 540)
        $dlg.StartPosition   = 'CenterParent'
        $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox     = $false
        $dlg.MinimizeBox     = $false
        $dlg.BackColor       = [System.Drawing.Color]::White

        $pb = New-Object System.Windows.Forms.PictureBox
        $pb.Image    = $bmp
        $pb.SizeMode = 'Zoom'
        $pb.Size     = New-Object System.Drawing.Size(420, 420)
        $pb.Location = New-Object System.Drawing.Point(15, 10)
        $dlg.Controls.Add($pb)

        $lbl = New-Object System.Windows.Forms.Label
        $lbl.Text      = "Scan to transfer specs to another app"
        $lbl.Font      = New-Object System.Drawing.Font('Segoe UI', 9)
        $lbl.ForeColor = [System.Drawing.Color]::Gray
        $lbl.AutoSize  = $false
        $lbl.Size      = New-Object System.Drawing.Size(420, 20)
        $lbl.Location  = New-Object System.Drawing.Point(15, 438)
        $lbl.TextAlign = 'MiddleCenter'
        $dlg.Controls.Add($lbl)

        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text     = "Close"
        $btnOk.Size     = New-Object System.Drawing.Size(100, 32)
        $btnOk.Location = New-Object System.Drawing.Point(175, 464)
        $btnOk.Font     = New-Object System.Drawing.Font('Segoe UI', 10)
        $btnOk.Add_Click({ $dlg.Close() })
        $dlg.Controls.Add($btnOk)

        $statusLabel.Text = "QR code ready."
        $dlg.ShowDialog($form) | Out-Null
        $bmp.Dispose()
        $ms.Dispose()
        $dlg.Dispose()

    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'WebClient|WebException|network|Unable to connect') {
            [System.Windows.Forms.MessageBox]::Show($form,
                "Could not reach api.qrserver.com. Check that this machine has internet access.",
                "QR Code", 'OK', 'Warning') | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show($form,
                "QR code generation failed:`r`n$msg",
                "QR Code", 'OK', 'Error') | Out-Null
        }
        $statusLabel.Text = "QR code failed."
    } finally {
        $form.Cursor = [System.Windows.Forms.Cursors]::Default
    }
})

# --- Test Speakers ------------------------------------------------------
$btnSpeakers.Add_Click({
    $btnSpeakers.Enabled = $false
    $leftWav  = Join-Path $env:TEMP ("spk-L-{0}.wav" -f ([Guid]::NewGuid().ToString('N')))
    $rightWav = Join-Path $env:TEMP ("spk-R-{0}.wav" -f ([Guid]::NewGuid().ToString('N')))
    try {
        New-PannedToneFile -Path $leftWav  -Channel Left  -Frequency 600 -DurationMs 900
        New-PannedToneFile -Path $rightWav -Channel Right -Frequency 800 -DurationMs 900

        $player = New-Object System.Media.SoundPlayer

        $statusLabel.Text = "Speaker test: playing LEFT speaker..."
        [System.Windows.Forms.Application]::DoEvents()
        $player.SoundLocation = $leftWav
        $player.Load()
        $player.PlaySync()

        Start-Sleep -Milliseconds 350

        $statusLabel.Text = "Speaker test: playing RIGHT speaker..."
        [System.Windows.Forms.Application]::DoEvents()
        $player.SoundLocation = $rightWav
        $player.Load()
        $player.PlaySync()

        $statusLabel.Text = "Speaker test complete."
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form, "Speaker test failed:`r`n$($_.Exception.Message)",
            "Speaker Test", 'OK', 'Error') | Out-Null
        $statusLabel.Text = "Speaker test failed."
    } finally {
        Remove-Item $leftWav, $rightWav -ErrorAction SilentlyContinue
        $btnSpeakers.Enabled = $true
    }
})

# --- Test Camera --------------------------------------------------------
$btnCamera.Add_Click({
    $statusLabel.Text = "Opening Camera app..."
    try {
        Start-Process "microsoft.windows.camera:" -ErrorAction Stop
        $statusLabel.Text = "Camera app launched."
    } catch {
        try {
            Start-Process "explorer.exe" "shell:AppsFolder\Microsoft.WindowsCamera_8wekyb3d8bbwe!App" -ErrorAction Stop
            $statusLabel.Text = "Camera app launched."
        } catch {
            [System.Windows.Forms.MessageBox]::Show($form,
                "Could not launch the Camera app. Make sure it is installed (Microsoft Store > Camera).`r`n`r`n$($_.Exception.Message)",
                "Camera", 'OK', 'Warning') | Out-Null
            $statusLabel.Text = "Camera app not available."
        }
    }
})

# --- Test Keyboard (kb.exe) --------------------------------------------
$btnKeyboard.Add_Click({
    $statusLabel.Text = "Launching keyboard tester (kb.exe)..."
    $kbExe = Join-Path $script:AppDir 'kb.exe'
    try {
        if (Test-Path $kbExe) {
            Start-Process $kbExe -ErrorAction Stop
            $statusLabel.Text = "kb.exe launched."
        } else {
            Start-Process 'kb.exe' -ErrorAction Stop
            $statusLabel.Text = "kb.exe launched (from PATH)."
        }
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form,
            "Could not launch kb.exe.`r`n`r`nLooked in: $script:AppDir`r`nAlso tried PATH.`r`n`r`n$($_.Exception.Message)",
            "Keyboard Test", 'OK', 'Warning') | Out-Null
        $statusLabel.Text = "kb.exe not found."
    }
})

$btnClose.Add_Click({ $form.Close() })

$form.Add_Shown({ Populate-Grid })

[void]$form.ShowDialog()
$form.Dispose()