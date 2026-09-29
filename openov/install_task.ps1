<#
Registreert de Taakplanner-taak "OV-fiets data sync": draait sync_local.ps1 uit deze map bij aanmelden en
daarna elk uur. De data komt in data\ naast dit script (standaard), of in de map die je met -Dest opgeeft.
Gemiste runs (laptop uit of in slaap) worden ingehaald zodra de laptop weer aanstaat.

Een bestaande taak met dezelfde naam wordt vervangen. Is die ooit met beheerrechten aangemaakt, start dit
script dan in een PowerShell-venster "Als administrator".

  .\install_task.ps1                  # data in openov\data
  .\install_task.ps1 -Dest D:\ergens  # andere doelmap
Verwijderen: Unregister-ScheduledTask -TaskName 'OV-fiets data sync' -Confirm:$false
#>
param([string]$Dest = (Join-Path $PSScriptRoot 'data'))

$naam = 'OV-fiets data sync'
$script = Join-Path $PSScriptRoot 'sync_local.ps1'
$action = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $PSScriptRoot `
    -Argument "-NoProfile -NonInteractive -ExecutionPolicy RemoteSigned -File `"$script`" -Dest `"$Dest`""
$triggers = @(
    New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Hours 1)
)
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
    -RunOnlyIfNetworkAvailable -ExecutionTimeLimit (New-TimeSpan -Minutes 15) -MultipleInstances IgnoreNew
# S4U = "ook uitvoeren als de gebruiker niet is aangemeld", zonder opgeslagen wachtwoord. De taak draait dan in een
# eigen, onzichtbare sessie: geen flitsend PowerShell-venster. Internet werkt; netwerkschijven met inlog niet.
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Limited

try {
    if (Get-ScheduledTask -TaskName $naam -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $naam -Confirm:$false -ErrorAction Stop
    }
    Register-ScheduledTask -TaskName $naam -Action $action -Trigger $triggers -Settings $settings -Principal $principal -ErrorAction Stop `
        -Description 'Haalt OV-fiets data van GitHub (api28092026-cmyk/realtime-verzamelaar) naar de lokale schijf' | Out-Null
} catch {
    Write-Host "Taak kon niet worden vervangen: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Start dit script opnieuw in een PowerShell-venster "Als administrator".'
    exit 1
}

$t = Get-ScheduledTask -TaskName $naam
Write-Host "Taak '$naam' ingesteld."
Write-Host "  script: $script"
Write-Host "  data:   $Dest"
Write-Host "  draait: bij aanmelden en elk uur"
Start-ScheduledTask -TaskName $naam
Write-Host 'Eerste synchronisatie gestart; zie sync.log in de datamap.'
