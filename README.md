# Realtime-verzamelaar

Bouwt tijdreeksen op uit open databronnen die zelf alleen de actuele stand tonen, of hun historie maar kort bewaren. Wat je niet opslaat, is weg; deze repository slaat het elke dag op.

- `Verzamel.ps1` met `bronnen/`: zes realtime-bronnen, in PowerShell (Windows PowerShell 5.1 of PowerShell 7).
- `ovfiets/`: OV-fiets-historie per locatie van ovfietsbeschikbaar.nl, in Python.
- `openov/`: OV-fiets-wijzigingen per 5 minuten van fiets.openov.nl, in Python.

Geen enkele bron vraagt een account of API-key. De workflows draaien op GitHub Actions en worden gestart door cron-job.org (zie [CRON.md](CRON.md)).

## Wat er verzameld wordt

| Bron | Wat je krijgt (in `data\`) | Bijzonderheden |
|---|---|---|
| **EnergyZero** | `energyzero_prijzen.csv`: uurprijs stroom (EUR/kWh) en gas (EUR/m³), excl. btw; `gasprijs_dag.csv`: gasprijs per gasdag (06:00–06:00) in EUR/m³ en omgerekend naar EUR/MWh, vanaf 2020 | Openbaar endpoint van de EnergyZero-app, geen officieel dataproduct. Het is de kale beursprijs zonder opslag en energiebelasting: de stroomprijs is gelijk aan de Nord Pool-dagprijs (gecontroleerd), de gasprijs is de TTF day-ahead-prijs, afgerond op hele centen per m³ (circa 0,5 EUR/MWh nauwkeurig). Omrekening met 9,769 kWh/m³ (Groningen-equivalent). |
| **TenderNed** | `tenderned_publicaties.csv`: elke nieuwe aankondiging, gunning en rectificatie, met opdrachtgever, procedure, CPV- en regiocodes | Gebruikt het openbare JSON-endpoint achter tenderned.nl en valt terug op de officiële Atom-feed. De eerste run haalt ~1.000 publicaties terug (10–15 min). Het volledige detail per publicatie staat in `tenderned_details\`. |
| **RDW** | `rdw_registraties_per_soort.csv` (alle voertuigen per dag), `rdw_personenautos_per_brandstof.csv` en `..._per_merk.csv` (per dag, nieuw of import), `rdw_wagenpark_per_brandstof.csv` (hele wagenpark per peildatum) | De laatste 10 dagen worden elke run opnieuw geteld, zodat late registraties meetellen. "Benzine+Elektriciteit" omvat zowel plug-in als gewone hybrides. |
| **Laadpunten (DOT-NL)** | `data/laadpunten/per_exploitant/<JJJJ-MM>.csv` (elk uur) en `per_plaats/<JJJJ-MM>.csv` (een keer per dag): aantallen per status (beschikbaar, aan het laden, defect …) en de mediaan kWh-prijs voor AC en DC | De rij `_totaal` bevat heel Nederland. De status per afzonderlijk laadpunt, elke 5 minuten, staat in de hoogfrequente verzamelaar (hieronder). Tot 6 oktober 2026 werd per plaats elk uur gemeten. |
| **Netcongestie** | `netcongestie_*.csv`: vier lagen van de Capaciteitskaart (regionale netbeheerders en TenneT, afname en teruglevering), per voedingsgebied met status, wachtrij en aantal verzoeken | Schrijft alleen een nieuwe momentopname als de bron gewijzigd is. De statusvelden (`afname`, `opwek`) zijn de kleurcodes van de kaart. |
| **OV-fiets** (`ovfiets/`) | `data/ovfiets/historie/<code>/<JJJJ-MM>.csv`: beschikbare fietsen per locatie per ~15 min, plus `locaties_live_reeks.csv` | Python-script (alleen standaardbibliotheek) voor ovfietsbeschikbaar.nl. De site toont ~4 weken; `samenvoegen.py` bouwt daar doorlopende reeksen van. De reeks begint eind augustus 2026 (eerdere scrape meegenomen). |
| **OV-fiets wijzigingen** (`openov/`) | Op de branch `data`: `changes/<JJJJ-MM>.csv` (een regel per locatie waarvan het aantal fietsen of de openingsstatus veranderde), `scrapes/<JJJJ-MM>.csv` (elke poging, voor dekking en gaten), `locaties_meta.csv` en `state.json` | Elke 5 minuten via cron-job.org. Afgesloten maanden gaan als zip naar een release `data-JJJJ-MM` en daarna uit de branch. `openov/sync_local.ps1` haalt alles naar de lokale schijf. |
| **Laadpunten en parkeren, elke 5 minuten** (`hoogfrequent/`) | Op de branch `hoogfrequent-data` de lopende dag, afgesloten dagen als gzip in release `hf-JJJJ-MM`: `laadpunten_wijzigingen` (een regel per statuswijziging van een laadpunt: tijd, laadpunt, status), `laadpunten_stand` (status van alle ~187.000 laadpunten aan het begin van de dag), `laadpunten_kenmerken` (exploitant, adres, coördinaten, vermogen, stekkers; wekelijks), `parkeren_npr` (vrije plekken per garage, ~250 live garages), `parkeren_amsterdam` (garages en P+R), `parkeren_vrachtwagen` (8 truckparkings), `parkeren_garages` en `parkeren_catalogus` (kenmerken, wekelijks), `runs` (log per run) | Python, alleen standaardbibliotheek. Alleen wijzigingen, met het tijdstip van de bron: bij laadpunten is dat `last_updated` (op de seconde), dus wissels binnen 5 minuten vallen alleen weg als een laadpunt twee keer wisselt tussen twee runs. Geen van deze bronnen bewaart zelf historie (NDW: "Er is geen historische database ingericht"). Garages en locaties krijgen elk uur ook een regel zonder wijziging, als teken van leven. Omvang: ~5 MB gzip per dag (~150 MB per maand). `hoogfrequent\sync_local.ps1` haalt alles naar `hoogfrequent\data\`. |
| **Parkeren** | `data/parkeren/tariefdelen.csv`: alle RDW-tariefdelen met `eerst_gezien` en `laatst_gezien`; `data/parkeren/bezetting/<JJJJ-MM>.csv`: bezetting per garage, elk uur, tot 6 oktober 2026 | Tarieven worden één keer per dag vergeleken; een gewijzigd tarief verschijnt als nieuwe regel, de oude houdt zijn laatste datum. De bezetting zit sinds 6 oktober 2026 in de hoogfrequente verzamelaar (hieronder), elke 5 minuten. |
| **Deelmobiliteit** | `data/deelmobiliteit/<JJJJ-MM>.csv`: per aanbieder, stad en voertuigtype het aantal beschikbare, gereserveerde en defecte voertuigen, mediaan bereik, en per stationsysteem de voertuigen en vrije plekken in stations | Alle Nederlandse GBFS-feeds uit de catalogus van MobilityData (Check, Felyx, Donkey Republic, Cykl, GoAbout, OV-fiets). Dott vraagt sinds kort een login en valt buiten beeld. Momentopname: draai elk uur. |
| **Verstoringen** | Weg: `data/verstoringen/weg/<JJJJ-MM>.csv` (logboek per NDW-melding: type, oorzaak, begin, eind, vertraging, locatie, eerst en laatst gezien) en `weg_aantallen/<JJJJ-MM>.csv` (tellingen per run). Spoor: `spoor_per_dag.csv` (ritten, uitval, punctualiteit per dag, vervoerder en treinsoort) en `spoor_per_station/<JJJJ-MM>.csv` | Weg komt uit NDW 'actueel beeld' (DATEX II v3); draai elk uur, anders mis je korte incidenten. Spoor komt uit het maandarchief van Rijden de Treinen (verschijnt begin volgende maand); elke maand wordt één keer samengevat, vanaf januari 2026. |
| **OV (GTFS)** | `data/ov/realtime/<JJJJ-MM>.csv`: per run en per vervoerder en modaliteit het aantal ritten, uitgevallen ritten en vertraagde ritten (≥3 en ≥5 min) en de gemiddelde vertraging; `data/ov/meldingen/<JJJJ-MM>.csv`: logboek van storingsmeldingen (oorzaak, effect, vervoerders, tekst, periode); `data/ov/dienstregeling/<JJJJ-MM>.csv`: geplande ritten per vervoerder, modaliteit en dag voor de komende 14 dagen; `data/ov/routes.csv` | Van OVapi (open data van de vervoerders, zonder registratie). Live-data wordt alleen samengevat opgeslagen. De dienstregeling (~230 MB) wordt één keer per dag opgehaald. OVapi vraagt om identificatie in de User-Agent; die verwijst daarom naar deze repository. Let op bij het interpreteren: sommige vervoerders zetten geplande ritten op 'geannuleerd' en vervangen ze door nieuwe (zo lijkt bij de GVB-metro soms het merendeel uitgevallen); vergelijk daarom vooral in de tijd per vervoerder. |
| **Wachttijden** (alleen lokaal) | `lokaal/wachttijden/<jaar>.csv`: per peildatum, soort (polikliniek, diagnostiek, behandeling), onderwerp en aanbieder (ziekenhuis of kliniek) de wachttijd in dagen | NZa-gegevens zoals getoond op ZorgkaartNederland (de NZa verzamelt ze elke 2 weken; het NZa-dashboard zelf zit achter een login). De Patiëntenfederatie claimt rechten op de inhoud van haar website, daarom draait deze bron **alleen op deze pc** en schrijft naar `lokaal/`, dat nooit in git komt. Een keer per week, ~115 pagina's met 1,5 s pauze. Plannen: `Installeer-WachttijdenTaak.ps1` (als administrator). |
| **NS** (key: geheim `NS_API_KEY`) | `data/ns/storingen/<JJJJ-MM>.csv`: logboek van storingen, werkzaamheden en calamiteiten (titel, impact 1-5, oorzaak, situatie, begin, eind, stations); `data/ns/drukte/<JJJJ-MM>.csv`: per run en per station het aantal rijdende treinen met drukteverwachting laag, middel of hoog; `data/ns/rijdende_treinen.csv`; `data/ns/stations.csv` | Disruptions API, Virtual Train API en Stations API van NS. De gratis key is voor niet-commercieel gebruik; daarom alleen samenvattingen, geen ruwe NS-data. Zonder key wordt de bron overgeslagen. Een run kost ~350 verzoeken (limiet 300 per 5 minuten; we wachten 1,1 s per verzoek). |
| **Energie** | `data/energie/`, per maand een bestand (`<JJJJ-MM>.csv`, tijden in UTC): `opwek/` (MW per energiebron, plus verbruik en aandeel hernieuwbaar in %), `grensstromen/` (GW per buurland, positief = import), `dayahead/` (EUR/MWh; per uur tot oktober 2025, daarna per kwartier), alle drie van Energy-Charts vanaf 2015; `tennet_afrekenprijzen/`: onbalansprijzen per kwartier (tekort, overschot, op- en afregelen, regeltoestand); `tennet_balance_delta/`: balance delta (elke 12 s) samengevat per kwartier; `dayahead_nordpool.csv`: officiële day-ahead-prijs NL per kwartier (vandaag en morgen) | Energy-Charts (Fraunhofer ISE, CC BY 4.0) en Nord Pool zonder key; TenneT met geheim `TENNET_API_KEY`. Historie: elke run vult 6 maanden Energy-Charts terug aan tot januari 2015 (klaar na ongeveer een dag), en één keer per dag 8 maanden TenneT-afrekenprijzen, tot TenneT twee maanden achter elkaar niets meer heeft. Voortgang in `data/status/energie_historie.json`. TenneT staat maar 25 verzoeken per dag toe: de afrekenprijzen worden één keer per dag opgehaald (TenneT publiceert ze na afloop van de dag), de balance delta één keer per run. |
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
- **Neutrale identificatie.** De `UserAgent` in `config.psd1` noemt geen persoon of bedrijf, maar verwijst naar deze (anonieme) repository. Zo kunnen bronhouders contact opnemen via GitHub in plaats van te blokkeren; OVapi vraagt daar expliciet om. Laat hem eerlijk: geen nagebootste browser.
- **Niet vanaf het kantoornetwerk.** Wil je niet dat verzoeken van het IP-adres van kantoor komen, draai dan via GitHub Actions (of een eigen cloudserver). De bronnen zien dan een IP-adres van Microsoft/GitHub. GitHub zelf weet uiteraard wel van wie de repository is.

Wat deze verzamelaar bewust **niet** doet: wisselende proxy's, nagebootste browsers of het omzeilen van limieten en blokkades. Dat is in strijd met de gebruiksvoorwaarden van de meeste bronnen en is ook niet nodig: het volume is een paar honderd rustige verzoeken per dag, met een pauze tussen elk verzoek.

## Waarom niet het Centraal Insolventieregister?

Het CIR is alleen geautomatiseerd te bevragen via een webservice-abonnement, dus met registratie, en het bevat persoonsgegevens (schuldsaneringen). Het veld `Insolventie` in de KVK open dataset geeft hetzelfde signaal voor alle bv's en nv's: anoniem, dagelijks en onder CC BY 4.0. Heb je per leverancier details nodig (curator, rechtbank, datum), vraag dan het gratis CIR-abonnement aan. Dat is een aparte module die zich identificeert.

## Onderhoud

- **Endpoints veranderen.** Vooral EnergyZero en het TenderNed-endpoint zijn onofficieel. Een falende bron staat als `ERROR` in het log en als `fout` in `laatste_run.json`; de andere bronnen draaien gewoon door.
- **Veldwijzigingen bij netcongestie** komen in een nieuw bestand (`..._vanaf_<datum>.csv`), zodat oude reeksen niet breken.
- **Ruwe downloads** (`data\ruw\`) worden na 30 dagen opgeruimd; de CSV's blijven altijd staan. Instellingen staan in `config.psd1`.
- **Bronvermelding.** De KVK-data valt onder CC BY 4.0 en de RDW-data onder CC0. Controleer de voorwaarden van de andere bronnen en vermeld altijd de bron wanneer je de data gebruikt of deelt.
