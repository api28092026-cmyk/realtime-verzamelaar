# NS API (apiportal.ns.nl), met een gratis key in de omgevingsvariabele NS_API_KEY (GitHub-geheim).
# De gratis key is bedoeld voor niet-commercieel gebruik; daarom slaan we alleen samenvattingen op, geen ruwe NS-data.
#  - Storingen en werkzaamheden (Disruptions API v3): logboek per melding, eerst en laatst gezien.
#  - Drukte (Virtual Train API): per station het aantal treinen met drukteverwachting laag, middel of hoog,
#    voor alle treinen die op dat moment rijden; plus het aantal rijdende treinen per treintype.
#  - Stations (NS-APP Stations API): referentietabel, een keer per dag.
# Limiet voor gratis gebruikers: 300 verzoeken per 5 minuten; we blijven daar ruim onder.

$script:NsBasis = 'https://gateway.apiportal.ns.nl'

function Invoke-NsGet {
    param([string]$Pad)
    $headers = @{ 'Ocp-Apim-Subscription-Key' = $env:NS_API_KEY; 'Accept' = 'application/json' }
    $delay = 5
    for ($i = 1; $i -le 3; $i++) {
        try {
            $r = Invoke-WebRequest -Uri ($script:NsBasis + $Pad) -Headers $headers -UserAgent $script:Cfg.UserAgent -UseBasicParsing -TimeoutSec 60
            return ConvertFrom-Json -InputObject ([Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()))
        } catch {
            $code = Get-HttpStatus $_
            if ($i -eq 3 -or ($code -ge 400 -and $code -lt 500 -and $code -ne 429)) { throw }
            Start-Sleep -Seconds $(if ($code -eq 429) { 65 } else { $delay }); $delay *= 3
        }
    }
}

function Get-NsTijd { param($t) if (-not $t) { return '' }; if ($t -is [datetime]) { return $t.ToString('yyyy-MM-ddTHH:mm:ss', $script:Inv) }; return [string]$t }

function Update-NsStations {
    $pad = Join-Path (Get-DataPath 'ns') 'stations.csv'
    $status = Get-Status 'ns'
    if ((Test-Path $pad) -and $status -and $status.stations_peildatum -eq $script:Today) { return $null }
    $st = @((Invoke-NsGet '/nsapp-stations/v3').payload)
    $rijen = foreach ($s in $st) { @{ code = $s.id.code; uic = $s.id.uicCode; naam = $s.names.long; land = $s.country; type = $s.stationType; lat = $s.location.lat; lng = $s.location.lng } }
    if (Test-Path $pad) { Remove-Item $pad }
    Add-CsvRows -Path $pad -Columns 'code', 'uic', 'naam', 'land', 'type', 'lat', 'lng' -Rows @($rijen)
    Set-Status 'ns' @{ stations_peildatum = $script:Today }
    return "stations: $($st.Count)"
}

function Invoke-NsStoringen {
    $meldingen = @{}
    foreach ($type in 'DISRUPTION', 'MAINTENANCE', 'CALAMITY') {
        foreach ($d in @(Invoke-NsGet "/disruptions/v3?isActive=true&type=$type")) {
            if (-not $d.id) { continue }
            $ts = @($d.timespans) | Select-Object -First 1
            $stations = New-Object System.Collections.Generic.List[string]
            foreach ($ps in @($d.publicationSections)) { foreach ($s in @($ps.section.stations)) { if ($s.stationCode -and -not $stations.Contains($s.stationCode)) { $stations.Add($s.stationCode) } } }
            $meldingen[[string]$d.id] = @{
                melding_id = [string]$d.id; type = $d.type; titel = [string]$d.title; impact = $d.impact.value
                oorzaak = [string]$ts.cause.label; situatie = [string]$ts.situation.label; fase = [string]$d.phase.label
                begin = (Get-NsTijd $d.start); eind = (Get-NsTijd $d.end); verwacht_eind = (Get-NsTijd $d.expectedDuration.endTime)
                stations = ($stations -join ' '); aantal_stations = $stations.Count; buitenland = [bool](@($d.publicationSections) | Where-Object { $_.sectionType -eq 'NEIGHBORING_COUNTRY' })
            }
        }
        Start-Sleep -Milliseconds 800
    }
    $map = Join-Path (Get-DataPath 'ns') 'storingen'; New-Item -ItemType Directory -Force -Path $map | Out-Null
    $maand = (Get-Date).ToUniversalTime().ToString('yyyy-MM', $script:Inv)
    $status = Get-Status 'ns_storingen'
    $inMaand = @{}; if ($status -and $status.actief) { foreach ($p in $status.actief.PSObject.Properties) { $inMaand[$p.Name] = [string]$p.Value } }
    $perMaand = @{}; foreach ($id in $meldingen.Keys) { $m = if ($inMaand.ContainsKey($id)) { $inMaand[$id] } else { $maand }; if (-not $perMaand.ContainsKey($m)) { $perMaand[$m] = @() }; $perMaand[$m] += $id }
    $kolommen = 'melding_id', 'type', 'titel', 'impact', 'oorzaak', 'situatie', 'fase', 'begin', 'eind', 'verwacht_eind', 'stations', 'aantal_stations', 'buitenland', 'eerst_gezien', 'laatst_gezien'
    $nieuw = 0
    foreach ($m in $perMaand.Keys) {
        $pad = Join-Path $map "$m.csv"
        $bestaand = @{}; if (Test-Path $pad) { foreach ($r in (Import-Csv $pad)) { $bestaand[$r.melding_id] = $r } }
        foreach ($id in $perMaand[$m]) {
            $n = $meldingen[$id]
            if ($bestaand.ContainsKey($id)) { $o = $bestaand[$id]; foreach ($v in 'impact', 'oorzaak', 'situatie', 'fase', 'eind', 'verwacht_eind', 'stations', 'aantal_stations') { $o.$v = $n[$v] }; $o.laatst_gezien = $script:RunStamp }
            else { $h = [ordered]@{}; foreach ($v in $kolommen) { $h[$v] = $n[$v] }; $h.eerst_gezien = $script:RunStamp; $h.laatst_gezien = $script:RunStamp; $bestaand[$id] = [pscustomobject]$h; $nieuw++ }
        }
        if (Test-Path $pad) { Remove-Item $pad }
        Add-CsvRows -Path $pad -Columns $kolommen -Rows @($bestaand.Values)
    }
    $actief = @{}; foreach ($m in $perMaand.Keys) { foreach ($id in $perMaand[$m]) { $actief[$id] = $m } }
    Set-Status 'ns_storingen' @{ actief = $actief }
    return "storingen/werkzaamheden: $($meldingen.Count) actief, $nieuw nieuw"
}

function Invoke-NsDrukte {
    # Alle treinen die nu rijden (posities), daarna per trein de drukteverwachting per station.
    $treinen = @((Invoke-NsGet '/virtual-train-api/api/vehicle').payload.treinen)
    $perType = @{}; foreach ($t in $treinen) { $perType[[string]$t.type] = 1 + [int]$perType[[string]$t.type] }
    $max = if ($script:Cfg.NsDrukteMaxTreinen) { [int]$script:Cfg.NsDrukteMaxTreinen } else { 400 }
    $nummers = @($treinen | ForEach-Object { [string]$_.treinNummer } | Where-Object { $_ } | Select-Object -Unique | Select-Object -First $max)
    $perStation = @{}; $gelukt = 0
    foreach ($nr in $nummers) {
        try {
            foreach ($p in @((Invoke-NsGet "/virtual-train-api/api/v1/prognose/$nr").prognoses)) {
                $k = [string]$p.stationUic
                if (-not $perStation.ContainsKey($k)) { $perStation[$k] = @{ LOW = 0; MEDIUM = 0; HIGH = 0; overig = 0 } }
                $c = [string]$p.classification; if ($perStation[$k].ContainsKey($c)) { $perStation[$k][$c]++ } else { $perStation[$k].overig++ }
            }
            $gelukt++
        } catch { }
        Start-Sleep -Milliseconds 1100     # ruim onder 300 verzoeken per 5 minuten
    }
    $map = Join-Path (Get-DataPath 'ns') 'drukte'; New-Item -ItemType Directory -Force -Path $map | Out-Null
    $maand = (Get-Date).ToUniversalTime().ToString('yyyy-MM', $script:Inv)
    $rijen = foreach ($k in $perStation.Keys) { $a = $perStation[$k]; @{ peilmoment = $script:RunStamp; station_uic = $k; treinen_laag = $a.LOW; treinen_middel = $a.MEDIUM; treinen_hoog = $a.HIGH; overig = $a.overig } }
    Add-CsvRows -Path (Join-Path $map "$maand.csv") -Columns 'peilmoment', 'station_uic', 'treinen_laag', 'treinen_middel', 'treinen_hoog', 'overig' -Rows @($rijen)
    $typeRijen = foreach ($k in $perType.Keys) { @{ peilmoment = $script:RunStamp; treintype = $k; rijdende_treinen = $perType[$k] } }
    Add-CsvRows -Path (Join-Path (Get-DataPath 'ns') 'rijdende_treinen.csv') -Columns 'peilmoment', 'treintype', 'rijdende_treinen' -Rows @($typeRijen)
    $hoog = 0; foreach ($a in $perStation.Values) { $hoog += $a.HIGH }
    return "drukte: $gelukt van $($nummers.Count) rijdende treinen, $($perStation.Count) stations, $hoog keer drukte hoog"
}

function Invoke-BronNS {
    if (-not $env:NS_API_KEY) { return 'overgeslagen: geen NS_API_KEY ingesteld' }
    New-Item -ItemType Directory -Force -Path (Get-DataPath 'ns') | Out-Null
    $uit = @()
    $s = Update-NsStations; if ($s) { $uit += $s }
    $uit += Invoke-NsStoringen
    $uit += Invoke-NsDrukte
    return ($uit -join '; ')
}
