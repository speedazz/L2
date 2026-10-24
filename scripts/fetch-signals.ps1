# Fetches free public signals (news from two engines, SEC filings, Federal Register, optional Reddit)
# for a list of tickers, de-duplicates against previously seen items, and scores source reliability.
# Usage: .\fetch-signals.ps1 -Items "NVDA|Nvidia OR Jensen Huang", "NIO|NIO stock" -MarkSeen
# Holdings are passed in at run time and are never stored by this script.
param(
    [Parameter(Mandatory = $true)][string[]]$Items,
    [string]$OutFile = ".\output\signals.json",
    [int]$MaxPerSource = 6,
    [string]$SeenFile = ".\output\seen.json",
    [switch]$MarkSeen,
    [int]$SecDays = 3,
    [int]$InsiderDays = 3
)

. "$PSScriptRoot\seen-lib.ps1"
$ua = "personal-stock-tracker/0.3 (personal use)"
$browserUa = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120 Safari/537.36"
$seen = Get-SeenSet $SeenFile
$newKeys = @{}
$skipped = 0
$notes = New-Object System.Collections.ArrayList

# Outlets treated as established. Anything else is flagged "unknown outlet" so single-source claims stand out.
$tier1 = 'reuters','bloomberg','cnbc','ft.com','financial times','wsj','wall street journal','barron','marketwatch','yahoo','the straits times','business times','scmp','south china morning post','nikkei','associated press','ap news','benzinga','the globe and mail','investor''s business daily','seeking alpha','the motley fool','fortune','cnn','bbc','the economist','tradingview'

# Headlines that are never news: institutional holding notices, quote pages, estimate pages, Form 4 pages, option contracts, social posts.
$noise = 'shares (purchased|bought|sold|acquired) by', 'sells [\d,]+ shares', 'buys [\d,]+ shares', 'purchases [\d,]+ shares', 'acquires [\d,]+ shares', 'stake (lessened|raised|boosted|trimmed|increased|reduced)', 'position in', 'stock price, news, quote', 'estimates [–-] ', '^form 4', '\(amd\d{6}[cp]\d+\)', 'call \(\w+\d{6}[cp]', 'promo code', 'dfs cheat sheet', 'price prediction', 'wall street zen', 'gf score', 'key facts:', ' - facebook$', 'blessing ceremony'

function Test-Noise([string]$title) {
    foreach ($p in $noise) { if ($title -match "(?i)$p") { return $true } }
    $false
}

function Get-Tier([string]$source) {
    if (-not $source) { return 'unknown' }
    $s = $source.ToLower()
    foreach ($t in $tier1) { if ($s.Contains($t)) { return 'established' } }
    'unknown'
}

function Get-GoogleNews([string]$query) {
    $q = [uri]::EscapeDataString("$query when:1d")
    try {
        $r = Invoke-RestMethod -Uri "https://news.google.com/rss/search?q=$q&hl=en-US&gl=US&ceid=US:en" -UserAgent $ua -TimeoutSec 20
        @($r) | ForEach-Object { [pscustomobject]@{ title = $_.title; source = $_.source.'#text'; published = $_.pubDate; link = $_.link; engine = 'google' } }
    } catch { [void]$notes.Add("google news failed for '$query': $($_.Exception.Message)"); @() }
}

# Bing News returns the real article URL inside the link, unlike Google's redirect links.
function Get-BingNews([string]$query) {
    $q = [uri]::EscapeDataString($query)
    try {
        $r = Invoke-RestMethod -Uri "https://www.bing.com/news/search?q=$q&format=rss&qft=interval%3d%227%22" -UserAgent $browserUa -TimeoutSec 20
        @($r) | ForEach-Object {
            $u = $_.link
            if ($u -match 'url=([^&]+)') { $u = [uri]::UnescapeDataString($Matches[1]) }
            $src = $_.source
            if ($src -isnot [string] -and $src) { $src = $src.'#text' }
            if (-not $src) { try { $src = ([uri]$u).Host -replace '^www\.', '' } catch { $src = '' } }
            [pscustomobject]@{ title = $_.title; source = $src; published = $_.pubDate; link = $u; engine = 'bing' }
        }
    } catch { [void]$notes.Add("bing news failed for '$query': $($_.Exception.Message)"); @() }
}

function Get-Levenshtein([string]$a, [string]$b) {
    $d = New-Object 'int[,]' ($a.Length + 1), ($b.Length + 1)
    for ($i = 0; $i -le $a.Length; $i++) { $d[$i, 0] = $i }
    for ($j = 0; $j -le $b.Length; $j++) { $d[0, $j] = $j }
    for ($i = 1; $i -le $a.Length; $i++) {
        for ($j = 1; $j -le $b.Length; $j++) {
            $im = $i - 1; $jm = $j - 1
            $cost = if ($a[$im] -eq $b[$jm]) { 0 } else { 1 }
            $del = $d[$im, $j] + 1
            $ins = $d[$i, $jm] + 1
            $sub = $d[$im, $jm] + $cost
            $d[$i, $j] = [Math]::Min([Math]::Min($del, $ins), $sub)
        }
    }
    $d[$a.Length, $b.Length]
}

# Reduces outlet names to a comparable id: "The Motley Fool on MSN" and "Motley Fool" match; typo domains match their brand.
function Get-OutletId([string]$name) {
    $n = $name.ToLower() -replace ' on msn$', '' -replace '\.(com|net|org|co|uk|ca|in)\b', '' -replace '^the ', '' -replace '[^a-z0-9]', ''
    $n
}

# Counts distinct publishers: two names are the same publisher if equal, contained in each other, or within 2 edits.
function Get-DistinctOutlets([string[]]$names) {
    $ids = @()
    foreach ($nm in ($names | Where-Object { $_ })) {
        $id = Get-OutletId $nm
        if (-not $id) { continue }
        $match = $false
        foreach ($e in $ids) {
            if ($e -eq $id -or $e.Contains($id) -or $id.Contains($e) -or (Get-Levenshtein $e $id) -le 2) { $match = $true; break }
        }
        if (-not $match) { $ids += $id }
    }
    ,$ids
}

# Merges both engines, groups the same story, counts distinct outlets, drops seen stories.
function Get-VerifiedNews([string]$query) {
    $all = @(Get-GoogleNews $query) + @(Get-BingNews $query)
    $groups = @{}
    foreach ($i in $all) {
        $k = Get-ItemKey $i.title
        if (-not $k) { continue }
        if (Test-Noise $i.title) { continue }
        if (-not $groups.ContainsKey($k)) { $groups[$k] = New-Object System.Collections.ArrayList }
        [void]$groups[$k].Add($i)
    }
    $out = @()
    foreach ($k in $groups.Keys) {
        if ($seen.Contains($k) -or $newKeys.ContainsKey($k)) { $script:skipped++; continue }
        $g = $groups[$k]
        $rep = ($g | Where-Object { $_.engine -eq 'bing' } | Select-Object -First 1)
        if (-not $rep) { $rep = $g[0] }
        $outlets = @(Get-DistinctOutlets @($g | ForEach-Object { $_.source }))
        $newKeys[$k] = (Get-Date).ToString('yyyy-MM-dd')
        $out += [pscustomobject]@{
            title = $rep.title; source = $rep.source; published = $rep.published; link = $rep.link
            outlets = $outlets.Count; outlet_names = (@($g | ForEach-Object { $_.source } | Where-Object { $_ } | Sort-Object -Unique) -join '; ')
            tier = Get-Tier $rep.source
            status = if ($outlets.Count -ge 2 -and (@($g | Where-Object { (Get-Tier $_.source) -eq 'established' }).Count -ge 1)) { 'corroborated' } elseif ($outlets.Count -ge 2) { 'multiple outlets, none established' } elseif ((Get-Tier $rep.source) -eq 'established') { 'single established source' } else { 'single unknown source' }
        }
    }
    # Most-covered stories first, then newest.
    $out | Sort-Object @{ Expression = { $_.outlets }; Descending = $true }, @{ Expression = { try { [datetime]::Parse(($_.published -replace ' GMT', '')) } catch { [datetime]::MinValue } }; Descending = $true } | Select-Object -First $MaxPerSource
}

# Official filings from SEC EDGAR (8-K and 6-K events, annual and quarterly reports) in the last $SecDays days.
$script:cikMap = $null
function Get-Sec([string]$ticker) {
    try {
        if (-not $script:cikMap) {
            $cache = ".\output\sec-tickers.json"
            if (-not (Test-Path $cache) -or ((Get-Item $cache).LastWriteTime -lt (Get-Date).AddDays(-7))) {
                $dir = Split-Path $cache -Parent; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
                Invoke-WebRequest -UseBasicParsing -Uri "https://www.sec.gov/files/company_tickers.json" -UserAgent $ua -OutFile $cache -TimeoutSec 30
            }
            $raw = Get-Content $cache -Raw | ConvertFrom-Json
            $script:cikMap = @{}
            foreach ($p in $raw.PSObject.Properties) { $script:cikMap[$p.Value.ticker] = $p.Value.cik_str }
        }
        if (-not $script:cikMap.ContainsKey($ticker)) { return @() }
        $cik = ('{0:D10}' -f [int64]$script:cikMap[$ticker])
        $s = Invoke-RestMethod -Uri "https://data.sec.gov/submissions/CIK$cik.json" -UserAgent $ua -TimeoutSec 20
        $r = $s.filings.recent
        $cut = (Get-Date).AddDays(-$SecDays).Date
        $rows = @()
        for ($n = 0; $n -lt [Math]::Min(25, $r.form.Count); $n++) {
            if ($r.form[$n] -notin '8-K', '6-K', '10-Q', '10-K', '20-F') { continue }
            if ([datetime]$r.filingDate[$n] -lt $cut) { continue }
            $acc = ($r.accessionNumber[$n] -replace '-', '')
            $rows += [pscustomobject]@{ form = $r.form[$n]; filed = $r.filingDate[$n]; items = $r.items[$n]; link = "https://www.sec.gov/Archives/edgar/data/$([int64]$cik)/$acc/$($r.primaryDocument[$n])" }
        }
        $rows
    } catch { [void]$notes.Add("sec failed for ${ticker}: $($_.Exception.Message)"); @() }
}

# Insider transactions (SEC Form 4) for US domestic filers in the last $InsiderDays days.
# Codes: P = open-market purchase, S = open-market sale, A = grant, M = option exercise, F = tax withholding, G = gift.
# Only P and S are reported; a footnote or flag about a 10b5-1 plan marks pre-scheduled sales.
function Get-Insider([string]$ticker) {
    try {
        if (-not $script:cikMap) { [void](Get-Sec $ticker) }
        if (-not $script:cikMap.ContainsKey($ticker)) { return @() }
        $cik = [int64]$script:cikMap[$ticker]
        $s = Invoke-RestMethod -Uri ("https://data.sec.gov/submissions/CIK{0:D10}.json" -f $cik) -UserAgent $ua -TimeoutSec 20
        $r = $s.filings.recent
        $cut = (Get-Date).AddDays(-$InsiderDays).Date
        $out = @()
        for ($n = 0; $n -lt [Math]::Min(60, $r.form.Count); $n++) {
            if ($r.form[$n] -ne '4' -or [datetime]$r.filingDate[$n] -lt $cut) { continue }
            $acc = ($r.accessionNumber[$n] -replace '-', '')
            $doc = ($r.primaryDocument[$n] -replace '^xsl[^/]+/', '')
            $url = "https://www.sec.gov/Archives/edgar/data/$cik/$acc/$doc"
            try {
                # SEC's fair-access policy wants contact details in the user-agent for filing documents.
                # It is read from the SEC_USER_AGENT user environment variable so no contact details are stored in the repo.
                $secUa = [Environment]::GetEnvironmentVariable('SEC_USER_AGENT', 'User'); if (-not $secUa) { $secUa = $ua }
                $x = [xml](Invoke-WebRequest -UseBasicParsing -Uri $url -UserAgent $secUa -TimeoutSec 20).Content
                $o = $x.ownershipDocument
                $name = Get-Txt $o.reportingOwner.reportingOwnerId.rptOwnerName
                $rel = $o.reportingOwner.reportingOwnerRelationship
                $title = if ((Get-Txt $rel.officerTitle)) { Get-Txt $rel.officerTitle } elseif ((Get-Txt $rel.isDirector) -match '1|true') { 'Director' } else { 'Owner' }
                $plan = ((Get-Txt $o.aff10b5One) -match '1|true') -or ($x.OuterXml -match '10b5-1')
                foreach ($t in @($o.nonDerivativeTable.nonDerivativeTransaction)) {
                    if (-not $t) { continue }
                    $code = Get-Txt $t.transactionCoding.transactionCode
                    if ($code -notin 'P', 'S') { continue }
                    $sh = [double](Get-Txt $t.transactionAmounts.transactionShares.value)
                    $px = [double](Get-Txt $t.transactionAmounts.transactionPricePerShare.value)
                    $out += [pscustomobject]@{ ticker = $ticker; filed = $r.filingDate[$n]; insider = $name; role = $title; action = $(if ($code -eq 'P') { 'bought' } else { 'sold' }); shares = $sh; price = $px; value_usd = [Math]::Round($sh * $px); planned_10b5_1 = $plan; link = $url }
                }
            } catch {
                $m = "form4 parse failed ${ticker}: $($_.Exception.Message)"
                if (-not $notes.Contains($m)) { [void]$notes.Add($m) }
                break
            }
        }
        # One row per insider, day and action: total shares, average price, total value.
        $out | Group-Object filed, insider, action | ForEach-Object {
            $g = $_.Group
            $sh = ($g | Measure-Object shares -Sum).Sum
            $val = ($g | Measure-Object value_usd -Sum).Sum
            [pscustomobject]@{ ticker = $g[0].ticker; filed = $g[0].filed; insider = $g[0].insider; role = $g[0].role; action = $g[0].action; shares = $sh; avg_price = $(if ($sh) { [Math]::Round($val / $sh, 2) } else { 0 }); value_usd = $val; planned_10b5_1 = [bool]($g | Where-Object { $_.planned_10b5_1 }); link = $g[0].link }
        }
    } catch { [void]$notes.Add("insider failed for ${ticker}: $($_.Exception.Message)"); @() }
}

# Official rulemaking from the Federal Register, for policy items that need a primary source.
function Get-FederalRegister([string[]]$terms) {
    foreach ($t in $terms) {
        try {
            $u = "https://www.federalregister.gov/api/v1/documents.json?conditions[term]=$([uri]::EscapeDataString($t))&order=newest&per_page=3"
            $f = Invoke-RestMethod -Uri $u -TimeoutSec 20
            $f.results | Where-Object { (($_.agencies | ForEach-Object { $_.name }) -join ', ') -match 'Treasury|Commerce|Trade Representative|Industry and Security|Investment Security' } | ForEach-Object { [pscustomobject]@{ term = $t; date = $_.publication_date; type = $_.type; title = $_.title; agencies = (($_.agencies | ForEach-Object { $_.name }) -join ', '); link = $_.html_url; abstract = $_.abstract } }
        } catch { [void]$notes.Add("federal register failed for '$t': $($_.Exception.Message)") }
    }
}

# Reddit blocks anonymous requests. This path only runs when app credentials exist as user env vars.
function Get-Reddit([string]$query) {
    $id = [Environment]::GetEnvironmentVariable('REDDIT_CLIENT_ID', 'User')
    $sec = [Environment]::GetEnvironmentVariable('REDDIT_CLIENT_SECRET', 'User')
    if (-not $id -or -not $sec) { return @() }
    try {
        if (-not $script:redditToken) {
            $cred = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${id}:${sec}"))
            $tok = Invoke-RestMethod -Method Post -Uri "https://www.reddit.com/api/v1/access_token" -Headers @{ Authorization = "Basic $cred" } -Body @{ grant_type = 'client_credentials' } -UserAgent $ua -TimeoutSec 20
            $script:redditToken = $tok.access_token
        }
        $q = [uri]::EscapeDataString($query)
        $r = Invoke-RestMethod -Uri "https://oauth.reddit.com/search?q=$q&sort=new&t=day&limit=$MaxPerSource" -Headers @{ Authorization = "bearer $script:redditToken" } -UserAgent $ua -TimeoutSec 20
        $r.data.children | ForEach-Object { [pscustomobject]@{ title = $_.data.title; subreddit = $_.data.subreddit; score = $_.data.score; comments = $_.data.num_comments; link = "https://www.reddit.com$($_.data.permalink)" } }
    } catch { [void]$notes.Add("reddit failed: $($_.Exception.Message)"); @() }
}
$redditConfigured = [bool]([Environment]::GetEnvironmentVariable('REDDIT_CLIENT_ID', 'User'))

# Free fallback for Reddit chatter: ApeWisdom aggregates ticker mentions across Reddit finance communities.
# Counts and rank only (no post text). A "spike" needs 15+ mentions and either 2x the mentions of 24h ago, or a 20+ rank jump with 1.2x mentions.
$script:buzzMap = $null
function Get-RedditBuzz([string]$ticker) {
    try {
        if (-not $script:buzzMap) {
            $script:buzzMap = @{}
            for ($p = 1; $p -le 9; $p++) {
                $r = Invoke-RestMethod -Uri "https://apewisdom.io/api/v1.0/filter/all-stocks/page/$p" -UserAgent $ua -TimeoutSec 25
                foreach ($x in $r.results) { $script:buzzMap[$x.ticker] = $x }
                if ($p -ge [int]$r.pages) { break }
            }
        }
        $b = $script:buzzMap[$ticker]
        if (-not $b) { return $null }
        $prev = [double]$b.mentions_24h_ago; $cur = [double]$b.mentions
        $ratio = if ($prev -gt 0) { [Math]::Round($cur / $prev, 2) } else { $null }
        $jump = if ($b.rank_24h_ago) { [int]$b.rank_24h_ago - [int]$b.rank } else { 0 }
        [pscustomobject]@{ rank = $b.rank; mentions = $b.mentions; mentions_24h_ago = $b.mentions_24h_ago; ratio = $ratio; rank_jump = $jump; spike = ($cur -ge 15 -and ($ratio -ge 2 -or ($jump -ge 20 -and $ratio -ge 1.2))) }
    } catch { [void]$notes.Add("apewisdom failed: $($_.Exception.Message)"); $null }
}

# Direct feeds: official policy sources, Truth Social mirror and trusted outlets. Items are filtered to topics that can move
# markets, or that mention a tracked company, then de-duplicated against the seen list.
$feedList = @(
    @{ name = 'Truth Social (Trump, mirror)'; url = 'https://trumpstruth.org/feed'; kind = 'trump' },
    @{ name = 'White House actions'; url = 'https://www.whitehouse.gov/presidential-actions/feed/'; kind = 'official' },
    @{ name = 'Federal Reserve'; url = 'https://www.federalreserve.gov/feeds/press_all.xml'; kind = 'fed' },
    @{ name = 'SEC press'; url = 'https://www.sec.gov/news/pressreleases.rss'; kind = 'official' },
    @{ name = 'CnEVPost'; url = 'https://cnevpost.com/feed/'; kind = 'outlet' },
    @{ name = 'SCMP tech'; url = 'https://www.scmp.com/rss/36/feed'; kind = 'outlet' },
    @{ name = 'SCMP China economy'; url = 'https://www.scmp.com/rss/4/feed'; kind = 'outlet' },
    @{ name = 'CNBC tech'; url = 'https://search.cnbc.com/rs/search/combinedcms/view.xml?partnerId=wrss01&id=19854910'; kind = 'outlet' },
    @{ name = 'MarketWatch'; url = 'https://feeds.content.dowjones.io/public/rss/mw_topstories'; kind = 'outlet' },
    @{ name = 'The Straits Times business'; url = 'https://www.straitstimes.com/news/business/rss.xml'; kind = 'outlet' },
    @{ name = 'The Business Times'; url = 'https://www.businesstimes.com.sg/rss/top-stories'; kind = 'outlet' }
)
$policyWords = 'tariff', 'tariffs', 'china', 'chinese', 'xi jinping', 'chips', 'semiconductor', 'semiconductors', 'nvidia', 'tsmc', 'taiwan', 'export controls', 'sanctions', 'oil', 'crude', 'iran', 'opec', 'interest rates', 'rate cut', 'rate cuts', 'powell', 'federal reserve', 'the fed', 'inflation', 'trade deal', 'trade war', 'stock market', 'artificial intelligence', 'electric vehicles', 'tesla', 'alibaba', 'byd', 'tencent', 'micron', 'palantir', 'treasury', 'executive order', 'strait of hormuz', 'blockade'
$fedWords = 'fomc', 'monetary', 'interest rate', 'discount rate', 'federal funds', 'economic projections', 'stress test', 'powell', 'chair'

# Whole-word, case-insensitive matches (so "ban" does not match "urban").
function Get-WordMatches([string]$text, [string[]]$words) {
    @($words | Where-Object { $text -match ('(?i)\b' + [regex]::Escape($_) + '\b') })
}

function Get-Txt($v) {
    if ($null -eq $v) { return '' }
    if ($v -is [string]) { return $v }
    if ($v -is [System.Xml.XmlNode]) { return [string]$v.InnerText }
    [string]$v
}

function Get-FeedItems([string]$termsCsv) {
    $companyWords = @($termsCsv -split ';' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_.Length -ge 3 })
    $found = @()
    foreach ($f in $feedList) {
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Uri $f.url -UserAgent $browserUa -TimeoutSec 20
            [xml]$x = ($r.Content -replace '^﻿', '' -replace '^ï»¿', '')
            $nodes = @($x.rss.channel.item) + @($x.feed.entry) | Where-Object { $_ }
            foreach ($n in ($nodes | Select-Object -First 25)) {
                $title = Get-Txt $n.title
                $desc = Get-Txt $n.description; if (-not $desc) { $desc = Get-Txt $n.summary }
                if ($f.kind -eq 'trump') {
                    # Truth Social mirror items have no title; the post text is in content or description.
                    $body = Get-Txt $n.content; if (-not $body) { $body = $desc }
                    $title = ($body -replace '<[^>]+>', ' ' -replace '\s+', ' ').Trim()
                    if ($title.Length -lt 20) { continue }
                    if ($title.Length -gt 300) { $title = $title.Substring(0, 300) + '...' }
                }
                $text = ("$title $desc").ToLower()
                $link = if ($n.link -is [string]) { $n.link } elseif ($n.link.href) { $n.link.href } else { [string]$n.guid }
                $pub = (Get-Txt $n.pubDate).Trim(); if (-not $pub) { $pub = (Get-Txt $n.updated).Trim() }
                $matchedCompanies = Get-WordMatches $text $companyWords
                $matchedTopics = Get-WordMatches $text $(if ($f.kind -eq 'fed') { $fedWords } else { $policyWords })
                # Skip anything older than 36 hours (undated items are kept).
                $age = $null
                try { $age = ((Get-Date).ToUniversalTime() - ([datetime]::Parse($pub)).ToUniversalTime()).TotalHours } catch {}
                if ($null -ne $age -and $age -gt 36) { continue }
                # Trump posts: only market-relevant ones. Other feeds: company mention, or policy topic for official sources.
                $keep = switch ($f.kind) { 'trump' { $matchedTopics.Count -gt 0 -or $matchedCompanies.Count -gt 0 } 'official' { $matchedTopics.Count -gt 0 -or $matchedCompanies.Count -gt 0 } 'fed' { $matchedTopics.Count -gt 0 } default { $matchedCompanies.Count -gt 0 } }
                if (-not $keep -or -not $title) { continue }
                if (Test-Noise $title) { continue }
                $k = Get-ItemKey $title
                if (-not $k -or $seen.Contains($k) -or $newKeys.ContainsKey($k)) { if ($k) { $script:skipped++ }; continue }
                $newKeys[$k] = (Get-Date).ToString('yyyy-MM-dd')
                $found += [pscustomobject]@{ source = $f.name; kind = $f.kind; title = ($title -replace '\s+', ' ').Trim(); link = $link; published = $pub; companies = ($matchedCompanies -join '; '); topics = (($matchedTopics | Select-Object -First 5) -join '; ') }
            }
        } catch { [void]$notes.Add("feed failed ($($f.name)): $($_.Exception.Message)") }
    }
    $found
}

$results = @()
foreach ($item in $Items) {
    $parts = $item -split '\|', 2
    $ticker = $parts[0].Trim()
    $terms = if ($parts.Count -gt 1) { $parts[1].Trim() } else { $ticker }
    $isUs = $ticker -match '^[A-Z]{1,5}$'
    $results += [pscustomobject]@{
        ticker = $ticker
        news   = @(Get-VerifiedNews $terms)
        reddit = @(Get-Reddit $terms)
        reddit_buzz = $(if ($isUs) { Get-RedditBuzz $ticker } else { $null })
        sec    = if ($isUs) { @(Get-Sec $ticker) } else { @() }
        insider = if ($isUs) { @(Get-Insider $ticker) } else { @() }
    }
    Start-Sleep -Milliseconds 600
}

$policy = @(Get-VerifiedNews "Trump tariffs OR export controls OR Truth Social OR chip restrictions")
$allTerms = (($Items | ForEach-Object { ($_ -split '\|', 2)[-1] -replace ' OR ', ';' -replace '\s+stock$', '' }) -join ';')
$feedItems = @(Get-FeedItems $allTerms)
$fedreg = @(Get-FederalRegister @('outbound investment', 'export controls entity list', 'semiconductor tariffs'))
$out = [pscustomobject]@{
    generated = (Get-Date).ToString('s'); policy = $policy; feeds = $feedItems; federal_register = $fedreg; tickers = $results
    coverage = [pscustomobject]@{ sec = 'ok'; federal_register = 'ok'; reddit = $(if ($redditConfigured) { 'official API configured' } else { 'mention counts only via ApeWisdom (US tickers); no post text' }); x = 'not covered'; notes = @($notes) }
}

$dir = Split-Path $OutFile -Parent
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
$out | ConvertTo-Json -Depth 6 | Set-Content -Path $OutFile -Encoding utf8
if ($MarkSeen) {
    foreach ($k in $newKeys.Keys) { [void]$seen.Add($k) }
    Save-SeenSet $seen $SeenFile $newKeys
}
"Wrote $OutFile with $($results.Count) tickers. Skipped $skipped already-seen. New: $($newKeys.Count). MarkSeen=$($MarkSeen.IsPresent). Notes: $($notes.Count)"
