<#
.SYNOPSIS
    Plant de verzamelaar in Windows Taakplanner (onder je eigen account, geen beheerrechten nodig).
.EXAMPLE
    .\Installeer-Taak.ps1                       # elke dag om 06:30
.EXAMPLE
    .\Installeer-Taak.ps1 -Tijd 07:00 -LaadpuntenElkUur
.EXAMPLE
    .\Installeer-Taak.ps1 -Verwijder
#>
param(
    [string]$Tijd = '06:30',
    [switch]$LaadpuntenElkUur,
    [switch]$OvFiets,
    [switch]$Verwijder
)

$naamDag = 'Realtime-verzamelaar (dagelijks)'
$naamUur = 'Realtime-verzamelaar (laadpunten elk uur)'
$naamOvf = 'Realtime-verzamelaar (OV-fiets, ma en do)'

if ($Verwijder) {
    foreach ($n in $naamDag, $naamUur, $naamOvf) { Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue }
    Write-Host 'Geplande taken verwijderd.'
    return
}

$root = $PSScriptRoot
$exe = (Get-Process -Id $PID).Path          # powershell.exe of pwsh.exe, waarmee dit script draait
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) `
    -RestartCount 2 -RestartInterval (New-TimeSpan -Minutes 30) -MultipleInstances IgnoreNew

$actie = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $root `
    -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f (Join-Path $root 'Verzamel.ps1'))
Register-ScheduledTask -TaskName $naamDag -Action $actie -Trigger (New-ScheduledTaskTrigger -Daily -At $Tijd) -Settings $settings `
    -Description 'Haalt de real-time bronnen op en werkt de tijdreeksen bij.' -Force | Out-Null
Write-Host "Taak '$naamDag' gepland om $Tijd."

if ($LaadpuntenElkUur) {
    $actie = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $root `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}" -Bron Laadpunten' -f (Join-Path $root 'Verzamel.ps1'))
    $start = (Get-Date).Date.AddHours((Get-Date).Hour + 1).AddMinutes(5)
    $trigger = New-ScheduledTaskTrigger -Once -At $start -RepetitionInterval (New-TimeSpan -Hours 1)
    Register-ScheduledTask -TaskName $naamUur -Action $actie -Trigger $trigger -Settings $settings `
        -Description 'Momentopname van alle publieke laadpunten (bezetting en tarieven).' -Force | Out-Null
    Write-Host "Taak '$naamUur' gepland, eerste run om $($start.ToString('HH:mm'))."
}
if ($OvFiets) {
    $py = (Get-Command py -ErrorAction SilentlyContinue).Source
    if (-not $py) { throw 'Python-launcher (py) niet gevonden; installeer Python 3 van python.org.' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) 'ovfiets-scrape'
    $cmd = ('/c py "{0}" --all --no-raw --out "{1}" & py "{0}" --index --out "{1}" & py "{2}" "{1}" "{3}"' -f `
        (Join-Path $root 'ovfiets\scrape_ovfiets.py'), $tmp, (Join-Path $root 'ovfiets\samenvoegen.py'), (Join-Path $root 'data\ovfiets'))
    $actie = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument $cmd -WorkingDirectory $root
    $trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday, Thursday -At '04:20'
    Register-ScheduledTask -TaskName $naamOvf -Action $actie -Trigger $trigger -Settings $settings `
        -Description 'OV-fiets historie van alle locaties ophalen en samenvoegen.' -Force | Out-Null
    Write-Host "Taak '$naamOvf' gepland op maandag en donderdag om 04:20."
}
Write-Host 'Let op: de taken draaien alleen als deze computer aan staat; gemiste runs worden ingehaald zodra dat weer zo is.'
