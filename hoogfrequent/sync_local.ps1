<#
Haalt de hoogfrequente data (laadpunten en parkeren) van GitHub naar de lokale schijf (standaard data\ naast dit script).
Wordt elk uur aangeroepen door openov\sync_local.ps1 (dezelfde geplande taak); ook los te draaien.

- Afgesloten dagen: uit de releases hf-JJJJ-MM, als data\<reeks>\<JJJJ-MM-DD>.csv.gz. Alleen bestanden die er nog niet zijn.
- Lopende dag: uit de branch hoogfrequent-data (ondiepe git-kopie in %LOCALAPPDATA%\realtime-verzamelaar\hoogfrequent-data),
  gekopieerd naar data\lopend\. Een dag die als release binnen is, verdwijnt daar weer uit.
Log: data\sync.log
#>
param([string]$Dest = (Join-Path $PSScriptRoot 'data'))

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo  = 'api28092026-cmyk/realtime-verzamelaar'
$cache = Join-Path $env:LOCALAPPDATA 'realtime-verzamelaar\hoogfrequent-data'
$log   = Join-Path $Dest 'sync.log'

New-Item -ItemType Directory -Force $Dest | Out-Null
function Log($msg) { Add-Content -Path $log -Value "$(Get-Date -Format s)  $msg" -Encoding utf8 }
function Invoke-Git { & git.exe -c core.autocrlf=false @args | Out-Null; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') mislukte (exitcode $LASTEXITCODE)" } }

try {
    # 1. Afgesloten dagen uit de releases.
    $nieuw = 0
    $releases = Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$repo/releases?per_page=100"
    foreach ($r in $releases | Where-Object { $_.tag_name -like 'hf-*' }) {
        for ($pagina = 1; ; $pagina++) {
            $assets = @(Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$repo/releases/$($r.id)/assets?per_page=100&page=$pagina")
            foreach ($a in $assets) {
                if ($a.name -notmatch '^(.+)_(\d{4}-\d{2}-\d{2})\.csv\.gz$') { continue }
                $doel = Join-Path (Join-Path $Dest $Matches[1]) ($Matches[2] + '.csv.gz')
                if (Test-Path $doel) { continue }
                New-Item -ItemType Directory -Force (Split-Path $doel) | Out-Null
                Invoke-WebRequest -UseBasicParsing $a.browser_download_url -OutFile ($doel + '.tmp')
                Move-Item -Force ($doel + '.tmp') $doel
                $nieuw++
            }
            if ($assets.Count -lt 100) { break }
        }
    }
    if ($nieuw) { Log "$nieuw dagbestanden uit releases binnengehaald" }

    # 2. Lopende dag uit de branch (zonder de state-bestanden).
    if (-not (Test-Path (Join-Path $cache '.git'))) {
        New-Item -ItemType Directory -Force (Split-Path $cache) | Out-Null
        Invoke-Git clone --quiet --depth 1 --single-branch --branch hoogfrequent-data "https://github.com/$repo.git" $cache
    } else {
        Invoke-Git -C $cache fetch --quiet --depth 1 origin hoogfrequent-data
        Invoke-Git -C $cache reset --quiet --hard FETCH_HEAD
    }
    $lopend = Join-Path $Dest 'lopend'
    foreach ($f in Get-ChildItem -Recurse -File $cache | Where-Object { $_.FullName -notlike "$cache\.git\*" -and $_.FullName -notlike "$cache\state\*" -and $_.Name -notlike '.git*' }) {
        $target = Join-Path $lopend $f.FullName.Substring($cache.Length + 1)
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        for ($i = 1; ; $i++) {
            try { Copy-Item -Force $f.FullName $target; break }
            catch { if ($i -ge 5) { throw }; Start-Sleep -Seconds (3 * $i) }
        }
    }
    # Dagen die inmiddels als release binnen zijn, uit lopend\ halen (het archief is de bron).
    foreach ($f in Get-ChildItem -Recurse -File $lopend -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^(\d{4}-\d{2}-\d{2})\.csv' }) {
        $reeks = ($f.DirectoryName.Substring($lopend.Length + 1)) -replace '\\', '_'
        if (Test-Path (Join-Path (Join-Path $Dest $reeks) ($Matches[1] + '.csv.gz'))) { Remove-Item -Force $f.FullName }
    }
    Log 'lopende dag gesynct'

    # Signaleren als de verzamelaar stilvalt (cron-job.org gestopt of token verlopen)
    $runs = Get-ChildItem (Join-Path $lopend 'runs') -Filter '*.csv' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if ($runs) {
        $last = (Get-Content $runs.FullName -Tail 1).Split(',')[0]
        $age = [int]((Get-Date).ToUniversalTime() - [datetime]::Parse($last).ToUniversalTime()).TotalMinutes
        if ($age -gt 30) { Log "WAARSCHUWING: laatste run $age minuten geleden ($last)" }
    }
}
catch {
    Log "FOUT (regel $($_.InvocationInfo.ScriptLineNumber)): $($_.Exception.Message)"
    exit 1
}
