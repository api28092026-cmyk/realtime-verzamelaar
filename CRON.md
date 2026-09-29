# Planning: cron-job.org start de workflows

Alle workflows in deze repository hebben alleen een handmatige trigger (`workflow_dispatch`). De planning ligt bij [cron-job.org](https://cron-job.org): dat stuurt op vaste tijden een POST naar de GitHub-API, en GitHub start dan de workflow. De eigen planner van GitHub (`schedule:`) slaat bij drukte runs over of start ze tot een half uur te laat. cron-job.org is gratis en stipt.

De repository is openbaar, dus GitHub Actions-minuten zijn gratis en onbeperkt.

| Job in cron-job.org | Workflow | Wanneer | Body |
|---|---|---|---|
| OV-fiets wijzigingen | `openov.yml` | elke 5 minuten | `{"ref":"main"}` |
| Realtime-bronnen | `verzamelen.yml` | dagelijks 06:30 | `{"ref":"main"}` |
| Laadpunten (optioneel) | `verzamelen.yml` | elk uur op :05 | `{"ref":"main","inputs":{"bron":"Laadpunten"}}` |
| OV-fiets historie | `ovfiets.yml` | maandag en donderdag 04:20 | `{"ref":"main"}` |

## Stap 1: token aanmaken (eenmalig, op het account api28092026-cmyk)

1. GitHub > **Settings** > **Developer settings** > **Personal access tokens** > **Fine-grained tokens** > **Generate new token**.
2. **Repository access:** *Only select repositories* > `realtime-verzamelaar`.
3. **Permissions** > *Repository permissions* > **Actions: Read and write**. Metadata (alleen lezen) komt er automatisch bij; verder niets aanvinken.
4. Kies een lange vervaldatum en zet een herinnering in je agenda. Een verlopen token geeft in cron-job.org status 401 en de scrapers stoppen.

Met dit token kan alleen workflows in deze ene repository gestart worden, niets anders. Zet het nergens in de repository zelf.

## Stap 2: jobs in cron-job.org

Maak per regel uit de tabel een cronjob aan (*Create cronjob*):

- **URL:** `https://api.github.com/repos/api28092026-cmyk/realtime-verzamelaar/actions/workflows/<workflow>/dispatches`, bijvoorbeeld `.../workflows/openov.yml/dispatches`
- **Execution schedule:** zie de tabel. Zet onder *Advanced* de tijdzone op **Europe/Amsterdam**; dan hoef je niet met zomer- en wintertijd te rekenen.
- **Advanced > Request method:** `POST`
- **Advanced > Headers:**
  | Key | Value |
  |---|---|
  | `Authorization` | `Bearer <token uit stap 1>` |
  | `Accept` | `application/vnd.github+json` |
  | `X-GitHub-Api-Version` | `2022-11-28` |
  | `Content-Type` | `application/json` |
- **Advanced > Request body:** de body uit de tabel.
- **Notifications:** zet een melding aan bij mislukte uitvoeringen. GitHub antwoordt `204 No Content` als het goed gaat.

Testen kan ook vanaf de command line; `204` betekent dat de workflow gestart is:

```bash
curl -i -X POST -H "Authorization: Bearer <token>" -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" https://api.github.com/repos/api28092026-cmyk/realtime-verzamelaar/actions/workflows/openov.yml/dispatches -d "{\"ref\":\"main\"}"
```

Voor handmatig starten is een token niet nodig: gebruik het tabblad *Actions* > workflow > *Run workflow*, of:

```bash
gh workflow run verzamelen.yml -R api28092026-cmyk/realtime-verzamelaar -f bron=TenderNed
```

## Waar de data terechtkomt

| Workflow | Branch | Map |
|---|---|---|
| `openov.yml` | `data` | root van de branch: `changes/`, `scrapes/`, `state.json`, `locaties_meta.csv`; afgesloten maanden als release `data-JJJJ-MM` |
| `verzamelen.yml` | `main` | `data/` |
| `ovfiets.yml` | `main` | `data/ovfiets/` |

Een run van `ovfiets.yml` duurt 1,5 tot 2 uur, omdat de site elke historiepagina op de server uitrekent (~10–25 s per locatie). Hij heeft daarom een eigen wachtrij en houdt de runs van `verzamelen.yml` niet op. Beide schrijven naar andere bestanden en doen `git pull --rebase` vóór het pushen, dus ze botsen niet. Wordt een OV-fiets-run toch afgebroken, dan wordt wat al is opgehaald nog samengevoegd en opgeslagen.

Lokaal bijhouden: `openov\install_task.ps1` plant `openov\sync_local.ps1`, dat de OV-fiets-wijzigingen elk uur naar `openov\data\` haalt. Voor de rest volstaat een `git pull`.

## Alternatief zonder GitHub Actions

**Eigen Linux-server (crontab).** Zet eerst de tijdzone van de server op Europe/Amsterdam:

```bash
sudo timedatectl set-timezone Europe/Amsterdam
```

Voeg dan met `crontab -e` deze regels toe (een `%` moet in crontab als `\%`):

```cron
30 6 * * *   cd /opt/realtime-verzamelaar && pwsh -NoProfile -File ./Verzamel.ps1 >> data/logs/cron.log 2>&1
5 * * * *    cd /opt/realtime-verzamelaar && pwsh -NoProfile -File ./Verzamel.ps1 -Bron Laadpunten >> data/logs/cron.log 2>&1
20 4 * * 1,4 cd /opt/realtime-verzamelaar && ( python3 ovfiets/scrape_ovfiets.py --all --no-raw --out /tmp/ovfiets; python3 ovfiets/scrape_ovfiets.py --index --out /tmp/ovfiets; python3 ovfiets/samenvoegen.py /tmp/ovfiets data/ovfiets ) >> data/logs/cron.log 2>&1
30 7 * * *   cd /opt/realtime-verzamelaar && git add data && git commit -qm "Data $(date +\%F)" && git pull -q --rebase && git push -q
```

**Windows Taakplanner (deze pc).** Gebruik `.\Installeer-Taak.ps1 -LaadpuntenElkUur -OvFiets` en haal ze weer weg met `-Verwijder`.

Gebruik steeds maar één route. Anders halen twee machines dezelfde data op en krijg je dubbele commits.

## Bewaken

- In cron-job.org: de uitvoeringsgeschiedenis per job; bij een melding eerst naar de statuscode kijken (401 = token verlopen, 404 = verkeerde URL of workflownaam).
- In GitHub: *Actions* toont elke run; de eigenaar krijgt een e-mail als een workflow faalt.
- `data/status/laatste_run.json` op `main`: per realtime-bron de laatste uitkomst.
- `openov\sync_local.ps1` schrijft een waarschuwing in `openov\data\sync.log` als de laatste 5-minutenscrape ouder is dan 30 minuten.
