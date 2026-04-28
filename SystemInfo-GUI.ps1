<#
.SYNOPSIS
    Windows GUI for the system information report.

.NOTES
    To convert this to a standalone .exe (no PowerShell window):
        Install-Module ps2exe -Scope CurrentUser
        Invoke-ps2exe .\SystemInfo-GUI.ps1 .\SystemInfo.exe -noConsole
#>

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
    <# Returns an int 0-100, or $null if unknown. Health = 100 - Wear%. #>
    param($PhysicalDisk)
    try {
        $rel = $PhysicalDisk | Get-StorageReliabilityCounter -ErrorAction Stop
        if ($rel -and $null -ne $rel.Wear) {
            return [Math]::Max(0, [Math]::Min(100, 100 - [int]$rel.Wear))
        }
    } catch { }
    return $null
}

function Get-SystemReport {
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

                $health = Get-DiskHealthPercent $d
                $highlight = $false
                if ($null -ne $health) {
                    $healthStr = "Health: $health%"
                    if ($d.MediaType -eq 'SSD' -and $health -lt 70) { $highlight = $true }
                } else {
                    $healthStr = "Health: $($d.HealthStatus)"
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

    _Add 'Operating System' (Get-Safe {
        $o = Get-CimInstance Win32_OperatingSystem
        $caption = $o.Caption.Trim()
        if ($o.BuildNumber -ge 22000 -and $caption -notmatch '11') { $caption = $caption -replace 'Windows 10', 'Windows 11' }
        "{0} (Version {1}, Build {2})" -f $caption, $o.Version, $o.BuildNumber
    })

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
        $bw.Write([uint32]16)                                    # fmt chunk size
        $bw.Write([uint16]1)                                     # PCM
        $bw.Write([uint16]$channels)
        $bw.Write([uint32]$sampleRate)
        $bw.Write([uint32]($sampleRate * $channels * 2))         # byte rate
        $bw.Write([uint16]($channels * 2))                       # block align
        $bw.Write([uint16]$bitsPerSample)
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
        $bw.Write([uint32]$dataSize)

        $amp = 16000
        $twoPiF = 2 * [Math]::PI * $Frequency
        $fadeSamples = [int]($sampleRate * 0.025)  # 25 ms fade in/out

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
#  FORM
# ======================================================================
$baseFont   = New-Object System.Drawing.Font('Segoe UI', 10.5)
$titleFont  = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$headerFont = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$propFont   = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$valFont    = New-Object System.Drawing.Font('Consolas', 10.5)

$form = New-Object System.Windows.Forms.Form
$form.Text          = "System Information"
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
$btnSpeakers = New-ActionButton "Test Speakers"
$btnCamera   = New-ActionButton "Test Camera"
$btnKeyboard = New-ActionButton "Test Keyboard"
$btnClose    = New-ActionButton "Close"
$buttons.Controls.AddRange(@($btnRefresh, $btnCopy, $btnSave, $btnBattery, $btnSpeakers, $btnCamera, $btnKeyboard, $btnClose))

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
                # Red highlight for unhealthy disks
                $bg = [System.Drawing.Color]::FromArgb(232, 90, 90)
                $fg = [System.Drawing.Color]::White
                $grid.Rows[$rowIndex].DefaultCellStyle.BackColor         = $bg
                $grid.Rows[$rowIndex].DefaultCellStyle.ForeColor         = $fg
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
        # Fallback: try the legacy executable name
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
            # Try PATH lookup as a fallback
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