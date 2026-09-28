# EnergyZero: uurprijzen stroom en gas (openbaar endpoint van de EnergyZero-app, geen key).
# Let op: de gasprijs is een consumententarief (TTF day-ahead + opslag + energiebelasting), excl. btw.

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
    return "$($rows.Count) uurprijzen bijgewerkt"
}
