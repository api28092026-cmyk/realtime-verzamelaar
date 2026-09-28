# RDW Open Data (Socrata, CC0, geen key): nieuwe registraties per dag en het wagenpark per brandstof.

function Invoke-BronRDW {
    $api = 'https://opendata.rdw.nl/resource'
    $vanaf = (Get-Date).Date.AddDays(-[int]$script:Cfg.RdwDagenTerug).ToString('yyyy-MM-dd', $script:Inv) + 'T00:00:00'
    $enc = { param($s) [Uri]::EscapeDataString($s) }

    # 1. Eerste tenaamstellingen in NL per dag en voertuigsoort (alle voertuigen).
    $q = '$select=' + (& $enc 'datum_eerste_tenaamstelling_in_nederland as datum, voertuigsoort, count(*) as aantal') +
         '&$where=' + (& $enc "datum_eerste_tenaamstelling_in_nederland_dt >= '$vanaf'") +
         '&$group=' + (& $enc 'datum_eerste_tenaamstelling_in_nederland, voertuigsoort') + '&$limit=50000'
    $perSoort = Invoke-GetJson -Uri "$api/m9d7-ebf2.json?$q"
    $rows1 = foreach ($r in $perSoort) { @{ datum = $r.datum; voertuigsoort = $r.voertuigsoort; aantal = [int]$r.aantal; opgehaald_op = $script:RunStamp } }
    Update-CsvRows -Path (Get-DataPath 'rdw_registraties_per_soort.csv') -Columns 'datum', 'voertuigsoort', 'aantal', 'opgehaald_op' -Rows @($rows1) -Key 'datum', 'voertuigsoort'
    Suspend-Beleefd

    # 2. Personenauto's: per kenteken merk, nieuw/import en brandstof (koppeling via de brandstoftabel).
    $q = '$select=' + (& $enc 'kenteken, merk, datum_eerste_toelating, datum_eerste_tenaamstelling_in_nederland') +
         '&$where=' + (& $enc "voertuigsoort = 'Personenauto' AND datum_eerste_tenaamstelling_in_nederland_dt >= '$vanaf'") + '&$limit=100000'
    $autos = @(Invoke-GetJson -Uri "$api/m9d7-ebf2.json?$q")
    Suspend-Beleefd
    $brandstof = @{}
    for ($i = 0; $i -lt $autos.Count; $i += 200) {
        $batch = $autos[$i..([Math]::Min($i + 199, $autos.Count - 1))]
        $lijst = ($batch | ForEach-Object { "'" + $_.kenteken + "'" }) -join ','
        $q = '$select=kenteken,brandstof_omschrijving&$where=' + (& $enc "kenteken in($lijst)") + '&$limit=5000'
        foreach ($b in (Invoke-GetJson -Uri "$api/8ys7-d773.json?$q")) {
            if (-not $brandstof.ContainsKey($b.kenteken)) { $brandstof[$b.kenteken] = New-Object System.Collections.Generic.List[string] }
            if (-not $brandstof[$b.kenteken].Contains($b.brandstof_omschrijving)) { $brandstof[$b.kenteken].Add($b.brandstof_omschrijving) }
        }
        Suspend-Beleefd
    }
    $telBrandstof = @{}; $telMerk = @{}
    foreach ($a in $autos) {
        $herkomst = if ($a.datum_eerste_toelating -eq $a.datum_eerste_tenaamstelling_in_nederland) { 'nieuw' } else { 'import' }
        $bs = if ($brandstof.ContainsKey($a.kenteken)) { (($brandstof[$a.kenteken] | Sort-Object) -join '+') } else { 'onbekend' }
        $k1 = $a.datum_eerste_tenaamstelling_in_nederland + '|' + $herkomst + '|' + $bs
        $k2 = $a.datum_eerste_tenaamstelling_in_nederland + '|' + $herkomst + '|' + $a.merk
        $telBrandstof[$k1] = 1 + [int]$telBrandstof[$k1]
        $telMerk[$k2] = 1 + [int]$telMerk[$k2]
    }
    $rows2 = foreach ($k in $telBrandstof.Keys) { $p = $k -split '\|'; @{ datum = $p[0]; herkomst = $p[1]; brandstof = $p[2]; aantal = $telBrandstof[$k]; opgehaald_op = $script:RunStamp } }
    $rows3 = foreach ($k in $telMerk.Keys) { $p = $k -split '\|', 3; @{ datum = $p[0]; herkomst = $p[1]; merk = $p[2]; aantal = $telMerk[$k]; opgehaald_op = $script:RunStamp } }
    # Vervang het hele venster, zodat weggevallen combinaties niet blijven hangen.
    foreach ($spec in @(@{ f = 'rdw_personenautos_per_brandstof.csv'; c = @('datum', 'herkomst', 'brandstof', 'aantal', 'opgehaald_op'); r = @($rows2) },
                        @{ f = 'rdw_personenautos_per_merk.csv'; c = @('datum', 'herkomst', 'merk', 'aantal', 'opgehaald_op'); r = @($rows3) })) {
        $pad = Get-DataPath $spec.f
        $grens = $vanaf.Substring(0, 10).Replace('-', '')
        $oud = if (Test-Path $pad) { @(Import-Csv $pad | Where-Object { $_.datum -lt $grens }) } else { @() }
        if (Test-Path $pad) { Remove-Item $pad }
        Add-CsvRows -Path $pad -Columns $spec.c -Rows ($oud + ($spec.r | Sort-Object { $_.datum }))
    }

    # 3. Wagenpark per brandstof (momentopname van het hele register).
    $q = '$select=' + (& $enc 'brandstof_omschrijving as brandstof, count(*) as aantal') + '&$group=brandstof_omschrijving&$limit=100'
    $park = Invoke-GetJson -Uri "$api/8ys7-d773.json?$q" -TimeoutSec 600
    $rows4 = foreach ($r in $park) { @{ peildatum = $script:Today; brandstof = $r.brandstof; aantal = [int64]$r.aantal; opgehaald_op = $script:RunStamp } }
    Update-CsvRows -Path (Get-DataPath 'rdw_wagenpark_per_brandstof.csv') -Columns 'peildatum', 'brandstof', 'aantal', 'opgehaald_op' -Rows @($rows4) -Key 'peildatum', 'brandstof'

    return "$($autos.Count) personenauto-registraties sinds $($vanaf.Substring(0,10)) verwerkt"
}
