# Deelmobiliteit: alle Nederlandse GBFS-feeds uit de catalogus van MobilityData (deelscooters, -fietsen, -bakfietsen,
# -auto's en OV-fiets). Open, geen key. Elke run is een momentopname; draai deze bron ook elk uur.
# De catalogus wordt elke run opnieuw gelezen, dus nieuwe of verdwenen aanbieders gaan vanzelf mee.

$script:GbfsCatalogus = 'https://raw.githubusercontent.com/MobilityData/gbfs/master/systems.csv'

function Test-GbfsWaar { param($x) return ("$x" -in 'true', 'True', '1') }   # GBFS 2 gebruikt 0/1, GBFS 3 true/false

function Get-GbfsFeeds {
    param($Gbfs)
    if ($Gbfs.data.feeds) { return @($Gbfs.data.feeds) }                  # GBFS 3.x
    $taal = $Gbfs.data.PSObject.Properties | Select-Object -First 1       # GBFS 2.x: data.<taal>.feeds
    if ($taal) { return @($taal.Value.feeds) }
    return @()
}

function Invoke-BronDeelmobiliteit {
    $catalogus = (Invoke-Get -Uri $script:GbfsCatalogus -TimeoutSec 120) | ConvertFrom-Csv
    $systemen = @($catalogus | Where-Object { $_.'Country Code' -eq 'NL' -and -not $_.'Authentication Type' })
    $rijen = New-Object System.Collections.ArrayList
    $mislukt = New-Object System.Collections.Generic.List[string]
    $voertuigen = 0
    foreach ($s in $systemen) {
        try {
            $feeds = Get-GbfsFeeds (Invoke-GetJson -Uri $s.'Auto-Discovery URL' -TimeoutSec 30 -Pogingen 2)
            $url = @{}; foreach ($f in $feeds) { $url[[string]$f.name] = [string]$f.url }
            $basis = @{ peilmoment = $script:RunStamp; systeem_id = $s.'System ID'; aanbieder = $s.Name; plaats = $s.Location }

            # Voertuigtypen: vormfactor (scooter, fiets, bakfiets, auto, moped) en aandrijving.
            $typen = @{}
            if ($url['vehicle_types']) {
                foreach ($t in @((Invoke-GetJson -Uri $url['vehicle_types'] -TimeoutSec 30 -Pogingen 2).data.vehicle_types)) {
                    $typen[[string]$t.vehicle_type_id] = ('{0}/{1}' -f $t.form_factor, $t.propulsion_type)
                }
            }

            # Losse voertuigen (free floating). In GBFS 3 staan voertuigen in een station ook in deze lijst;
            # die tellen we hier niet mee, want ze zitten al in station_status.
            $vUrl = if ($url['vehicle_status']) { $url['vehicle_status'] } else { $url['free_bike_status'] }
            if ($vUrl) {
                $d = (Invoke-GetJson -Uri $vUrl -TimeoutSec 30 -Pogingen 2).data
                $lijst = if ($d.vehicles) { @($d.vehicles) } else { @($d.bikes) }
                $perType = @{}
                foreach ($v in $lijst) {
                    if ($v.station_id) { continue }
                    $typ = if ($v.vehicle_type_id -and $typen.ContainsKey([string]$v.vehicle_type_id)) { $typen[[string]$v.vehicle_type_id] } elseif ($v.vehicle_type_id) { [string]$v.vehicle_type_id } else { 'onbekend' }
                    if (-not $perType.ContainsKey($typ)) { $perType[$typ] = @{ beschikbaar = 0; gereserveerd = 0; defect = 0; bereik = (New-Object System.Collections.Generic.List[double]) } }
                    $a = $perType[$typ]
                    if (Test-GbfsWaar $v.is_disabled) { $a.defect++ }
                    elseif (Test-GbfsWaar $v.is_reserved) { $a.gereserveerd++ }
                    else { $a.beschikbaar++ }
                    if ($null -ne $v.current_range_meters) { $a.bereik.Add([double]$v.current_range_meters / 1000) }
                    $voertuigen++
                }
                foreach ($typ in $perType.Keys) {
                    $a = $perType[$typ]; $r = $basis.Clone()
                    $r.soort = 'los'; $r.voertuigtype = $typ; $r.beschikbaar = $a.beschikbaar; $r.gereserveerd = $a.gereserveerd; $r.defect = $a.defect
                    $r.mediaan_bereik_km = Get-Mediaan $a.bereik.ToArray()
                    [void]$rijen.Add($r)
                }
            }

            # Stations (OV-fiets, Donkey Republic, GoAbout, Cykl): voertuigen en vrije plekken bij elkaar opgeteld.
            if ($url['station_status']) {
                $st = @((Invoke-GetJson -Uri $url['station_status'] -TimeoutSec 30 -Pogingen 2).data.stations)
                $r = $basis.Clone(); $r.soort = 'station'; $r.voertuigtype = ''
                $r.stations = $st.Count
                $r.stations_verhuur = @($st | Where-Object { Test-GbfsWaar $_.is_renting }).Count
                $r.beschikbaar = ($st | ForEach-Object { if ($null -ne $_.num_vehicles_available) { [int]$_.num_vehicles_available } else { [int]$_.num_bikes_available } } | Measure-Object -Sum).Sum
                $r.vrije_plekken = ($st | ForEach-Object { if ($null -ne $_.num_docks_available) { [int]$_.num_docks_available } else { 0 } } | Measure-Object -Sum).Sum
                [void]$rijen.Add($r)
                $voertuigen += [int]$r.beschikbaar
            }
        } catch { $mislukt.Add($s.'System ID') }
        Suspend-Beleefd
    }
    if ($rijen.Count -eq 0) { throw "Geen enkele GBFS-feed gaf data ($($mislukt.Count) fouten)." }
    $map = Get-DataPath 'deelmobiliteit'
    New-Item -ItemType Directory -Force -Path $map | Out-Null
    Add-CsvRows -Path (Join-Path $map ((Get-Date).ToUniversalTime().ToString('yyyy-MM', $script:Inv) + '.csv')) `
        -Columns 'peilmoment', 'systeem_id', 'aanbieder', 'plaats', 'soort', 'voertuigtype', 'beschikbaar', 'gereserveerd', 'defect', 'mediaan_bereik_km', 'stations', 'stations_verhuur', 'vrije_plekken' -Rows $rijen
    $extra = if ($mislukt.Count) { "; niet bereikbaar: $($mislukt -join ', ')" } else { '' }
    return "$($systemen.Count - $mislukt.Count) van $($systemen.Count) systemen, $voertuigen voertuigen$extra"
}
