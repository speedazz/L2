# No-repeat helpers: a headline counts as "seen" if its normalized key was recorded before.
# Same story from different outlets collapses to one key (source suffix and punctuation are stripped).

function Get-ItemKey([string]$title) {
    $t = $title.ToLower()
    $t = $t -replace '\s+-\s+[^-]{2,40}$', ''      # drop trailing " - Outlet"
    $t = $t -replace '[^a-z0-9 ]', ''
    $t = ($t -replace '\s+', ' ').Trim()
    if ($t.Length -gt 70) { $t = $t.Substring(0, 70) }
    $t
}

function Get-SeenSet([string]$path) {
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    if (Test-Path $path) {
        $raw = [System.IO.File]::ReadAllText((Resolve-Path $path).Path)
        if ($raw.Trim()) { ($raw | ConvertFrom-Json) | ForEach-Object { [void]$set.Add([string]$_.key) } }
    }
    ,$set
}

function Save-SeenSet($set, [string]$path, [hashtable]$firstSeen) {
    $dir = Split-Path $path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $rows = $set | ForEach-Object { [pscustomobject]@{ key = $_; first_seen = $(if ($firstSeen.ContainsKey($_)) { $firstSeen[$_] } else { $today }) } }
    $rows | ConvertTo-Json | Set-Content -Path $path -Encoding utf8
}
