param([Parameter(Mandatory=$true)][string]$InputDirectory)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$profile = Get-Content (Join-Path $InputDirectory 'driver.json') -Raw | ConvertFrom-Json
if ($profile.backend -notin @('cuda', 'rocm')) { throw 'Unknown driver backend' }
if ($profile.sha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Invalid driver SHA-256' }
if ($profile.device_id -cnotmatch '^[a-f0-9]{4}$') { throw 'Invalid PCI device identity' }
$vendor = if ($profile.backend -eq 'cuda') { '10DE' } else { '1002' }
$identity = "PCI\VEN_$vendor&DEV_$($profile.device_id.ToUpperInvariant())"
$pciDevices = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -and $_.PNPDeviceID.StartsWith('PCI\') })
$pciDevices | Select-Object Name,PNPDeviceID,ConfigManagerErrorCode | ConvertTo-Json |
    Set-Content (Join-Path $InputDirectory '..\output\pci-before-driver.json') -Encoding UTF8
$device = @($pciDevices | Where-Object { $_.PNPDeviceID.StartsWith($identity) })
Write-Output "Matching physical PCI devices: $($device.Count) ($identity)"
if ($device.Count -ne 1) { throw 'Expected physical GPU is absent from the Windows guest' }
$driver = Join-Path $InputDirectory 'driver.exe'
if ((Get-FileHash $driver -Algorithm SHA256).Hash.ToLowerInvariant() -ne $profile.sha256) {
    throw 'Windows GPU driver checksum mismatch'
}
if ((Get-AuthenticodeSignature $driver).Status -ne 'Valid') { throw 'Windows GPU driver signature is invalid' }
Write-Output 'GPU installer checksum and signature verified'
$stamp = 'C:\MeshWindows\driver-installed.txt'
if (-not (Test-Path $stamp) -or (Get-Content $stamp -Raw).Trim() -ne $profile.sha256) {
    # Vendor self-extractors must execute from the guest's local disk. Network
    # execution can wait on Windows trust prompts or lose its extraction path.
    $localDriver = "C:\MeshWindows\driver-$($profile.sha256).exe"
    Copy-Item -LiteralPath $driver -Destination $localDriver -Force
    if ((Get-FileHash $localDriver -Algorithm SHA256).Hash.ToLowerInvariant() -ne $profile.sha256) {
        throw 'Local GPU installer checksum mismatch'
    }
    $arguments = if ($profile.backend -eq 'cuda') { '-s -noreboot' } else { '-INSTALL' }
    Write-Output "Starting local $($profile.backend) driver installation"
    $process = Start-Process -FilePath $localDriver -ArgumentList $arguments -Wait -PassThru
    Write-Output "GPU installer exited $($process.ExitCode)"
    if ($process.ExitCode -notin @(0, 3010)) { throw "GPU driver installer exited $($process.ExitCode)" }
    Set-Content $stamp $profile.sha256
    Remove-Item -LiteralPath $localDriver
    # Reboot once even when the vendor returns 0: enumeration and its kernel
    # driver must be settled before the smoke starts.
    exit 3010
}
$device = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -and $_.PNPDeviceID.StartsWith($identity) })
$device | Select-Object Name,PNPDeviceID,DriverVersion,ConfigManagerErrorCode | ConvertTo-Json |
    Set-Content (Join-Path $InputDirectory '..\output\gpu-after-driver.json') -Encoding UTF8
foreach ($gpu in $device) { Write-Output "GPU after reboot: $($gpu.Name), device error $($gpu.ConfigManagerErrorCode)" }
if ($device.Count -ne 1 -or $device[0].ConfigManagerErrorCode -ne 0) {
    throw 'GPU driver did not initialize successfully after reboot'
}
$device | Select-Object Name, PNPDeviceID, DriverVersion, ConfigManagerErrorCode | ConvertTo-Json |
    Set-Content (Join-Path $InputDirectory '..\output\gpu.json') -Encoding UTF8
