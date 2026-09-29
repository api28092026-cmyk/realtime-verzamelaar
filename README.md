# Realtime-verzamelaar

Bouwt tijdreeksen op uit open databronnen die zelf alleen de actuele stand tonen, of hun historie maar kort bewaren. Wat je niet opslaat, is weg; deze repository slaat het elke dag op.

- `Verzamel.ps1` met `bronnen/`: zes realtime-bronnen, in PowerShell (Windows PowerShell 5.1 of PowerShell 7).
- `ovfiets/`: OV-fiets-historie per locatie van ovfietsbeschikbaar.nl, in Python.
- `openov/`: OV-fiets-wijzigingen per 5 minuten van fiets.openov.nl, in Python.

Geen enkele bron vraagt een account of API-key. De workflows draaien op GitHub Actions en worden gestart door cron-job.org (zie [CRON.md](CRON.md)).

## Wat er verzameld wordt

| Bron | Wat je krijgt (in `data\`) | Bijzonderheden |
|---|---|---|
| **EnergyZero** | `energyzero_prijzen.csv`: uurprijs stroom (EUR/kWh) en gas (EUR/m³), excl. btw | Openbaar endpoint van de EnergyZero-app, geen officieel dataproduct. De gasprijs is een consumententarief: TTF day-ahead plus opslag en energiebelasting. De dagelijkse beweging volgt TTF. |
| **TenderNed** | `tenderned_publicaties.csv`: elke nieuwe aankondiging, gunning en rectificatie, met opdrachtgever, procedure, CPV- en regiocodes | Gebruikt het openbare JSON-endpoint achter tenderned.nl en valt terug op de officiële Atom-feed. De eerste run haalt ~1.000 publicaties terug (10–15 min). Het volledige detail per publicatie staat in `tenderned_details\`. |
| **RDW** | `rdw_registraties_per_soort.csv` (alle voertuigen per dag), `rdw_personenautos_per_brandstof.csv` en `..._per_merk.csv` (per dag, nieuw of import), `rdw_wagenpark_per_brandstof.csv` (hele wagenpark per peildatum) | De laatste 10 dagen worden elke run opnieuw geteld, zodat late registraties meetellen. "Benzine+Elektriciteit" omvat zowel plug-in als gewone hybrides. |
| **Laadpunten (DOT-NL)** | `laadpunten_per_exploitant.csv` en `laadpunten_per_plaats.csv`: aantallen per status (beschikbaar, aan het laden, defect …) en de mediaan kWh-prijs voor AC en DC | Elke run is een momentopname. Voor bezettingsgraden draai je deze bron elk uur (zie hieronder). De rij `_totaal` bevat heel Nederland. |
| **Netcongestie** | `netcongestie_*.csv`: vier lagen van de Capaciteitskaart (regionale netbeheerders en TenneT, afname en teruglevering), per voedingsgebied met status, wachtrij en aantal verzoeken | Schrijft alleen een nieuwe momentopname als de bron gewijzigd is. De statusvelden (`afname`, `opwek`) zijn de kleurcodes van de kaart. |
| **OV-fiets** (`ovfiets/`) | `data/ovfiets/historie/<code>/<JJJJ-MM>.csv`: beschikbare fietsen per locatie per ~15 min, plus `locaties_live_reeks.csv` | Python-script (alleen standaardbibliotheek) voor ovfietsbeschikbaar.nl. De site toont ~4 weken; `samenvoegen.py` bouwt daar doorlopende reeksen van. De reeks begint eind augustus 2026 (eerdere scrape meegenomen). |
| **OV-fiets wijzigingen** (`openov/`) | Op de branch `data`: `changes/<JJJJ-MM>.csv` (een regel per locatie waarvan het aantal fietsen of de openingsstatus veranderde), `scrapes/<JJJJ-MM>.csv` (elke poging, voor dekking en gaten), `locaties_meta.csv` en `state.json` | Elke 5 minuten via cron-job.org. Afgesloten maanden gaan als zip naar een release `data-JJJJ-MM` en daarna uit de branch. `openov/sync_local.ps1` haalt alles naar de lokale schijf. |
| **Parkeren** | `data/parkeren/bezetting/<JJJJ-MM>.csv`: per garage capaciteit, vrije plekken, open en vol (~325 garages met openbare NPR-data); `data/parkeren/tariefdelen.csv`: alle RDW-tariefdelen met `eerst_gezien` en `laatst_gezien` | Bezetting is een momentopname: draai deze bron elk uur. Garages met `limitedAccess` (login vereist) worden overgeslagen. Tarieven worden één keer per dag vergeleken; een gewijzigd tarief verschijnt als nieuwe regel, de oude houdt zijn laatste datum. |
| **Deelmobiliteit** | `data/deelmobiliteit/<JJJJ-MM>.csv`: per aanbieder, stad en voertuigtype het aantal beschikbare, gereserveerde en defecte voertuigen, mediaan bereik, en per stationsysteem de voertuigen en vrije plekken in stations | Alle Nederlandse GBFS-feeds uit de catalogus van MobilityData (Check, Felyx, Donkey Republic, Cykl, GoAbout, OV-fiets). Dott vraagt sinds kort een login en valt buiten beeld. Momentopname: draai elk uur. |
| **Verstoringen** | Weg: `data/verstoringen/weg/<JJJJ-MM>.csv` (logboek per NDW-melding: type, oorzaak, begin, eind, vertraging, locatie, eerst en laatst gezien) en `weg_aantallen/<JJJJ-MM>.csv` (tellingen per run). Spoor: `spoor_per_dag.csv` (ritten, uitval, punctualiteit per dag, vervoerder en treinsoort) en `spoor_per_station/<JJJJ-MM>.csv` | Weg komt uit NDW 'actueel beeld' (DATEX II v3); draai elk uur, anders mis je korte incidenten. Spoor komt uit het maandarchief van Rijden de Treinen (verschijnt begin volgende maand); elke maand wordt één keer samengevat, vanaf januari 2026. |
| **KVK open dataset** | `kvk_stand_per_sbi.csv` en `kvk_stand_per_regio.csv` (bv's en nv's per actief/insolventie), `kvk_oprichtingen_per_dag.csv` | Anonieme vervanger van het Insolventieregister (zie hieronder). Alleen bv's en nv's, zonder namen. Nieuwe faillissementen zie je als stijging van `FAIL` tussen twee peildata. |

Alle CSV's gebruiken een komma als scheidingsteken en een punt als decimaalteken, in UTF-8. In Excel open je ze via **Gegevens > Van tekst/CSV**; in Power BI of Python lezen ze direct in. Elke rij heeft een `opgehaald_op`-tijdstempel (UTC).

## Snel starten

```powershell
cd realtime-verzamelaar
.\Verzamel.ps1                    # alle bronnen, ~5–15 minuten
.\Verzamel.ps1 -Bron RDW,TenderNed
```

Geeft Windows een melding over het uitvoeringsbeleid, start dan met:

```powershell
powershell -ExecutionPolicy Bypass -File .\Verzamel.ps1
```

Het logboek staat in `data\logs\`. Het resultaat van de laatste run per bron staat in `data\status\laatste_run.json`.

## Automatisch laten draaien

De workflows draaien op GitHub Actions. Omdat de repository openbaar is, zijn de minuten gratis; de verzamelde data is daardoor ook openbaar. cron-job.org start ze op vaste tijden: elke 5 minuten OV-fiets-wijzigingen, dagelijks de realtime-bronnen, optioneel elk uur de laadpunten en twee keer per week de OV-fiets-historie. Hoe je dat instelt, staat stap voor stap in [CRON.md](CRON.md), samen met de alternatieven via crontab op een eigen server en via Windows Taakplanner (`Installeer-Taak.ps1`).

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
- **Bronvermelding.** De KVK-data valt onder CC BY 4.0 en de RDW-data onder CC0. Controleer de voorwaarden van de andere bronnen en vermeld altijd de bron wanneer je de data gebruikt of deelt.
