$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$root = 'C:\MeshWindows'
New-Item -ItemType Directory -Force $root | Out-Null
Start-Transcript -Path "$root\install.log" -Force
try {
    $pins = Get-Content C:\OEM\tools.json -Raw | ConvertFrom-Json
    foreach ($tool in $pins.tools) {
        $download = Join-Path $root $tool.filename
        Invoke-WebRequest -UseBasicParsing -Uri $tool.url -OutFile $download
        if ((Get-FileHash $download -Algorithm SHA256).Hash.ToLowerInvariant() -ne $tool.sha256) {
            throw "Checksum mismatch for $($tool.filename)"
        }
        if ($tool.kind -eq 'zip') {
            Expand-Archive -LiteralPath $download -DestinationPath (Join-Path $root $tool.directory) -Force
        } else {
            if ((Get-AuthenticodeSignature $download).Status -ne 'Valid') {
                throw "Invalid installer signature: $($tool.filename)"
            }
            $process = Start-Process -FilePath $download -ArgumentList $tool.arguments -Wait -PassThru
            if ($process.ExitCode -notin @(0, 3010)) {
                throw "Installer $($tool.filename) exited $($process.ExitCode)"
            }
        }
        Remove-Item -LiteralPath $download
    }
    Copy-Item C:\OEM\RunTask.ps1 "$root\RunTask.ps1" -Force
    Copy-Item C:\OEM\InstallDriver.ps1 "$root\InstallDriver.ps1" -Force
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File C:\MeshWindows\RunTask.ps1'
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 2) -StartWhenAvailable
    Register-ScheduledTask -TaskName 'MeshWindowsTask' -Action $action -Trigger $trigger -Settings $settings -User SYSTEM -RunLevel Highest -Force | Out-Null
    # Emit the marker only after provisioning succeeds. A failed installer must
    # never turn into a reusable base disk.
    New-Item -ItemType Directory -Force '\\host.lan\Data\output' | Out-Null
    Set-Content '\\host.lan\Data\output\prepared.json' '{"schema":1,"prepared":true}' -Encoding UTF8
} finally {
    Stop-Transcript
}
shutdown.exe /s /t 5
