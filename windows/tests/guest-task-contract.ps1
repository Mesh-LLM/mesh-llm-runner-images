$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$scratch = Join-Path ([System.IO.Path]::GetTempPath()) ([guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $scratch | Out-Null
Copy-Item "$PSScriptRoot\..\guest\GuestTask.ps1" $scratch
Copy-Item "$PSScriptRoot\..\guest\TaskProcess.cs" $scratch
@{files=@{'TaskProcess.cs'=(Get-FileHash "$scratch\TaskProcess.cs" -Algorithm SHA256).Hash.ToLowerInvariant()}} |
    ConvertTo-Json | Set-Content "$scratch\guest.json" -Encoding UTF8
. "$scratch\GuestTask.ps1"
Initialize-GuestTaskControl
$cancel = Join-Path $scratch 'cancel.request'
$scriptFile = Join-Path $scratch 'task with spaces.ps1'
$unrelated = $null
$publisher = $null
try {
    Set-Content $scriptFile 'Write-Output "child output"; exit 7'
    $code = Invoke-GuestTask -ScriptPath $scriptFile -CancellationPath $cancel -LogPrefix "$scratch\exit"
    if ($code -ne 7) { throw "Child failure was lost: $code" }
    if ($global:MeshGuestTaskTreeActive) { throw 'Completed task retained an active-tree marker' }
    $log = Get-ChildItem "$scratch\exit-*.stdout.log" | Select-Object -First 1
    if ((Get-Content $log.FullName -Raw) -notmatch 'child output') { throw 'Child output was lost' }

    $orphanDone = Join-Path $scratch 'orphan-complete.txt'
    Set-Content $scriptFile @'
param([string]$Done)
$command = "Start-Sleep -Seconds 2; Set-Content '$Done' 'completed'"
Start-Process powershell.exe -ArgumentList @('-NoProfile','-Command',$command) | Out-Null
exit 9
'@
    $code = Invoke-GuestTask -ScriptPath $scriptFile -ScriptArguments @('-Done', $orphanDone) `
        -CancellationPath $cancel -LogPrefix "$scratch\orphan"
    if ($code -ne 9 -or -not (Test-Path $orphanDone)) { throw 'Root exit escaped descendant completion' }

    $unrelated = Start-Process powershell.exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 180') -PassThru
    foreach ($exitRoot in @($false, $true)) {
        $grandchildFile = Join-Path $scratch 'grandchild.pid'
        Set-Content $scriptFile @'
param([string]$PidFile, [switch]$ExitRoot)
$process = Start-Process powershell.exe -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 20') -PassThru
Set-Content $PidFile $process.Id
if ($ExitRoot) { exit 9 }
Start-Sleep -Seconds 20
'@
        $publisher = Start-Job -ArgumentList $grandchildFile, $cancel, $exitRoot -ScriptBlock {
            param($ReadyPath, $CancelPath, $RootExits)
            $deadline = (Get-Date).AddSeconds(20)
            while (-not (Test-Path $ReadyPath)) {
                if ((Get-Date) -gt $deadline) { throw 'Child readiness deadline' }
                Start-Sleep -Milliseconds 100
            }
            if ($RootExits) { Start-Sleep -Seconds 2 }
            Set-Content $CancelPath 'cancel'
        }
        $arguments = @('-PidFile', $grandchildFile)
        if ($exitRoot) { $arguments += '-ExitRoot' }
        $cancelled = $false
        try {
            Invoke-GuestTask -ScriptPath $scriptFile -ScriptArguments $arguments `
                -CancellationPath $cancel -LogPrefix "$scratch\cancel" | Out-Null
        } catch {
            if ($_ -notmatch 'Host cancelled') { throw }
            $cancelled = $true
        }
        if (-not $cancelled) { throw "Cancellation did not fail the task (root exited: $exitRoot)" }
        if ($global:MeshGuestTaskTreeActive) { throw 'Cancelled task retained an active-tree marker' }
        $grandchildId = [int](Get-Content $grandchildFile -Raw)
        $grandchild = Get-Process -Id $grandchildId -ErrorAction SilentlyContinue
        if ($null -ne $grandchild) {
            Write-Output "Descendant $grandchildId remains visible; exited: $($grandchild.HasExited)"
            if (-not $grandchild.HasExited) { throw 'A task descendant survived cancellation' }
        }
        if ($unrelated.HasExited) { throw 'Cancellation stopped an unrelated process' }
        Stop-Job $publisher
        Remove-Job $publisher -Force
        $publisher = $null
        Remove-Item $grandchildFile, $cancel
        Write-Output "Guest cancellation passed (root exited: $exitRoot)"
    }
    Write-Output 'Guest child exit, output, cancellation and process-tree scope passed'
} finally {
    if ($null -ne $publisher) { Stop-Job $publisher; Remove-Job $publisher -Force }
    if ($null -ne $unrelated) { Stop-Process -Id $unrelated.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item $scratch -Recurse -Force
}
