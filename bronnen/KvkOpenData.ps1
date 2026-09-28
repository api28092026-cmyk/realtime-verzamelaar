# KVK open dataset Basis Bedrijfsgegevens (CC BY 4.0, geen key): alle bv's en nv's, anoniem, elke werkdag vernieuwd.
# Dient als anonieme vervanger van het Centraal Insolventieregister: het veld Insolventie (FAIL/SURS/SSAN) per bedrijf.

function Invoke-BronKvkOpenData {
    $zip = Get-RuwPad 'kvk' 'basis-bedrijfsgegevens.zip'
    Invoke-Get -Uri 'https://www.kvk.nl/download/kvk-open-dataset-basis-bedrijfsgegevens.zip' -OutFile $zip -TimeoutSec 900
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $z = [IO.Compression.ZipFile]::OpenRead($zip)
    try {
        $entry = $z.Entries | Where-Object { $_.Name -match '\.csv$' } | Select-Object -First 1
        $rd = New-Object IO.StreamReader($entry.Open(), [Text.Encoding]::UTF8)
        $kop = $rd.ReadLine().Split(';') | ForEach-Object { $_.Trim('"') }
        $iAanvang = [array]::IndexOf($kop, 'Datum aanvang'); $iActief = [array]::IndexOf($kop, 'Actief'); $iIns = [array]::IndexOf($kop, 'Insolventie')
        $iPc = [array]::IndexOf($kop, 'Postcode regio'); $iHoofd = [array]::IndexOf($kop, 'Hoofdactiviteiten'); $iVorm = [array]::IndexOf($kop, 'Rechtsvorm')
        if (($iAanvang, $iActief, $iIns, $iPc, $iHoofd) -contains -1) { throw "Onverwachte kolommen in KVK-bestand: $($kop -join ', ')" }
        $grens = (Get-Date).Date.AddDays(-[int]$script:Cfg.KvkDagenTerug).ToString('yyyyMMdd', $script:Inv)
        $perSbi = @{}; $perRegio = @{}; $starts = @{}; $n = 0
        while ($null -ne ($l = $rd.ReadLine())) {
            $f = $l.Split(';'); if ($f.Count -le $iHoofd) { continue }
            $n++
            $actief = $f[$iActief].Trim('"'); $ins = $f[$iIns].Trim('"'); if (-not $ins) { $ins = 'geen' }
            $sbi2 = $f[$iHoofd].Trim('"').Split(',')[0]; $sbi2 = if ($sbi2.Length -ge 2) { $sbi2.Substring(0, 2) } else { 'onbekend' }
            $pc = $f[$iPc].Trim('"')
            $k = "$sbi2|$actief|$ins"; $perSbi[$k] = 1 + [int]$perSbi[$k]
            $k = "$pc|$actief|$ins"; $perRegio[$k] = 1 + [int]$perRegio[$k]
            $aanvang = $f[$iAanvang].Trim('"')
            if ($aanvang -ge $grens) { $vorm = if ($iVorm -ge 0) { $f[$iVorm].Trim('"') } else { '' }; $k = "$aanvang|$sbi2|$vorm"; $starts[$k] = 1 + [int]$starts[$k] }
        }
        $rd.Dispose()
    } finally { $z.Dispose() }
    if ($n -lt 100000) { throw "KVK-bestand lijkt onvolledig ($n rijen)." }

    $rows = foreach ($k in $perSbi.Keys) { $p = $k -split '\|'; @{ peildatum = $script:Today; sbi2 = $p[0]; actief = $p[1]; insolventie = $p[2]; aantal = $perSbi[$k] } }
    Update-CsvRows -Path (Get-DataPath 'kvk_stand_per_sbi.csv') -Columns 'peildatum', 'sbi2', 'actief', 'insolventie', 'aantal' -Rows @($rows) -Key 'peildatum', 'sbi2', 'actief', 'insolventie'
    $rows = foreach ($k in $perRegio.Keys) { $p = $k -split '\|'; @{ peildatum = $script:Today; postcode_regio = $p[0]; actief = $p[1]; insolventie = $p[2]; aantal = $perRegio[$k] } }
    Update-CsvRows -Path (Get-DataPath 'kvk_stand_per_regio.csv') -Columns 'peildatum', 'postcode_regio', 'actief', 'insolventie', 'aantal' -Rows @($rows) -Key 'peildatum', 'postcode_regio', 'actief', 'insolventie'

    # Oprichtingen per aanvangsdatum: venster vervangen zodat late inschrijvingen meetellen.
    $pad = Get-DataPath 'kvk_oprichtingen_per_dag.csv'
    $oud = if (Test-Path $pad) { @(Import-Csv $pad | Where-Object { $_.datum -lt $grens }) } else { @() }
    $nieuw = foreach ($k in $starts.Keys) { $p = $k -split '\|'; @{ datum = $p[0]; sbi2 = $p[1]; rechtsvorm = $p[2]; aantal = $starts[$k]; opgehaald_op = $script:RunStamp } }
    if (Test-Path $pad) { Remove-Item $pad }
    Add-CsvRows -Path $pad -Columns 'datum', 'sbi2', 'rechtsvorm', 'aantal', 'opgehaald_op' -Rows ($oud + @($nieuw | Sort-Object { $_.datum }))

    $fail = ($perSbi.Keys | Where-Object { $_ -like '*|FAIL' } | ForEach-Object { $perSbi[$_] } | Measure-Object -Sum).Sum
    return "$n bv's/nv's verwerkt, waarvan $fail met status faillissement"
}
