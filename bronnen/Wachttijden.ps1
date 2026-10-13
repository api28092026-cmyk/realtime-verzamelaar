# Wachttijden van ZorgkaartNederland: VERVANGEN door de bron NzaWachttijden (13 oktober 2026).
# ZorgkaartNederland toonde de NZa-wachttijden zonder historie en met een rechtenvoorbehoud van de Patientenfederatie;
# de NZa publiceert dezelfde cijfers zelf als open data, met historie vanaf augustus 2021 (zie bronnen\NzaWachttijden.ps1).
# Deze functie bestaat nog zodat de lokale geplande taak niet faalt. Die taak kan weg, als administrator:
#   .\Installeer-WachttijdenTaak.ps1 -Verwijder
# De oude scraper staat in de git-historie; de metingen van 29 sep - 13 okt 2026 staan in lokaal\wachttijden.

function Invoke-BronWachttijden {
    return 'vervangen door NzaWachttijden (open data van de NZa); deze lokale taak kan worden verwijderd met Installeer-WachttijdenTaak.ps1 -Verwijder'
}