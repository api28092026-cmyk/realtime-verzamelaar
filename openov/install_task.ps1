<#
Registreert de Taakplanner-taak "OV-fiets data sync": draait sync_local.ps1 bij aanmelden en daarna elk uur.
Gemiste runs (laptop uit of in slaap) worden ingehaald zodra de laptop weer aanstaat.
Verwijderen: Unregister-ScheduledTask -TaskName 'OV-fiets data sync' -Confirm:$false
#>
$script = Join-Path $PSScriptRoot 'sync_local.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
$triggers = @(
    New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1)
)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
Register-ScheduledTask -TaskName 'OV-fiets data sync' -Action $action -Trigger $triggers -Settings $settings `
    -Description 'Haalt OV-fiets data van GitHub (api28092026-cmyk/realtime-verzamelaar) naar de lokale schijf' -Force
