# Netcongestie: de lagen achter de Capaciteitskaart van Netbeheer Nederland (ArcGIS, open, geen key).
# Schrijft alleen een nieuwe momentopname als de bron sinds de vorige run is gewijzigd.

$script:NcDiensten = 'Capaciteitskaart_elektriciteitsnet_v2_afname', 'Capaciteitskaart_elektriciteitsnet_v2_teruglevering',
                     'Capaciteitskaart_Tennet_afname', 'Capaciteitskaart_Tennet_teruglevering'
$script:NcBasis = 'https://services.arcgis.com/nSZVuSZjHpEZZbRo/arcgis/rest/services'

function Invoke-BronNetcongestie {
    $status = Get-Status 'netcongestie'
    $nieuweStatus = @{}
    if ($status) { foreach ($p in $status.PSObject.Properties) { $nieuweStatus[$p.Name] = $p.Value } }
    $meldingen = @()
    foreach ($dienst in $script:NcDiensten) {
        $svc = Invoke-GetJson -Uri "$script:NcBasis/$dienst/FeatureServer?f=json"
        $laagId = $svc.layers[0].id
        $laag = Invoke-GetJson -Uri "$script:NcBasis/$dienst/FeatureServer/$laagId`?f=json"
        $bewerkt = if ($laag.editingInfo -and $laag.editingInfo.dataLastEditDate) { [int64]$laag.editingInfo.dataLastEditDate } elseif ($laag.editingInfo) { [int64]$laag.editingInfo.lastEditDate } else { 0 }
        if ($nieuweStatus.ContainsKey($dienst) -and [int64]$nieuweStatus[$dienst] -eq $bewerkt -and $bewerkt -ne 0) {
            $meldingen += "$dienst ongewijzigd"; Suspend-Beleefd; continue
        }
        $velden = @($laag.fields | ForEach-Object { $_.name } | Where-Object { $_ -notmatch '^Shape__' })
        $rijen = New-Object System.Collections.ArrayList
        $offset = 0
        do {
            $uri = "$script:NcBasis/$dienst/FeatureServer/$laagId/query?where=1%3D1&outFields=*&returnGeometry=false&orderByFields=OBJECTID&resultOffset=$offset&resultRecordCount=1000&f=json"
            $res = Invoke-GetJson -Uri $uri
            foreach ($f in $res.features) {
                $r = @{ bron_bijgewerkt = [DateTimeOffset]::FromUnixTimeMilliseconds($bewerkt).UtcDateTime.ToString('yyyy-MM-ddTHH:mm:ssZ', $script:Inv); opgehaald_op = $script:RunStamp }
                foreach ($v in $velden) { $r[$v] = $f.attributes.$v }
                [void]$rijen.Add($r)
            }
            $offset += @($res.features).Count
            Suspend-Beleefd
        } while (@($res.features).Count -gt 0 -and $res.exceededTransferLimit)

        $kolommen = @('bron_bijgewerkt') + $velden + @('opgehaald_op')
        $pad = Get-DataPath ("netcongestie_" + ($dienst -replace '^Capaciteitskaart_', '').ToLower() + '.csv')
        if (Test-Path $pad) {
            $kop = (Get-Content -Path $pad -TotalCount 1 -Encoding UTF8).TrimStart([char]0xFEFF)
            if ($kop -ne ($kolommen -join ',')) {
                $pad = $pad -replace '\.csv$', ('_vanaf_' + $script:Today + '.csv')
                Write-Log "Velden van $dienst zijn veranderd; nieuwe reeks in $(Split-Path $pad -Leaf)." 'WARN'
            }
        }
        Add-CsvRows -Path $pad -Columns $kolommen -Rows $rijen
        Save-Ruw -Bron 'netcongestie' -Naam "$dienst.json" -Content ($rijen | ConvertTo-Json -Depth 3 -Compress)
        $nieuweStatus[$dienst] = $bewerkt
        $meldingen += "$dienst nieuwe momentopname ($($rijen.Count) gebieden)"
    }
    Set-Status 'netcongestie' $nieuweStatus
    return ($meldingen -join '; ')
}
