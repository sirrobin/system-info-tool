# Create a README
@"
# System Info Tool

PowerShell WinForms application that reports hardware/OS info for a Windows machine: model, serial, CPU, GPU, RAM (with slot layout), per-disk storage (with NVMe PCIe gen and SSD health), networking (Wi-Fi / Bluetooth / WWAN), and battery health.

Includes built-in tests for speakers, camera, and keyboard (via ``kb.exe``).

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