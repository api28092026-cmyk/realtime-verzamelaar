# Wachttijden medisch-specialistische zorg (NZa-gegevens, getoond op ZorgkaartNederland van de Patientenfederatie).
# De NZa verzamelt de wachttijden elke 2 weken; ZorgkaartNederland toont ze per poli, onderzoek en behandeling
# voor alle ziekenhuizen en klinieken. De Patientenfederatie claimt rechten op de inhoud van de website, daarom:
#  - deze bron draait ALLEEN lokaal (niet op GitHub) en schrijft naar een datamap buiten git (zie Installeer-Taak.ps1);
#  - hooguit een keer per week (WachttijdenDagen in config.psd1), met een rustig tempo.

$script:ZkBasis = 'https://www.zorgkaartnederland.nl'

function Invoke-BronWachttijden {
    if ($env:GITHUB_ACTIONS -eq 'true') { return 'overgeslagen: deze bron draait alleen lokaal' }
    $interval = if ($script:Cfg.WachttijdenDagen) { [int]$script:Cfg.WachttijdenDagen } else { 7 }
    $status = Get-Status 'wachttijden'
    if ($status -and $status.laatste_run -and ((Get-Date) - [datetime]::ParseExact($status.laatste_run, 'yyyy-MM-dd', $script:Inv)).TotalDays -lt $interval) {
        return "overgeslagen: laatste ronde op $($status.laatste_run)"
    }
    $pauze = if ($script:Cfg.WachttijdenPauzeMs) { [int]$script:Cfg.WachttijdenPauzeMs } else { 1500 }

    # 1. Alle onderwerpen per soort (polikliniek, diagnostiek, behandeling).
    $onderwerpen = New-Object System.Collections.ArrayList
    foreach ($soort in @(@{ pad = 'poliklinieken'; naam = 'polikliniek' }, @{ pad = 'diagnostiek'; naam = 'diagnostiek' }, @{ pad = 'behandelingen'; naam = 'behandeling' })) {
        $html = Invoke-Get -Uri "$script:ZkBasis/wachttijden/$($soort.pad)" -TimeoutSec 60
        $gezien = @{}
        foreach ($m in [regex]::Matches($html, '<a[^>]+href="/wachttijden/([a-z0-9\-]+)"[^>]*>\s*([^<]+?)\s*</a>')) {
            $slug = $m.Groups[1].Value
            if ($slug -in 'poliklinieken', 'diagnostiek', 'behandelingen' -or $gezien.ContainsKey($slug)) { continue }
            $gezien[$slug] = $true
            [void]$onderwerpen.Add(@{ soort = $soort.naam; slug = $slug; naam = [Net.WebUtility]::HtmlDecode($m.Groups[2].Value) })
        }
        Start-Sleep -Milliseconds $pauze
    }
    if ($onderwerpen.Count -lt 50) { throw "Maar $($onderwerpen.Count) onderwerpen gevonden; is de site veranderd?" }

    # 2. Per onderwerp de tabel met alle aanbieders, locaties en wachttijden in dagen.
    $rijen = New-Object System.Collections.ArrayList
    $mislukt = New-Object System.Collections.Generic.List[string]
    foreach ($o in $onderwerpen) {
        try {
            $html = Invoke-Get -Uri "$script:ZkBasis/wachttijden/$($o.slug)" -TimeoutSec 60 -Pogingen 2
            $body = [regex]::Match($html, '(?s)<tbody>(.*?)</tbody>').Groups[1].Value
            foreach ($tr in [regex]::Matches($body, '(?s)<tr>(.*?)</tr>')) {
                $td = [regex]::Matches($tr.Groups[1].Value, '(?s)<td[^>]*>(.*?)</td>')
                if ($td.Count -lt 3) { continue }
                $a = [regex]::Match($td[0].Groups[1].Value, 'href="/zorginstelling/([^"/#]+)[^"]*"[^>]*>\s*([^<]+?)\s*</a>')
                $plaats = ([regex]::Replace($td[1].Groups[1].Value, '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
                $dagen = ([regex]::Replace($td[2].Groups[1].Value, '<[^>]+>', ' ') -replace '\s+', ' ').Trim()
                $id = [regex]::Match($a.Groups[1].Value, '-(\d+)$').Groups[1].Value
                [void]$rijen.Add(@{ peildatum = $script:Today; soort = $o.soort; onderwerp = $o.naam; onderwerp_slug = $o.slug
                    aanbieder = [Net.WebUtility]::HtmlDecode($a.Groups[2].Value); aanbieder_id = $id; plaats = [Net.WebUtility]::HtmlDecode($plaats)
                    wachttijd_dagen = $(if ($dagen -match '^\d+$') { [int]$dagen } else { $null }); opmerking = $(if ($dagen -match '^\d+$') { '' } else { $dagen }) })
            }
        } catch { $mislukt.Add($o.slug) }
        Start-Sleep -Milliseconds $pauze
    }
    if ($rijen.Count -lt 1000) { throw "Maar $($rijen.Count) wachttijden gevonden; is de site veranderd?" }
    $map = Get-DataPath 'wachttijden'; New-Item -ItemType Directory -Force -Path $map | Out-Null
    Add-CsvRows -Path (Join-Path $map ((Get-Date).ToString('yyyy', $script:Inv) + '.csv')) `
        -Columns 'peildatum', 'soort', 'onderwerp', 'onderwerp_slug', 'aanbieder', 'aanbieder_id', 'plaats', 'wachttijd_dagen', 'opmerking' -Rows $rijen
    Set-Status 'wachttijden' @{ laatste_run = $script:Today }
    $extra = if ($mislukt.Count) { "; niet gelukt: $($mislukt -join ', ')" } else { '' }
    return "$($rijen.Count) wachttijden uit $($onderwerpen.Count - $mislukt.Count) van $($onderwerpen.Count) overzichten$extra"
}
