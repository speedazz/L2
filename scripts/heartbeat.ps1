# Health check for the scheduled scans.
#   -Record  : log that a scan ran now (call at the end of every scan, even quiet ones).
#   -Check   : print which scheduled slots in the last 3 days had no run, so a skipped scan is reported instead of silent.
# Slots are local times: 07:00, 22:00, 23:30. A run within 5 minutes before to 90 minutes after a slot counts as on time;
# a run later than that but before the next slot counts as late (usually the app was closed and ran on next launch).
param(
    [switch]$Record,
    [switch]$Check,
    [string]$Scan = '',
    [string]$LogFile = ".\output\heartbeat-log.csv",
    [string[]]$Slots = @('07:00', '22:00', '23:30')
)

$dir = Split-Path $LogFile -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }

if ($Record) {
    if (-not (Test-Path $LogFile)) { Set-Content -Path $LogFile -Value 'run_at,scan' -Encoding utf8 }
    Add-Content -Path $LogFile -Value ("{0},{1}" -f (Get-Date).ToString('s'), $Scan) -Encoding utf8
    "recorded $(Get-Date -Format s) $Scan"
    return
}

if ($Check) {
    $now = Get-Date
    $runs = @()
    if (Test-Path $LogFile) { $runs = @(Import-Csv $LogFile | ForEach-Object { [datetime]$_.run_at }) }
    if ($runs.Count -eq 0) { "FIRST RUN: no history yet"; return }
    $first = ($runs | Sort-Object | Select-Object -First 1)
    $slotTimes = @()
    foreach ($d in -3..0) {
        foreach ($s in $Slots) {
            $h, $m = $s -split ':'
            $slotTimes += (Get-Date).Date.AddDays($d).AddHours([int]$h).AddMinutes([int]$m)
        }
    }
    $slotTimes = @($slotTimes | Sort-Object)
    $missed = @(); $late = @()
    for ($i = 0; $i -lt $slotTimes.Count; $i++) {
        $st = $slotTimes[$i]
        if ($st -lt $first.AddMinutes(-5) -or $st -gt $now.AddMinutes(-95)) { continue }   # before history began, or the current/very recent slot
        $next = if ($i + 1 -lt $slotTimes.Count) { $slotTimes[$i + 1] } else { $now.AddDays(1) }
        $onTime = $runs | Where-Object { $_ -ge $st.AddMinutes(-5) -and $_ -le $st.AddMinutes(90) }
        if ($onTime) { continue }
        $lateRun = $runs | Where-Object { $_ -gt $st.AddMinutes(90) -and $_ -lt $next }
        if ($lateRun) { $late += $st.ToString('ddd HH:mm') } else { $missed += $st.ToString('ddd HH:mm') }
    }
    $last = ($runs | Sort-Object | Select-Object -Last 1).ToString('ddd HH:mm')
    if ($missed.Count -eq 0 -and $late.Count -eq 0) { "OK last_run=$last" }
    else { "ISSUES last_run=$last missed=[$($missed -join ', ')] late=[$($late -join ', ')]" }
}
