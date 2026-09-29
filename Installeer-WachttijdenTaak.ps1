<#
.SYNOPSIS
    Plant de wachttijden-scraper (ZorgkaartNederland/NZa) als onzichtbare taak op deze pc.
    De data komt in .\lokaal\wachttijden\ en gaat nooit naar de openbare repository (lokaal\ staat in .gitignore).
    De taak start elke dag; de scraper haalt zelf hooguit een keer per 7 dagen op (WachttijdenDagen in config.psd1),
    zodat een gemiste week vanzelf wordt ingehaald zodra de pc aan staat.
    Start dit script als administrator (nodig voor een taak die onzichtbaar draait).
.EXAMPLE
    .\Installeer-WachttijdenTaak.ps1
.EXAMPLE
    .\Installeer-WachttijdenTaak.ps1 -Verwijder
#>
param(
    [string]$Tijd = '07:15',
    [switch]$Verwijder
)

$naam = 'Wachttijden ZorgkaartNederland (lokaal)'
if ($Verwijder) { Unregister-ScheduledTask -TaskName $naam -Confirm:$false -ErrorAction SilentlyContinue; Write-Host "Taak '$naam' verwijderd."; return }

$root = $PSScriptRoot
$data = Join-Path $root 'lokaal'
$exe = (Get-Process -Id $PID).Path
$actie = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $root `
    -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Bron Wachttijden -DataDir "{1}"' -f (Join-Path $root 'Verzamel.ps1'), $data)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -RunOnlyIfNetworkAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -ExecutionTimeLimit (New-TimeSpan -Hours 1) -MultipleInstances IgnoreNew
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited
try {
    Register-ScheduledTask -TaskName $naam -Action $actie -Trigger (New-ScheduledTaskTrigger -Daily -At $Tijd) -Settings $settings -Principal $principal `
        -Description 'Haalt wekelijks de NZa-wachttijden van ZorgkaartNederland op; data blijft lokaal.' -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Host "Taak kon niet worden aangemaakt: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Start dit script in een PowerShell-venster "Als administrator".'
    exit 1
}
Write-Host "Taak '$naam' ingesteld: elke dag om $Tijd een controle, ophalen hooguit eens per 7 dagen."
Write-Host "Data: $data\wachttijden\<jaar>.csv"
