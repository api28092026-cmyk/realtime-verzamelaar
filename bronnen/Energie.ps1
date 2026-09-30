# Energiemarkt NL:
#  - Nord Pool: officiele day-ahead-prijs NL per kwartier (openbaar endpoint, geen key).
#  - Energy-Charts (Fraunhofer ISE, CC BY 4.0, geen key): opwek per energiebron, grensstromen per buurland en de
#    day-ahead-prijs voor NL, per kwartier (tot eind 2014 niet beschikbaar; de prijs is per uur tot oktober 2025).
#  - TenneT (key in TENNET_API_KEY): onbalans- en afrekenprijzen per kwartier (een keer per dag, TenneT publiceert
#    ze na afloop van de dag; limiet 25 verzoeken per dag) en de balance delta (elke 12 s), samengevat per kwartier.
# Opslag per maand: data/energie/<reeks>/<JJJJ-MM>.csv, een regel per tijdstip (UTC) en bij Energy-Charts een kolom
# per energiebron of land. Invoke-EnergieHistorie vult elke run een paar maanden terug in de tijd aan, tot 2015.

function Get-EnergieBestand { param([string]$Naam) $map = Get-DataPath 'energie'; New-Item -ItemType Directory -Force -Path $map | Out-Null; Join-Path $map $Naam }
function Get-EnergieMap { param([string]$Naam) Join-Path (Get-DataPath 'energie') $Naam }
function ConvertTo-Kolomnaam { param([string]$Naam) ($Naam.ToLower() -replace '[^a-z0-9]+', '_').Trim('_') }
function ConvertFrom-UnixUtc { param($Sec) [DateTimeOffset]::FromUnixTimeSeconds([int64]$Sec).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', $script:Inv) }

function Get-NlTijdzone {
    if (-not $script:NlTz) {
        foreach ($id in 'Europe/Amsterdam', 'W. Europe Standard Time') { try { $script:NlTz = [TimeZoneInfo]::FindSystemTimeZoneById($id); break } catch { } }
    }
    return $script:NlTz
}

# TenneT geeft het kwartier in lokale tijd. Bij de wintertijdovergang komt 02:00-03:00 twee keer voor; dan beslist het
# ISP-nummer (9-12 is zomertijd, 13-16 wintertijd).
function ConvertTo-TenneTUtc {
    param([string]$Lokaal, [int]$Isp)
    $t = [datetime]::ParseExact($Lokaal.Substring(0, 16), 'yyyy-MM-ddTHH:mm', $script:Inv)
    $tz = Get-NlTijdzone
    if ($tz.IsAmbiguousTime($t)) { $offset = [TimeSpan]::FromHours($(if ($Isp -le 12) { 2 } else { 1 })) } else { $offset = $tz.GetUtcOffset($t) }
    return [datetime]::SpecifyKind($t - $offset, [DateTimeKind]::Utc).ToString('yyyy-MM-ddTHH:mm:ssZ', $script:Inv)
}

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

# Energy-Charts-reeksen (unix_seconds plus een lijst met naam en data) naar brede rijen: een per tijdstip, een kolom per reeks.
# Schrijft ze per maand weg en geeft het aantal tijdstippen terug.
function Save-EnergieBreed {
    param([string]$Reeks, $Tijden, [object[]]$Reeksen)
    $tijden = @($Tijden)
    $rijen = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $tijden.Count; $i++) {
        $r = @{ tijdstip_utc = (ConvertFrom-UnixUtc $tijden[$i]) }; $iets = $false
        foreach ($rk in $Reeksen) { $w = $rk.data[$i]; if ($null -ne $w) { $r[$rk.naam] = [double]$w; $iets = $true } }
        if ($iets) { [void]$rijen.Add($r) }
    }
    $kolommen = @('tijdstip_utc') + @($Reeksen | ForEach-Object { $_.naam })
    Update-CsvRowsPerPeriode -Map (Get-EnergieMap $Reeks) -Columns $kolommen -Rows $rijen -Key 'tijdstip_utc' -TijdKolom 'tijdstip_utc'
    return $rijen.Count
}

# Opwek per energiebron (MW; aandelen in %), grensstromen per buurland (GW; positief = import naar NL) en de
# day-ahead-prijs (EUR/MWh) voor de periode $Van t/m $Tot (datums, lokale tijd).
function Invoke-EnergieChartsPeriode {
    param([string]$Van, [string]$Tot, [int]$PauzeMs = [int]$script:Cfg.PauzeMs)
    $p = Invoke-GetJson -Uri "https://api.energy-charts.info/public_power?country=nl&start=$Van&end=$Tot" -TimeoutSec 120 -Pogingen 2
    $n1 = Save-EnergieBreed 'opwek' $p.unix_seconds @(foreach ($pt in @($p.production_types)) { @{ naam = (ConvertTo-Kolomnaam $pt.name); data = @($pt.data) } })
    Start-Sleep -Milliseconds $PauzeMs
    $c = Invoke-GetJson -Uri "https://api.energy-charts.info/cbpf?country=nl&start=$Van&end=$Tot" -TimeoutSec 120 -Pogingen 2
    $n2 = Save-EnergieBreed 'grensstromen' $c.unix_seconds @(foreach ($land in @($c.countries)) { @{ naam = (ConvertTo-Kolomnaam $land.name); data = @($land.data) } })
    Start-Sleep -Milliseconds $PauzeMs
    $d = Invoke-GetJson -Uri "https://api.energy-charts.info/price?bzn=NL&start=$Van&end=$Tot" -TimeoutSec 120 -Pogingen 2
    $n3 = Save-EnergieBreed 'dayahead' $d.unix_seconds @(@{ naam = 'eur_mwh'; data = @($d.price) })
    return "opwek $n1, grensstromen $n2, day-ahead $n3 tijdstippen"
}

function Invoke-EnergieCharts {
    $van = (Get-Date).ToUniversalTime().AddDays(-2).ToString('yyyy-MM-dd', $script:Inv); $tot = (Get-Date).ToUniversalTime().AddDays(1).ToString('yyyy-MM-dd', $script:Inv)
    return 'Energy-Charts: ' + (Invoke-EnergieChartsPeriode $van $tot)
}

function Invoke-TenneT {
    param([string]$Pad, [string]$Van, [string]$Tot)
    $headers = @{ 'apikey' = $env:TENNET_API_KEY; 'Accept' = 'text/csv' }
    $u = "https://api.tennet.eu/publications/v1/$Pad`?date_from=$([Uri]::EscapeDataString($Van))&date_to=$([Uri]::EscapeDataString($Tot))"
    $r = Invoke-WebRequest -Uri $u -Headers $headers -UserAgent $script:Cfg.UserAgent -UseBasicParsing -TimeoutSec 120
    $txt = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    if (-not $txt.Trim()) { return @() }
    return @($txt | ConvertFrom-Csv)
}

$script:AfrekenKolommen = 'begin_utc', 'begin_lokaal', 'eind_lokaal', 'isp', 'prijs_tekort', 'prijs_overschot', 'prijs_opregelen', 'prijs_afregelen', 'regeltoestand', 'regelconditie', 'noodreserve_op', 'noodreserve_af', 'opgehaald_op'

# Haalt de afrekenprijzen op voor [$Van, $Tot] (lokale tijd, hooguit een maand) en schrijft ze per maand weg.
function Save-TenneTAfrekenprijzen {
    param([datetime]$Van, [datetime]$Tot)
    $fmt = 'dd-MM-yyyy HH:mm:ss'
    $rijen = foreach ($r in (Invoke-TenneT 'settlement-prices' ($Van.ToString($fmt, $script:Inv)) ($Tot.ToString($fmt, $script:Inv)))) {
        if (-not $r.'Timeinterval Start Loc') { continue }
        @{ begin_utc = (ConvertTo-TenneTUtc $r.'Timeinterval Start Loc' ([int]$r.Isp)); begin_lokaal = $r.'Timeinterval Start Loc'; eind_lokaal = $r.'Timeinterval End Loc'; isp = $r.Isp
           prijs_tekort = $r.'Price Shortage'; prijs_overschot = $r.'Price Surplus'; prijs_opregelen = $r.'Price Dispatch Up'; prijs_afregelen = $r.'Price Dispatch Down'
           regeltoestand = $r.'Regulation State'; regelconditie = $r.'Regulating Condition'; noodreserve_op = $r.'Incident Reserve Up'; noodreserve_af = $r.'Incident Reserve Down'; opgehaald_op = $script:RunStamp } }
    Update-CsvRowsPerPeriode -Map (Get-EnergieMap 'tennet_afrekenprijzen') -Columns $script:AfrekenKolommen -Rows @($rijen) -Key 'begin_utc' -TijdKolom 'begin_utc'
    return @($rijen).Count
}

function Invoke-EnergieTenneT {
    if (-not $env:TENNET_API_KEY) { return 'TenneT overgeslagen: geen TENNET_API_KEY ingesteld' }
    $uit = @()
    $status = Get-Status 'energie_tennet'
    # 1. Afrekenprijzen: een keer per dag, de laatste 3 dagen (TenneT publiceert na afloop van de dag).
    if (-not $status -or $status.afrekenprijzen_peildatum -ne $script:Today) {
        $n = Save-TenneTAfrekenprijzen (Get-Date).Date.AddDays(-3) (Get-Date).Date
        $status = @{ afrekenprijzen_peildatum = $script:Today; balance_delta_tot = $(if ($status) { $status.balance_delta_tot } else { $null }) }
        $uit += "afrekenprijzen: $n kwartieren"
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
        $minuut = [int][math]::Floor($t.Minute / 15) * 15
        $k = [datetime]::SpecifyKind($t.Date.AddHours($t.Hour).AddMinutes($minuut), [DateTimeKind]::Utc).ToString($iso, $script:Inv)
        if (-not $perKwartier.ContainsKey($k)) { $perKwartier[$k] = @{ n = 0; som = @{}; min = @{}; max = @{} } }
        $a = $perKwartier[$k]; $a.n++
        foreach ($v in $velden) {
            $w = 0.0; if (-not [double]::TryParse([string]$p.$v, [Globalization.NumberStyles]::Float, $script:Inv, [ref]$w)) { continue }
            $a.som[$v] = [double]$a.som[$v] + $w
            if (-not $a.min.ContainsKey($v) -or $w -lt $a.min[$v]) { $a.min[$v] = $w }
            if (-not $a.max.ContainsKey($v) -or $w -gt $a.max[$v]) { $a.max[$v] = $w }
        }
    }
    $kolommen = @('kwartier_utc', 'metingen') + @($velden | ForEach-Object { 'gem_' + (ConvertTo-Kolomnaam $_) }) + @($velden | Where-Object { $_ -match 'Price' } | ForEach-Object { 'min_' + (ConvertTo-Kolomnaam $_); 'max_' + (ConvertTo-Kolomnaam $_) })
    $rijen = foreach ($k in ($perKwartier.Keys | Sort-Object)) {
        $a = $perKwartier[$k]; $r = @{ kwartier_utc = $k; metingen = $a.n }
        foreach ($v in $velden) {
            $cnt = $a.n; $r['gem_' + (ConvertTo-Kolomnaam $v)] = $(if ($a.som.ContainsKey($v)) { [math]::Round($a.som[$v] / $cnt, 2) } else { $null })
            if ($v -match 'Price') { $r['min_' + (ConvertTo-Kolomnaam $v)] = $a.min[$v]; $r['max_' + (ConvertTo-Kolomnaam $v)] = $a.max[$v] }
        }
        $r }
    if (@($rijen).Count) {
        Update-CsvRowsPerPeriode -Map (Get-EnergieMap 'tennet_balance_delta') -Columns $kolommen -Rows @($rijen) -Key 'kwartier_utc' -TijdKolom 'kwartier_utc'
        $status.balance_delta_tot = $tot.ToString($iso, $script:Inv)
    }
    Set-Status 'energie_tennet' $status
    $uit += "balance delta: $($punten.Count) metingen in $(@($rijen).Count) kwartieren"
    return 'TenneT: ' + ($uit -join ', ')
}

# Historische aanvulling, maand voor maand terug in de tijd vanaf de huidige maand:
#  - Energy-Charts: elke run EnergieHistorieMaandenPerRun maanden, tot EnergieHistorieVanaf. Een maand die drie
#    runs achter elkaar mislukt, wordt overgeslagen (en in de status genoteerd).
#  - TenneT-afrekenprijzen: een keer per dag TennetHistorieMaandenPerDag maanden (1 verzoek per maand, 13 s ertussen
#    voor de limiet van 5 per minuut), tot twee maanden achter elkaar leeg zijn of TenneT de limiet meldt.
function Invoke-EnergieHistorie {
    $oud = Get-Status 'energie_historie'
    $st = @{ ec_volgende = (Get-Date).ToString('yyyy-MM', $script:Inv); ec_klaar = $false; ec_fouten = 0; ec_overgeslagen = @()
             tennet_volgende = (Get-Date).ToString('yyyy-MM', $script:Inv); tennet_leeg = 0; tennet_klaar = $false; tennet_peildatum = '' }
    if ($oud) { foreach ($e in $oud.PSObject.Properties) { $st[$e.Name] = $e.Value } }
    $st.ec_overgeslagen = @($st.ec_overgeslagen)
    $grens = [datetime]::ParseExact($script:Cfg.EnergieHistorieVanaf + '-01', 'yyyy-MM-dd', $script:Inv)
    $maand = { param($s) [datetime]::ParseExact($s + '-01', 'yyyy-MM-dd', $script:Inv) }
    $uit = @()

    if (-not $st.ec_klaar) {
        $gedaan = @()
        for ($i = 0; $i -lt [int]$script:Cfg.EnergieHistorieMaandenPerRun; $i++) {
            $m = & $maand $st.ec_volgende
            if ($m -lt $grens) { $st.ec_klaar = $true; break }
            try {
                [void](Invoke-EnergieChartsPeriode $m.ToString('yyyy-MM-dd', $script:Inv) $m.AddMonths(1).AddDays(-1).ToString('yyyy-MM-dd', $script:Inv) 4000)
                $gedaan += $st.ec_volgende; $st.ec_fouten = 0
            } catch {
                $st.ec_fouten = [int]$st.ec_fouten + 1
                if ($st.ec_fouten -lt 3) { Set-Status 'energie_historie' $st; throw "Energy-Charts $($st.ec_volgende): $($_.Exception.Message)" }
                $st.ec_overgeslagen = @($st.ec_overgeslagen) + $st.ec_volgende; $st.ec_fouten = 0
            }
            $st.ec_volgende = $m.AddMonths(-1).ToString('yyyy-MM', $script:Inv)
            Set-Status 'energie_historie' $st
            Start-Sleep -Seconds 4                  # Energy-Charts geeft anders 429
        }
        if ((& $maand $st.ec_volgende) -lt $grens) { $st.ec_klaar = $true }
        $uit += $(if ($gedaan.Count) { "Energy-Charts $($gedaan[-1]) t/m $($gedaan[0])" } else { 'Energy-Charts niets' }) + $(if ($st.ec_klaar) { ' (compleet)' } else { '' })
    }

    if ($env:TENNET_API_KEY -and -not $st.tennet_klaar -and $st.tennet_peildatum -ne $script:Today) {
        $gedaan = @(); $n = 0
        for ($i = 0; $i -lt [int]$script:Cfg.TennetHistorieMaandenPerDag; $i++) {
            $m = & $maand $st.tennet_volgende
            if ($m -lt $grens) { $st.tennet_klaar = $true; break }
            Start-Sleep -Seconds 13
            # Tot middernacht, anders valt het laatste kwartier (23:45-00:00) weg. Weigert TenneT dat als langer dan een
            # maand, dan tot 23:59:59. Een 4xx op beide telt als een lege maand.
            $aantal = 0; $limiet = $false
            foreach ($tot in @($m.AddMonths(1), $m.AddMonths(1).AddSeconds(-1))) {
                try { $aantal = Save-TenneTAfrekenprijzen $m $tot; break }
                catch {
                    $code = Get-HttpStatus $_
                    if ($code -eq 429) { $limiet = $true; break }
                    if ($code -lt 400 -or $code -ge 500) { Set-Status 'energie_historie' $st; throw "TenneT $($st.tennet_volgende): $($_.Exception.Message)" }
                    Start-Sleep -Seconds 13
                }
            }
            if ($limiet) { $uit += 'TenneT-limiet bereikt, morgen verder'; break }
            $gedaan += "$($st.tennet_volgende) ($aantal)"; $n += $aantal
            if ($aantal -eq 0) { $st.tennet_leeg = [int]$st.tennet_leeg + 1 } else { $st.tennet_leeg = 0 }
            $st.tennet_volgende = $m.AddMonths(-1).ToString('yyyy-MM', $script:Inv)
            if ($st.tennet_leeg -ge 2) { $st.tennet_klaar = $true }
            Set-Status 'energie_historie' $st
            if ($st.tennet_klaar) { break }
        }
        $st.tennet_peildatum = $script:Today
        $uit += "TenneT-afrekenprijzen $($gedaan -join ', ')" + $(if ($st.tennet_klaar) { ' (compleet)' } else { '' })
    }
    Set-Status 'energie_historie' $st
    if (-not $uit.Count) { return 'Historie compleet' }
    return 'Historie: ' + ($uit -join '; ')
}

# Eenmalig: de oude losse bestanden (lang formaat of een groeiend bestand) omzetten naar de maandbestanden.
function Move-EnergieOudeBestanden {
    $uit = @()
    foreach ($o in @(@{ bestand = 'opwek_per_bron.csv'; reeks = 'opwek'; naam = 'bron'; waarde = 'mw' }, @{ bestand = 'grensstromen.csv'; reeks = 'grensstromen'; naam = 'land'; waarde = 'gw' })) {
        $pad = Join-Path (Get-DataPath 'energie') $o.bestand
        if (-not (Test-Path $pad)) { continue }
        $perTijd = @{}; $namen = New-Object System.Collections.Generic.List[string]
        foreach ($r in (Import-Csv -Path $pad)) {
            $k = ConvertTo-Kolomnaam $r.($o.naam); if (-not $namen.Contains($k)) { $namen.Add($k) }
            if (-not $perTijd.ContainsKey($r.tijdstip_utc)) { $perTijd[$r.tijdstip_utc] = @{ tijdstip_utc = $r.tijdstip_utc } }
            $perTijd[$r.tijdstip_utc][$k] = [double]::Parse($r.($o.waarde), $script:Inv)
        }
        Update-CsvRowsPerPeriode -Map (Get-EnergieMap $o.reeks) -Columns (@('tijdstip_utc') + $namen.ToArray()) -Rows @($perTijd.Values) -Key 'tijdstip_utc' -TijdKolom 'tijdstip_utc'
        Remove-Item -Path $pad; $uit += "$($o.bestand) -> $($o.reeks)/"
    }
    $pad = Join-Path (Get-DataPath 'energie') 'tennet_afrekenprijzen.csv'
    if (Test-Path $pad) {
        $rijen = foreach ($r in (Import-Csv -Path $pad)) { $h = @{}; foreach ($e in $r.PSObject.Properties) { $h[$e.Name] = $e.Value }; $h.begin_utc = ConvertTo-TenneTUtc $r.begin_lokaal ([int]$r.isp); $h }
        Update-CsvRowsPerPeriode -Map (Get-EnergieMap 'tennet_afrekenprijzen') -Columns $script:AfrekenKolommen -Rows @($rijen) -Key 'begin_utc' -TijdKolom 'begin_utc'
        Remove-Item -Path $pad; $uit += 'tennet_afrekenprijzen.csv -> tennet_afrekenprijzen/'
    }
    foreach ($f in @(Get-ChildItem -Path (Get-DataPath 'energie') -Filter 'tennet_balance_delta_kwartier*.csv' -ErrorAction SilentlyContinue)) {
        $kop = @(((Get-Content -Path $f.FullName -TotalCount 1 -Encoding UTF8).TrimStart([char]0xFEFF) -split ',') | ForEach-Object { $_.Trim('"') })
        Update-CsvRowsPerPeriode -Map (Get-EnergieMap 'tennet_balance_delta') -Columns $kop -Rows @(Import-Csv -Path $f.FullName) -Key 'kwartier_utc' -TijdKolom 'kwartier_utc'
        Remove-Item -Path $f.FullName; $uit += "$($f.Name) -> tennet_balance_delta/"
    }
    if ($uit.Count) { return 'Omgezet: ' + ($uit -join ', ') }
}

function Invoke-BronEnergie {
    $uit = @(); $fouten = @()
    foreach ($stap in 'Move-EnergieOudeBestanden', 'Invoke-EnergieNordPool', 'Invoke-EnergieCharts', 'Invoke-EnergieTenneT', 'Invoke-EnergieHistorie') {
        try { $r = & $stap; if ($r) { $uit += $r } } catch { $fouten += "$($stap -replace '^(Invoke|Move)-Energie','') mislukt: $($_.Exception.Message)" }
    }
    if ($fouten.Count) { throw ((@($uit) + @($fouten)) -join '; ') }
    return ($uit -join '; ')
}
