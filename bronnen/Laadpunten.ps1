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
    $status = Get-Status 'laadpunten'
    if (-not $status -or $status.per_plaats_peildatum -ne $script:Today) {
        $plRijen = foreach ($k in ($perPlaats.Keys | Sort-Object)) { & $maakRij 'plaats' $k $perPlaats[$k] }
        Add-CsvRows -Path (Join-Path (Get-LaadpuntenMap 'per_plaats') $maand) -Columns (@('peilmoment', 'plaats', 'locaties', 'evses', 'evses_dc') + $statusKol + @('mediaan_kwh_ac', 'mediaan_kwh_dc')) -Rows @($plRijen)
        Set-Status 'laadpunten' @{ per_plaats_peildatum = $script:Today }
    }

    $tot = $perOp['_totaal']
    return "$($tot.locaties) locaties, $($tot.evses) laadpunten ($($tot.CHARGING) aan het laden); bestand van $bronTijd"
}
