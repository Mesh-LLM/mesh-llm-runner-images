function Invoke-GuestTask {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptPath,
        [string[]]$ScriptArguments = @(),
        [Parameter(Mandatory=$true)][string]$CancellationPath,
        [Parameter(Mandatory=$true)][string]$LogPrefix
    )
    if (Test-Path $CancellationPath) { throw 'Host cancelled the Windows task' }
    if (-not ('MeshWindows.TaskProcess' -as [type])) {
        $source = Join-Path $PSScriptRoot 'TaskProcess.cs'
        $manifest = Get-Content (Join-Path $PSScriptRoot 'guest.json') -Raw | ConvertFrom-Json
        if ((Get-FileHash $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $manifest.files.'TaskProcess.cs') {
            throw 'Guest process-tree runner checksum mismatch'
        }
        Add-Type -Path $source
    }
    $prefix = "$LogPrefix-$([guid]::NewGuid().ToString('N'))"
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$ScriptPath`"")
    $arguments += @($ScriptArguments | ForEach-Object { "`"$_`"" })
    $global:MeshGuestTaskTreeActive = $true
    $child = $null
    try {
        $child = New-Object MeshWindows.TaskProcess -ArgumentList @(
            (Join-Path $PSHOME 'powershell.exe'), ($arguments -join ' '),
            "$prefix.stdout.log", "$prefix.stderr.log"
        )
        while (-not $child.HasExited -or -not $child.IsTreeEmpty) {
            if (Test-Path $CancellationPath) {
                $child.Stop()
                throw 'Host cancelled the Windows task'
            }
            Start-Sleep -Milliseconds 250
        }
        $code = $child.ExitCode
        if ($null -eq $code) { throw 'Windows child exit status is unavailable' }
    } finally {
        if ($null -ne $child) {
            try {
                if (-not $child.IsTreeEmpty) { $child.Stop() }
                if (-not $child.IsTreeEmpty) { throw 'Windows task descendants remain active' }
                $global:MeshGuestTaskTreeActive = $false
            } finally {
                $child.Dispose()
            }
        }
        foreach ($log in @("$prefix.stdout.log", "$prefix.stderr.log")) {
            if (Test-Path $log) { Get-Content $log | ForEach-Object { Write-Host $_ } }
        }
    }
    return $code
}
