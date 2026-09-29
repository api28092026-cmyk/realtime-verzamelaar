# Verstoringen op weg en spoor. Open, geen key.
#  - Weg: NDW 'actueel beeld' (DATEX II v3): ongevallen, stilstaande voertuigen, files, afsluitingen, snelheidsmaatregelen.
#    Elke run: tellingen per type, plus een logboek per melding (eerst en laatst gezien, begin, eind, vertraging, locatie).
#    Draai deze bron ook elk uur, anders mis je korte incidenten.
#  - Spoor: Rijden de Treinen publiceert na afloop van elke maand alle ritten met vertraging en uitval per halte.
#    Elke nieuwe maand wordt één keer samengevat tot punctualiteit en uitval per dag, vervoerder en station.

$script:NdwActueel = 'https://opendata.ndw.nu/actueel_beeld.xml.gz'
$script:RdtServices = 'https://opendata.rijdendetreinen.nl/public/services/services-{0}.csv.gz'

if (-not ('RdtAggregator' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
public class RdtAggregator {
    // sleutel dag|vervoerder|treinsoort -> [ritten, geheel uitgevallen, deels uitgevallen, aankomsten, >=3 min, >=5 min, som vertraging (min), geannuleerde aankomsten]
    public Dictionary<string, long[]> PerDag = new Dictionary<string, long[]>();
    // sleutel dag|stationscode|stationsnaam -> [aankomsten, >=5 min, geannuleerde aankomsten]
    public Dictionary<string, long[]> PerStation = new Dictionary<string, long[]>();
    public long Regels;
    static string[] Split(string l) {
        if (l.IndexOf('"') < 0) return l.Split(',');
        var uit = new List<string>(); var sb = new System.Text.StringBuilder(); bool q = false;
        for (int i = 0; i < l.Length; i++) {
            char c = l[i];
            if (q) { if (c == '"') { if (i + 1 < l.Length && l[i + 1] == '"') { sb.Append('"'); i++; } else q = false; } else sb.Append(c); }
            else if (c == '"') q = true; else if (c == ',') { uit.Add(sb.ToString()); sb.Length = 0; } else sb.Append(c);
        }
        uit.Add(sb.ToString()); return uit.ToArray();
    }
    static long[] Get(Dictionary<string, long[]> d, string k, int n) { long[] a; if (!d.TryGetValue(k, out a)) { a = new long[n]; d[k] = a; } return a; }
    public void Process(TextReader r) {
        string[] kop = Split(r.ReadLine());
        int iId = Array.IndexOf(kop, "Service:RDT-ID"), iDag = Array.IndexOf(kop, "Service:Date"), iSoort = Array.IndexOf(kop, "Service:Type"),
            iVv = Array.IndexOf(kop, "Service:Company"), iGeheel = Array.IndexOf(kop, "Service:Completely cancelled"), iDeels = Array.IndexOf(kop, "Service:Partly cancelled"),
            iCode = Array.IndexOf(kop, "Stop:Station code"), iNaam = Array.IndexOf(kop, "Stop:Station name"), iAank = Array.IndexOf(kop, "Stop:Arrival time"),
            iVertr = Array.IndexOf(kop, "Stop:Arrival delay"), iAnnul = Array.IndexOf(kop, "Stop:Arrival cancelled");
        if (iId < 0 || iDag < 0 || iVertr < 0) throw new Exception("Onverwachte kolommen: " + string.Join(",", kop));
        string vorige = null; string l;
        while ((l = r.ReadLine()) != null) {
            Regels++;
            string[] f = Split(l); if (f.Length <= iAnnul) continue;
            string sk = f[iDag] + "|" + f[iVv] + "|" + f[iSoort];
            long[] a = Get(PerDag, sk, 8);
            if (f[iId] != vorige) { vorige = f[iId]; a[0]++; if (f[iGeheel] == "true") a[1]++; if (f[iDeels] == "true") a[2]++; }
            if (f[iAank].Length == 0) continue;                        // beginstation: geen aankomst
            long[] s = Get(PerStation, f[iDag] + "|" + f[iCode] + "|" + f[iNaam], 3);
            if (f[iAnnul] == "true") { a[7]++; s[2]++; continue; }
            int v; if (!int.TryParse(f[iVertr], out v)) v = 0;
            if (v < 0 || v > 600) v = 0;                               // uitschieters (bv. +1440 rond middernacht) niet meetellen
            a[3]++; s[0]++; a[6] += v;
            if (v >= 3) a[4]++;
            if (v >= 5) { a[5]++; s[1]++; }
        }
    }
}
'@
}

function Get-XmlWaarde { param([string]$Xml, [string]$Tag) $m = [regex]::Match($Xml, "<$Tag>([^<]*)</$Tag>"); if ($m.Success) { return $m.Groups[1].Value } else { return '' } }

function Invoke-VerstoringenWeg {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'realtime-verzamelaar'
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $gz = Join-Path $tmp 'actueel_beeld.xml.gz'
    Invoke-Get -Uri $script:NdwActueel -OutFile $gz -TimeoutSec 300
    $s = New-Object IO.Compression.GZipStream([IO.File]::OpenRead($gz), [IO.Compression.CompressionMode]::Decompress)
    $rd = New-Object IO.StreamReader($s, [Text.Encoding]::UTF8); $xml = $rd.ReadToEnd(); $rd.Dispose()

    $geenSubtype = 'causeType', 'mobilityType', 'delayBand', 'carriageway', 'validityStatus'
    $meldingen = @{}
    foreach ($m in [regex]::Matches($xml, '(?s)<sit:situationRecord ([^>]*)>(.*?)</sit:situationRecord>')) {
        $kop = $m.Groups[1].Value; $body = $m.Groups[2].Value
        $id = [regex]::Match($kop, 'id="([^"]+)"').Groups[1].Value
        if (-not $id) { continue }
        $sub = ''
        foreach ($t in [regex]::Matches($body, '<sit:(\w+Type)>([^<]+)</sit:\1>')) { if ($geenSubtype -notcontains $t.Groups[1].Value) { $sub = $t.Groups[2].Value; break } }
        $lat = Get-XmlWaarde $body 'loc:latitude'; $lon = Get-XmlWaarde $body 'loc:longitude'
        if (-not $lat) { $pos = (Get-XmlWaarde $body 'loc:posList') -split ' '; if ($pos.Count -ge 2) { $lat = $pos[0]; $lon = $pos[1] } }
        $vertraging = Get-XmlWaarde $body 'sit:delayTimeValue'
        $meldingen[$id] = @{
            melding_id = $id; versie = [regex]::Match($kop, 'version="([^"]+)"').Groups[1].Value
            type = ([regex]::Match($kop, 'xsi:type="(?:sit:)?([^"]+)"').Groups[1].Value); subtype = $sub
            oorzaak = Get-XmlWaarde $body 'sit:causeType'; bron = [regex]::Match($body, '<com:value lang="nl">([^<]*)</com:value>').Groups[1].Value
            begin = Get-XmlWaarde $body 'com:overallStartTime'; eind = Get-XmlWaarde $body 'com:overallEndTime'
            vertraging_s = $vertraging; veiligheid = Get-XmlWaarde $body 'sit:safetyRelatedMessage'
            lat = $lat; lon = $lon; vild_locatie = Get-XmlWaarde $body 'loc:specificLocation'
        }
    }
    if ($meldingen.Count -eq 0) { throw 'NDW actueel beeld bevat geen meldingen; formaat veranderd?' }

    $map = Get-DataPath 'verstoringen'
    foreach ($d in 'weg', 'weg_aantallen') { New-Item -ItemType Directory -Force -Path (Join-Path $map $d) | Out-Null }
    $maand = (Get-Date).ToUniversalTime().ToString('yyyy-MM', $script:Inv)

    # Tellingen per type en subtype op dit moment.
    $tel = @{}
    foreach ($r in $meldingen.Values) {
        $k = $r.type + '|' + $r.subtype
        if (-not $tel.ContainsKey($k)) { $tel[$k] = @{ n = 0; vertraging = 0.0 } }
        $tel[$k].n++; if ($r.vertraging_s) { $tel[$k].vertraging += [double]::Parse($r.vertraging_s, $script:Inv) }
    }
    $rijen = foreach ($k in $tel.Keys) { $p = $k -split '\|', 2; @{ peilmoment = $script:RunStamp; type = $p[0]; subtype = $p[1]; aantal = $tel[$k].n; totale_vertraging_min = [math]::Round($tel[$k].vertraging / 60, 1) } }
    Add-CsvRows -Path (Join-Path (Join-Path $map 'weg_aantallen') "$maand.csv") -Columns 'peilmoment', 'type', 'subtype', 'aantal', 'totale_vertraging_min' -Rows @($rijen)

    # Logboek: elke melding staat in het maandbestand van de maand waarin hij voor het eerst gezien is.
    $status = Get-Status 'verstoringen_weg'
    $inMaand = @{}
    if ($status -and $status.actief) { foreach ($p in $status.actief.PSObject.Properties) { $inMaand[$p.Name] = [string]$p.Value } }
    $perMaand = @{}
    foreach ($id in $meldingen.Keys) { $mnd = if ($inMaand.ContainsKey($id)) { $inMaand[$id] } else { $maand }; if (-not $perMaand.ContainsKey($mnd)) { $perMaand[$mnd] = @() }; $perMaand[$mnd] += $id }
    $kolommen = 'melding_id', 'type', 'subtype', 'oorzaak', 'bron', 'begin', 'eind', 'vertraging_s', 'max_vertraging_s', 'veiligheid', 'lat', 'lon', 'vild_locatie', 'versie', 'eerst_gezien', 'laatst_gezien'
    $nieuw = 0
    foreach ($mnd in $perMaand.Keys) {
        $pad = Join-Path (Join-Path $map 'weg') "$mnd.csv"
        $bestaand = @{}
        if (Test-Path $pad) { foreach ($r in (Import-Csv $pad)) { $bestaand[$r.melding_id] = $r } }
        foreach ($id in $perMaand[$mnd]) {
            $n = $meldingen[$id]
            if ($bestaand.ContainsKey($id)) {
                $o = $bestaand[$id]
                foreach ($v in 'versie', 'subtype', 'oorzaak', 'eind', 'vertraging_s') { $o.$v = $n[$v] }
                if ($n.vertraging_s -and ((-not $o.max_vertraging_s) -or [double]::Parse($n.vertraging_s, $script:Inv) -gt [double]::Parse($o.max_vertraging_s, $script:Inv))) { $o.max_vertraging_s = $n.vertraging_s }
                $o.laatst_gezien = $script:RunStamp
            } else {
                $h = [ordered]@{}; foreach ($v in $kolommen) { $h[$v] = $n[$v] }
                $h.max_vertraging_s = $n.vertraging_s; $h.eerst_gezien = $script:RunStamp; $h.laatst_gezien = $script:RunStamp
                $bestaand[$id] = [pscustomobject]$h; $nieuw++
            }
        }
        if (Test-Path $pad) { Remove-Item $pad }
        Add-CsvRows -Path $pad -Columns $kolommen -Rows @($bestaand.Values)
    }
    $actief = @{}; foreach ($mnd in $perMaand.Keys) { foreach ($id in $perMaand[$mnd]) { $actief[$id] = $mnd } }
    Set-Status 'verstoringen_weg' @{ actief = $actief }
    return "weg: $($meldingen.Count) actieve meldingen, $nieuw nieuw"
}

function Invoke-VerstoringenSpoor {
    $status = Get-Status 'verstoringen_spoor'
    $verwerkt = @(); if ($status -and $status.verwerkt) { $verwerkt = @($status.verwerkt) }
    $vanaf = [datetime]::ParseExact($(if ($script:Cfg.RdtVanaf) { $script:Cfg.RdtVanaf } else { '2026-01' }), 'yyyy-MM', $script:Inv)
    $maxPerRun = if ($script:Cfg.RdtMaandenPerRun) { [int]$script:Cfg.RdtMaandenPerRun } else { 2 }
    $vorige = (Get-Date).Date.AddDays(1 - (Get-Date).Day).AddMonths(-1)
    $teDoen = @(); for ($d = $vanaf; $d -le $vorige; $d = $d.AddMonths(1)) { $m = $d.ToString('yyyy-MM', $script:Inv); if ($verwerkt -notcontains $m) { $teDoen += $m } }
    $teDoen = @($teDoen | Select-Object -First $maxPerRun)
    if ($teDoen.Count -eq 0) { return 'spoor: niets nieuws' }
    # Nog niet gepubliceerde maand hooguit één keer per dag opnieuw proberen (een HEAD-verzoek, zonder herhaalpogingen).
    if ($status -and $status.niet_gevonden -eq $teDoen[0] -and $status.gecontroleerd -eq $script:Today) { return "spoor: $($teDoen[0]) nog niet gepubliceerd" }
    try { Invoke-WebRequest -Uri ($script:RdtServices -f $teDoen[0]) -Method Head -UseBasicParsing -UserAgent $script:Cfg.UserAgent -TimeoutSec 60 | Out-Null }
    catch {
        if ("$($_.Exception.Message)" -match '404') {
            Set-Status 'verstoringen_spoor' @{ verwerkt = $verwerkt; niet_gevonden = $teDoen[0]; gecontroleerd = $script:Today }
            return "spoor: $($teDoen[0]) nog niet gepubliceerd"
        }
        throw
    }

    $map = Get-DataPath 'verstoringen'; New-Item -ItemType Directory -Force -Path (Join-Path $map 'spoor_per_station') | Out-Null
    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'realtime-verzamelaar'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $gedaan = @()
    foreach ($m in $teDoen) {
        $gz = Join-Path $tmp "services-$m.csv.gz"
        try { Invoke-Get -Uri ($script:RdtServices -f $m) -OutFile $gz -TimeoutSec 900 }
        catch { if ("$($_.Exception.Message)" -match '404') { break } else { throw } }   # maand nog niet gepubliceerd
        $agg = New-Object RdtAggregator
        $s = New-Object IO.Compression.GZipStream([IO.File]::OpenRead($gz), [IO.Compression.CompressionMode]::Decompress)
        $rd = New-Object IO.StreamReader($s, [Text.Encoding]::UTF8)
        try { $agg.Process($rd) } finally { $rd.Dispose(); Remove-Item $gz -ErrorAction SilentlyContinue }
        $dag = foreach ($k in $agg.PerDag.Keys) { $p = $k -split '\|'; $a = $agg.PerDag[$k]
            @{ datum = $p[0]; vervoerder = $p[1]; treinsoort = $p[2]; ritten = $a[0]; geheel_uitgevallen = $a[1]; deels_uitgevallen = $a[2]
               aankomsten = $a[3]; aankomsten_3min = $a[4]; aankomsten_5min = $a[5]; gem_vertraging_min = $(if ($a[3]) { [math]::Round($a[6] / $a[3], 2) } else { $null }); geannuleerde_aankomsten = $a[7] } }
        Add-CsvRows -Path (Join-Path $map 'spoor_per_dag.csv') -Columns 'datum', 'vervoerder', 'treinsoort', 'ritten', 'geheel_uitgevallen', 'deels_uitgevallen', 'aankomsten', 'aankomsten_3min', 'aankomsten_5min', 'gem_vertraging_min', 'geannuleerde_aankomsten' -Rows @($dag | Sort-Object { $_.datum })
        $st = foreach ($k in $agg.PerStation.Keys) { $p = $k -split '\|', 3; $a = $agg.PerStation[$k]; @{ datum = $p[0]; station_code = $p[1]; station = $p[2]; aankomsten = $a[0]; aankomsten_5min = $a[1]; geannuleerde_aankomsten = $a[2] } }
        $pad = Join-Path (Join-Path $map 'spoor_per_station') "$m.csv"; if (Test-Path $pad) { Remove-Item $pad }
        Add-CsvRows -Path $pad -Columns 'datum', 'station_code', 'station', 'aankomsten', 'aankomsten_5min', 'geannuleerde_aankomsten' -Rows @($st | Sort-Object { $_.datum }, { $_.station_code })
        $verwerkt += $m; $gedaan += "$m ($($agg.Regels) haltes)"
        Set-Status 'verstoringen_spoor' @{ verwerkt = $verwerkt }
    }
    if ($gedaan.Count -eq 0) { return "spoor: $($teDoen[0]) nog niet gepubliceerd" }
    return "spoor: " + ($gedaan -join ', ')
}

function Invoke-BronVerstoringen {
    $uit = @()
    $fout = $null
    try { $uit += Invoke-VerstoringenWeg } catch { $fout = "weg: $($_.Exception.Message)" }
    try { $uit += Invoke-VerstoringenSpoor } catch { $fout = (@($fout, "spoor: $($_.Exception.Message)") | Where-Object { $_ }) -join '; ' }
    if ($fout) { throw ((@($uit) + @($fout)) -join '; ') }
    return ($uit -join '; ')
}
