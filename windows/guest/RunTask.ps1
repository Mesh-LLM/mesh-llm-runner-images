$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$share = '\\host.lan\Data'
$deadline = (Get-Date).AddMinutes(5)
while (-not (Test-Path "$share\input\task.ps1")) {
    if ((Get-Date) -gt $deadline) { exit 1 }
    Start-Sleep -Seconds 2
}
$env:PATH = "C:\MeshWindows\Python;C:\MeshWindows\Git\cmd;C:\MeshWindows\Git\bin;C:\MeshWindows\Just;C:\MeshWindows\Tools;$env:PATH"
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
    # Existing admitted bases predate jq, which the shared CI planner requires.
    $guest = Get-Content "$share\input\guest.json" -Raw | ConvertFrom-Json
    $childRunner = "$share\input\GuestTask.ps1"
    if ((Get-FileHash $childRunner -Algorithm SHA256).Hash.ToLowerInvariant() -cne $guest.files.'GuestTask.ps1') {
        throw 'Guest child runner checksum mismatch'
    }
    . $childRunner
    Initialize-GuestTaskControl
    $toolsFile = "$share\input\tools.json"
    if ((Get-FileHash $toolsFile -Algorithm SHA256).Hash.ToLowerInvariant() -cne $guest.files.'tools.json') {
        throw 'Guest tool pins checksum mismatch'
    }
    $tools = Get-Content $toolsFile -Raw | ConvertFrom-Json
    $jq = @($tools.tools | Where-Object { $_.filename -eq 'jq-windows-amd64.exe' })
    if ($jq.Count -ne 1) { throw 'Expected one pinned Windows jq tool' }
    foreach ($tool in @($tools.tools | Where-Object { $_.kind -eq 'file' })) {
        $directory = Join-Path 'C:\MeshWindows' $tool.directory
        $target = Join-Path $directory $tool.target
        New-Item -ItemType Directory -Force $directory | Out-Null
        if (-not (Test-Path $target)) {
            Invoke-WebRequest -UseBasicParsing -Uri $tool.url -OutFile $target
        }
        if ((Get-FileHash $target -Algorithm SHA256).Hash.ToLowerInvariant() -cne $tool.sha256) {
            throw "Guest tool checksum mismatch: $($tool.filename)"
        }
    }
    $jqPath = 'C:\MeshWindows\Tools\jq.exe'
    & $jqPath --version
    if ($LASTEXITCODE -ne 0) { throw 'Windows jq preflight failed' }
    $driverExit = Invoke-GuestTask -ScriptPath "$share\input\InstallDriver.ps1" `
        -ScriptArguments @('-InputDirectory', "$share\input") `
        -CancellationPath "$share\input\cancel.request" -LogPrefix "$output\driver"
    if ($driverExit -eq 3010) {
        Stop-AssignedGpu
        # The next boot can enable the device before this script starts again.
        # A cancellation in that window must not trust this boot's unload proof.
        if (Test-Path "$output\gpu-release.json") { Remove-Item "$output\gpu-release.json" -Force }
        $reboot = $true
        Restart-Computer -Force
        exit 3010
    }
    if ($driverExit -ne 0) { throw "Driver initialization exited $driverExit" }
    # The caller supplies one task from its admitted immutable source. Child
    # process exit is explicit; PowerShell's nonterminating errors cannot pass.
    $exitCode = Invoke-GuestTask -ScriptPath "$share\input\task.ps1" `
        -CancellationPath "$share\input\cancel.request" -LogPrefix "$output\task"
} catch {
    Write-Output $_
} finally {
    $treeActive = Get-Variable -Name MeshGuestTaskTreeActive -Scope Global -ValueOnly -ErrorAction SilentlyContinue
    if ($treeActive) {
        Write-Output 'Task tree shutdown was not proven; withholding GPU release and task receipt'
        Stop-Transcript
        shutdown.exe /s /t 5
        exit 1
    }
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
