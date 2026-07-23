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

# --- Screen size (EDID physical dimensions -> diagonal inches) ---
$edid = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction SilentlyContinue | Select-Object -First 1
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
$full   = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue).FullChargedCapacity
$design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue).DesignedCapacity
if ($full -and $design) { $fields.battery = ('{0}% ({1} / {2} mWh)' -f [math]::Round(100 * $full / $design), $full, $design) }

if ($fields.Count -eq 0) { Write-Host '  No specs collected.' -ForegroundColor Red; return }

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
