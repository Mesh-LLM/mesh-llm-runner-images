$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. "$PSScriptRoot\..\guest\GuestTask.ps1"
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $scratch | Out-Null
$cancel = Join-Path $scratch 'cancel.request'
$scriptFile = Join-Path $scratch 'task with spaces.ps1'
$unrelated = $null
$publisher = $null
try {
    Set-Content $scriptFile 'Write-Output "child output"; exit 7'
    $code = Invoke-GuestTask -ScriptPath $scriptFile -CancellationPath $cancel -LogPrefix "$scratch\exit"
    if ($code -ne 7) { throw "Child failure was lost: $code" }
    $log = Get-ChildItem "$scratch\exit-*.stdout.log" | Select-Object -First 1
    if ((Get-Content $log.FullName -Raw) -notmatch 'child output') { throw 'Child output was lost' }

    $grandchildFile = Join-Path $scratch 'grandchild.pid'
    Set-Content $scriptFile @'
param([string]$PidFile)
$process = Start-Process powershell.exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 180') -PassThru
Set-Content $PidFile $process.Id
Start-Sleep -Seconds 180
'@
    $unrelated = Start-Process powershell.exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 180') -PassThru
    $publisher = Start-Job -ArgumentList $grandchildFile, $cancel -ScriptBlock {
        param($ReadyPath, $CancelPath)
        $deadline = (Get-Date).AddSeconds(20)
        while (-not (Test-Path $ReadyPath)) {
            if ((Get-Date) -gt $deadline) { throw 'Child readiness deadline' }
            Start-Sleep -Milliseconds 100
        }
        Set-Content $CancelPath 'cancel'
    }
    $cancelled = $false
    try {
        Invoke-GuestTask -ScriptPath $scriptFile -ScriptArguments @('-PidFile', $grandchildFile) `
            -CancellationPath $cancel -LogPrefix "$scratch\cancel" | Out-Null
    } catch {
        if ($_ -notmatch 'Host cancelled') { throw }
        $cancelled = $true
    }
    if (-not $cancelled) { throw 'Cancellation did not fail the child task' }
    $grandchildId = [int](Get-Content $grandchildFile -Raw)
    if (Get-Process -Id $grandchildId -ErrorAction SilentlyContinue) { throw 'A task descendant survived cancellation' }
    if ($unrelated.HasExited) { throw 'Cancellation stopped an unrelated process' }
    Write-Output 'Guest child exit, output, cancellation and process-tree scope passed'
} finally {
    if ($null -ne $publisher) { Stop-Job $publisher; Remove-Job $publisher -Force }
    if ($null -ne $unrelated) { Stop-Process -Id $unrelated.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $scratch -Recurse -Force
}
