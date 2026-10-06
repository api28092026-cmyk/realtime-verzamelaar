# Parkeren: parkeertarieven (RDW Open Data), een keer per dag. Open, geen key.
# De bezetting van garages (tot en met 6 oktober 2026 elk uur in data/parkeren/bezetting/) zit sinds 6 oktober 2026 in de
# hoogfrequente verzamelaar (hoogfrequent/), elke 5 minuten.

$script:RdwTariefdeel = 'https://opendata.rdw.nl/resource/534e-5vdg.json'

function Invoke-BronParkeren {
    $meldingen = @()

    $map = Get-DataPath 'parkeren'; New-Item -ItemType Directory -Force -Path $map | Out-Null

    # Tarieven: een keer per dag de volledige tabel tariefdelen; per regel bijhouden wanneer hij voor het eerst en
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
    if (-not $meldingen) { return 'tarieven vandaag al bijgewerkt' }
    return ($meldingen -join '; ')
}
