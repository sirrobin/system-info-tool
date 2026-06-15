$ErrorActionPreference = 'Continue'
$tests = @(
    @{ Name = 'Win32_ComputerSystem';          Block = { Get-CimInstance Win32_ComputerSystem } }
    @{ Name = 'Win32_BIOS';                    Block = { Get-CimInstance Win32_BIOS } }
    @{ Name = 'Win32_Processor';               Block = { Get-CimInstance Win32_Processor } }
    @{ Name = 'Win32_VideoController';         Block = { Get-CimInstance Win32_VideoController } }
    @{ Name = 'Win32_SoundDevice';             Block = { Get-CimInstance Win32_SoundDevice } }
    @{ Name = 'Win32_DiskDrive';               Block = { Get-CimInstance Win32_DiskDrive } }
    @{ Name = 'Win32_PhysicalMemoryArray';     Block = { Get-CimInstance Win32_PhysicalMemoryArray } }
    @{ Name = 'Win32_PhysicalMemory';          Block = { Get-CimInstance Win32_PhysicalMemory } }
    @{ Name = 'Win32_OperatingSystem';         Block = { Get-CimInstance Win32_OperatingSystem } }
    @{ Name = 'Win32_Battery';                 Block = { Get-CimInstance Win32_Battery } }
    @{ Name = 'Win32_SystemEnclosure';         Block = { Get-CimInstance Win32_SystemEnclosure } }
    @{ Name = 'Win32_ComputerSystemProduct';   Block = { Get-CimInstance Win32_ComputerSystemProduct } }
    @{ Name = 'WmiMonitorBasicDisplayParams';  Block = { Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams } }
    @{ Name = 'WmiMonitorListedSupportedSourceModes'; Block = { Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorListedSupportedSourceModes } }
    @{ Name = 'BatteryFullChargedCapacity';    Block = { Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity } }
    @{ Name = 'BatteryStaticData';             Block = { Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData } }
    @{ Name = 'Get-PhysicalDisk';              Block = { Get-PhysicalDisk } }
    @{ Name = 'Get-StorageReliabilityCounter'; Block = { Get-PhysicalDisk | Get-StorageReliabilityCounter } }
    @{ Name = 'Get-PnpDevice';                 Block = { Get-PnpDevice -PresentOnly | Select-Object -First 5 } }
)

foreach ($t in $tests) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Host -NoNewline ("[{0,-45}] " -f $t.Name)
    $job = Start-Job -ScriptBlock $t.Block
    if (Wait-Job $job -Timeout 8) {
        $r = Receive-Job $job
        $count = if ($r) { @($r).Count } else { 0 }
        Write-Host ("OK  {0,5} ms  ({1} item(s))" -f $sw.ElapsedMilliseconds, $count) -ForegroundColor Green
    } else {
        Write-Host ("HANG after {0} ms" -f $sw.ElapsedMilliseconds) -ForegroundColor Red
        Stop-Job $job -ErrorAction SilentlyContinue
    }
    Remove-Job $job -Force -ErrorAction SilentlyContinue
    $sw.Stop()
}
Write-Host "`nDone. Press Enter to close." -ForegroundColor Cyan
[void](Read-Host)
