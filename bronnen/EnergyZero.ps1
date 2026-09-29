# EnergyZero: uurprijzen stroom en de dagprijs van gas (openbaar endpoint van de EnergyZero-app, geen key).
# Met inclBtw=false is dit de kale beursprijs excl. btw, zonder inkoopvergoeding en energiebelasting:
# de stroomprijs is gelijk aan de day-ahead-prijs van Nord Pool (gecontroleerd 29-09-2026), de gasprijs is de
# TTF day-ahead-prijs. Die laatste staat afgerond op hele centen per m3 (circa 0,5 EUR/MWh nauwkeurig).
# Voor gas houden we daarnaast een dagreeks bij in EUR/m3 en in EUR/MWh (zoals TTF genoteerd wordt).

# Omrekening m3 -> kWh: Groningen-equivalent, 35,17 MJ/m3 (bovenste verbrandingswaarde) = 9,769 kWh/m3.
$script:KwhPerM3 = 9.769

function Invoke-BronEnergyZero {
    $fmt = "yyyy-MM-dd'T'HH:mm:ss.fff'Z'"
    $from = (Get-Date).Date.AddDays(-3).ToUniversalTime().ToString($fmt, $script:Inv)
    $till = (Get-Date).Date.AddDays(2).AddMilliseconds(-1).ToUniversalTime().ToString($fmt, $script:Inv)
    $rows = New-Object System.Collections.ArrayList
    foreach ($d in @(@{ drager = 'stroom'; usage = 1; eenheid = 'EUR/kWh' }, @{ drager = 'gas'; usage = 3; eenheid = 'EUR/m3' })) {
        $uri = "https://api.energyzero.nl/v1/energyprices?fromDate=$from&tillDate=$till&interval=4&usageType=$($d.usage)&inclBtw=false"
        $json = Invoke-Get -Uri $uri
        Save-Ruw -Bron 'energyzero' -Naam ($d.drager + '.json') -Content $json
        $obj = $json | ConvertFrom-Json
        foreach ($p in $obj.Prices) {
            [void]$rows.Add(@{ tijdstip_utc = (Format-Utc $p.readingDate); drager = $d.drager; prijs_excl_btw = [double]$p.price; eenheid = $d.eenheid; opgehaald_op = $script:RunStamp })
        }
        Suspend-Beleefd
    }
    if ($rows.Count -eq 0) { throw 'EnergyZero gaf geen prijzen terug.' }
    Update-CsvRows -Path (Get-DataPath 'energyzero_prijzen.csv') -Columns 'tijdstip_utc', 'drager', 'prijs_excl_btw', 'eenheid', 'opgehaald_op' -Rows $rows -Key 'tijdstip_utc', 'drager'

    # Eenmalig: de gashistorie vanaf 2020 (EnergyZero bewaart die) voor de dagreeks.
    $gasRijen = @($rows | Where-Object { $_.drager -eq 'gas' })
    $status = Get-Status 'energyzero'
    if (-not $status -or -not $status.gas_historie_geladen) {
        $hist = (Invoke-Get -Uri "https://api.energyzero.nl/v1/energyprices?fromDate=2020-01-01T00:00:00.000Z&tillDate=$from&interval=4&usageType=3&inclBtw=false" -TimeoutSec 300) | ConvertFrom-Json
        $gasRijen = @($hist.Prices | ForEach-Object { @{ tijdstip_utc = (Format-Utc $_.readingDate); prijs_excl_btw = [double]$_.price } }) + $gasRijen
        Set-Status 'energyzero' @{ gas_historie_geladen = $script:Today }
    }

    # Gas per gasdag (06:00-06:00 Nederlandse tijd): een prijs per dag.
    $tz = [TimeZoneInfo]::FindSystemTimeZoneById($(if ($IsLinux -or $IsMacOS) { 'Europe/Amsterdam' } else { 'W. Europe Standard Time' }))
    $perDag = @{}
    foreach ($r in $gasRijen) {
        $utc = [datetime]::Parse($r.tijdstip_utc, $script:Inv, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
        $gasdag = [TimeZoneInfo]::ConvertTimeFromUtc($utc, $tz).AddHours(-6).ToString('yyyy-MM-dd', $script:Inv)
        if (-not $perDag.ContainsKey($gasdag)) { $perDag[$gasdag] = $r.prijs_excl_btw }
    }
    $gas = foreach ($dag in ($perDag.Keys | Sort-Object)) {
        $m3 = [double]$perDag[$dag]
        @{ gasdag = $dag; eur_per_m3_excl_btw = $m3; eur_per_mwh = [math]::Round($m3 / $script:KwhPerM3 * 1000, 2); opgehaald_op = $script:RunStamp }
    }
    if (@($gas).Count) { Update-CsvRows -Path (Get-DataPath 'gasprijs_dag.csv') -Columns 'gasdag', 'eur_per_m3_excl_btw', 'eur_per_mwh', 'opgehaald_op' -Rows @($gas) -Key 'gasdag' }
    return "$($rows.Count) uurprijzen bijgewerkt; gas: $(@($gas).Count) gasdagen"
}
