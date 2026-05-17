<#
.SYNOPSIS
    Windows GUI for the system information report.

.DESCRIPTION
    Starts elevated automatically (UAC prompt on launch). Admin rights are
    needed to read SMART/wear data for SSD health.

    Label printing uses QZ Tray (https://qz.io) running on a shared host.
    Run Generate-QzCert.ps1 once to create the signing credentials, then
    paste the values into the two constants near the top of this file and
    recompile.

.NOTES
    To convert this to a standalone .exe (no PowerShell window):
        Install-Module ps2exe -Scope CurrentUser
        Invoke-ps2exe .\SystemInfo-GUI.ps1 .\SystemInfo.exe -noConsole -requireAdmin
#>

# ── Auto-elevate ──────────────────────────────────────────────────────────────
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
            Start-Process -FilePath $_exePath -Verb RunAs | Out-Null
            exit
        } else {
            $_scriptPath = $null
            if ($PSCommandPath)                   { $_scriptPath = $PSCommandPath }
            elseif ($MyInvocation.MyCommand.Path) { $_scriptPath = $MyInvocation.MyCommand.Path }

            if ($_scriptPath) {
                Start-Process -FilePath 'powershell.exe' `
                    -ArgumentList @('-NoProfile','-NonInteractive','-WindowStyle','Hidden',
                                    '-ExecutionPolicy','Bypass','-File',"`"$_scriptPath`"") `
                    -Verb RunAs -WindowStyle Hidden | Out-Null
                exit
            }
        }
    } catch {
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

# ── AppDir detection (works for .ps1 and ps2exe .exe) ─────────────────────────
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

# ══════════════════════════════════════════════════════════════════════════════
#  QZ TRAY CERTIFICATE  (QZ Tray Demo Cert — generated on the QZ Tray host via
#  Site Manager > + > Create New, which installs override.crt AND registers the
#  cert in QZ Tray's runtime trust store. Fingerprint: f2b7583d...420eccf8.
#  Subject: 'QZ Tray Demo Cert' / O='QZ Industries, LLC'. 2048-bit RSA, PKCS#8.)
# ══════════════════════════════════════════════════════════════════════════════
$script:EmbeddedCertPem = @'
-----BEGIN CERTIFICATE-----
MIIECzCCAvOgAwIBAgIGAZ40pFf6MA0GCSqGSIb3DQEBCwUAMIGiMQswCQYDVQQG
EwJVUzELMAkGA1UECAwCTlkxEjAQBgNVBAcMCUNhbmFzdG90YTEbMBkGA1UECgwS
UVogSW5kdXN0cmllcywgTExDMRswGQYDVQQLDBJRWiBJbmR1c3RyaWVzLCBMTEMx
HDAaBgkqhkiG9w0BCQEWDXN1cHBvcnRAcXouaW8xGjAYBgNVBAMMEVFaIFRyYXkg
RGVtbyBDZXJ0MB4XDTI2MDUxNjA2MzQwNloXDTQ2MDUxNjA2MzQwNlowgaIxCzAJ
BgNVBAYTAlVTMQswCQYDVQQIDAJOWTESMBAGA1UEBwwJQ2FuYXN0b3RhMRswGQYD
VQQKDBJRWiBJbmR1c3RyaWVzLCBMTEMxGzAZBgNVBAsMElFaIEluZHVzdHJpZXMs
IExMQzEcMBoGCSqGSIb3DQEJARYNc3VwcG9ydEBxei5pbzEaMBgGA1UEAwwRUVog
VHJheSBEZW1vIENlcnQwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDH
x51c97jJdpAcODfK8i1a+U1rLM06U/rH1TTjZSFafAO65/9FDJph+/lTeUy7327S
Jae2WngFbdFeyjBz1B8h/Gow0VLJ59n6hliAhHGssSu1Bd8iQW/1+HsHwi8yWkHq
dvtOZmQEaFcmr8ZfS3JSmW8oeLaJzlDMsiH9NBLjhAPy50NWiq0QsYHaWniPmaEh
DRAk2t696oTbUcosZ6sBKfn7bkVRAvBZlwJ9IoUeOIwrEypIjJoihoInBjtVkSjR
Q5XP4VbU2KSFYITotaNaJbWMcr9Ct6brPAPc+KSLtFLOdyJGyuslHrj+jJ3/ppGP
VnltZ1/tC3jThH0VDe/JAgMBAAGjRTBDMBIGA1UdEwEB/wQIMAYBAf8CAQEwDgYD
VR0PAQH/BAQDAgEGMB0GA1UdDgQWBBQUVbyfPij7g/7ZwODM7XOzNFVqqTANBgkq
hkiG9w0BAQsFAAOCAQEAxB7XKkEsFWCUashZQMA+zfwfL2DuAdvvzQHHP3vQYK1p
t4fU68hRZ3iL75kaVGHkYxnsxpMByaAAQ7FkLs1rhSR4e5QPPFV1y2quS2KlHT/y
Lg3KzgUDtXuDCAXpKJh5nCfLWnPmxynhXT9FdprqKwGq0S5EKl2wVVi78JzxI+Di
0Iv6yZPV9ESZoHP5mlhnk1uC8+xBbO24nfqUldoHMn5Q/hMhObGJ5OPVicAkeWw2
PCVUG3iX52js//p3cJYncV3mBYuERsIks7StQ3R0pk0ILQpiQ/he+Wu1gCPkza0w
DhSlpMnguYLchrLNquF3KajOuaGSz/Z11fHbrDHfwQ==
-----END CERTIFICATE-----
'@

$script:EmbeddedKeyPem = @'
-----BEGIN PRIVATE KEY-----
MIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQDHx51c97jJdpAc
ODfK8i1a+U1rLM06U/rH1TTjZSFafAO65/9FDJph+/lTeUy7327SJae2WngFbdFe
yjBz1B8h/Gow0VLJ59n6hliAhHGssSu1Bd8iQW/1+HsHwi8yWkHqdvtOZmQEaFcm
r8ZfS3JSmW8oeLaJzlDMsiH9NBLjhAPy50NWiq0QsYHaWniPmaEhDRAk2t696oTb
UcosZ6sBKfn7bkVRAvBZlwJ9IoUeOIwrEypIjJoihoInBjtVkSjRQ5XP4VbU2KSF
YITotaNaJbWMcr9Ct6brPAPc+KSLtFLOdyJGyuslHrj+jJ3/ppGPVnltZ1/tC3jT
hH0VDe/JAgMBAAECggEAEwl1eFdut1vh7Z55yo/7PHEHLJBPWiCIhCRP7t9DJ2Er
5dKXo5fI2k9tecPUSQ7Ie6P08E58o1/MlLDFnzP2Z4GrCM3Zir3aKqJEqrJ0NpWH
aa+OjLAZoCG2b43Ue4LYRyRhXB4rp7PdoiUbzRbeZPqT+hJOqqELWAYdcQhWSHGv
5P7QF8vp9cKlieYzYbbEiSaqMwkDsAh8/MTDMGAn6vB4nfFg9z6jnSYNhlA1Fqmb
z4fFZnSHfucxbe4DF6HZaEdd+s+YC3+dDHHGA26d/8t9iGgJ0EZFcG7WJlZ4zXT0
jbeU/I8Q/odqyD9hIKZHJ5eMSIhNqvFjeLu3deyuVQKBgQDoVwsiVdeadC+CKLk/
/715UwkC+c4OYiXWEneeAB7SiZEOMoEGZvr/yMNt3ht+VgOYGCFqfSV+7cBaphMF
u1KByWwKpWrXfDrfVEvvpJQdsY3z+MzqkPCCXCbNRCU0pqn4bp+5A9Po5KqEPeOt
OQL9lvyQawbW7PwBcv5HnoNWKwKBgQDcH77lvj/5k/9Xrtpad2wSKfRWOshTiJDy
8e/xA8UAL28gZxO94mGtwZShBuoHMoN56OciiXLAD7q0JRurGjoExqG1oIojjzuR
8sdVeRFab23EH15pkURjNUGgJXJcQxZ8iOkh2KsbxBCfLwGCtYdCkFLdUrLsJtZY
qx+Yjq4r2wKBgBLYnKqYU/jPW9su+nfagsAIoD6BjNlV1MPck59ZWyawyfdg2V5v
lASTgGa1EX3Z9EiuDGfa5uO43VV9CyX33+VvNThX2qbICO58o/w4WVtfP6h+kgCk
6R1p5CvaTzpKGpdwQbx8NwA5LCu16XXvnfJ8ANimFdPxPS/Q6BdfIEApAoGAWvgT
oEZ7kd0DzWzJeFGaK/eCrpAkccEihgROMMBqDaWMu0td8T85NuGlVtbQqKDLjPof
azp6Xb0iX4hmYtO33nloIvNxozhyWeKHVl9uOH2MU1zTW7VZGdbMhC51kIN5K4Y5
Mm+kZxkj9WUrrqTufSe/1w9yOf3i30n5CMcOW7kCgYEAjXyMP+eg52pqBGYMAK+H
mCxrUy0zOdZaHkwb5f2NgprVUdIMbR2XlF+uRVrObMQlN5/uSfmInDKPsAr7/zgZ
oKDeV+hji0Yeq1f2OTcX8TRpX39xbV681tl+NDpQbxb2kXQomsWLovh+XMsU43rK
oQEn69TPWh4VXelEWByghPQ=
-----END PRIVATE KEY-----
'@

$script:SettingsPath = Join-Path $script:AppDir 'settings.json'

# ══════════════════════════════════════════════════════════════════════════════
#  SETTINGS  (persisted to settings.json alongside the exe/script)
# ══════════════════════════════════════════════════════════════════════════════
function Get-AppSettings {
    $defaults = [PSCustomObject]@{
        QzHost        = 'localhost'
        QzPort        = 8181
        UseSecureWs   = $true
        PrinterName   = 'DYMO LabelWriter 450 Turbo'
        LabelWidthMm  = 89
        LabelHeightMm = 36
        RotateLabel90 = $true
    }
    if (-not (Test-Path $script:SettingsPath)) { return $defaults }
    try {
        $s = Get-Content $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        # Fill in any keys missing from an older settings file
        foreach ($p in $defaults.PSObject.Properties) {
            if ($null -eq $s.($p.Name)) {
                Add-Member -InputObject $s -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force
            }
        }
        return $s
    } catch { return $defaults }
}

function Save-AppSettings {
    param($Settings)
    $Settings | ConvertTo-Json -Depth 3 |
        Set-Content -LiteralPath $script:SettingsPath -Encoding UTF8 -Force
}

# ══════════════════════════════════════════════════════════════════════════════
#  DATA GATHERING
# ══════════════════════════════════════════════════════════════════════════════
function Get-Safe {
    param([scriptblock]$Script, [string]$Default = 'Unknown')
    try {
        $v = & $Script
        if ($null -eq $v -or "$v".Trim() -eq '') { return $Default }
        return $v
    } catch { return $Default }
}

# DEVPKEY property IDs from pciprop.h
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
            $desc  = "PCIe $($script:PcieGenMap[[int]$maxSpeed]) x$maxWidth"
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
    param($PhysicalDisk)
    try {
        $rel = $PhysicalDisk | Get-StorageReliabilityCounter -ErrorAction Stop
        if ($rel -and $null -ne $rel.Wear) {
            return [Math]::Max(0, [Math]::Min(100, 100 - [int]$rel.Wear))
        }
    } catch { }
    try {
        $rel2 = Get-CimInstance -Namespace root\Microsoft\Windows\Storage `
            -ClassName MSFT_StorageReliabilityCounter -ErrorAction Stop |
            Where-Object { $_.DeviceId -eq $PhysicalDisk.DeviceId } | Select-Object -First 1
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
    $portable = @(8, 9, 10, 11, 12, 14, 30, 31, 32)
    try {
        $enc = Get-CimInstance -ClassName Win32_SystemEnclosure -ErrorAction Stop
        foreach ($e in $enc) {
            foreach ($t in $e.ChassisTypes) {
                if ($portable -contains [int]$t) { return $true }
            }
        }
    } catch { }
    try {
        $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
        if ($bat) { return $true }
    } catch { }
    return $false
}

function Get-WindowsActivationStatus {
    try {
        $q   = "SELECT LicenseStatus FROM SoftwareLicensingProduct " +
               "WHERE ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' " +
               "AND PartialProductKey IS NOT NULL"
        $lic = Get-CimInstance -Query $q -ErrorAction Stop | Select-Object -First 1
        if (-not $lic) { return 'Not activated' }
        switch ([int]$lic.LicenseStatus) {
            1 { 'Activated' }          0 { 'Unlicensed' }
            2 { 'Initial grace' }      3 { 'Additional grace' }
            4 { 'Non-genuine grace' }  5 { 'Notification (not activated)' }
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
            $m = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction Stop |
                Select-Object -First 1
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
                $best  = $modes | ForEach-Object {
                    $_.MonitorSourceModes |
                        Sort-Object { $_.HorizontalActivePixels * $_.VerticalActivePixels } -Descending |
                        Select-Object -First 1
                } | Sort-Object { $_.HorizontalActivePixels * $_.VerticalActivePixels } -Descending |
                    Select-Object -First 1
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

    # Storage: one row per physical disk
    try {
        $physDisks = Get-PhysicalDisk -ErrorAction SilentlyContinue | Sort-Object DeviceId
        if (-not $physDisks) { _Add 'Storage' 'Unknown' }
        else {
            $w32Map = @{}
            Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue |
                ForEach-Object { $w32Map[[int]$_.Index] = $_ }

            foreach ($d in $physDisks) {
                $sizeGB   = [Math]::Round($d.Size / 1GB, 0)
                $model    = if ($d.FriendlyName) { $d.FriendlyName.Trim() } else { 'Unknown disk' }
                $typeDesc = ''
                switch ($d.MediaType) {
                    'SSD' {
                        switch ($d.BusType) {
                            'NVMe' {
                                $w32  = $w32Map[[int]$d.DeviceId]
                                $pcie = if ($w32) { Get-PcieLinkForNvme -DiskPnpId $w32.PNPDeviceID } else { $null }
                                $typeDesc = if ($pcie) { "NVMe SSD ($pcie)" } else { 'NVMe SSD' }
                            }
                            'SATA'  { $typeDesc = 'SATA SSD' }
                            'USB'   { $typeDesc = 'USB SSD'  }
                            'SCSI'  { $typeDesc = 'SCSI SSD' }
                            'RAID'  { $typeDesc = 'RAID SSD' }
                            default { $typeDesc = "$($d.BusType) SSD" }
                        }
                    }
                    'HDD' {
                        switch ($d.BusType) {
                            'SATA'  { $typeDesc = 'SATA HDD' }
                            'USB'   { $typeDesc = 'USB HDD'  }
                            default { $typeDesc = "$($d.BusType) HDD" }
                        }
                    }
                    default { $typeDesc = "$($d.BusType) $($d.MediaType)" }
                }
                $health    = Get-DiskHealthPercent $d
                $highlight = $false
                if ($null -ne $health) {
                    $healthStr = "Health: $health%"
                    if ($d.MediaType -eq 'SSD' -and $health -lt 70) { $highlight = $true }
                } else {
                    $healthStr = "Health: N/A"
                }
                _Add "Storage (Disk $($d.DeviceId))" "$model -- $sizeGB GB -- $typeDesc -- $healthStr" -Highlight:$highlight
            }
        }
    } catch { _Add 'Storage' "Error: $($_.Exception.Message)" }

    _Add 'RAM' (Get-Safe { "{0:N0} GB" -f [Math]::Round($cs.TotalPhysicalMemory / 1GB, 0) })

    _Add 'RAM Slots' (Get-Safe {
        $array      = Get-CimInstance Win32_PhysicalMemoryArray | Select-Object -First 1
        $totalSlots = if ($array) { [int]$array.MemoryDevices } else { 0 }
        $modules    = Get-CimInstance Win32_PhysicalMemory | Sort-Object DeviceLocator
        $populated  = @($modules).Count
        $looksSoldered = $false
        foreach ($m in $modules) {
            if ($m.FormFactor -eq 11 -or $m.DeviceLocator -match 'onboard|soldered|system\s*board') {
                $looksSoldered = $true; break
            }
        }
        $typeMap = @{20='DDR';21='DDR2';24='DDR3';26='DDR4';34='DDR5';27='FBD2';
                     30='LPDDR';31='LPDDR2';32='LPDDR3';33='LPDDR4';35='LPDDR5'}
        $formMap = @{8='DIMM';11='Row-of-chips (soldered)';12='SODIMM';13='SRIMM';15='FB-DIMM'}
        $slotLines = foreach ($m in $modules) {
            $sizeGB = [Math]::Round($m.Capacity / 1GB, 0)
            $type   = if ($typeMap.ContainsKey([int]$m.SMBIOSMemoryType)) { $typeMap[[int]$m.SMBIOSMemoryType] } else { "Type$($m.SMBIOSMemoryType)" }
            $form   = if ($formMap.ContainsKey([int]$m.FormFactor))       { $formMap[[int]$m.FormFactor] }       else { "Form$($m.FormFactor)" }
            $speed  = if ($m.ConfiguredClockSpeed) { "$($m.ConfiguredClockSpeed) MT/s" } elseif ($m.Speed) { "$($m.Speed) MT/s" } else { '' }
            $loc    = if ($m.DeviceLocator) { $m.DeviceLocator.Trim() } else { 'Slot?' }
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
                ($_.PhysicalMediaType -eq 'Native 802.11' -or
                 $_.InterfaceDescription -match 'Wi-?Fi|Wireless|WLAN|802\.11') -and
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
        if     ($radioTypes -match '802\.11be') { $gen = 'Wi-Fi 7 (802.11be)'   }
        elseif ($radioTypes -match '802\.11ax') { $gen = 'Wi-Fi 6/6E (802.11ax)' }
        elseif ($radioTypes -match '802\.11ac') { $gen = 'Wi-Fi 5 (802.11ac)'   }
        elseif ($radioTypes -match '802\.11n')  { $gen = 'Wi-Fi 4 (802.11n)'    }
        "$gen -- $($adapter.InterfaceDescription)"
    })

    _Add 'Bluetooth' (Get-Safe {
        $bt = Get-PnpDevice -Class Bluetooth -PresentOnly -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'OK' -and $_.FriendlyName -match 'Bluetooth' -and
                           $_.FriendlyName -notmatch 'Enumerator' } |
            Select-Object -First 1
        if (-not $bt) { return 'No Bluetooth adapter found' }
        $lmp = $null
        try {
            $prop = Get-PnpDeviceProperty -InstanceId $bt.InstanceId -KeyName $script:PKEY_BtLmp -ErrorAction Stop
            if ($null -ne $prop.Data) { $lmp = [int]$prop.Data }
        } catch {}
        $btVer = switch ($lmp) {
            0  {'Bluetooth 1.0b'}        1  {'Bluetooth 1.1'}           2  {'Bluetooth 1.2'}
            3  {'Bluetooth 2.0 + EDR'}   4  {'Bluetooth 2.1 + EDR'}    5  {'Bluetooth 3.0 + HS'}
            6  {'Bluetooth 4.0'}         7  {'Bluetooth 4.1'}           8  {'Bluetooth 4.2'}
            9  {'Bluetooth 5.0'}         10 {'Bluetooth 5.1'}           11 {'Bluetooth 5.2'}
            12 {'Bluetooth 5.3'}         13 {'Bluetooth 5.4'}
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
        $o       = Get-CimInstance Win32_OperatingSystem
        $caption = $o.Caption.Trim()
        if ($o.BuildNumber -ge 22000 -and $caption -notmatch '11') {
            $caption = $caption -replace 'Windows 10', 'Windows 11'
        }
        $activation = Get-WindowsActivationStatus
        "{0} (Version {1}, Build {2}) -- {3}" -f $caption, $o.Version, $o.BuildNumber, $activation
    })

    if ($script:IsLaptop) {
        _Add 'Battery Health Percentage' (Get-Safe {
            $full   = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop
            $static = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData         -ErrorAction Stop
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

# ══════════════════════════════════════════════════════════════════════════════
#  AUDIO  (panned tone generator for speaker test)
# ══════════════════════════════════════════════════════════════════════════════
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
        $bw.Write([uint32]16); $bw.Write([uint16]1)
        $bw.Write([uint16]$channels); $bw.Write([uint32]$sampleRate)
        $bw.Write([uint32]($sampleRate * $channels * 2))
        $bw.Write([uint16]($channels * 2)); $bw.Write([uint16]$bitsPerSample)
        $bw.Write([System.Text.Encoding]::ASCII.GetBytes('data'))
        $bw.Write([uint32]$dataSize)
        $amp = 16000; $twoPiF = 2 * [Math]::PI * $Frequency
        $fadeSamples = [int]($sampleRate * 0.025)
        for ($i = 0; $i -lt $totalSamples; $i++) {
            $env = 1.0
            if ($i -lt $fadeSamples)                     { $env = $i / $fadeSamples }
            elseif ($i -gt $totalSamples - $fadeSamples) { $env = ($totalSamples - $i) / $fadeSamples }
            $val = [int16]($amp * $env * [Math]::Sin($twoPiF * $i / $sampleRate)); $silence = [int16]0
            switch ($Channel) {
                'Left'  { $bw.Write($val);    $bw.Write($silence) }
                'Right' { $bw.Write($silence); $bw.Write($val) }
                'Both'  { $bw.Write($val);    $bw.Write($val) }
            }
        }
    } finally { $bw.Close(); $fs.Close() }
}

# ══════════════════════════════════════════════════════════════════════════════
#  LABEL DATA  (gather fields for printing)
# ══════════════════════════════════════════════════════════════════════════════
function Get-ShortCpuName {
    param([string]$Full)
    if (-not $Full) { return 'CPU' }
    if ($Full -match '\b(i\d-\d{3,5}\w*)\b')                      { return $matches[1] }
    if ($Full -match '\b(Core\s*Ultra\s*\d+\s*\d{3}\w*)\b')       { return $matches[1] }
    if ($Full -match '\b(Xeon\s+\S+)\b')                          { return $matches[1] }
    if ($Full -match '\b(Ryzen\s+\d(?:\s+PRO)?\s+\d{3,4}\w*)\b')  { return $matches[1] }
    $clean = $Full -replace 'Intel\(R\)|Core\(TM\)|AMD|\(R\)|\(TM\)|CPU|Processor|@.*$|\d+(?:\.\d+)?\s*GHz', ''
    return ($clean -replace '\s+', ' ').Trim()
}

function Get-LabelStorageSummary {
    $disks = Get-PhysicalDisk -ErrorAction SilentlyContinue | Where-Object { $_.BusType -ne 'USB' }
    if (-not $disks) { return 'Storage Unknown' }
    $ssdBytes   = ($disks | Where-Object MediaType -eq 'SSD' | Measure-Object Size -Sum).Sum
    $hddBytes   = ($disks | Where-Object MediaType -eq 'HDD' | Measure-Object Size -Sum).Sum
    $otherBytes = ($disks | Where-Object { $_.MediaType -ne 'SSD' -and $_.MediaType -ne 'HDD' } | Measure-Object Size -Sum).Sum
    function _Pretty([Int64]$bytes) {
        if (-not $bytes) { return $null }
        $gib = $bytes / 1GB
        if     ($gib -lt 100)   { '{0:0}GB'  -f $gib }
        elseif ($gib -lt 200)   { '128GB' }   elseif ($gib -lt 350)   { '256GB' }
        elseif ($gib -lt 700)   { '512GB' }   elseif ($gib -lt 1400)  { '1TB'   }
        elseif ($gib -lt 2700)  { '2TB'   }   elseif ($gib -lt 5500)  { '4TB'   }
        elseif ($gib -lt 11000) { '8TB'   }   elseif ($gib -lt 22000) { '16TB'  }
        else                    { '{0:0}TB' -f ($gib / 1024) }
    }
    $parts = @()
    if ($ssdBytes)   { $parts += "$(_Pretty $ssdBytes) SSD"     }
    if ($hddBytes)   { $parts += "$(_Pretty $hddBytes) HDD"     }
    if ($otherBytes) { $parts += "$(_Pretty $otherBytes) Storage" }
    if (-not $parts) { return 'Storage Unknown' }
    return ($parts -join ' + ')
}

function Get-LabelDisplaySummary {
    $sizeStr = ''; $resStr = ''
    try {
        $m = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction Stop |
            Select-Object -First 1
        if ($m -and $m.MaxHorizontalImageSize -and $m.MaxVerticalImageSize) {
            $wCm = [double]$m.MaxHorizontalImageSize; $hCm = [double]$m.MaxVerticalImageSize
            $sizeStr = '{0:N1}"' -f ([Math]::Sqrt(($wCm*$wCm)+($hCm*$hCm)) / 2.54)
        }
    } catch {}
    try {
        $modes = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes -ErrorAction Stop
        $best  = $modes | ForEach-Object {
            $_.MonitorSourceModes |
                Sort-Object { $_.HorizontalActivePixels * $_.VerticalActivePixels } -Descending |
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
    $touchStr = if ($touch) { ' touchscreen' } else { '' }
    $parts = @($sizeStr, $resStr) | Where-Object { $_ }
    if (-not $parts) { return 'Display Unknown' }
    return (($parts -join ' ') + $touchStr).Trim()
}

function Get-LabelGpuSummary {
    param([string]$DedicatedGpuFull)
    if (-not $DedicatedGpuFull -or $DedicatedGpuFull -eq 'None') { return $null }
    $s = $DedicatedGpuFull -replace '\([^)]+\)', '' -replace '^\s*NVIDIA\s+', '' -replace '\s+', ' '
    return $s.Trim()
}

function Get-LabelBatterySummary {
    try {
        $full   = Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction Stop
        $static = Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData         -ErrorAction Stop
        if ($full -and $static -and $static.DesignedCapacity -gt 0) {
            $fullCap   = ($full   | Measure-Object FullChargedCapacity -Sum).Sum
            $designCap = ($static | Measure-Object DesignedCapacity    -Sum).Sum
            return "Battery: $([Math]::Round(($fullCap / $designCap) * 100, 0))%"
        }
    } catch {}
    return $null
}

function Get-LabelData {
    $cs       = Get-CimInstance Win32_ComputerSystem
    $cpuFull  = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
    $isLaptop = Test-IsLaptop
    $modelLine = ''
    try {
        $cs2 = Get-CimInstance Win32_ComputerSystemProduct
        if ($cs2.Vendor -match 'LENOVO' -and $cs2.Version) { $modelLine = $cs2.Version }
    } catch {}
    if (-not $modelLine) { $modelLine = $cs.Model }
    $modelLine = ($modelLine -replace '\s+', ' ').Trim()
    $ramGB     = [Math]::Round($cs.TotalPhysicalMemory / 1GB, 0)
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
    [PSCustomObject]@{
        Model   = $modelLine
        Specs   = "$(Get-ShortCpuName $cpuFull) / ${ramGB}GB RAM / $(Get-LabelStorageSummary)"
        Display = if ($isLaptop) { Get-LabelDisplaySummary  } else { $null }
        Gpu     = Get-LabelGpuSummary $dedicated
        Battery = if ($isLaptop) { Get-LabelBatterySummary  } else { $null }
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  LABEL BITMAP  (rendered via System.Drawing — bypasses QZ Tray HTML engine)
# ══════════════════════════════════════════════════════════════════════════════
function New-LabelBitmap {
    <#
      Renders the label as a 300-DPI PNG bitmap and returns it as a Base64
      string ready for QZ Tray's pixel/image/base64 print format.
      Using System.Drawing here means we never rely on QZ Tray's Java WebView
      renderer, which can silently fail on some Windows configurations.

      The bitmap is always drawn in LANDSCAPE orientation (LabelWidthMm wide ×
      LabelHeightMm tall) so each text line gets the full LabelWidthMm of
      horizontal room — important for long spec strings.

      When $Settings.RotateLabel90 is true, the finished bitmap is rotated
      90° clockwise into a portrait orientation (LabelHeightMm × LabelWidthMm)
      before encoding. This is needed when the printer driver expects the
      label paper in portrait — common for DYMO 99017-style file folder
      labels where the driver's natural orientation is 12mm × 50mm.
      Invoke-QzPrint swaps width/height in the print params to match.
    #>
    param($LabelData, [string]$Notes, $Settings)

    $dpi = 300

    # ALWAYS draw in landscape: text lines run across the long dimension
    # (LabelWidthMm) and stack down the short dimension (LabelHeightMm).
    $wPx = [int]($Settings.LabelWidthMm  / 25.4 * $dpi)
    $hPx = [int]($Settings.LabelHeightMm / 25.4 * $dpi)

    # Collect content lines
    $bodyLines = @($LabelData.Specs)
    if ($LabelData.Display) { $bodyLines += $LabelData.Display }
    if ($LabelData.Gpu)     { $bodyLines += $LabelData.Gpu }
    if ($LabelData.Battery) { $bodyLines += $LabelData.Battery }

    $noteLines = @()
    if ($Notes -and $Notes.Trim()) {
        $noteLines = ($Notes -split "`r?`n") | Where-Object { $_.Trim() } | Select-Object -First 3
    }
    $hasNotes = $noteLines.Count -gt 0

    # Font sizes in points — scale down if many lines
    $totalLines = 1 + $bodyLines.Count + $(if ($hasNotes) { $noteLines.Count + 1 } else { 0 })
    if     ($totalLines -le 5) { $mPt = 10;  $bPt = 8;   $nPt = 7   }
    elseif ($totalLines -le 7) { $mPt = 9;   $bPt = 7.5; $nPt = 6.5 }
    else                       { $mPt = 8;   $bPt = 7;   $nPt = 6   }

    $bmp = New-Object System.Drawing.Bitmap($wPx, $hPx)
    $bmp.SetResolution($dpi, $dpi)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.Clear([System.Drawing.Color]::White)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAlias

    try {
        $fModel = New-Object System.Drawing.Font('Arial', $mPt, ([System.Drawing.FontStyle]::Bold),    [System.Drawing.GraphicsUnit]::Point)
        $fBody  = New-Object System.Drawing.Font('Arial', $bPt, ([System.Drawing.FontStyle]::Regular), [System.Drawing.GraphicsUnit]::Point)
        $fNotes = New-Object System.Drawing.Font('Arial', $nPt, ([System.Drawing.FontStyle]::Italic),  [System.Drawing.GraphicsUnit]::Point)
        $brush  = [System.Drawing.Brushes]::Black
        $sfmt   = New-Object System.Drawing.StringFormat
        $sfmt.Trimming    = [System.Drawing.StringTrimming]::EllipsisCharacter
        $sfmt.FormatFlags = [System.Drawing.StringFormatFlags]::NoWrap

        try {
            $padX = [Math]::Max(4, [int]($wPx * 0.02))
            $padY = [Math]::Max(3, [int]($hPx * 0.05))
            $cw   = $wPx - 2 * $padX
            $cy   = $padY

            # ── Model line (bold) ─────────────────────────────────────────────
            $mH = $fModel.GetHeight($g)
            $g.DrawString($LabelData.Model, $fModel, $brush,
                [System.Drawing.RectangleF]::new($padX, $cy, $cw, $mH * 1.3), $sfmt)
            $cy += [int]($mH * 1.15)

            # ── Spec / detail lines ───────────────────────────────────────────
            $bH = $fBody.GetHeight($g)
            foreach ($line in $bodyLines) {
                if ($cy + $bH -gt $hPx - $padY) { break }
                $g.DrawString($line, $fBody, $brush,
                    [System.Drawing.RectangleF]::new($padX, $cy, $cw, $bH * 1.3), $sfmt)
                $cy += [int]($bH * 1.15)
            }

            # ── Notes (separator + italic lines) ─────────────────────────────
            $nH = $fNotes.GetHeight($g)
            if ($hasNotes -and $cy + 6 + $nH -le $hPx - $padY) {
                $cy += 3
                $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::Black, 1)
                $g.DrawLine($pen, $padX, $cy, ($padX + $cw), $cy)
                $pen.Dispose()
                $cy += 4

                foreach ($nl in $noteLines) {
                    if ($cy + $nH -gt $hPx - $padY) { break }
                    $g.DrawString($nl, $fNotes, $brush,
                        [System.Drawing.RectangleF]::new($padX, $cy, $cw, $nH * 1.3), $sfmt)
                    $cy += [int]($nH * 1.15)
                }
            }
        } finally {
            $fModel.Dispose(); $fBody.Dispose(); $fNotes.Dispose(); $sfmt.Dispose()
        }
    } finally {
        $g.Dispose()
    }

    # When RotateLabel90 is true, rotate the finished landscape bitmap 90°
    # clockwise into portrait. Use this when the printer driver expects
    # portrait-oriented paper (typical for DYMO 99017 file folder labels).
    # Invoke-QzPrint swaps width/height in the print params to match.
    if ($Settings.RotateLabel90 -eq $true) {
        $bmp.RotateFlip([System.Drawing.RotateFlipType]::Rotate90FlipNone)
    }

    # Save a copy of the final bitmap to disk for diagnostic inspection. The
    # file is overwritten each print and is useful when the printed output
    # doesn't match expectations — open it to see what was actually sent.
    try {
        $previewPath = Join-Path $script:AppDir 'label-preview.png'
        $bmp.Save($previewPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } catch {}

    # Encode bitmap as Base64 PNG
    $ms = New-Object System.IO.MemoryStream
    try {
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $b64 = [Convert]::ToBase64String($ms.ToArray())
    } finally {
        $bmp.Dispose(); $ms.Dispose()
    }
    return $b64
}

# ══════════════════════════════════════════════════════════════════════════════
#  QZ TRAY  (WebSocket client + RSA signing)
# ══════════════════════════════════════════════════════════════════════════════
function Get-QzCredentials {
    <#
      Loads the certificate and private key from the embedded PEM strings.
      Uses Windows CNG (CngKey.Import) to handle PKCS#8 keys — avoids the
      .NET 7 vs .NET Framework PFX encryption incompatibility entirely.
    #>
    if ($script:EmbeddedCertPem -like '*REPLACE_*') {
        throw ("QZ Tray certificate not configured.`n`n" +
               "Copy QZ_CERT and QZ_PRIVATE_KEY from the web app's app.js " +
               "into the constants at the top of this script.")
    }

    # ── Certificate (public part) ─────────────────────────────────────────────
    $certPem = $script:EmbeddedCertPem.Trim() + "`n"

    # ── Private key via Windows CNG  (PKCS#8, .NET 4.6+ / .NET 5+) ──────────
    $keyClean = ($script:EmbeddedKeyPem -replace '-----BEGIN PRIVATE KEY-----','') -replace '-----END PRIVATE KEY-----',''
    $keyClean = ($keyClean -replace "`r",'') -replace "`n",'' -replace ' ',''
    $keyBytes = [Convert]::FromBase64String($keyClean)

    try {
        $cngKey = [System.Security.Cryptography.CngKey]::Import(
                      $keyBytes,
                      [System.Security.Cryptography.CngKeyBlobFormat]::Pkcs8PrivateBlob)
        $rsaKey = New-Object System.Security.Cryptography.RSACng($cngKey)
    } catch {
        throw ("Could not import the RSA private key.`n" +
               "Ensure the key PEM is the unencrypted PKCS#8 block from app.js.`n" +
               "Detail: $($_.Exception.Message)")
    }

    return [PSCustomObject]@{ CertPem = $certPem; Rsa = $rsaKey }
}

function Wait-WSTask {
    <#
      Polls a WebSocket Task to completion while pumping WinForms messages so
      the UI stays responsive. Replaces synchronous .GetAwaiter().GetResult()
      which would block the UI thread for the duration of the I/O.

      Returns the completed task's result. Throws any task exception just like
      GetAwaiter().GetResult() would.
    #>
    param([System.Threading.Tasks.Task]$Task)
    while (-not $Task.IsCompleted) {
        [System.Windows.Forms.Application]::DoEvents()
        Start-Sleep -Milliseconds 20
    }
    # GetAwaiter().GetResult() unwraps the result and re-throws any exception
    return $Task.GetAwaiter().GetResult()
}

function Invoke-QzCall {
    <#
      Connects to QZ Tray, sends a certificate-signed call, reads responses
      until a UID-matching COMPLETE/ERROR is found, then closes.

      Uses the QZ Tray Demo Cert which is registered as a fully-trusted root
      via the Site Manager 'Create New' wizard.  No Allow/Block dialog;
      prints immediately.
    #>
    param(
        [string] $Call,
        [object] $Params,
        $Settings,
        $Credentials,
        [int]    $TimeoutMs = 6000
    )

    $scheme = if ($Settings.UseSecureWs) { 'wss' } else { 'ws' }
    $uri    = [Uri]"${scheme}://$($Settings.QzHost):$($Settings.QzPort)"

    # ── Connect ───────────────────────────────────────────────────────────────
    $ws      = New-Object System.Net.WebSockets.ClientWebSocket
    # Intentionally NOT setting an Origin header. .NET ClientWebSocket will then
    # not send one, which matches how QZ Tray's own utility clients connect.
    # Custom Origins appear to interfere with QZ Tray's signature verification path.
    $connCts = New-Object System.Threading.CancellationTokenSource(6000)
    try {
        Wait-WSTask -Task ($ws.ConnectAsync($uri, $connCts.Token)) | Out-Null
    } catch {
        $ws.Dispose(); $connCts.Dispose()
        throw ("Cannot reach QZ Tray at $uri.`n" +
               "Verify the host/port in Settings and that QZ Tray is running on the print server.")
    }
    $connCts.Dispose()

    try {
        $epoch = [DateTimeOffset]::new(1970, 1, 1, 0, 0, 0, [TimeSpan]::Zero)

        # ── Step 0: getVersion handshake (required by QZ Tray protocol) ────────
        # The qz-tray.js library always sends getVersion as the very first message
        # before certificate registration. Without it QZ Tray reports "Bad signature"
        # even when the signature is cryptographically correct, because the cert isn't
        # properly associated with the connection for subsequent verification.
        $gvUid  = [Guid]::NewGuid().ToString('N')
        $gvTs   = [long]([DateTimeOffset]::UtcNow - $epoch).TotalMilliseconds
        $gvMsg  = [ordered]@{
            call      = 'getVersion'
            timestamp = $gvTs
            uid       = $gvUid
            position  = [ordered]@{ x = 100; y = 100 }
        }
        $gvJson  = $gvMsg | ConvertTo-Json -Depth 3 -Compress
        $gvJson  = $gvJson -replace '/', '\/'
        $gvBytes = [System.Text.Encoding]::UTF8.GetBytes($gvJson)
        $gvSeg   = [ArraySegment[byte]]::new($gvBytes)
        $sendCts0 = New-Object System.Threading.CancellationTokenSource(5000)
        try   { Wait-WSTask -Task ($ws.SendAsync($gvSeg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $sendCts0.Token)) | Out-Null }
        finally { $sendCts0.Dispose() }

        # ── Step 1: Send certificate-only message (pre-register cert) ─────────
        # Certificate is sent as a SEPARATE message before any signed call.
        Start-Sleep -Milliseconds 50
        $certTs  = [long]([DateTimeOffset]::UtcNow - $epoch).TotalMilliseconds
        $certUid = [Guid]::NewGuid().ToString('N')
        $certMsg = [ordered]@{
            certificate = $Credentials.CertPem
            timestamp   = $certTs
            uid         = $certUid
            position    = [ordered]@{ x = 100; y = 100 }
        }
        $certJson  = $certMsg | ConvertTo-Json -Depth 3 -Compress
        $certJson  = $certJson -replace '/', '\/'
        $certBytes = [System.Text.Encoding]::UTF8.GetBytes($certJson)
        $certSeg   = [ArraySegment[byte]]::new($certBytes)
        $sendCts1  = New-Object System.Threading.CancellationTokenSource(5000)
        try   { Wait-WSTask -Task ($ws.SendAsync($certSeg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $sendCts1.Token)) | Out-Null }
        finally { $sendCts1.Dispose() }

        # Brief pause — gives QZ Tray time to process the cert before the call
        Start-Sleep -Milliseconds 100

        # ── Step 2: Build signed call WITHOUT embedding the certificate ────────
        $uid   = [Guid]::NewGuid().ToString('N')
        $ts    = [long]([DateTimeOffset]::UtcNow - $epoch).TotalMilliseconds

        # ── BUILD THE STRING TO SIGN ──────────────────────────────────────────
        # qz-tray.js signs SHA256-hex of JSON({call, params, timestamp}), NOT
        # the timestamp alone. Reference: qz-tray.js source —
        #   var signObj = { call: obj.call, params: obj.params, timestamp: obj.timestamp };
        #   var hashing = _qz.tools.hash(_qz.tools.stringify(signObj));
        #   hashing.then(hashed => _qz.security.callSign(hashed));
        # In 2.1+, _qz.tools.hash defaults to SHA256 producing lowercase hex.
        # The signer (SHA512withRSA / PKCS1) signs the UTF-8 bytes of that hex.
        #
        # CRITICAL: do NOT escape forward slashes in the signing JSON. QZ Tray's
        # validSignature() in PrintSocketClient.java does:
        #   copy.toString().replaceAll("\\\\/", "/")
        # i.e. it strips any \/ back to bare / BEFORE hashing. To match, we
        # must hash JSON containing bare / characters (no \/ escape). Base64
        # data is full of /'s so this matters a lot.
        $signObj = [ordered]@{
            call      = $Call
            params    = $Params
            timestamp = $ts
        }
        $signJson = $signObj | ConvertTo-Json -Depth 20 -Compress

        # SHA256 → lowercase hex (qz-tray.js convention)
        $sha256alg = [System.Security.Cryptography.SHA256]::Create()
        try {
            $signJsonBytes = [System.Text.Encoding]::UTF8.GetBytes($signJson)
            $hashBytes     = $sha256alg.ComputeHash($signJsonBytes)
        } finally { $sha256alg.Dispose() }
        $sha256Hex = -join ($hashBytes | ForEach-Object { $_.ToString('x2') })

        # Sign the hex string bytes with SHA512+RSA+PKCS1
        $toSign = [System.Text.Encoding]::UTF8.GetBytes($sha256Hex)
        if ($Credentials.Rsa -is [System.Security.Cryptography.RSACryptoServiceProvider]) {
            $sha512 = New-Object System.Security.Cryptography.SHA512CryptoServiceProvider
            $sigB64 = [Convert]::ToBase64String($Credentials.Rsa.SignData($toSign, $sha512))
            $sha512.Dispose()
        } else {
            $sigB64 = [Convert]::ToBase64String(
                $Credentials.Rsa.SignData($toSign,
                    [System.Security.Cryptography.HashAlgorithmName]::SHA512,
                    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1))
        }

        # Debug log: capture exactly what was signed so we can verify externally
        try {
            $sigDbg = "[$(Get-Date -Format 'HH:mm:ss.fff')] SIGN | signJson=$signJson | sha256Hex=$sha256Hex | sigB64=$sigB64"
            Add-Content -LiteralPath (Join-Path $script:AppDir 'qz-debug.log') -Value $sigDbg -Encoding UTF8
        } catch {}

        # Field order matches qz-tray.js exactly: call, params, signature, timestamp,
        # uid, position, signAlgorithm. Some QZ Tray parsers appear order-sensitive.
        $msg = [ordered]@{
            call          = $Call
            params        = $Params
            signature     = $sigB64
            timestamp     = $ts
            uid           = $uid
            position      = [ordered]@{ x = 100; y = 100 }
            signAlgorithm = 'SHA512'
            # certificate intentionally omitted — pre-registered above
        }
        $json    = $msg | ConvertTo-Json -Depth 10 -Compress
        # Escape forward slashes as \/ to exactly match qz-tray.js JSON output.
        # JSON spec treats both as equivalent but some parsers are strict.
        $json    = $json -replace '/', '\/'
        $txBytes = [System.Text.Encoding]::UTF8.GetBytes($json)
        $txSeg   = [ArraySegment[byte]]::new($txBytes)

        $sendCts = New-Object System.Threading.CancellationTokenSource(5000)
        try   { Wait-WSTask -Task ($ws.SendAsync($txSeg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, $sendCts.Token)) | Out-Null }
        finally { $sendCts.Dispose() }

        # ── Read until we match our UID (QZ Tray may send other frames first) ─
        # Receive loop: wait for COMPLETE/ERROR matching our UIDs (up to $TimeoutMs).
        # With proper signing in place, QZ Tray sends a COMPLETE within ~300ms
        # of receiving the print message. The OperationCanceledException catch
        # below is defensive in case QZ Tray ever drops the connection without
        # a final frame.
        $recvCts = New-Object System.Threading.CancellationTokenSource($TimeoutMs)
        $recvBuf = New-Object byte[] 65536
        try {
            while ($true) {
                $recvSeg    = [ArraySegment[byte]]::new($recvBuf)
                $recvResult = Wait-WSTask -Task ($ws.ReceiveAsync($recvSeg, $recvCts.Token))

                if ($recvResult.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    # Connection closed without ERROR — print likely succeeded
                    return ([PSCustomObject]@{
                        uid    = $uid
                        type   = 'COMPLETE'
                        result = 'Connection closed by QZ Tray after dispatch'
                    })
                }

                $responseJson = [System.Text.Encoding]::UTF8.GetString($recvBuf, 0, $recvResult.Count)

                # ── Debug log every received frame ────────────────────────────
                try {
                    $dbgLine = "[$(Get-Date -Format 'HH:mm:ss.fff')] RECV $($recvResult.Count)b | want-uid=$uid | raw=$responseJson"
                    Add-Content -LiteralPath (Join-Path $script:AppDir 'qz-debug.log') -Value $dbgLine -Encoding UTF8
                } catch {}

                try   { $resp = $responseJson | ConvertFrom-Json }
                catch { continue }   # Non-JSON frame — skip

                # Accept responses for either the print call UID or the cert pre-reg UID.
                if ($resp.uid -ne $uid -and $resp.uid -ne $certUid) { continue }

                if ($resp.PSObject.Properties['type']) {
                    if ($resp.type -eq 'ERROR') { throw "QZ Tray error: $($resp.result)" }
                    return $resp
                }

                continue   # bare UID ack — keep waiting
            }
        } catch [System.OperationCanceledException] {
            # Defensive — should not be hit during normal signed flow. If we get
            # here the print may or may not have happened; the user can retry.
            return ([PSCustomObject]@{
                uid    = $uid
                type   = 'COMPLETE'
                result = 'Dispatched (no COMPLETE response received)'
            })
        } finally {
            $recvCts.Dispose()
        }

    } finally {
        # Polite close — only attempt if the socket is still in a closeable state
        try {
            $closeable = @([System.Net.WebSockets.WebSocketState]::Open,
                           [System.Net.WebSockets.WebSocketState]::CloseReceived)
            if ($ws.State -in $closeable) {
                $closeCts = New-Object System.Threading.CancellationTokenSource(2000)
                $ws.CloseAsync([System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'Done',
                               $closeCts.Token).Wait(2500) | Out-Null
                $closeCts.Dispose()
            }
        } catch {}
        $ws.Dispose()
    }
}

function Get-QzPrinterList {
    param($Settings, $Credentials)
    $resp = Invoke-QzCall -Call 'printers.find' -Params ([ordered]@{ query = '' }) `
                          -Settings $Settings -Credentials $Credentials -TimeoutMs 8000
    if ($null -eq $resp.result) { return @() }
    return @($resp.result | ForEach-Object { "$_" })
}

function Invoke-QzPrint {
    param([string]$ImageBase64, $Settings, $Credentials)
    <#
      Send the full options structure that QZ Tray 2.2.x JS API generates.
      QZ Tray 2.2.x validates the params object and silently drops the job
      when expected fields (legacy, rasterize, spool, etc.) are absent.

      When RotateLabel90 is on, New-LabelBitmap produces a portrait-oriented
      bitmap, so we tell QZ Tray the page is portrait (swap width/height)
      to match what the printer driver expects.
    #>
    if ($Settings.RotateLabel90 -eq $true) {
        # Portrait: short dimension is width, long dimension is height
        $wIn = [Math]::Round($Settings.LabelHeightMm / 25.4, 4)
        $hIn = [Math]::Round($Settings.LabelWidthMm  / 25.4, 4)
    } else {
        # Landscape: long dimension is width, short dimension is height
        $wIn = [Math]::Round($Settings.LabelWidthMm  / 25.4, 4)
        $hIn = [Math]::Round($Settings.LabelHeightMm / 25.4, 4)
    }

    $params = [ordered]@{
        printer = [ordered]@{
            name = $Settings.PrinterName
            file = $null
            host = $null
            port = $null
        }
        options = [ordered]@{
            bounds          = $null
            colorType       = 'grayscale'
            copies          = 1
            density         = $null
            duplex          = $false
            fallbackDensity = $null
            interpolation   = 'bicubic'
            jobName         = $null
            legacy          = $false
            margins         = 0
            orientation     = $null
            paperThickness  = $null
            printerTray     = $null
            rasterize       = $true
            rotation        = 0
            scaleContent    = $true
            size            = [ordered]@{ width = $wIn; height = $hIn }
            units           = 'in'
            encoding        = $null
            spool           = [ordered]@{ size = $null }
        }
        data = @([ordered]@{
            type   = 'pixel'
            format = 'image'
            flavor = 'base64'
            data   = $ImageBase64
        })
    }
    Invoke-QzCall -Call 'print' -Params $params -Settings $Settings -Credentials $Credentials | Out-Null
}

# ══════════════════════════════════════════════════════════════════════════════
#  FORM
# ══════════════════════════════════════════════════════════════════════════════
$baseFont   = New-Object System.Drawing.Font('Segoe UI', 10.5)
$titleFont  = New-Object System.Drawing.Font('Segoe UI Semibold', 16)
$headerFont = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$propFont   = New-Object System.Drawing.Font('Segoe UI Semibold', 10.5)
$valFont    = New-Object System.Drawing.Font('Consolas', 10.5)

$form = New-Object System.Windows.Forms.Form
$form.Text          = if (Test-IsAdmin) { "System Information (Administrator)" } else { "System Information" }
$form.Size          = New-Object System.Drawing.Size(960, 760)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize   = New-Object System.Drawing.Size(740, 580)
$form.Font          = $baseFont

# ── Header ────────────────────────────────────────────────────────────────────
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

# ── Button bar ────────────────────────────────────────────────────────────────
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
$btnLabel    = New-ActionButton "Print Label"
$btnQR       = New-ActionButton "Show QR Code"
$btnSpeakers = New-ActionButton "Test Speakers"
$btnCamera   = New-ActionButton "Test Camera"
$btnKeyboard = New-ActionButton "Test Keyboard"
$btnSettings = New-ActionButton "Settings"
$btnClose    = New-ActionButton "Close"

$buttons.Controls.AddRange(@($btnRefresh, $btnCopy, $btnSave, $btnBattery, $btnLabel,
    $btnQR, $btnSpeakers, $btnCamera, $btnKeyboard, $btnSettings, $btnClose))

# ── Status strip ──────────────────────────────────────────────────────────────
$status = New-Object System.Windows.Forms.StatusStrip
$status.Font = $baseFont
$statusLabel = New-Object System.Windows.Forms.ToolStripStatusLabel
$statusLabel.Text = "Ready"
[void]$status.Items.Add($statusLabel)
$form.Controls.Add($status)

# ── Content panel: fills between header and button bar ────────────────────────
# Contains the data grid (Fill) and notes panel (Bottom).
$contentPanel = New-Object System.Windows.Forms.Panel
$contentPanel.Dock = 'Fill'
$form.Controls.Add($contentPanel)
$contentPanel.BringToFront()

# Notes panel — docked to the bottom of the content panel
$notesPanel = New-Object System.Windows.Forms.Panel
$notesPanel.Dock      = 'Bottom'
$notesPanel.Height    = 82
$notesPanel.BackColor = [System.Drawing.Color]::FromArgb(242, 244, 248)
$contentPanel.Controls.Add($notesPanel)

$notesHeaderLabel = New-Object System.Windows.Forms.Label
$notesHeaderLabel.Text      = "Notes for label:"
$notesHeaderLabel.Font      = $propFont
$notesHeaderLabel.Dock      = 'Top'
$notesHeaderLabel.Height    = 22
$notesHeaderLabel.Padding   = New-Object System.Windows.Forms.Padding(8, 0, 0, 0)
$notesHeaderLabel.TextAlign = 'MiddleLeft'
$notesPanel.Controls.Add($notesHeaderLabel)

$notesBox = New-Object System.Windows.Forms.TextBox
$notesBox.Multiline  = $true
$notesBox.ScrollBars = 'Vertical'
$notesBox.Font       = $valFont
$notesBox.Dock       = 'Fill'
$notesBox.BackColor  = [System.Drawing.Color]::White
$notesPanel.Controls.Add($notesBox)
$notesBox.BringToFront()

# ── Data grid — fills the space above the notes panel ─────────────────────────
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

$contentPanel.Controls.Add($grid)
$grid.BringToFront()

# ══════════════════════════════════════════════════════════════════════════════
#  ACTIONS
# ══════════════════════════════════════════════════════════════════════════════
$script:currentReport = $null

function Resize-FormToContent {
    if ($grid.Rows.Count -eq 0) { return }
    [System.Windows.Forms.Application]::DoEvents()
    $rowsHeight = 0
    foreach ($row in $grid.Rows) { $rowsHeight += $row.Height }
    $gridNeeded   = $rowsHeight + $grid.ColumnHeadersHeight + 4
    $chrome       = $form.Height - $form.ClientSize.Height
    $targetClient = $header.Height + $buttons.Height + $status.Height + $notesPanel.Height + $gridNeeded
    $targetForm   = $targetClient + $chrome
    $screen       = [System.Windows.Forms.Screen]::FromControl($form).WorkingArea
    $newH         = [Math]::Max($form.MinimumSize.Height, [Math]::Min($targetForm, $screen.Height - 40))
    if ($newH -ne $form.Height) {
        $top = $form.Top
        if (($top + $newH) -gt ($screen.Top + $screen.Height)) {
            $top = [Math]::Max($screen.Top, $screen.Top + $screen.Height - $newH)
        }
        $form.SetBounds($form.Left, $top, $form.Width, $newH)
    }
}

function Populate-Grid {
    $statusLabel.Text   = "Gathering system information..."
    $form.Cursor        = [System.Windows.Forms.Cursors]::WaitCursor
    $btnRefresh.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $report = Get-SystemReport
        $script:currentReport = $report
        $grid.Rows.Clear()
        foreach ($item in $report) {
            $rowIndex = $grid.Rows.Add($item.Property, $item.Value)
            if ($item.Highlight) {
                $grid.Rows[$rowIndex].DefaultCellStyle.BackColor          = [System.Drawing.Color]::FromArgb(232, 90, 90)
                $grid.Rows[$rowIndex].DefaultCellStyle.ForeColor          = [System.Drawing.Color]::White
                $grid.Rows[$rowIndex].DefaultCellStyle.SelectionBackColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
                $grid.Rows[$rowIndex].DefaultCellStyle.SelectionForeColor = [System.Drawing.Color]::White
            }
        }
        Resize-FormToContent
        $statusLabel.Text = "Ready. $($report.Count) items. Last refreshed $(Get-Date -Format 'HH:mm:ss')."
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form,
            "Error gathering information:`r`n$($_.Exception.Message)", "Error", 'OK', 'Error') | Out-Null
        $statusLabel.Text = "Error: $($_.Exception.Message)"
    } finally {
        $form.Cursor        = [System.Windows.Forms.Cursors]::Default
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

# ── Print Label via QZ Tray ───────────────────────────────────────────────────
$btnLabel.Add_Click({
    $statusLabel.Text = "Printing label..."
    $btnLabel.Enabled = $false
    [System.Windows.Forms.Application]::DoEvents()
    try {
        $settings = Get-AppSettings
        if (-not $settings.PrinterName) {
            throw "No printer configured. Open Settings to select a printer."
        }
        $creds  = Get-QzCredentials
        $data   = Get-LabelData
        $imgB64 = New-LabelBitmap -LabelData $data -Notes $notesBox.Text -Settings $settings
        Invoke-QzPrint -ImageBase64 $imgB64 -Settings $settings -Credentials $creds
        $statusLabel.Text = "Label printed to '$($settings.PrinterName)'."
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form,
            "Print failed:`r`n`r`n$($_.Exception.Message)", "Print Label", 'OK', 'Error') | Out-Null
        $statusLabel.Text = "Print failed."
    } finally {
        $btnLabel.Enabled = $true
    }
})

$btnQR.Add_Click({
    $statusLabel.Text = "Generating QR code..."
    $form.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    [System.Windows.Forms.Application]::DoEvents()
    try {
        if (-not $script:currentReport) { throw "No report data yet. Please wait for the report to load." }
        $qrLines     = @()
        $wantedKeys  = @('Manufacturer','Model','Serial Number','CPU',
                         'Dedicated GPU','Integrated GPU','RAM','Operating System','Battery Health Percentage')
        $storageKeys = $script:currentReport | Where-Object { $_.Property -like 'Storage*' } |
                           ForEach-Object { $_.Property }
        $allKeys = $wantedKeys + $storageKeys
        foreach ($item in $script:currentReport) {
            if ($allKeys -contains $item.Property) {
                $qrLines += "$($item.Property): $(($item.Value -split "`r?`n")[0])"
            }
        }
        Add-Type -AssemblyName System.Web
        $encoded  = [System.Web.HttpUtility]::UrlEncode($qrLines -join "`n")
        $url      = "https://api.qrserver.com/v1/create-qr-code/?size=400x400&ecc=M&data=$encoded"
        $statusLabel.Text = "Downloading QR code..."
        [System.Windows.Forms.Application]::DoEvents()
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'SystemInfoTool/1.0')
        $imgBytes = $wc.DownloadData($url)
        $wc.Dispose()
        $ms  = New-Object System.IO.MemoryStream(,$imgBytes)
        $bmp = [System.Drawing.Bitmap]::FromStream($ms)
        $dlg = New-Object System.Windows.Forms.Form
        $dlg.Text = "QR Code - System Specs"; $dlg.Size = New-Object System.Drawing.Size(460, 540)
        $dlg.StartPosition = 'CenterParent'; $dlg.FormBorderStyle = 'FixedDialog'
        $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false; $dlg.BackColor = [System.Drawing.Color]::White
        $pb = New-Object System.Windows.Forms.PictureBox
        $pb.Image = $bmp; $pb.SizeMode = 'Zoom'
        $pb.Size = New-Object System.Drawing.Size(420, 420); $pb.Location = New-Object System.Drawing.Point(15, 10)
        $dlg.Controls.Add($pb)
        $lbl2 = New-Object System.Windows.Forms.Label
        $lbl2.Text = "Scan to transfer specs to another app"
        $lbl2.Font = New-Object System.Drawing.Font('Segoe UI', 9)
        $lbl2.ForeColor = [System.Drawing.Color]::Gray; $lbl2.AutoSize = $false
        $lbl2.Size = New-Object System.Drawing.Size(420, 20); $lbl2.Location = New-Object System.Drawing.Point(15, 438)
        $lbl2.TextAlign = 'MiddleCenter'; $dlg.Controls.Add($lbl2)
        $btnOk = New-Object System.Windows.Forms.Button
        $btnOk.Text = "Close"; $btnOk.Size = New-Object System.Drawing.Size(100, 32)
        $btnOk.Location = New-Object System.Drawing.Point(175, 464)
        $btnOk.Font = New-Object System.Drawing.Font('Segoe UI', 10)
        $btnOk.Add_Click({ $dlg.Close() }); $dlg.Controls.Add($btnOk)
        $statusLabel.Text = "QR code ready."
        $dlg.ShowDialog($form) | Out-Null
        $bmp.Dispose(); $ms.Dispose(); $dlg.Dispose()
    } catch {
        $msg = $_.Exception.Message
        if ($msg -match 'WebClient|WebException|network|Unable to connect') {
            [System.Windows.Forms.MessageBox]::Show($form,
                "Could not reach api.qrserver.com. Check internet access.", "QR Code", 'OK', 'Warning') | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show($form, "QR code failed:`r`n$msg", "QR Code", 'OK', 'Error') | Out-Null
        }
        $statusLabel.Text = "QR code failed."
    } finally { $form.Cursor = [System.Windows.Forms.Cursors]::Default }
})

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
        $player.SoundLocation = $leftWav;  $player.Load(); $player.PlaySync()
        Start-Sleep -Milliseconds 350
        $statusLabel.Text = "Speaker test: playing RIGHT speaker..."
        [System.Windows.Forms.Application]::DoEvents()
        $player.SoundLocation = $rightWav; $player.Load(); $player.PlaySync()
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
                "Could not launch the Camera app.`r`n`r`n$($_.Exception.Message)", "Camera", 'OK', 'Warning') | Out-Null
            $statusLabel.Text = "Camera app not available."
        }
    }
})

$btnKeyboard.Add_Click({
    $kbExe = Join-Path $script:AppDir 'kb.exe'
    try {
        if (Test-Path $kbExe) { Start-Process $kbExe -ErrorAction Stop; $statusLabel.Text = "kb.exe launched." }
        else                  { Start-Process 'kb.exe' -ErrorAction Stop; $statusLabel.Text = "kb.exe launched (from PATH)." }
    } catch {
        [System.Windows.Forms.MessageBox]::Show($form,
            "Could not launch kb.exe.`r`n`r`nLooked in: $script:AppDir`r`nAlso tried PATH.`r`n`r`n$($_.Exception.Message)",
            "Keyboard Test", 'OK', 'Warning') | Out-Null
        $statusLabel.Text = "kb.exe not found."
    }
})

$btnSettings.Add_Click({ Show-SettingsDialog -Owner $form })

$btnClose.Add_Click({ $form.Close() })

# ══════════════════════════════════════════════════════════════════════════════
#  SETTINGS DIALOG
# ══════════════════════════════════════════════════════════════════════════════
function Show-SettingsDialog {
    param([System.Windows.Forms.Form]$Owner)

    $s = Get-AppSettings

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text            = 'QZ Tray Settings'
    $dlg.ClientSize      = New-Object System.Drawing.Size(420, 298)
    $dlg.StartPosition   = 'CenterParent'
    $dlg.FormBorderStyle = 'FixedDialog'
    $dlg.MaximizeBox     = $false
    $dlg.MinimizeBox     = $false
    $dlg.Font            = $baseFont

    # Helper: right-aligned row label
    function _L([string]$text, [int]$y) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $text; $l.TextAlign = 'MiddleRight'
        $l.Location = New-Object System.Drawing.Point(12, $y)
        $l.Size     = New-Object System.Drawing.Size(126, 22)
        $dlg.Controls.Add($l)
    }
    $cx = 144   # control column x

    # Row 0 — Host
    _L 'QZ Tray Host:' 14
    $txtHost = New-Object System.Windows.Forms.TextBox
    $txtHost.Text = $s.QzHost
    $txtHost.Location = New-Object System.Drawing.Point($cx, 12)
    $txtHost.Size     = New-Object System.Drawing.Size(264, 24)
    $dlg.Controls.Add($txtHost)

    # Row 1 — Port + WSS
    _L 'Port / Security:' 50
    $numPort = New-Object System.Windows.Forms.NumericUpDown
    $numPort.Location = New-Object System.Drawing.Point($cx, 48)
    $numPort.Size     = New-Object System.Drawing.Size(72, 24)
    $numPort.Minimum  = 1; $numPort.Maximum = 65535; $numPort.Value = $s.QzPort
    $chkWss = New-Object System.Windows.Forms.CheckBox
    $chkWss.Text     = 'Use WSS (TLS)'
    $chkWss.Checked  = [bool]$s.UseSecureWs
    $chkWss.Location = New-Object System.Drawing.Point(($cx + 78), 50)
    $chkWss.AutoSize = $true
    $dlg.Controls.AddRange(@($numPort, $chkWss))

    # Row 2 — Printer
    _L 'Printer:' 88
    $cbPrinter = New-Object System.Windows.Forms.ComboBox
    $cbPrinter.Text          = $s.PrinterName
    $cbPrinter.DropDownStyle = 'DropDown'
    $cbPrinter.Location      = New-Object System.Drawing.Point($cx, 86)
    $cbPrinter.Size          = New-Object System.Drawing.Size(196, 24)
    $btnList = New-Object System.Windows.Forms.Button
    $btnList.Text     = 'List...'
    $btnList.Location = New-Object System.Drawing.Point(($cx + 202), 86)
    $btnList.Size     = New-Object System.Drawing.Size(62, 26)
    $dlg.Controls.AddRange(@($cbPrinter, $btnList))

    # Row 3 — Label dimensions
    _L 'Label (W × H mm):' 126
    $numW = New-Object System.Windows.Forms.NumericUpDown
    $numW.Location = New-Object System.Drawing.Point($cx, 124)
    $numW.Size     = New-Object System.Drawing.Size(62, 24)
    $numW.Minimum  = 10; $numW.Maximum = 300; $numW.Value = $s.LabelWidthMm
    $lblX = New-Object System.Windows.Forms.Label
    $lblX.Text = '×'; $lblX.AutoSize = $true
    $lblX.Location = New-Object System.Drawing.Point(($cx + 68), 128)
    $numH = New-Object System.Windows.Forms.NumericUpDown
    $numH.Location = New-Object System.Drawing.Point(($cx + 82), 124)
    $numH.Size     = New-Object System.Drawing.Size(62, 24)
    $numH.Minimum  = 10; $numH.Maximum = 300; $numH.Value = $s.LabelHeightMm
    $dlg.Controls.AddRange(@($numW, $lblX, $numH))

    # Row 3b — Rotation toggle
    $chkRot = New-Object System.Windows.Forms.CheckBox
    $chkRot.Text     = 'Rotate text 90° (text runs along long edge of label)'
    $chkRot.Checked  = [bool]$s.RotateLabel90
    $chkRot.AutoSize = $true
    $chkRot.Location = New-Object System.Drawing.Point($cx, 158)
    $dlg.Controls.Add($chkRot)

    # Row 4 — Test Print
    $btnTest = New-Object System.Windows.Forms.Button
    $btnTest.Text     = 'Test Print'
    $btnTest.Location = New-Object System.Drawing.Point($cx, 192)
    $btnTest.Size     = New-Object System.Drawing.Size(100, 28)
    $dlg.Controls.Add($btnTest)

    # Separator line
    $sep = New-Object System.Windows.Forms.Panel
    $sep.BackColor = [System.Drawing.Color]::FromArgb(208, 210, 214)
    $sep.Location  = New-Object System.Drawing.Point(12, 232)
    $sep.Size      = New-Object System.Drawing.Size(396, 1)
    $dlg.Controls.Add($sep)

    # Save / Cancel
    $btnDlgSave = New-Object System.Windows.Forms.Button
    $btnDlgSave.Text         = 'Save'
    $btnDlgSave.Location     = New-Object System.Drawing.Point(220, 243)
    $btnDlgSave.Size         = New-Object System.Drawing.Size(84, 30)
    $btnDlgSave.DialogResult = 'OK'
    $btnDlgCancel = New-Object System.Windows.Forms.Button
    $btnDlgCancel.Text         = 'Cancel'
    $btnDlgCancel.Location     = New-Object System.Drawing.Point(316, 243)
    $btnDlgCancel.Size         = New-Object System.Drawing.Size(84, 30)
    $btnDlgCancel.DialogResult = 'Cancel'
    $dlg.Controls.AddRange(@($btnDlgSave, $btnDlgCancel))
    $dlg.AcceptButton = $btnDlgSave
    $dlg.CancelButton = $btnDlgCancel

    # ── Handlers ─────────────────────────────────────────────────────────────
    $btnList.Add_Click({
        $btnList.Enabled = $false
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $ts = [PSCustomObject]@{
                QzHost = $txtHost.Text.Trim(); QzPort = [int]$numPort.Value
                UseSecureWs = $chkWss.Checked; PrinterName = $cbPrinter.Text.Trim()
                LabelWidthMm = [int]$numW.Value; LabelHeightMm = [int]$numH.Value
                RotateLabel90 = $chkRot.Checked
            }
            $creds    = Get-QzCredentials
            $printers = Get-QzPrinterList -Settings $ts -Credentials $creds
            $cbPrinter.Items.Clear()
            foreach ($p in $printers) { [void]$cbPrinter.Items.Add($p) }
            if ($cbPrinter.Items.Count -gt 0 -and -not $cbPrinter.Text) { $cbPrinter.SelectedIndex = 0 }
            if ($printers.Count -eq 0) {
                [System.Windows.Forms.MessageBox]::Show($dlg,
                    "QZ Tray responded but returned no printers.`nCheck that the Dymo driver is installed on the host.",
                    "No Printers", 'OK', 'Warning') | Out-Null
            }
        } catch {
            [System.Windows.Forms.MessageBox]::Show($dlg,
                "Could not list printers:`r`n`r`n$($_.Exception.Message)", "QZ Tray", 'OK', 'Error') | Out-Null
        } finally {
            $btnList.Enabled = $true
            $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    $btnTest.Add_Click({
        $btnTest.Enabled = $false
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        [System.Windows.Forms.Application]::DoEvents()
        try {
            $ts = [PSCustomObject]@{
                QzHost = $txtHost.Text.Trim(); QzPort = [int]$numPort.Value
                UseSecureWs = $chkWss.Checked; PrinterName = $cbPrinter.Text.Trim()
                LabelWidthMm = [int]$numW.Value; LabelHeightMm = [int]$numH.Value
                RotateLabel90 = $chkRot.Checked
            }
            $testData = [PSCustomObject]@{
                Model = 'Test Label'; Specs = 'CPU / 16 GB RAM / 512 GB SSD'
                Display = $null; Gpu = $null; Battery = $null
            }
            $creds  = Get-QzCredentials
            $imgB64 = New-LabelBitmap -LabelData $testData `
                                     -Notes "Test print`n$(Get-Date -Format 'yyyy-MM-dd HH:mm')" `
                                     -Settings $ts
            Invoke-QzPrint -ImageBase64 $imgB64 -Settings $ts -Credentials $creds
            [System.Windows.Forms.MessageBox]::Show($dlg,
                "Test label sent to '$($ts.PrinterName)'.", "Test Print", 'OK', 'Information') | Out-Null
        } catch {
            [System.Windows.Forms.MessageBox]::Show($dlg,
                "Test print failed:`r`n`r`n$($_.Exception.Message)", "Test Print", 'OK', 'Error') | Out-Null
        } finally {
            $btnTest.Enabled = $true
            $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    })

    # Show dialog, save on OK
    if ($dlg.ShowDialog($Owner) -eq 'OK') {
        $newSettings = [PSCustomObject]@{
            QzHost        = $txtHost.Text.Trim()
            QzPort        = [int]$numPort.Value
            UseSecureWs   = $chkWss.Checked
            PrinterName   = $cbPrinter.Text.Trim()
            LabelWidthMm  = [int]$numW.Value
            LabelHeightMm = [int]$numH.Value
            RotateLabel90 = $chkRot.Checked
        }
        try {
            Save-AppSettings $newSettings
            $statusLabel.Text = "Settings saved."
        } catch {
            [System.Windows.Forms.MessageBox]::Show($Owner,
                "Settings could not be saved to disk:`r`n$($_.Exception.Message)",
                "Settings", 'OK', 'Warning') | Out-Null
        }
    }
    $dlg.Dispose()
}

# ══════════════════════════════════════════════════════════════════════════════
$form.Add_Shown({ Populate-Grid })
[void]$form.ShowDialog()
$form.Dispose()
