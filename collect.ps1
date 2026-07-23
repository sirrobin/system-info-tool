# Headless spec collector for the eBay lister.
#
# Designed to be run in-memory, leaving nothing on disk:
#     irm http://<lister-ip>/s | iex
#
# The lister serves this file at /s (and /s/<sku>), substituting the two
# placeholders below with the callback URL and (optional) target SKU. It gathers
# ground-truth hardware specs via CIM/WMI and POSTs them back to the lister,
# which attaches them to the scanned SKU or creates a new item.
#
# Emits the same compact schema as the SystemInfo GUI's QR:
#   { "t":"sysinfo", "v":1, "fields": { manufacturer, model, serial, cpu,
#     gpuDedicated, gpuIntegrated, ram, os, storage[], screenSize, resolution,
#     touch, wwan, battery } }
#
# Note: this is a lean collector (no GUI, no embedded tools). Model/serial/CPU/
# RAM/GPU/OS/storage-size come through without admin; SSD wear and battery health
# read best from an elevated terminal.

$ErrorActionPreference = 'SilentlyContinue'
$CallbackUrl = '__CALLBACK__'   # injected by the lister; e.g. http://192.168.1.34/api/specs/scan
$Sku         = '__SKU__'        # injected by the lister; empty for the bare /s form

function V($x) { if ($null -eq $x) { '' } else { ([string]$x).Trim() } }

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)

# Not admin? Relaunch elevated so battery health + SSD wear read. The script is
# piped from the network (not a file), so we re-fetch it in an elevated window.
# If the user declines UAC we just continue without those two fields.
if (-not $elevated -and $CallbackUrl -like 'http*') {
  $base = $CallbackUrl -replace '/api/specs/scan$', ''
  $selfUrl = if ($Sku) { "$base/s/$Sku" } else { "$base/s" }
  Write-Host ''
  Write-Host '  Requesting administrator rights (for battery health + SSD wear)...' -ForegroundColor Yellow
  try {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ErrorAction Stop `
      -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-Command', "irm $selfUrl | iex"
    Write-Host '  Continuing in the elevated window that just opened.' -ForegroundColor DarkGray
    return   # hand off to the elevated instance
  } catch {
    Write-Host '  (elevation declined - continuing without battery health / SSD wear)' -ForegroundColor DarkYellow
  }
}

Write-Host ''
Write-Host '  Collecting specs...' -ForegroundColor Cyan

$fields = [ordered]@{}

# --- System identity ---
$cs   = Get-CimInstance Win32_ComputerSystem
$enc  = Get-CimInstance Win32_SystemEnclosure
$bios = Get-CimInstance Win32_BIOS
if ($cs) { if (V $cs.Manufacturer) { $fields.manufacturer = V $cs.Manufacturer }; if (V $cs.Model) { $fields.model = V $cs.Model } }
$serial = V $enc.SerialNumber
if (-not $serial -or $serial -match '^(0+|none|default|to be filled|system serial number)$') { $serial = V $bios.SerialNumber }
if ($serial) { $fields.serial = $serial }

# --- CPU ---
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
if ($cpu) { $fields.cpu = (V $cpu.Name) -replace '\s+', ' ' }

# --- GPUs (classify dedicated vs integrated) ---
foreach ($g in @(Get-CimInstance Win32_VideoController | Where-Object { $_.Name })) {
  $n = (V $g.Name) -replace '\s+', ' '
  if ($n -match 'NVIDIA|GeForce|Quadro|RTX|GTX|Radeon (RX|Pro)|FirePro|Arc\b') {
    if (-not $fields.gpuDedicated) { $fields.gpuDedicated = $n }
  } elseif ($n -match 'Intel|UHD|Iris|HD Graphics|Vega|Radeon\(TM\) Graphics|AMD Radeon Graphics') {
    if (-not $fields.gpuIntegrated) { $fields.gpuIntegrated = $n }
  } elseif (-not $fields.gpuIntegrated) { $fields.gpuIntegrated = $n }
}

# --- RAM ---
$mem = Get-CimInstance Win32_PhysicalMemory
if ($mem) {
  $bytes = ($mem | Measure-Object -Property Capacity -Sum).Sum
  if ($bytes) { $fields.ram = ('{0} GB' -f [math]::Round($bytes / 1GB)) }
} elseif ($cs -and $cs.TotalPhysicalMemory) {
  $fields.ram = ('{0} GB' -f [math]::Round($cs.TotalPhysicalMemory / 1GB))
}

# --- OS ---
$os = Get-CimInstance Win32_OperatingSystem
if ($os) { $fields.os = (V $os.Caption) -replace '\s+', ' ' }

# --- Storage (size + wear-based health) ---
$storage = @()
$phys = @(Get-PhysicalDisk | Where-Object { $_.Size -gt 0 })
if ($phys.Count) {
  foreach ($d in ($phys | Sort-Object DeviceId)) {
    $gb = [math]::Round($d.Size / 1GB)
    $desc = if ($gb -ge 1000) { ('{0:0.#} TB' -f ($gb / 1024)) } else { "$gb GB" }
    $mt = V $d.MediaType; if ($mt -and $mt -ne 'Unspecified') { $desc = "$desc $mt" }
    $wear = ($d | Get-StorageReliabilityCounter).Wear
    if ($null -ne $wear) { $desc = "$desc -- Health: $([math]::Max(0, 100 - [int]$wear))%" }
    $fn = V $d.FriendlyName; if ($fn) { $desc = "$fn -- $desc" }
    $storage += $desc
  }
} else {
  foreach ($d in (Get-CimInstance Win32_DiskDrive | Sort-Object Index)) {
    $gb = [math]::Round($d.Size / 1GB); if (-not $gb) { continue }
    $desc = if ($gb -ge 1000) { ('{0:0.#} TB' -f ($gb / 1024)) } else { "$gb GB" }
    $md = V $d.Model; if ($md) { $desc = "$md -- $desc" }
    $storage += $desc
  }
}
if ($storage.Count) { $fields.storage = @($storage) }

# --- Screen size: prefer the INTERNAL laptop panel over any docked external ---
$allEdid = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue)
$conn    = @(Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorConnectionParams -ErrorAction SilentlyContinue)
# D3DKMDT_VOT_INTERNAL = 0x80000000 marks the built-in panel (eDP/LVDS).
$internal = $conn | Where-Object { $_.VideoOutputTechnology -eq 2147483648 -or $_.VideoOutputTechnology -eq -2147483648 } | Select-Object -First 1
$edid = $null
if ($internal) { $edid = $allEdid | Where-Object { $_.InstanceName -eq $internal.InstanceName } | Select-Object -First 1 }
if (-not $edid) { $edid = $allEdid | Select-Object -First 1 }  # desktop / no internal flag
if ($edid -and $edid.MaxHorizontalImageSize) {
  $diag = [math]::Sqrt([math]::Pow($edid.MaxHorizontalImageSize, 2) + [math]::Pow($edid.MaxVerticalImageSize, 2)) / 2.54
  if ($diag -ge 5) { $fields.screenSize = ('{0:0.0}"' -f $diag) }
}
# --- Resolution (current desktop mode is a good native proxy on laptops) ---
$vc = Get-CimInstance Win32_VideoController | Where-Object { $_.CurrentHorizontalResolution } | Select-Object -First 1
if ($vc) { $fields.resolution = ('{0}x{1}' -f $vc.CurrentHorizontalResolution, $vc.CurrentVerticalResolution) }

# --- Touchscreen ---
if (Get-CimInstance Win32_PnPEntity | Where-Object { $_.Name -match 'touch ?screen|HID-compliant touch' }) { $fields.touch = 'Yes' }

# --- WWAN / mobile broadband ---
if (Get-CimInstance Win32_NetworkAdapter | Where-Object { $_.Name -match 'Mobile Broadband|WWAN|LTE|5G Modem|Cellular' }) { $fields.wwan = 'Yes' }

# --- Battery health (design vs full-charge capacity) ---
$hasBattery = [bool](Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue)
$full   = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue | Measure-Object -Property FullChargedCapacity -Sum).Sum
$design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue | Measure-Object -Property DesignedCapacity -Sum).Sum
if (-not ($full -and $design) -and $hasBattery) {
  # The root\wmi ACPI classes are missing on many laptops (even elevated). Fall
  # back to powercfg's battery report — reliable, and it doesn't need admin.
  try {
    $rpt = Join-Path $env:TEMP ("bat_" + [guid]::NewGuid().ToString('N') + ".xml")
    powercfg /batteryreport /output "$rpt" /xml *> $null
    if (Test-Path $rpt) {
      $txt = Get-Content $rpt -Raw
      Remove-Item $rpt -Force -ErrorAction SilentlyContinue
      $dm = [regex]::Match($txt, 'Design(?:ed)?Capacity[^<>]*>\s*([\d,]+)')
      $fm = [regex]::Match($txt, 'FullCharge(?:d)?Capacity[^<>]*>\s*([\d,]+)')
      if ($dm.Success -and $fm.Success) {
        $design = [int64]($dm.Groups[1].Value -replace ',', '')
        $full = [int64]($fm.Groups[1].Value -replace ',', '')
      }
    }
  } catch { }
}
if ($full -and $design) {
  $fields.battery = ('{0}% (full {1} / design {2} mWh)' -f [math]::Round(100 * $full / $design), $full, $design)
} elseif ($hasBattery) {
  $fields.battery = 'present (health unavailable)'
}

if ($fields.Count -eq 0) { Write-Host '  No specs collected.' -ForegroundColor Red; return }

# Show what we found so it's visible on the machine itself, not just in the lister.
$labels = [ordered]@{
  manufacturer = 'Manufacturer'; model = 'Model'; serial = 'Serial'; cpu = 'CPU'
  gpuDedicated = 'GPU (dedicated)'; gpuIntegrated = 'GPU (integrated)'; ram = 'RAM'
  os = 'OS'; screenSize = 'Screen'; resolution = 'Resolution'; touch = 'Touch'; wwan = 'WWAN'; battery = 'Battery'
}
Write-Host ''
Write-Host '  --- Collected specs ---' -ForegroundColor Cyan
foreach ($k in $fields.Keys) {
  if ($k -eq 'storage') {
    Write-Host ('  {0,-16}:' -f 'Storage') -ForegroundColor Gray
    foreach ($s in $fields.storage) { Write-Host "      - $s" }
  } else {
    $lbl = if ($labels.Contains($k)) { $labels[$k] } else { $k }
    Write-Host ('  {0,-16}: ' -f $lbl) -ForegroundColor Gray -NoNewline
    Write-Host $fields[$k]
  }
}
if (-not $elevated) {
  Write-Host '  (tip: run PowerShell as Administrator to read battery health + SSD wear)' -ForegroundColor DarkYellow
}
Write-Host ''

$json = ([ordered]@{ t = 'sysinfo'; v = 1; fields = $fields } | ConvertTo-Json -Depth 5 -Compress)

if ($CallbackUrl -like 'http*') {
  $body = (@{ payload = $json; sku = $Sku } | ConvertTo-Json -Depth 6 -Compress)
  try {
    $r = Invoke-RestMethod -Uri $CallbackUrl -Method Post -Body $body -ContentType 'application/json' -TimeoutSec 15
    Write-Host ''
    Write-Host ('  ' + $r.message) -ForegroundColor Green
    if ($r.title) { Write-Host ('  Title: ' + $r.title) -ForegroundColor Green }
  } catch {
    Write-Host ''
    Write-Host ('  Could not reach the lister: ' + $_.Exception.Message) -ForegroundColor Red
    Write-Host '  Specs JSON (copy into the lister manually if needed):' -ForegroundColor Yellow
    Write-Host "  $json"
  }
} else {
  # Served without a callback (e.g. saved locally) — just print the payload.
  Write-Host $json
}
