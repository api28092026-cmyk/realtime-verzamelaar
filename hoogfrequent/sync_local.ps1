<#
Haalt de hoogfrequente data (laadpunten en parkeren) van GitHub naar de lokale schijf (standaard data\ naast dit script).
Wordt elk uur aangeroepen door openov\sync_local.ps1 (dezelfde geplande taak); ook los te draaien.

- Afgesloten dagen: uit de releases hf-JJJJ-MM, als data\<reeks>\<JJJJ-MM-DD>.csv.gz. Alleen bestanden die er nog niet zijn.
- Lopende dag: data\lopend\ is een ondiepe git-kopie van de branch hoogfrequent-data (zonder state\). Een dag die
  gearchiveerd is, verdwijnt daar vanzelf uit; hij staat dan compleet in data\<reeks>\.
Log: data\sync.log
#>
param([string]$Dest = (Join-Path $PSScriptRoot 'data'))

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$repo  = 'api28092026-cmyk/realtime-verzamelaar'
$log   = Join-Path $Dest 'sync.log'

New-Item -ItemType Directory -Force $Dest | Out-Null
function Log($msg) { Add-Content -Path $log -Value "$(Get-Date -Format s)  $msg" -Encoding utf8 }
function Invoke-Git { & git.exe -c core.autocrlf=false @args | Out-Null; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') mislukte (exitcode $LASTEXITCODE)" } }

try {
    # 1. Afgesloten dagen uit de releases.
    $nieuw = 0
    $releases = @(Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$repo/releases?per_page=100" | ForEach-Object { $_ })
    foreach ($r in $releases | Where-Object { $_.tag_name -like 'hf-*' }) {
        for ($pagina = 1; ; $pagina++) {
            # ForEach-Object rolt de lijst uit: PowerShell 5.1 geeft een JSON-array anders als een enkel object terug.
            $assets = @(Invoke-RestMethod -UseBasicParsing "https://api.github.com/repos/$repo/releases/$($r.id)/assets?per_page=100&page=$pagina" | ForEach-Object { $_ })
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

    # 2. Lopende dag: data\lopend\ is een ondiepe git-kopie van de branch, zonder state\. Git houdt hem gelijk met
    #    GitHub; dagen die gearchiveerd zijn, verdwijnen er vanzelf uit (ze staan dan compleet in de dagbestanden).
    $lopend = Join-Path $Dest 'lopend'
    if ((Test-Path $lopend) -and -not (Test-Path (Join-Path $lopend '.git'))) {
        # Eenmalig: de oude gekopieerde map (tot 13 okt 2026) naar de Prullenbak, net als de oude cache in %LOCALAPPDATA%.
        Add-Type -AssemblyName Microsoft.VisualBasic
        foreach ($oud in @($lopend, (Join-Path $env:LOCALAPPDATA 'realtime-verzamelaar\hoogfrequent-data'))) {
            if (Test-Path $oud) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($oud, 'OnlyErrorDialogs', 'SendToRecycleBin') }
        }
        Log 'oude kopie van lopend\ naar de Prullenbak'
    }
    if (-not (Test-Path (Join-Path $lopend '.git'))) {
        Invoke-Git clone --quiet --depth 1 --single-branch --branch hoogfrequent-data --no-checkout "https://github.com/$repo.git" $lopend
        Invoke-Git -C $lopend sparse-checkout set --no-cone '/*' '!/state/'
        Invoke-Git -C $lopend checkout --quiet hoogfrequent-data
    } else {
        Invoke-Git -C $lopend fetch --quiet --depth 1 origin hoogfrequent-data
        Invoke-Git -C $lopend reset --quiet --hard FETCH_HEAD
    }
    # De branch begint elke dag opnieuw; eens per dag de oude git-objecten opruimen, anders groeit .git elke dag.
    $gcMerk = Join-Path $lopend '.git\laatste_opruiming'
    if (-not (Test-Path $gcMerk) -or (Get-Content $gcMerk) -ne (Get-Date -Format 'yyyy-MM-dd')) {
        Invoke-Git -C $lopend reflog expire --expire=now --all
        Invoke-Git -C $lopend gc --quiet --prune=now
        Set-Content -Path $gcMerk -Value (Get-Date -Format 'yyyy-MM-dd')
    }    Log 'lopende dag gesynct'

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
