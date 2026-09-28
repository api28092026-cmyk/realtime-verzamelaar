#!/usr/bin/env python3
"""
Scrapet http://fiets.openov.nl/locaties.json en logt alleen WIJZIGINGEN
in beschikbaarheid per locatie (change log). Alleen standaardbibliotheek.

Output (map data/; in GitHub staat die op de branch `data`):
  changes/YYYY-MM.csv   een rij per locatie waarvan rentalBikes of open-status veranderde
  scrapes/YYYY-MM.csv   een rij per scrape-poging (dekking/gaten controleren)
  locaties_meta.csv     statische kenmerken per locatie (overschreven, wijzigt zelden)
  state.json            laatst bekende stand per locatie (nodig voor change-detectie)
"""
import csv
import json
import time
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

URL = "http://fiets.openov.nl/locaties.json"
DATA = Path("data")
STATE = DATA / "state.json"


def fetch(retries: int = 3) -> dict:
    req = urllib.request.Request(URL, headers={"User-Agent": "ovfiets-scraper/1.0"})
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return json.load(r)
        except Exception:
            if attempt == retries:
                raise
            time.sleep(5 * attempt)


def append_csv(path: Path, header: list, rows: list) -> None:
    if not rows:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    new = not path.exists()
    with path.open("a", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        if new:
            w.writerow(header)
        w.writerows(rows)


def main() -> None:
    now = datetime.now(timezone.utc)
    ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    scrape_log = DATA / "scrapes" / f"{now:%Y-%m}.csv"
    scrape_header = ["scrape_ts_utc", "status", "n_locations", "n_changes", "max_fetch_time", "error"]

    try:
        payload = fetch()
    except Exception as e:
        append_csv(scrape_log, scrape_header, [[ts, "error", 0, 0, "", str(e)[:200]]])
        return

    locs = payload.get("locaties", {}) or {}
    state = json.loads(STATE.read_text(encoding="utf-8")) if STATE.exists() else {}

    changes, meta, fetch_times = [], [], []
    for code, loc in locs.items():
        extra = loc.get("extra") or {}
        bikes = extra.get("rentalBikes")          # string, kan ontbreken
        is_open = loc.get("open")                  # "Yes" / "No" / "Unknown"
        ft = extra.get("fetchTime")                # upstream-tijd per locatie (unix)
        if isinstance(ft, int):
            fetch_times.append(ft)

        cur = {"bikes": bikes, "open": is_open}
        if state.get(code) != cur:
            changes.append([ts, code, loc.get("stationCode", ""),
                            "" if bikes is None else bikes, is_open or "", ft or ""])
        state[code] = cur

        meta.append([code, loc.get("stationCode", ""), loc.get("name", ""),
                     (loc.get("city") or "").strip(), loc.get("lat", ""), loc.get("lng", ""),
                     extra.get("serviceType", ""), extra.get("type", "")])

    # Locaties die uit de feed verdwenen zijn
    for code in sorted(set(state) - set(locs)):
        changes.append([ts, code, "", "", "removed", ""])
        del state[code]

    month_file = DATA / "changes" / f"{now:%Y-%m}.csv"
    append_csv(month_file,
               ["scrape_ts_utc", "location_code", "station_code", "rental_bikes", "open", "fetch_time"],
               changes)

    # Meta alleen herschrijven (git commit alleen bij echte wijziging)
    meta.sort(key=lambda r: r[0].lower())
    meta_path = DATA / "locaties_meta.csv"
    DATA.mkdir(exist_ok=True)
    with meta_path.open("w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["location_code", "station_code", "name", "city", "lat", "lng", "service_type", "type"])
        w.writerows(meta)

    STATE.write_text(json.dumps(state, sort_keys=True, indent=0), encoding="utf-8")
    append_csv(scrape_log, scrape_header,
               [[ts, "ok", len(locs), len(changes), max(fetch_times, default=""), ""]])


if __name__ == "__main__":
    main()
