# DOT-NL (NDW): alle publieke laadpunten in NL met status en tarieven (OCPI, open, geen key).
# Elke run is een momentopname: per exploitant elke run, per plaats een keer per dag (maandbestanden in data/laadpunten/).
# De status per laadpunt, elke 5 minuten, staat in de hoogfrequente verzamelaar (hoogfrequent/).

$script:LpStatussen = 'AVAILABLE', 'CHARGING', 'BLOCKED', 'RESERVED', 'OUTOFORDER', 'INOPERATIVE', 'PLANNED', 'REMOVED', 'UNKNOWN'

function Get-LaadpuntenMap { param([string]$Naam) $m = Join-Path (Get-DataPath 'laadpunten') $Naam; New-Item -ItemType Directory -Force -Path $m | Out-Null; $m }

# Eenmalig: de oude doorlopende bestanden opsplitsen in maandbestanden (per_plaats groeide te hard voor git).
# Regel voor regel (de eerste kolom is peilmoment, JJJJ-MM-...), want Import-Csv is op 30 MB te traag.
function Move-LaadpuntenOudeBestanden {
    foreach ($naam in 'per_exploitant', 'per_plaats') {
        $pad = Get-DataPath "laadpunten_$naam.csv"
        if (-not (Test-Path $pad)) { continue }
        $map = Get-LaadpuntenMap $naam
        $kop = $null; $perMaand = @{}
        foreach ($regel in [IO.File]::ReadLines($pad)) {
            if ($null -eq $kop) { $kop = $regel.TrimStart([char]0xFEFF); continue }
            if ($regel.Length -lt 7) { continue }
            $m = $regel.Substring(0, 7)
            if (-not $perMaand.ContainsKey($m)) { $perMaand[$m] = New-Object Text.StringBuilder }
            [void]$perMaand[$m].AppendLine($regel)
        }
        foreach ($m in $perMaand.Keys) {
            $doel = Join-Path $map ($m + '.csv')
            $tekst = $(if (Test-Path $doel) { '' } else { $kop + "`r`n" }) + $perMaand[$m].ToString()
            [IO.File]::AppendAllText($doel, $tekst, $script:Utf8Bom)
        }
        Remove-Item -Path $pad
    }
}

# Niet elke exploitant geeft zijn status live door aan NDW. Deze indeling, elke dag opnieuw uit de uurtellingen van de
# afgelopen 7 dagen, zegt per exploitant wat de data waard is:
#   live             'aan het laden' verandert in >= 60% van de uren: echte wisseltijden, bruikbaar per 5 minuten
#   per 6 uur        wisselt vrijwel alleen om 04, 10, 16 en 22 uur UTC: alleen die vier standen per dag zijn betrouwbaar
#   deels aanwezig   staat maar een deel van de uren in de feed (bv. Enviem: 12 uur per dag)
#   bevroren         status verandert (bijna) nooit
#   onregelmatig     geen duidelijk patroon (vaak kleine exploitanten)
#   klein            minder dan 25 laadpunten: te weinig om te beoordelen
#   te kort gemeten  minder dan 48 uurmetingen (bv. een net aangesloten exploitant)
function Update-LaadpuntenIndeling {
    $map = Get-LaadpuntenMap 'per_exploitant'
    $nu = (Get-Date).ToUniversalTime()
    $vanaf = $nu.AddDays(-7).ToString('yyyy-MM-ddTHH', $script:Inv)
    $maanden = @($nu.AddDays(-7).ToString('yyyy-MM', $script:Inv), $nu.ToString('yyyy-MM', $script:Inv)) | Select-Object -Unique
    # Een meting per uur: de vaste uurrun (hh:05 tot hh:20); extra runs halverwege het uur tellen niet mee.
    $perUur = @{}
    foreach ($m in $maanden) {
        $f = Join-Path $map ($m + '.csv')
        if (-not (Test-Path $f)) { continue }
        foreach ($r in (Import-Csv $f)) {
            $uur = $r.peilmoment.Substring(0, 13); $min = [int]$r.peilmoment.Substring(14, 2)
            if ($uur -lt $vanaf -or $min -gt 20) { continue }
            if (-not $perUur.ContainsKey($uur)) { $perUur[$uur] = @{ t = $r.peilmoment; rijen = @{} } }
            if ($r.peilmoment -ne $perUur[$uur].t) { continue }
            $perUur[$uur].rijen[$r.exploitant] = $r
        }
    }
    $uren = @($perUur.Keys | Sort-Object)
    if ($uren.Count -lt 24) { return "indeling overgeslagen: pas $($uren.Count) uurmetingen" }
    $exploitanten = @($perUur.Values | ForEach-Object { $_.rijen.Keys } | Sort-Object -Unique | Where-Object { $_ -ne '_totaal' })
    $batch = '04', '10', '16', '22'
    $rijen = foreach ($op in $exploitanten) {
        $aanwezig = 0; $stappen = 0; $veranderd = 0; $opBatch = 0; $min = [int]::MaxValue; $max = 0; $vorige = $null; $vorigUur = $null
        foreach ($u in $uren) {
            $r = $perUur[$u].rijen[$op]
            if (-not $r) { $vorige = $null; continue }
            $aanwezig++; $n = [int]$r.evses; if ($n -lt $min) { $min = $n }; if ($n -gt $max) { $max = $n }
            $tijd = [datetime]::ParseExact($u, 'yyyy-MM-ddTHH', $script:Inv)
            if ($vorige -and ($tijd - $vorigUur).TotalHours -eq 1) {
                $stappen++
                if ($vorige.charging -ne $r.charging) { $veranderd++; if ($batch -contains $u.Substring(11, 2)) { $opBatch++ } }
            }
            $vorige = $r; $vorigUur = $tijd
        }
        $fracAanwezig = $aanwezig / $uren.Count
        $fracVeranderd = $(if ($stappen) { $veranderd / $stappen } else { 0 })
        $fracBatch = $(if ($veranderd) { $opBatch / $veranderd } else { 0 })
        $groep = if ($aanwezig -lt 48) { 'te kort gemeten' }
                 elseif ($max -lt 25) { 'klein' }
                 elseif ($fracAanwezig -lt 0.8 -or $min -lt 0.5 * $max) { 'deels aanwezig' }
                 elseif ($fracVeranderd -ge 0.6) { 'live' }
                 elseif ($veranderd -ge 5 -and $fracBatch -ge 0.8) { 'per 6 uur' }
                 elseif ($veranderd -le 2) { 'bevroren' }
                 else { 'onregelmatig' }
        @{ peildatum = $script:Today; exploitant = $op; groep = $groep; laadpunten = $max; uren_gemeten = $aanwezig
           aandeel_uren_aanwezig = [math]::Round($fracAanwezig, 3); aandeel_uren_veranderd = [math]::Round($fracVeranderd, 3)
           aandeel_wissels_op_batchuur = [math]::Round($fracBatch, 3); periode_van = $uren[0] + ':00Z'; periode_tot = $uren[-1] + ':00Z' }
    }
    $kol = 'peildatum', 'exploitant', 'groep', 'laadpunten', 'uren_gemeten', 'aandeel_uren_aanwezig', 'aandeel_uren_veranderd', 'aandeel_wissels_op_batchuur', 'periode_van', 'periode_tot'
    $pad = Join-Path (Get-DataPath 'laadpunten') 'exploitant_indeling.csv'
    if (Test-Path $pad) { Remove-Item $pad }
    Add-CsvRows -Path $pad -Columns $kol -Rows @($rijen | Sort-Object { $_.groep }, { - $_.laadpunten })
    Add-CsvRows -Path (Join-Path (Get-DataPath 'laadpunten') 'exploitant_indeling_historie.csv') -Columns $kol -Rows @($rijen)
    $live = @($rijen | Where-Object { $_.groep -eq 'live' })
    $somLive = 0; foreach ($r in $live) { $somLive += $r.laadpunten }
    $som = 0; foreach ($r in $rijen) { $som += $r.laadpunten }
    return "indeling: $($live.Count) van $(@($rijen).Count) exploitanten live ($([math]::Round(100 * $somLive / [math]::Max(1, $som)))% van de laadpunten)"
}

function Invoke-BronLaadpunten {
    $tmpDir = Join-Path ([IO.Path]::GetTempPath()) 'realtime-verzamelaar'
    New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
    $locGz = Join-Path $tmpDir 'locaties.json.gz'
    $tarGz = Join-Path $tmpDir 'tarieven.json.gz'
    Invoke-Get -Uri 'https://opendata.ndw.nu/charging_point_tariffs_ocpi.json.gz' -OutFile $tarGz
    Suspend-Beleefd
    Invoke-Get -Uri 'https://opendata.ndw.nu/charging_point_locations_ocpi.json.gz' -OutFile $locGz
    foreach ($p in @(@{ s = $tarGz; n = 'tarieven.json.gz' }, @{ s = $locGz; n = 'locaties.json.gz' })) {
        $doel = Get-RuwPad 'laadpunten' $p.n
        if (-not (Test-Path $doel)) { Copy-Item $p.s $doel }   # een ruwe kopie per dag
    }

    # Tarieven: prijs per kWh (eerste ENERGY-component) per party_id|tarief-id.
    $kwh = @{}
    foreach ($s in (Get-GzipJsonElements $tarGz)) {
        $t = $s | ConvertFrom-Json
        foreach ($el in @($t.elements)) {
            $e = @($el.price_components) | Where-Object { $_.type -eq 'ENERGY' } | Select-Object -First 1
            if ($e) { $kwh[([string]$t.party_id + '|' + [string]$t.id)] = [double]$e.price; break }
        }
    }

    $perOp = @{}; $perPlaats = @{}
    $nieuwAgg = { $h = @{ locaties = 0; evses = 0; evses_dc = 0; prijzen_ac = (New-Object System.Collections.Generic.List[double]); prijzen_dc = (New-Object System.Collections.Generic.List[double]) }
                  foreach ($st in $script:LpStatussen) { $h[$st] = 0 }; $h }
    foreach ($s in (Get-GzipJsonElements $locGz)) {
        $loc = $s | ConvertFrom-Json
        $op = if ($loc.operator -and $loc.operator.name) { [string]$loc.operator.name } else { [string]$loc.party_id }
        $plaats = [string]$loc.city
        foreach ($sleutel in @(@{ tbl = $perOp; k = $op }, @{ tbl = $perOp; k = '_totaal' }, @{ tbl = $perPlaats; k = $plaats })) {
            if (-not $sleutel.tbl.ContainsKey($sleutel.k)) { $sleutel.tbl[$sleutel.k] = & $nieuwAgg }
            $sleutel.tbl[$sleutel.k].locaties++
        }
        foreach ($evse in @($loc.evses)) {
            $st = [string]$evse.status; if ($script:LpStatussen -notcontains $st) { $st = 'UNKNOWN' }
            $conns = @($evse.connectors)
            $dc = [bool](@($conns | Where-Object { [string]$_.power_type -like 'DC*' }).Count)
            $prijs = $null
            foreach ($c in $conns) { foreach ($tid in @($c.tariff_ids)) { $k = [string]$loc.party_id + '|' + [string]$tid; if ($kwh.ContainsKey($k)) { $prijs = $kwh[$k]; break } }; if ($null -ne $prijs) { break } }
            foreach ($agg in @($perOp[$op], $perOp['_totaal'], $perPlaats[$plaats])) {
                $agg.evses++; $agg[$st]++
                if ($dc) { $agg.evses_dc++ }
                if ($null -ne $prijs -and $prijs -gt 0) { if ($dc) { $agg.prijzen_dc.Add($prijs) } else { $agg.prijzen_ac.Add($prijs) } }
            }
        }
    }

    $bronTijd = (Get-Item $locGz).LastWriteTimeUtc.ToString('yyyy-MM-ddTHH:mm:ssZ', $script:Inv)
    $maakRij = { param($naamKol, $naam, $a)
        $r = @{ peilmoment = $script:RunStamp; $naamKol = $naam; locaties = $a.locaties; evses = $a.evses; evses_dc = $a.evses_dc
                mediaan_kwh_ac = (Get-Mediaan $a.prijzen_ac.ToArray()); mediaan_kwh_dc = (Get-Mediaan $a.prijzen_dc.ToArray()) }
        foreach ($st in $script:LpStatussen) { $r[$st.ToLower()] = $a[$st] }
        $r }
    $statusKol = $script:LpStatussen | ForEach-Object { $_.ToLower() }
    Move-LaadpuntenOudeBestanden
    $maand = (Get-Date).ToUniversalTime().ToString('yyyy-MM', $script:Inv) + '.csv'
    $opRijen = foreach ($k in ($perOp.Keys | Sort-Object)) { & $maakRij 'exploitant' $k $perOp[$k] }
    Add-CsvRows -Path (Join-Path (Get-LaadpuntenMap 'per_exploitant') $maand) -Columns (@('peilmoment', 'exploitant', 'locaties', 'evses', 'evses_dc') + $statusKol + @('mediaan_kwh_ac', 'mediaan_kwh_dc')) -Rows @($opRijen)
    # Per plaats (~2.500 plaatsen) een keer per dag; elk uur zou ruim 100 MB per maand opleveren.
    # Ook een keer per dag: de indeling van exploitanten naar hoe vaak hun status ververst.
    $oud = Get-Status 'laadpunten'
    $status = @{ per_plaats_peildatum = $(if ($oud) { $oud.per_plaats_peildatum }); indeling_peildatum = $(if ($oud) { $oud.indeling_peildatum }) }
    $extra = ''
    if ($status.per_plaats_peildatum -ne $script:Today) {
        $plRijen = foreach ($k in ($perPlaats.Keys | Sort-Object)) { & $maakRij 'plaats' $k $perPlaats[$k] }
        Add-CsvRows -Path (Join-Path (Get-LaadpuntenMap 'per_plaats') $maand) -Columns (@('peilmoment', 'plaats', 'locaties', 'evses', 'evses_dc') + $statusKol + @('mediaan_kwh_ac', 'mediaan_kwh_dc')) -Rows @($plRijen)
        $status.per_plaats_peildatum = $script:Today
    }
    if ($status.indeling_peildatum -ne $script:Today) {
        $extra = '; ' + (Update-LaadpuntenIndeling)
        $status.indeling_peildatum = $script:Today
    }
    Set-Status 'laadpunten' $status

    $tot = $perOp['_totaal']
    return "$($tot.locaties) locaties, $($tot.evses) laadpunten ($($tot.CHARGING) aan het laden); bestand van $bronTijd$extra"
}
