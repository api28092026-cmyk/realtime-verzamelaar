# TenderNed: nieuwe publicaties (aankondigingen, gunningen, rectificaties).
# Gebruikt het openbare JSON-endpoint achter tenderned.nl (geen account). Valt terug op de officiële
# Atom-feed (laatste 25 publicaties) als dat endpoint niet werkt.

function Get-XmlText { param($v) if ($null -eq $v) { return '' }; if ($v -is [string]) { return $v }; if ($v -is [array]) { $v = $v[0] }; if ($v.PSObject.Properties['#text']) { return [string]$v.'#text' }; if ($v.PSObject.Properties['href']) { return [string]$v.href }; return [string]$v.InnerText }
function Get-TnCode { param($v) if ($null -eq $v) { return '' }; if ($v.PSObject.Properties['code']) { return [string]$v.code }; return [string]$v }
function Get-TnOmschrijving { param($v) if ($null -eq $v) { return '' }; if ($v.PSObject.Properties['omschrijving']) { return [string]$v.omschrijving }; return [string]$v }

function Invoke-BronTenderNed {
    $csv = Get-DataPath 'tenderned_publicaties.csv'
    $cols = 'publicatie_id', 'publicatiedatum', 'type_publicatie', 'publicatiecode', 'aanbesteding', 'opdrachtgever', 'type_opdracht',
            'procedure', 'europees', 'sluitingsdatum', 'kenmerk', 'cpv_hoofd', 'cpv_codes', 'nuts_codes', 'juridisch_kader', 'is_gegund',
            'link', 'omschrijving', 'opgehaald_op'
    $bekend = Get-CsvColumnValues -Path $csv -Column 'publicatie_id'
    $nieuw = New-Object System.Collections.ArrayList
    $base = 'https://www.tenderned.nl/papi/tenderned-rs-tns/v2/publicaties'
    try {
        for ($page = 0; $page -lt [int]$script:Cfg.TenderNedMaxPaginas; $page++) {
            $res = Invoke-GetJson -Uri "$base`?page=$page&size=100"
            $nieuwOpPagina = 0
            foreach ($p in $res.content) {
                $id = [string]$p.publicatieId
                if ($bekend.Contains($id)) { continue }
                [void]$bekend.Add($id); $nieuwOpPagina++
                $oms = [string]$p.opdrachtBeschrijving
                if ($oms.Length -gt 1500) { $oms = $oms.Substring(0, 1500) }
                [void]$nieuw.Add(@{
                    publicatie_id = $id; publicatiedatum = (Format-Tijd $p.publicatieDatum)
                    type_publicatie = (Get-TnOmschrijving $p.typePublicatie); publicatiecode = (Get-TnCode $p.publicatiecode)
                    aanbesteding = $p.aanbestedingNaam; opdrachtgever = $p.opdrachtgeverNaam; type_opdracht = (Get-TnOmschrijving $p.typeOpdracht)
                    procedure = (Get-TnOmschrijving $p.procedure); europees = $p.europees; sluitingsdatum = (Format-Tijd $p.sluitingsDatum)
                    kenmerk = $p.kenmerk; link = $p.link.href; omschrijving = $oms.Replace("`r", ' ').Replace("`n", ' ')
                    cpv_hoofd = ''; cpv_codes = ''; nuts_codes = ''; juridisch_kader = ''; is_gegund = ''; opgehaald_op = $script:RunStamp
                })
            }
            Suspend-Beleefd
            if ($nieuwOpPagina -eq 0 -or $res.last) { break }
        }
    } catch {
        Write-Log "TenderNed JSON-endpoint faalde ($($_.Exception.Message)); terugval op de Atom-feed." 'WARN'
        [xml]$feed = Invoke-Get -Uri 'https://www.tenderned.nl/papi/tenderned-rs-tns/rss/laatste-publicatie.rss'
        foreach ($e in $feed.feed.entry) {
            $link = Get-XmlText $e.link
            $id = ($link -split '/')[-1]
            if (-not $id -or $bekend.Contains($id)) { continue }
            [void]$bekend.Add($id)
            [void]$nieuw.Add(@{ publicatie_id = $id; publicatiedatum = (Get-XmlText $e.published); aanbesteding = (Get-XmlText $e.title); opdrachtgever = (Get-XmlText $e.author.name);
                link = $link; omschrijving = (Get-XmlText $e.summary); opgehaald_op = $script:RunStamp })
        }
    }

    if ($script:Cfg.TenderNedDetails -and $nieuw.Count -gt 0) {
        $detailDir = Get-DataPath 'tenderned_details'
        New-Item -ItemType Directory -Force -Path $detailDir | Out-Null
        $jsonl = Join-Path $detailDir ((Get-Date).ToString('yyyy-MM', $script:Inv) + '.jsonl')
        foreach ($r in $nieuw) {
            try {
                $raw = Invoke-Get -Uri "$base/$($r.publicatie_id)"
                $d = $raw | ConvertFrom-Json
                [IO.File]::AppendAllText($jsonl, ($raw -replace "\r?\n", ' ') + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
                $cpv = @($d.cpvCodes)
                $hoofd = $cpv | Where-Object { $_.isHoofdOpdracht } | Select-Object -First 1
                $r.cpv_hoofd = if ($hoofd) { $hoofd.code } else { '' }
                $r.cpv_codes = (($cpv | ForEach-Object { $_.code }) -join ' ')
                $r.nuts_codes = ((@($d.nutsCodes) | ForEach-Object { $_.code }) -join ' ')
                $r.juridisch_kader = Get-TnCode $d.juridischKaderCode
                $r.is_gegund = $d.isGegund
            } catch { Write-Log "Detail van publicatie $($r.publicatie_id) niet opgehaald: $($_.Exception.Message)" 'WARN' }
            Suspend-Beleefd
        }
    }
    Add-CsvRows -Path $csv -Columns $cols -Rows $nieuw
    return "$($nieuw.Count) nieuwe publicaties"
}
