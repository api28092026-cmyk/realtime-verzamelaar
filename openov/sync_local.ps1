<#
Haalt de OV-fiets data van GitHub naar de lokale schijf (standaard data\ naast dit script).
Draait via Taakplanner bij aanmelden en elk uur zolang de laptop aanstaat (zie install_task.ps1).

- Afgesloten maanden: uit de releases data-YYYY-MM (eenmalig per release, overschrijft een half gesyncte maand)
- Lopende maand, state.json en locaties_meta.csv: uit de branch `data` (binnen een maand alleen aangevuld)
Bestanden die op GitHub verdwijnen blijven lokaal staan. Log: data\sync.log
#>
param([string]$Dest = (Join-Path $PSScriptRoot 'data'))

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo = 'api28092026-cmyk/realtime-verzamelaar'
$tmp  = Join-Path $env:TEMP 'ovfiets_sync'
$log  = Join-Path $Dest 'sync.log'
$done = Join-Path $Dest '.releases'   # releases die al binnengehaald zijn

New-Item -ItemType Directory -Force $Dest | Out-Null
function Log($msg) { Add-Content -Path $log -Value "$(Get-Date -Format s)  $msg" -Encoding utf8 }

try {
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
    New-Item -ItemType Directory -Force $tmp | Out-Null

    # 1. Afgesloten maanden uit releases (eerst, zodat de actuele locaties_meta.csv uit stap 2 wint)
    $have = @(if (Test-Path $done) { Get-Content $done })
    $releases = Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$repo/releases?per_page=100"
    foreach ($r in $releases | Where-Object { $_.tag_name -like 'data-*' -and $have -notcontains $_.tag_name }) {
        foreach ($a in $r.assets | Where-Object { $_.name -like '*.zip' }) {
            $zip = Join-Path $tmp $a.name
            Invoke-WebRequest -UseBasicParsing $a.browser_download_url -OutFile $zip
            Unblock-File $zip   # "van internet"-markering niet meenemen naar de uitgepakte bestanden
            Expand-Archive -Force $zip $Dest
        }
        Add-Content -Path $done -Value $r.tag_name -Encoding utf8
        Log "release $($r.tag_name) binnengehaald"
    }

    # 2. Lopende maand uit de data-branch
    $zip = Join-Path $tmp 'data.zip'
    Invoke-WebRequest -UseBasicParsing "https://codeload.github.com/$repo/zip/refs/heads/data" -OutFile $zip
    Unblock-File $zip
    Expand-Archive -Force $zip $tmp
    $src = (Get-ChildItem $tmp -Directory | Select-Object -First 1).FullName
    # Per bestand kopieren, zodat lokale bestanden die niet meer op GitHub staan blijven bestaan
    foreach ($f in Get-ChildItem -Recurse -File $src | Where-Object { $_.Name -notlike '.git*' }) {
        $target = Join-Path $Dest $f.FullName.Substring($src.Length + 1)
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        # Virusscanner/indexering houdt een bestand soms even vast ("Access denied"): paar keer opnieuw proberen
        for ($i = 1; ; $i++) {
            try { Copy-Item -Force $f.FullName $target; break }
            catch { if ($i -ge 5) { throw }; Start-Sleep -Seconds (3 * $i) }
        }
    }
    Log 'data-branch gesynct'

    # Signaleren als de scraper stilvalt (bv. cron-job.org gestopt of token verlopen)
    $scrapeLog = Get-ChildItem (Join-Path $Dest 'scrapes') -Filter '*.csv' | Sort-Object Name | Select-Object -Last 1
    $last = (Get-Content $scrapeLog.FullName -Tail 1).Split(',')[0]
    $age = [int]((Get-Date).ToUniversalTime() - [datetime]::Parse($last).ToUniversalTime()).TotalMinutes
    if ($age -gt 30) { Log "WAARSCHUWING: laatste scrape $age minuten geleden ($last)" }
}
catch {
    Log "FOUT (regel $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)"   # bv. geen internet; volgende run probeert opnieuw
    exit 1
}
finally {
    if (Test-Path $tmp) { Remove-Item -Recurse -Force $tmp }
}
