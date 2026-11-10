<#
.SYNOPSIS
    AmdEeuSsdFix.ps1 - Detect (and optionally mitigate) the AMD External Events
    Utility (EEU) continuous-SSD-write bug.

.DESCRIPTION
    In November 2026 Tom's Hardware reported that AMD's External Events Utility
    service - installed with Radeon drivers, processes atieclxx.exe and
    atiesrxx.exe - continuously writes to the system SSD on SOME systems
    (one report: ~5 MB/s at idle). AMD acknowledged the issue on its community
    forum on Oct 21, 2026 and said a fix is coming in a future driver release;
    none has shipped yet, and there is no clear pattern across driver versions.

    AMD's driver is closed-source, so this tool does NOT patch the driver.
    It does the two things a PC owner actually can do:

      Check   - measure the EEU processes' disk writes, read SSD health/wear,
                and print a plain verdict. (Read-only.)
      Disable - apply the community workaround: stop the EEU service and set
                it to Disabled, then re-measure. Reversible; may affect
                FreeSync or other driver features on some systems.
      Enable  - undo Disable (service back to Automatic and started).
      Status  - one-shot service + process + write counters, no sampling.

    Check/Status are read-only. No telemetry, no network access.

.NOTES
    Version 1.0 - 2026-11-10 - Brett Roberts (MIT License)
    Requires Windows PowerShell 5.1+. Disable/Enable change a Windows
    service and require an elevated (Administrator) PowerShell.
    Exit codes: 0 = quiet/low (or success), 2 = elevated/severe writes,
    1 = could not measure / needs elevation / error.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('Check', 'Disable', 'Enable', 'Status')]
    [string]$Mode = 'Check',

    [switch]$WhatIf
)

$ServiceName   = 'AMD External Events Utility'
$SampleSeconds = 30
$script:ExitCode = 1

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-EeuService {
    $svc = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $svc) {
        $svc = Get-Service -ErrorAction SilentlyContinue |
               Where-Object { $_.DisplayName -like '*External Events Utility*' } |
               Select-Object -First 1
    }
    return $svc
}

function ConvertTo-DateTimeSafe($value) {
    if ($null -eq $value) { return $null }
    if ($value -is [datetime]) { return $value }
    try { return [Management.ManagementDateTimeConverter]::ToDateTime([string]$value) }
    catch { return $null }
}

function Get-AmdProcessIo {
    $procs = Get-CimInstance Win32_Process -Filter "Name='atieclxx.exe' OR Name='atiesrxx.exe'" -ErrorAction SilentlyContinue
    $list = @()
    foreach ($p in $procs) {
        $list += [PSCustomObject]@{
            Name       = $p.Name
            Pid        = [int]$p.ProcessId
            WriteBytes = [uint64]$p.WriteTransferCount
            StartTime  = ConvertTo-DateTimeSafe $p.CreationDate
        }
    }
    return $list
}

function Get-TotalWriteBytes($list) {
    [uint64]$total = 0
    foreach ($p in $list) { $total += $p.WriteBytes }
    return $total
}

function Format-GB([uint64]$bytes) { return [math]::Round($bytes / 1GB, 3) }
function Format-KBs([double]$bytesPerSec) { return [math]::Round($bytesPerSec / 1KB, 2) }

function Show-ServiceInfo($svc) {
    if ($null -eq $svc) {
        Write-Output "Service '$ServiceName': NOT INSTALLED"
        return
    }
    Write-Output ("Service '{0}': Status {1}, StartupType {2}" -f $svc.Name, $svc.Status, $svc.StartType)
}

function Show-ProcessInfo($list) {
    if (-not $list -or $list.Count -eq 0) {
        Write-Output 'Processes atieclxx.exe / atiesrxx.exe: NOT RUNNING'
        return
    }
    foreach ($p in $list) {
        $since = 'unknown'
        $avgTxt = 'average n/a'
        if ($p.StartTime) {
            $since = $p.StartTime.ToString('yyyy-MM-dd HH:mm:ss')
            $secs = ((Get-Date) - $p.StartTime).TotalSeconds
            if ($secs -gt 0) { $avgTxt = ('{0} KB/s average since start' -f (Format-KBs ($p.WriteBytes / $secs))) }
        }
        Write-Output ("  {0} (PID {1}): {2} GB written since {3} ({4})" -f $p.Name, $p.Pid, (Format-GB $p.WriteBytes), $since, $avgTxt)
    }
}

function Show-SsdInfo {
    Write-Output '--- System drives ---'
    try {
        $disks = Get-PhysicalDisk -ErrorAction Stop
        foreach ($d in $disks) {
            $line = '  {0} | {1} | Health: {2}' -f $d.FriendlyName, $d.MediaType, $d.HealthStatus
            try {
                $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop
                if ($null -ne $rc.Wear) { $line += (' | Wear: {0}% of rated life used' -f $rc.Wear) }
            } catch {
                $line += ' | Wear: unavailable'
            }
            Write-Output $line
        }
    } catch {
        Write-Output '  Drive health: unavailable on this system.'
    }
}

function Show-AdminInstructions([string]$forMode) {
    Write-Output ''
    Write-Output 'This mode changes a Windows service and needs an elevated PowerShell.'
    Write-Output 'To run it:'
    Write-Output '  1. Right-click the Start button and choose "Windows PowerShell (Admin)" (or "Terminal (Admin)").'
    Write-Output '  2. cd to the folder containing this script.'
    Write-Output ("  3. Run: powershell -ExecutionPolicy Bypass -File .\AmdEeuSsdFix.ps1 -Mode {0}" -f $forMode)
}

$DisableWarning = 'WARNING: The EEU service supports driver features such as FreeSync and display-event handling. Disabling it may affect FreeSync or other driver features on some systems (per community reports). This change is fully reversible: run this script with -Mode Enable.'

function Invoke-Status {
    Write-Output '=== AMD EEU status ==='
    Write-Output ("Computer: {0}   Time: {1}" -f $env:COMPUTERNAME, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    Show-ServiceInfo (Get-EeuService)
    Show-ProcessInfo @(Get-AmdProcessIo)
    $script:ExitCode = 0
}

function Invoke-Check {
    Write-Output '=== AMD EEU SSD-write check ==='
    Write-Output ("Computer: {0}   Time: {1}" -f $env:COMPUTERNAME, (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    $svc = Get-EeuService
    Show-ServiceInfo $svc
    if ($null -eq $svc) {
        Write-Output ''
        Write-Output 'VERDICT: NOT INSTALLED - the AMD External Events Utility is not on this PC, so this bug cannot affect it.'
        $script:ExitCode = 0
        return
    }

    $before = @(Get-AmdProcessIo)
    Show-ProcessInfo $before
    if ($before.Count -eq 0) {
        if ($svc.Status -ne 'Running') {
            Show-SsdInfo
            Write-Output ''
            Write-Output 'VERDICT: QUIET - the EEU service is not running, so it is writing nothing.'
            $script:ExitCode = 0
            return
        }
        Write-Output ''
        Write-Output 'VERDICT: COULD NOT MEASURE - the service reports Running but its processes were not found.'
        $script:ExitCode = 1
        return
    }

    Write-Output ("Sampling writes for {0} seconds..." -f $SampleSeconds)
    $t0 = Get-TotalWriteBytes $before
    Start-Sleep -Seconds $SampleSeconds
    $after = @(Get-AmdProcessIo)
    $t1 = Get-TotalWriteBytes $after
    $delta = [double]$t1 - [double]$t0
    if ($delta -lt 0) { $delta = 0 }   # a process restarted mid-sample; its counter reset
    $rateKBs = [math]::Round(($delta / $SampleSeconds) / 1KB, 2)
    Write-Output ("Live sample: {0} bytes in {1}s = {2} KB/s" -f $delta, $SampleSeconds, $rateKBs)
    Show-SsdInfo
    Write-Output ''
    if ($rateKBs -eq 0) {
        Write-Output 'VERDICT: QUIET - no writes measured. This system is NOT affected.'
        $script:ExitCode = 0
    } elseif ($rateKBs -lt 50) {
        Write-Output 'VERDICT: LOW - minor chatter only, far below the reported bug rate (~5 MB/s). Re-check another time.'
        $script:ExitCode = 0
    } elseif ($rateKBs -lt 500) {
        Write-Output 'VERDICT: ELEVATED - sustained writes in the bug class. Consider -Mode Disable (Admin), or wait for AMD''s fixed driver.'
        $script:ExitCode = 2
    } else {
        Write-Output 'VERDICT: SEVERE - very heavy sustained writes. Run -Mode Disable (Admin) now, and watch for AMD''s fixed driver.'
        $script:ExitCode = 2
    }
}

function Invoke-Disable {
    if ($WhatIf) {
        Write-Output "[WhatIf] Would STOP service '$ServiceName' and set its StartupType to Disabled."
        Write-Output '[WhatIf] Would then re-measure EEU writes for 10 seconds and print before/after.'
        Write-Output '[WhatIf] No changes made.'
        Write-Output $DisableWarning
        $script:ExitCode = 0
        return
    }
    if (-not (Test-IsAdmin)) {
        Show-AdminInstructions 'Disable'
        $script:ExitCode = 1
        return
    }
    $svc = Get-EeuService
    if ($null -eq $svc) {
        Write-Output 'Service not installed - nothing to disable.'
        $script:ExitCode = 0
        return
    }
    $beforeTotal = Get-TotalWriteBytes @(Get-AmdProcessIo)
    Write-Output ("Before: {0} GB written cumulatively by the EEU processes." -f (Format-GB $beforeTotal))
    Stop-Service -Name $svc.Name -Force -ErrorAction SilentlyContinue
    Set-Service -Name $svc.Name -StartupType Disabled
    Start-Sleep -Seconds 2
    Write-Output 'Service stopped and set to Disabled. Measuring writes for 10 seconds...'
    $a = Get-TotalWriteBytes @(Get-AmdProcessIo)
    Start-Sleep -Seconds 10
    $b = Get-TotalWriteBytes @(Get-AmdProcessIo)
    $delta = [double]$b - [double]$a
    if ($delta -lt 0) { $delta = 0 }
    $rate = [math]::Round(($delta / 10) / 1KB, 2)
    Write-Output ("After: {0} bytes in 10s = {1} KB/s" -f $delta, $rate)
    Show-ServiceInfo (Get-EeuService)
    Write-Output $DisableWarning
    Write-Output 'To undo this change: run this script with -Mode Enable (Admin).'
    $script:ExitCode = 0
}

function Invoke-Enable {
    if (-not (Test-IsAdmin)) {
        Show-AdminInstructions 'Enable'
        $script:ExitCode = 1
        return
    }
    $svc = Get-EeuService
    if ($null -eq $svc) {
        Write-Output 'Service not installed - nothing to enable.'
        $script:ExitCode = 0
        return
    }
    Set-Service -Name $svc.Name -StartupType Automatic
    Start-Service -Name $svc.Name -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Show-ServiceInfo (Get-EeuService)
    Write-Output 'EEU service restored to Automatic and started.'
    $script:ExitCode = 0
}

try {
    switch ($Mode) {
        'Check'   { Invoke-Check }
        'Status'  { Invoke-Status }
        'Disable' { Invoke-Disable }
        'Enable'  { Invoke-Enable }
    }
} catch {
    Write-Output ("ERROR: {0}" -f $_.Exception.Message)
    $script:ExitCode = 1
}
exit $script:ExitCode
