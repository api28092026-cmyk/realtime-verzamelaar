# Planning: wanneer draait wat

| Taak | Wanneer | Duur | Waarom zo vaak |
|---|---|---|---|
| Alle realtime-bronnen (`Verzamel.ps1`) | dagelijks 06:30 | ~5 min (eerste keer ~15) | De bronnen verversen dagelijks; RDW en KVK tellen een venster van dagen terug. |
| Laadpunten (`Verzamel.ps1 -Bron Laadpunten`) | elk uur (optioneel) | ~2 min | Status is een momentopname; pas met meerdere metingen per dag krijg je bezettingsgraden. |
| OV-fiets (`ovfiets/scrape_ovfiets.py`) | maandag en donderdag 04:20 | ~25 min | De site bewaart zelf ~4 weken per kwartier; twee keer per week geeft ruime overlap. |

Er zijn drie manieren om dit te plannen. Kies er één, anders halen twee machines dezelfde data op en krijg je dubbele commits.

## 1. GitHub Actions (aanbevolen)

De planning zit al in de repository:

- `.github/workflows/verzamelen.yml`: `30 4 * * *` (dagelijks)
- `.github/workflows/ovfiets.yml`: `20 2 * * 1,4` (maandag en donderdag)

**GitHub rekent cron in UTC.** `30 4 * * *` is 06:30 in de zomer en 05:30 in de winter. Wil je dat het hele jaar om 06:30 Nederlandse tijd valt, dan moet je de regel twee keer per jaar aanpassen. Voor deze data maakt dat niet uit.

Zo werkt de cron-regel (`minuut uur dag-van-maand maand dag-van-week`):

```
30 4 * * *       elke dag om 04:30 UTC
20 2 * * 1,4     maandag (1) en donderdag (4) om 02:20 UTC
5 * * * *        elk uur op :05
```

Handig om te weten:

- **Handmatig starten:** via het tabblad *Actions* > workflow > *Run workflow*, of vanaf de command line:
  ```bash
  gh workflow run verzamelen.yml -R api28092026-cmyk/realtime-verzamelaar
  ```
  Eén bron draaien kan ook:
  ```bash
  gh workflow run verzamelen.yml -R api28092026-cmyk/realtime-verzamelaar -f bron=TenderNed
  ```
- **Resultaten bekijken:**
  ```bash
  gh run list -R api28092026-cmyk/realtime-verzamelaar
  ```
- **Vertraging.** Geplande runs starten bij drukte soms 5–30 minuten te laat. Kies daarom geen tijdstip precies op het hele uur.
- **Minuten.** Een privérepository heeft 2.000 gratis Actions-minuten per maand. Dagelijks plus OV-fiets kost ~500 minuten. Een laadpuntrun elk uur (`5 * * * *`) komt daar ~1.500 bij; doe die liever op een eigen server of pc.
- **Inactiviteit.** GitHub zet geplande workflows uit na 60 dagen zonder activiteit in de repository. Omdat elke run data commit, gebeurt dat hier niet. Krijg je toch een melding, zet ze dan weer aan onder *Actions*.

Laadpunten elk uur via GitHub (als je de minuten ervoor over hebt): voeg in `verzamelen.yml` onder `schedule:` een tweede regel toe en laat de stap alleen de laadpunten draaien als dat schema afgaat:

```yaml
    - cron: '5 * * * *'
```
```pwsh
if ('${{ github.event.schedule }}' -eq '5 * * * *') { ./Verzamel.ps1 -Bron Laadpunten } elseif ($env:BRON) { ... } else { ./Verzamel.ps1 }
```

## 2. Eigen Linux-server (crontab)

Eenmalig:

```bash
sudo timedatectl set-timezone Europe/Amsterdam
git clone https://github.com/api28092026-cmyk/realtime-verzamelaar.git /opt/realtime-verzamelaar
# PowerShell 7 (pwsh) en Python 3 installeren, zie learn.microsoft.com/powershell/scripting/install
```

Daarna `crontab -e` en deze regels plakken (let op: `%` moet in crontab als `\%`):

```cron
MAILTO=""
# dagelijks 06:30: alle realtime-bronnen
30 6 * * *   cd /opt/realtime-verzamelaar && pwsh -NoProfile -File ./Verzamel.ps1 >> data/logs/cron.log 2>&1
# elk uur op :05: momentopname laadpunten
5 * * * *    cd /opt/realtime-verzamelaar && pwsh -NoProfile -File ./Verzamel.ps1 -Bron Laadpunten >> data/logs/cron.log 2>&1
# maandag en donderdag 04:20: OV-fiets
20 4 * * 1,4 cd /opt/realtime-verzamelaar && ( python3 ovfiets/scrape_ovfiets.py --all --no-raw --out /tmp/ovfiets; python3 ovfiets/scrape_ovfiets.py --index --out /tmp/ovfiets; python3 ovfiets/samenvoegen.py /tmp/ovfiets data/ovfiets ) >> data/logs/cron.log 2>&1
# optioneel 07:30: resultaten naar GitHub pushen (vereist een deploy key of token met schrijfrechten)
30 7 * * *   cd /opt/realtime-verzamelaar && git add data && git commit -qm "Data $(date +\%F)" && git pull -q --rebase && git push -q
```

Gebruik je deze route, schakel dan de geplande workflows in GitHub uit (*Actions* > workflow > *Disable workflow*).

## 3. Windows Taakplanner (deze pc)

```powershell
.\Installeer-Taak.ps1 -LaadpuntenElkUur -OvFiets   # dagelijks 06:30, laadpunten elk uur, OV-fiets ma/do 04:20
.\Installeer-Taak.ps1 -Verwijder                    # alles weer weghalen
```

De taken draaien onder je eigen account en alleen als de pc aan staat. Gemiste runs worden ingehaald. Pushen naar GitHub gebeurt hier niet automatisch.

## Bewaken

- `data/status/laatste_run.json`: per bron de laatste uitkomst (`ok` of `fout`) met melding.
- `data/logs/<JJJJ-MM>.log`: volledig logboek van de realtime-bronnen.
- In GitHub krijgt de eigenaar van de repository standaard een e-mail als een workflow faalt.
