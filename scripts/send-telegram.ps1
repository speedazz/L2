# Sends a text file to Telegram. Token and chat id come from user environment variables.
# Reads the file with .NET (not Get-Content) so no PowerShell metadata leaks into the JSON.
# With -Html the text may use <b>, <i>, <a href="">; escape & < > in plain text as &amp; &lt; &gt;.
# If Telegram rejects the HTML, the message is resent as plain text with tags removed.
param(
    [Parameter(Mandatory = $true)][string]$File,
    [switch]$Html,
    [switch]$Silent,            # deliver without sound or vibration (for non-urgent scans)
    [string]$ButtonsJson = ''   # inline link buttons, e.g. [[{"text":"Open email","url":"https://..."}]]
)

$t = [Environment]::GetEnvironmentVariable('TELEGRAM_BOT_TOKEN', 'User')
$c = [Environment]::GetEnvironmentVariable('TELEGRAM_CHAT_ID', 'User')
if (-not $t -or -not $c) { throw "TELEGRAM_BOT_TOKEN or TELEGRAM_CHAT_ID not set" }

$text = [System.IO.File]::ReadAllText((Resolve-Path $File).Path, [System.Text.Encoding]::UTF8)
if ($text.Length -gt 4000) { $text = $text.Substring(0, 3990) + "`n..." }

function Send([string]$msg, [bool]$asHtml) {
    $payload = [ordered]@{ chat_id = [string]$c; text = [string]$msg; disable_web_page_preview = $true }
    if ($asHtml) { $payload['parse_mode'] = 'HTML' }
    if ($Silent) { $payload['disable_notification'] = $true }
    $json = ConvertTo-Json -InputObject $payload -Depth 6
    # Buttons are spliced in as raw JSON, because PowerShell 5.1 flattens nested arrays when it re-serializes them.
    if ($ButtonsJson) { $json = $json.TrimEnd().TrimEnd('}').TrimEnd() + ',"reply_markup":{"inline_keyboard":' + $ButtonsJson + '}}' }
    $body = [System.Text.Encoding]::UTF8.GetBytes($json)
    Invoke-RestMethod -Method Post -Uri "https://api.telegram.org/bot$t/sendMessage" -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 20
}

try {
    try {
        $r = Send $text $Html.IsPresent
        $mode = if ($Html) { 'html' } else { 'plain' }
    } catch {
        if (-not $Html) { throw }
        $plain = [System.Net.WebUtility]::HtmlDecode(($text -replace '<[^>]+>', ''))
        $r = Send $plain $false
        $mode = 'plain-fallback (HTML rejected)'
    }
    $sent = [string]$r.result.text
    "ok=$($r.ok) mode=$mode silent=$($Silent.IsPresent) buttons=$([bool]$ButtonsJson) chars_sent=$($sent.Length)"
    if ($sent -match 'PSPath|PSDrive|ReadCount') { "WARNING: metadata leaked into message" }
} catch {
    "failed: $($_.Exception.Message -replace [regex]::Escape($t), '<token>')"
}
