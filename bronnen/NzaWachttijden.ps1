# NZa: wachttijden medisch-specialistische zorg per vestiging x (sub)specialisme x polikliniek/diagnostiek/behandeling.
# Open data van de NZa (puc.overheid.nl, dataset PUC_651798_22): elke 2 weken een peildatum (dinsdag), gepubliceerd de
# werkdag erna. Het actuele bestand bevat een jaar historie; eerdere jaren staan als archief, terug tot 10 augustus 2021.
# De eerste run laadt alle archieven; daarna alleen het actuele bestand, en alleen als er een nieuwe peildatum te verwachten is.
#
# Opslag in data/nza_wachttijden/ (compact: korte nummers in plaats van de lange NZa-codes):
#   wachttijden/<JJJJ>.csv  peildatum, vestiging_nr, code_nr, wachttijd_dagen, onvoldoende_waarnemingen (1 = te weinig
#                           waarnemingen volgens de NZa)
#   vestigingen.csv         vestiging_nr, locatiecode (NZa), naam, instelling, type (Ziekenhuis/Kliniek), AGB, KVK, adres,
#                           ROAZ-regio, eerste en laatste peildatum
#   codes.csv               code_nr, code_wachttijd (NZa), type (Polikliniekbezoek/Diagnostiek/Behandeling), specialisme,
#                           omschrijving
# Dit vervangt de oude scraper van ZorgkaartNederland (bron Wachttijden): dezelfde NZa-cijfers, maar met historie,
# met de specialismecodes van Open DIS en zonder rechtenvoorbehoud.

$script:NzaPagina = 'https://puc.overheid.nl/nza/doc/PUC_651798_22/1/'
$script:NzaVestigingKol = 'vestiging_nr', 'locatiecode', 'naam_vestiging', 'naam_instelling', 'type_zorginstelling', 'agbcode', 'kvk_instelling', 'kvk_vestiging', 'straat', 'postcode', 'plaats', 'roaz_regio', 'eerste_peildatum', 'laatste_peildatum'
$script:NzaCodeKol = 'code_nr', 'code_wachttijd', 'type_wachttijd', 'specialisme', 'omschrijving'

# Downloadlinks van de datasetpagina: 'actueel' (de link 'de dataset') en per archiefjaar.
function Get-NzaLinks {
    $html = Invoke-Get -Uri $script:NzaPagina -TimeoutSec 60
    $links = [ordered]@{}
    foreach ($m in [regex]::Matches($html, '<a[^>]+href="([^"]*DownloadDocument\.ashx\?identifier=PUC_\d+_22[^"]*)"[^>]*>(.*?)</a>', 'Singleline')) {
        $tekst = ($m.Groups[2].Value -replace '<[^>]+>', '').Trim()
        $url = 'https://puc.overheid.nl' + [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
        if ($tekst -eq 'de dataset') { $links['actueel'] = $url } elseif ($tekst -match '^\d{4}$') { $links[$tekst] = $url }
    }
    if (-not $links.Contains('actueel')) { throw 'Link naar de actuele dataset niet gevonden op de NZa-pagina (opmaak gewijzigd?).' }
    return $links
}

function Get-Cp1252 { try { [Text.Encoding]::GetEncoding(1252) } catch { [Text.Encoding]::GetEncoding('iso-8859-1') } }

# Leest een NZa-bestand en geeft per peildatum (alleen nieuwer dan $Na) de regels terug; werkt vestigingen en codes bij.
function Read-NzaBestand {
    param([string]$Pad, [string]$Na, [hashtable]$Vest, [hashtable]$Codes, [hashtable]$Uit)
    Add-Type -AssemblyName Microsoft.VisualBasic
    $p = New-Object Microsoft.VisualBasic.FileIO.TextFieldParser($Pad, (Get-Cp1252))
    try {
        $p.SetDelimiters(';'); $p.HasFieldsEnclosedInQuotes = $true
        $kop = $p.ReadFields(); $i = @{}; for ($k = 0; $k -lt $kop.Count; $k++) { $i[$kop[$k].Trim()] = $k }
        foreach ($nodig in 'PEILDATUM', 'LOCATIECODE', 'CODE_WACHTTIJD', 'WACHTTIJD', 'SPECIALISME', 'TYPE_WACHTTIJD') {
            if (-not $i.ContainsKey($nodig)) { throw "Kolom $nodig ontbreekt in $(Split-Path $Pad -Leaf)." }
        }
        $k = @{}; foreach ($naam in 'PEILDATUM', 'LOCATIECODE', 'CODE_WACHTTIJD', 'WACHTTIJD', 'SPECIALISME', 'TYPE_WACHTTIJD', 'OMS_WACHTTIJD', 'INSUFFICIENT_OBSERVATIONS',
                                  'NAAM_VESTIGING', 'NAAM_INSTELLING', 'TYPE_ZORGINSTELLING', 'AGBCODE', 'KVK_INSTELLING', 'KVK_VESTIGING_NR', 'STRAAT', 'POSTCODE', 'PLAATS', 'ROAZ_REGIO') {
            $k[$naam] = $(if ($i.ContainsKey($naam)) { $i[$naam] } else { -1 })
        }
        $iPeil = $k.PEILDATUM; $iLoc = $k.LOCATIECODE; $iCode = $k.CODE_WACHTTIJD; $iWt = $k.WACHTTIJD; $iOnv = $k.INSUFFICIENT_OBSERVATIONS
        $kenm = @{ naam_vestiging = 'NAAM_VESTIGING'; naam_instelling = 'NAAM_INSTELLING'; type_zorginstelling = 'TYPE_ZORGINSTELLING'; agbcode = 'AGBCODE'
                   kvk_instelling = 'KVK_INSTELLING'; kvk_vestiging = 'KVK_VESTIGING_NR'; straat = 'STRAAT'; postcode = 'POSTCODE'; plaats = 'PLAATS'; roaz_regio = 'ROAZ_REGIO' }
        $n = 0
        while (-not $p.EndOfData) {
            $f = $p.ReadFields()
            $peil = $f[$iPeil].Substring(0, 10)
            if ($peil -le $Na) { continue }
            $loc = $f[$iLoc].Trim(); $code = $f[$iCode].Trim()
            $v = $Vest[$loc]
            if (-not $v) { $v = @{ vestiging_nr = 0; locatiecode = $loc; eerste_peildatum = $peil; laatste_peildatum = '' }; $Vest[$loc] = $v }
            if ($peil -lt $v.eerste_peildatum) { $v.eerste_peildatum = $peil }
            if ($peil -gt $v.laatste_peildatum) {            # kenmerken volgens de nieuwste peildatum, een keer per peildatum
                $v.laatste_peildatum = $peil
                foreach ($e in $kenm.GetEnumerator()) { $ix = $k[$e.Value]; $v[$e.Key] = $(if ($ix -ge 0) { $f[$ix].Trim() } else { '' }) }
            }
            if (-not $Codes.ContainsKey($code)) {
                $Codes[$code] = @{ code_nr = 0; code_wachttijd = $code; type_wachttijd = $f[$k.TYPE_WACHTTIJD].Trim(); specialisme = $f[$k.SPECIALISME].Trim()
                                   omschrijving = $(if ($k.OMS_WACHTTIJD -ge 0) { $f[$k.OMS_WACHTTIJD].Trim() } else { '' }) }
            }
            $lijst = $Uit[$peil]
            if (-not $lijst) { $lijst = New-Object System.Collections.Generic.List[object]; $Uit[$peil] = $lijst }
            $onv = $(if ($iOnv -ge 0 -and $f[$iOnv] -match '^(?i)\s*true\s*$') { 1 } else { 0 })
            $lijst.Add(@($loc, $code, $f[$iWt].Trim(), $onv))
            $n++
        }        return $n
    } finally { $p.Close() }
}

function Import-NzaTabel {
    param([string]$Pad, [string]$Sleutel)
    $t = @{}
    if (Test-Path $Pad) { foreach ($r in (Import-Csv $Pad)) { $h = @{}; foreach ($e in $r.PSObject.Properties) { $h[$e.Name] = $e.Value }; $t[$r.$Sleutel] = $h } }
    return $t
}

function Invoke-BronNzaWachttijden {
    $map = Get-DataPath 'nza_wachttijden'; New-Item -ItemType Directory -Force -Path (Join-Path $map 'wachttijden') | Out-Null
    $status = Get-Status 'nza_wachttijden'
    $laatste = $(if ($status -and $status.laatste_peildatum) { [string]$status.laatste_peildatum } else { '' })
    $historie = [bool]($status -and $status.historie_geladen)

    # Elke 2 weken een peildatum, gepubliceerd de werkdag erna: pas vanaf 15 dagen na de vorige weer kijken.
    if ($historie -and $laatste) {
        $volgende = [datetime]::ParseExact($laatste, 'yyyy-MM-dd', $script:Inv).AddDays(15)
        if ((Get-Date).Date -lt $volgende) { return "laatste peildatum $laatste; volgende update niet voor $($volgende.ToString('yyyy-MM-dd', $script:Inv))" }
    }

    $links = Get-NzaLinks
    $bronnen = @()
    if (-not $historie) { $bronnen += @($links.Keys | Where-Object { $_ -match '^\d{4}$' } | Sort-Object | ForEach-Object { $links[$_] } | Select-Object -Unique) }
    $bronnen += $links['actueel']
    $bronnen = @($bronnen | Select-Object -Unique)

    $vest = Import-NzaTabel (Join-Path $map 'vestigingen.csv') 'locatiecode'
    $codes = Import-NzaTabel (Join-Path $map 'codes.csv') 'code_wachttijd'
    $nieuw = @{}
    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'realtime-verzamelaar'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    foreach ($url in $bronnen) {
        $f = Join-Path $tmp 'nza_wachttijden.csv'
        Invoke-Get -Uri $url -OutFile $f -TimeoutSec 600 -Pogingen 3
        # De bestanden overlappen (het actuele bestand bevat een jaar terug): per peildatum wint het nieuwste bestand.
        $ditBestand = @{}
        $n = Read-NzaBestand -Pad $f -Na $laatste -Vest $vest -Codes $codes -Uit $ditBestand
        foreach ($peil in $ditBestand.Keys) { $nieuw[$peil] = $ditBestand[$peil] }
        Write-Log "NZa-wachttijden: $n nieuwe regels uit $($url -replace '.*identifier=', '')"
        Remove-Item $f -ErrorAction SilentlyContinue
        Suspend-Beleefd
    }
    if ($nieuw.Count -eq 0) { return "geen nieuwe peildatum na $laatste (NZa publiceert elke 2 weken)" }

    # Vaste korte nummers: nieuwe vestigingen en codes krijgen het volgende vrije nummer, op volgorde van eerste peildatum.
    $max = 0; foreach ($v in $vest.Values) { if ([int]$v.vestiging_nr -gt $max) { $max = [int]$v.vestiging_nr } }
    foreach ($v in @($vest.Values | Where-Object { [int]$_.vestiging_nr -eq 0 } | Sort-Object { $_.eerste_peildatum }, { $_.locatiecode })) { $max++; $v.vestiging_nr = $max }
    $max = 0; foreach ($c in $codes.Values) { if ([int]$c.code_nr -gt $max) { $max = [int]$c.code_nr } }
    foreach ($c in @($codes.Values | Where-Object { [int]$_.code_nr -eq 0 } | Sort-Object { $_.specialisme }, { $_.type_wachttijd }, { $_.omschrijving })) { $max++; $c.code_nr = $max }

    # Wachttijden: alleen nieuwe peildata, dus achteraan toevoegen per jaarbestand.
    $peildata = @($nieuw.Keys | Sort-Object)
    foreach ($jaar in @($peildata | ForEach-Object { $_.Substring(0, 4) } | Sort-Object -Unique)) {
        $pad = Join-Path (Join-Path $map 'wachttijden') "$jaar.csv"
        $sb = New-Object Text.StringBuilder
        if (-not (Test-Path $pad)) { [void]$sb.AppendLine('peildatum,vestiging_nr,code_nr,wachttijd_dagen,onvoldoende_waarnemingen') }
        foreach ($peil in @($peildata | Where-Object { $_.StartsWith($jaar) })) {
            foreach ($r in $nieuw[$peil]) { [void]$sb.AppendLine("$peil,$($vest[$r[0]].vestiging_nr),$($codes[$r[1]].code_nr),$($r[2]),$($r[3])") }
        }
        [IO.File]::AppendAllText($pad, $sb.ToString(), $script:Utf8Bom)
    }
    $vPad = Join-Path $map 'vestigingen.csv'; if (Test-Path $vPad) { Remove-Item $vPad }
    Add-CsvRows -Path $vPad -Columns $script:NzaVestigingKol -Rows @($vest.Values | Sort-Object { [int]$_.vestiging_nr })
    $cPad = Join-Path $map 'codes.csv'; if (Test-Path $cPad) { Remove-Item $cPad }
    Add-CsvRows -Path $cPad -Columns $script:NzaCodeKol -Rows @($codes.Values | Sort-Object { [int]$_.code_nr })

    $regels = 0; foreach ($p in $peildata) { $regels += $nieuw[$p].Count }
    Set-Status 'nza_wachttijden' @{ laatste_peildatum = $peildata[-1]; historie_geladen = $true }
    return "$($peildata.Count) nieuwe peildata ($($peildata[0]) t/m $($peildata[-1])), $regels regels; $($vest.Count) vestigingen, $($codes.Count) codes"
}
