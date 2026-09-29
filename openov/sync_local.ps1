<#
Haalt de OV-fiets data van GitHub naar de lokale schijf (standaard data\ naast dit script).
Draait via Taakplanner bij aanmelden en elk uur zolang de laptop aanstaat (zie install_task.ps1).

- Lopende maand, state.json en locaties_meta.csv: uit de branch `data`, opgehaald met git (ondiepe kopie in
  %LOCALAPPDATA%\realtime-verzamelaar\openov-data). Er worden hiervoor geen bestanden gedownload en uitgepakt.
- Afgesloten maanden: uit de releases data-YYYY-MM (eenmalig per release, een keer per maand).
Bestanden die op GitHub verdwijnen blijven lokaal staan. Log: data\sync.log
#>
param([string]$Dest = (Join-Path $PSScriptRoot 'data'))

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo  = 'api28092026-cmyk/realtime-verzamelaar'
$cache = Join-Path $env:LOCALAPPDATA 'realtime-verzamelaar\openov-data'   # ondiepe git-kopie van de branch data
$log   = Join-Path $Dest 'sync.log'
$done  = Join-Path $Dest '.releases'                                      # releases die al binnengehaald zijn

New-Item -ItemType Directory -Force $Dest | Out-Null
function Log($msg) { Add-Content -Path $log -Value "$(Get-Date -Format s)  $msg" -Encoding utf8 }
# git.exe zelf aanroepen; stderr niet omleiden (in PowerShell 5.1 wordt dat anders als fout gezien).
function Invoke-Git { & git.exe -c core.autocrlf=false @args | Out-Null; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') mislukte (exitcode $LASTEXITCODE)" } }

try {
    # 1. Afgesloten maanden uit releases (eerst, zodat de actuele locaties_meta.csv uit stap 2 wint).
    $have = @(if (Test-Path $done) { Get-Content $done })
    $releases = Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$repo/releases?per_page=100"
    foreach ($r in $releases | Where-Object { $_.tag_name -like 'data-*' -and $have -notcontains $_.tag_name }) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        foreach ($a in $r.assets | Where-Object { $_.name -like '*.zip' }) {
            $zip = Join-Path $env:TEMP $a.name
            Invoke-WebRequest -UseBasicParsing $a.browser_download_url -OutFile $zip
            $z = [IO.Compression.ZipFile]::OpenRead($zip)
            try {
                foreach ($e in $z.Entries | Where-Object { $_.Name }) {
                    $target = Join-Path $Dest $e.FullName
                    New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
                }
            } finally { $z.Dispose(); Remove-Item $zip -ErrorAction SilentlyContinue }
        }
        Add-Content -Path $done -Value $r.tag_name -Encoding utf8
        Log "release $($r.tag_name) binnengehaald"
    }

    # 2. Lopende maand uit de branch data, met git (alleen de nieuwste stand, zonder historie).
    if (-not (Test-Path (Join-Path $cache '.git'))) {
        New-Item -ItemType Directory -Force (Split-Path $cache) | Out-Null
        Invoke-Git clone --quiet --depth 1 --single-branch --branch data "https://github.com/$repo.git" $cache
    } else {
        Invoke-Git -C $cache fetch --quiet --depth 1 origin data
        Invoke-Git -C $cache reset --quiet --hard FETCH_HEAD
    }
    # Per bestand kopieren, zodat lokale bestanden die niet meer op GitHub staan blijven bestaan.
    foreach ($f in Get-ChildItem -Recurse -File $cache | Where-Object { $_.FullName -notlike "$cache\.git\*" -and $_.Name -notlike '.git*' }) {
        $target = Join-Path $Dest $f.FullName.Substring($cache.Length + 1)
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
