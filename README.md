# Realtime-verzamelaar

Haalt elke nacht de zes bronnen op die in het *Real-time API-kompas* het oordeel **"Begin nu met opslaan"** kregen. Deze bronnen tonen alleen de actuele stand, of bewaren hun historie maar kort. Met deze verzamelaar bouw je daar een eigen tijdreeks van op.

Het geheel is geschreven in PowerShell en werkt zonder extra software in Windows PowerShell 5.1 (standaard op elke Windows-pc) en in PowerShell 7 (Windows, Linux, macOS). Geen enkele bron vraagt een account of API-key.

## Wat er verzameld wordt

| Bron | Wat je krijgt (in `data\`) | Bijzonderheden |
|---|---|---|
| **EnergyZero** | `energyzero_prijzen.csv`: uurprijs stroom (EUR/kWh) en gas (EUR/m³), excl. btw | Openbaar endpoint van de EnergyZero-app, geen officieel dataproduct. De gasprijs is een consumententarief: TTF day-ahead plus opslag en energiebelasting. De dagelijkse beweging volgt TTF. |
| **TenderNed** | `tenderned_publicaties.csv`: elke nieuwe aankondiging, gunning en rectificatie, met opdrachtgever, procedure, CPV- en regiocodes | Gebruikt het openbare JSON-endpoint achter tenderned.nl en valt terug op de officiële Atom-feed. De eerste run haalt ~1.000 publicaties terug (10–15 min). Het volledige detail per publicatie staat in `tenderned_details\`. |
| **RDW** | `rdw_registraties_per_soort.csv` (alle voertuigen per dag), `rdw_personenautos_per_brandstof.csv` en `..._per_merk.csv` (per dag, nieuw of import), `rdw_wagenpark_per_brandstof.csv` (hele wagenpark per peildatum) | De laatste 10 dagen worden elke run opnieuw geteld, zodat late registraties meetellen. "Benzine+Elektriciteit" omvat zowel plug-in als gewone hybrides. |
| **Laadpunten (DOT-NL)** | `laadpunten_per_exploitant.csv` en `laadpunten_per_plaats.csv`: aantallen per status (beschikbaar, aan het laden, defect …) en de mediaan kWh-prijs voor AC en DC | Elke run is een momentopname. Voor bezettingsgraden draai je deze bron elk uur (zie hieronder). De rij `_totaal` bevat heel Nederland. |
| **Netcongestie** | `netcongestie_*.csv`: vier lagen van de Capaciteitskaart (regionale netbeheerders en TenneT, afname en teruglevering), per voedingsgebied met status, wachtrij en aantal verzoeken | Schrijft alleen een nieuwe momentopname als de bron gewijzigd is. De statusvelden (`afname`, `opwek`) zijn de kleurcodes van de kaart. |
| **OV-fiets** (`ovfiets/`) | `data/ovfiets/historie/<code>/<JJJJ-MM>.csv`: beschikbare fietsen per locatie per ~15 min, plus `locaties_live_reeks.csv` | Python-script (alleen standaardbibliotheek) voor ovfietsbeschikbaar.nl. De site toont ~4 weken; `samenvoegen.py` bouwt daar doorlopende reeksen van. De reeks begint eind augustus 2026 (eerdere scrape meegenomen). |
| **KVK open dataset** | `kvk_stand_per_sbi.csv` en `kvk_stand_per_regio.csv` (bv's en nv's per actief/insolventie), `kvk_oprichtingen_per_dag.csv` | Anonieme vervanger van het Insolventieregister (zie hieronder). Alleen bv's en nv's, zonder namen. Nieuwe faillissementen zie je als stijging van `FAIL` tussen twee peildata. |

Alle CSV's gebruiken een komma als scheidingsteken en een punt als decimaalteken, in UTF-8. In Excel open je ze via **Gegevens > Van tekst/CSV**; in Power BI of Python lezen ze direct in. Elke rij heeft een `opgehaald_op`-tijdstempel (UTC).

## Snel starten

```powershell
cd D:\1_Eurekon\Downloads\realtime-verzamelaar
.\Verzamel.ps1                    # alle bronnen, ~5–15 minuten
.\Verzamel.ps1 -Bron RDW,TenderNed
```

Geeft Windows een melding over het uitvoeringsbeleid, start dan met:

```powershell
powershell -ExecutionPolicy Bypass -File .\Verzamel.ps1
```

Het logboek staat in `data\logs\`. Het resultaat van de laatste run per bron staat in `data\status\laatste_run.json`.

## Automatisch laten draaien

De volledige planning (GitHub Actions, crontab op een eigen server of Windows Taakplanner) staat in [CRON.md](CRON.md). Kort samengevat:

**Op deze computer (Windows Taakplanner):**

```powershell
.\Installeer-Taak.ps1                      # elke dag om 06:30
.\Installeer-Taak.ps1 -LaadpuntenElkUur    # plus elk uur een laadpunt-momentopname
.\Installeer-Taak.ps1 -Verwijder
```

De taken draaien onder je eigen account en alleen als de computer aan staat. Gemiste runs worden ingehaald.

**In de cloud (GitHub Actions):** zet deze map in een (privé) GitHub-repository. De workflow in `.github\workflows\verzamelen.yml` draait dan elke ochtend op een server van GitHub en legt de CSV's vast in de repository. Er hoeft geen computer aan te staan. De dagelijkse run past ruim binnen de gratis minuten van een privérepository. Een run van de laadpunten elk uur kost ongeveer 1.800 minuten per maand; doe dat dus liever lokaal.

## Anoniem verzamelen

Wat de bronnen van je zien, en wat je daaraan kunt doen:

- **Geen account, geen key.** Alle zes de bronnen zijn zonder registratie te gebruiken. Er is dus nergens een naam, e-mailadres of bedrijf aan de verzoeken gekoppeld.
- **Je haalt alles op, niet een selectie.** De scripts downloaden steeds de volledige landelijke dataset (alle laadpunten, alle bv's, alle publicaties) en filteren pas daarna. Een bron kan dus niet zien welke concurrent, regio of klant je volgt.
- **Neutrale identificatie.** De `UserAgent` in `config.psd1` noemt geen bedrijfsnaam. Laat hem eerlijk (geen nagebootste browser) en voeg desgewenst een algemeen contactadres toe; dat maakt het bronhouders makkelijker om contact op te nemen in plaats van te blokkeren.
- **Niet vanaf het kantoornetwerk.** Wil je niet dat verzoeken van het IP-adres van kantoor komen, draai dan via GitHub Actions (of een eigen cloudserver). De bronnen zien dan een IP-adres van Microsoft/GitHub. GitHub zelf weet uiteraard wel van wie de repository is.

Wat deze verzamelaar bewust **niet** doet: wisselende proxy's, nagebootste browsers of het omzeilen van limieten en blokkades. Dat is in strijd met de gebruiksvoorwaarden van de meeste bronnen en is ook niet nodig: het volume is een paar honderd rustige verzoeken per dag, met een pauze tussen elk verzoek.

## Waarom niet het Centraal Insolventieregister?

Het CIR is alleen geautomatiseerd te bevragen via een webservice-abonnement, dus met registratie, en het bevat persoonsgegevens (schuldsaneringen). Het veld `Insolventie` in de KVK open dataset geeft hetzelfde signaal voor alle bv's en nv's: anoniem, dagelijks en onder CC BY 4.0. Heb je per leverancier details nodig (curator, rechtbank, datum), vraag dan het gratis CIR-abonnement aan. Dat is een aparte module die zich identificeert.

## Onderhoud

- **Endpoints veranderen.** Vooral EnergyZero en het TenderNed-endpoint zijn onofficieel. Een falende bron staat als `ERROR` in het log en als `fout` in `laatste_run.json`; de andere bronnen draaien gewoon door.
- **Veldwijzigingen bij netcongestie** komen in een nieuw bestand (`..._vanaf_<datum>.csv`), zodat oude reeksen niet breken.
- **Ruwe downloads** (`data\ruw\`) worden na 30 dagen opgeruimd; de CSV's blijven altijd staan. Instellingen staan in `config.psd1`.
- **Bronvermelding.** De KVK-data valt onder CC BY 4.0 en de RDW-data onder CC0. Controleer de voorwaarden van de andere bronnen en vermeld altijd de bron in klantrapportages.
