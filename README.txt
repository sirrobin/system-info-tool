# Create a README
@"
# System Info Tool

PowerShell WinForms application that reports hardware/OS info for a Windows machine: model, serial, CPU, GPU, RAM (with slot layout), per-disk storage (with NVMe PCIe gen and SSD health), networking (Wi-Fi / Bluetooth / WWAN), and battery health.

Includes built-in tests for speakers, camera, and keyboard (via ``kb.exe``).

## Transferring specs (QR)

**Show QR Code** encodes the key specs and renders a QR **entirely offline** (via an embedded QRCoder library — no internet, and the specs never leave the machine). The payload is compact JSON:

``````json
{"t":"sysinfo","v":1,"fields":{"manufacturer":"...","model":"...","serial":"...","cpu":"...","gpuDedicated":"...","gpuIntegrated":"...","ram":"...","os":"...","battery":"...","storage":["..."]}}
``````

Another app can scan it to import the specs (e.g. the eBay AI auto-lister attaches them to an item and feeds them to its listing AI). Rebuild the .exe after changing the script for the new QR to take effect.

## Running

``````powershell
.\SystemInfo-GUI.ps1
``````

## Building a standalone .exe

``````powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-ps2exe .\SystemInfo-GUI.ps1 .\SystemInfo.exe -noConsole
``````
"@ | Out-File -Encoding UTF8 README.md