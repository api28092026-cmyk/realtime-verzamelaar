<#
.SYNOPSIS
    Haalt de 'begin nu met opslaan'-bronnen op en werkt de tijdreeksen in .\data bij.
.EXAMPLE
    .\Verzamel.ps1                         # alle bronnen
.EXAMPLE
    .\Verzamel.ps1 -Bron Laadpunten        # één bron (bijv. elk uur voor bezettingsgraden)
#>
[CmdletBinding()]
param(
    [ValidateSet('EnergyZero', 'TenderNed', 'RDW', 'Laadpunten', 'Netcongestie', 'KvkOpenData', 'Parkeren', 'Deelmobiliteit', 'Verstoringen', 'OV', 'NS', 'Energie', 'Wachttijden')]
    [string[]]$Bron = @('EnergyZero', 'TenderNed', 'RDW', 'Laadpunten', 'Netcongestie', 'KvkOpenData', 'Parkeren', 'Deelmobiliteit', 'Verstoringen', 'OV', 'NS', 'Energie'),
    # Andere datamap dan in config.psd1, bv. voor bronnen die alleen lokaal mogen (Wachttijden -> lokaal\).
    [string]$DataDir
)

$root = $PSScriptRoot
. (Join-Path (Join-Path $root 'lib') 'Common.ps1')
Get-ChildItem -Path (Join-Path $root 'bronnen') -Filter '*.ps1' | ForEach-Object { . $_.FullName }
$config = Import-PowerShellDataFile (Join-Path $root 'config.psd1')
if ($DataDir) { $config.DataDir = $DataDir }
Initialize-Verzamelaar -Config $config -Root $root

$resultaat = [ordered]@{}
$fouten = 0
foreach ($b in $Bron) {
    $start = Get-Date
    try {
        $melding = & "Invoke-Bron$b"
        $sec = [int]((Get-Date) - $start).TotalSeconds
        Write-Log "$b OK in $sec s: $melding"
        $resultaat[$b] = @{ status = 'ok'; melding = [string]$melding; seconden = $sec; tijd = $script:RunStamp }
    } catch {
        $fouten++
        Write-Log "$b MISLUKT: $($_.Exception.Message)" 'ERROR'
        $resultaat[$b] = @{ status = 'fout'; melding = $_.Exception.Message; tijd = $script:RunStamp }
    }
}

# Laatste resultaat per bron bijhouden (handig voor bewaking).
$vorig = Get-Status 'laatste_run'
$alle = @{}
if ($vorig) { foreach ($p in $vorig.PSObject.Properties) { $alle[$p.Name] = $p.Value } }
foreach ($k in $resultaat.Keys) { $alle[$k] = $resultaat[$k] }
Set-Status 'laatste_run' $alle
Clear-OudeRuweData

if ($fouten -gt 0) { exit 1 }
