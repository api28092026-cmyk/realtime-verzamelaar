# Energiemarkt NL:
#  - Nord Pool: officiele day-ahead-prijs NL per kwartier (openbaar endpoint, geen key).
#  - Energy-Charts (Fraunhofer ISE, CC BY 4.0, geen key): opwek per energiebron en grensstromen per buurland voor NL.
#  - TenneT (key in TENNET_API_KEY): onbalans- en afrekenprijzen per kwartier (een keer per dag, TenneT publiceert
#    ze na afloop van de dag; limiet 25 verzoeken per dag) en de balance delta (elke 12 s), samengevat per kwartier.

function Get-EnergieBestand { param([string]$Naam) $map = Get-DataPath 'energie'; New-Item -ItemType Directory -Force -Path $map | Out-Null; Join-Path $map $Naam }

function Invoke-EnergieNordPool {
    $rijen = New-Object System.Collections.ArrayList
    foreach ($d in @((Get-Date).Date, (Get-Date).Date.AddDays(1))) {
        $datum = $d.ToString('yyyy-MM-dd', $script:Inv)
        # Voor morgen is er pas rond 13:00 een prijs; tot die tijd is het antwoord leeg (204).
        $txt = Invoke-Get -Uri "https://dataportal-api.nordpoolgroup.com/api/DayAheadPrices?date=$datum&market=DayAhead&deliveryArea=NL&currency=EUR" -TimeoutSec 60 -Pogingen 2
        if (-not $txt -or -not $txt.Trim()) { continue }
        $np = ConvertFrom-Json -InputObject $txt
        foreach ($e in @($np.multiAreaEntries)) {
            if ($null -eq $e.entryPerArea.NL) { continue }
            [void]$rijen.Add(@{ begin_utc = (Format-Utc $e.deliveryStart); eind_utc = (Format-Utc $e.deliveryEnd); prijs_eur_mwh = [double]$e.entryPerArea.NL; opgehaald_op = $script:RunStamp })
        }
        Suspend-Beleefd
    }
    if ($rijen.Count -eq 0) { throw 'Nord Pool gaf geen NL-prijzen.' }
    Update-CsvRows -Path (Get-EnergieBestand 'dayahead_nordpool.csv') -Columns 'begin_utc', 'eind_utc', 'prijs_eur_mwh', 'opgehaald_op' -Rows $rijen -Key 'begin_utc'
    return "Nord Pool: $($rijen.Count) kwartierprijzen"
}

function Invoke-EnergieCharts {
    $uit = @()
    $van = (Get-Date).ToUniversalTime().AddDays(-2).ToString('yyyy-MM-dd', $script:Inv); $tot = (Get-Date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-dd', $script:Inv)
    # Opwek per energiebron (MW per kwartier).
    $p = Invoke-GetJson -Uri "https://api.energy-charts.info/public_power?country=nl&start=$van&end=$tot" -TimeoutSec 120 -Pogingen 2
    $rijen = New-Object System.Collections.ArrayList
    $tijden = @($p.unix_seconds)
    foreach ($pt in @($p.production_types)) {
        $data = @($pt.data)
        for ($i = 0; $i -lt $tijden.Count; $i++) {
            if ($null -eq $data[$i]) { continue }
            [void]$rijen.Add(@{ tijdstip_utc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$tijden[$i]).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', $script:Inv); bron = [string]$pt.name; mw = [double]$data[$i] })
        }
    }
    Update-CsvRows -Path (Get-EnergieBestand 'opwek_per_bron.csv') -Columns 'tijdstip_utc', 'bron', 'mw' -Rows $rijen -Key 'tijdstip_utc', 'bron'
    $uit += "opwek: $($rijen.Count) waarden"
    Suspend-Beleefd
    # Fysieke grensstromen per buurland (GW; positief = import naar NL).
    $c = Invoke-GetJson -Uri "https://api.energy-charts.info/cbpf?country=nl&start=$van&end=$tot" -TimeoutSec 120 -Pogingen 2
    $rijen = New-Object System.Collections.ArrayList
    $tijden = @($c.unix_seconds)
    foreach ($land in @($c.countries)) {
        $data = @($land.data)
        for ($i = 0; $i -lt $tijden.Count; $i++) {
            if ($null -eq $data[$i]) { continue }
            [void]$rijen.Add(@{ tijdstip_utc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$tijden[$i]).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', $script:Inv); land = [string]$land.name; gw = [double]$data[$i] })
        }
    }
    Update-CsvRows -Path (Get-EnergieBestand 'grensstromen.csv') -Columns 'tijdstip_utc', 'land', 'gw' -Rows $rijen -Key 'tijdstip_utc', 'land'
    $uit += "grensstromen: $($rijen.Count) waarden"
    return ($uit -join ', ')
}

function Invoke-TenneT {
    param([string]$Pad, [string]$Van, [string]$Tot)
    $headers = @{ 'apikey' = $env:TENNET_API_KEY; 'Accept' = 'text/csv' }
    $u = "https://api.tennet.eu/publications/v1/$Pad`?date_from=$([Uri]::EscapeDataString($Van))&date_to=$([Uri]::EscapeDataString($Tot))"
    $r = Invoke-WebRequest -Uri $u -Headers $headers -UserAgent $script:Cfg.UserAgent -UseBasicParsing -TimeoutSec 120
    $txt = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    return @($txt | ConvertFrom-Csv)
}

function Invoke-EnergieTenneT {
    if (-not $env:TENNET_API_KEY) { return 'TenneT overgeslagen: geen TENNET_API_KEY ingesteld' }
    $uit = @()
    $status = Get-Status 'energie_tennet'
    # 1. Afrekenprijzen: een keer per dag, de laatste 3 dagen (TenneT publiceert na afloop van de dag).
    if (-not $status -or $status.afrekenprijzen_peildatum -ne $script:Today) {
        $fmt = 'dd-MM-yyyy HH:mm:ss'
        $rij = Invoke-TenneT 'settlement-prices' ((Get-Date).Date.AddDays(-3).ToString($fmt, $script:Inv)) ((Get-Date).ToString($fmt, $script:Inv))
        $rijen = foreach ($r in $rij) {
            @{ begin_lokaal = $r.'Timeinterval Start Loc'; eind_lokaal = $r.'Timeinterval End Loc'; isp = $r.Isp; prijs_tekort = $r.'Price Shortage'; prijs_overschot = $r.'Price Surplus'
               prijs_opregelen = $r.'Price Dispatch Up'; prijs_afregelen = $r.'Price Dispatch Down'; regeltoestand = $r.'Regulation State'; regelconditie = $r.'Regulating Condition'
               noodreserve_op = $r.'Incident Reserve Up'; noodreserve_af = $r.'Incident Reserve Down'; opgehaald_op = $script:RunStamp } }
        if (@($rijen).Count) {
            Update-CsvRows -Path (Get-EnergieBestand 'tennet_afrekenprijzen.csv') -Columns 'begin_lokaal', 'eind_lokaal', 'isp', 'prijs_tekort', 'prijs_overschot', 'prijs_opregelen', 'prijs_afregelen', 'regeltoestand', 'regelconditie', 'noodreserve_op', 'noodreserve_af', 'opgehaald_op' -Rows @($rijen) -Key 'begin_lokaal'
        }
        $status = @{ afrekenprijzen_peildatum = $script:Today; balance_delta_tot = $(if ($status) { $status.balance_delta_tot } else { $null }) }
        $uit += "afrekenprijzen: $(@($rijen).Count) kwartieren"
        Start-Sleep -Seconds 2
    }
    # 2. Balance delta (12 s) sinds de vorige run, samengevat per kwartier; hooguit 1 dag per verzoek.
    $nu = (Get-Date).ToUniversalTime()
    $tot = $nu.AddMinutes(-5)
    $van = if ($status -and $status.balance_delta_tot) { [datetime]::Parse($status.balance_delta_tot, $script:Inv, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal) } else { $nu.AddHours(-3) }
    if ($van -lt $tot.AddHours(-23)) { $van = $tot.AddHours(-23) }
    $van = $van.AddMinutes(-15)                        # overlap: het laatste kwartier opnieuw, zodat het compleet wordt
    $iso = 'yyyy-MM-ddTHH:mm:ssZ'
    $punten = Invoke-TenneT 'balance-delta-high-res' ($van.ToString($iso, $script:Inv)) ($tot.ToString($iso, $script:Inv))
    $velden = @()
    if ($punten.Count) { $velden = @($punten[0].PSObject.Properties.Name | Where-Object { $_ -notmatch '^(Timeinterval|Isp)' }) }
    $perKwartier = @{}
    foreach ($p in $punten) {
        $t = [datetime]::Parse($p.'Timeinterval Start Utc', $script:Inv, [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal)
        $k = (New-Object DateTime ($t.Year, $t.Month, $t.Day, $t.Hour, ([int][math]::Floor($t.Minute / 15)) * 15, 0, [DateTimeKind]::Utc)).ToString($iso, $script:Inv)
        if (-not $perKwartier.ContainsKey($k)) { $perKwartier[$k] = @{ n = 0; som = @{}; min = @{}; max = @{} } }
        $a = $perKwartier[$k]; $a.n++
        foreach ($v in $velden) {
            $w = 0.0; if (-not [double]::TryParse([string]$p.$v, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$w)) { continue }
            $a.som[$v] = [double]$a.som[$v] + $w
            if (-not $a.min.ContainsKey($v) -or $w -lt $a.min[$v]) { $a.min[$v] = $w }
            if (-not $a.max.ContainsKey($v) -or $w -gt $a.max[$v]) { $a.max[$v] = $w }
        }
    }
    $naam = { param($v) ($v.ToLower() -replace '[^a-z0-9]+', '_').Trim('_') }
    $kolommen = @('kwartier_utc', 'metingen') + @($velden | ForEach-Object { 'gem_' + (& $naam $_) }) + @($velden | Where-Object { $_ -match 'Price' } | ForEach-Object { 'min_' + (& $naam $_); 'max_' + (& $naam $_) })
    $rijen = foreach ($k in ($perKwartier.Keys | Sort-Object)) {
        $a = $perKwartier[$k]; $r = @{ kwartier_utc = $k; metingen = $a.n }
        foreach ($v in $velden) {
            $cnt = $a.n; $r['gem_' + (& $naam $v)] = $(if ($a.som.ContainsKey($v)) { [math]::Round($a.som[$v] / $cnt, 2) } else { $null })
            if ($v -match 'Price') { $r['min_' + (& $naam $v)] = $a.min[$v]; $r['max_' + (& $naam $v)] = $a.max[$v] }
        }
        $r }
    if (@($rijen).Count) {
        $pad = Get-EnergieBestand 'tennet_balance_delta_kwartier.csv'
        if (Test-Path $pad) { $kop = (Get-Content -Path $pad -TotalCount 1 -Encoding UTF8).TrimStart([char]0xFEFF); if ($kop -ne ($kolommen -join ',')) { $pad = $pad -replace '\.csv$', ('_vanaf_' + $script:Today + '.csv') } }
        Update-CsvRows -Path $pad -Columns $kolommen -Rows @($rijen) -Key 'kwartier_utc'
        $status.balance_delta_tot = $tot.ToString($iso, $script:Inv)
    }
    Set-Status 'energie_tennet' $status
    $uit += "balance delta: $($punten.Count) metingen in $(@($rijen).Count) kwartieren"
    return 'TenneT: ' + ($uit -join ', ')
}

function Invoke-BronEnergie {
    $uit = @(); $fouten = @()
    foreach ($stap in 'Invoke-EnergieNordPool', 'Invoke-EnergieCharts', 'Invoke-EnergieTenneT') {
        try { $uit += (& $stap) } catch { $fouten += "$($stap -replace 'Invoke-Energie','') mislukt: $($_.Exception.Message)" }
    }
    if ($fouten.Count) { throw ((@($uit) + @($fouten)) -join '; ') }
    return ($uit -join '; ')
}
