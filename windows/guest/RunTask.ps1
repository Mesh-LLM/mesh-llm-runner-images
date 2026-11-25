$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$share = '\\host.lan\Data'
$deadline = (Get-Date).AddMinutes(5)
while (-not (Test-Path "$share\input\task.ps1")) {
    if ((Get-Date) -gt $deadline) { exit 1 }
    Start-Sleep -Seconds 2
}
$env:PATH = "C:\MeshWindows\Python;C:\MeshWindows\Git\cmd;C:\MeshWindows\Git\bin;C:\MeshWindows\Just;$env:PATH"
$output = "$share\output"
New-Item -ItemType Directory -Force $output | Out-Null
$exitCode = 1
$reboot = $false
function Stop-AssignedGpu {
    $profile = Get-Content "$share\input\driver.json" -Raw | ConvertFrom-Json
    if ($profile.backend -ne 'rocm') { return }
    $identity = "PCI\VEN_1002&DEV_$($profile.device_id.ToUpperInvariant())"
    $devices = @(Get-PnpDevice -PresentOnly | Where-Object { $_.InstanceId.StartsWith($identity) })
    if ($devices.Count -ne 1) { throw 'Assigned AMD GPU is absent during release' }
    Disable-PnpDevice -InstanceId $devices[0].InstanceId -Confirm:$false -ErrorAction Stop
    $released = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.PNPDeviceID -and $_.PNPDeviceID.StartsWith($identity) })
    $released | Select-Object Name,PNPDeviceID,ConfigManagerErrorCode | ConvertTo-Json |
        Set-Content "$output\gpu-release.json" -Encoding UTF8
    if ($released.Count -ne 1 -or $released[0].ConfigManagerErrorCode -ne 22) {
        throw 'Assigned AMD GPU did not unload before guest shutdown'
    }
    Write-Output 'Released the assigned AMD GPU before guest shutdown'
}
Start-Transcript -Path "$output\guest.log" -Append -Force
try {
    # A vendor-requested reboot must not leave proof from the previous boot
    # after the assigned device is enabled again.
    if (Test-Path "$output\gpu-release.json") { Remove-Item "$output\gpu-release.json" -Force }
    # Also apply this to compatible bases prepared before the update policy.
    $updates = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    New-Item "$updates\AU" -Force | Out-Null
    New-ItemProperty $updates -Name ExcludeWUDriversInQualityUpdate -Value 1 -PropertyType DWord -Force | Out-Null
    New-ItemProperty "$updates\AU" -Name NoAutoUpdate -Value 1 -PropertyType DWord -Force | Out-Null
    Set-Service wuauserv -StartupType Disabled
    Stop-Service wuauserv -Force
    Copy-Item 'C:\MeshWindows\Python\python.exe' 'C:\MeshWindows\Python\python3.exe' -Force
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$share\input\InstallDriver.ps1" -InputDirectory "$share\input"
    if ($LASTEXITCODE -eq 3010) {
        Stop-AssignedGpu
        $reboot = $true
        Restart-Computer -Force
        exit 3010
    }
    if ($LASTEXITCODE -ne 0) { throw "Driver initialization exited $LASTEXITCODE" }
    # The caller supplies one task from its admitted immutable source. Child
    # process exit is explicit; PowerShell's nonterminating errors cannot pass.
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$share\input\task.ps1"
    $exitCode = $LASTEXITCODE
} catch {
    Write-Output $_
} finally {
    if (-not $reboot) {
        try { Stop-AssignedGpu } catch { Write-Output $_; $exitCode = 1 }
    }
    Stop-Transcript
    if (-not $reboot) {
        @{schema=1; exit_code=$exitCode} | ConvertTo-Json | Set-Content "$output\result.json" -Encoding UTF8
        shutdown.exe /s /t 5
    }
}
exit $exitCode
