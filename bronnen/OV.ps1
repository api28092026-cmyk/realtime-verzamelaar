# OV: GTFS en GTFS-realtime van OVapi (gtfs.ovapi.nl). Open data van de vervoerders, zonder registratie.
# OVapi vraagt: identificeer je in de User-Agent en vraag niet vaker dan eens per minuut (zie config.psd1).
#  - Elke run: live-stand van alle ritten (bus, tram, metro, veerboot en trein) samengevat per vervoerder en
#    modaliteit: ritten, uitgevallen ritten, vertraging. Ruwe realtime-data wordt niet bewaard.
#  - Elke run: storingsmeldingen (GTFS-RT alerts) als logboek: oorzaak, effect, vervoerders, tekst, periode.
#  - Eén keer per dag: de dienstregeling (gtfs-nl.zip, ~230 MB) samengevat tot geplande ritten per vervoerder,
#    modaliteit en dag voor de komende 14 dagen; plus een routetabel waarmee de live-data aan vervoerders wordt gekoppeld.

$script:OvBasis = 'https://gtfs.ovapi.nl/nl'

if (-not ('GtfsRt' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
public class PbReader {
    byte[] b; int p, end;
    public PbReader(byte[] buf, int start, int stop) { b = buf; p = start; end = stop; }
    public bool Next(out int field, out int wt) {
        if (p >= end) { field = 0; wt = 0; return false; }
        ulong k = Varint(); field = (int)(k >> 3); wt = (int)(k & 7); return true;
    }
    public ulong Varint() { ulong r = 0; int s = 0; while (true) { byte x = b[p++]; r |= (ulong)(x & 0x7F) << s; if ((x & 0x80) == 0) return r; s += 7; } }
    public PbReader Sub() { int len = (int)Varint(); PbReader r = new PbReader(b, p, p + len); p += len; return r; }
    public string Str() { int len = (int)Varint(); string s = Encoding.UTF8.GetString(b, p, len); p += len; return s; }
    public void Skip(int wt) {
        if (wt == 0) Varint(); else if (wt == 1) p += 8; else if (wt == 2) { int len = (int)Varint(); p += len; } else if (wt == 5) p += 4;
        else throw new Exception("Onbekend protobuf-wiretype " + wt);
    }
}
public class RtTrip { public string RouteId = "", TripId = "", StartDate = ""; public int Relatie; public bool HeeftVertraging; public int Vertraging; }
public class RtAlert { public string Id = "", Kop = "", KopTaal = ""; public int Oorzaak, Effect; public ulong Begin, Eind; public HashSet<string> Vervoerders = new HashSet<string>(); public HashSet<string> Routes = new HashSet<string>(); }
public class GtfsRt {
    public ulong Tijdstempel;
    public List<RtTrip> Ritten = new List<RtTrip>();
    public List<RtAlert> Meldingen = new List<RtAlert>();
    public static GtfsRt Parse(byte[] data) {
        GtfsRt g = new GtfsRt(); PbReader r = new PbReader(data, 0, data.Length); int f, wt;
        while (r.Next(out f, out wt)) {
            if (f == 1 && wt == 2) { PbReader h = r.Sub(); while (h.Next(out f, out wt)) { if (f == 3 && wt == 0) g.Tijdstempel = h.Varint(); else h.Skip(wt); } }
            else if (f == 2 && wt == 2) g.Entiteit(r.Sub());
            else r.Skip(wt);
        }
        return g;
    }
    void Entiteit(PbReader e) {
        string id = ""; int f, wt;
        while (e.Next(out f, out wt)) {
            if (f == 1 && wt == 2) id = e.Str();
            else if (f == 3 && wt == 2) Ritten.Add(Rit(e.Sub()));
            else if (f == 5 && wt == 2) { RtAlert a = Melding(e.Sub()); a.Id = id; Meldingen.Add(a); }
            else e.Skip(wt);
        }
    }
    static int Int32(ulong v) { return (int)(long)v; }
    static RtTrip Rit(PbReader t) {
        RtTrip rit = new RtTrip(); int f, wt; bool eigen = false; int eigenV = 0; bool stu = false; int stuV = 0;
        while (t.Next(out f, out wt)) {
            if (f == 1 && wt == 2) {
                PbReader d = t.Sub();
                while (d.Next(out f, out wt)) {
                    if (f == 1 && wt == 2) rit.TripId = d.Str(); else if (f == 3 && wt == 2) rit.StartDate = d.Str();
                    else if (f == 4 && wt == 0) rit.Relatie = (int)d.Varint(); else if (f == 5 && wt == 2) rit.RouteId = d.Str(); else d.Skip(wt);
                }
            } else if (f == 2 && wt == 2) {
                PbReader s = t.Sub();
                while (s.Next(out f, out wt)) {
                    if ((f == 2 || f == 3) && wt == 2 && !stu) {
                        PbReader ev = s.Sub();
                        while (ev.Next(out f, out wt)) { if (f == 1 && wt == 0) { stuV = Int32(ev.Varint()); stu = true; } else ev.Skip(wt); }
                    } else s.Skip(wt);
                }
            } else if (f == 5 && wt == 0) { eigenV = Int32(t.Varint()); eigen = true; }
            else t.Skip(wt);
        }
        if (eigen) { rit.HeeftVertraging = true; rit.Vertraging = eigenV; } else if (stu) { rit.HeeftVertraging = true; rit.Vertraging = stuV; }
        return rit;
    }
    static RtAlert Melding(PbReader a) {
        RtAlert m = new RtAlert(); int f, wt;
        while (a.Next(out f, out wt)) {
            if (f == 1 && wt == 2) {
                PbReader tr = a.Sub(); ulong s = 0, e = 0;
                while (tr.Next(out f, out wt)) { if (f == 1 && wt == 0) s = tr.Varint(); else if (f == 2 && wt == 0) e = tr.Varint(); else tr.Skip(wt); }
                if (s > 0 && (m.Begin == 0 || s < m.Begin)) m.Begin = s;
                if (e > m.Eind) m.Eind = e;
            } else if (f == 5 && wt == 2) {
                PbReader sel = a.Sub();
                while (sel.Next(out f, out wt)) { if (f == 1 && wt == 2) m.Vervoerders.Add(sel.Str()); else if (f == 2 && wt == 2) m.Routes.Add(sel.Str()); else sel.Skip(wt); }
            } else if (f == 6 && wt == 0) m.Oorzaak = (int)a.Varint();
            else if (f == 7 && wt == 0) m.Effect = (int)a.Varint();
            else if (f == 10 && wt == 2) {
                PbReader ts = a.Sub();
                while (ts.Next(out f, out wt)) {
                    if (f == 1 && wt == 2) {
                        PbReader tl = ts.Sub(); string tekst = "", taal = "";
                        while (tl.Next(out f, out wt)) { if (f == 1 && wt == 2) tekst = tl.Str(); else if (f == 2 && wt == 2) taal = tl.Str(); else tl.Skip(wt); }
                        if (m.Kop.Length == 0 || taal == "nl") { m.Kop = tekst; m.KopTaal = taal; }
                    } else ts.Skip(wt);
                }
            } else a.Skip(wt);
        }
        return m;
    }
}
public static class GtfsStatisch {
    public static string[] Split(string l) {
        if (l.IndexOf('"') < 0) return l.Split(',');
        List<string> uit = new List<string>(); StringBuilder sb = new StringBuilder(); bool q = false;
        for (int i = 0; i < l.Length; i++) {
            char c = l[i];
            if (q) { if (c == '"') { if (i + 1 < l.Length && l[i + 1] == '"') { sb.Append('"'); i++; } else q = false; } else sb.Append(c); }
            else if (c == '"') q = true; else if (c == ',') { uit.Add(sb.ToString()); sb.Length = 0; } else sb.Append(c);
        }
        uit.Add(sb.ToString()); return uit.ToArray();
    }
    public static Dictionary<string, int> Kolommen(string kop) {
        Dictionary<string, int> d = new Dictionary<string, int>(); string[] k = Split(kop.TrimStart((char)0xFEFF));
        for (int i = 0; i < k.Length; i++) d[k[i].Trim()] = i; return d;
    }
    // Geplande ritten per route per dag binnen [vanaf, tot]; trips.txt en calendar_dates.txt (OVapi gebruikt geen calendar.txt).
    public static Dictionary<string, int> RittenPerRouteEnDag(TextReader trips, TextReader kalender, string vanaf, string tot) {
        Dictionary<string, List<string>> dagen = new Dictionary<string, List<string>>();
        Dictionary<string, int> k = Kolommen(kalender.ReadLine()); string l;
        int iS = k["service_id"], iD = k["date"], iE = k["exception_type"];
        while ((l = kalender.ReadLine()) != null) {
            string[] f = Split(l); if (f.Length <= iE || f[iE] != "1") continue;
            string d = f[iD]; if (string.CompareOrdinal(d, vanaf) < 0 || string.CompareOrdinal(d, tot) > 0) continue;
            List<string> lijst; if (!dagen.TryGetValue(f[iS], out lijst)) { lijst = new List<string>(); dagen[f[iS]] = lijst; } lijst.Add(d);
        }
        Dictionary<string, int> uit = new Dictionary<string, int>();
        k = Kolommen(trips.ReadLine()); int iR = k["route_id"], iT = k["service_id"];
        while ((l = trips.ReadLine()) != null) {
            string[] f = Split(l); if (f.Length <= Math.Max(iR, iT)) continue;
            List<string> lijst; if (!dagen.TryGetValue(f[iT], out lijst)) continue;
            foreach (string d in lijst) { string key = f[iR] + "|" + d; int n; uit.TryGetValue(key, out n); uit[key] = n + 1; }
        }
        return uit;
    }
}
'@
}

$script:OvModaliteit = @{ '0' = 'tram'; '1' = 'metro'; '2' = 'trein'; '3' = 'bus'; '4' = 'veerboot'; '5' = 'kabeltram'; '6' = 'kabelbaan'; '7' = 'kabelspoor'; '11' = 'trolleybus'; '12' = 'monorail' }
$script:OvOorzaak = @{ 1 = 'onbekend'; 2 = 'overig'; 3 = 'technisch probleem'; 4 = 'staking'; 5 = 'demonstratie'; 6 = 'ongeval'; 7 = 'feestdag'; 8 = 'weer'; 9 = 'onderhoud'; 10 = 'werkzaamheden'; 11 = 'politie-inzet'; 12 = 'medisch noodgeval' }
$script:OvEffect = @{ 1 = 'geen dienst'; 2 = 'minder dienst'; 3 = 'flinke vertraging'; 4 = 'omleiding'; 5 = 'extra dienst'; 6 = 'aangepaste dienst'; 7 = 'overig'; 8 = 'onbekend'; 9 = 'halte verplaatst'; 10 = 'geen effect'; 11 = 'toegankelijkheid' }

# Basistypen (0-12) en de uitgebreide typen (100 trein, 200 touringcar, 400 metro, 700 bus, 900 tram, 1000 veerboot, ...).
function Get-OvModaliteit {
    param($Type)
    $t = [string]$Type
    if ($script:OvModaliteit.ContainsKey($t)) { return $script:OvModaliteit[$t] }
    $n = 0; if (-not [int]::TryParse($t, [ref]$n)) { return 'onbekend' }
    if ($n -ge 100 -and $n -lt 200) { return 'trein' }
    if ($n -ge 200 -and $n -lt 300) { return 'touringcar' }
    if ($n -ge 400 -and $n -lt 500) { return 'metro' }
    if ($n -ge 700 -and $n -lt 800) { return 'bus' }
    if ($n -ge 900 -and $n -lt 1000) { return 'tram' }
    if ($n -ge 1000 -and $n -lt 1300) { return 'veerboot' }
    return "type $t"
}

function Update-OvStatisch {
    # Eén keer per dag: dienstregeling ophalen, routetabel verversen en geplande ritten per dag samenvatten.
    $status = Get-Status 'ov'
    $routesPad = Join-Path (Get-DataPath 'ov') 'routes.csv'
    if ($status -and $status.dienstregeling_peildatum -eq $script:Today -and (Test-Path $routesPad)) { return $null }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'realtime-verzamelaar'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $zip = Join-Path $tmp 'gtfs-nl.zip'
    Invoke-Get -Uri "$script:OvBasis/gtfs-nl.zip" -OutFile $zip -TimeoutSec 900
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $open = { param($naam) $e = $z.Entries | Where-Object { $_.Name -eq $naam } | Select-Object -First 1; if (-not $e) { throw "$naam ontbreekt in gtfs-nl.zip" }; New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8) }
        $rd = & $open 'agency.txt'; $k = [GtfsStatisch]::Kolommen($rd.ReadLine()); $vervoerders = @{}
        while ($null -ne ($l = $rd.ReadLine())) { $f = [GtfsStatisch]::Split($l); $vervoerders[$f[$k['agency_id']]] = $f[$k['agency_name']] }; $rd.Dispose()
        $rd = & $open 'routes.txt'; $k = [GtfsStatisch]::Kolommen($rd.ReadLine()); $routes = New-Object System.Collections.ArrayList
        while ($null -ne ($l = $rd.ReadLine())) {
            $f = [GtfsStatisch]::Split($l); $aid = $f[$k['agency_id']]
            [void]$routes.Add([pscustomobject]@{ route_id = $f[$k['route_id']]; vervoerder_id = $aid; vervoerder = $vervoerders[$aid]; modaliteit = (Get-OvModaliteit $f[$k['route_type']]); lijn = $f[$k['route_short_name']] })
        }
        $rd.Dispose()
        $vanaf = (Get-Date).ToString('yyyyMMdd', $script:Inv); $tot = (Get-Date).AddDays(13).ToString('yyyyMMdd', $script:Inv)
        $trips = & $open 'trips.txt'; $kal = & $open 'calendar_dates.txt'
        try { $perRoute = [GtfsStatisch]::RittenPerRouteEnDag($trips, $kal, $vanaf, $tot) } finally { $trips.Dispose(); $kal.Dispose() }
    } finally { $z.Dispose(); Remove-Item $zip -ErrorAction SilentlyContinue }

    $map = Get-DataPath 'ov'; New-Item -ItemType Directory -Force -Path (Join-Path $map 'dienstregeling') | Out-Null
    if (Test-Path $routesPad) { Remove-Item $routesPad }
    Add-CsvRows -Path $routesPad -Columns 'route_id', 'vervoerder_id', 'vervoerder', 'modaliteit', 'lijn' -Rows @($routes)
    $idx = @{}; foreach ($r in $routes) { $idx[$r.route_id] = $r }
    $tel = @{}
    foreach ($key in $perRoute.Keys) {
        $p = $key -split '\|'; $r = $idx[$p[0]]
        $k2 = $(if ($r) { "$($r.vervoerder)|$($r.modaliteit)" } else { 'onbekend|onbekend' }) + '|' + $p[1]
        $tel[$k2] = [int]$tel[$k2] + $perRoute[$key]
    }
    $rijen = foreach ($key in $tel.Keys) { $p = $key -split '\|'; @{ peildatum = $script:Today; datum = $p[2]; vervoerder = $p[0]; modaliteit = $p[1]; geplande_ritten = $tel[$key] } }
    Add-CsvRows -Path (Join-Path (Join-Path $map 'dienstregeling') ((Get-Date).ToString('yyyy-MM', $script:Inv) + '.csv')) `
        -Columns 'peildatum', 'datum', 'vervoerder', 'modaliteit', 'geplande_ritten' -Rows @($rijen | Sort-Object { $_.datum }, { $_.vervoerder })
    Set-Status 'ov' @{ dienstregeling_peildatum = $script:Today }
    $som = 0; foreach ($v in $perRoute.Values) { $som += $v }
    return "dienstregeling: $($routes.Count) lijnen, $som geplande ritten in 14 dagen"
}

function Invoke-BronOV {
    $uit = @()
    $statisch = Update-OvStatisch
    if ($statisch) { $uit += $statisch }
    $idx = @{}
    foreach ($r in (Import-Csv (Join-Path (Get-DataPath 'ov') 'routes.csv'))) { $idx[$r.route_id] = $r }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'realtime-verzamelaar'; New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $maand = (Get-Date).ToUniversalTime().ToString('yyyy-MM', $script:Inv)
    $map = Get-DataPath 'ov'; foreach ($d in 'realtime', 'meldingen') { New-Item -ItemType Directory -Force -Path (Join-Path $map $d) | Out-Null }

    # Live-stand van de ritten, per vervoerder en modaliteit.
    $rijen = New-Object System.Collections.ArrayList
    $meldingen = @{}
    foreach ($feed in @(@{ naam = 'tripUpdates'; soort = 'bus/tram/metro/veer' }, @{ naam = 'trainUpdates'; soort = 'trein' }, @{ naam = 'alerts'; soort = 'meldingen' })) {
        $pb = Join-Path $tmp "$($feed.naam).pb"
        Invoke-Get -Uri "$script:OvBasis/$($feed.naam).pb" -OutFile $pb -TimeoutSec 180
        $g = [GtfsRt]::Parse([IO.File]::ReadAllBytes($pb)); Remove-Item $pb -ErrorAction SilentlyContinue
        $bronTijd = if ($g.Tijdstempel) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$g.Tijdstempel).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', $script:Inv) } else { '' }
        foreach ($a in $g.Meldingen) { $meldingen[$a.Id] = $a }
        if ($g.Ritten.Count -eq 0) { continue }
        $agg = @{}
        foreach ($t in $g.Ritten) {
            $r = $idx[$t.RouteId]
            $k = if ($r) { "$($r.vervoerder)|$($r.modaliteit)" } else { 'onbekend|' + $(if ($feed.naam -eq 'trainUpdates') { 'trein' } else { 'onbekend' }) }
            if (-not $agg.ContainsKey($k)) { $agg[$k] = @{ ritten = 0; uitgevallen = 0; met = 0; v3 = 0; v5 = 0; som = 0.0 } }
            $a = $agg[$k]; $a.ritten++
            if ($t.Relatie -eq 3) { $a.uitgevallen++; continue }
            if ($t.HeeftVertraging -and [Math]::Abs($t.Vertraging) -lt 7200) {
                $a.met++; $a.som += $t.Vertraging
                if ($t.Vertraging -ge 180) { $a.v3++ }; if ($t.Vertraging -ge 300) { $a.v5++ }
            }
        }
        foreach ($k in $agg.Keys) {
            $p = $k -split '\|'; $a = $agg[$k]
            [void]$rijen.Add(@{ peilmoment = $script:RunStamp; bron_tijd = $bronTijd; feed = $feed.naam; vervoerder = $p[0]; modaliteit = $p[1]; ritten = $a.ritten; uitgevallen = $a.uitgevallen
                ritten_met_vertraging_info = $a.met; vertraagd_3min = $a.v3; vertraagd_5min = $a.v5; gem_vertraging_s = $(if ($a.met) { [math]::Round($a.som / $a.met, 1) } else { $null }) })
        }
    }
    if ($rijen.Count -eq 0) { throw 'Geen ritten in de GTFS-realtime-feeds; formaat veranderd?' }
    Add-CsvRows -Path (Join-Path (Join-Path $map 'realtime') "$maand.csv") -Columns 'peilmoment', 'bron_tijd', 'feed', 'vervoerder', 'modaliteit', 'ritten', 'uitgevallen', 'ritten_met_vertraging_info', 'vertraagd_3min', 'vertraagd_5min', 'gem_vertraging_s' -Rows $rijen
    $totRitten = 0; $totUit = 0; foreach ($r in $rijen) { $totRitten += $r.ritten; $totUit += $r.uitgevallen }
    $uit += "live: $totRitten ritten, $totUit uitgevallen"

    # Storingsmeldingen als logboek (in het maandbestand van de maand waarin ze voor het eerst gezien zijn).
    $status = Get-Status 'ov_meldingen'
    $inMaand = @{}; if ($status -and $status.actief) { foreach ($p in $status.actief.PSObject.Properties) { $inMaand[$p.Name] = [string]$p.Value } }
    $kolommen = 'melding_id', 'oorzaak', 'effect', 'vervoerders', 'aantal_lijnen', 'kop', 'begin', 'eind', 'eerst_gezien', 'laatst_gezien'
    $perMaand = @{}; foreach ($id in $meldingen.Keys) { $m = if ($inMaand.ContainsKey($id)) { $inMaand[$id] } else { $maand }; if (-not $perMaand.ContainsKey($m)) { $perMaand[$m] = @() }; $perMaand[$m] += $id }
    $utc = { param($s) if ($s) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$s).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', $script:Inv) } else { '' } }
    $nieuw = 0
    foreach ($m in $perMaand.Keys) {
        $pad = Join-Path (Join-Path $map 'meldingen') "$m.csv"
        $bestaand = @{}; if (Test-Path $pad) { foreach ($r in (Import-Csv $pad)) { $bestaand[$r.melding_id] = $r } }
        foreach ($id in $perMaand[$m]) {
            $a = $meldingen[$id]
            $vv = (@($a.Vervoerders) | ForEach-Object { $_ } | Sort-Object) -join ' '
            if ($bestaand.ContainsKey($id)) { $o = $bestaand[$id]; $o.eind = & $utc $a.Eind; $o.kop = $a.Kop; $o.effect = $script:OvEffect[$a.Effect]; $o.laatst_gezien = $script:RunStamp }
            else {
                $bestaand[$id] = [pscustomobject]([ordered]@{ melding_id = $id; oorzaak = $script:OvOorzaak[$a.Oorzaak]; effect = $script:OvEffect[$a.Effect]; vervoerders = $vv; aantal_lijnen = $a.Routes.Count
                    kop = $a.Kop.Replace("`r", ' ').Replace("`n", ' '); begin = & $utc $a.Begin; eind = & $utc $a.Eind; eerst_gezien = $script:RunStamp; laatst_gezien = $script:RunStamp }); $nieuw++
            }
        }
        if (Test-Path $pad) { Remove-Item $pad }
        Add-CsvRows -Path $pad -Columns $kolommen -Rows @($bestaand.Values)
    }
    $actief = @{}; foreach ($m in $perMaand.Keys) { foreach ($id in $perMaand[$m]) { $actief[$id] = $m } }
    Set-Status 'ov_meldingen' @{ actief = $actief }
    $uit += "meldingen: $($meldingen.Count) actief, $nieuw nieuw"
    return ($uit -join '; ')
}
