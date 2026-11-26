function Invoke-GuestTask {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptPath,
        [string[]]$ScriptArguments = @(),
        [Parameter(Mandatory=$true)][string]$CancellationPath,
        [Parameter(Mandatory=$true)][string]$LogPrefix
    )
    if (Test-Path $CancellationPath) { throw 'Host cancelled the Windows task' }
    $prefix = "$LogPrefix-$([guid]::NewGuid().ToString('N'))"
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")
    $arguments += @($ScriptArguments | ForEach-Object { "`"$_`"" })
    $child = Start-Process powershell.exe -ArgumentList $arguments -NoNewWindow -PassThru `
        -RedirectStandardOutput "$prefix.stdout.log" -RedirectStandardError "$prefix.stderr.log"
    try {
        # Retain the handle so ExitCode remains available even for a short task.
        $null = $child.Handle
        while (-not $child.HasExited) {
            if (Test-Path $CancellationPath) {
                & taskkill.exe /PID $child.Id /T /F | Out-Null
                if (-not $child.WaitForExit(10000)) { throw 'Windows child did not stop after cancellation' }
                throw 'Host cancelled the Windows task'
            }
            Start-Sleep -Milliseconds 250
        }
        $child.WaitForExit()
        $code = $child.ExitCode
        if ($null -eq $code) { throw 'Windows child exit status is unavailable' }
    } finally {
        if (-not $child.HasExited) {
            & taskkill.exe /PID $child.Id /T /F | Out-Null
            $null = $child.WaitForExit(10000)
        }
        foreach ($log in @("$prefix.stdout.log", "$prefix.stderr.log")) {
            if (Test-Path $log) { Get-Content $log | ForEach-Object { Write-Host $_ } }
        }
        $child.Dispose()
    }
    return $code
}
