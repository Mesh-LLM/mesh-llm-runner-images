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
Start-Transcript -Path "$output\guest.log" -Append -Force
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$share\input\InstallDriver.ps1" -InputDirectory "$share\input"
    if ($LASTEXITCODE -eq 3010) {
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
    Stop-Transcript
    if (-not $reboot) {
        @{schema=1; exit_code=$exitCode} | ConvertTo-Json | Set-Content "$output\result.json" -Encoding UTF8
        shutdown.exe /s /t 5
    }
}
exit $exitCode
