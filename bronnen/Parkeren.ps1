# Parkeren: bezetting van garages (NPR open parkeerdata, RDW) en parkeertarieven (RDW Open Data). Open, geen key.
# Bezetting is een momentopname per run; draai deze bron ook elk uur voor bezettingsgraden.

$script:NprCatalogus = 'https://npropendata.rdw.nl/parkingdata/v2'
$script:RdwTariefdeel = 'https://opendata.rdw.nl/resource/534e-5vdg.json'

function Invoke-BronParkeren {
    $meldingen = @()

    # 1. Bezetting: alle garages met openbare dynamische data (garages met limitedAccess vragen een login).
    $cat = Invoke-GetJson -Uri $script:NprCatalogus -TimeoutSec 180
    $garages = @($cat.ParkingFacilities | Where-Object { $_.dynamicDataUrl -and -not $_.limitedAccess })
    $pauze = if ($script:Cfg.ParkerenPauzeMs) { [int]$script:Cfg.ParkerenPauzeMs } else { 200 }
    $rijen = New-Object System.Collections.ArrayList
    $mislukt = 0
    foreach ($g in $garages) {
        try {
            $st = (Invoke-GetJson -Uri $g.dynamicDataUrl -TimeoutSec 20 -Pogingen 2).parkingFacilityDynamicInformation.facilityActualStatus
            if ($st) {
                $bij = if ($st.lastUpdated) { [DateTimeOffset]::FromUnixTimeSeconds([int64]$st.lastUpdated).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', $script:Inv) } else { '' }
                [void]$rijen.Add(@{ peilmoment = $script:RunStamp; garage_id = $g.identifier; naam = $g.name; capaciteit = $st.parkingCapacity
                    vrij = $st.vacantSpaces; open = $st.open; vol = $st.full; bron_bijgewerkt = $bij })
            }
        } catch { $mislukt++ }
        Start-Sleep -Milliseconds $pauze
    }
    if ($rijen.Count -eq 0) { throw "Geen enkele garage gaf bezettingsdata ($mislukt fouten)." }
    $map = Get-DataPath 'parkeren'; New-Item -ItemType Directory -Force -Path (Join-Path $map 'bezetting') | Out-Null
    Add-CsvRows -Path (Join-Path (Join-Path $map 'bezetting') ((Get-Date).ToUniversalTime().ToString('yyyy-MM', $script:Inv) + '.csv')) `
        -Columns 'peilmoment', 'garage_id', 'naam', 'capaciteit', 'vrij', 'open', 'vol', 'bron_bijgewerkt' -Rows $rijen
    $meldingen += "bezetting van $($rijen.Count) van $($garages.Count) garages ($mislukt mislukt)"

    # 2. Tarieven: één keer per dag de volledige tabel tariefdelen; per regel bijhouden wanneer hij voor het eerst en
    #    het laatst gezien is. Zo blijft een wijziging zichtbaar, ook als RDW een oude regel verwijdert.
    $status = Get-Status 'parkeren'
    if (-not $status -or $status.tarieven_peildatum -ne $script:Today) {
        $tarief = @(Invoke-GetJson -Uri ($script:RdwTariefdeel + '?$limit=200000') -TimeoutSec 300)
        if ($tarief.Count -lt 1000) { throw "Tarieftabel lijkt onvolledig ($($tarief.Count) regels)." }
        $velden = 'areamanagerid', 'farecalculationcode', 'startdatefarepart', 'enddatefarepart', 'startdurationfarepart', 'enddurationfarepart', 'amountfarepart', 'stepsizefarepart', 'amountcumulative'
        $pad = Join-Path $map 'tariefdelen.csv'
        $oud = @{}
        if (Test-Path $pad) { foreach ($r in (Import-Csv $pad)) { $oud[(($velden | ForEach-Object { [string]$r.$_ }) -join '|')] = $r } }
        $nieuw = 0
        foreach ($t in $tarief) {
            $k = ($velden | ForEach-Object { [string]$t.$_ }) -join '|'
            if ($oud.ContainsKey($k)) { $oud[$k].laatst_gezien = $script:Today }
            else {
                $h = [ordered]@{}; foreach ($v in $velden) { $h[$v] = [string]$t.$v }
                $h.eerst_gezien = $script:Today; $h.laatst_gezien = $script:Today
                $oud[$k] = [pscustomobject]$h; $nieuw++
            }
        }
        $alle = @($oud.Values)
        if (Test-Path $pad) { Remove-Item $pad }
        Add-CsvRows -Path $pad -Columns ($velden + @('eerst_gezien', 'laatst_gezien')) -Rows $alle
        Set-Status 'parkeren' @{ tarieven_peildatum = $script:Today }
        $meldingen += "tarieven: $($tarief.Count) tariefdelen, $nieuw nieuw"
    }
    return ($meldingen -join '; ')
}
