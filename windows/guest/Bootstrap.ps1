$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$inputDirectory = '\\host.lan\Data\input'
$deadline = (Get-Date).AddMinutes(5)
while (-not (Test-Path "$inputDirectory\guest.json")) {
    if ((Get-Date) -gt $deadline) { exit 1 }
    Start-Sleep -Seconds 2
}
$manifest = Get-Content "$inputDirectory\guest.json" -Raw | ConvertFrom-Json
if ($manifest.schema -ne 1) { throw 'Unsupported guest payload manifest' }
foreach ($name in @('RunTask.ps1', 'InstallDriver.ps1')) {
    $expected = $manifest.files.$name
    if ($expected -cnotmatch '^[a-f0-9]{64}$' -or
        (Get-FileHash "$inputDirectory\$name" -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) {
        throw "Guest script checksum mismatch: $name"
    }
}
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$inputDirectory\RunTask.ps1"
exit $LASTEXITCODE
